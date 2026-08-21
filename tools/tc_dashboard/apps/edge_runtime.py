"""edge_runtime 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
"""

ID = "edge_runtime"
LABEL = "edge_runtime"
SCRIPT_NAME = "tc_edge_runtime.sh"
RUNS_DIRNAME = "runs_edge_runtime"
STATUS_FILENAME = "latest_status_edge_runtime.json"

CATALOG = [
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
    {"id": "tc13", "label": "TC13 [SKIP] Configuration 기반 Project(non-uniep) Application 실행", "flag": "--tc13",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 대상 conf 사전 확인"},
    {"id": "tc14", "label": "TC14 자동화 불가 항목 목록", "flag": "--tc14",
     "timeout": 180, "reboot": False, "note": None},
]
CUSTOM_TC_TIMEOUTS = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180, "TC12": 180,
    "TC13": 180, "TC14": 180,
}
