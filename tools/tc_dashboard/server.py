#!/usr/bin/env python3
"""AC Gen2 EMS TC 웹 대시보드 백엔드.

DUT(config.env의 DUT_HOST)에 SSH로 tc_<app>.sh 를 transfer+실행하고,
결과를 파싱해 현황판/실행이력으로 제공한다. 앱(system_log, device_log, ...)별로
스크립트/실행이력/현황판을 분리해서 관리한다 — APPS 딕셔너리에 새 앱을 등록하면
프론트엔드 사이드바에 자동으로 나타난다.
"""
import asyncio
import json
import re
import shutil
import subprocess
from datetime import datetime
from io import BytesIO
from pathlib import Path
from typing import Callable, List, Optional

import markdown as md_lib
from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from xhtml2pdf import pisa

# 앱별 카탈로그(버튼 목록)/선택 실행 타임아웃은 방대해지므로 apps/<app_id>.py로 분리했다 —
# 새 앱을 추가하려면 apps/<name>.py를 만들고 아래 APP_MODULES에 등록하면 된다.
from apps import (
    system_log, device_log, update_monitor, sys_manager, db_manager,
    device_manager, azure_connector, edge_runtime, web_interface, energy_monitor,
)

# xhtml2pdf(reportlab)는 한글 글꼴이 기본 내장되어 있지 않아 별도 등록이 필요함.
# WSL2 환경 기준 Windows 기본 한글 글꼴(맑은 고딕) 경로를 우선 사용.
KOREAN_FONT_CANDIDATES = [
    "/mnt/c/Windows/Fonts/malgun.ttf",
    str(Path.home() / ".local/share/fonts/NanumMyeongjo-Regular.ttf"),
]

REPO_ROOT = Path(__file__).resolve().parents[2]
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

MAX_RUNS = 50  # 앱별로 이 개수를 넘는 오래된 run은 _prune_old_runs()가 디스크에서 삭제한다


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
# DUT가 SSH 연결을 짧은 간격으로 반복하면(성공/실패 무관) 한동안 새 연결을 거부하는
# 패턴이 관찰됨(연속 실행 시 두 번째 연결부터 timeout, 수 분 뒤 자연 복구) — 매번 새로
# TCP+인증을 맺는 대신 ControlMaster로 한 번 맺은 연결을 계속 재사용해서 이 문제를 우회한다.
# ControlPersist=yes: 마지막 클라이언트(scp/ssh)가 끝나도 마스터 연결은 백그라운드에 계속 살아있음.
SSH_CONTROL_PATH = str(BASE_DIR / "ssh_control.sock")
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
    "-o", "ControlMaster=auto",
    "-o", f"ControlPath={SSH_CONTROL_PATH}",
    "-o", "ControlPersist=yes",
]

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


# ============================================================
# 앱 레지스트리 — 카탈로그/타임아웃 등 앱별 데이터는 apps/<app_id>.py에 있다. 새 앱을
# 추가하려면 apps/<name>.py를 만들고 아래 APP_MODULES에 등록하면 사이드바에 자동으로
# 나타난다.
# ============================================================

# system_log는 기존 배포와 동일한 경로(runs/, latest_status.json)를 그대로 써서 기존
# 실행 이력을 마이그레이션 없이 유지한다(apps/system_log.py의 RUNS_DIRNAME/
# STATUS_FILENAME 참고). 다른 앱은 각자 이름이 붙은 디렉토리/파일을 쓴다.
APP_MODULES = [
    system_log, device_log, update_monitor, sys_manager, db_manager,
    device_manager, azure_connector, edge_runtime, web_interface, energy_monitor,
]


def _register_app(app_id: str, label: str, script_name: str, catalog: list,
                   custom_tc_timeouts: dict, runs_dirname: str, status_filename: str,
                   hidden_entries: Optional[list] = None, reboot_tc_map: Optional[dict] = None) -> dict:
    tc_dir = REPO_ROOT / "tcs" / app_id
    runs_dir = BASE_DIR / runs_dirname
    runs_dir.mkdir(exist_ok=True)
    # hidden_entries는 사이드바 버튼(catalog)에는 안 나오지만 chain_reboot_pairs가
    # id로 조회할 수 있도록 catalog_map에는 포함시킨다.
    catalog_map = {c["id"]: c for c in catalog}
    catalog_map.update({c["id"]: c for c in (hidden_entries or [])})
    return {
        "id": app_id,
        "label": label,
        "tc_script": tc_dir / script_name,
        "remote_script": f"/tmp/{script_name}",
        "catalog": catalog,
        "catalog_map": catalog_map,
        "custom_tc_timeouts": custom_tc_timeouts,
        "custom_tc_order": list(custom_tc_timeouts.keys()),
        "reboot_tc_map": reboot_tc_map or {},
        "runs_dir": runs_dir,
        "status_file": BASE_DIR / status_filename,
    }


APPS = {
    m.ID: _register_app(
        m.ID, m.LABEL, m.SCRIPT_NAME, m.CATALOG, m.CUSTOM_TC_TIMEOUTS,
        runs_dirname=m.RUNS_DIRNAME, status_filename=m.STATUS_FILENAME,
        hidden_entries=getattr(m, "HIDDEN_ENTRIES", None),
        reboot_tc_map=getattr(m, "REBOOT_TC_MAP", None),
    )
    for m in APP_MODULES
}
DEFAULT_APP_ID = "system_log"


def _get_app(app_id: str) -> dict:
    cfg = APPS.get(app_id)
    if cfg is None:
        raise HTTPException(404, f"unknown app: {app_id}")
    return cfg


app = FastAPI(title="AC Gen2 EMS TC Dashboard")

# 물리적으로 DUT가 하나뿐이라 앱이 달라도 SSH/시리얼 채널을 동시에 쓸 수 없다 —
# run 동시성 제한은 앱별이 아니라 전역으로 건다.
current_run = {"run_id": None, "proc": None, "cancelled": False, "case_times": None}


class RunRequest(BaseModel):
    app_id: str = DEFAULT_APP_ID
    tc_id: str
    channel: str = "ssh"
    tc_ids: Optional[List[str]] = None  # tc_id == "custom" 일 때만 사용 — 선택된 TC 목록(예: ["TC01","TC03"])


def ssh_argv(remote_cmd: str):
    return ["ssh", *SSH_OPTS, f"root@{DUT_HOST}", remote_cmd]


def _write_meta(run_dir: Path, meta: dict):
    (run_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))


ASSERT_RE = re.compile(r"^\[(PASS|FAIL|SKIP)\]\s+TC(\d+)-(\d+):\s*(.*)$")
REASON_RE = re.compile(r"^\[REASON\]\s*(.*)$")


EXPECTED_CASE_RE = re.compile(r'assert\s+"(TC\d+-\d+):\s*([^"]*)"')
TC_BANNER_RE = re.compile(r"^===\s*(TC\d+)")
TC_BANNER_DESC_RE = re.compile(r"^===\s*(TC\d+):\s*(.*?)\s*===\s*$")
TC_SUBBANNER_RE = re.compile(r"^-{3}\s*(TC\d+-\d+):\s*(.*?)\s*-{3}$")


