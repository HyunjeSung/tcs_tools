"""device_log 앱 등록 정보 — server.py의 APPS 레지스트리가 이 모듈을 읽어간다.

tc_device_log.md(TC01~TC27, 연번) 기반으로 qa 에이전트가 전체 구현 완료(2026-08-21).
버튼은 빠른 실행/전체 실행 두 개만 노출하고 개별 TC는 모두 "선택 실행" 드롭다운으로
옮겼다(2026-08-21, tc_device_log.sh에 --only/--full 파싱 추가).
재부팅 사이클(TC06/07, TC15, TC20, TC25)은 --only로 못 묶어(세션이 끊김)
REBOOT_TC_MAP을 통해 "선택 실행"에서 골라도 대시보드가 -pre/-post를 직접 체이닝한다 —
"전체 실행"의 chain_reboot_pairs와 같은 오케스트레이션(server._run_ssh_full_with_reboots)을
재사용.

[2026-08-24 갱신] tc_device_log.md/.sh가 결번(TC06/TC15/TC17)을 정리하고 TC01~TC27로
번호를 당겼다 — 이 파일의 CATALOG/HIDDEN_ENTRIES/CUSTOM_TC_TIMEOUTS/REBOOT_TC_MAP을
전부 새 번호에 맞춰 재작성했다(기존 값은 재부팅 사이클 대응 관계 기준으로 그대로 이전).

[2026-08-25 갱신] TC26(factory_reset)을 "전체 실행"의 자동 재부팅 체인에서 뺐다 —
매번 --full을 돌릴 때마다 로그가 통째로 삭제되는 부작용이 있어(다른 TC가 남긴
잔여 파일 분석 등에 방해), 실수로 같이 실행되지 않도록 별도의 명시적 버튼
(id="tc26")으로 분리했다. "전체 실행"은 이제 재부팅 3사이클(06/07,15,20)까지만
자동 진행하고, TC26은 "⚠ Factory Reset(TC26)" 버튼을 따로 눌러야만 실행된다.

[2026-08-26 갱신] 구 TC24(EOL 로그 압축 형식 zip vs xz)를 요구사항 자체 삭제 —
DUT 실측으로 eol_logger.cpp에 압축 호출이 전혀 없어(zip은 물론 xz도) 검증 대상이
없음을 확정. 뒤 번호를 당겨 연번 유지: 구TC25(EOL field logging 중단)→TC24,
구TC26(Factory Reset)→TC25, 구TC27(EOL 로그 추출 IPC)→TC26. 이 파일의
CATALOG/HIDDEN_ENTRIES/CUSTOM_TC_TIMEOUTS/REBOOT_TC_MAP 전부 새 번호로 갱신
(id="tc26" 버튼 → id="tc25", tc26-pre/post → tc25-pre/post).
"""

ID = "device_log"
LABEL = "device_log"
SCRIPT_NAME = "tc_device_log.sh"
RUNS_DIRNAME = "runs_device_log"
STATUS_FILENAME = "latest_status_device_log.json"

CATALOG = [
    {"id": "default", "label": "빠른 실행 (TC01~04,08,10~14,16,17,21,22)", "flag": None,
     "timeout": 3600, "reboot": False,
     "note": "재부팅 3사이클(06/07,15,20)·시스템시각변경(05,18,19)·정책수정+재시작(09)·"
             "EOL 로그 관련(23,24,26, Factory EOL Mode 토글)·Factory Reset(25)은 미포함 — 아래 "
             "선택 실행(개별 TC) 또는 전체 실행(TC01~24,26)으로 실행. TC25는 파괴적이라 별도 버튼"},
    {"id": "full", "label": "전체 실행 (TC01~24,26, TC25 제외)", "flag": "--full",
     "timeout": 6600, "reboot": False,
     "chain_reboot_pairs": [("tc06-pre", "tc06-post"), ("tc15-pre", "tc15-post"),
                            ("tc20-pre", "tc20-post")],
     "note": "TC01~05,08~14,16~19,21~24,26을 --full로 순서대로 실행한 뒤 재부팅 3사이클(TC06/07→TC15→"
             "TC20)까지 이 대시보드가 직접 이어서 진행 — SSH 세션이 reboot로 끊기는 구간은 "
             "ping/ssh 폴링으로 재접속을 기다렸다가 자동 재개한다(수동 -pre/-post 클릭 불필요). "
             "[2026-08-25] TC05는 logCreationTime 자연 경과 대기 대신 timedatectl 시간 점프 방식으로 "
             "바뀌어 더 이상 전체 소요를 지배하지 않는다(TC18/19처럼 20초 내외). TC05/18/19는 시스템 "
             "시각을 임시 변경(모두 원복 로직 포함). [2026-08-25] TC25(factory_reset — /edge/log/eol, "
             "device_log, toupload/device_log 전체 삭제)은 이 전체 실행 흐름에서 완전히 빠졌다 — "
             "실수로 같이 눌려 로그가 통째로 날아가는 일을 막기 위해 아래 별도 'Factory Reset(TC25)' "
             "버튼으로만 실행한다. 이 버튼 실행 중에는 다른 TC를 동시에 돌릴 수 없다"},
    {"id": "tc25", "label": "⚠ Factory Reset (TC25, 파괴적)", "flag": None,
     "timeout": 90, "reboot": False,
     "chain_reboot_pairs": [("tc25-pre", "tc25-post")],
     "note": "⚠ 파괴적 — /edge/log/eol, device_log, toupload/device_log 전체 삭제 + 재부팅. "
             "[2026-08-25] 이전엔 '전체 실행'에 자동 포함돼 있었는데, 매번 로그가 통째로 날아가는 "
             "부작용이 있어 별도 버튼으로 분리했다 — 실제로 필요할 때만 명시적으로 눌러서 실행할 것"},
]

