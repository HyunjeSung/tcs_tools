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
    {"id": "default", "label": "빠른 실행 (TC01~09, 11~14, 19)", "flag": None,
     "timeout": 3500, "reboot": False,
     "note": "TC10(reboot)·TC15/16(ENOSPC 파괴적 시험)·TC20/21/22(파티션 실채움, 파괴적) "
             "제외 회귀 세트 — [2026-09-23] TC04가 100MB/200MB 두 티어로 늘고 압축 전용 "
             "타임아웃이 300초로 커져 대기 포함 15분 내외로 늘어남(과거 10분 내외 대비). "
             "TC18(저장공간 부족 cleanup)은 R09 전용(main에선 함수 제거)이라 미포함 — 개별 버튼 "
             "또는 선택 실행으로 돌릴 것. TC19(로그 디스크 예산 watermark 근거 수집)는 읽기 전용이라 "
             "여기 포함됨. TC15/16/20/21/22는 아래 개별 버튼 또는 --full 로 따로 돌릴 것"},
    {"id": "full", "label": "전체 실행 (TC01~09, 11~16, 20~22)", "flag": "--full",
     "timeout": 7910, "reboot": False, "chain_reboot_pairs": [("tc10-pre", "tc10-post")],
     "note": "TC01~09, 11~16, 20~22를 --full로 돌린 뒤 TC10(pre→reboot 대기→post)까지 이 대시보드가 "
             "직접 이어서 진행 — SSH 세션이 reboot로 끊기는 구간은 ping/ssh 폴링으로 재접속을 "
             "기다렸다가 자동 재개한다(수동 TC10-pre/post 클릭 불필요). TC18(저장공간 "
             "부족 cleanup)은 R09 전용이라 미포함(개별 버튼/선택 실행). TC15/16은 ENOSPC "
             "fault injection으로 재설계 — 판정 자체는 수 초 안에 끝나지만 /edge/log(5.9GB급) GB급 "
             "filler 채우기/삭제가 대부분의 시간을 차지해 수 분~10분대로 소요 + TC04 두 티어 확장"
             "(최대 800초대) + TC20/21 로그 디스크 예산(~2.6GiB 더미, 트립+재개 각각 재시작 수반) "
             "+ TC22(신규, 능동정리 검증 — TC20과 비슷한 규모의 더미) + reboot 대기 포함 55~70분+ "
             "소요 — 릴리즈 전 전수 검증용. TC17은 미포함(별도 버튼). 회귀 확인엔 위 빠른 실행 권장. "
             "이 버튼 실행 중에는 다른 TC를 동시에 돌릴 수 없다"},
    {"id": "tc02", "label": "TC02 24시간 타이머", "flag": "--tc02",
     "timeout": 180, "reboot": False, "note": "system_log 프로세스 kill 수반 (내부 타이머 상태 초기화)"},
    {"id": "tc04", "label": "TC04 대용량 journal timeout", "flag": "--tc04",
     "timeout": 1000, "reboot": False,
     "note": "[2026-09-23] 100MB(기존 회귀)+200MB(신규) 두 티어 순차 실행 — xz -0 + compress 전용 "
             "300초 타임아웃 분리가 대용량에서도 정상 성공하는지 확인. 응답 대기 상한: 100MB=200초, "
             "200MB=500초(이론상 최악 dump185+compress305=490초+여유) + 양 티어 무결성(xz --test) 검증"},
    {"id": "tc05", "label": "TC05 압축 (TC05-4 단독)", "flag": "--tc05",
     "timeout": 120, "reboot": False, "note": "TC05-1~3 은 setup 필요 — 기본 실행에서만 확인됨"},
    {"id": "tc10-pre", "label": "TC10-pre (reboot 발생)", "flag": "--tc10-pre",
     "timeout": 120, "reboot": True, "note": "실행 후 DUT 재부팅. 부팅 완료 후 TC10-post 실행 필요"},
    {"id": "tc10-post", "label": "TC10-post (reboot 후)", "flag": "--tc10-post",
     "timeout": 240, "reboot": False, "note": "TC10-pre 먼저 실행하고 DUT 재부팅 완료 후 사용"},
    {"id": "tc11", "label": "TC11 nmon 업로드 happy path", "flag": "--tc11",
     "timeout": 420, "reboot": False, "note": "BlobUploadDirector 5분+30초 대기"},
    {"id": "tc12", "label": "TC12 nmon retention", "flag": "--tc12",
     "timeout": 120, "reboot": False, "note": None},
    {"id": "tc13", "label": "TC13 nmon no-op", "flag": "--tc13",
     "timeout": 120, "reboot": False, "note": None},
    {"id": "tc-nmon", "label": "TC11+12+13 일괄 (nmon)", "flag": "--tc-nmon",
     "timeout": 420, "reboot": False, "note": None},
    {"id": "tc14", "label": "TC14 RTC 동일 시작 병합", "flag": "--tc14",
     "timeout": 420, "reboot": False, "note": "system_log 프로세스 kill 수반"},
    {"id": "tc15", "label": "TC15 rotate_sync compress 실패 보존", "flag": "--tc15",
     "timeout": 1110, "reboot": False,
     "note": "[2026-09-23 재설계, 실측 조정] ENOSPC fault injection — /edge/log 파티션(실측 "
             "5.9GB)을 측정된 dump 산출물 크기+마진만 남기고 채워 xz -0을 몇 초 안에 "
             "결정적으로 실패시킨다(기존 raw 400MB 주입+180s 공유 타임아웃 방식은 xz -0+compress "
             "전용 300s 분리로 더 이상 compress 실패를 재현 못 해 폐기). 실패 판정 자체는 수 초 "
             "안에 끝나지만 GB급 filler 채우기/삭제(dd)가 대부분의 시간을 "
             "차지 — 타임아웃도 넉넉히 잡음. 파괴적 시험 — 여유공간 부족/과다 시 "
             "자동 SKIP(TC15-0)"},
    {"id": "tc16", "label": "TC16 boot_log compress 실패 보존", "flag": "--tc16",
     "timeout": 1080, "reboot": False,
     "note": "[2026-09-23 재설계, 실측 조정] TC15와 동일 ENOSPC 기법(GB급 filler, 실측 조정된 "
             "타임아웃) + system_log kill -9 재시작 수반. 파괴적 시험 — 여유공간 부족/과다 시 "
             "자동 SKIP(TC16-0)"},
    {"id": "tc17", "label": "TC17 MessageContext tid 미검증 재현", "flag": "--tc17",
     "timeout": 90, "reboot": False,
     "note": "아직 고쳐지지 않은 결함을 이용한 재현 시험 — cmd_host 응답 토픽에 위조 메시지를 "
             "직접 발행(mosquitto_pub)해 tid 검증 없이 소비/크래시되는지 확인. 정상 판정 관례와 "
             "동일하게 FAIL=결함 재현(현재 코드에서 항상 재현됨), PASS=tid 검증 도입 후. "
             "회귀 세트(빠른 실행/전체 실행)에는 미포함, 이 버튼으로만 단독 실행"},
    {"id": "tc18", "label": "TC18 저장공간 부족 시 cleanup (R09 전용)", "flag": "--tc18",
     "timeout": 600, "reboot": False,
     "note": "[2026-10-02 R09 전용 복구] R090125 백포트(309e4e2)에 남아있는 cleanup_if_low_disk_space()"
             "검증용 — main 계열 빌드는 이 함수가 제거돼 TC18-0에서 자동 SKIP(실행 중 바이너리를 "
             "직접 grep). 예외 케이스 전용 파괴적 시험 — /edge/log 파티션을 실제로 10% 미만까지 "
             "소진시킨 뒤 systemctl restart docker-loader로 트리거. 여유율<25% 또는 df 파싱 "
             "이상(>950‰)이면 자동 SKIP. 더미 mtime을 30일 미만으로 둬서 day-retention과 안 섞인다. "
             "빠른/전체 실행 미포함, TC04/15/16/20/21/22와 동시 실행 금지"},
    {"id": "tc19", "label": "TC19 로그 디스크 예산 watermark 근거 수집", "flag": "--tc19",
     "timeout": 90, "reboot": False,
     "note": "읽기 전용/비파괴적(informational) — hard limit 2560MiB / low watermark 2304MiB "
             "타당성 판단용 실기기 dump 크기 분포·사용량을 수집만 한다. PASS/FAIL 게이트 아님"
             "(근거 수집 자체 실패 시에만 FAIL)"},
    {"id": "tc20", "label": "TC20 로그 디스크 예산 circuit breaker 트립/재개", "flag": "--tc20",
     "timeout": 700, "reboot": False,
     "note": "예외 케이스 전용 파괴적 시험 — /edge/log에 최대 ~2.6GiB 더미를 채워 하드리밋(2560MiB) "
             "트립을 유발하고, kill -9 재시작으로 task_check_disk_budget()을 결정적으로 즉시 "
             "발화시킨다. 트립 중 day-retention 유지 확인 포함, 더미 정리 후 재시작으로 로우워터마크"
             "(2304MiB) 재개까지 확인. TC20-4(트립 중 journal vacuum 실행 여부)는 informational/Flag"
             "— 코드 분석상 트립 중 미실행 기대(review 전달 필요). 여유공간 부족 시 자동 SKIP. "
             "TC04/15/16/18과 동시 실행 금지"},
    {"id": "tc21", "label": "TC21 온디맨드 반복 요청 WARN 로그량 선형성", "flag": "--tc21",
     "timeout": 600, "reboot": False,
     "note": "예외 케이스 전용 파괴적 시험 — TC20과 동일 기법으로 자체 트립 유발 후 get_log_data를"
             "4초 간격 8회 반복 발행, request_dump_journal()의 매 skip WARN이 요청 수만큼만(레이트"
             "리밋 없음, 폭증 아님) 찍히는지·응답이 매번 10초 이내 반환되는지 확인. 여유공간 부족 시"
             " 자동 SKIP. TC04/15/16/18/20과 동시 실행 금지"},
    {"id": "tc22", "label": "TC22 로그 디스크 예산 능동 정리 (트립 tick 내 즉시 정리+재개)", "flag": "--tc22",
     "timeout": 700, "reboot": False,
     "note": "[2026-09-23 신규] 예외 케이스 전용 파괴적 시험 — task_check_disk_budget()이 트립되면 "
             "이제 스스로 cleanup_log_disk_budget()을 불러 오래된 .xz/.log/.meta/.nmon부터 지우며 "
             "재측정, 로우워터마크(2304MiB) 이하가 되면 재시작 없이 같은 tick 안에서 즉시 재개하는지 "
             "확인한다. TC20/21의 .tc20fill 더미(삭제 후보 이중 면제)는 재사용 불가 — TOUPLOAD_DIR에 "
             "직접 .log.xz 더미(mtime 오름차순 분산)를 배치한다. 여유공간 부족 시 자동 SKIP. "
             "TC04/15/16/18/20/21과 동시 실행 금지"},
]

