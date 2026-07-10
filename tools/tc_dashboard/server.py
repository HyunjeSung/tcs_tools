#!/usr/bin/env python3
"""system_log TC 웹 대시보드 백엔드.

DUT(config.env의 DUT_HOST)에 SSH로 tc_system_log.sh 를 transfer+실행하고,
결과를 파싱해 현황판/실행이력으로 제공한다.
"""
import asyncio
import json
import re
import subprocess
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

REPO_ROOT = Path(__file__).resolve().parents[2]
TC_DIR = REPO_ROOT / "tcs" / "system_log"
TC_SCRIPT = TC_DIR / "tc_system_log.sh"

BASE_DIR = Path(__file__).resolve().parent
RUNS_DIR = BASE_DIR / "runs"
STATUS_FILE = BASE_DIR / "latest_status.json"
STATIC_DIR = BASE_DIR / "static"
RUNS_DIR.mkdir(exist_ok=True)


def _load_config() -> dict:
    """레포 루트의 config.env(KEY=VALUE)를 읽는다. 없으면 빈 dict — 호출부에서 기본값 사용."""
    config_path = REPO_ROOT / "config.env"
    if not config_path.exists():
        return {}
    values = {}
    for line in config_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


_CONFIG = _load_config()

DUT_HOST = _CONFIG.get("DUT_HOST", "192.168.10.25")
SSH_KEY = str(Path(_CONFIG.get("SSH_KEY_PATH", "~/.ssh/emsplus_mass_nopass")).expanduser())
SSH_OPTS = [
    "-i", SSH_KEY,
    "-o", "StrictHostKeyChecking=no",
    "-o", "ConnectTimeout=5",
    "-o", "UserKnownHostsFile=/dev/null",
    # TC04 등 고부하 TC 중 DUT CPU가 거의 100%까지 치솟는 구간이 있어(systemd-cat
    # 대량 injection), keepalive를 너무 타이트하게 잡으면 세션이 살아있는데도
    # false-negative 로 끊길 수 있다 (실측: feedback_serial_vs_ssh_polling 참고).
    # interval*countmax 로 최대 무응답 허용 시간을 넉넉히 잡는다.
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=80",
]
REMOTE_SCRIPT = "/tmp/tc_system_log.sh"

# tc_system_log.sh 가 실제로 지원하는 --flag 목록 (스크립트 case 문 기준).
# TC01/02/03/06/07/08/09 는 단독 flag가 없어 기본(default) 실행에만 포함됨.
CATALOG = [
    {"id": "default", "label": "전체 실행 (TC01,02,03,04,05,06,07,08,09,12,13)", "flag": None,
     "timeout": 1800, "reboot": False,
     "note": "기본 회귀 세트. TC04 대기 포함, 수 분 소요"},
    {"id": "tc04", "label": "TC04 대용량 journal timeout", "flag": "--tc04",
     "timeout": 300, "reboot": False, "note": None},
    {"id": "tc05", "label": "TC05 압축 (TC05-4 단독)", "flag": "--tc05",
     "timeout": 120, "reboot": False, "note": "TC05-1~3 은 setup 필요 — 기본 실행에서만 확인됨"},
    {"id": "tc10-pre", "label": "TC10-pre (reboot 발생)", "flag": "--tc10-pre",
     "timeout": 120, "reboot": True, "note": "실행 후 DUT 재부팅. 부팅 완료 후 TC10-post 실행 필요"},
    {"id": "tc10-post", "label": "TC10-post (reboot 후)", "flag": "--tc10-post",
     "timeout": 120, "reboot": False, "note": "TC10-pre 먼저 실행하고 DUT 재부팅 완료 후 사용"},
    {"id": "tc11", "label": "TC11 nmon 업로드 happy path", "flag": "--tc11",
     "timeout": 420, "reboot": False, "note": "BlobUploadDirector 5분+30초 대기"},
    {"id": "tc12", "label": "TC12 nmon retention", "flag": "--tc12",
     "timeout": 120, "reboot": False, "note": None},
    {"id": "tc13", "label": "TC13 nmon no-op", "flag": "--tc13",
     "timeout": 120, "reboot": False, "note": None},
    {"id": "tc-nmon", "label": "TC11+12+13 일괄 (nmon)", "flag": "--tc-nmon",
     "timeout": 420, "reboot": False, "note": None},
    {"id": "tc14", "label": "TC14 RTC 동일 시작 병합", "flag": "--tc14",
     "timeout": 180, "reboot": False, "note": "system_log 프로세스 kill 수반"},
]
CATALOG_MAP = {c["id"]: c for c in CATALOG}