def _expected_cases(app_cfg: dict) -> dict:
    """스크립트가 만들어낼 수 있는 모든 sub-case id -> desc (분기 조건 무시하고 전체 스캔).

    사전조건 미충족으로 이번 run에서 assert()가 한 번도 안 불린 sub-case를 찾아내기
    위한 "기대 집합". PASS/FAIL 양쪽 분기에 보통 같은 desc 리터럴이 쓰이므로 어느
    쪽에서 스캔되든 상관없다. `assert "TCxx-${var}: ..."`처럼 sub-id를 쉘 변수로
    동적 생성하는 스크립트(update_monitor TC02, system_log TC04)는 리터럴 매칭이
    안 되어 자동으로 이 집합에서 빠진다 — 오탐(false SKIP)은 없고 그 TC들만
    조용히 이 기능의 적용 대상에서 제외될 뿐이다.
    """
    try:
        text = app_cfg["tc_script"].read_text()
    except Exception:
        return {}
    return dict(EXPECTED_CASE_RE.findall(text))


def _attempted_tc_numbers(text: str) -> set:
    """output.log에서 실행된(배너가 찍힌) TC 번호 집합.

    사전조건이 실패해도 각 TC 함수 맨 앞의 `echo "=== TCxx: ..."` 배너는 무조건
    먼저 실행되므로, 이 집합이 "이번 run의 실행 범위"를 신뢰성 있게 말해준다 —
    `_split_log_by_tc()`가 같은 배너를 다른 목적(journal 필터링)으로 이미
    파싱하는 것과 동일한 신호(TC_SECTION_RE 참고).
    """
    numbers = set()
    for line in text.splitlines():
        m = TC_BANNER_RE.match(line.strip())
        if m:
            numbers.add(m.group(1))
    return numbers


def _pending_case_rows(app_cfg: dict, log_text: str, existing_cases: list) -> list:
    """진행 중인 run에서 배너는 찍혔지만(=시작됨) 아직 assert가 안 불린(=대기중인) sub-case를
    'RUNNING' placeholder row로 만든다 — 결과 현황판에 완료된 case 옆에 '진행중' 애니메이션
    행이 같이 보이다가, 실제 assert가 찍히면 다음 폴링에서 PASS/FAIL/SKIP 행으로 자연히
    대체된다(같은 case id로 재조회되므로 존재 여부만 바뀜).

    아직 배너도 안 찍힌(=시작도 안 한) TC의 case는 만들지 않는다 — 실제 실행 순서/범위와
    다르게 미리 나열되는 것을 피하기 위함.

    각 placeholder에는 그 TC 하나만 기준으로 한 진행률(progress_percent)을 같이 담는다
    (다른 TC의 진행 상황이 섞여 엉뚱한 숫자로 보이지 않도록 TC 단위로 분리). pending
    row가 존재한다는 것 자체가 그 TC의 case가 아직 남아있다는 뜻이라 done < total이
    보장되어 100%로 보이는 일은 없다.
    sub-id를 쉘 변수로 동적 생성하는 TC(예: system_log TC04)는 expected 집합에 안 잡혀
    tc_totals에 그 TC 번호 자체가 없다. 이 경우 위 루프는 그 TC에 대해 아무 row도
    만들지 않아, 배너는 찍혔는데(=실행 중) 결과 현황판에는 전혀 안 보이는 상태가
    된다 — TC04의 journal 주입처럼 첫 sub-case 판정까지 수 분이 걸리는 TC에서
    실제로 관찰됨(2026-08-20). 아래 fallback으로, "배너만 찍히고 아직 그 TC의
    어떤 case도 안 온" 마지막 TC 하나에 한해 진행률 없는 제네릭 RUNNING row를
    하나 만들어준다.
    """
    attempted = _attempted_tc_numbers(log_text)
    if not attempted:
        return []
    existing_ids = {c["case"] for c in existing_cases}
    existing_tc_nos = {c["tc"] for c in existing_cases}
    expected = _expected_cases(app_cfg)
    tc_totals: dict = {}
    tc_done: dict = {}
    for sub_id in expected:
        tc_no = sub_id.split("-", 1)[0]
        tc_totals[tc_no] = tc_totals.get(tc_no, 0) + 1
    for c in existing_cases:
        tc_done[c["tc"]] = tc_done.get(c["tc"], 0) + 1

    pending = []
    for sub_id, desc in expected.items():
        tc_no = sub_id.split("-", 1)[0]
        if tc_no in attempted and sub_id not in existing_ids:
            total_tc = tc_totals.get(tc_no, 0)
            done_tc = tc_done.get(tc_no, 0)
            pct = round(done_tc / total_tc * 100) if total_tc > 0 else None
            pending.append({"tc": tc_no, "case": sub_id, "status": "RUNNING", "desc": desc,
                             "reason": "", "progress_percent": pct})

    last_tc, last_desc = None, ""
    last_sub_case, last_sub_desc = None, ""
    for line in log_text.splitlines():
        stripped = line.strip()
        m = TC_BANNER_DESC_RE.match(stripped)
        if m:
            last_tc, last_desc = m.group(1), m.group(2)
            continue
        m = TC_SUBBANNER_RE.match(stripped)
        if m:
            last_sub_case, last_sub_desc = m.group(1), m.group(2)
    if last_tc and last_tc not in tc_totals and last_tc not in existing_tc_nos:
        # 스크립트가 "--- TC04-1: ... ---" 식으로 자기 sub-case 배너를 직접 찍어주면
        # 그 실제 sub-case id를 그대로 쓴다(예: TC04-1) — placeholder를 위해 지어낸
        # 이름(예: TC04-live)을 Case 칸에 넣지 않기 위함. TC 칸은 항상 last_tc(TC04)로 고정.
        if last_sub_case and last_sub_case.startswith(f"{last_tc}-") and last_sub_case not in existing_ids:
            case_id, desc = last_sub_case, last_sub_desc
        else:
            case_id, desc = last_tc, last_desc or "진행중"
        pending.append({"tc": last_tc, "case": case_id, "status": "RUNNING",
                         "desc": desc or "진행중", "reason": "", "progress_percent": None})
    return pending


def _case_sort_key(c: dict):
    tc_num = int(re.sub(r"\D", "", c["tc"]) or 0)
    sub_part = c["case"].split("-", 1)[1] if "-" in c["case"] else ""
    sub_num = int(re.sub(r"\D", "", sub_part) or 0)
    return (tc_num, sub_num)


def _parse_results(text: str, app_cfg: Optional[dict] = None):
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

    # 사전조건 미충족으로 assert() 자체가 안 불린 sub-case를 SKIP으로 보충한다.
    # 이 TC 번호의 배너가 이번 run에 등장했는데(=실행 범위에 포함) 기대 sub-case
    # 중 실제로 판정되지 않은 게 있으면 SKIP — PASS/FAIL 카운트에는 안 들어간다.
    #
    # 반드시 "완료된" run에만 적용한다 — SUMMARY_RE(최종 "결과: PASS=X FAIL=Y" 줄)가
    # 없으면 아직 실행 중이거나 중간에 끊긴 로그라, 그저 "아직 안 온" sub-case까지
    # "영원히 판정 안 될 SKIP"으로 오판하게 된다(2026-08-13 실측: system_log 진행 중인
    # run의 TC02-1/2가 서비스 재시작 대기 단계에서 SKIP으로 잘못 표시됨).
    if app_cfg is not None and SUMMARY_RE.search(text):
        attempted = _attempted_tc_numbers(text)
        for sub_id, desc in _expected_cases(app_cfg).items():
            tc_no = sub_id.split("-", 1)[0]
            if tc_no in attempted and sub_id not in cases_map:
                order.append(sub_id)
                cases_map[sub_id] = {
                    "tc": tc_no, "case": sub_id, "status": "SKIP",
                    "desc": desc,
                    "reason": "사전조건 미충족 — 로그의 해당 TC 블록 [SKIP] 안내 참고",
                }

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


