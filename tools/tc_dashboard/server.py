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
from io import BytesIO
from pathlib import Path

import markdown as md_lib
from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from xhtml2pdf import pisa

# xhtml2pdf(reportlab)는 한글 글꼴이 기본 내장되어 있지 않아 별도 등록이 필요함.
# WSL2 환경 기준 Windows 기본 한글 글꼴(맑은 고딕) 경로를 우선 사용.
KOREAN_FONT_CANDIDATES = [
    "/mnt/c/Windows/Fonts/malgun.ttf",
    str(Path.home() / ".local/share/fonts/NanumMyeongjo-Regular.ttf"),
]

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


TC_SECTION_RE = re.compile(r"^(?:===|---)\s*(TC\d+)(?:-\d+)?\s*[:：].*?(?:===|---)$")


def _split_log_by_tc(text: str) -> dict:
    """output.log를 `=== TCxx: ... ===` / `--- TCxx-n: ... ---` 헤더 기준으로 TC별 원본 블록으로 나눈다.

    tc_system_log.sh 가 각 TC 실행 전 이런 구분선을 찍어주는 것을 그대로 활용 —
    tc_system_log_result.md 의 "근거 (tc_run.out)" 인용과 같은 방식.
    """
    blocks: dict = {}
    current_tc = None
    current_lines: list = []
    for line in text.splitlines():
        m = TC_SECTION_RE.match(line.strip())
        if m:
            if current_tc:
                blocks[current_tc] = "\n".join(current_lines).strip()
            current_tc = m.group(1)
            current_lines = [line]
        elif current_tc:
            current_lines.append(line)
    if current_tc:
        blocks[current_tc] = "\n".join(current_lines).strip()
    return blocks


def _generate_result_md(run_id: str, meta: dict, cases: list, log_text: str, sl_journal_text: str = "") -> str:
    """tcs/system_log/tc_system_log_result.md 형식을 본떠 run 단위 결과 보고서를 생성한다."""
    lines = [
        f"# TC 실행 결과 보고서 — {meta.get('label') or meta.get('tc_id', run_id)}",
        "",
        f"**Run ID:** {run_id}",
        f"**실행일시:** {meta.get('started_at', '')} ~ {meta.get('finished_at', '')}",
        f"**DUT:** {DUT_HOST} (qcells-emsplus, AC Gen2, aarch64)",
        f"**스크립트:** tc_system_log.sh",
        "",
        f"**총 결과: PASS={meta.get('pass', 0)} / FAIL={meta.get('fail', 0)} / {len(cases)}기준**",
        "",
        "| TC | 기준 | 결과 |",
        "|----|------|------|",
    ]
    for c in cases:
        desc = c.get("desc", "").replace("|", "\\|")
        lines.append(f"| {c['case']} ({desc}) | | **{c['status']}** |")

    grouped: dict = {}
    for c in cases:
        grouped.setdefault(c["tc"], []).append(c)

    tc_blocks = _split_log_by_tc(log_text)

    lines += ["", "---"]
    for tc, items in grouped.items():
        lines += ["", f"## {tc}", "", "| 기준 ID | 결과 |", "|---------|------|"]
        for c in items:
            desc = c.get("desc", "").replace("|", "\\|")
            lines.append(f"| {c['case']}: {desc} | **{c['status']}** |")
            if c.get("reason"):
                lines.append(f"| ↳ 사유 | {c['reason'].replace('|', chr(92) + '|')} |")
        block = tc_blocks.get(tc)
        if block:
            lines += ["", "**근거 (output.log):**", "```", block, "```"]
        if sl_journal_text.strip():
            lines += ["", "**근거 (journald — [SL]/[SM] 애플리케이션 로그):**", "```", sl_journal_text.strip(), "```"]
    lines.append("")
    return "\n".join(lines)


def _korean_font_path():
    for p in KOREAN_FONT_CANDIDATES:
        if Path(p).exists():
            return p
    return None