app = FastAPI(title="system_log TC Dashboard")

current_run = {"run_id": None}


class RunRequest(BaseModel):
    tc_id: str


def ssh_argv(remote_cmd: str):
    return ["ssh", *SSH_OPTS, f"root@{DUT_HOST}", remote_cmd]


def _write_meta(run_dir: Path, meta: dict):
    (run_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))


ASSERT_RE = re.compile(r"^\[(PASS|FAIL)\]\s+TC(\d+)-(\d+):\s*(.*)$")
REASON_RE = re.compile(r"^\[REASON\]\s*(.*)$")


def _parse_results(text: str):
    pass_n = fail_n = 0
    cases = []
    for line in text.splitlines():
        stripped = line.strip()
        m = ASSERT_RE.match(stripped)
        if m:
            status, tc_no, sub_no, desc = m.groups()
            if status == "PASS":
                pass_n += 1
            else:
                fail_n += 1
            cases.append({
                "tc": f"TC{tc_no}", "case": f"TC{tc_no}-{sub_no}",
                "status": status, "desc": desc, "reason": "",
            })
            continue
        rm = REASON_RE.match(stripped)
        if rm and cases:
            cases[-1]["reason"] = rm.group(1)
    return pass_n, fail_n, cases


def _update_latest_status(run_id: str, meta: dict, cases: list):
    status_map = {}
    if STATUS_FILE.exists():
        status_map = json.loads(STATUS_FILE.read_text())
    for c in cases:
        status_map[c["case"]] = {
            "status": c["status"],
            "desc": c["desc"],
            "reason": c.get("reason", ""),
            "tc": c["tc"],
            "run_id": run_id,
            "at": meta["finished_at"],
        }
    STATUS_FILE.write_text(json.dumps(status_map, ensure_ascii=False, indent=2))


async def run_tc(run_id: str, entry: dict):
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "output.log"
    meta = {
        "run_id": run_id,
        "tc_id": entry["id"],
        "label": entry["label"],
        "flag": entry["flag"],
        "started_at": datetime.now().isoformat(timespec="seconds"),
        "finished_at": None,
        "status": "running",
        "pass": 0,
        "fail": 0,
        "exit_code": None,
    }
    _write_meta(run_dir, meta)

    try:
        with open(log_path, "wb") as logf:
            logf.write(f"$ scp tc_system_log.sh -> root@{DUT_HOST}:{REMOTE_SCRIPT}\n".encode())
            logf.flush()
            scp_proc = await asyncio.create_subprocess_exec(
                "scp", *SSH_OPTS, str(TC_SCRIPT), f"root@{DUT_HOST}:{REMOTE_SCRIPT}",
                stdout=logf, stderr=logf,
            )
            scp_rc = await asyncio.wait_for(scp_proc.wait(), timeout=30)
            if scp_rc != 0:
                raise RuntimeError(f"scp 전송 실패 (exit={scp_rc})")

            chmod_proc = await asyncio.create_subprocess_exec(
                *ssh_argv(f"chmod +x {REMOTE_SCRIPT}"), stdout=logf, stderr=logf,
            )
            await asyncio.wait_for(chmod_proc.wait(), timeout=15)

            flag = entry["flag"] or ""
            remote_cmd = f"{REMOTE_SCRIPT} {flag} 2>&1".strip()
            logf.write(f"\n$ ssh root@{DUT_HOST} '{remote_cmd}'\n\n".encode())
            logf.flush()
            run_proc = await asyncio.create_subprocess_exec(
                *ssh_argv(remote_cmd), stdout=logf, stderr=logf,
            )
            try:
                exit_code = await asyncio.wait_for(run_proc.wait(), timeout=entry["timeout"])
            except asyncio.TimeoutError:
                run_proc.kill()
                await run_proc.wait()
                logf.write(b"\n[DASHBOARD] TIMEOUT - \xed\x94\x84\xeb\xa1\x9c\xec\x84\xb8\xec\x8a\xa4 \xea\xb0\x95\xec\xa0\x9c \xec\xa2\x85\xeb\xa3\x8c\n")
                exit_code = None

        meta["exit_code"] = exit_code
        text = log_path.read_text(errors="replace")
        pass_n, fail_n, cases = _parse_results(text)
        meta["pass"] = pass_n
        meta["fail"] = fail_n
        if entry["reboot"]:
            meta["status"] = "rebooted"
        elif exit_code is None:
            meta["status"] = "timeout"
        elif fail_n > 0:
            meta["status"] = "fail"
        elif exit_code != 0 and pass_n == 0 and fail_n == 0:
            meta["status"] = "error"
        else:
            meta["status"] = "pass"
        meta["finished_at"] = datetime.now().isoformat(timespec="seconds")
        _write_meta(run_dir, meta)
        if cases:
            _update_latest_status(run_id, meta, cases)
    except Exception as e:
        meta["status"] = "error"
        meta["finished_at"] = datetime.now().isoformat(timespec="seconds")
        _write_meta(run_dir, meta)
        with open(log_path, "ab") as logf:
            logf.write(f"\n[DASHBOARD ERROR] {e}\n".encode())
    finally:
        current_run["run_id"] = None


