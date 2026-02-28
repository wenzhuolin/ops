#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
REPO_URL="${2:-}"
REF="${3:-main}"

BASE_DIR="${PATCH_BASE_DIR:-/opt/patch-system}"
APP_DIR="${BASE_DIR}/current"
TMP_DIR="${BASE_DIR}/tmp_build"
BACKUP_DIR="${BASE_DIR}/backup"
META_FILE="${BASE_DIR}/.deploy_meta.json"
SERVICE_NAME="${PATCH_SERVICE_NAME:-patch-system}"
NODE_PORT="${PATCH_PORT:-3000}"
START_CMD="${PATCH_START_CMD:-/usr/bin/npm start}"
GIT_RETRY_COUNT="${GIT_RETRY_COUNT:-4}"
GIT_RETRY_DELAY="${GIT_RETRY_DELAY:-2}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

validate_ref() {
  [[ "$REF" =~ ^[A-Za-z0-9._/\-]{1,128}$ ]] || die "非法 ref: $REF"
}

validate_repo() {
  [[ "$REPO_URL" =~ ^(https://|git@)[A-Za-z0-9._:/-]+(\.git)?$ ]] || die "非法 repo: $REPO_URL"
}

write_meta() {
  local commit="$1"
  local ref="$2"
  cat >"$META_FILE" <<EOF
{"deployed_commit":"$commit","deployed_ref":"$ref","updated_at":"$(date -Iseconds)"}
EOF
}

current_commit() {
  git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

prepare_base() {
  mkdir -p "$BASE_DIR"
  require_cmd git
}

clone_to_tmp() {
  rm -rf "$TMP_DIR"
  log "拉取代码: $REPO_URL @ $REF"
  git_clone_with_retry "$REPO_URL" "$REF" "$TMP_DIR"
}

git_clone_with_retry() {
  local repo_url="$1"
  local ref_name="$2"
  local target_dir="$3"
  local total="${GIT_RETRY_COUNT}"
  local delay="${GIT_RETRY_DELAY}"
  local attempt=1

  while (( attempt <= total )); do
    rm -rf "$target_dir"
    if git -c http.version=HTTP/1.1 clone --depth 1 --single-branch --branch "$ref_name" "$repo_url" "$target_dir"; then
      return 0
    fi

    if (( attempt == total )); then
      log "git clone 连续失败，已达到最大重试次数: ${total}"
      return 1
    fi

    log "git clone 失败，${delay}s 后进行第 $((attempt + 1)) 次重试..."
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done

  return 1
}

build_node_project() {
  cd "$TMP_DIR"
  require_cmd npm

  if [[ -f package-lock.json ]]; then
    log "执行 npm ci"
    npm ci
  else
    log "执行 npm install"
    npm install
  fi

  if node -e "const p=require('./package.json');process.exit(p.scripts&&p.scripts.build?0:1)" >/dev/null 2>&1; then
    log "执行 npm run build"
    npm run build
  else
    log "未检测到 build 脚本，跳过构建"
  fi
}

install_patch_service_if_missing() {
  require_cmd systemctl
  local service_path="/etc/systemd/system/${SERVICE_NAME}.service"
  if [[ -f "$service_path" ]]; then
    return 0
  fi

  log "创建补丁服务 systemd 文件: $service_path"
  cat >"$service_path" <<EOF
[Unit]
Description=Patch System Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${START_CMD}
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=${NODE_PORT}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

activate_tmp_release() {
  if [[ -d "$APP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
    mv "$APP_DIR" "$BACKUP_DIR"
    log "已备份当前版本到: $BACKUP_DIR"
  fi
  mv "$TMP_DIR" "$APP_DIR"
  local commit
  commit="$(current_commit)"
  write_meta "$commit" "$REF"
  log "已切换到版本: ${commit} (${REF})"
}

restart_patch_service() {
  install_patch_service_if_missing
  log "重启服务: $SERVICE_NAME"
  systemctl restart "$SERVICE_NAME" || return 1
  systemctl is-active --quiet "$SERVICE_NAME" || return 1
  log "服务运行正常"
  return 0
}

do_download() {
  prepare_base
  validate_repo
  validate_ref

  if [[ -d "$APP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
    mv "$APP_DIR" "$BACKUP_DIR"
    log "下载前备份完成: $BACKUP_DIR"
  fi

  rm -rf "$APP_DIR"
  log "开始下载代码（不部署）"
  git_clone_with_retry "$REPO_URL" "$REF" "$APP_DIR"

  local commit
  commit="$(current_commit)"
  write_meta "$commit" "$REF"
  log "下载完成，当前版本: ${commit} (${REF})"
}

do_deploy() {
  prepare_base
  validate_repo
  validate_ref

  clone_to_tmp
  build_node_project
  activate_tmp_release
  restart_patch_service || die "服务启动失败: $SERVICE_NAME"
  log "部署完成"
}

do_upgrade() {
  prepare_base
  validate_repo
  validate_ref

  local activated="0"
  set +e
  clone_to_tmp
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log "升级失败：拉取代码失败"
    exit $rc
  fi

  build_node_project
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log "升级失败：构建失败"
    rm -rf "$TMP_DIR"
    exit $rc
  fi

  activate_tmp_release
  activated="1"
  restart_patch_service
  rc=$?

  if [[ $rc -ne 0 ]]; then
    log "升级后重启失败，执行自动回滚"
    if [[ "$activated" == "1" ]]; then
      do_rollback || true
    fi
    exit $rc
  fi
  set -e
  log "升级完成"
}

do_rollback() {
  prepare_base
  require_cmd systemctl

  [[ -d "$BACKUP_DIR" ]] || die "未找到备份目录: $BACKUP_DIR"
  rm -rf "$APP_DIR"
  mv "$BACKUP_DIR" "$APP_DIR"
  local commit
  commit="$(current_commit)"
  write_meta "$commit" "rollback"
  log "已回滚到版本: $commit"
  systemctl restart "$SERVICE_NAME" || die "回滚后服务重启失败"
  log "回滚完成"
}

case "$ACTION" in
  download)
    do_download
    ;;
  deploy)
    do_deploy
    ;;
  upgrade)
    do_upgrade
    ;;
  rollback)
    do_rollback
    ;;
  *)
    die "未知动作: $ACTION，支持: download | deploy | upgrade | rollback"
    ;;
esac
