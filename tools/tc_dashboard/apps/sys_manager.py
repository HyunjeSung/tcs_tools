"""sys_manager 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
reboot:True는 실제로 SSH 세션이 끊기는 재부팅이라 판단해 -pre/-post로 분리한 TC에만
붙어있다 — 파괴적 컨테이너 재시작(kill -9, bin 변조 등)이라도 스크립트 안에서 자체
polling으로 끝나면 reboot:False로 둔 것(단일 SSH 세션 내에서 완결). CUSTOM_TC_TIMEOUTS
에는 reboot 전용 -pre/-post TC를 제외한 나머지만 담아 선택 실행 대상으로 노출한다.
"""

ID = "sys_manager"
LABEL = "sys_manager"
SCRIPT_NAME = "tc_sys_manager.sh"
RUNS_DIRNAME = "runs_sys_manager"
STATUS_FILENAME = "latest_status_sys_manager.json"

CATALOG = [
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
    {"id": "tc14", "label": "TC14 [SKIP] LED 상태 시나리오 (부팅/업데이트/네트워크/클라우드/운영 모드)", "flag": "--tc14",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 소스 내 일부만 확인"},
    {"id": "tc15", "label": "TC15 LED 제어", "flag": "--tc15",
     "timeout": 180, "reboot": False, "note": "밝기 0~255 + RGB 색상, IPC 경유"},
]
CUSTOM_TC_TIMEOUTS = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180,
    "TC13": 180, "TC14": 180, "TC15": 180,
}  # TC12는 reboot로 세션이 끊겨 미포함 (--tc12-pre/-post 전용 버튼만 사용)
