# Ops Console One-Click Install Guide (Ubuntu 22+, IP Access)

This guide is for servers without domain names. You will access the console via:

`http://<server-ip>`

The installation script configures:

- Flask ops app on `127.0.0.1:4000` (not public)
- Nginx on `80` as reverse proxy
- Basic auth in Nginx (single auth by default)
- UFW rules to block ports `3000` and `4000` from public access
- systemd services for `ops-console` and `patch-system`

---

## 1) Prerequisites

- OS: Ubuntu 22.04+ (required by script)
- Root or sudo access
- Your project contains:
  - `app.py`
  - `templates/index.html`
  - `scripts/ops_task.sh`

The script auto-detects source dir:

- current dir contains `app.py`, or
- current dir contains `ops-console/app.py`

---

## 2) Quick Start

### 2.1 Upload/copy `ops-console` directory to server

Example target path:

`/opt/ops-console`

### 2.2 Run one command

```bash
cd /opt/ops-console
sudo bash install_ip_mode.sh \
  --default-repo https://github.com/your-org/patch-system.git \
  --default-ref main \
  --nginx-user opsweb \
  --nginx-password 'StrongNginxPass_ChangeMe'
```

Optional: restrict access by office IP(s):

```bash
sudo bash install_ip_mode.sh \
  --default-repo https://github.com/your-org/patch-system.git \
  --nginx-user opsweb \
  --nginx-password 'StrongNginxPass_ChangeMe' \
  --allowed-ips 1.2.3.4,5.6.7.8
```

When done, the script prints:

- URL: `http://<server-ip>`
- Nginx auth credentials

Optional: if you still want app-level auth, enable it explicitly:

```bash
sudo bash install_ip_mode.sh \
  --default-repo https://github.com/your-org/patch-system.git \
  --enable-app-auth yes \
  --ops-username admin \
  --ops-password 'StrongOpsPass_ChangeMe'
```

---

## 3) What the script does

1. Validates Ubuntu 22+ and root privileges
2. Installs packages (`git`, `python3`, `nginx`, `ufw`, etc.)
3. Installs Node.js 20 if missing/too old
4. Copies ops files to `/opt/ops-console`
5. Creates Python venv and installs dependencies
6. Generates:
   - `/etc/systemd/system/ops-console.service`
   - `/etc/systemd/system/patch-system.service`
7. Configures Nginx:
   - `/etc/nginx/sites-available/ops-console`
   - Basic auth file `/etc/nginx/.ops_htpasswd`
8. Applies UFW rules:
   - allow `22/tcp`, `80/tcp`
   - deny `3000/tcp`, `4000/tcp`
9. Starts services:
   - `ops-console`
   - `nginx`

---

## 4) First deployment workflow in UI

Open browser:

`http://<server-ip>`

Then:

1. Enter patch system git URL
2. Enter branch/tag (default `main`)
3. Click **Download**
4. Click **Deploy**
5. Watch real-time logs

Patch files are managed under:

- current release: `/opt/patch-system/current`
- backup release: `/opt/patch-system/backup`

---

## 5) Upgrade and rollback

- Upgrade: click **Upgrade**
- Rollback: click **Rollback**

The script attempts automatic rollback when upgrade fails after release activation.

---

## 6) Validate installation

```bash
systemctl status ops-console --no-pager
systemctl status nginx --no-pager
systemctl status patch-system --no-pager
curl -I http://127.0.0.1:4000
nginx -t
ufw status
```

Logs:

```bash
journalctl -u ops-console -f
journalctl -u nginx -f
journalctl -u patch-system -f
```

---

## 7) Common commands

Restart services:

```bash
sudo systemctl restart ops-console
sudo systemctl restart nginx
sudo systemctl restart patch-system
```

Re-run installer with updated config:

```bash
cd /opt/ops-console
sudo bash install_ip_mode.sh --default-repo <repo-url> --ops-password '<new-pass>'
```

---

## 8) Script options

```text
--source-dir <path>
--install-dir <path>                default /opt/ops-console
--patch-base-dir <path>             default /opt/patch-system
--patch-service-name <name>         default patch-system
--patch-port <port>                 default 3000
--ops-host <host>                   default 127.0.0.1
--ops-port <port>                   default 4000
--default-repo <url>
--default-ref <ref>                 default main
--enable-app-auth <yes|no>          default no
--ops-username <name>               only used when app auth enabled
--ops-password <pass>               only used when app auth enabled
--nginx-user <name>                 default opsweb
--nginx-password <pass>             auto-generate if empty
--allowed-ips <csv>                 optional whitelist
--enable-ufw <yes|no>               default yes
--auto-install-node <yes|no>        default yes
```