# 카탈로그(버튼)에는 안 보이지만 catalog_map 조회용으로만 쓰는 항목 — 전체 실행/선택 실행이
# 재부팅 TC를 고를 때 chain_reboot_pairs가 이 id로 pre/post 엔트리를 찾아 체이닝한다.
HIDDEN_ENTRIES = [
    {"id": "tc06-pre", "label": "TC06/07-pre 재부팅 후 로깅 재개(동일 파일 이어쓰기 + 빈 행 삽입)", "flag": "--tc06-pre",
     "timeout": 90, "reboot": True, "note": "TC07(빈 행 삽입)도 같은 사이클에서 함께 검증"},
    {"id": "tc06-post", "label": "TC06/07-post 재부팅 후 로깅 재개", "flag": "--tc06-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc15-pre", "label": "TC15-pre 재부팅 후 업로드 재개", "flag": "--tc15-pre",
     "timeout": 90, "reboot": True, "note": None},
    {"id": "tc15-post", "label": "TC15-post 재부팅 후 업로드 재개", "flag": "--tc15-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc20-pre", "label": "TC20-pre 재부팅 후 업로드 설정 파일(logcount.json) 유지", "flag": "--tc20-pre",
     "timeout": 90, "reboot": True, "note": None},
    {"id": "tc20-post", "label": "TC20-post 재부팅 후 업로드 설정 파일(logcount.json) 유지", "flag": "--tc20-post",
     "timeout": 180, "reboot": False, "note": None},
    {"id": "tc25-pre", "label": "TC25-pre Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제", "flag": "--tc25-pre",
     "timeout": 90, "reboot": True, "note": "파괴적 — /edge/log/eol, device_log, toupload/device_log 전체 삭제"},
    {"id": "tc25-post", "label": "TC25-post Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제", "flag": "--tc25-post",
     "timeout": 240, "reboot": False, "note": None},
]

