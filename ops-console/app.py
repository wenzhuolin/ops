#!/usr/bin/env python3
import json
import os
import re
import socket
import subprocess
import threading
import uuid
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

BASE_DIR = Path(__file__).resolve().parent
SCRIPT_PATH = BASE_DIR / "scripts" / "ops_task.sh"
PATCH_BASE_DIR = Path(os.getenv("PATCH_BASE_DIR", "/opt/patch-system"))
META_FILE = PATCH_BASE_DIR / ".deploy_meta.json"
PATCH_PORT = int(os.getenv("PATCH_PORT", "3000"))
MAX_LOG_LINES = int(os.getenv("MAX_LOG_LINES", "5000"))

jobs = {}
jobs_lock = threading.Lock()
running_job_id = None


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def is_port_open(host: str, port: int, timeout: float = 0.5) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        return sock.connect_ex((host, port)) == 0


def validate_repo(repo: str) -> bool:
    pattern = r"^(https://|git@)[A-Za-z0-9._:/-]+(\.git)?$"
    return bool(re.match(pattern, repo))


def validate_ref(ref: str) -> bool:
    return bool(re.match(r"^[A-Za-z0-9._/\-]{1,128}$", ref))


def get_current_version() -> dict:
    if META_FILE.exists():
        try:
            content = json.loads(META_FILE.read_text(encoding="utf-8"))
            return {
                "commit": content.get("deployed_commit", "unknown"),
                "ref": content.get("deployed_ref", "unknown"),
                "updated_at": content.get("updated_at"),
            }
        except json.JSONDecodeError:
            return {"commit": "unknown", "ref": "unknown", "updated_at": None}
    return {"commit": "unknown", "ref": "unknown", "updated_at": None}


def parse_allowed_ips() -> set:
    raw = os.getenv("OPS_ALLOWED_IPS", "").strip()
    if not raw:
        return set()
    return {ip.strip() for ip in raw.split(",") if ip.strip()}


def request_auth_ok() -> bool:
    expected_user = os.getenv("OPS_USERNAME", "")
    expected_pass = os.getenv("OPS_PASSWORD", "")
    if not expected_user and not expected_pass:
        return True

    auth = request.authorization
    if not auth:
        return False
    return auth.username == expected_user and auth.password == expected_pass


def request_ip_ok() -> bool:
    allowed_ips = parse_allowed_ips()
    if not allowed_ips:
        return True
    client_ip = request.headers.get("X-Forwarded-For", request.remote_addr or "")
    client_ip = client_ip.split(",")[0].strip()
    return client_ip in allowed_ips


