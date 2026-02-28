#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_DIR="${SOURCE_DIR:-$SCRIPT_DIR}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ops-console}"
PATCH_BASE_DIR="${PATCH_BASE_DIR:-/opt/patch-system}"
PATCH_SERVICE_NAME="${PATCH_SERVICE_NAME:-patch-system}"
PATCH_PORT="${PATCH_PORT:-3000}"
OPS_HOST="${OPS_HOST:-127.0.0.1}"
OPS_PORT="${OPS_PORT:-4000}"

DEFAULT_REPO="${DEFAULT_REPO:-}"
DEFAULT_REF="${DEFAULT_REF:-main}"
OPS_USERNAME="${OPS_USERNAME:-admin}"
OPS_PASSWORD="${OPS_PASSWORD:-}"
NGINX_AUTH_USER="${NGINX_AUTH_USER:-opsweb}"
NGINX_AUTH_PASSWORD="${NGINX_AUTH_PASSWORD:-}"
ALLOWED_IPS="${ALLOWED_IPS:-}"
ENABLE_UFW="${ENABLE_UFW:-yes}"
AUTO_INSTALL_NODE="${AUTO_INSTALL_NODE:-yes}"

print_usage() {
  cat <<'EOF'
Usage:
  sudo bash install_ip_mode.sh [options]

Options:
  --source-dir <path>             Source directory containing app.py/templates/scripts
  --install-dir <path>            Install directory (default: /opt/ops-console)
  --patch-base-dir <path>         Patch base dir (default: /opt/patch-system)
  --patch-service-name <name>     Patch systemd service name (default: patch-system)
  --patch-port <port>             Patch port (default: 3000)
  --ops-host <host>               Ops app host (default: 127.0.0.1)
  --ops-port <port>               Ops app port (default: 4000)
  --default-repo <url>            Default patch git repo in UI
  --default-ref <ref>             Default branch/tag in UI (default: main)
  --ops-username <name>           Flask basic auth username (default: admin)
  --ops-password <pass>           Flask basic auth password (auto-generate if empty)
  --nginx-user <name>             Nginx basic auth user (default: opsweb)
  --nginx-password <pass>         Nginx basic auth password (auto-generate if empty)
  --allowed-ips <csv>             Comma-separated allowed IPs (optional)
  --enable-ufw <yes|no>           Configure UFW (default: yes)
  --auto-install-node <yes|no>    Install Node.js 20 when missing/old (default: yes)
  --help                          Show this message

Examples:
  sudo bash install_ip_mode.sh \
    --default-repo https://github.com/acme/patch-system.git \
    --ops-username admin \
    --ops-password 'ChangeMeStrong' \
    --nginx-user opsweb \
    --nginx-password 'AnotherStrongPass' \
    --allowed-ips 1.2.3.4,5.6.7.8
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo -i)."
}

require_ubuntu_22_plus() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script targets Ubuntu."
  local major
  major="$(printf '%s' "${VERSION_ID:-0}" | cut -d. -f1)"
  [[ "$major" -ge 22 ]] || die "Ubuntu 22+ is required."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-dir) SOURCE_DIR="$2"; shift 2 ;;
      --install-dir) INSTALL_DIR="$2"; shift 2 ;;
      --patch-base-dir) PATCH_BASE_DIR="$2"; shift 2 ;;
      --patch-service-name) PATCH_SERVICE_NAME="$2"; shift 2 ;;
      --patch-port) PATCH_PORT="$2"; shift 2 ;;
      --ops-host) OPS_HOST="$2"; shift 2 ;;
      --ops-port) OPS_PORT="$2"; shift 2 ;;
      --default-repo) DEFAULT_REPO="$2"; shift 2 ;;
      --default-ref) DEFAULT_REF="$2"; shift 2 ;;
      --ops-username) OPS_USERNAME="$2"; shift 2 ;;
      --ops-password) OPS_PASSWORD="$2"; shift 2 ;;
      --nginx-user) NGINX_AUTH_USER="$2"; shift 2 ;;
      --nginx-password) NGINX_AUTH_PASSWORD="$2"; shift 2 ;;
      --allowed-ips) ALLOWED_IPS="$2"; shift 2 ;;
      --enable-ufw) ENABLE_UFW="$2"; shift 2 ;;
      --auto-install-node) AUTO_INSTALL_NODE="$2"; shift 2 ;;
      --help|-h) print_usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

random_password() {
  python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(18)))
PY
}

normalize_source_dir() {
  if [[ -f "$SOURCE_DIR/app.py" && -d "$SOURCE_DIR/templates" ]]; then
    return 0
  fi
  if [[ -f "$SOURCE_DIR/ops-console/app.py" && -d "$SOURCE_DIR/ops-console/templates" ]]; then
    SOURCE_DIR="$SOURCE_DIR/ops-console"
    return 0
  fi
  die "Cannot locate source files under SOURCE_DIR=$SOURCE_DIR"
}

install_apt_packages() {
  log "Installing base packages..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl rsync python3 python3-venv python3-pip nginx apache2-utils ufw
}

install_node_if_needed() {
  [[ "$AUTO_INSTALL_NODE" == "yes" ]] || return 0

  local need_install="yes"
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -p 'process.versions.node.split(".")[0]')"
    if [[ "$major" -ge 20 ]]; then
      need_install="no"
    fi
  fi

  if [[ "$need_install" == "yes" ]]; then
    log "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  else
    log "Node.js >=20 already installed."
  fi
}

