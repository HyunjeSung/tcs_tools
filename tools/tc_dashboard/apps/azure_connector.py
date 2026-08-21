"""azure_connector 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
"""

ID = "azure_connector"
LABEL = "azure_connector"
SCRIPT_NAME = "tc_azure_connector.sh"
RUNS_DIRNAME = "runs_azure_connector"
STATUS_FILENAME = "latest_status_azure_connector.json"

CATALOG = [
    {"id": "default", "label": "전체 실행 (TC01~TC12, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 [SKIP] TLS 1.2 이상 지원", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 런타임 negotiated 버전 로그 없음"},
    {"id": "tc02", "label": "TC02 Device Provisioning: edge_device_id 설정 및 DPS 등록 트리거", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "로컬 프로토콜 레벨"},
    {"id": "tc03", "label": "TC03 인증서 파일 손상 시 재발급(Re-enrollment) 동작 확인", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 인증서 파일 삭제 시 재발급 동작 확인", "flag": "--tc04",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc05", "label": "TC05 [SKIP] 인증서 만료 임박 시 Re-Enroll", "flag": "--tc05",
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
CUSTOM_TC_TIMEOUTS = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180,
}
