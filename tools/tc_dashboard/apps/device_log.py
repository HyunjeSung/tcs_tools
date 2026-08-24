"""device_log 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

tc_device_log.md(TC01~TC27, 연번) 기반으로 qa 에이전트가 전체 구현 완료(2026-08-21).
버튼은 빠른 실행/전체 실행 두 개만 노출하고 개별 TC는 모두 "선택 실행" 드롭다운으로
옮겼다(2026-08-21, tc_device_log.sh에 --only/--full 파싱 추가).
재부팅 4사이클(TC06/07, TC15, TC20, TC26)은 --only로 못 묶어(세션이 끊김)
REBOOT_TC_MAP을 통해 "선택 실행"에서 골라도 대시보드가 -pre/-post를 직접 체이닝한다 —
"전체 실행"의 chain_reboot_pairs와 같은 오케스트레이션(server._run_ssh_full_with_reboots)을
재사용.

[2026-08-24 갱신] tc_device_log.md/.sh가 결번(TC06/TC15/TC17)을 정리하고 TC01~TC27로
번호를 당겼다 — 이 파일의 CATALOG/HIDDEN_ENTRIES/CUSTOM_TC_TIMEOUTS/REBOOT_TC_MAP을
전부 새 번호에 맞춰 재작성했다(기존 값은 재부팅 사이클 대응 관계 기준으로 그대로 이전).
"""

ID = "device_log"
LABEL = "device_log"
SCRIPT_NAME = "tc_device_log.sh"
RUNS_DIRNAME = "runs_device_log"
STATUS_FILENAME = "latest_status_device_log.json"

CATALOG = [
    {"id": "default", "label": "빠른 실행 (TC01~04,08,10~14,16,17,21~25,27)", "flag": None,
     "timeout": 3600, "reboot": False,
     "note": "재부팅 4사이클(06/07,15,20,26)·6시간+ 대기(05)·정책수정+재시작(09)·시스템시각변경(18,19)은 "
             "미포함 — 아래 선택 실행(개별 TC) 또는 전체 실행(TC01~27)으로 실행"},
    {"id": "full", "label": "전체 실행 (TC01~27)", "flag": "--full",
     "timeout": 30600, "reboot": False,
     "chain_reboot_pairs": [("tc06-pre", "tc06-post"), ("tc15-pre", "tc15-post"),
                            ("tc20-pre", "tc20-post"), ("tc26-pre", "tc26-post")],
     "note": "TC01~05,08~14,16~19,21~25,27을 --full로 순서대로 실행한 뒤 재부팅 4사이클(TC06/07→TC15→"
             "TC20→TC26)까지 이 대시보드가 직접 이어서 진행 — SSH 세션이 reboot로 끊기는 구간은 "
             "ping/ssh 폴링으로 재접속을 기다렸다가 자동 재개한다(수동 -pre/-post 클릭 불필요). "
             "TC05(6시간+5분 자연 경과 대기)가 전체 소요를 지배해 총 7~8시간+ 소요. TC18/19는 시스템 "
             "시각을 임시 변경(원복 포함), TC26는 파괴적(factory_reset — /edge/log/eol, device_log, "
             "toupload/device_log 전체 삭제)이라 항상 맨 마지막에 실행된다. 이 버튼 실행 중에는 다른 "
             "TC를 동시에 돌릴 수 없다"},
]

