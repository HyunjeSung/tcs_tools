"""system_log 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다."""

ID = "system_log"
LABEL = "system_log"
SCRIPT_NAME = "tc_system_log.sh"
# 기존 배포와 동일한 경로(runs/, latest_status.json)를 그대로 써서 기존 실행 이력을
# 마이그레이션 없이 유지한다. 다른 앱은 각자 이름이 붙은 디렉토리/파일을 쓴다.
RUNS_DIRNAME = "runs"
STATUS_FILENAME = "latest_status.json"

# tc_system_log.sh 가 실제로 지원하는 --flag 목록 (스크립트 case 문 기준).
# TC01/02/03/06/07/08/09 는 단독 flag가 없어 기본(default) 실행에만 포함됨.
# TC10은 reboot로 SSH 세션이 끊겨 default 실행 안에서 이어갈 수 없어 유일하게 제외.
CATALOG = [
    {"id": "default", "label": "빠른 실행 (TC01~09, 11~14)", "flag": None,
     "timeout": 2600, "reboot": False,
     "note": "TC10(reboot)·TC15/16(각 8~9분+, 대용량 journal) 제외 회귀 세트 — TC04/11/14 대기 "
             "포함 10분 내외. TC15/16은 아래 개별 버튼 또는 --full 로 따로 돌릴 것"},
    {"id": "full", "label": "전체 실행 (TC01~16, 18)", "flag": "--full",
     "timeout": 4200, "reboot": False, "chain_reboot_pairs": [("tc10-pre", "tc10-post")],
     "note": "TC01~09, 11~16, 18을 --full로 돌린 뒤 TC10(pre→reboot 대기→post)까지 이 대시보드가 "
             "직접 이어서 진행 — SSH 세션이 reboot로 끊기는 구간은 ping/ssh 폴링으로 재접속을 "
             "기다렸다가 자동 재개한다(수동 TC10-pre/post 클릭 불필요). TC15/16 대용량 journal "
             "주입 + TC18 파티션 소진 + reboot 대기 포함 40~50분+ 소요 — 릴리즈 전 전수 검증용. "
             "회귀 확인엔 위 빠른 실행 권장. 이 버튼 실행 중에는 다른 TC를 동시에 돌릴 수 없다"},
    {"id": "tc02", "label": "TC02 24시간 타이머", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "system_log 프로세스 kill 수반 (내부 타이머 상태 초기화)"},
    {"id": "tc04", "label": "TC04 대용량 journal timeout", "flag": "--tc04",
     "timeout": 450, "reboot": False, "note": None},
    {"id": "tc05", "label": "TC05 압축 (TC05-4 단독)", "flag": "--tc05",
     "timeout": 120, "reboot": False, "note": "TC05-1~3 은 setup 필요 — 기본 실행에서만 확인됨"},
    {"id": "tc10-pre", "label": "TC10-pre (reboot 발생)", "flag": "--tc10-pre",
     "timeout": 120, "reboot": True, "note": "실행 후 DUT 재부팅. 부팅 완료 후 TC10-post 실행 필요"},
    {"id": "tc10-post", "label": "TC10-post (reboot 후)", "flag": "--tc10-post",
     "timeout": 120, "reboot": False, "note": "TC10-pre 먼저 실행하고 DUT 재부팅 완료 후 사용"},
    {"id": "tc11", "label": "TC11 nmon 업로드 happy path", "flag": "--tc11",
     "timeout": 420, "reboot": False, "note": "BlobUploadDirector 5분+30초 대기"},
    {"id": "tc12", "label": "TC12 nmon retention", "flag": "--tc12",
     "timeout": 120, "reboot": False, "note": None},
    {"id": "tc13", "label": "TC13 nmon no-op", "flag": "--tc13",
     "timeout": 120, "reboot": False, "note": None},
    {"id": "tc-nmon", "label": "TC11+12+13 일괄 (nmon)", "flag": "--tc-nmon",
     "timeout": 420, "reboot": False, "note": None},
    {"id": "tc14", "label": "TC14 RTC 동일 시작 병합", "flag": "--tc14",
     "timeout": 180, "reboot": False, "note": "system_log 프로세스 kill 수반"},
    {"id": "tc15", "label": "TC15 rotate_sync compress 실패 보존", "flag": "--tc15",
     "timeout": 500, "reboot": False,
     "note": "journal 대량(raw ~400MB) 주입으로 180s 압축 타임아웃 강제 유발, 5분+ 소요"},
    {"id": "tc16", "label": "TC16 boot_log compress 실패 보존", "flag": "--tc16",
     "timeout": 560, "reboot": False,
     "note": "TC15와 동일 주입 + system_log kill 수반, task_capture_boot_log 완료 신호를 "
             "journald 폴링으로 기다림(최대 480s) — 5분+ 소요"},
    {"id": "tc17", "label": "TC17 MessageContext tid 미검증 재현", "flag": "--tc17",
     "timeout": 90, "reboot": False,
     "note": "아직 고쳐지지 않은 결함을 이용한 재현 시험 — cmd_host 응답 토픽에 위조 메시지를 "
             "직접 발행(mosquitto_pub)해 tid 검증 없이 소비/크래시되는지 확인. 정상 판정 관례와 "
             "동일하게 FAIL=결함 재현(현재 코드에서 항상 재현됨), PASS=tid 검증 도입 후. "
             "회귀 세트(빠른 실행/전체 실행)에는 미포함, 이 버튼으로만 단독 실행"},
    {"id": "tc18", "label": "TC18 저장공간 부족 시 cleanup", "flag": "--tc18",
     "timeout": 600, "reboot": False,
     "note": "예외 케이스 전용 파괴적 시험 — /edge/log 파티션을 실제로 10% 미만까지 소진시킨 "
             "뒤 systemctl restart docker-loader로 트리거(TC12와 동일 패턴, reboot 아님). "
             "여유율<25% 또는 df 파싱 이상(>950‰)이면 자동 SKIP(TC18-0 FAIL). 더미 mtime을 "
             "30일 미만으로 둬서 day-retention(delete_log)과 안 섞이고 저장공간-부족 경로만 "
             "검증한다. [2026-09-04 재설계] 원래 reboot로 트리거했으나 reboot 자체가 원인 불명의 "
             "대용량 쓰기 유실을 동반해 실 필드 버그 패턴과도 안 맞아 제외 — SSH 세션이 안 끊겨 "
             "더 이상 세션 재접속 오케스트레이션이 필요 없다"},
]

# 대시보드 "선택 실행" 체크박스용 — tc_system_log.sh 의 `--only TC01,TC03,...` 가 지원하는
# TC 목록과 대략적인 개별 소요시간(초). TC10은 reboot로 세션이 끊겨 다른 TC와 한 번에
# 묶을 수 없으므로 선택 대상에서 제외(--tc10-pre/post 전용 버튼만 사용).
# TC18은 2026-09-04 재설계로 reboot 대신 systemctl restart docker-loader 트리거를 쓰게
# 되면서 세션이 안 끊기게 됐고, --only의 일반 플로우로 자연스럽게 편입됐다(더 이상
# REBOOT_TC_MAP 재부팅 체이닝이 필요 없음).
# 순서 = tc_system_log.sh 의 표준 실행 순서와 동일.
CUSTOM_TC_TIMEOUTS = {
    "TC01": 90, "TC02": 180, "TC03": 90, "TC04": 300, "TC05": 120,
    "TC06": 90, "TC07": 90, "TC08": 90, "TC09": 230,
    "TC11": 420, "TC12": 120, "TC13": 120, "TC14": 180, "TC15": 500, "TC16": 560,
    "TC17": 90, "TC18": 600,
}