# "선택 실행" 드롭다운 목록 — TC01~26 전부 노출. TC06/TC07/TC15/TC20/TC25는
# --only로 못 묶여 값 자체는 쓰이지 않지만(REBOOT_TC_MAP 경로로 분기) 검증/표시용으로
# 채워둔다(대략 pre+post 합).
CUSTOM_TC_TIMEOUTS = {
    "TC01": 120, "TC02": 300, "TC03": 180, "TC04": 90,
    # [2026-08-25 재설계] TC05는 logCreationTime(최대 6시간+) 자연 경과 대기를
    # timedatectl 시간 점프로 바꿔(tc_device_log.sh) TC18/TC19와 같은 급으로 짧아졌다
    # (기존 22500 → TC19와 동일하게 150).
    "TC05": 150,
    "TC06": 270, "TC07": 270, "TC08": 60,
    # [2026-08-24 DUT 실측 후 수정] TC11/TC12는 cloud_broker BlobUploadDirector의
    # kScanIntervalSec=300초 고정 스캔을 최대 310초까지 폴링 대기하는 설계인데(tc_device_
    # log.sh tc11_upload_result_journal()/tc12_multi_file_upload()), 이 값들이 그 설계
    # 이전의 구값(120/150)으로 남아있어 --only로 여러 TC를 묶어 돌릴 때 합산 타임아웃이
    # 실제 소요를 못 따라가 마지막 TC(TC21 등)가 시작도 못 하고 죽는 원인이 됐다
    # (20260824_140257_device_log_custom 실측: TC11=313s, TC12=331s인데 budget은
    # 120/150이라 즉시 초과). 실측치에 여유를 두어 상향.
    "TC11": 360, "TC12": 380, "TC13": 150,
    # TC14/TC16/TC17도 restart_docker_loader()를 포함하는데, 그 재기동 대기가 자기
    # 자신과 오매칭돼 사실상 기다리지 않던 회귀 버그를 이번에 고치면서(server.py가 아니라
    # tc_device_log.sh 쪽 수정) 실제로 재기동 완료를 기다리게 됐다 — 그만큼 소요시간이
    # 늘어난 것을 반영(같은 실측 런: TC14=176s, TC16=148s, TC17=152s).
    #
    # [2026-08-25 재수정] pgrep으로 프로세스 존재만 확인해도 CloudUploadManager::init()
    # (root/archive 큐 등록)이 끝났다는 보장이 안 됨을 TC21 실측으로 추가 발견 —
    # restart_docker_loader()에 "Total files found in root" 로그를 기다리는 2차 대기
    # (최대 60초)를 더했다(tc_device_log.sh). 이 함수를 호출하는 모든 TC의 budget에
    # 호출 횟수 × 60초를 더해 반영: TC09(2회 호출) 300→420, TC10(1회) 180→240,
    # TC14(3회) 280→460, TC16(2회) 220→340, TC17(2회) 220→340.
    "TC09": 420, "TC10": 240,
    "TC14": 460, "TC15": 270,
    "TC16": 340, "TC17": 340,
    # [2026-08-25 수정, 재수정] TC18/TC19는 isMidNightRoutineTime() 관측 창
    # ([23:50,23:55))의 시작점(23:50:00)으로 직행하도록 바꿔 23:49+90초 대기(75초
    # 낭비)를 23:50+15초로 단축했다. plain `date -s`는 NTP 데몬이 즉시 되돌리는
    # 레이스가 있어 `timedatectl set-ntp no`+`set-time`으로 교체(DUT 실측 확인,
    # tc_device_log.sh). TC18은 추가로 perDayArchive=0일 때 5로 올리는
    # restart_docker_loader() 1회(+원복 시 조건부 1회, 최대 2회)가 들어가
    # (120s×2=240s대) + 시간조작 오버헤드. 여유를 두어 320s.
    "TC18": 320,
    # [2026-08-25 재설계, 재수정] TC21은 이제 라운드로빈 관측이 아니라 toupload
    # 게이트를 log_item 1개(Meter)로 직접 검증한다(tc_device_log.sh
    # tc21_toupload_routing()). get_log_data는 게이트를 안 거치는 별도 경로라
    # (handleForcedLogUploadRequest) 실측 후 폐기, TC10 방식(root/toupload에 더미
    # 직접 배치 + restart_docker_loader()로 큐 등록)으로 재수정 — sub-case마다
    # restart(CloudUploadManager 초기화 대기 포함 최대 120s대) + idle thread 폴링
    # (<=60s)이 들어가 TC21-1/2 합쳐 최악의 경우 (120+60)*2=360s대. 여유를 두어 420s.
    "TC19": 120, "TC20": 270, "TC21": 420, "TC22": 90, "TC23": 300,
    # [2026-08-26] 구 TC24(EOL 압축 zip vs xz)는 요구사항 삭제로 제거. 뒤 번호를 당김:
    # 구TC25(EOL field logging 중단)→TC24, 구TC26(Factory Reset)→TC25,
    # 구TC27(EOL 로그 추출 IPC)→TC26 (타임아웃 값은 그대로 이전).
    # [2026-08-26 재수정] TC26이 미구현 SKIP에서 실제 HTTP API 실측(토큰 발급 +
    # tar 다운로드, 2회 HTTPS round trip)으로 바뀌어 15s로는 빠듯할 수 있어 상향.
    "TC24": 180, "TC25": 330, "TC26": 30,
}

# "full"(전체 실행)은 여러 TC를 이어 돌려 개별 TC 타임아웃 합만큼 누적 소요될 수 있다 —
# server.py의 SSH 좀비-채널 stall guard 기본값(900s)으로는 오탐(false stall)할 수 있어
# 가장 긴 개별 TC 타임아웃 기준으로 여유를 둔 값으로 오버라이드한다.
next(e for e in CATALOG if e["id"] == "full")["stall_timeout"] = max(CUSTOM_TC_TIMEOUTS.values()) + 1200

# "선택 실행"에서 이 TC를 고르면 --only가 아니라 -pre/-post 재부팅 체이닝으로 실행한다
# (server.api_run의 custom 분기 참고). TC07은 TC06과 같은 재부팅 사이클을 공유.
REBOOT_TC_MAP = {
    "TC06": ("tc06-pre", "tc06-post"),
    "TC07": ("tc06-pre", "tc06-post"),
    "TC15": ("tc15-pre", "tc15-post"),
    "TC20": ("tc20-pre", "tc20-post"),
    "TC25": ("tc25-pre", "tc25-post"),
}

# TC26(EOL 로그 추출 API)이 필요로 하는 인증정보 — secrets.env(git에 안 올라감,
# repo 루트)에만 두고, server.py의 _env_prefix_for()가 SSH 실행 시에만 이 변수명
# 목록으로 골라서 원격 명령에 주입한다. 값 자체는 여기 없음(하드코딩 금지).
PASSTHROUGH_ENV = ["FACTORY_AUTH_KEY", "FACTORY_AUTH_SECRET"]