# 대시보드 "선택 실행" 체크박스용 — tc_system_log.sh 의 `--only TC01,TC03,...` 가 지원하는
# TC 목록과 대략적인 개별 소요시간(초). TC10은 reboot로 세션이 끊겨 --only에 못 묶지만,
# [2026-10-06] REBOOT_TC_MAP으로 선택 실행에 포함 — 대시보드가 나머지 선택 TC를 --only로
# 먼저 돌린 뒤 tc10-pre → 재부팅 대기 → tc10-post를 이어 붙인다(그래서 항상 맨 마지막).
# [2026-10-02] TC18은 main에서 검증 대상 함수가 제거돼 2026-09-23에 삭제됐다가, R09
# (R090125 백포트) 검증용으로 복구됨 — main 빌드에선 스크립트가 TC18-0에서 자동 SKIP.
# 순서 = tc_system_log.sh 의 표준 실행 순서와 동일. [2026-10-06] TC02(+25h 시간 이동)는
# 파일명 시각을 보는 TC 뒤로 이동 — TC14 다음.
CUSTOM_TC_TIMEOUTS = {
    "TC01": 90, "TC03": 90, "TC04": 850, "TC05": 120,
    "TC06": 90, "TC07": 90, "TC08": 90, "TC09": 230,
    # TC10: pre(120) + 재부팅 대기(최대 180+45) + post(240) — 표시/추정용. 목록에서는 번호 순
    # 자리에 두지만, 실행은 REBOOT_TC_MAP 체이닝이라 항상 나머지 선택 TC 뒤에 돈다.
    "TC10": 600,
    "TC11": 420, "TC12": 120, "TC13": 120, "TC14": 420, "TC02": 180, "TC15": 1110, "TC16": 1080,
    "TC17": 90, "TC18": 600, "TC19": 90, "TC20": 700, "TC21": 600, "TC22": 700,
}

# 선택 실행에서 재부팅 TC를 pre/post 체이닝으로 분기시키는 매핑(device_log와 동일 구조)
REBOOT_TC_MAP = {"TC10": ("tc10-pre", "tc10-post")}
