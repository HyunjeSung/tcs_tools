#!/usr/bin/env python3
"""system_log TC 웹 대시보드 백엔드.

DUT(config.env의 DUT_HOST)에 SSH로 tc_system_log.sh 를 transfer+실행하고,
결과를 파싱해 현황판/실행이력으로 제공한다.
"""
import asyncio
import json
import re
import shutil
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

MAX_RUNS = 50  # 이 개수를 넘는 오래된 run은 _prune_old_runs()가 디스크에서 삭제한다


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

SERIAL_COM_PORT = _CONFIG.get("SERIAL_COM_PORT", "COM6")
SERIAL_RUN_PS1 = BASE_DIR / "serial_run.ps1"
# serial_run.ps1이 시리얼 원문을 실시간으로 append하는 Windows 쪽 파일.
# WIN_TEMP_LOG_PATH(config.env)와 같은 디렉토리를 쓰되 tc-run 스킬의 로그(tc_console.log)와
# 겹치지 않도록 대시보드 전용 파일명을 쓴다.
_WIN_TEMP_LOG_PATH = _CONFIG.get("WIN_TEMP_LOG_PATH", r"C:\Users\hyunje.sung\AppData\Local\Temp\tc_console.log")
SERIAL_LIVE_LOG_WIN = _WIN_TEMP_LOG_PATH.rsplit("\\", 1)[0] + "\\tc_dashboard_serial.log"


def _win_path(path: Path) -> str:
    return subprocess.run(
        ["wslpath", "-w", str(path)], capture_output=True, text=True, check=True,
    ).stdout.strip()


def _wsl_path(win_path: str) -> Path:
    return Path(subprocess.run(
        ["wslpath", "-u", win_path], capture_output=True, text=True, check=True,
    ).stdout.strip())

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
    channel: str = "ssh"


def ssh_argv(remote_cmd: str):
    return ["ssh", *SSH_OPTS, f"root@{DUT_HOST}", remote_cmd]


def _write_meta(run_dir: Path, meta: dict):
    (run_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))


ASSERT_RE = re.compile(r"^\[(PASS|FAIL)\]\s+TC(\d+)-(\d+):\s*(.*)$")
REASON_RE = re.compile(r"^\[REASON\]\s*(.*)$")


def _parse_results(text: str):
    # case_id로 dedup — 시리얼 채널은 tee로 살린 라이브 스트림과 최종 base64 디코딩본에
    # 같은 [PASS]/[FAIL] 블록이 두 번 나타날 수 있어(_tail_serial_log 참고), 같은 case가
    # 중복 매칭되면 나중 것(더 뒤에 오는 최종 디코딩본, 항상 깨끗함)으로 덮어써 한 번만 센다.
    cases_map: dict = {}
    order: list = []
    for line in text.splitlines():
        stripped = line.strip()
        m = ASSERT_RE.match(stripped)
        if m:
            status, tc_no, sub_no, desc = m.groups()
            case_id = f"TC{tc_no}-{sub_no}"
            if case_id not in cases_map:
                order.append(case_id)
            cases_map[case_id] = {
                "tc": f"TC{tc_no}", "case": case_id,
                "status": status, "desc": desc, "reason": "",
            }
            continue
        rm = REASON_RE.match(stripped)
        if rm and order:
            cases_map[order[-1]]["reason"] = rm.group(1)
    cases = [cases_map[cid] for cid in order]
    pass_n = sum(1 for c in cases if c["status"] == "PASS")
    fail_n = sum(1 for c in cases if c["status"] == "FAIL")
    return pass_n, fail_n, cases


TC_SECTION_RE = re.compile(r"^(?:===|---)\s*(TC\d+)(?:-\d+)?\s*[:：].*?(?:===|---)$")
JOURNAL_TOKEN_RE = re.compile(r"[\w./\-]*\d[\w./\-]*\.(?:log(?:\.xz)?(?:\.meta)?|xz|meta|nmon(?:\.meta)?)\b")
JOURNAL_EXCERPT_MAX_LINES = 8


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