def _markdown_to_pdf(md_text: str) -> bytes:
    body_html = md_lib.markdown(md_text, extensions=["tables", "fenced_code"])
    font_path = _korean_font_path()
    font_css = (
        f'@font-face {{ font-family: "Korean"; src: url("{font_path}"); }}\n'
        'body, table, th, td, h1, h2, pre, code { font-family: "Korean"; }\n'
        if font_path else ""
    )
    html = f"""<html><head><meta charset="utf-8"><style>
{font_css}
body {{ font-size: 10px; }}
table {{ border-collapse: collapse; width: 100%; margin: 8px 0; }}
th, td {{ border: 1px solid #999; padding: 4px 6px; text-align: left; }}
h1 {{ font-size: 16px; }} h2 {{ font-size: 13px; }}
pre {{ font-size: 8px; white-space: pre-wrap; background: #f2f2f2; border: 1px solid #ccc; padding: 6px; }}
</style></head><body>{body_html}</body></html>"""
    buf = BytesIO()
    pisa.CreatePDF(html, dest=buf)
    return buf.getvalue()


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


SL_TAG_RE = re.compile(r"\[SL\]|\[SM\]")


async def _start_journal_capture():
    """DUT의 [SL]/[SM] 애플리케이션 로그를 별도 SSH 세션으로 실시간 캡처 시작.

    tc-run 스킬이 시리얼에서 하는 '백그라운드 journalctl -f capture' 패턴을
    SSH 세션으로 재현한 것 — 실패해도 본 TC 실행에는 영향 주지 않는다(best-effort).
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            *ssh_argv("journalctl -u docker-loader -f -o short-iso --no-pager"),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
    except Exception:
        return None, [], None

    lines: list = []

    async def _collect():
        try:
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                lines.append(line.decode(errors="replace"))
        except Exception:
            pass

    task = asyncio.create_task(_collect())
    await asyncio.sleep(0.5)  # journalctl -f 가 구독을 시작할 시간 확보
    return proc, lines, task


async def _stop_journal_capture(proc, lines: list, task, run_dir: Path):
    if proc is None:
        return
    try:
        await asyncio.sleep(1.5)  # DUT journald 기록 지연분까지 확보
        proc.kill()
        await asyncio.wait_for(proc.wait(), timeout=5)
    except Exception:
        pass
    if task:
        task.cancel()
    sl_lines = [l for l in lines if SL_TAG_RE.search(l)]
    if sl_lines:
        (run_dir / "sl_journal.log").write_text("".join(sl_lines))


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

            journal_proc, journal_lines, collector_task = await _start_journal_capture()

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

            await _stop_journal_capture(journal_proc, journal_lines, collector_task, run_dir)

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
    _, _, cases = _parse_results(log_text)
    return {"meta": meta, "log": log_text, "cases": cases}


def _load_finished_run(run_id: str):
    run_dir = RUNS_DIR / run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        raise HTTPException(404, "run not found")
    meta = json.loads(meta_path.read_text())
    if meta.get("status") == "running":
        raise HTTPException(409, "run이 아직 진행 중")
    log_path = run_dir / "output.log"
    log_text = log_path.read_text(errors="replace") if log_path.exists() else ""
    _, _, cases = _parse_results(log_text)
    sl_journal_path = run_dir / "sl_journal.log"
    sl_journal_text = sl_journal_path.read_text(errors="replace") if sl_journal_path.exists() else ""
    return meta, cases, log_text, sl_journal_text


@app.get("/api/runs/{run_id}/result.pdf")
def api_run_result_pdf(run_id: str):
    meta, cases, log_text, sl_journal_text = _load_finished_run(run_id)
    md_content = _generate_result_md(run_id, meta, cases, log_text, sl_journal_text)
    pdf_bytes = _markdown_to_pdf(md_content)
    filename = f"tc_system_log_result_{run_id}.pdf"
    return Response(
        pdf_bytes, media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


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