SUMMARY_RE = re.compile(r"PASS=(\d+)\s+FAIL=(\d+)")


def _reconcile_stale_runs():
    """서버 재시작/크래시로 완료 처리를 못 받은 run을 로그 기준으로 정정.

    run_tc()는 프로세스가 끝나야 meta.json에 finished_at/status를 쓰는데,
    서버 프로세스 자체가 죽으면(재시작 등) 그 전에 meta가 running으로 남는다.
    output.log 에 최종 요약 라인이 있으면 실제로는 끝난 것이므로 그 결과로
    채우고, 없으면 진짜 중단된 것이므로 interrupted 로 표시한다.
    """
    if not RUNS_DIR.exists():
        return
    for run_dir in RUNS_DIR.iterdir():
        meta_path = run_dir / "meta.json"
        if not meta_path.exists():
            continue
        meta = json.loads(meta_path.read_text())
        if meta.get("status") != "running":
            continue
        log_path = run_dir / "output.log"
        text = log_path.read_text(errors="replace") if log_path.exists() else ""
        pass_n, fail_n, cases = _parse_results(text)
        finished_at = (
            datetime.fromtimestamp(log_path.stat().st_mtime).isoformat(timespec="seconds")
            if log_path.exists() else datetime.now().isoformat(timespec="seconds")
        )
        entry = CATALOG_MAP.get(meta["tc_id"], {})
        meta["pass"], meta["fail"] = pass_n, fail_n
        meta["finished_at"] = finished_at
        if SUMMARY_RE.search(text):
            meta["exit_code"] = 0 if fail_n == 0 else 1
            meta["status"] = "rebooted" if entry.get("reboot") else ("fail" if fail_n > 0 else "pass")
            if cases:
                _update_latest_status(meta["run_id"], meta, cases)
        else:
            meta["status"] = "interrupted"
        _write_meta(run_dir, meta)


@app.on_event("startup")
def _on_startup():
    current_run["run_id"] = None
    _reconcile_stale_runs()


@app.get("/api/tcs")
def api_tcs():
    return CATALOG


@app.get("/api/status")
def api_status():
    if STATUS_FILE.exists():
        return json.loads(STATUS_FILE.read_text())
    return {}


@app.get("/api/ping")
def api_ping():
    try:
        rc = subprocess.run(
            ["ping", "-c", "1", "-W", "1", DUT_HOST],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode
        return {"reachable": rc == 0, "host": DUT_HOST}
    except Exception:
        return {"reachable": False, "host": DUT_HOST}


@app.get("/api/runs")
def api_runs():
    runs = []
    for d in sorted(RUNS_DIR.iterdir(), reverse=True):
        meta_path = d / "meta.json"
        if meta_path.exists():
            runs.append(json.loads(meta_path.read_text()))
    return runs[:50]


@app.get("/api/runs/{run_id}")
def api_run_detail(run_id: str):
    run_dir = RUNS_DIR / run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        raise HTTPException(404, "run not found")
    meta = json.loads(meta_path.read_text())
    log_path = run_dir / "output.log"
    log_text = log_path.read_text(errors="replace") if log_path.exists() else ""
    return {"meta": meta, "log": log_text}


@app.post("/api/run")
async def api_run(req: RunRequest):
    if req.tc_id not in CATALOG_MAP:
        raise HTTPException(400, "unknown tc_id")
    if current_run["run_id"] is not None:
        raise HTTPException(409, f"이미 실행 중인 run: {current_run['run_id']}")
    run_id = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{req.tc_id}"
    current_run["run_id"] = run_id
    asyncio.create_task(run_tc(run_id, CATALOG_MAP[req.tc_id]))
    return {"run_id": run_id}


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    return (STATIC_DIR / "index.html").read_text()
