"""device_manager 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
"""

ID = "device_manager"
LABEL = "device_manager"
SCRIPT_NAME = "tc_device_manager.sh"
RUNS_DIRNAME = "runs_device_manager"
STATUS_FILENAME = "latest_status_device_manager.json"

CATALOG = [
    {"id": "default", "label": "전체 실행 (TC04~TC05만, TC01~TC03은 환경 제약/재부팅으로 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "TC01/TC02는 환경 제약으로 SKIP 전용, TC03은 reboot 수반이라 default에 포함 안 됨 — 각각 아래 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01-pre", "label": "TC01-pre [SKIP] configuration.json 신규 Protocol 추가 → 코드 수정 없이 연결 시도 확인", "flag": "--tc01-pre",
     "timeout": 60, "reboot": False,
     "note": "이 DUT에서 자동화 불가(환경 제약, 2026-08-12 확정) — /edge/app이 호스트에 bind mount 안 돼 파일 수정이 컨테이너 재기동(reboot 포함)을 못 버팀. 버튼을 눌러도 SKIP 안내만 출력하고 reboot는 실행하지 않음. tc_device_manager.md 참고"},
    {"id": "tc01-post", "label": "TC01-post [SKIP] configuration.json 신규 Protocol 추가 → 코드 수정 없이 연결 시도 확인", "flag": "--tc01-post",
     "timeout": 60, "reboot": False, "note": "TC01-pre가 SKIP이므로 실행 대상 없음 — 안내만 출력"},
    {"id": "tc02-pre", "label": "TC02-pre [SKIP] configuration.json / register_map.json 부재 시 부팅 동작", "flag": "--tc02-pre",
     "timeout": 60, "reboot": False,
     "note": "TC01과 동일한 환경 제약으로 SKIP — 버튼을 눌러도 SKIP 안내만 출력하고 reboot는 실행하지 않음. 원본 로그 태그 불일치 검토도 별도 필요"},
    {"id": "tc02-post", "label": "TC02-post [SKIP] configuration.json / register_map.json 부재 시 부팅 동작", "flag": "--tc02-post",
     "timeout": 60, "reboot": False, "note": "TC02-pre가 SKIP이므로 실행 대상 없음 — 안내만 출력"},
    {"id": "tc03-pre", "label": "TC03-pre configuration.json / register_map.json 정상 로드 확인", "flag": "--tc03-pre",
     "timeout": 180, "reboot": True, "note": None},
    {"id": "tc03-post", "label": "TC03-post configuration.json / register_map.json 정상 로드 확인", "flag": "--tc03-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 주기적 Read Data 처리", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 실제 폴링 루프는 energy_link 소관. 2026-08-12 실측: PASS=2/FAIL=1(TC04-2, periodMs=1000 대비 avg_interval_ms=1333)"},
    {"id": "tc05", "label": "TC05 자동화 불가 / 검토 필요 항목 목록", "flag": "--tc05",
     "timeout": 180, "reboot": False, "note": None},
]
CUSTOM_TC_TIMEOUTS = {
    "TC04": 180, "TC05": 180,
}  # TC01/TC02는 환경 제약(SKIP)이라 default 미포함, TC03은 reboot로 세션이 끊겨 미포함
   # (각각 -pre/-post 전용 버튼만 사용)