def _generate_result_md(app_cfg: dict, run_id: str, meta: dict, cases: list,
                         log_text: str, sl_journal_text: str = "") -> str:
    """tcs/<app>/tc_<app>_result.md 형식을 본떠 run 단위 결과 보고서를 생성한다."""
    lines = [
        f"# TC 실행 결과 보고서 — {meta.get('label') or meta.get('tc_id', run_id)}",
        "",
        f"**Run ID:** {run_id}",
        f"**앱:** {app_cfg['label']}",
        f"**실행일시:** {meta.get('started_at', '')} ~ {meta.get('finished_at', '')}",
        f"**DUT:** {DUT_HOST} (qcells-emsplus, AC Gen2, aarch64)",
        f"**스크립트:** {app_cfg['tc_script'].name}",
        "",
        f"**총 결과: PASS={meta.get('pass', 0)} / FAIL={meta.get('fail', 0)} / SKIP={meta.get('skip', 0)} / {len(cases)}기준**",
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


def _record_case_times(log_path: Path, app_cfg: dict, case_times: dict) -> None:
    """log_path를 다시 파싱해, 아직 시각을 못 남긴 case_id에 한해 "지금 처음 목격했다"는
    시각을 기록한다. _wait_run_proc()의 on_progress 콜백으로 폴링 주기(2초)마다 호출되며,
    이미 기록된 case는 건드리지 않는다(setdefault) — 여러 번 호출돼도 안전.
    """
    try:
        text = log_path.read_text(errors="replace")
    except Exception:
        return
    _, _, cases = _parse_results(text, app_cfg)
    now = datetime.now()
    for c in cases:
        case_times.setdefault(c["case"], now)


def _compute_case_durations(started_at_iso: str, cases: list, case_times: dict) -> dict:
    """"결과 현황판"에 표시할 case별 소요시간(초) 근사치.

    case_times는 폴링(2초 간격)으로 채운 "이 case를 처음 목격한 시각"이라 실제 완료
    시각보다 최대 폴링 주기만큼 늦을 수 있다 — 정확한 계측이 아니라 "어느 TC가 오래
    걸렸는지" 파악용 근사치다. cases는 _parse_results()가 반환하는 실행(출현) 순서를
    그대로 따르므로, "직전 case가 기록된 시각부터 이 case가 기록된 시각까지"를 그
    case의 소요시간으로 근사한다(첫 case는 run 시작 시각 기준).
    """
    prev = datetime.fromisoformat(started_at_iso)
    durations: dict = {}
    for c in cases:
        t = case_times.get(c["case"])
        if t is None:
            continue
        durations[c["case"]] = max(0.0, (t - prev).total_seconds())
        prev = t
    return durations


def _merge_case_status(status_map: dict, run_id: str, meta: dict, cases: list):
    # "at"(run 종료 시각)은 카드 요약("최근 실행 시각")이 여전히 참조하므로 남겨두고,
    # 결과현황판 표의 "소요 시간" 칸은 새로 추가된 duration_sec을 쓴다.
    case_durations = meta.get("case_durations") or {}
    for c in cases:
        status_map[c["case"]] = {
            "status": c["status"],
            "desc": c["desc"],
            "reason": c.get("reason", ""),
            "tc": c["tc"],
            "run_id": run_id,
            "at": meta["finished_at"],
            "duration_sec": case_durations.get(c["case"]),
        }


def _update_latest_status(status_file: Path, run_id: str, meta: dict, cases: list):
    status_map = {}
    if status_file.exists():
        status_map = json.loads(status_file.read_text())
    _merge_case_status(status_map, run_id, meta, cases)
    status_file.write_text(json.dumps(status_map, ensure_ascii=False, indent=2))


CASE_ID_IN_ASSERT_RE = re.compile(r'assert\s+"(TC\d+)')


def _valid_tc_numbers(app_cfg: dict) -> set:
    """앱의 현재 tc_<app>.sh에 실제 `assert "TCxx...` 로 남아있는 TC 번호(예: "TC04") 집합.

    TC 스펙이 바뀌어(예: TC04-2 티어 제거) 더 이상 스크립트가 만들어내지 않는 case가
    과거 run의 output.log에는 여전히 남아있어, 그대로 replay하면 현황판(latest_status)에
    유령처럼 계속 다시 나타난다 — replay 결과를 이 집합으로 걸러 현재 스크립트에 없는
    TC는 자동으로 빠지게 한다.

    case id 전체(예: "TC04-1")가 아니라 TC 번호만 뽑는다 — TC04처럼 sub-id를
    `assert "TC04-${idx}: ..."`같은 셸 변수로 넣는 TC는 소스 텍스트에 리터럴
    "TC04-1"이 없어서, case id 전체를 정규식으로 매칭하면 그 TC가 통째로 걸러져
    현황판에서 사라지는 실제 버그가 있었다(2026-08-04). TC 번호는 항상 리터럴이므로
    이 레벨에서 매칭하면 sub-id가 동적이어도 안전하다.

    스크립트를 못 읽으면(경로 이상 등) 빈 집합을 돌려주고, 호출부에서 빈 집합이면
    필터링 자체를 건너뛰어 오동작으로 전체가 비는 걸 방지한다.
    """
    try:
        text = app_cfg["tc_script"].read_text()
    except Exception:
        return set()
    return set(CASE_ID_IN_ASSERT_RE.findall(text))


def _prune_old_runs(runs_dir: Path, keep: int = MAX_RUNS):
    """runs_dir 아래 run_id(=YYYYMMDD_HHMMSS_... 접두라 이름순=시간순) 기준 최신 keep개만 남기고 나머지는 삭제."""
    run_dirs = sorted((d for d in runs_dir.iterdir() if d.is_dir()), key=lambda d: d.name, reverse=True)
    for stale_dir in run_dirs[keep:]:
        shutil.rmtree(stale_dir, ignore_errors=True)


def _rebuild_latest_status(app_cfg: dict):
    """status_file을 실제 runs_dir에 남아있는 run들만 기준으로 처음부터 다시 만든다.

    _update_latest_status()는 누적(merge)만 하므로 _prune_old_runs()로 오래된 run 디렉토리를
    지워도 그 run이 마지막으로 채운 케이스 항목은 그대로 남는다 — 존재하지 않는 run_id를
    가리키는 stale 항목이 생기지 않도록, 남은 run들을 시간순으로 재생해 상태를 재구성한다.
    """
    status_map: dict = {}
    run_dirs = sorted((d for d in app_cfg["runs_dir"].iterdir() if d.is_dir()), key=lambda d: d.name)
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
        _, _, cases = _parse_results(log_path.read_text(errors="replace"), app_cfg)
        if cases:
            _merge_case_status(status_map, run_dir.name, meta, cases)

    valid_tcs = _valid_tc_numbers(app_cfg)
    if valid_tcs:
        status_map = {cid: v for cid, v in status_map.items() if v.get("tc") in valid_tcs}

    app_cfg["status_file"].write_text(json.dumps(status_map, ensure_ascii=False, indent=2))


SL_TAG_RE = re.compile(r"\[SL\]|\[SM\]")


async def _start_journal_capture():
    """DUT의 [SL]/[SM] 애플리케이션 로그를 별도 SSH 세션으로 실시간 캡처 시작.
    캡처 자체는 둘 다 남기고, 보고서에 실릴 때는 _filter_journal_for_tc가 TC별로
    관련 있는 라인만(최대 JOURNAL_EXCERPT_MAX_LINES줄) 추려서 방대해지지 않게 한다.

    tc-run 스킬이 시리얼에서 하는 '백그라운드 journalctl -f capture' 패턴을
    SSH 세션으로 재현한 것 — 실패해도 본 TC 실행에는 영향 주지 않는다(best-effort).
    [SL]/[SM] 태그는 system_log 전용이라 다른 앱에서는 근거가 안 잡힐 수 있음 —
    새 앱이 자기 태그를 쓰게 되면 이 필터를 앱별로 넓히면 된다.
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


async def _ensure_fresh_ssh_master():
    """DUT가 재부팅되면 기존 ControlMaster 연결은 죽지만, 그 마스터 프로세스 자체는
    ServerAliveCountMax(80회)를 다 채워야 스스로 종료돼 최대 20분간 좀비로 남는다 —
    그동안 새 scp/ssh는 죽은 채널을 계속 재사용하려다 (타임아웃 없이) 멈춰버린다.

    `ssh -O check`만으로는 이 좀비를 못 잡는다 — 마스터 "프로세스"는 살아있다고
    응답하지만(그래서 rc=0), 그 밑의 실제 멀티플렉스 터널은 죽어있는 경우가 실측으로
    확인됨(2026-08-04, DUT 재부팅 후 두 차례 재현: `-O check` "Master running"인데
    실제 `ssh ... true`는 15초+ 무한 대기). 그래서 check가 통과해도 SSH_OPTS(같은
    ControlPath)로 실제 왕복(`true`) 하나를 짧은 타임아웃으로 찔러보고, 그것마저
    막히면 좀비로 간주해 `-O exit`로 정리한다 — 다음 scp/ssh(ControlMaster=auto)가
    새 연결을 맺는다.
    """
    master_alive = False
    try:
        check = await asyncio.create_subprocess_exec(
            "ssh", "-o", f"ControlPath={SSH_CONTROL_PATH}", "-O", "check", f"root@{DUT_HOST}",
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        rc = await asyncio.wait_for(check.wait(), timeout=5)
        master_alive = (rc == 0)
    except Exception:
        master_alive = False

    zombie = not master_alive
    if master_alive:
        probe = None
        try:
            probe = await asyncio.create_subprocess_exec(
                "ssh", *SSH_OPTS, f"root@{DUT_HOST}", "true",
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            probe_rc = await asyncio.wait_for(probe.wait(), timeout=8)
            zombie = (probe_rc != 0)
        except asyncio.TimeoutError:
            zombie = True
            if probe:
                probe.kill()
                await probe.wait()
        except Exception:
            zombie = True

    if zombie:
        try:
            exit_proc = await asyncio.create_subprocess_exec(
                "ssh", "-o", f"ControlPath={SSH_CONTROL_PATH}", "-O", "exit", f"root@{DUT_HOST}",
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(exit_proc.wait(), timeout=5)
            await asyncio.sleep(0.3)  # 소켓 파일 정리 여유 — 없어도 대개 direct fallback으로 동작함
        except Exception:
            pass  # 소켓이 아예 없으면 여기로 옴 — best-effort


# SSH ControlMaster 멀티플렉스 채널이 세션 도중 좀비가 되는 사례가 실측으로 확인됨
# (2026-08-04, _ensure_fresh_ssh_master 참고) — 마스터 프로세스 자체는 keepalive에
# 계속 응답해 ServerAliveCountMax(최대 20분)로는 못 잡고, run_proc이 아무 출력 없이
# 타임아웃(entry["timeout"], 길게는 8.5시간)까지 그냥 멈춰있게 된다. log 파일 크기가
# 일정 시간 전혀 늘지 않으면 좀비로 보고 강제 종료한다. 기본값(900s)은 이 코드베이스의
# 모든 TC 스크립트에서 가장 긴 "출력 없는 단일 sleep" 구간(device_log TC21(구 TC24) ~330s 등)보다
# 넉넉히 크게 잡았다 — device_log TC05처럼 6시간+ 동안 중간 출력이 전혀 없는 TC가
# 포함된 entry는 반드시 entry["stall_timeout"]으로 이 기본값을 오버라이드해야 한다.
STALL_TIMEOUT = 900


async def _wait_run_proc(run_proc, log_path: Path, timeout: float, stall_timeout: float = STALL_TIMEOUT,
                          on_progress: Optional[Callable[[], None]] = None) -> "tuple[int | None, str]":
    """run_proc.wait()을 기다리되 두 조건 중 하나라도 걸리면 강제 종료한다.

    - timeout(entry 전체 허용 시간) 초과 → 기존 동작과 동일
    - stall_timeout 동안 log_path 크기가 전혀 늘지 않음 → SSH 멀티플렉스 채널이
      세션 도중 좀비가 된 것으로 보고 강제 종료
    - on_progress: log_path 크기가 늘 때마다(=새 출력이 있을 때마다) 호출되는 콜백.
      결과현황판의 "소요 시간" 계산용 case별 목격 시각 기록(_record_case_times)에 쓰인다
      — 폴링 주기(2초)를 그대로 재사용해 별도 타이머 없이 근사 시각을 얻는다.

    반환: (exit_code, reason) — reason은 "ok" | "timeout" | "stalled"
    """
    loop = asyncio.get_event_loop()
    start = loop.time()
    last_size = log_path.stat().st_size if log_path.exists() else 0
    last_change = start
    wait_task = asyncio.ensure_future(run_proc.wait())
    try:
        while True:
            # case별 소요시간 근사 정확도를 위해 기존 10초 폴링을 2초로 단축했다 —
            # stall 감지 임계값(stall_timeout) 자체는 그대로라 판정 로직에 영향 없음.
            done, _ = await asyncio.wait({wait_task}, timeout=2)
            if wait_task in done:
                return wait_task.result(), "ok"

            now = loop.time()
            if now - start > timeout:
                run_proc.kill()
                await run_proc.wait()
                return None, "timeout"

            size = log_path.stat().st_size if log_path.exists() else last_size
            if size > last_size:
                last_size = size
                last_change = now
                if on_progress:
                    on_progress()
            elif now - last_change > stall_timeout:
                run_proc.kill()
                await run_proc.wait()
                return None, "stalled"
    finally:
        if not wait_task.done():
            wait_task.cancel()


async def _run_ssh(app_cfg: dict, entry: dict, log_path: Path, run_dir: Path,
                    case_times: Optional[dict] = None) -> "int | None":
    await _ensure_fresh_ssh_master()
    tc_script = app_cfg["tc_script"]
    remote_script = app_cfg["remote_script"]
    with open(log_path, "wb") as logf:
        logf.write(f"$ scp {tc_script.name} -> root@{DUT_HOST}:{remote_script}\n".encode())
        logf.flush()
        scp_proc = await asyncio.create_subprocess_exec(
            "scp", *SSH_OPTS, str(tc_script), f"root@{DUT_HOST}:{remote_script}",
            stdout=logf, stderr=logf,
        )
        scp_rc = await asyncio.wait_for(scp_proc.wait(), timeout=30)
        if scp_rc != 0:
            raise RuntimeError(f"scp 전송 실패 (exit={scp_rc})")

        chmod_proc = await asyncio.create_subprocess_exec(
            *ssh_argv(f"chmod +x {remote_script}"), stdout=logf, stderr=logf,
        )
        await asyncio.wait_for(chmod_proc.wait(), timeout=15)

        journal_proc, journal_lines, collector_task = await _start_journal_capture()

        flag = entry["flag"] or ""
        remote_cmd = f"sh {remote_script} {flag} 2>&1".strip()
        logf.write(f"\n$ ssh root@{DUT_HOST} '{remote_cmd}'\n\n".encode())
        logf.flush()
        run_proc = await asyncio.create_subprocess_exec(
            *ssh_argv(remote_cmd), stdout=logf, stderr=logf,
        )
        current_run["proc"] = run_proc
        on_progress = (
            (lambda: _record_case_times(log_path, app_cfg, case_times))
            if case_times is not None else None
        )
        exit_code, reason = await _wait_run_proc(
            run_proc, log_path, entry["timeout"], entry.get("stall_timeout", STALL_TIMEOUT),
            on_progress=on_progress,
        )
        if reason == "timeout":
            logf.write(b"\n[DASHBOARD] TIMEOUT - \xed\x94\x84\xeb\xa1\x9c\xec\x84\xb8\xec\x8a\xa4 \xea\xb0\x95\xec\xa0\x9c \xec\xa2\x85\xeb\xa3\x8c\n")
        elif reason == "stalled":
            logf.write(
                f"\n[DASHBOARD] STALL - {entry.get('stall_timeout', STALL_TIMEOUT)}초간 출력 없음"
                "(SSH 멀티플렉스 채널 좀비 의심) - 프로세스 강제 종료\n".encode()
            )

        await _stop_journal_capture(journal_proc, journal_lines, collector_task, run_dir)
    return exit_code


async def _wait_for_dut_reboot(logf, max_wait_s: int = 180) -> bool:
    """TC10-pre 직후 ping → SSH 순으로 폴링해 재부팅 완료를 기다린다.
    tc-run 스킬의 SSH fallback 절차(ping 폴링 → ssh ALIVE 폴링 → boot+merge sleep)를
    대시보드 오케스트레이션으로 재현한 것. reboot로 기존 ControlMaster 소켓이 좀비가
    되는 문제는 _ensure_fresh_ssh_master()가 처리(module docstring 참고)."""
    loop = asyncio.get_event_loop()

    logf.write("\n[DASHBOARD] DUT 재부팅 대기 중 (ping polling)...\n".encode())
    logf.flush()
    deadline = loop.time() + max_wait_s
    pinged = False
    while loop.time() < deadline:
        proc = await asyncio.create_subprocess_exec(
            "ping", "-c", "1", "-W", "1", DUT_HOST,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        if await proc.wait() == 0:
            pinged = True
            break
        await asyncio.sleep(2)
    if not pinged:
        logf.write(f"[DASHBOARD] ping 응답 없음 ({max_wait_s}s 초과) - reboot 실패 가능성\n".encode())
        return False

    logf.write("[DASHBOARD] ping 응답 확인. SSH 재접속 대기...\n".encode())
    logf.flush()
    await _ensure_fresh_ssh_master()

    deadline = loop.time() + max_wait_s
    alive = False
    while loop.time() < deadline:
        proc = await asyncio.create_subprocess_exec(
            *ssh_argv("echo ALIVE"), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            out = b""
        if b"ALIVE" in out:
            alive = True
            break
        await asyncio.sleep(3)
    if not alive:
        logf.write(f"[DASHBOARD] SSH 재접속 실패 ({max_wait_s}s 초과)\n".encode())
        return False

    logf.write("[DASHBOARD] SSH 재접속 확인. boot+merge 완료 대기 (45s)...\n".encode())
    logf.flush()
    await asyncio.sleep(45)
    return True


async def _run_ssh_full_with_reboots(app_cfg: dict, entry: dict, log_path: Path, run_dir: Path,
                                      case_times: Optional[dict] = None) -> "int | None":
    """entry["flag"](있으면, 예: --full)를 먼저 실행한 뒤 entry["chain_reboot_pairs"]에 담긴
    (pre_id, post_id) 목록을 순서대로 pre → 재부팅 대기 → post 로 이어 붙인다.

    reboot를 수반하는 TC는 SSH 세션이 끊겨 단일 ssh 호출 안에 넣을 수 없다 — 이 함수가
    직접 오케스트레이션한다(system_log는 TC10 한 쌍, device_log는 TC06/07·15·20·26
    네 쌍). entry["flag"]가 없으면(단일 reboot TC "선택 실행") 앞 단계 없이 pair
    체이닝부터 바로 시작한다. 모든 단계가 같은 output.log에 이어 쓰인다 — run_tc()의
    _parse_results가 output.log 전체를 한 번에 스캔해 [PASS]/[FAIL]을 case_id로
    모으므로, 여기선 병합 로직 없이 그냥 이어 쓰기만 하면 최종 PASS/FAIL이 자동 합산된다.
    sl_journal.log만 예외적으로 _stop_journal_capture가 매 단계 덮어쓰므로, 여기서는
    단계별로 직접 수거해 마지막에 한 번에 합쳐 쓴다.
    """
    accumulated_sl_lines: list = []
    wrote_header = False

    async def _run_step(step_entry: dict) -> "int | None":
        nonlocal wrote_header
        await _ensure_fresh_ssh_master()
        tc_script = app_cfg["tc_script"]
        remote_script = app_cfg["remote_script"]
        with open(log_path, "ab" if wrote_header else "wb") as logf:
            wrote_header = True
            logf.write(f"$ scp {tc_script.name} -> root@{DUT_HOST}:{remote_script}\n".encode())
            logf.flush()
            scp_proc = await asyncio.create_subprocess_exec(
                "scp", *SSH_OPTS, str(tc_script), f"root@{DUT_HOST}:{remote_script}",
                stdout=logf, stderr=logf,
            )
            scp_rc = await asyncio.wait_for(scp_proc.wait(), timeout=30)
            if scp_rc != 0:
                raise RuntimeError(f"scp 전송 실패 (exit={scp_rc})")

            chmod_proc = await asyncio.create_subprocess_exec(
                *ssh_argv(f"chmod +x {remote_script}"), stdout=logf, stderr=logf,
            )
            await asyncio.wait_for(chmod_proc.wait(), timeout=15)

            journal_proc, journal_lines, collector_task = await _start_journal_capture()

            flag = step_entry["flag"] or ""
            remote_cmd = f"sh {remote_script} {flag} 2>&1".strip()
            logf.write(f"\n$ ssh root@{DUT_HOST} '{remote_cmd}'\n\n".encode())
            logf.flush()
            run_proc = await asyncio.create_subprocess_exec(
                *ssh_argv(remote_cmd), stdout=logf, stderr=logf,
            )
            current_run["proc"] = run_proc
            on_progress = (
                (lambda: _record_case_times(log_path, app_cfg, case_times))
                if case_times is not None else None
            )
            exit_code, reason = await _wait_run_proc(
                run_proc, log_path, step_entry["timeout"], step_entry.get("stall_timeout", STALL_TIMEOUT),
                on_progress=on_progress,
            )
            if reason == "timeout":
                logf.write(b"\n[DASHBOARD] TIMEOUT - \xed\x94\x84\xeb\xa1\x9c\xec\x84\xb8\xec\x8a\xa4 \xea\xb0\x95\xec\xa0\x9c \xec\xa2\x85\xeb\xa3\x8c\n")
            elif reason == "stalled":
                logf.write(
                    f"\n[DASHBOARD] STALL - {step_entry.get('stall_timeout', STALL_TIMEOUT)}초간 출력 없음"
                    "(SSH 멀티플렉스 채널 좀비 의심) - 프로세스 강제 종료\n".encode()
                )

            # -pre 단계는 reboot로 세션이 끊기며 journalctl -f 프로세스도 같이 죽는다 —
            # best-effort로 그때까지 모인 lines만 수거한다 (_stop_journal_capture와 달리
            # 파일에 바로 쓰지 않고 accumulated_sl_lines에 모아뒀다 마지막에 합쳐 쓴다).
            try:
                await asyncio.sleep(1.5)
            except Exception:
                pass
            if journal_proc is not None:
                try:
                    journal_proc.kill()
                    await asyncio.wait_for(journal_proc.wait(), timeout=5)
                except Exception:
                    pass
                if collector_task:
                    collector_task.cancel()
                accumulated_sl_lines.extend(l for l in journal_lines if SL_TAG_RE.search(l))
            logf.flush()
        return exit_code

    exit_code = None
    if entry.get("flag"):
        exit_code = await _run_step(entry)
        if exit_code != 0:
            reason = "사용자가 중지함" if current_run.get("cancelled") else f"비정상 종료(exit_code={exit_code}) — 타임아웃/좀비 감지 등"
            with open(log_path, "ab") as logf:
                logf.write(f"\n[DASHBOARD ERROR] 메인 단계가 정상 종료되지 않음({reason}) - 재부팅 체인 스킵, 이후 단계 중단\n".encode())
            if accumulated_sl_lines:
                (run_dir / "sl_journal.log").write_text("".join(accumulated_sl_lines))
            return exit_code

    for pre_id, post_id in entry.get("chain_reboot_pairs", []):
        tc_label = pre_id.split("-", 1)[0].upper()
        with open(log_path, "ab" if wrote_header else "wb") as logf:
            wrote_header = True
            logf.write(f"\n\n=== {tc_label} (reboot) 자동 진행 ===\n".encode())

        # pre 단계 (reboot 발생 — 세션이 끊기며 exit_code가 비정상/None일 수 있음, 정상 동작)
        await _run_step(app_cfg["catalog_map"][pre_id])

        with open(log_path, "ab") as logf:
            rebooted_ok = await _wait_for_dut_reboot(logf)

        if not rebooted_ok:
            with open(log_path, "ab") as logf:
                logf.write(f"\n[DASHBOARD ERROR] DUT 재부팅 확인 실패 - {tc_label}-post 스킵, 이후 단계 중단\n".encode())
            if accumulated_sl_lines:
                (run_dir / "sl_journal.log").write_text("".join(accumulated_sl_lines))
            return None

        exit_code = await _run_step(app_cfg["catalog_map"][post_id])

    if accumulated_sl_lines:
        (run_dir / "sl_journal.log").write_text("".join(accumulated_sl_lines))
    return exit_code


_SERIAL_NOISE_LINE_RE = re.compile(r"docker-loader\[")
_SERIAL_PROMPT_PREFIX_RE = re.compile(r"^(?:P>\s*)+")
_SERIAL_DASH_MARKERS = {"M_RM_DONE", "M_DECODE_DONE", "M_DASH_RUN_END"}


def _looks_corrupted(line: str) -> bool:
    """시리얼 라인 노이즈로 바이트가 깨지면 errors="replace"가 U+FFFD로 채운다.
    개행 없는 수천자짜리 덩어리부터 짧은 순수 바이너리 조각까지 다 나올 수 있어
    (전자는 낮은 비율로도 절대량이 많고, 후자는 절대량은 적어도 비율이 높다) 최소
    길이만 짧게 잡고 비율 기준으로 판정한다.
    """
    if len(line) < 8:
        return False
    bad = line.count("�")
    return bad >= 3 and bad / len(line) > 0.15


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


async def _run_serial(app_cfg: dict, entry: dict, log_path: Path) -> "int | None":
    """COM 포트로 transfer+실행. SSH 를 전혀 쓰지 않으므로 SSH lockout 상태에서도 동작한다
    (journal capture 등 SSH 기반 부가 기능은 지원하지 않음)."""
    flag = entry["flag"] or ""
    argv = [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", _win_path(SERIAL_RUN_PS1),
        "-ComPort", SERIAL_COM_PORT,
        "-ScriptPath", _win_path(app_cfg["tc_script"]),
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
        current_run["proc"] = proc
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


async def run_tc(run_id: str, app_cfg: dict, entry: dict, channel: str = "ssh"):
    run_dir = app_cfg["runs_dir"] / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "output.log"
    meta = {
        "run_id": run_id,
        "app_id": app_cfg["id"],
        "tc_id": entry["id"],
        "label": entry["label"],
        "flag": entry["flag"],
        "channel": channel,
        "started_at": datetime.now().isoformat(timespec="seconds"),
        "finished_at": None,
        "status": "running",
        "pass": 0,
        "fail": 0,
        "skip": 0,
        "exit_code": None,
    }
    _write_meta(run_dir, meta)

    # case_id별 "처음 목격한 시각" — _wait_run_proc()의 on_progress 콜백(_record_case_times)이
    # 폴링 주기(2초)마다 채운다. serial 채널은 아직 미지원(그래도 duration_sec=None으로
    # 안전하게 표시됨 — _compute_case_durations가 case_times에 없는 case는 건너뜀).
    # current_run["case_times"]에도 같이 얹어둬서, 이 run이 아직 "running"인 동안에도
    # api_run_detail()이 실시간으로 진행중 소요시간을 계산할 수 있게 한다(동시에 하나의
    # run만 진행되는 이 대시보드의 싱글턴 실행 모델을 그대로 재사용).
    case_times: dict = {}
    current_run["case_times"] = case_times

    try:
        if channel == "serial":
            exit_code = await _run_serial(app_cfg, entry, log_path)
        elif entry.get("chain_reboot_pairs"):
            exit_code = await _run_ssh_full_with_reboots(app_cfg, entry, log_path, run_dir, case_times)
        else:
            exit_code = await _run_ssh(app_cfg, entry, log_path, run_dir, case_times)

        meta["exit_code"] = exit_code
        text = log_path.read_text(errors="replace")
        pass_n, fail_n, cases = _parse_results(text, app_cfg)
        _record_case_times(log_path, app_cfg, case_times)  # 마지막 순간에 찍힌 case까지 마저 기록
        meta["case_durations"] = _compute_case_durations(meta["started_at"], cases, case_times)
        meta["pass"] = pass_n
        meta["fail"] = fail_n
        meta["skip"] = sum(1 for c in cases if c["status"] == "SKIP")
        if current_run.get("cancelled"):
            # 사용자가 중지 버튼을 눌러 강제 종료한 경우 — reboot/timeout/fail 판정보다 우선.
            meta["status"] = "cancelled"
        elif entry["reboot"]:
            meta["status"] = "rebooted"
        elif exit_code is None:
            meta["status"] = "timeout"
        elif fail_n > 0:
            meta["status"] = "fail"
        elif not cases:
            # exit_code가 0이어도(예: 시리얼 결과 dump가 노이즈로 깨진 경우) 파싱된 케이스가
            # 하나도 없으면 "결과 없음"이지 "pass"가 아니다.
            meta["status"] = "error"
        elif pass_n == 0:
            # cases는 있지만 전부 SKIP(자동화 불가/환경 제약)인 경우 — "결과 없음"과
            # 달리 실제로 정상 실행되어 의도한 SKIP 판정이 난 것이므로 error가 아니다.
            meta["status"] = "skip"
        else:
            meta["status"] = "pass"
        meta["finished_at"] = datetime.now().isoformat(timespec="seconds")
        _write_meta(run_dir, meta)
        if cases:
            _update_latest_status(app_cfg["status_file"], run_id, meta, cases)
    except Exception as e:
        meta["status"] = "error"
        meta["finished_at"] = datetime.now().isoformat(timespec="seconds")
        _write_meta(run_dir, meta)
        with open(log_path, "ab") as logf:
            logf.write(f"\n[DASHBOARD ERROR] {e}\n".encode())
    finally:
        current_run["run_id"] = None
        current_run["proc"] = None
        current_run["cancelled"] = False
        current_run["case_times"] = None
        _prune_old_runs(app_cfg["runs_dir"])
        _rebuild_latest_status(app_cfg)


SUMMARY_RE = re.compile(r"PASS=(\d+)\s+FAIL=(\d+)")


def _reconcile_stale_runs():
    """서버 재시작/크래시로 완료 처리를 못 받은 run을 로그 기준으로 정정 (모든 앱 대상).

    run_tc()는 프로세스가 끝나야 meta.json에 finished_at/status를 쓰는데,
    서버 프로세스 자체가 죽으면(재시작 등) 그 전에 meta가 running으로 남는다.
    output.log 에 최종 요약 라인이 있으면 실제로는 끝난 것이므로 그 결과로
    채우고, 없으면 진짜 중단된 것이므로 interrupted 로 표시한다.
    """
    for app_cfg in APPS.values():
        runs_dir = app_cfg["runs_dir"]
        if not runs_dir.exists():
            continue
        for run_dir in runs_dir.iterdir():
            meta_path = run_dir / "meta.json"
            if not meta_path.exists():
                continue
            meta = json.loads(meta_path.read_text())
            if meta.get("status") != "running":
                continue
            log_path = run_dir / "output.log"
            text = log_path.read_text(errors="replace") if log_path.exists() else ""
            pass_n, fail_n, cases = _parse_results(text, app_cfg)
            finished_at = (
                datetime.fromtimestamp(log_path.stat().st_mtime).isoformat(timespec="seconds")
                if log_path.exists() else datetime.now().isoformat(timespec="seconds")
            )
            entry = app_cfg["catalog_map"].get(meta["tc_id"], {})
            meta["pass"], meta["fail"] = pass_n, fail_n
            meta["skip"] = sum(1 for c in cases if c["status"] == "SKIP")
            meta["finished_at"] = finished_at
            if SUMMARY_RE.search(text):
                meta["exit_code"] = 0 if fail_n == 0 else 1
                if entry.get("reboot"):
                    meta["status"] = "rebooted"
                elif fail_n > 0:
                    meta["status"] = "fail"
                elif pass_n == 0 and cases:
                    meta["status"] = "skip"
                else:
                    meta["status"] = "pass"
                if cases:
                    _update_latest_status(app_cfg["status_file"], meta["run_id"], meta, cases)
            else:
                meta["status"] = "interrupted"
            _write_meta(run_dir, meta)


@app.on_event("startup")
def _on_startup():
    current_run["run_id"] = None
    _reconcile_stale_runs()
    for app_cfg in APPS.values():
        _prune_old_runs(app_cfg["runs_dir"])
        _rebuild_latest_status(app_cfg)


@app.get("/api/apps")
def api_apps():
    """사이드바용 앱 목록 — id/표시명/선택 실행(custom) 지원 여부를 내려준다."""
    return [
        {"id": cfg["id"], "label": cfg["label"], "has_custom": len(cfg["custom_tc_order"]) > 0}
        for cfg in APPS.values()
    ]


@app.get("/api/tcs")
def api_tcs(app_id: str = DEFAULT_APP_ID):
    return _get_app(app_id)["catalog"]


@app.get("/api/custom_tcs")
def api_custom_tcs(app_id: str = DEFAULT_APP_ID):
    """'선택 실행' 체크박스 목록 — id/타임아웃을 서버(앱별 CUSTOM_TC_TIMEOUTS)에서 그대로 내려준다."""
    cfg = _get_app(app_id)
    return [{"id": tc, "timeout": cfg["custom_tc_timeouts"][tc]} for tc in cfg["custom_tc_order"]]


@app.get("/api/status")
def api_status(app_id: str = DEFAULT_APP_ID):
    status_file = _get_app(app_id)["status_file"]
    if status_file.exists():
        return json.loads(status_file.read_text())
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
def api_runs(app_id: str = DEFAULT_APP_ID, page: int = 1, page_size: int = 10):
    runs_dir = _get_app(app_id)["runs_dir"]
    runs = []
    for d in sorted(runs_dir.iterdir(), reverse=True):
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


def _read_clean_log(log_path: Path) -> str:
    """output.log를 읽되 _looks_corrupted() 줄은 걸러서 반환한다.

    _tail_serial_log()의 실시간 필터는 라이브 tee 스트림만 거치므로, base64 덤프
    전송 자체가 시리얼 노이즈로 깨지면(디코딩은 성공하지만 내용이 깨진 경우) 그 최종
    결과문은 child 프로세스 stdout으로 바로 들어가 필터를 안 거친다 — 읽을 때 한 번 더
    걸러서 그런 케이스도 브라우저에 안 나가게 한다.
    """
    if not log_path.exists():
        return ""
    text = log_path.read_text(errors="replace")
    lines = [l for l in text.splitlines() if not _looks_corrupted(l)]
    return "\n".join(lines) + ("\n" if lines else "")


@app.get("/api/runs/{run_id}")
def api_run_detail(run_id: str, app_id: str = DEFAULT_APP_ID):
    app_cfg = _get_app(app_id)
    run_dir = app_cfg["runs_dir"] / run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        raise HTTPException(404, "run not found")
    meta = json.loads(meta_path.read_text())
    log_path = run_dir / "output.log"
    log_text = _read_clean_log(log_path)
    _, _, cases = _parse_results(log_text, app_cfg)
    if meta.get("status") == "running":
        cases = sorted(cases + _pending_case_rows(app_cfg, log_text, cases), key=_case_sort_key)
        # 아직 진행 중인 run이면 current_run의 실시간 case_times로 소요시간을 계산한다
        # (완료 전까지는 meta.json에 case_durations가 없음) — 다른 run이 이미 시작돼
        # current_run이 이 run_id를 더 이상 가리키지 않으면 계산하지 않는다(빈 값 유지).
        if current_run.get("run_id") == run_id and current_run.get("case_times") is not None:
            case_durations = _compute_case_durations(meta["started_at"], cases, current_run["case_times"])
        else:
            case_durations = {}
    else:
        case_durations = meta.get("case_durations") or {}
    for c in cases:
        c["duration_sec"] = case_durations.get(c["case"])
    return {"meta": meta, "log": log_text, "cases": cases}


def _load_finished_run(app_cfg: dict, run_id: str):
    run_dir = app_cfg["runs_dir"] / run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        raise HTTPException(404, "run not found")
    meta = json.loads(meta_path.read_text())
    if meta.get("status") == "running":
        raise HTTPException(409, "run이 아직 진행 중")
    log_path = run_dir / "output.log"
    log_text = _read_clean_log(log_path)
    _, _, cases = _parse_results(log_text, app_cfg)
    sl_journal_path = run_dir / "sl_journal.log"
    sl_journal_text = sl_journal_path.read_text(errors="replace") if sl_journal_path.exists() else ""
    return meta, cases, log_text, sl_journal_text


@app.get("/api/runs/{run_id}/result.pdf")
def api_run_result_pdf(run_id: str, app_id: str = DEFAULT_APP_ID):
    app_cfg = _get_app(app_id)
    meta, cases, log_text, sl_journal_text = _load_finished_run(app_cfg, run_id)
    md_content = _generate_result_md(app_cfg, run_id, meta, cases, log_text, sl_journal_text)
    pdf_bytes = _markdown_to_pdf(md_content)
    filename = f"tc_{app_id}_result_{run_id}.pdf"
    return Response(
        pdf_bytes, media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@app.post("/api/run")
async def api_run(req: RunRequest):
    app_cfg = _get_app(req.app_id)
    if req.channel not in ("ssh", "serial"):
        raise HTTPException(400, "unknown channel")
    if current_run["run_id"] is not None:
        raise HTTPException(409, f"이미 실행 중인 run: {current_run['run_id']}")

    if req.tc_id == "custom":
        custom_timeouts = app_cfg["custom_tc_timeouts"]
        selected = req.tc_ids or []
        unknown = [t for t in selected if t not in custom_timeouts]
        if unknown:
            raise HTTPException(400, f"지원하지 않는 TC: {', '.join(unknown)}")
        # 사용자가 체크박스를 어떤 순서로 눌렀든, 스크립트가 실행할 표준 순서로 정렬.
        ordered = [t for t in app_cfg["custom_tc_order"] if t in selected]
        if not ordered:
            raise HTTPException(400, "선택된 TC가 없음")

        reboot_tc_map = app_cfg.get("reboot_tc_map", {})
        reboot_selected = [t for t in ordered if t in reboot_tc_map]
        if reboot_selected:
            # 재부팅을 수반하는 TC(device_log의 TC06/07,15,20,26)는 세션이 끊겨 다른 TC와
            # --only로 한 번에 묶을 수 없다 — 단독 선택만 허용하고, "전체 실행"과 같은
            # -pre/-post 체이닝(_run_ssh_full_with_reboots)으로 실행한다.
            if len(ordered) > 1:
                raise HTTPException(
                    400,
                    f"재부팅을 수반하는 TC({', '.join(reboot_selected)})는 다른 TC와 함께 선택할 수 없습니다 — 단독으로 선택하세요",
                )
            tc = reboot_selected[0]
            pre_id, post_id = reboot_tc_map[tc]
            pre_entry = app_cfg["catalog_map"][pre_id]
            post_entry = app_cfg["catalog_map"][post_id]
            entry = {
                "id": "custom",
                "label": f"선택 실행 ({tc})",
                "flag": None,
                "timeout": 90,
                "reboot": False,
                "note": pre_entry.get("note"),
                "chain_reboot_pairs": [(pre_id, post_id)],
            }
        else:
            # verify_timer_loop_started + (필요시) setup_rotate 오버헤드 여유분.
            timeout = 90 + sum(custom_timeouts[t] for t in ordered)
            # stall_timeout(무출력 정지 판정)은 STALL_TIMEOUT 기본값이 아니라 선택된 TC 중
            # "출력 없는 단일 대기"가 가장 긴 것 기준으로 잡는다 — device_log TC05(6시간+)처럼
            # 중간 출력이 전혀 없는 TC가 섞여 있으면 기본값(900s)으로는 오탐(false stall)한다.
            stall_timeout = max(custom_timeouts[t] for t in ordered) + 300
            entry = {
                "id": "custom",
                "label": f"선택 실행 ({', '.join(ordered)})",
                "flag": f"--only {','.join(ordered)}",
                "timeout": timeout,
                "stall_timeout": stall_timeout,
                "reboot": False,
                "note": None,
            }
    else:
        if req.tc_id not in app_cfg["catalog_map"]:
            raise HTTPException(400, "unknown tc_id")
        entry = app_cfg["catalog_map"][req.tc_id]

    run_id = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{req.app_id}_{req.tc_id}"
    current_run["run_id"] = run_id
    asyncio.create_task(run_tc(run_id, app_cfg, entry, req.channel))
    return {"run_id": run_id, "app_id": req.app_id}


@app.post("/api/runs/{run_id}/stop")
def api_stop_run(run_id: str):
    """실행 중인 run을 강제 종료한다.

    로컬 ssh/powershell 클라이언트 프로세스만 kill한다 — DUT의 원격 셸이 그 즉시
    같이 죽는지는 세션 종료 방식에 달려있어 보장되지 않지만(기존 타임아웃 처리와
    동일한 한계), 로컬 채널이 끊기면 run_tc()의 대기가 곧바로 풀려 dashboard는
    항상 정상적으로 "cancelled"로 마무리된다.
    """
    if current_run["run_id"] != run_id:
        raise HTTPException(409, f"'{run_id}'는 현재 실행 중인 run이 아님 (현재: {current_run['run_id']})")
    proc = current_run.get("proc")
    if proc is None:
        raise HTTPException(409, "아직 프로세스가 시작되지 않음 — 잠시 후 다시 시도")
    current_run["cancelled"] = True
    try:
        proc.kill()
    except ProcessLookupError:
        # 로컬 프로세스가 이미 종료되어 있음(결과 후처리 중일 수 있음) — run_tc()가
        # 곧 정상적으로 마무리하므로 별도 처리 없이 stopping으로 응답한다.
        pass
    return {"run_id": run_id, "status": "stopping"}


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    return (STATIC_DIR / "index.html").read_text()
