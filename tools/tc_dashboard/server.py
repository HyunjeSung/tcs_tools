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
from typing import List, Optional

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
# 앱 레지스트리 — 여기에 항목을 추가하면 사이드바에 자동으로 나타난다.
# ============================================================

# tc_system_log.sh 가 실제로 지원하는 --flag 목록 (스크립트 case 문 기준).
# TC01/02/03/06/07/08/09 는 단독 flag가 없어 기본(default) 실행에만 포함됨.
# TC10은 reboot로 SSH 세션이 끊겨 default 실행 안에서 이어갈 수 없어 유일하게 제외.
CATALOG_SYSTEM_LOG = [
    {"id": "default", "label": "빠른 실행 (TC01~09, 11~14)", "flag": None,
     "timeout": 2600, "reboot": False,
     "note": "TC10(reboot)·TC15/16(각 8~9분+, 대용량 journal) 제외 회귀 세트 — TC04/11/14 대기 "
             "포함 10분 내외. TC15/16은 아래 개별 버튼 또는 --full 로 따로 돌릴 것"},
    {"id": "full", "label": "전체 실행 (TC01~16)", "flag": "--full",
     "timeout": 3900, "reboot": False, "chain_tc10": True,
     "note": "TC01~09, 11~16을 --full로 돌린 뒤 TC10(pre→reboot 대기→post)까지 이 대시보드가 "
             "직접 이어서 진행 — SSH 세션이 reboot로 끊기는 구간은 ping/ssh 폴링으로 재접속을 "
             "기다렸다가 자동 재개한다(수동 TC10-pre/post 클릭 불필요). TC15/16 대용량 journal "
             "주입 + reboot 대기 포함 35~45분+ 소요 — 릴리즈 전 전수 검증용. 회귀 확인엔 위 "
             "빠른 실행 권장. 이 버튼 실행 중에는 다른 TC를 동시에 돌릴 수 없다"},
    {"id": "tc02", "label": "TC02 24시간 타이머", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "system_log 프로세스 kill 수반 (내부 타이머 상태 초기화)"},
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
    {"id": "tc15", "label": "TC15 rotate_sync compress 실패 보존", "flag": "--tc15",
     "timeout": 500, "reboot": False,
     "note": "journal 대량(raw ~400MB) 주입으로 180s 압축 타임아웃 강제 유발, 5분+ 소요"},
    {"id": "tc16", "label": "TC16 boot_log compress 실패 보존", "flag": "--tc16",
     "timeout": 560, "reboot": False,
     "note": "TC15와 동일 주입 + system_log kill 수반, task_capture_boot_log 완료 신호를 "
             "journald 폴링으로 기다림(최대 480s) — 5분+ 소요"},
    {"id": "tc17", "label": "TC17 MessageContext tid 미검증 재현", "flag": "--tc17",
     "timeout": 90, "reboot": False,
     "note": "아직 고쳐지지 않은 결함을 이용한 재현 시험 — cmd_host 응답 토픽에 위조 메시지를 "
             "직접 발행(mosquitto_pub)해 tid 검증 없이 소비/크래시되는지 확인. 정상 판정 관례와 "
             "동일하게 FAIL=결함 재현(현재 코드에서 항상 재현됨), PASS=tid 검증 도입 후. "
             "회귀 세트(빠른 실행/전체 실행)에는 미포함, 이 버튼으로만 단독 실행"},
]

# 대시보드 "선택 실행" 체크박스용 — tc_system_log.sh 의 `--only TC01,TC03,...` 가 지원하는
# TC 목록과 대략적인 개별 소요시간(초). TC10은 reboot로 세션이 끊겨 다른 TC와 한 번에
# 묶을 수 없으므로 선택 대상에서 제외(--tc10-pre/post 전용 버튼만 사용).
# 순서 = tc_system_log.sh 의 표준 실행 순서와 동일.
CUSTOM_TC_TIMEOUTS_SYSTEM_LOG = {
    "TC01": 90, "TC02": 180, "TC03": 90, "TC04": 300, "TC05": 120,
    "TC06": 90, "TC07": 90, "TC08": 90, "TC09": 230,
    "TC11": 420, "TC12": 120, "TC13": 120, "TC14": 180, "TC15": 500, "TC16": 560,
    "TC17": 90,
}

