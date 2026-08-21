"""web_interface 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
"""

ID = "web_interface"
LABEL = "web_interface"
SCRIPT_NAME = "tc_web_interface.sh"
RUNS_DIRNAME = "runs_web_interface"
STATUS_FILENAME = "latest_status_web_interface.json"

CATALOG = [
    {"id": "default", "label": "전체 실행 (TC01~TC15, 재부팅/스텁 TC 제외)", "flag": None,
     "timeout": 600, "reboot": False,
     "note": "각 TC 개별 버튼은 아래 참고 — 재부팅을 수반하는 TC는 default에 포함되지 않고 개별 -pre/-post 버튼으로 실행"},
    {"id": "tc01", "label": "TC01 API 문서 제공", "flag": "--tc01",
     "timeout": 180, "reboot": False, "note": "Swagger/OpenAPI 문서 서버"},
    {"id": "tc02", "label": "TC02 [SKIP] MQTT Disconnect 시 Error Response 처리", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "검토 필요 — 원본 Action 미기재"},
    {"id": "tc03", "label": "TC03 MQTT-HTTP Bridge 지원", "flag": "--tc03",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc04", "label": "TC04 [SKIP] 로깅 보안 (민감 정보 마스킹)", "flag": "--tc04",
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
CUSTOM_TC_TIMEOUTS = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180, "TC12": 180,
    "TC13": 180, "TC14": 180, "TC15": 180,
}
