"""db_manager 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
reboot:True는 실제로 SSH 세션이 끊기는 재부팅이라 판단해 -pre/-post로 분리한 TC에만
붙어있다. CUSTOM_TC_TIMEOUTS에는 reboot 전용 -pre/-post TC를 제외한 나머지만 담아
선택 실행 대상으로 노출한다.
"""

ID = "db_manager"
LABEL = "db_manager"
SCRIPT_NAME = "tc_db_manager.sh"
RUNS_DIRNAME = "runs_db_manager"
STATUS_FILENAME = "latest_status_db_manager.json"

CATALOG = [
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
    {"id": "tc05", "label": "TC05 [SKIP] Persistent State 부팅 시점 정보 전달", "flag": "--tc05",
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
CUSTOM_TC_TIMEOUTS = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180,
}  # TC06은 reboot로 세션이 끊겨 미포함 (--tc06-pre/-post 전용 버튼만 사용)
