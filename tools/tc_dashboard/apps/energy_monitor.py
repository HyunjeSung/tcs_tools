"""energy_monitor 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
"""

ID = "energy_monitor"
LABEL = "energy_monitor"
SCRIPT_NAME = "tc_energy_monitor.sh"
RUNS_DIRNAME = "runs_energy_monitor"
STATUS_FILENAME = "latest_status_energy_monitor.json"

CATALOG = [
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
    {"id": "tc08", "label": "TC08 [SKIP] 자동화 불가 항목 목록", "flag": "--tc08",
     "timeout": 180, "reboot": False, "note": "Azure IoT Hub Explorer 클라우드 포털 확인"},
]
CUSTOM_TC_TIMEOUTS = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180,
    "TC06": 180, "TC07": 180, "TC08": 180,
}