def _filter_journal_for_tc(tc_block_text: str, sl_journal_text: str) -> str:
    """전체 journald 캡처에서 해당 TC의 output.log 블록에 등장하는 실제 파일명(타임스탬프 포함,
    즉 숫자를 포함하는 토큰)과 겹치는 라인만 추려 근거를 최소화한다 (default 실행처럼 여러 TC가
    캡처 하나를 공유할 때 TC 무관 로그까지 전부 딸려오는 것을 방지).

    tc-dev 스킬의 "evidence_full.log 에 실제로 있는 라인만 인용 — 추측/일반화 X" 원칙에 따라,
    TC04처럼 output.log에 ".xz" 같은 확장자만 언급하고 실제 파일명을 남기지 않는 TC는
    토큰이 안 잡혀 근거 없음(빈 문자열)으로 처리된다 — 원본 tc_system_log_result.md 에서도
    TC04는 journald 근거 섹션이 없다.
    """
    tokens = set(JOURNAL_TOKEN_RE.findall(tc_block_text))
    if not tokens:
        return ""
    matched = []
    for line in sl_journal_text.splitlines():
        if any(tok in line for tok in tokens):
            matched.append(line)
            if len(matched) >= JOURNAL_EXCERPT_MAX_LINES:
                break
    return "\n".join(matched)


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
        "| TC | 결과 |",
        "|----|------|",
    ]
    for c in cases:
        desc = c.get("desc", "").replace("|", "\\|")
        lines.append(f"| {c['case']} ({desc}) | **{c['status']}** |")

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
            journal_excerpt = _filter_journal_for_tc(block or "", sl_journal_text)
            if journal_excerpt:
                lines += ["", "**근거 (journald — [SL]/[SM] 애플리케이션 로그):**", "```", journal_excerpt, "```"]
    lines.append("")
    return "\n".join(lines)


def _korean_font_path():
    for p in KOREAN_FONT_CANDIDATES:
        if Path(p).exists():
            return p
    return None


PRE_CODE_RE = re.compile(r"(<pre><code>)(.*?)(</code></pre>)", re.DOTALL)
PRE_LEADING_SPACES_RE = re.compile(r"^( +)", re.MULTILINE)


def _fix_pre_linebreaks(html: str) -> str:
    """xhtml2pdf는 <pre>의 white-space:pre-wrap을 지키지 않고 줄바꿈/들여쓰기를 뭉개버리므로,
    <pre><code> 블록 안에서만 개행을 <br/>로, 앞 공백을 &nbsp;로 치환해 원본 로그 줄 구조를 보존한다.
    """
    def _replace(m):
        body = PRE_LEADING_SPACES_RE.sub(lambda sm: "&nbsp;" * len(sm.group(1)), m.group(2))
        body = body.replace("\n", "<br/>\n")
        return m.group(1) + body + m.group(3)
    return PRE_CODE_RE.sub(_replace, html)


def _markdown_to_pdf(md_text: str) -> bytes:
    body_html = md_lib.markdown(md_text, extensions=["tables", "fenced_code"])
    body_html = _fix_pre_linebreaks(body_html)
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


def _merge_case_status(status_map: dict, run_id: str, meta: dict, cases: list):
    for c in cases:
        status_map[c["case"]] = {
            "status": c["status"],
            "desc": c["desc"],
            "reason": c.get("reason", ""),
            "tc": c["tc"],
            "run_id": run_id,
            "at": meta["finished_at"],
        }


def _update_latest_status(run_id: str, meta: dict, cases: list):
    status_map = {}
    if STATUS_FILE.exists():
        status_map = json.loads(STATUS_FILE.read_text())
    _merge_case_status(status_map, run_id, meta, cases)
    STATUS_FILE.write_text(json.dumps(status_map, ensure_ascii=False, indent=2))


def _prune_old_runs(keep: int = MAX_RUNS):
    """runs/ 아래 run_id(=YYYYMMDD_HHMMSS_... 접두라 이름순=시간순) 기준 최신 keep개만 남기고 나머지는 삭제."""
    run_dirs = sorted((d for d in RUNS_DIR.iterdir() if d.is_dir()), key=lambda d: d.name, reverse=True)
    for stale_dir in run_dirs[keep:]:
        shutil.rmtree(stale_dir, ignore_errors=True)