# 카탈로그(버튼)에는 안 보이지만 catalog_map 조회용으로만 쓰는 항목 — 전체 실행/선택 실행이
# 재부팅 TC를 고를 때 chain_reboot_pairs가 이 id로 pre/post 엔트리를 찾아 체이닝한다.
HIDDEN_ENTRIES = [
    {"id": "tc06-pre", "label": "TC06/07-pre 재부팅 후 로깅 재개(동일 파일 이어쓰기 + 빈 행 삽입)", "flag": "--tc06-pre",
     "timeout": 90, "reboot": True, "note": "TC07(빈 행 삽입)도 같은 사이클에서 함께 검증"},
    {"id": "tc06-post", "label": "TC06/07-post 재부팅 후 로깅 재개", "flag": "--tc06-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc15-pre", "label": "TC15-pre 재부팅 후 업로드 재개", "flag": "--tc15-pre",
     "timeout": 90, "reboot": True, "note": None},
    {"id": "tc15-post", "label": "TC15-post 재부팅 후 업로드 재개", "flag": "--tc15-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc20-pre", "label": "TC20-pre 재부팅 후 업로드 설정 파일(logcount.json) 유지", "flag": "--tc20-pre",
     "timeout": 90, "reboot": True, "note": None},
    {"id": "tc20-post", "label": "TC20-post 재부팅 후 업로드 설정 파일(logcount.json) 유지", "flag": "--tc20-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc26-pre", "label": "TC26-pre Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제", "flag": "--tc26-pre",
     "timeout": 90, "reboot": True, "note": "파괴적 — /edge/log/eol, device_log, toupload/device_log 전체 삭제"},
    {"id": "tc26-post", "label": "TC26-post Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제", "flag": "--tc26-post",
     "timeout": 240, "reboot": False, "note": None},
]

# "선택 실행" 드롭다운 목록 — TC01~27 전부 노출. TC06/TC07/TC15/TC20/TC26는
# --only로 못 묶여 값 자체는 쓰이지 않지만(REBOOT_TC_MAP 경로로 분기) 검증/표시용으로
# 채워둔다(대략 pre+post 합).
CUSTOM_TC_TIMEOUTS = {
    "TC01": 120, "TC02": 300, "TC03": 180, "TC04": 90, "TC05": 22500,
    "TC06": 270, "TC07": 270, "TC08": 60, "TC09": 300, "TC10": 180,
    "TC11": 120, "TC12": 150, "TC13": 150, "TC14": 180, "TC15": 270,
    "TC16": 120, "TC17": 120, "TC18": 300,
    # TC21(구 TC24)는 network_block(60s, 온라인 시작 시) + get_log_data 3회(각 <=30+70=100s
    # → 300s) + idle thread 능동 폴링(사이클당 5초, 최대 40사이클=200s, 대상 log_item 전원
    # 관측 시 조기 종료)로 재작성됐다(tc_device_log.sh tc21_round_robin()). 조기 종료 덕에
    # 실제 소요는 대개 이보다 짧지만, 최악의 경우(60+300+200=560s대)에도 여유가 있도록
    # 기존 780s 타임아웃을 그대로 유지한다.
    "TC19": 300, "TC20": 270, "TC21": 780, "TC22": 90, "TC23": 300,
    "TC24": 90, "TC25": 180, "TC26": 330, "TC27": 15,
}

# "full"(전체 실행)에는 TC05(6시간+5분 동안 중간 출력이 전혀 없는 단일 sleep)가 포함돼
# server.py의 SSH 좀비-채널 stall guard 기본값(900s)으로는 오탐(false stall)한다 —
# TC05 자체 예상 소요를 넉넉히 웃도는 값으로 오버라이드한다.
next(e for e in CATALOG if e["id"] == "full")["stall_timeout"] = max(CUSTOM_TC_TIMEOUTS.values()) + 1200

# "선택 실행"에서 이 TC를 고르면 --only가 아니라 -pre/-post 재부팅 체이닝으로 실행한다
# (server.api_run의 custom 분기 참고). TC07은 TC06과 같은 재부팅 사이클을 공유.
REBOOT_TC_MAP = {
    "TC06": ("tc06-pre", "tc06-post"),
    "TC07": ("tc06-pre", "tc06-post"),
    "TC15": ("tc15-pre", "tc15-post"),
    "TC20": ("tc20-pre", "tc20-post"),
    "TC26": ("tc26-pre", "tc26-post"),
}