install_ops_files() {
  log "Deploying ops console files..."
  mkdir -p "$INSTALL_DIR" "$PATCH_BASE_DIR"
  rsync -a --delete "$SOURCE_DIR/" "$INSTALL_DIR/"
  chmod +x "$INSTALL_DIR/scripts/ops_task.sh"
}

install_python_requirements() {
  log "Installing Python dependencies in virtualenv..."
  python3 -m venv "$INSTALL_DIR/.venv"
  "$INSTALL_DIR/.venv/bin/pip" install -U pip
  "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
}

write_patch_service() {
  log "Writing patch-system service..."
  cat >"/etc/systemd/system/${PATCH_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Patch System Node App
After=network.target

[Service]
Type=simple
WorkingDirectory=${PATCH_BASE_DIR}/current
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=${PATCH_PORT}

[Install]
WantedBy=multi-user.target
EOF
}

write_ops_service() {
  log "Writing ops-console service..."
  local service_file="/etc/systemd/system/ops-console.service"
  cat >"$service_file" <<EOF
[Unit]
Description=Patch Ops Console (Flask)
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/app.py
Restart=always
RestartSec=3
Environment=HOST=${OPS_HOST}
Environment=PORT=${OPS_PORT}
Environment=PATCH_BASE_DIR=${PATCH_BASE_DIR}
Environment=PATCH_SERVICE_NAME=${PATCH_SERVICE_NAME}
Environment=PATCH_PORT=${PATCH_PORT}
Environment=DEFAULT_REPO=${DEFAULT_REPO}
Environment=OPS_USERNAME=${OPS_USERNAME}
Environment=OPS_PASSWORD=${OPS_PASSWORD}
EOF

  if [[ -n "$ALLOWED_IPS" ]]; then
    printf 'Environment=OPS_ALLOWED_IPS=%s\n' "$ALLOWED_IPS" >>"$service_file"
  fi

  cat >>"$service_file" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_config() {
  log "Configuring Nginx reverse proxy (IP mode)..."

  htpasswd -bc /etc/nginx/.ops_htpasswd "$NGINX_AUTH_USER" "$NGINX_AUTH_PASSWORD" >/dev/null

  local conf="/etc/nginx/sites-available/ops-console"
  cat >"$conf" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    auth_basic "Ops Console";
    auth_basic_user_file /etc/nginx/.ops_htpasswd;

EOF

  if [[ -n "$ALLOWED_IPS" ]]; then
    IFS=',' read -r -a ip_arr <<<"$ALLOWED_IPS"
    for ip in "${ip_arr[@]}"; do
      ip="$(printf '%s' "$ip" | xargs)"
      [[ -n "$ip" ]] && printf '    allow %s;\n' "$ip" >>"$conf"
    done
    printf '    deny all;\n\n' >>"$conf"
  fi

  cat >>"$conf" <<EOF
    location / {
        proxy_pass http://${OPS_HOST}:${OPS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sfn "$conf" /etc/nginx/sites-enabled/ops-console
  nginx -t
}

configure_ufw() {
  [[ "$ENABLE_UFW" == "yes" ]] || {
    log "Skipping UFW configuration (--enable-ufw no)."
    return 0
  }

  log "Applying UFW rules..."
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw deny 3000/tcp || true
  ufw deny 4000/tcp || true
  ufw --force enable
}

start_services() {
  log "Enabling and restarting services..."
  systemctl daemon-reload
  systemctl enable "$PATCH_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl enable --now ops-console
  systemctl enable --now nginx
  systemctl restart nginx
}

show_summary() {
  local server_ip
  server_ip="$(hostname -I | awk '{print $1}')"
  echo
  echo "==============================================================="
  echo "Installation completed."
  echo "Visit: http://${server_ip}"
  echo
  echo "[Nginx Basic Auth]"
  echo "  user: ${NGINX_AUTH_USER}"
  echo "  pass: ${NGINX_AUTH_PASSWORD}"
  echo
  echo "[Ops App Basic Auth]"
  echo "  user: ${OPS_USERNAME}"
  echo "  pass: ${OPS_PASSWORD}"
  echo
  echo "Services:"
  echo "  systemctl status ops-console --no-pager"
  echo "  systemctl status nginx --no-pager"
  echo "  systemctl status ${PATCH_SERVICE_NAME} --no-pager"
  echo
  echo "Logs:"
  echo "  journalctl -u ops-console -f"
  echo "  journalctl -u nginx -f"
  echo "==============================================================="
}

main() {
  require_root
  require_ubuntu_22_plus
  parse_args "$@"
  normalize_source_dir

  [[ -n "$OPS_USERNAME" ]] || die "--ops-username cannot be empty"
  [[ -n "$DEFAULT_REF" ]] || die "--default-ref cannot be empty"
  [[ "$ENABLE_UFW" =~ ^(yes|no)$ ]] || die "--enable-ufw must be yes|no"
  [[ "$AUTO_INSTALL_NODE" =~ ^(yes|no)$ ]] || die "--auto-install-node must be yes|no"

  if [[ -z "$OPS_PASSWORD" ]]; then
    OPS_PASSWORD="$(random_password)"
    log "Generated ops app password."
  fi
  if [[ -z "$NGINX_AUTH_PASSWORD" ]]; then
    NGINX_AUTH_PASSWORD="$(random_password)"
    log "Generated nginx basic auth password."
  fi

  install_apt_packages
  install_node_if_needed
  install_ops_files
  install_python_requirements
  write_patch_service
  write_ops_service
  write_nginx_config
  configure_ufw
  start_services
  show_summary
}

main "$@"
