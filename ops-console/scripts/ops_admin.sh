#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

SERVICE_NAME="${SERVICE_NAME:-ops-console}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ops-console}"
BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-}"
SKIP_PIP="${SKIP_PIP:-no}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Ops-only maintenance helper

Usage:
  sudo bash scripts/ops_admin.sh restart
  sudo bash scripts/ops_admin.sh stop
  sudo bash scripts/ops_admin.sh upgrade [options]

Options (for upgrade):
  --repo <url>              Upgrade from git repo URL
  --branch <name>           Branch/tag to pull (default: main)
  --install-dir <path>      Ops install directory (default: /opt/ops-console)
  --service-name <name>     systemd service name (default: ops-console)
  --skip-pip <yes|no>       Skip pip install (default: no)

Examples:
  sudo bash scripts/ops_admin.sh restart
  sudo bash scripts/ops_admin.sh stop
  sudo bash scripts/ops_admin.sh upgrade --branch main
  sudo bash scripts/ops_admin.sh upgrade --repo https://github.com/acme/ops.git --branch main
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."
}

parse_upgrade_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO_URL="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --install-dir) INSTALL_DIR="$2"; shift 2 ;;
      --service-name) SERVICE_NAME="$2"; shift 2 ;;
      --skip-pip) SKIP_PIP="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

ensure_service_exists() {
  systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || die "systemd service not found: ${SERVICE_NAME}.service"
}

restart_ops() {
  ensure_service_exists
  log "Restarting ${SERVICE_NAME}..."
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "Service failed to start: $SERVICE_NAME"
  log "Service is active: $SERVICE_NAME"
}

stop_ops() {
  ensure_service_exists
  log "Stopping ${SERVICE_NAME}..."
  systemctl stop "$SERVICE_NAME"
  log "Service stopped: $SERVICE_NAME"
}

detect_source_dir() {
  local root="$1"
  if [[ -f "$root/app.py" && -d "$root/templates" ]]; then
    printf '%s\n' "$root"
    return 0
  fi
  if [[ -f "$root/ops-console/app.py" && -d "$root/ops-console/templates" ]]; then
    printf '%s\n' "$root/ops-console"
    return 0
  fi
  return 1
}

upgrade_from_local_git() {
  [[ -d "$INSTALL_DIR/.git" ]] || return 1
  log "Upgrading from local git repo: $INSTALL_DIR (branch/tag: $BRANCH)"
  git -C "$INSTALL_DIR" fetch origin "$BRANCH"
  git -C "$INSTALL_DIR" checkout "$BRANCH"
  git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
}

upgrade_from_remote_repo() {
  [[ -n "$REPO_URL" ]] || die "No git repo found in $INSTALL_DIR; please provide --repo <url>"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  log "Cloning from remote repo: $REPO_URL (branch/tag: $BRANCH)"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$tmp_dir/repo"

  local src
  src="$(detect_source_dir "$tmp_dir/repo")" || die "Cannot find ops source (app.py/templates) in repo."
  mkdir -p "$INSTALL_DIR"
  rsync -a --delete "$src/" "$INSTALL_DIR/"
  log "Files synchronized to: $INSTALL_DIR"
}

refresh_python_deps() {
  [[ "$SKIP_PIP" =~ ^(yes|no)$ ]] || die "--skip-pip must be yes|no"
  [[ "$SKIP_PIP" == "yes" ]] && {
    log "Skipping pip install (--skip-pip yes)."
    return 0
  }

  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  if [[ ! -d "$INSTALL_DIR/.venv" ]]; then
    log "Creating virtualenv..."
    python3 -m venv "$INSTALL_DIR/.venv"
  fi
  log "Installing Python dependencies..."
  "$INSTALL_DIR/.venv/bin/pip" install -U pip
  "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
}

make_scripts_executable() {
  if compgen -G "$INSTALL_DIR/scripts/*.sh" >/dev/null 2>&1; then
    chmod +x "$INSTALL_DIR"/scripts/*.sh
  fi
  [[ -f "$INSTALL_DIR/install_ip_mode.sh" ]] && chmod +x "$INSTALL_DIR/install_ip_mode.sh"
}

upgrade_ops() {
  ensure_service_exists
  command -v git >/dev/null 2>&1 || die "git not found"
  command -v rsync >/dev/null 2>&1 || die "rsync not found"

  if ! upgrade_from_local_git; then
    upgrade_from_remote_repo
  fi
  refresh_python_deps
  make_scripts_executable
  systemctl daemon-reload
  restart_ops
  log "Upgrade finished."
}

main() {
  require_root
  case "$ACTION" in
    restart)
      restart_ops
      ;;
    stop)
      stop_ops
      ;;
    upgrade)
      parse_upgrade_args "$@"
      upgrade_ops
      ;;
    ""|help|--help|-h)
      usage
      ;;
    *)
      die "Unknown action: $ACTION (supported: restart | stop | upgrade)"
      ;;
  esac
}

main "$@"