# device_log는 아직 tc-bootstrap 스켈레톤 단계(tc01_placeholder만 존재, --only 미지원) —
# tc-dev로 실제 TC가 채워지면 CATALOG_DEVICE_LOG/CUSTOM_TC_TIMEOUTS_DEVICE_LOG를
# system_log와 같은 패턴으로 채우면 된다. 지금은 뼈대만 등록해 사이드바에서 앱 전환이
# 가능함을 보여준다.
CATALOG_DEVICE_LOG = [
    {"id": "default", "label": "전체 실행 (TC01)", "flag": None,
     "timeout": 60, "reboot": False,
     "note": "스켈레톤 단계 — tc-dev로 실제 TC 구현 필요 (tc01_placeholder만 존재)"},
]
CUSTOM_TC_TIMEOUTS_DEVICE_LOG = {}  # --only 플래그 미지원 — 선택 실행 UI는 비어있으면 자동 숨김

# 아래 8개 앱(update_monitor ~ energy_monitor)은 AC Gen2 TestCase.xlsx "Unified Edge
# Platform" 카테고리 기반으로 tc-plan/dev 에이전트가 신규 작성(2026-08-10), DUT 실기
# 검증 및 --only 선택 실행 지원 추가(2026-08-11). reboot:True는 실제로 SSH 세션이
# 끊기는 재부팅이라 판단해 -pre/-post로 분리한 TC에만 붙어있다 — 파괴적 컨테이너
# 재시작(kill -9, bin 변조 등)이라도 스크립트 안에서 자체 polling으로 끝나면
# reboot:False로 둔 것(단일 SSH 세션 내에서 완결). CUSTOM_TC_TIMEOUTS_*에는 reboot
# 전용 -pre/-post TC를 제외한 나머지만 담아 선택 실행 대상으로 노출한다.

