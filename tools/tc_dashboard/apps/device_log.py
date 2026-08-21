"""device_log 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

tc_device_log.md(TC01~TC30, TC06/TC27 검토 중 삭제로 TC06 결번) 기반으로 qa 에이전트가
전체 구현 완료(2026-08-21). 버튼은 빠른 실행/전체 실행 두 개만 노출하고 개별 TC는 모두
"선택 실행" 드롭다운으로 옮겼다(2026-08-21, tc_device_log.sh에 --only/--full 파싱 추가).
재부팅 4사이클(TC07/08, TC18, TC23, TC29)은 --only로 못 묶어(세션이 끊김)
REBOOT_TC_MAP을 통해 "선택 실행"에서 골라도 대시보드가 -pre/-post를 직접 체이닝한다 —
"전체 실행"의 chain_reboot_pairs와 같은 오케스트레이션(server._run_ssh_full_with_reboots)을
재사용.
"""

ID = "device_log"
LABEL = "device_log"
SCRIPT_NAME = "tc_device_log.sh"
RUNS_DIRNAME = "runs_device_log"
STATUS_FILENAME = "latest_status_device_log.json"

CATALOG = [
    {"id": "default", "label": "빠른 실행 (TC01~04,09,11~17,19,20,24~28,30)", "flag": None,
     "timeout": 3600, "reboot": False,
     "note": "재부팅 4사이클(07/08,18,23,29)·6시간+ 대기(05)·정책수정+재시작(10)·시스템시각변경(21,22)은 "
             "미포함 — 아래 선택 실행(개별 TC) 또는 전체 실행(TC01~30)으로 실행"},
    {"id": "full", "label": "전체 실행 (TC01~30)", "flag": "--full",
     "timeout": 30600, "reboot": False,
     "chain_reboot_pairs": [("tc07-pre", "tc07-post"), ("tc18-pre", "tc18-post"),
                            ("tc23-pre", "tc23-post"), ("tc29-pre", "tc29-post")],
     "note": "TC01~05,09~17,19~22,24~28,30을 --full로 순서대로 실행한 뒤 재부팅 4사이클(TC07/08→TC18→"
             "TC23→TC29)까지 이 대시보드가 직접 이어서 진행 — SSH 세션이 reboot로 끊기는 구간은 "
             "ping/ssh 폴링으로 재접속을 기다렸다가 자동 재개한다(수동 -pre/-post 클릭 불필요). "
             "TC05(6시간+5분 자연 경과 대기)가 전체 소요를 지배해 총 7~8시간+ 소요. TC21/22는 시스템 "
             "시각을 임시 변경(원복 포함), TC29는 파괴적(factory_reset — /edge/log/eol, device_log, "
             "toupload/device_log 전체 삭제)이라 항상 맨 마지막에 실행된다. 이 버튼 실행 중에는 다른 "
             "TC를 동시에 돌릴 수 없다"},
]

# 카탈로그(버튼)에는 안 보이지만 catalog_map 조회용으로만 쓰는 항목 — 전체 실행/선택 실행이
# 재부팅 TC를 고를 때 chain_reboot_pairs가 이 id로 pre/post 엔트리를 찾아 체이닝한다.
HIDDEN_ENTRIES = [
    {"id": "tc07-pre", "label": "TC07/08-pre 재부팅 후 로깅 재개(동일 파일 이어쓰기 + 빈 행 삽입)", "flag": "--tc07-pre",
     "timeout": 90, "reboot": True, "note": "TC08(빈 행 삽입)도 같은 사이클에서 함께 검증"},
    {"id": "tc07-post", "label": "TC07/08-post 재부팅 후 로깅 재개", "flag": "--tc07-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc18-pre", "label": "TC18-pre 재부팅 후 업로드 재개", "flag": "--tc18-pre",
     "timeout": 90, "reboot": True, "note": None},
    {"id": "tc18-post", "label": "TC18-post 재부팅 후 업로드 재개", "flag": "--tc18-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc23-pre", "label": "TC23-pre 재부팅 후 업로드 설정 파일(logcount.json) 유지", "flag": "--tc23-pre",
     "timeout": 90, "reboot": True, "note": None},
    {"id": "tc23-post", "label": "TC23-post 재부팅 후 업로드 설정 파일(logcount.json) 유지", "flag": "--tc23-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc29-pre", "label": "TC29-pre Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제", "flag": "--tc29-pre",
     "timeout": 90, "reboot": True, "note": "파괴적 — /edge/log/eol, device_log, toupload/device_log 전체 삭제"},
    {"id": "tc29-post", "label": "TC29-post Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제", "flag": "--tc29-post",
     "timeout": 240, "reboot": False, "note": None},
]

# "선택 실행" 드롭다운 목록 — TC01~30(TC06 결번) 전부 노출. TC07/TC08/TC18/TC23/TC29는
# --only로 못 묶여 값 자체는 쓰이지 않지만(REBOOT_TC_MAP 경로로 분기) 검증/표시용으로
# 채워둔다(대략 pre+post 합).
CUSTOM_TC_TIMEOUTS = {
    "TC01": 120, "TC02": 300, "TC03": 180, "TC04": 90, "TC05": 22500,
    "TC07": 270, "TC08": 270, "TC09": 60, "TC10": 300, "TC11": 180,
    "TC12": 120, "TC13": 150, "TC14": 150, "TC15": 180, "TC16": 180,
    "TC17": 150, "TC18": 270, "TC19": 120, "TC20": 120, "TC21": 300,
    "TC22": 300, "TC23": 270, "TC24": 300, "TC25": 90, "TC26": 300,
    "TC27": 90, "TC28": 180, "TC29": 330, "TC30": 15,
}

# "선택 실행"에서 이 TC를 고르면 --only가 아니라 -pre/-post 재부팅 체이닝으로 실행한다
# (server.api_run의 custom 분기 참고). TC08은 TC07과 같은 재부팅 사이클을 공유.
REBOOT_TC_MAP = {
    "TC07": ("tc07-pre", "tc07-post"),
    "TC08": ("tc07-pre", "tc07-post"),
    "TC18": ("tc18-pre", "tc18-post"),
    "TC23": ("tc23-pre", "tc23-post"),
    "TC29": ("tc29-pre", "tc29-post"),
}