def _rebuild_latest_status():
    """latest_status.json을 실제 runs/ 에 남아있는 run들만 기준으로 처음부터 다시 만든다.

    _update_latest_status()는 누적(merge)만 하므로 _prune_old_runs()로 오래된 run 디렉토리를
    지워도 그 run이 마지막으로 채운 케이스 항목은 그대로 남는다 — 존재하지 않는 run_id를
    가리키는 stale 항목이 생기지 않도록, 남은 run들을 시간순으로 재생해 상태를 재구성한다.
    """
    status_map: dict = {}
    run_dirs = sorted((d for d in RUNS_DIR.iterdir() if d.is_dir()), key=lambda d: d.name)
    for run_dir in run_dirs:
        meta_path = run_dir / "meta.json"
        if not meta_path.exists():
            continue
        meta = json.loads(meta_path.read_text())
        if meta.get("status") == "running" or not meta.get("finished_at"):
            continue
        log_path = run_dir / "output.log"
        if not log_path.exists():
            continue
        _, _, cases = _parse_results(log_path.read_text(errors="replace"))
        if cases:
            _merge_case_status(status_map, run_dir.name, meta, cases)
    STATUS_FILE.write_text(json.dumps(status_map, ensure_ascii=False, indent=2))


SL_TAG_RE = re.compile(r"\[SL\]|\[SM\]")


