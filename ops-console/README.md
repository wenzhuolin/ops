# 补丁系统运维页面（极简版）

一个独立的运维页面，部署在同一台 Linux 服务器上，默认端口 `4000`，用于管理补丁系统（默认端口 `3000`）的下载、部署、升级与回滚。

---

## 1. 整体架构（极简）

- 前端：单页 HTML + 原生 JavaScript，负责提交操作和轮询日志。
- 后端：Flask 提供 API，接收请求后异步调用 Shell 脚本执行实际运维动作。
- 执行层：`scripts/ops_task.sh` 统一处理 `download/deploy/upgrade/rollback`，并通过 `systemd` 管理补丁服务与运维页面服务。
- 状态来源：通过检测 `3000` 端口监听状态 + 读取部署元数据 `.deploy_meta.json` 展示当前版本。

---

## 2. 推荐目录结构

```text
ops-console/
├── app.py                         # Flask 后端
├── requirements.txt               # Python 依赖
├── templates/
│   └── index.html                 # 运维页面（原生 JS）
├── scripts/
│   └── ops_task.sh                # download/deploy/upgrade/rollback 核心脚本
└── systemd/
    ├── ops-console.service        # 运维页面服务 (4000)
    └── patch-system.service       # 补丁系统服务 (3000, npm start)
```

---

## 3. 快速部署（Ubuntu 20.04 / CentOS 7）

> 下面按“从零开始”给出最小步骤，默认你有 root 或 sudo 权限。

### 3.1 安装基础依赖

#### Ubuntu 20.04

```bash
sudo apt update
sudo apt install -y git curl python3 python3-pip python3-venv nodejs npm
```

#### CentOS 7

```bash
sudo yum install -y epel-release
sudo yum install -y git curl python3 python3-pip nodejs npm
```

### 3.2 放置代码并安装 Python 依赖

```bash
sudo mkdir -p /opt/ops-console
sudo cp -r ./ops-console/* /opt/ops-console/
cd /opt/ops-console
sudo python3 -m venv .venv
sudo ./.venv/bin/pip install -U pip
sudo ./.venv/bin/pip install -r requirements.txt
sudo chmod +x /opt/ops-console/scripts/ops_task.sh
```

> 如果你使用虚拟环境启动，把 `systemd/ops-console.service` 的 `ExecStart` 改为：
>
> `ExecStart=/opt/ops-console/.venv/bin/python /opt/ops-console/app.py`

### 3.3 安装并启动运维页面服务（4000）

```bash
sudo cp /opt/ops-console/systemd/ops-console.service /etc/systemd/system/ops-console.service
sudo systemctl daemon-reload
sudo systemctl enable --now ops-console
sudo systemctl status ops-console --no-pager
```

访问：`http://<服务器IP>:4000`

### 3.4 首次部署补丁系统（3000）

在运维页面输入：

- 仓库地址：`https://github.com/your-org/patch-system.git`
- 分支/Tag：`main`

点击 **部署服务**，脚本会：

1. 拉取代码；
2. 执行 `npm ci`/`npm install` + `npm run build`（若存在）；
3. 创建/重启 `patch-system` systemd 服务；
4. 写入部署元数据（当前 commit、ref、时间）。

---

## 4. API 说明（后端核心接口）

### 状态检查

```http
GET /api/status
```

返回：

```json
{
  "patch_running": true,
  "patch_port": 3000,
  "version": {
    "commit": "a1b2c3d",
    "ref": "main",
    "updated_at": "2026-02-28T11:22:33+00:00"
  },
  "active_job": null
}
```

### 下载 / 部署 / 升级

```http
POST /api/download
POST /api/deploy
POST /api/upgrade
Content-Type: application/json

{
  "repo": "https://github.com/your-org/patch-system.git",
  "ref": "main"
}
```

返回：

```json
{ "job_id": "uuid..." }
```

### 回滚

```http
POST /api/rollback
```

### 任务日志轮询

```http
GET /api/job/<job_id>?offset=0
```

前端每 1 秒轮询一次，增量获取日志并刷新终端输出。

---

## 5. 默认行为说明

- 代码目录：`/opt/patch-system/current`
- 备份目录：`/opt/patch-system/backup`
- 升级失败：脚本会尝试自动回滚（尤其在“替换成功但服务重启失败”场景）
- 一键回滚：点击页面 **回滚** 按钮触发

---

## 6. 安全注意事项（至少做前两条）

1. **启用账号密码**（必须）  
   在 `ops-console.service` 里设置：
   - `OPS_USERNAME=admin`
   - `OPS_PASSWORD=强密码`

2. **限制来源 IP**（强烈建议）  
   设置：`OPS_ALLOWED_IPS=你的办公出口IP`

3. **防火墙仅放行必要端口**  
   - 外部开放：`4000`（建议仅办公网段）
   - 业务端口：`3000`（按需开放或仅内网）

4. **建议加 HTTPS**  
   可在 Nginx 做反向代理与 TLS 终止，再转发到 `127.0.0.1:4000`。

5. **最小权限原则**  
   生产上建议给运维页面单独用户，并通过 `sudoers` 仅放行必要命令（`systemctl patch-system`、部署脚本）。

---

## 7. 适配其他技术栈

当前脚本默认 Node.js。若补丁系统是 Java / Go / Python，可修改 `scripts/ops_task.sh`：

- 构建命令（例如 `mvn package` / `go build` / `pip install -r`）
- 启动命令（通过 `PATCH_START_CMD` 环境变量指定）

其余接口和页面可保持不变。