def require_guard(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not request_ip_ok():
            return jsonify({"error": "ip_not_allowed"}), 403
        if not request_auth_ok():
            return (
                jsonify({"error": "auth_required"}),
                401,
                {"WWW-Authenticate": 'Basic realm="Ops Console"'},
            )
        return fn(*args, **kwargs)

    return wrapper


def append_log(job_id: str, line: str) -> None:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return
        job["logs"].append(line.rstrip("\n"))
        if len(job["logs"]) > MAX_LOG_LINES:
            job["logs"] = job["logs"][-MAX_LOG_LINES:]


def run_job(job_id: str, action: str, repo: str = "", ref: str = "main") -> None:
    global running_job_id
    env = os.environ.copy()
    cmd = [str(SCRIPT_PATH), action]
    if action in {"download", "deploy", "upgrade"}:
        cmd.extend([repo, ref])

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        for line in process.stdout or []:
            append_log(job_id, line)
        return_code = process.wait()
        with jobs_lock:
            job = jobs.get(job_id, {})
            job["status"] = "success" if return_code == 0 else "failed"
            job["finished_at"] = now_iso()
            job["return_code"] = return_code
            jobs[job_id] = job
    except Exception as exc:  # noqa: BLE001
        append_log(job_id, f"[ERROR] Unexpected exception: {exc}")
        with jobs_lock:
            job = jobs.get(job_id, {})
            job["status"] = "failed"
            job["finished_at"] = now_iso()
            job["return_code"] = -1
            jobs[job_id] = job
    finally:
        with jobs_lock:
            if running_job_id == job_id:
                running_job_id = None


def create_job(action: str, repo: str = "", ref: str = "main"):
    global running_job_id
    with jobs_lock:
        if running_job_id and jobs.get(running_job_id, {}).get("status") == "running":
            return None, running_job_id

        job_id = str(uuid.uuid4())
        jobs[job_id] = {
            "id": job_id,
            "action": action,
            "repo": repo,
            "ref": ref,
            "status": "running",
            "logs": [f"[{datetime.now().strftime('%F %T')}] Job created: {action}"],
            "started_at": now_iso(),
            "finished_at": None,
            "return_code": None,
        }
        running_job_id = job_id

    thread = threading.Thread(target=run_job, args=(job_id, action, repo, ref), daemon=True)
    thread.start()
    return job_id, None


@app.get("/")
@require_guard
def index():
    return render_template("index.html")


@app.get("/api/status")
@require_guard
def api_status():
    version = get_current_version()
    with jobs_lock:
        active_job = running_job_id
    return jsonify(
        {
            "patch_running": is_port_open("127.0.0.1", PATCH_PORT),
            "patch_port": PATCH_PORT,
            "version": version,
            "active_job": active_job,
            "auth_enabled": bool(os.getenv("OPS_USERNAME", "") or os.getenv("OPS_PASSWORD", "")),
            "ip_filter_enabled": bool(parse_allowed_ips()),
        }
    )


@app.get("/api/job/<job_id>")
@require_guard
def api_job(job_id: str):
    try:
        offset = int(request.args.get("offset", "0"))
    except ValueError:
        offset = 0
    offset = max(offset, 0)

    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return jsonify({"error": "job_not_found"}), 404
        logs = job["logs"][offset:]
        return jsonify(
            {
                "id": job["id"],
                "action": job["action"],
                "status": job["status"],
                "started_at": job["started_at"],
                "finished_at": job["finished_at"],
                "return_code": job["return_code"],
                "logs": logs,
                "next_offset": offset + len(logs),
            }
        )


def parse_repo_ref():
    data = request.get_json(silent=True) or {}
    repo = (data.get("repo") or "").strip()
    ref = (data.get("ref") or "main").strip() or "main"
    if not repo:
        default_repo = os.getenv("DEFAULT_REPO", "").strip()
        repo = default_repo
    return repo, ref


def create_action_job(action: str):
    repo = ""
    ref = "main"
    if action in {"download", "deploy", "upgrade"}:
        repo, ref = parse_repo_ref()
        if not repo:
            return jsonify({"error": "repo_required"}), 400
        if not validate_repo(repo):
            return jsonify({"error": "invalid_repo"}), 400
        if not validate_ref(ref):
            return jsonify({"error": "invalid_ref"}), 400

    job_id, running = create_job(action, repo, ref)
    if not job_id:
        return jsonify({"error": "job_running", "job_id": running}), 409
    return jsonify({"job_id": job_id}), 202


@app.post("/api/download")
@require_guard
def api_download():
    return create_action_job("download")


@app.post("/api/deploy")
@require_guard
def api_deploy():
    return create_action_job("deploy")


@app.post("/api/upgrade")
@require_guard
def api_upgrade():
    return create_action_job("upgrade")


@app.post("/api/rollback")
@require_guard
def api_rollback():
    return create_action_job("rollback")


if __name__ == "__main__":
    if not SCRIPT_PATH.exists():
        raise SystemExit(f"Missing script: {SCRIPT_PATH}")

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "4000"))
    debug = os.getenv("FLASK_DEBUG", "0") == "1"
    app.run(host=host, port=port, debug=debug, threaded=True)