CATALOG_UPDATE_MONITOR = [
    {"id": "default", "label": "전체 실행 (TC01~TC12, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 Batch Update 요청 프로토콜", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": "수락/거부/우선순위 정렬"},
    {"id": "tc02", "label": "TC02 ADU Step Manifest 단계별 상태 전이", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "is-installed/download/install/apply"},
    {"id": "tc03", "label": "TC03 ADU Agent 로그 기반 연동 상태 확인", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 Firmware Download 세션 영속화 및 프로세스 재시작 후 Resume", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc05", "label": "TC05 리소스 사전 점검 설정", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 소스 내 미확인"},
    {"id": "tc06", "label": "TC06 다운로드 중 네트워크 단절 시 재시도", "flag": "--tc06",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc07", "label": "TC07 Manifest SHA256 해시 불일치 시 다운로드 차단", "flag": "--tc07",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc08", "label": "TC08 .swu 서명/AES 키 훼손 파일 업데이트 차단", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": "수동 준비물 필요"},
    {"id": "tc09", "label": "TC09 sw-description HW 호환성(hwrevision) 검사", "flag": "--tc09",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc10", "label": "TC10 업데이트 진행률 MQTT 알림", "flag": "--tc10",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc11", "label": "TC11 Docker 이미지 기반 배포 PRECHECK 및 컨테이너/볼륨 상태 확인", "flag": "--tc11",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc12", "label": "TC12 자동화 불가 항목 목록", "flag": "--tc12",
     "timeout": 180, "reboot": False, "note": "클라우드 OTA 전체 흐름 / Web HMI 수동 조작"},
]
CUSTOM_TC_TIMEOUTS_UPDATE_MONITOR = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180, "TC12": 180,
}

CATALOG_SYS_MANAGER = [
    {"id": "default", "label": "전체 실행 (TC01~TC16, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 악성코드 점검(chkrootkit) 매일 02:00 자동 실행", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc02", "label": "TC02 방화벽(iptables) 규칙 조회", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "Open Ports 문서 대조는 범위 밖"},
    {"id": "tc03", "label": "TC03 System Time 관리", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": "NTP on/off 및 상태 조회"},
    {"id": "tc04", "label": "TC04 System Info 모니터링", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": "get_system_info"},
    {"id": "tc05", "label": "TC05 EEPROM Nameplate 관리", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": "get/set_eeprom_info"},
    {"id": "tc06", "label": "TC06 Internet 연결 관리", "flag": "--tc06",
     "timeout": 180, "reboot": False, "note": "get_internet_status"},
    {"id": "tc07", "label": "TC07 Host Network Interface 관리", "flag": "--tc07",
     "timeout": 180, "reboot": False, "note": "조회 + DHCP 설정 + 서비스 재시작"},
    {"id": "tc08", "label": "TC08 Host Agent와의 연동", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": "UDS 재연결 + LED 상태 조회"},
    {"id": "tc09", "label": "TC09 Host Agent Event Logging", "flag": "--tc09",
     "timeout": 180, "reboot": False, "note": "whitelist 차단 로그"},
    {"id": "tc10", "label": "TC10 Host Command 지원", "flag": "--tc10",
     "timeout": 180, "reboot": False, "note": "cmd_host 화이트리스트 명령군"},
    {"id": "tc11", "label": "TC11 HW별 Configuration 지원", "flag": "--tc11",
     "timeout": 180, "reboot": False, "note": "get_platform_info"},
    {"id": "tc12-pre", "label": "TC12-pre Safe Reboot", "flag": "--tc12-pre",
     "timeout": 180, "reboot": True, "note": "request_system_reboot → sys_manager → host_agent"},
    {"id": "tc12-post", "label": "TC12-post Safe Reboot", "flag": "--tc12-post",
     "timeout": 180, "reboot": False, "note": "request_system_reboot → sys_manager → host_agent"},
    {"id": "tc13", "label": "TC13 LED 밝기 경계값 제어", "flag": "--tc13",
     "timeout": 180, "reboot": False, "note": "sysfs 직접"},
    {"id": "tc14", "label": "TC14 LED 상태 시나리오 (부팅/업데이트/네트워크/클라우드/운영 모드) —", "flag": "--tc14",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 소스 내 일부만 확인"},
    {"id": "tc15", "label": "TC15 LED 제어", "flag": "--tc15",
     "timeout": 180, "reboot": False, "note": "밝기 0~255 + RGB 색상, IPC 경유"},
]
CUSTOM_TC_TIMEOUTS_SYS_MANAGER = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180,
    "TC13": 180, "TC14": 180, "TC15": 180,
}  # TC12는 reboot로 세션이 끊겨 미포함 (--tc12-pre/-post 전용 버튼만 사용)

CATALOG_DB_MANAGER = [
    {"id": "default", "label": "전체 실행 (TC01~TC11, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 Configuration 테이블 생성 및 select_all_records 조회", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc02", "label": "TC02 Configuration 이력 정보 클라우드 전달", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "SyncConfigurationRequest"},
    {"id": "tc03", "label": "TC03 Persistent State 변경 정보 전달", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": "update_records 즉시 반영"},
    {"id": "tc04", "label": "TC04 System Setting 변경 정보 즉시 반영", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": "Log Level"},
    {"id": "tc05", "label": "TC05 Persistent State 부팅 시점 정보 전달", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 로그 태그 불일치"},
    {"id": "tc06-pre", "label": "TC06-pre System Setting 부팅 시점 정보 전달", "flag": "--tc06-pre",
     "timeout": 180, "reboot": True, "note": "Log Level 재부팅 후 유지"},
    {"id": "tc06-post", "label": "TC06-post System Setting 부팅 시점 정보 전달", "flag": "--tc06-post",
     "timeout": 180, "reboot": False, "note": "Log Level 재부팅 후 유지"},
    {"id": "tc07", "label": "TC07 Persistent State 테이블 생성/조회", "flag": "--tc07",
     "timeout": 180, "reboot": False, "note": "select_all_records"},
    {"id": "tc08", "label": "TC08 System Setting 테이블 생성/조회", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": "select_all_records"},
    {"id": "tc09", "label": "TC09 DB 파일 생성/저장 위치 확인", "flag": "--tc09",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc10", "label": "TC10 Register Map 최신 정보 Cloud Sync", "flag": "--tc10",
     "timeout": 180, "reboot": False, "note": "SyncRegisterMapRequest"},
]
CUSTOM_TC_TIMEOUTS_DB_MANAGER = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180,
}  # TC06은 reboot로 세션이 끊겨 미포함 (--tc06-pre/-post 전용 버튼만 사용)

CATALOG_DEVICE_MANAGER = [
    {"id": "default", "label": "전체 실행 (TC01~TC05, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01-pre", "label": "TC01-pre configuration.json 신규 Protocol 추가 → 코드 수정 없이 연결 시도 확인", "flag": "--tc01-pre",
     "timeout": 180, "reboot": True, "note": None},
    {"id": "tc01-post", "label": "TC01-post configuration.json 신규 Protocol 추가 → 코드 수정 없이 연결 시도 확인", "flag": "--tc01-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc02-pre", "label": "TC02-pre configuration.json / register_map.json 부재 시 부팅 동작", "flag": "--tc02-pre",
     "timeout": 180, "reboot": True, "note": "검토 필요 — 원본 로그 태그 불일치"},
    {"id": "tc02-post", "label": "TC02-post configuration.json / register_map.json 부재 시 부팅 동작", "flag": "--tc02-post",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 원본 로그 태그 불일치"},
    {"id": "tc03-pre", "label": "TC03-pre configuration.json / register_map.json 정상 로드 확인", "flag": "--tc03-pre",
     "timeout": 180, "reboot": True, "note": None},
    {"id": "tc03-post", "label": "TC03-post configuration.json / register_map.json 정상 로드 확인", "flag": "--tc03-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 주기적 Read Data 처리", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 실제 폴링 루프는 energy_link 소관"},
    {"id": "tc05", "label": "TC05 자동화 불가 / 검토 필요 항목 목록", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": None},
]
CUSTOM_TC_TIMEOUTS_DEVICE_MANAGER = {
    "TC04": 180, "TC05": 180,
}  # TC01~03은 reboot로 세션이 끊겨 미포함 (--tcNN-pre/-post 전용 버튼만 사용)

CATALOG_AZURE_CONNECTOR = [
    {"id": "default", "label": "전체 실행 (TC01~TC12, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 TLS 1.2 이상 지원", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 런타임 negotiated 버전 로그 없음"},
    {"id": "tc02", "label": "TC02 Device Provisioning: edge_device_id 설정 및 DPS 등록 트리거", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "로컬 프로토콜 레벨"},
    {"id": "tc03", "label": "TC03 인증서 파일 손상 시 재발급(Re-enrollment) 동작 확인", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 인증서 파일 삭제 시 재발급 동작 확인", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc05", "label": "TC05 인증서 만료 임박 시 Re-Enroll", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 24시간+ 실시간 대기 필요"},
    {"id": "tc06", "label": "TC06 Blob Storage 업로드", "flag": "--tc06",
     "timeout": 180, "reboot": False, "note": "로컬 프로토콜/로그 레벨"},
    {"id": "tc07", "label": "TC07 Message Queueing Logic: Offline 상태에서 Telemetry 축적", "flag": "--tc07",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc08", "label": "TC08 Message Queueing Logic: Cloud 재연결 후 Telemetry 재발송", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc09", "label": "TC09 서버(C2D) 메시지 수신 로그 확인", "flag": "--tc09",
     "timeout": 180, "reboot": False, "note": "반자동 — 발신은 Azure IoT Explorer 수동 조작 필요"},
    {"id": "tc10", "label": "TC10 Azure IoT Hub 연결 상태 모니터링", "flag": "--tc10",
     "timeout": 180, "reboot": False, "note": "연결 확인 / 연결 해제 재현"},
    {"id": "tc11", "label": "TC11 X.509 인증서 파일 존재 및 유효성 검사", "flag": "--tc11",
     "timeout": 180, "reboot": False, "note": None},
]
CUSTOM_TC_TIMEOUTS_AZURE_CONNECTOR = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180,
}

CATALOG_EDGE_RUNTIME = [
    {"id": "default", "label": "전체 실행 (TC01~TC14, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 Application Reboot 요청 시 전체 Application 정상 종료", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": "파괴적: 컨테이너 재시작"},
    {"id": "tc02", "label": "TC02 Application Reboot 요청 시 reboot_info.txt 기록", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "TC01과 동일 트리거"},
    {"id": "tc03", "label": "TC03 부팅 시 uniep Application 실행 순서", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": "order 기반 fork/Ready 시퀀스, 파괴적"},
    {"id": "tc04", "label": "TC04 전체 Application Ready 시 All App Ready 알림 + LED 녹색 전환", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": "파괴적"},
    {"id": "tc05", "label": "TC05 일부 Application Ready 실패 시 60초 Boot Watchdog 타임아웃 → LED 적색 + 컨테이너 재시작", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": "파괴적, bin 변조"},
    {"id": "tc06", "label": "TC06 DB Manager Ready 실패 시 10초 초기 서비스 타이머 타임아웃 → 컨테이너 재시작", "flag": "--tc06",
     "timeout": 180, "reboot": False, "note": "파괴적, bin 변조"},
    {"id": "tc07", "label": "TC07 Heartbeat 수신 시 Watchdog 리스트 갱신 로그", "flag": "--tc07",
     "timeout": 180, "reboot": False, "note": "Debug 로그 레벨 필요"},
    {"id": "tc08", "label": "TC08 Heartbeat 9초 미수신(Application Crash 포함) 시 Watchdog 재부팅", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": "파괴적, kill -9"},
    {"id": "tc09", "label": "TC09 최초 Watchdog 점검(부팅 후 60초 시점) 관리 앱 총계 로그", "flag": "--tc09",
     "timeout": 180, "reboot": False, "note": "파괴적, TC04와 캡처 세션 공유 가능"},
    {"id": "tc10", "label": "TC10 uniep_applist.conf 파일 형식 검증", "flag": "--tc10",
     "timeout": 180, "reboot": False, "note": "비파괴적"},
    {"id": "tc11", "label": "TC11 devapp 오버라이드로 Application 실행 순서 변경", "flag": "--tc11",
     "timeout": 180, "reboot": False, "note": "파괴적, conf 변경 + 컨테이너 재시작"},
    {"id": "tc12", "label": "TC12 실행 중인 필수 Application 프로세스 목록 확인", "flag": "--tc12",
     "timeout": 180, "reboot": False, "note": "비파괴적"},
    {"id": "tc13", "label": "TC13 Configuration 기반 Project(non-uniep) Application 실행", "flag": "--tc13",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 대상 conf 사전 확인"},
    {"id": "tc14", "label": "TC14 자동화 불가 항목 목록", "flag": "--tc14",
     "timeout": 180, "reboot": False, "note": None},
]
CUSTOM_TC_TIMEOUTS_EDGE_RUNTIME = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180, "TC12": 180,
    "TC13": 180, "TC14": 180,
}

CATALOG_WEB_INTERFACE = [
    {"id": "default", "label": "전체 실행 (TC01~TC15, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 API 문서 제공", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": "Swagger/OpenAPI 문서 서버"},
    {"id": "tc02", "label": "TC02 MQTT Disconnect 시 Error Response 처리", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 원본 Action 미기재"},
    {"id": "tc03", "label": "TC03 MQTT-HTTP Bridge 지원", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 로깅 보안 (민감 정보 마스킹)", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 마스킹 로직 위치 미확인"},
    {"id": "tc05", "label": "TC05 JWT 토큰 검증", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc06", "label": "TC06 경로 순회 공격 방지", "flag": "--tc06",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc07", "label": "TC07 Injection 공격 방지", "flag": "--tc07",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc08", "label": "TC08 CORS", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc09", "label": "TC09 SSL 암호화 스위트", "flag": "--tc09",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc10", "label": "TC10 TLS 1.3 강제", "flag": "--tc10",
     "timeout": 180, "reboot": False, "note": "구버전 TLS 거부"},
    {"id": "tc11", "label": "TC11 Content-Type 검증", "flag": "--tc11",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc12", "label": "TC12 Rate Limit", "flag": "--tc12",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc13", "label": "TC13 XSS", "flag": "--tc13",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc14", "label": "TC14 HSTS", "flag": "--tc14",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc15", "label": "TC15 Log Level Control", "flag": "--tc15",
     "timeout": 180, "reboot": False, "note": None},
]
CUSTOM_TC_TIMEOUTS_WEB_INTERFACE = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180, "TC12": 180,
    "TC13": 180, "TC14": 180, "TC15": 180,
}

CATALOG_ENERGY_MONITOR = [
    {"id": "default", "label": "전체 실행 (TC01~TC08, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 Report 항목 필터링", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc02", "label": "TC02 Azure IoT Hub 전송", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc03", "label": "TC03 평균 값 계산", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 전송 주기 조절", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": "Flag — 요구사항의 `samplingRate` 필드가 코드에 없음"},
    {"id": "tc05", "label": "TC05 소수점 자릿수 조정 검증", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc06", "label": "TC06 누적값 계산", "flag": "--tc06",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc07", "label": "TC07 Telemetry 수신", "flag": "--tc07",
     "timeout": 180, "reboot": False, "note": "IPC 프로토콜 레벨"},
    {"id": "tc08", "label": "TC08 자동화 불가 항목 목록", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": "Azure IoT Hub Explorer 클라우드 포털 확인"},
]
CUSTOM_TC_TIMEOUTS_ENERGY_MONITOR = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180,
    "TC06": 180, "TC07": 180, "TC08": 180,
}


def _register_app(app_id: str, label: str, script_name: str, catalog: list,
                   custom_tc_timeouts: dict, runs_dirname: str, status_filename: str) -> dict:
    tc_dir = REPO_ROOT / "tcs" / app_id
    runs_dir = BASE_DIR / runs_dirname
    runs_dir.mkdir(exist_ok=True)
    return {
        "id": app_id,
        "label": label,
        "tc_script": tc_dir / script_name,
        "remote_script": f"/tmp/{script_name}",
        "catalog": catalog,
        "catalog_map": {c["id"]: c for c in catalog},
        "custom_tc_timeouts": custom_tc_timeouts,
        "custom_tc_order": list(custom_tc_timeouts.keys()),
        "runs_dir": runs_dir,
        "status_file": BASE_DIR / status_filename,
    }


# system_log는 기존 배포와 동일한 경로(runs/, latest_status.json)를 그대로 써서
# 기존 실행 이력을 마이그레이션 없이 유지한다. 새 앱은 각자 이름이 붙은 디렉토리/파일을 쓴다.
APPS = {
    "system_log": _register_app(
        "system_log", "system_log", "tc_system_log.sh",
        CATALOG_SYSTEM_LOG, CUSTOM_TC_TIMEOUTS_SYSTEM_LOG,
        runs_dirname="runs", status_filename="latest_status.json",
    ),
    "device_log": _register_app(
        "device_log", "device_log", "tc_device_log.sh",
        CATALOG_DEVICE_LOG, CUSTOM_TC_TIMEOUTS_DEVICE_LOG,
        runs_dirname="runs_device_log", status_filename="latest_status_device_log.json",
    ),
    "update_monitor": _register_app(
        "update_monitor", "update_monitor", "tc_update_monitor.sh",
        CATALOG_UPDATE_MONITOR, CUSTOM_TC_TIMEOUTS_UPDATE_MONITOR,
        runs_dirname="runs_update_monitor", status_filename="latest_status_update_monitor.json",
    ),
    "sys_manager": _register_app(
        "sys_manager", "sys_manager", "tc_sys_manager.sh",
        CATALOG_SYS_MANAGER, CUSTOM_TC_TIMEOUTS_SYS_MANAGER,
        runs_dirname="runs_sys_manager", status_filename="latest_status_sys_manager.json",
    ),
    "db_manager": _register_app(
        "db_manager", "db_manager", "tc_db_manager.sh",
        CATALOG_DB_MANAGER, CUSTOM_TC_TIMEOUTS_DB_MANAGER,
        runs_dirname="runs_db_manager", status_filename="latest_status_db_manager.json",
    ),
    "device_manager": _register_app(
        "device_manager", "device_manager", "tc_device_manager.sh",
        CATALOG_DEVICE_MANAGER, CUSTOM_TC_TIMEOUTS_DEVICE_MANAGER,
        runs_dirname="runs_device_manager", status_filename="latest_status_device_manager.json",
    ),
    "azure_connector": _register_app(
        "azure_connector", "azure_connector", "tc_azure_connector.sh",
        CATALOG_AZURE_CONNECTOR, CUSTOM_TC_TIMEOUTS_AZURE_CONNECTOR,
        runs_dirname="runs_azure_connector", status_filename="latest_status_azure_connector.json",
    ),
    "edge_runtime": _register_app(
        "edge_runtime", "edge_runtime", "tc_edge_runtime.sh",
        CATALOG_EDGE_RUNTIME, CUSTOM_TC_TIMEOUTS_EDGE_RUNTIME,
        runs_dirname="runs_edge_runtime", status_filename="latest_status_edge_runtime.json",
    ),
    "web_interface": _register_app(
        "web_interface", "web_interface", "tc_web_interface.sh",
        CATALOG_WEB_INTERFACE, CUSTOM_TC_TIMEOUTS_WEB_INTERFACE,
        runs_dirname="runs_web_interface", status_filename="latest_status_web_interface.json",
    ),
    "energy_monitor": _register_app(
        "energy_monitor", "energy_monitor", "tc_energy_monitor.sh",
        CATALOG_ENERGY_MONITOR, CUSTOM_TC_TIMEOUTS_ENERGY_MONITOR,
        runs_dirname="runs_energy_monitor", status_filename="latest_status_energy_monitor.json",
    ),
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
current_run = {"run_id": None}


class RunRequest(BaseModel):
    app_id: str = DEFAULT_APP_ID
    tc_id: str
    channel: str = "ssh"
    tc_ids: Optional[List[str]] = None  # tc_id == "custom" 일 때만 사용 — 선택된 TC 목록(예: ["TC01","TC03"])


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
        _, _, cases = _parse_results(log_path.read_text(errors="replace"))
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


async def _run_ssh(app_cfg: dict, entry: dict, log_path: Path, run_dir: Path) -> "int | None":
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
        try:
            exit_code = await asyncio.wait_for(run_proc.wait(), timeout=entry["timeout"])
        except asyncio.TimeoutError:
            run_proc.kill()
            await run_proc.wait()
            logf.write(b"\n[DASHBOARD] TIMEOUT - \xed\x94\x84\xeb\xa1\x9c\xec\x84\xb8\xec\x8a\xa4 \xea\xb0\x95\xec\xa0\x9c \xec\xa2\x85\xeb\xa3\x8c\n")
            exit_code = None

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


async def _run_ssh_full_with_tc10(app_cfg: dict, entry: dict, log_path: Path, run_dir: Path) -> "int | None":
    """--full(TC01~09,11~16) 뒤에 TC10(pre-reboot-post)까지 같은 run으로 이어 붙인다.

    TC10은 reboot로 SSH 세션이 끊겨 단일 ssh 호출 안에 넣을 수 없다 — 이 함수가
    --full 실행 → --tc10-pre 발사(세션 끊김) → ping/ssh 폴링으로 재부팅 완료 대기 →
    스크립트 재전송(재부팅 후 /tmp ramdisk 휘발) → --tc10-post 순으로 직접
    오케스트레이션한다. 세 단계 모두 같은 output.log에 이어 쓴다 — run_tc()의
    _parse_results가 output.log 전체를 한 번에 스캔해 [PASS]/[FAIL]을 case_id로
    모으므로, 여기선 병합 로직 없이 그냥 이어 쓰기만 하면 최종 PASS/FAIL이 자동 합산된다.
    sl_journal.log만 예외적으로 _stop_journal_capture가 매 단계 덮어쓰므로, 여기서는
    단계별로 직접 수거해 마지막에 한 번에 합쳐 쓴다.
    """
    accumulated_sl_lines: list = []

    async def _run_step(step_entry: dict, append: bool) -> "int | None":
        await _ensure_fresh_ssh_master()
        tc_script = app_cfg["tc_script"]
        remote_script = app_cfg["remote_script"]
        with open(log_path, "ab" if append else "wb") as logf:
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
            try:
                exit_code = await asyncio.wait_for(run_proc.wait(), timeout=step_entry["timeout"])
            except asyncio.TimeoutError:
                run_proc.kill()
                await run_proc.wait()
                logf.write(b"\n[DASHBOARD] TIMEOUT - \xed\x94\x84\xeb\xa1\x9c\xec\x84\xb8\xec\x8a\xa4 \xea\xb0\x95\xec\xa0\x9c \xec\xa2\x85\xeb\xa3\x8c\n")
                exit_code = None

            # tc10-pre는 reboot로 세션이 끊기며 journalctl -f 프로세스도 같이 죽는다 —
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

    # 1단계: TC01~09, 11~16
    exit_code = await _run_step({**entry, "flag": "--full"}, append=False)

    # 2단계: TC10-pre (reboot 발생 — 세션이 끊기며 exit_code가 비정상/None일 수 있음, 정상 동작)
    with open(log_path, "ab") as logf:
        logf.write("\n\n=== TC10 (reboot) 자동 진행 ===\n".encode())
    await _run_step(app_cfg["catalog_map"]["tc10-pre"], append=True)

    # 3단계: 재부팅 완료 대기
    with open(log_path, "ab") as logf:
        rebooted_ok = await _wait_for_dut_reboot(logf)

    if not rebooted_ok:
        with open(log_path, "ab") as logf:
            logf.write("\n[DASHBOARD ERROR] DUT 재부팅 확인 실패 - TC10-post 스킵\n".encode())
        if accumulated_sl_lines:
            (run_dir / "sl_journal.log").write_text("".join(accumulated_sl_lines))
        return None

    # 4단계: TC10-post
    exit_code = await _run_step(app_cfg["catalog_map"]["tc10-post"], append=True)

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
        "exit_code": None,
    }
    _write_meta(run_dir, meta)

    try:
        if channel == "serial":
            exit_code = await _run_serial(app_cfg, entry, log_path)
        elif entry.get("chain_tc10"):
            exit_code = await _run_ssh_full_with_tc10(app_cfg, entry, log_path, run_dir)
        else:
            exit_code = await _run_ssh(app_cfg, entry, log_path, run_dir)

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
            _update_latest_status(app_cfg["status_file"], run_id, meta, cases)
    except Exception as e:
        meta["status"] = "error"
        meta["finished_at"] = datetime.now().isoformat(timespec="seconds")
        _write_meta(run_dir, meta)
        with open(log_path, "ab") as logf:
            logf.write(f"\n[DASHBOARD ERROR] {e}\n".encode())
    finally:
        current_run["run_id"] = None
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
            pass_n, fail_n, cases = _parse_results(text)
            finished_at = (
                datetime.fromtimestamp(log_path.stat().st_mtime).isoformat(timespec="seconds")
                if log_path.exists() else datetime.now().isoformat(timespec="seconds")
            )
            entry = app_cfg["catalog_map"].get(meta["tc_id"], {})
            meta["pass"], meta["fail"] = pass_n, fail_n
            meta["finished_at"] = finished_at
            if SUMMARY_RE.search(text):
                meta["exit_code"] = 0 if fail_n == 0 else 1
                meta["status"] = "rebooted" if entry.get("reboot") else ("fail" if fail_n > 0 else "pass")
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
    run_dir = _get_app(app_id)["runs_dir"] / run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        raise HTTPException(404, "run not found")
    meta = json.loads(meta_path.read_text())
    log_path = run_dir / "output.log"
    log_text = _read_clean_log(log_path)
    _, _, cases = _parse_results(log_text)
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
    _, _, cases = _parse_results(log_text)
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
        # verify_timer_loop_started + (필요시) setup_rotate 오버헤드 여유분.
        timeout = 90 + sum(custom_timeouts[t] for t in ordered)
        entry = {
            "id": "custom",
            "label": f"선택 실행 ({', '.join(ordered)})",
            "flag": f"--only {','.join(ordered)}",
            "timeout": timeout,
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


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    return (STATIC_DIR / "index.html").read_text()
