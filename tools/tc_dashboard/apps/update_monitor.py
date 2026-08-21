"""update_monitor 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

AC Gen2 TestCase.xlsx "Unified Edge Platform" 카테고리 기반으로 tc-plan/dev 에이전트가
신규 작성(2026-08-10), DUT 실기 검증 및 --only 선택 실행 지원 추가(2026-08-11).
reboot:True는 실제로 SSH 세션이 끊기는 재부팅이라 판단해 -pre/-post로 분리한 TC에만
붙어있다 — 파괴적 컨테이너 재시작(kill -9, bin 변조 등)이라도 스크립트 안에서 자체
polling으로 끝나면 reboot:False로 둔 것(단일 SSH 세션 내에서 완결). CUSTOM_TC_TIMEOUTS
에는 reboot 전용 -pre/-post TC를 제외한 나머지만 담아 선택 실행 대상으로 노출한다.
"""

ID = "update_monitor"
LABEL = "update_monitor"
SCRIPT_NAME = "tc_update_monitor.sh"
RUNS_DIRNAME = "runs_update_monitor"
STATUS_FILENAME = "latest_status_update_monitor.json"

CATALOG = [
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
    {"id": "tc05", "label": "TC05 [SKIP] 리소스 사전 점검 설정", "flag": "--tc05",
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
CUSTOM_TC_TIMEOUTS = {
    "TC01": 180, "TC02": 180, "TC03": 180, "TC04": 180, "TC05": 180, "TC06": 180,
    "TC07": 180, "TC08": 180, "TC09": 180, "TC10": 180, "TC11": 180, "TC12": 180,
}