async def _start_journal_capture():
    """DUT의 [SL]/[SM] 애플리케이션 로그를 별도 SSH 세션으로 실시간 캡처 시작.
    캡처 자체는 둘 다 남기고, 보고서에 실릴 때는 _filter_journal_for_tc가 TC별로
    관련 있는 라인만(최대 JOURNAL_EXCERPT_MAX_LINES줄) 추려서 방대해지지 않게 한다.

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


async def _run_ssh(entry: dict, log_path: Path, run_dir: Path) -> "int | None":
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
        remote_cmd = f"sh {REMOTE_SCRIPT} {flag} 2>&1".strip()
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
    return exit_code


_SERIAL_NOISE_LINE_RE = re.compile(r"docker-loader\[")
_SERIAL_PROMPT_PREFIX_RE = re.compile(r"^(?:P>\s*)+")
_SERIAL_DASH_MARKERS = {"M_RM_DONE", "M_DECODE_DONE", "M_DASH_RUN_END"}


def _looks_corrupted(line: str) -> bool:
    """시리얼 라인 노이즈로 바이트가 깨지면 errors="replace"가 U+FFFD로 채운다.
    한 줄이 그런 깨진 문자로 대부분 차 있으면(개행 없는 수천자짜리 덩어리가 되기도 함)
    브라우저 렌더링만 무거워지고 정보도 없으므로 통째로 버린다.
    """
    if len(line) < 20:
        return False
    bad = line.count("�")
    return bad > 5 and bad / len(line) > 0.1


def _filter_serial_noise(text: str, in_dump: bool) -> "tuple[str, bool]":
    """시리얼 콘솔은 DUT의 docker-loader 저널(`[DM]/[MCU]/...`)이 우리 명령 입출력과 무관하게 계속
    끼어들고, echo 꺼도 프롬프트(`P> `)/`^C` 에코가 섞인다. tee로 살린 TC 스크립트 자체 출력만
    골라내 SSH 채널과 비슷하게 보이도록, 그런 잡음 줄과 대시보드 내부 프로토콜 마커
    (M_RM_DONE 등, M_DUMPBEG~M_DUMPEND 사이 base64 덤프 — 어차피 최종 디코딩본이 뒤이어 깨끗하게
    나옴)는 버린다. base64 덤프가 여러 tail 주기(1초)에 걸쳐 나뉠 수 있어 in_dump 상태를 호출 간
    이어받는다.
    """
    kept = []
    for line in text.splitlines():
        # 마커/노이즈 판별 전에 프롬프트 접두부터 벗긴다 — "P> M_DUMPBEG"처럼 마커 앞에
        # 프롬프트가 그대로 붙어 나오는 경우가 흔해서, 벗기기 전에 startswith를 하면 못 잡는다.
        line = _SERIAL_PROMPT_PREFIX_RE.sub("", line)
        s = line.strip()
        if s.startswith("M_DUMPBEG"):
            in_dump = True
            continue
        if s.startswith("M_DUMPEND"):
            in_dump = False
            continue
        if in_dump:
            continue
        if s in _SERIAL_DASH_MARKERS:
            continue
        if _SERIAL_NOISE_LINE_RE.search(line):
            continue
        if not line.strip() or line.strip() == "^C":
            continue
        if _looks_corrupted(line):
            continue
        kept.append(line)
    filtered = ("\n".join(kept) + "\n") if kept else ""
    return filtered, in_dump


async def _tail_serial_log(wsl_log_path: Path, start_offset: int, log_path: Path, stop_event: asyncio.Event):
    """serial_run.ps1이 Windows 로컬 디스크(SERIAL_LIVE_LOG_WIN)에 실시간으로 append하는 시리얼 원문을
    1초 간격으로 tail해, 잡음을 걸러낸 뒤 output.log에 이어붙인다.

    쓰기(시리얼 pump)는 여전히 Windows 로컬 디스크로만 가서 타이밍에 영향 없고, 읽기(tail)만
    WSL의 /mnt/c 브릿지를 거친다 — 쓰기 경로를 WSL 쪽으로 바꾸면 pump 주기(80ms)마다 9P 왕복이
    붙어 시리얼 타이밍이 깨질 수 있어 피한다. 그 파일은 run 간 공유·누적(append-only, 안 지워짐)
    이므로 이번 run 시작 시점의 크기(start_offset) 이후분만 읽는다.
    """
    offset = start_offset
    in_dump = False
    pending = ""  # 청크 경계에서 잘린 미완성 줄 — 다음 주기에 이어붙여야 노이즈 필터가 온전한 줄로 판단 가능

    def _read_new() -> bytes:
        if not wsl_log_path.exists():
            return b""
        size = wsl_log_path.stat().st_size
        if size <= offset:
            return b""
        with open(wsl_log_path, "rb") as f:
            f.seek(offset)
            return f.read()

    def _flush(text: str):
        nonlocal in_dump
        filtered, in_dump = _filter_serial_noise(text, in_dump)
        if filtered:
            try:
                with open(log_path, "ab") as f:
                    f.write(filtered.encode("utf-8"))
            except Exception:
                pass

    loop = asyncio.get_event_loop()
    while True:
        await asyncio.sleep(1)
        try:
            # asyncio.to_thread()는 3.9+ 전용이라(이 venv는 3.8) run_in_executor로 대체
            chunk = await loop.run_in_executor(None, _read_new)
        except Exception:
            chunk = b""
        if chunk:
            offset += len(chunk)
            pending += chunk.decode("utf-8", errors="replace")
            if "\n" in pending:
                complete, _, pending = pending.rpartition("\n")
                _flush(complete + "\n")
        if stop_event.is_set():
            if pending:
                _flush(pending)
                pending = ""
            break


async def _run_serial(entry: dict, log_path: Path) -> "int | None":
    """COM 포트로 transfer+실행. SSH 를 전혀 쓰지 않으므로 SSH lockout 상태에서도 동작한다
    (journal capture 등 SSH 기반 부가 기능은 지원하지 않음)."""
    flag = entry["flag"] or ""
    argv = [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", _win_path(SERIAL_RUN_PS1),
        "-ComPort", SERIAL_COM_PORT,
        "-ScriptPath", _win_path(TC_SCRIPT),
        "-Flag", flag,
        "-TimeoutMs", str(entry["timeout"] * 1000),
        "-LogFile", SERIAL_LIVE_LOG_WIN,
    ]

    tail_task = None
    stop_tail = asyncio.Event()
    try:
        wsl_live_log = _wsl_path(SERIAL_LIVE_LOG_WIN)
        start_offset = wsl_live_log.stat().st_size if wsl_live_log.exists() else 0
        tail_task = asyncio.create_task(_tail_serial_log(wsl_live_log, start_offset, log_path, stop_tail))
    except Exception:
        tail_task = None  # best-effort — 실시간 tail 실패해도 최종 결과 수신엔 영향 없음

    # "ab"(O_APPEND) 필수 — 자식 프로세스가 이 fd를 물려받아 stdout으로 쓰는 것과
    # _tail_serial_log()가 별도 fd로 append하는 게 동시에 일어나므로, O_APPEND 없이 "wb"로 열면
    # 둘 중 하나가 캐시된 오프셋으로 써서 상대방이 방금 append한 내용을 덮어쓸 수 있다.
    with open(log_path, "ab") as logf:
        logf.write(f"$ powershell.exe serial_run.ps1 -ComPort {SERIAL_COM_PORT} -Flag '{flag}' (SSH 미사용)\n\n".encode())
        logf.flush()
        proc = await asyncio.create_subprocess_exec(*argv, stdout=logf, stderr=logf)
        try:
            await asyncio.wait_for(proc.wait(), timeout=entry["timeout"] + 90)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            logf.write(b"\n[DASHBOARD] TIMEOUT - \xed\x94\x84\xeb\xa1\x9c\xec\x84\xb8\xec\x8a\xa4 \xea\xb0\x95\xec\xa0\x9c \xec\xa2\x85\xeb\xa3\x8c\n")

    if tail_task:
        stop_tail.set()
        try:
            await asyncio.wait_for(tail_task, timeout=3)
        except (asyncio.TimeoutError, Exception):
            tail_task.cancel()

    text = log_path.read_text(errors="replace")
    if "SERIAL_RUN_OK=True" in text:
        return 0
    if "SERIAL_RUN_OK=False" in text:
        return None
    return None


async def run_tc(run_id: str, entry: dict, channel: str = "ssh"):
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "output.log"
    meta = {
        "run_id": run_id,
        "tc_id": entry["id"],
        "label": entry["label"],
        "flag": entry["flag"],
        "channel": channel,
        "started_at": datetime.now().isoformat(timespec="seconds"),
        "finished_at": None,
        "status": "running",
        "pass": 0,
        "fail": 0,
        "exit_code": None,
    }
    _write_meta(run_dir, meta)

    try:
        if channel == "serial":
            exit_code = await _run_serial(entry, log_path)
        else:
            exit_code = await _run_ssh(entry, log_path, run_dir)

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
        elif pass_n == 0:
            # exit_code가 0이어도(예: 시리얼 결과 dump가 노이즈로 깨진 경우) 파싱된 케이스가
            # 하나도 없으면 "결과 없음"이지 "pass"가 아니다.
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
        _prune_old_runs()
        _rebuild_latest_status()


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
    _prune_old_runs()
    _rebuild_latest_status()


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
    # SSH(22번 포트) 연결 시도는 절대 여기서 하지 않는다 — DUT는 SSH 연결 시도가 3회 이상
    # 실패하면 리부트 전까지 lockout 되므로, 실제 TC 실행(run_tc) 외에는 SSH를 건드리지 않는다.
    # 이 헬스체크는 ICMP ping만으로 DUT 전원/네트워크 생존 여부만 확인한다 (SSH 가능 여부 보장 아님).
    ping_rc = subprocess.run(
        ["ping", "-c", "1", "-W", "1", DUT_HOST],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode
    return {"reachable": ping_rc == 0, "host": DUT_HOST}


@app.get("/api/runs")
def api_runs(page: int = 1, page_size: int = 10):
    runs = []
    for d in sorted(RUNS_DIR.iterdir(), reverse=True):
        meta_path = d / "meta.json"
        if meta_path.exists():
            runs.append(json.loads(meta_path.read_text()))
    total = len(runs)
    page = max(1, page)
    start = (page - 1) * page_size
    return {
        "runs": runs[start:start + page_size],
        "total": total,
        "page": page,
        "page_size": page_size,
    }


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
    if req.channel not in ("ssh", "serial"):
        raise HTTPException(400, "unknown channel")
    if current_run["run_id"] is not None:
        raise HTTPException(409, f"이미 실행 중인 run: {current_run['run_id']}")
    run_id = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{req.tc_id}"
    current_run["run_id"] = run_id
    asyncio.create_task(run_tc(run_id, CATALOG_MAP[req.tc_id], req.channel))
    return {"run_id": run_id}


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    return (STATIC_DIR / "index.html").read_text()
