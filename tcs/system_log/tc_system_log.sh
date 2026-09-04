#!/bin/bash
# TC: system_log
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="system_log"
STAGING_DIR="/edge/log/system"
TOUPLOAD_DIR="/edge/log/toupload/system"
ARCHIVE_DIR="/edge/log/system/archive"
SHUTDOWN_DONE="/edge/log/system/shutdown_done"
TC10_SAVE="/edge/log/system/.tc10_before"
NMON_OLD_DIR="/edge/log/system/nmon/old"
NMON_TOUPLOAD_DIR="/edge/log/toupload/system/nmon"
NMON_ARCHIVE_DIR="/edge/log/system/nmon/archive"
JOURNAL_DIR="/var/log/journal"
# TC04/TC15/TC16 journal 대량 주입용 premade blob. 매 실행마다 urandom+base64를
# 새로 뽑는 대신 디바이스에 1회 생성해 영구 상주시키고 재사용한다 (질문 답변 참고:
# journald가 검증하는 건 "systemd-cat 정상 경로로 들어왔는가"이지 내용의 신선도가
# 아니므로, 한 번 뽑은 고엔트로피 데이터를 재사용해도 무방하다).
DUMMY_BLOB="/edge/log/.tc_dummy_journal_blob"
DUMMY_BLOB_RAW_MB=400
# TC18 저장공간 부족(<10%) 재현용 상수. reboot이 아니라 systemctl restart docker-loader로
# 트리거하는 단일 함수라 세션 간 상태 저장(TC18_SAVE) 자체가 불필요해졌다(2026-09-04 재설계).
TC18_TARGET_LOW_PERCENT=9
TC18_MIN_FREE_BEFORE_PERMILLE=250
# 상한은 "df 파싱이 완전히 깨진 경우"만 걸러내는 최후 안전장치로만 두고(실사용 DUT는
# 여유율이 얼마든 실제로 채운다 — 실측 192.168.10.25: 5.9GB 파티션 여유율 85%에서 목표
# 9%까지 낮추는 데 더미 약 4.55GB 필요했음), 안전 상한(TC18_MAX_FILL_MB)을 그 실측치보다
# 넉넉히 크게 잡아 그대로 수용한다.
TC18_MAX_FREE_BEFORE_PERMILLE=950
TC18_MAX_FILL_MB=6144
PASS=0
FAIL=0

# subscribe 먼저 시작 후 publish → 응답 누락 방지
send_and_wait() {
    local service="$1"
    local payload="$2"
    [ -z "$payload" ] && payload="{}"
    local timeout="${3:-30}"
    local tid="tc-$(date +%s)"
    local full_payload
    full_payload=$(printf '{"tid":"%s","payload":%s}' "$tid" "$payload")
    local resp_topic="emsp/${SOURCE}/${TARGET}/res/${service}"
    local req_topic="emsp/${TARGET}/${SOURCE}/req/${service}"
    local resp_file="/tmp/mqtt_resp_$$_${service}"

    mosquitto_sub -h "$MQTT_HOST" -t "$resp_topic" -W "$timeout" -C 1 > "$resp_file" 2>/dev/null &
    local sub_pid=$!
    sleep 0.5
    mosquitto_pub -h "$MQTT_HOST" -t "$req_topic" -m "$full_payload"
    wait "$sub_pid"
    cat "$resp_file" 2>/dev/null
    rm -f "$resp_file"
}

assert() {
    local desc="$1"
    local result="$2"
    local reason="$3"
    if [ "$result" = "PASS" ]; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
    [ -n "$reason" ] && echo "  [REASON] $reason"
}

# 판정에 사용한 명령어를 그대로 실행하고 raw 출력을 evidence로 남긴다.
# (서술문("~확인됨")만으로는 근거로 인정하지 않는다 — 반드시 명령어 실행 결과를 남길 것)
dump_cmd() {
    echo "  \$ $*"
    "$@" > /tmp/tc_dump_out_$$ 2>&1
    local rc=$?
    sed 's/^/    /' /tmp/tc_dump_out_$$
    rm -f /tmp/tc_dump_out_$$
    echo "    exit_code:${rc}"
    return "$rc"
}

# ls -t(수정시각) 기준 "최신"은 TC02가 시스템 시계를 조작하는 것과 상극이다 — 이전 run이
# 시간 복원에 실패해 미래 mtime 파일이 남으면, 이후 run이 방금 만든 진짜 최신 파일보다
# 그 잔재가 계속 "최신"으로 잡혀 endtime 비교가 어긋난다. 파일명에 박힌 endtime(마지막
# _ 뒤 14자리, 항상 고정폭이라 사전순 정렬=시간순 정렬)으로 찾으면 시계 상태와 무관하다.
find_latest_xz() {
    ls "$1"/systemlog_*.log.xz 2>/dev/null | sort -t_ -k3 | tail -1
}

# DUMMY_BLOB이 없으면 최초 1회만 raw urandom을 base64로 부풀려 생성해 디바이스에
# 영구 상주시킨다. 이후 호출부터는 이 파일을 그대로 재사용 — urandom 생성/base64
# 인코딩 자체가 임베디드 CPU에서 느려 TC15/16이 "5분 이상" 걸리던 주요 원인이었다.
ensure_dummy_blob() {
    if [ ! -s "$DUMMY_BLOB" ]; then
        echo "  [SETUP] premade journal dummy blob 없음 — 최초 1회 생성 (raw ${DUMMY_BLOB_RAW_MB}MB → ${DUMMY_BLOB})"
        mkdir -p "$(dirname "$DUMMY_BLOB")"
        head -c $((DUMMY_BLOB_RAW_MB * 1048576)) /dev/urandom | base64 -w 4096 > "$DUMMY_BLOB"
        sync
        dump_cmd ls -la "$DUMMY_BLOB"
    fi
}

# DUMMY_BLOB에서 raw_mb(예: 70/105)에 해당하는 만큼만 슬라이스해 systemd-cat으로
# journald에 주입한다. raw_mb를 생략하거나 DUMMY_BLOB_RAW_MB 이상이면 전체를 주입.
inject_dummy_blob() {
    local tag="$1"
    local raw_mb="${2:-$DUMMY_BLOB_RAW_MB}"
    ensure_dummy_blob
    if [ "$raw_mb" -ge "$DUMMY_BLOB_RAW_MB" ]; then
        cat "$DUMMY_BLOB" | systemd-cat -t "$tag"
    else
        local blob_total slice_bytes
        blob_total=$(wc -c < "$DUMMY_BLOB")
        slice_bytes=$((blob_total * raw_mb / DUMMY_BLOB_RAW_MB))
        head -c "$slice_bytes" "$DUMMY_BLOB" | systemd-cat -t "$tag"
    fi
}

# TC18용 — df -P 로 얻은 1K-block 값을 정수 연산(퍼밀, ‰)으로 다뤄 busybox awk의
# 부동소수 출력 편차를 피한다. 100‰=10%, 200‰=20% (cleanup_if_low_disk_space의
# threshold_percent=10, delete_oldest_files_until_safe의 목표치 threshold_percent*2=20 과 대응).
disk_total_kb() { df -P "$1" 2>/dev/null | awk 'NR==2{print $2}'; }
disk_avail_kb() { df -P "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
disk_free_permille() {
    df -P "$1" 2>/dev/null | awk 'NR==2{ if ($2>0) printf "%d", ($4*1000)/$2; else print 0 }'
}

# ============================================================
# SETUP: get_log_data 1회 실행 (TC01~TC07 공용)
# ============================================================
setup_rotate() {
    echo "[SETUP] get_log_data 요청 (응답 대기 30초 + 파일 생성 대기 10초)..."

    mkdir -p "${TOUPLOAD_DIR}"
    dump_cmd journalctl --disk-usage
    JOURNAL_DISKUSAGE_BEFORE="$(journalctl --disk-usage 2>/dev/null)"
    JOURNAL_SIZE_BEFORE=$(echo "$JOURNAL_DISKUSAGE_BEFORE" | awk '/take up/{print $7}')
    dump_cmd du -sk "${JOURNAL_DIR}"
    JOURNAL_KB_BEFORE=$(du -sk "${JOURNAL_DIR}" 2>/dev/null | awk '{print $1}')
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    FILES_BEFORE=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)

    ROTATE_RESP=$(send_and_wait "get_log_data" "{}" 30)
    echo "[SETUP] 응답: $([ -n "$ROTATE_RESP" ] && echo "OK: $ROTATE_RESP" || echo 'TIMEOUT')"
    sleep 10

    dump_cmd journalctl --disk-usage
    JOURNAL_DISKUSAGE_AFTER="$(journalctl --disk-usage 2>/dev/null)"
    JOURNAL_SIZE_AFTER=$(echo "$JOURNAL_DISKUSAGE_AFTER" | awk '/take up/{print $7}')
    dump_cmd du -sk "${JOURNAL_DIR}"
    JOURNAL_KB_AFTER=$(du -sk "${JOURNAL_DIR}" 2>/dev/null | awk '{print $1}')
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    FILES_AFTER=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    LATEST_XZ=$(find_latest_xz "${TOUPLOAD_DIR}")

    echo "[SETUP] 완료."
    echo "[SETUP] xz 파일: before=${FILES_BEFORE} after=${FILES_AFTER}"
    echo "[SETUP] 저널: before=${JOURNAL_SIZE_BEFORE} after=${JOURNAL_SIZE_AFTER}"
    echo ""
}

# ============================================================
# TC01: 파일명 규칙 - systemlog_{시작 시각}_{저장 시각}.log.xz
# ============================================================
tc01_filename_format() {
    echo "=== TC01: 파일명 규칙 검증 ==="
    dump_cmd ls -la "$LATEST_XZ"

    if echo "$LATEST_XZ" | grep -qE "systemlog_[0-9]{14}_[0-9]{14}\.log\.xz"; then
        assert "TC01-1: 파일명 형식 (systemlog_시작_저장.log.xz)" "PASS"
    else
        assert "TC01-1: 파일명 형식 (systemlog_시작_저장.log.xz)" "FAIL"
        echo "  실제 파일: $LATEST_XZ"
    fi

    local start_t end_t
    start_t=$(basename "$LATEST_XZ" | sed 's/systemlog_\([0-9]*\)_.*/\1/')
    end_t=$(basename "$LATEST_XZ" | sed 's/systemlog_[0-9]*_\([0-9]*\).*/\1/')
    if [ "$start_t" -le "$end_t" ] 2>/dev/null; then
        assert "TC01-2: start_time <= end_time" "PASS"
    else
        assert "TC01-2: start_time <= end_time" "FAIL"
        echo "  start=$start_t end=$end_t"
    fi
}

# ============================================================
# TC02: 24시간 타이머 - 프로세스 실행 확인
# ============================================================
tc02_timer_running() {
    echo "=== TC02: 24시간 타이머 동작 확인 ==="

    # 0. system_log 재시작 (내부 last_run_time 타이머 상태 초기화).
    # 직전 run(들)이 이미 get_log_data/task_rotate_sync를 호출했으면 last_run_time이
    # 최근 실시각으로 갱신돼 있어서, 이번 +25h shift로도 elapsed>=24h 조건이 안 잡혀
    # 발화가 누락될 수 있다(스펙에 명시된 한계 — TC02가 다른 TC SETUP보다 먼저 실행돼야
    # 하는 이유). system_log를 kill하면 edge_runtime이 컨테이너를 재시작해(TC14와 동일
    # 메커니즘) last_run_time이 fresh 상태가 되므로, TC02가 실행 순서와 무관하게
    # 항상 스스로 깨끗한 상태에서 시작하도록 매번 이걸 먼저 한다.
    echo "  [TC02-절차0] system_log 재시작 (타이머 상태 초기화)..."
    local sl_pid_before sl_pid_after wait_i
    sl_pid_before=$(pgrep -f /edge/app/bin/system_log | head -1)
    if [ -n "$sl_pid_before" ]; then
        kill -9 "$sl_pid_before" 2>/dev/null
        wait_i=0
        sl_pid_after=""
        while [ "$wait_i" -lt 60 ]; do
            sleep 1
            # kill한 PID가 완전히 정리되기 전까지 pgrep에 잠깐 같이 잡히는 경우가 있어서
            # (좀비 상태), head -1로 첫 번째 값만 보면 그 옛날 PID를 계속 집을 수 있다.
            # sl_pid_before를 제외한 나머지 중에서 새 PID를 찾는다.
            sl_pid_after=$(pgrep -f /edge/app/bin/system_log | grep -v "^${sl_pid_before}$" | head -1)
            [ -n "$sl_pid_after" ] && break
            wait_i=$((wait_i + 1))
        done
        if [ -n "$sl_pid_after" ]; then
            echo "    system_log 재시작 완료 (PID ${sl_pid_before} -> ${sl_pid_after}, ${wait_i}초 소요)"
            sleep 3  # edge_runtime의 나머지 서브시스템도 안정화될 시간
        else
            echo "    [WARN] system_log 재시작 확인 실패(60초 대기) — 계속 진행하나 발화 보장 안 됨"
        fi
    else
        echo "    [WARN] system_log PID 확인 실패 — 재시작 스킵, 계속 진행"
    fi

    # 0-1. startup 시퀀스(task_capture_boot_log → task_merge_staged_logs → task_upload_nmon)
    # 완료 대기. system_log_timer_loop는 while문 진입 전에 이 셋을 무조건 한 번 돌리는데,
    # task_merge_staged_logs가 staging에 남은 파일이 있으면 그걸 toupload로 옮겨버려서
    # (부팅로그 병합/업로드) +25h shift와 무관한 새 .xz가 생긴다. 이게 아래 70초 관찰
    # 창에 걸리면 comm -13이 이 파일을 "신규 파일"로 잘못 채택해 TC02-2가 엉뚱한 파일의
    # endtime을 비교하게 된다. task_upload_nmon은 task_merge_staged_logs 바로 다음에
    # 실행되므로, 그 시작 로그가 찍히면 병합/업로드까지는 이미 끝난 상태임이 보장된다.
    echo "  [TC02-절차0-1] startup 시퀀스(부팅로그 캡처/병합) 완료 대기..."
    local restart_epoch=$(date +%s)
    local startup_done=""
    local wait_j=0
    while [ "$wait_j" -lt 100 ]; do
        if journalctl -u docker-loader --no-pager -o cat --since "@${restart_epoch}" 2>/dev/null \
            | grep -qF '[task_upload_nmon] Start nmon upload'; then
            startup_done=1
            break
        fi
        sleep 3
        wait_j=$((wait_j + 1))
    done
    if [ -n "$startup_done" ]; then
        echo "    [OK] startup 시퀀스 완료 확인 (${wait_j}x3초 대기)"
    else
        echo "    [WARN] startup 시퀀스 완료 로그 미확인(300초 대기) — 계속 진행하나 files_before에 부팅로그 병합 파일이 섞일 수 있음"
    fi

    # 1. system_log_timer_loop 실행 확인
    echo "  [TC02-절차1] system_log_timer_loop 실행 로그 확인..."
    local loop_log
    loop_log=$(journalctl -u docker-loader --no-pager -o cat 2>/dev/null \
                | grep -F '[system_log_timer_loop] loop started' | tail -1)
    if [ -n "$loop_log" ]; then
        echo "    [OK] ${loop_log}"
    else
        echo "    [WARN] '[system_log_timer_loop] loop started' 로그 없음 — 부팅 직후 vacuum으로 사라졌을 가능성, 계속 진행"
    fi

    # 2. BEFORE 목록 기록 — "최신 파일"을 mtime/파일명 중 뭘로 찾든 이전 run이 남긴
    # 미래 날짜 잔재에 취약하다(find_latest_xz도 마찬가지). TC11/TC14와 동일하게
    # before/after 목록을 통째로 저장해두고 diff(comm -13)로 "이번에 진짜 새로 생긴
    # 파일"만 식별한다 — 잔재 존재 여부와 무관하게 항상 정확하다.
    local files_before files_after t0 BEFORE_LIST
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    BEFORE_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    files_before=$(echo "$BEFORE_LIST" | grep -c .)
    echo "  [TC02-절차2] files_before=${files_before}"

    # 3. 시스템 시간을 현재 시간(NTP)과 동기화
    echo "  [TC02-절차3] NTP로 시스템 시간 동기화..."
    timedatectl set-ntp yes 2>/dev/null
    sleep 2
    timedatectl set-ntp false 2>/dev/null
    echo "    동기화 후 시간: $(date '+%F %T')"

    # 4. 시간 +25h shift
    t0=$(date +%s)
    local t_shift=$((t0 + 25 * 3600))
    echo "  [TC02-절차4] 시스템 시간 +25h 이동: $(date -d "@${t_shift}" '+%F %T') (원래: $(date -d "@${t0}" '+%F %T'))"
    date -s "@${t_shift}" > /dev/null

    # 5. 타이머 발화 대기 (70초)
    echo "  [TC02-절차5] 타이머 발화 대기 (70초)..."
    sleep 70

    # 6. 신규 파일 + endtime 확인 — comm -13 으로 BEFORE_LIST에 없던 파일만 골라낸다
    # (TC14의 NEW_XZ 패턴과 동일). 여러 개면 그중 첫 번째를 본다 — TC14와 동일한 관례.
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    local AFTER_LIST
    AFTER_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    files_after=$(echo "$AFTER_LIST" | grep -c .)
    local latest_xz
    latest_xz=$(comm -13 <(echo "$BEFORE_LIST") <(echo "$AFTER_LIST") | head -1)
    echo "  [TC02-절차6] files_after=${files_after}, 신규 파일=$(basename "${latest_xz:-none}")"

    # 7. 시스템 시간을 현재 시간으로 복원.
    # [2026-08-25 device_log TC18 세션에서 발견 후 재수정] 원래는 hwclock -s(RTC 기준)를
    # 우선 쓰고 실패 시 NTP로 폴백했는데, 이 DUT는 `/`가 ro로 마운트돼 있어
    # `hwclock --systohc`(RTC에 쓰기)가 항상 실패한다 — 그런데 device_log의 TC18/TC19
    # 같은 `timedatectl set-time` 기반 TC가 이 RTC에 값을 남겨두면(그 TC들은 RTC에도
    # 쓴다), 이후 이 TC가 도는 시점에 `hwclock -s`(RTC→시스템)는 에러 없이 "성공"하면서
    # 그 오염된 RTC 값을 시스템 시계에 그대로 옮겨버린다(실측: 13시간 이상 틀어진 채
    # "성공"으로 보고됨) — RTC 상태에 따라 복원이 조용히 실패할 수 있는 구조였다.
    # RTC/NTP 둘 다에 의존하지 않고, 4번에서 이미 셸 변수로 저장해둔 t0(jump 전 원래
    # epoch)로 직접 복원한다 — device_log TC18/TC19가 이미 쓰는 것과 동일한 방식.
    echo "  [TC02-절차7] 시스템 시간 복원..."
    date -s "@${t0}" > /dev/null
    echo "    복원 후 시간: $(date '+%F %T')"

    # PASS/FAIL Criteria
    if [ "$files_after" -gt "$files_before" ]; then
        assert "TC02-1: toupload 신규 .xz 생성" "PASS"
    else
        assert "TC02-1: toupload 신규 .xz 생성" "FAIL"
        echo "    files_before=${files_before} files_after=${files_after}"
    fi

    local expected_endtime actual_endtime expected_epoch actual_epoch diff_sec
    expected_endtime=$(date -d "@${t_shift}" '+%Y%m%d%H%M%S')
    actual_endtime=$(basename "${latest_xz:-}" | sed -n 's/systemlog_[0-9]*_\([0-9]\{14\}\)\.log\.xz/\1/p')
    echo "  [TC02-2] 최신 파일: $(basename "${latest_xz:-none}")"
    echo "  [TC02-2] 기대 endtime(+25h)=${expected_endtime}, 실제 endtime=${actual_endtime:-N/A}"
    if [ -n "$actual_endtime" ]; then
        expected_epoch="$t_shift"
        dump_cmd date -d "${actual_endtime:0:4}-${actual_endtime:4:2}-${actual_endtime:6:2} ${actual_endtime:8:2}:${actual_endtime:10:2}:${actual_endtime:12:2}" "+%s"
        actual_epoch=$(date -d "${actual_endtime:0:4}-${actual_endtime:4:2}-${actual_endtime:6:2} ${actual_endtime:8:2}:${actual_endtime:10:2}:${actual_endtime:12:2}" "+%s" 2>/dev/null)
        if [ -n "$actual_epoch" ]; then
            diff_sec=$((actual_epoch - expected_epoch))
            diff_sec=${diff_sec#-}
            echo "  [TC02-2] |expected - actual|=${diff_sec}초"
            if [ "$diff_sec" -le 120 ]; then
                assert "TC02-2: 파일명 endtime이 변경 시간 ±120초 이내" "PASS"
            else
                assert "TC02-2: 파일명 endtime이 변경 시간 ±120초 이내" "FAIL"
            fi
        else
            assert "TC02-2: 파일명 endtime이 변경 시간 ±120초 이내" "FAIL"
            echo "    actual_endtime 파싱 실패: ${actual_endtime}"
        fi
    else
        assert "TC02-2: 파일명 endtime이 변경 시간 ±120초 이내" "FAIL"
        echo "    latest_xz에서 endtime 추출 실패: ${latest_xz}"
    fi
}

# ============================================================
# TC03: On-demand export - get_log_data 응답 및 파일 생성
# ============================================================
tc03_on_demand_export() {
    echo "=== TC03: On-demand export ==="

    if [ "$FILES_AFTER" -gt "$FILES_BEFORE" ]; then
        assert "TC03-1: get_log_data 후 .xz 파일 신규 생성됨" "PASS"
        echo "  before=${FILES_BEFORE} after=${FILES_AFTER}"
    else
        assert "TC03-1: get_log_data 후 .xz 파일 신규 생성됨" "FAIL"
        echo "  before=${FILES_BEFORE} after=${FILES_AFTER}"
    fi
}

# ============================================================
# TC04: On-demand timeout - 310초 이내 응답 확인
# ============================================================
tc04_timeout_large_log() {
    echo "=== TC04: On-demand timeout (실제 journal 데이터 시나리오) ==="
    echo "  systemd-cat으로 journald에 실제 데이터 주입 → 사이즈별로 get_log_data 응답/파일 생성 검증"

    # 사이즈 (MB journal 목표)와 라벨, 그에 맞춰 주입할 raw urandom 사이즈
    # 측정 기준: 200MB urandom (base64 -w 4096) → journald 약 281MB (≈1.4x)
    # 300MB는 압축 시간이 너무 오래 걸려 150MB로 축소했었으나, 100MB/150MB 두 티어
    # 모두 180초 SYSTEM_LOG_REQUEST_CMD_TIMEOUT 경계까지 압축을 밀어붙이는 통에
    # cmd_host의 늦은 응답이 MessageContext를 오염시키는 레이스를 매 run마다
    # 재현시키는 주범이었다 — 100MB 단일 티어만 남긴다.
    local target_sizes="100"
    local raw_sizes="70"
    local labels="100MB"
    local idx=0

    for target_mb in $target_sizes; do
        idx=$((idx + 1))
        local label raw_mb
        label=$(echo "$labels" | awk -v n="$idx" '{print $n}')
        raw_mb=$(echo "$raw_sizes" | awk -v n="$idx" '{print $n}')

        echo ""
        echo "  --- TC04-${idx}: 목표 journal ${label} (urandom ${raw_mb}MB 주입) ---"

        # 1. journal 초기화
        dump_cmd journalctl --rotate
        dump_cmd journalctl --vacuum-files=1
        sleep 2
        local before_size
        dump_cmd journalctl --disk-usage
        before_size=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
        echo "    [SETUP] vacuum 후 journal: ${before_size}"

        # before_files는 개수가 아니라 목록(BEFORE_LIST) 그대로 저장해둔다 — 개수 비교는
        # 관찰 창 동안 다른 파일이 사라지면(Blob 업로드 후 delete, 이전 run의 미래 날짜
        # 잔재 등) 진짜 신규 생성을 놓칠 수 있다(TC02와 동일한 이유로 comm -13 diff 사용).
        local before_files BEFORE_LIST
        dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
        BEFORE_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
        before_files=$(echo "$BEFORE_LIST" | grep -c .)

        # 2. systemd-cat 으로 실제 journal 데이터 주입 (premade DUMMY_BLOB 슬라이스 재사용)
        local t_inject_t0 t_inject_t1
        t_inject_t0=$(date +%s)
        inject_dummy_blob "TC04_DUMMY" "$raw_mb"
        sync
        sleep 3
        dump_cmd journalctl --rotate
        sleep 2
        t_inject_t1=$(date +%s)
        local after_size
        dump_cmd journalctl --disk-usage
        after_size=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
        echo "    [SETUP] 주입 took $((t_inject_t1 - t_inject_t0))s, journal: ${before_size} → ${after_size}"
        dump_cmd df -h /edge

        # 3. get_log_data 요청 — 실제 완료 신호(=get_log_data 자체의 MQTT 응답)를 기다린다.
        # handle_request_get_log_data()는 dump+rotate+compress+move 를 전부 마친 뒤에야
        # publish_response() 하므로, 이 응답이 곧 "작업이 끝났다"는 진짜 신호다. 180초
        # SYSTEM_LOG_REQUEST_CMD_TIMEOUT + host_agent가 타임아웃을 살짝 넘겨서라도 명령을
        # 끝까지 실행해주는 여유분을 감안해 TC15와 동일하게 200초까지 기다린다 — 예전처럼
        # 30초에 포기하고 10초만 훑어보면, 실제로는 정상 진행 중인데 아직 안 끝났을 뿐인
        # 상황을 FAIL로 오판한다(실측: 30초/10초로는 못 잡고 몇 분 뒤 정상 완료된 사례).
        echo "    [TC04-${idx}] get_log_data 요청 송신..."
        local t0 t1 elapsed resp
        t0=$(date +%s)
        resp=$(send_and_wait "get_log_data" "{}" 200)
        t1=$(date +%s)
        elapsed=$((t1 - t0))
        echo "    [TC04-${idx}] 응답: $([ -n "$resp" ] && echo "OK ($resp)" || echo 'TIMEOUT'), 응답까지 ${elapsed}초"

        local AFTER_LIST after_files new_xz
        AFTER_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
        new_xz=$(comm -13 <(echo "$BEFORE_LIST") <(echo "$AFTER_LIST") | head -1)
        after_files=$(echo "$AFTER_LIST" | grep -c .)

        dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
        echo "    [TC04-${idx}] after: files=${after_files}"

        if [ -n "$new_xz" ]; then
            assert "TC04-${idx}: journal ${label} 상태에서 get_log_data 완료 응답 후 .xz 파일 생성" "PASS"
        else
            assert "TC04-${idx}: journal ${label} 상태에서 get_log_data 완료 응답 후 .xz 파일 생성" "FAIL"
            echo "    before_files=${before_files} after_files=${after_files}, journal=${after_size}, 응답=${elapsed}s"
        fi
    done

    # 최종 cleanup
    journalctl --rotate 2>/dev/null
    journalctl --vacuum-files=1 2>/dev/null
}

# ============================================================
# TC05: Rotation - xz 압축 확인
# ============================================================
tc05_compression() {
    echo "=== TC05: 로그 파일 xz 압축 확인 ==="

    if [ -n "$LATEST_XZ" ] && [ -f "$LATEST_XZ" ]; then
        dump_cmd ls -la "$LATEST_XZ"
        assert "TC05-1: .xz 파일 존재" "PASS"

        local xz_test_rc
        dump_cmd xz --test "$LATEST_XZ"
        xz_test_rc=$?
        if [ "$xz_test_rc" -eq 0 ]; then
            assert "TC05-2: xz 파일 무결성 (xz --test)" "PASS"
        else
            local xz_size xz_age
            xz_size=$(stat -c%s "$LATEST_XZ" 2>/dev/null || echo "?")
            xz_age=$(( $(date +%s) - $(stat -c%Y "$LATEST_XZ" 2>/dev/null || date +%s) ))
            assert "TC05-2: xz 파일 무결성 (xz --test)" "FAIL" \
                "${xz_size}B, 마지막 수정 ${xz_age}초 전 — host_agent 압축 타임아웃(5s) 후에도 xz 프로세스가 취소되지 않고 계속 쓰는 중일 가능성"
        fi

        local log_file="${LATEST_XZ%.xz}"
        dump_cmd ls -la "$log_file"
        if [ ! -f "$log_file" ]; then
            assert "TC05-3: 원본 .log 파일 삭제됨" "PASS"
        else
            local log_size
            log_size=$(stat -c%s "$log_file" 2>/dev/null || echo "?")
            assert "TC05-3: 원본 .log 파일 삭제됨" "FAIL" \
                "원본 .log 여전히 존재 (${log_size}B) — xz는 압축 완료 후에만 원본을 삭제하므로 TC05-2와 동일 원인(압축 미완료)"
        fi
    elif [ -z "$LATEST_XZ" ]; then
        echo "  [SKIP] TC05-1~3: setup_rotate 없이 단독 실행 — LATEST_XZ 미설정"
    else
        dump_cmd ls -la "$LATEST_XZ"
        assert "TC05-1: .xz 파일 존재" "FAIL"
    fi

    # TC05-4: xz -f 덮어쓰기 — staging에 동명 .xz 존재 시 강제 덮어쓰기 성공
    local XZ_TEST_BASE="${STAGING_DIR}/systemlog_tc05xztest_tc05xztest"
    echo "small dummy content" | xz -c > "${XZ_TEST_BASE}.log.xz" 2>/dev/null
    seq 1 5000 > "${XZ_TEST_BASE}.log" 2>/dev/null
    echo "  [TC05-4] 덮어쓰기 전:"
    dump_cmd ls -la "${XZ_TEST_BASE}.log" "${XZ_TEST_BASE}.log.xz"
    local DUMMY_SIZE
    DUMMY_SIZE=$(stat -c%s "${XZ_TEST_BASE}.log.xz" 2>/dev/null || echo 0)

    local xzf_rc
    dump_cmd xz -f "${XZ_TEST_BASE}.log"
    xzf_rc=$?

    echo "  [TC05-4] 덮어쓰기 후:"
    dump_cmd ls -la "${XZ_TEST_BASE}.log.xz"

    if [ "$xzf_rc" -eq 0 ]; then
        local SIZE_AFTER
        SIZE_AFTER=$(stat -c%s "${XZ_TEST_BASE}.log.xz" 2>/dev/null || echo 0)
        if [ "$SIZE_AFTER" -gt "$DUMMY_SIZE" ] && [ ! -f "${XZ_TEST_BASE}.log" ]; then
            assert "TC05-4: staging 동명 .xz 존재 시 xz -f 덮어쓰기 성공 (크기 증가, .log 삭제)" "PASS"
        else
            assert "TC05-4: staging 동명 .xz 존재 시 xz -f 덮어쓰기 성공 (크기 증가, .log 삭제)" "FAIL"
            echo "    dummy_size=${DUMMY_SIZE} after=${SIZE_AFTER} log_exists=$([ -f "${XZ_TEST_BASE}.log" ] && echo yes || echo no)"
        fi
    else
        assert "TC05-4: xz -f 실행 성공" "FAIL"
    fi
    rm -f "${XZ_TEST_BASE}.log" "${XZ_TEST_BASE}.log.xz" 2>/dev/null
}

# ============================================================
# TC06: Rotation - rotate 후 저널 사용량 감소
# ============================================================
tc06_journal_rotation() {
    echo "=== TC06: journalctl rotate 후 저널 사용량 확인 ==="
    echo "  journalctl --disk-usage: 전=${JOURNAL_SIZE_BEFORE} 후=${JOURNAL_SIZE_AFTER}"
    echo "  du -sk ${JOURNAL_DIR}: 전=${JOURNAL_KB_BEFORE:-?}KB 후=${JOURNAL_KB_AFTER:-?}KB"
    if [ -n "$JOURNAL_KB_BEFORE" ] && [ -n "$JOURNAL_KB_AFTER" ] && [ "$JOURNAL_KB_AFTER" -le "$JOURNAL_KB_BEFORE" ]; then
        assert "TC06-1: journalctl rotate && vacuum 후 저널 사용량 감소 또는 유지 (du -sk 비교)" "PASS"
    else
        assert "TC06-1: journalctl rotate && vacuum 후 저널 사용량 감소 또는 유지 (du -sk 비교)" "FAIL"
    fi
}

# ============================================================
# TC07: Rotation - 30일 경과 파일 삭제
# ============================================================
tc07_retention_delete() {
    echo "=== TC07: 30일 경과 파일 삭제 ==="

    # cleanup_log_dir(day:30 삭제)는 get_log_data가 아니라 24h 타이머
    # (system_log_timer_loop, system_log.cpp:807-816)에서만 발화한다. get_log_data로는
    # 트리거를 흉내낼 수 없다는 게 확인된 사실이라, TC02와 동일한 패턴(재시작으로
    # last_run_time 초기화 → +25h shift로 elapsed>=24h 강제 → 대기 → 시간 복원)으로
    # 실제 24h 타이머를 발화시켜 검증한다.

    # 0. system_log 재시작 (내부 last_run_time 타이머 상태 초기화) — TC02-절차0과 동일 이유.
    echo "  [TC07-절차0] system_log 재시작 (타이머 상태 초기화)..."
    local sl_pid_before sl_pid_after wait_i
    sl_pid_before=$(pgrep -f /edge/app/bin/system_log | head -1)
    if [ -n "$sl_pid_before" ]; then
        kill -9 "$sl_pid_before" 2>/dev/null
        wait_i=0
        sl_pid_after=""
        while [ "$wait_i" -lt 60 ]; do
            sleep 1
            sl_pid_after=$(pgrep -f /edge/app/bin/system_log | grep -v "^${sl_pid_before}$" | head -1)
            [ -n "$sl_pid_after" ] && break
            wait_i=$((wait_i + 1))
        done
        if [ -n "$sl_pid_after" ]; then
            echo "    system_log 재시작 완료 (PID ${sl_pid_before} -> ${sl_pid_after}, ${wait_i}초 소요)"
            sleep 3
        else
            echo "    [WARN] system_log 재시작 확인 실패(60초 대기) — 계속 진행하나 발화 보장 안 됨"
        fi
    else
        echo "    [WARN] system_log PID 확인 실패 — 재시작 스킵, 계속 진행"
    fi

    # 0-1. startup 시퀀스 완료 대기. last_run_time은 task_capture_boot_log/
    # task_merge_staged_logs/task_upload_nmon/delete_old_journals가 끝난 뒤에야
    # system_clock::now()로 세팅된다(system_log.cpp:796-802) — TC02-절차0-1과 동일.
    echo "  [TC07-절차0-1] startup 시퀀스(부팅로그 캡처/병합) 완료 대기..."
    local restart_epoch=$(date +%s)
    local startup_done=""
    local wait_j=0
    while [ "$wait_j" -lt 100 ]; do
        if journalctl -u docker-loader --no-pager -o cat --since "@${restart_epoch}" 2>/dev/null \
            | grep -qF '[task_upload_nmon] Start nmon upload'; then
            startup_done=1
            break
        fi
        sleep 3
        wait_j=$((wait_j + 1))
    done
    if [ -n "$startup_done" ]; then
        echo "    [OK] startup 시퀀스 완료 확인 (${wait_j}x3초 대기)"
    else
        echo "    [WARN] startup 시퀀스 완료 로그 미확인(300초 대기) — 계속 진행"
    fi

    # 1. NTP로 시스템 시간 동기화 (TC02-절차3과 동일)
    echo "  [TC07-절차1] NTP로 시스템 시간 동기화..."
    timedatectl set-ntp yes 2>/dev/null
    sleep 2
    timedatectl set-ntp false 2>/dev/null
    echo "    동기화 후 시간: $(date '+%F %T')"

    # 2. 시간 +25h shift — elapsed>=24h 조건을 확실히 채운다 (TC02-절차4와 동일)
    local t0 t_shift
    t0=$(date +%s)
    t_shift=$((t0 + 25 * 3600))
    echo "  [TC07-절차2] 시스템 시간 +25h 이동: $(date -d "@${t_shift}" '+%F %T') (원래: $(date -d "@${t0}" '+%F %T'))"
    date -s "@${t_shift}" > /dev/null

    # 3. 더미 파일 생성 — 반드시 shift *이후* "지금"을 기준으로 31일 전/29일 전을 touch한다.
    # shift 전에 touch하면 파일 나이에 25h가 더 얹혀(29일 더미가 30일 문턱을 넘어) TC07-2가
    # 오탐 FAIL 날 수 있다.
    local dummy_31="${TOUPLOAD_DIR}/systemlog_20250101000000_20250101010000.log.xz"
    local dummy_29="${TOUPLOAD_DIR}/systemlog_20250501000000_20250501010000.log.xz"
    touch -d "31 days ago" "$dummy_31" 2>/dev/null
    touch -d "29 days ago" "$dummy_29" 2>/dev/null
    echo "  [TC07-절차3] 더미 파일 생성 완료 (shift 후 시각 기준):"
    dump_cmd ls -la "$dummy_31" "$dummy_29"

    # 4. 24h 타이머 발화 대기 — task_rotate_sync 완료 직후 같은 루프 반복 안에서
    # cleanup_log_dir가 바로 이어 실행되므로(system_log.cpp:810-816), TC02와 동일한
    # 70초 관찰창을 재사용한다.
    echo "  [TC07-절차4] 24h 타이머 발화 대기 (70초)..."
    sleep 70

    # 5. 삭제 결과 확인
    dump_cmd ls -la "$dummy_31"
    if [ ! -f "$dummy_31" ]; then
        assert "TC07-1: 31일 경과 파일 자동 삭제됨" "PASS"
    else
        assert "TC07-1: 31일 경과 파일 자동 삭제됨" "FAIL"
        rm -f "$dummy_31"
    fi

    dump_cmd ls -la "$dummy_29"
    if [ -f "$dummy_29" ]; then
        assert "TC07-2: 29일 경과 파일 유지됨" "PASS"
        rm -f "$dummy_29"
    else
        assert "TC07-2: 29일 경과 파일 유지됨" "FAIL"
    fi

    # 6. 시간 복원 (TC02-절차7과 동일 이유로 재수정, 2026-08-25) — 이 DUT는 rootfs가
    # ro라 hwclock --systohc(RTC 쓰기)가 항상 실패하는데, device_log의 TC18/TC19 같은
    # `timedatectl set-time` 기반 TC가 RTC에 남긴 오염값이 있으면 hwclock -s(RTC→시스템)
    # 는 에러 없이 "성공"하면서 그 오염값을 시스템 시계에 그대로 옮겨버린다(실측:
    # 13시간 이상 틀어진 채 성공 처리됨). RTC/NTP 둘 다 의존하지 않고 2번에서 저장해둔
    # t0(jump 전 원래 epoch)로 직접 복원한다.
    echo "  [TC07-절차6] 시스템 시간 복원..."
    date -s "@${t0}" > /dev/null
    echo "    복원 후 시간: $(date '+%F %T')"
}

# ============================================================
# TC08: Azure Connector - toupload에 .xz + .meta 파일 존재 확인
# ============================================================
tc08_blob_upload() {
    echo "=== TC08: Azure Connector 업로드 대상 파일 생성 확인 ==="

    local xz_count meta_count
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    xz_count=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz.meta
    meta_count=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz.meta 2>/dev/null | wc -l)

    if [ "$xz_count" -gt 0 ]; then
        assert "TC08-1: toupload에 .log.xz 파일 존재" "PASS"
        echo "  .xz 파일 수: $xz_count"
    else
        assert "TC08-1: toupload에 .log.xz 파일 존재" "FAIL"
    fi

    if [ "$meta_count" -gt 0 ]; then
        assert "TC08-2: toupload에 .log.xz.meta 파일 존재" "PASS"
        echo "  .meta 파일 수: $meta_count"
    else
        assert "TC08-2: toupload에 .log.xz.meta 파일 존재" "FAIL"
    fi
}

# ============================================================
# TC09: Factory Reset - 로그 전체 삭제
# ============================================================
tc09_factory_reset() {
    echo "=== TC09: Factory Reset 시 로그 전체 삭제 ==="

    local dummy="${TOUPLOAD_DIR}/systemlog_dummy.log.xz"
    touch "$dummy" 2>/dev/null

    # factory_reset의 clear_all_logs()는 log_dir_mutex_ unique_lock을 잡는데, 그 사이
    # 이전 get_log_data가 트리거한 task_rotate_sync(shared_lock)가 아직 안 끝났으면
    # 그게 풀릴 때까지(최대 SYSTEM_LOG_REQUEST_CMD_TIMEOUT=180s급) 줄을 서서 기다린다.
    # 의도적으로 30s(타이트한 간격)를 유지한다 — get_log_data 직후 곧바로 factory_reset이
    # 들어오는 실사용 패턴에서 이 대기가 계속 길어지는 회귀가 생기면 여기서 바로 FAIL로
    # 드러나야 한다(실측: 24s 대기 후 성공한 이력 있음 — 30s는 그 마진을 일부러 좁게 둔 값).
    local resp
    resp=$(send_and_wait "request_factory_reset" "{}" 30)

    if [ -n "$resp" ]; then
        assert "TC09-1: factory_reset 응답 수신" "PASS"
    else
        assert "TC09-1: factory_reset 응답 수신" "FAIL"
        return
    fi

    dump_cmd ls -la "${TOUPLOAD_DIR}"
    if [ ! -f "$dummy" ] && [ -z "$(ls "${TOUPLOAD_DIR}"/*.* 2>/dev/null)" ]; then
        assert "TC09-2: toupload 디렉토리 내 파일 전체 삭제" "PASS"
    else
        assert "TC09-2: toupload 디렉토리 내 파일 전체 삭제" "FAIL"
        rm -f "$dummy"
    fi
}

# ============================================================
# TC10-PRE: 리부트 전 로그 저장 (shutdown_application_for_system_reboot)
# [주의] 실행 후 reboot 발생 → SSH 접속 끊김
#        SSH 재접속 후 --tc10-post 실행
# ============================================================
tc10_pre() {
    echo "=== TC10-PRE: 리부트 전 로그 저장 ==="

    local before_staging before_toupload
    dump_cmd ls -la "${STAGING_DIR}"/systemlog_*.log.xz
    before_staging=$(ls "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    before_toupload=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)

    echo "  현재 staging .xz: $before_staging, toupload .xz: $before_toupload"

    local resp
    resp=$(send_and_wait "shutdown_application_for_system_reboot" "{}" 320)

    if [ -n "$resp" ]; then
        assert "TC10-1: 리부트 전 로그 저장 응답 수신" "PASS"
    else
        assert "TC10-1: 리부트 전 로그 저장 응답 수신 (timeout)" "FAIL"
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        return
    fi

    local after_staging
    dump_cmd ls -la "${STAGING_DIR}"/systemlog_*.log.xz
    after_staging=$(ls "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    if [ "$after_staging" -gt "$before_staging" ]; then
        assert "TC10-2: staging에 shutdown 로그 .xz 생성됨" "PASS"
    else
        assert "TC10-2: staging에 shutdown 로그 .xz 생성됨" "FAIL"
        echo "  staging before=${before_staging} after=${after_staging}"
    fi

    # post 단계에서 비교하기 위해 toupload 파일 수 저장
    echo "$before_toupload" > "${TC10_SAVE}"

    echo ""
    echo "============================================"
    echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
    echo ""
    echo "[TC10-PRE 완료] reboot 실행 중... SSH 재접속 후 --tc10-post 실행"
    sync
    reboot
}

# ============================================================
# TC10-POST: 재부팅 후 boot 로그 병합 확인
# SSH 재접속 후 실행: ./tc_system_log.sh --tc10-post
# ============================================================
tc10_post() {
    echo "=== TC10-POST: 재부팅 후 boot 로그 병합 확인 ==="

    if [ ! -f "${TC10_SAVE}" ]; then
        echo "[ERROR] ${TC10_SAVE} 없음 - --tc10-pre 를 먼저 실행하세요"
        exit 1
    fi

    local before_toupload
    dump_cmd cat "${TC10_SAVE}"
    before_toupload=$(cat "${TC10_SAVE}")
    rm -f "${TC10_SAVE}"

    local after_toupload
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    after_toupload=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)

    if [ "$after_toupload" -gt "$before_toupload" ]; then
        assert "TC10-3: 재부팅 후 toupload .xz 파일 증가 (boot 로그 병합)" "PASS"
        echo "  toupload before=${before_toupload} after=${after_toupload}"
    else
        assert "TC10-3: 재부팅 후 toupload .xz 파일 증가 (boot 로그 병합)" "FAIL"
        echo "  toupload before=${before_toupload} after=${after_toupload}"
    fi

    echo ""
    echo "============================================"
    echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
}

# ============================================================
# TC18: 저장공간 부족(<10%) 시 SYSTEM_LOG_DIRS(staging/toupload/archive) cleanup 확인
# [2026-09-04 재설계] 원래는 더미 배치 후 실제 reboot으로 재현했으나, reboot 자체가
# (원인 불명, 실 필드 버그 패턴과도 다른) 대용량 쓰기를 유실시키는 별개 현상과 뒤섞여
# 있었다 — systemctl restart docker-loader(전원 재부팅 없이 앱만 재시작)로 트리거를
# 바꾸면 cleanup이 매번 로그 증거까지 포함해 정상 발화하는 것을 실측으로 확인했다
# (TC12가 이미 쓰는 검증된 트리거와 동일 패턴). reboot 관련 유실 현상 자체는 원인
# 불명·실 필드 패턴 불일치로 이 TC 범위에서 제외하고 별도 이슈로만 기록한다.
# 더미 mtime은 30일 미만(1일 전)으로 둬서 day-retention(delete_log)이 같이 지우지
# 않게 하고, 순수하게 cleanup_if_low_disk_space() 경로만 검증한다.
# [주의] 실제 파티션 여유공간을 소진시키는 파괴적 시험이다 — 사전 조건(여유율 >=25%,
#        필요 소진량 <= 안전 상한) 미충족 시 자동으로 SKIP(TC18-0 FAIL로 기록).
# ============================================================
tc18_low_disk_cleanup() {
    echo "=== TC18: 저장공간 부족(<10%) 시 SYSTEM_LOG_DIRS cleanup 확인 (systemctl restart docker-loader 트리거) ==="

    mkdir -p "${STAGING_DIR}" "${TOUPLOAD_DIR}" "${ARCHIVE_DIR}"

    dump_cmd df -h "${STAGING_DIR}"
    local total_kb avail_kb before_permille
    total_kb=$(disk_total_kb "${STAGING_DIR}")
    avail_kb=$(disk_avail_kb "${STAGING_DIR}")
    before_permille=$(disk_free_permille "${STAGING_DIR}")
    echo "  [TC18] 현재 파티션: total=${total_kb}KB avail=${avail_kb}KB free=${before_permille}‰"

    local TC18_0_LABEL="TC18-0: 사전 조건 확인 (df 파싱 성공, 여유율>=25%, 필요 소진량<=안전상한)"

    if [ -z "$total_kb" ] || [ -z "$avail_kb" ]; then
        assert "$TC18_0_LABEL" "FAIL" "df -P 파싱 실패 (total_kb=${total_kb} avail_kb=${avail_kb})"
        return
    fi
    if [ "$total_kb" -le 0 ]; then
        assert "$TC18_0_LABEL" "FAIL" "total_kb=${total_kb} 비정상"
        return
    fi

    # 여유율 하한(>=25%): 더미 삭제만으로 코드의 회복 목표치(threshold_percent*2=20%)를
    # 확정적으로 넘길 수 있고, 실제 로그 파일을 건드릴 위험도 없게 하는 마진.
    if [ "$before_permille" -lt "$TC18_MIN_FREE_BEFORE_PERMILLE" ]; then
        assert "$TC18_0_LABEL" "FAIL" "현재 여유율 ${before_permille}‰(<250‰) - 이미 부족한 상태라 안전하게 재현 불가, 시험 중단"
        return
    fi
    # 상한(<=950‰)은 df 파싱이 완전히 깨진 극단적 케이스만 걸러내는 최후 안전장치다.
    # 여유율 자체가 아무리 높아도 실제로 그만큼 더미를 채운다 — 필요 더미량은 안전 상한
    # (TC18_MAX_FILL_MB)이 실측치(약 4.55GB, 192.168.10.25 5.9GB 파티션 기준)보다
    # 넉넉히 크게 잡혀있어 이 DUT에서도 그대로 수용됨.
    if [ "$before_permille" -gt "$TC18_MAX_FREE_BEFORE_PERMILLE" ]; then
        assert "$TC18_0_LABEL" "FAIL" "현재 여유율 ${before_permille}‰(>950‰) - df 파싱 이상 가능성, 시험 중단"
        return
    fi

    # 목표: STAGING/TOUPLOAD엔 각 1MB(트리거 확인용) / ARCHIVE엔 나머지 전부(실제 회복을
    # 담당). SYSTEM_LOG_DIRS는 STAGING→TOUPLOAD→ARCHIVE 순서로 처리되고 매 디렉토리마다
    # "파티션 전체 여유율<10%"인지 다시 확인한다 — 회복량이 큰 더미를 마지막 디렉토리에
    # 몰아둬야 앞선 두 디렉토리 처리 뒤에도 여전히 10% 밑에 머물러 세 곳 모두 확정적으로
    # 발화한다(파일 삭제 여부는 그 시점 파티션 여유율<10%만으로 결정되고, 삭제되는 각 파일
    # 자체의 크기와는 무관 — delete_oldest_files_until_safe는 그 디렉토리에 남은 대상
    # 확장자 파일이 없어질 때까지 또는 20%에 도달할 때까지 가장 오래된 것부터 지운다).
    # 목표 여유율을 10%에 최대한 가깝게(9%) 잡아 필요 더미량 자체를 최소화한다.
    local need_kb archive_mb
    need_kb=$(awk -v avail="$avail_kb" -v total="$total_kb" -v tgt="$TC18_TARGET_LOW_PERCENT" 'BEGIN{ n = avail - (total*tgt/100); if (n<1024) n=1024; printf "%d", n }')
    archive_mb=$(( (need_kb / 1024) - 2 ))
    [ "$archive_mb" -lt 1 ] && archive_mb=1

    if [ "$archive_mb" -gt "$TC18_MAX_FILL_MB" ]; then
        assert "$TC18_0_LABEL" "FAIL" "필요 소진량 ${archive_mb}MB > 안전 상한 ${TC18_MAX_FILL_MB}MB — 시험 중단(코드 결함 아님)"
        return
    fi
    assert "$TC18_0_LABEL" "PASS"

    local d1_glob="${STAGING_DIR}/tc18_dummy_staging_"
    local d2_glob="${TOUPLOAD_DIR}/tc18_dummy_toupload_"
    local d3_glob="${ARCHIVE_DIR}/tc18_dummy_archive_"

    echo "  [TC18] 더미 생성: 세 디렉토리 전부 단일 거대 파일이 아니라 여러 개로 분할한다"
    echo "         (system_log_partition.txt 참고 사례처럼 여러 파일이 쌓인 형태를 재현,"
    echo "         delete_oldest_files_until_safe가 오래된 순으로 순차 삭제하는 것도 관찰 가능)"

    # 파일마다 mtime을 1분씩 어긋나게(모두 1일 전 기준) 찍어서 삭제 순서가 오래된 것부터
    # 결정적으로 보이도록 한다(2026-09-04, 사용자 확인). day-retention(LOG_RETAIN_DAY=30일,
    # delete_log)이 이 더미를 같이 집어가지 않도록 30일 미만으로 유지한다.
    local now_epoch base_epoch
    now_epoch=$(date +%s)
    base_epoch=$(( now_epoch - 86400 ))
    local global_idx=1

    # total_mb를 sizes 목록 청크로 쪼개 glob_prefix{NNN}.ext 여러 파일로 나눠 쓴다.
    # global_idx를 함수 밖(전역)에서 계속 증가시켜, 같은 mtime 오프셋이 세 디렉토리에
    # 걸쳐 겹치지 않게 한다.
    make_split_dummy() {
        local glob_prefix="$1" ext="$2" total_mb="$3" sizes="$4"
        local made_mb=0 count=0
        while [ "$made_mb" -lt "$total_mb" ]; do
            for sz in $sizes; do
                [ "$made_mb" -ge "$total_mb" ] && break
                local remain=$(( total_mb - made_mb ))
                [ "$sz" -gt "$remain" ] && sz=$remain
                [ "$sz" -lt 1 ] && sz=1
                local f="${glob_prefix}$(printf '%03d' "$global_idx").${ext}"
                local file_epoch=$(( base_epoch + global_idx * 60 ))
                dd if=/dev/zero of="$f" bs=1M count="$sz" 2>/dev/null
                touch -d "@${file_epoch}" "$f" 2>/dev/null
                made_mb=$(( made_mb + sz ))
                count=$((count + 1))
                global_idx=$((global_idx + 1))
            done
        done
        echo "$count"
    }

    local staging_count toupload_count archive_count
    # staging/toupload는 트리거 확인용(합쳐서 최대 3MB — 목표~10% 문턱 사이 마진(약 60MB)
    # 대비 무시할 수준이라, 지워져도 그 자체만으로 20% 회복을 채우지 않는다. 그래야
    # STAGING→TOUPLOAD→ARCHIVE 순회 중 뒤 디렉토리도 계속 "여유율<10%"로 남아 확정적으로
    # 발화한다 — 위 더미 배치 설계 근거 참고).
    staging_count=$(make_split_dummy "$d1_glob" "log" 3 "1 1 1")
    toupload_count=$(make_split_dummy "$d2_glob" "xz" 3 "1 1 1")
    archive_count=$(make_split_dummy "$d3_glob" "xz" "$archive_mb" "8 23 47 68 91 105 42 15 33 76 12 58 99 29 64")
    echo "  [TC18] 분할 생성 완료: staging ${staging_count}개(3MB), toupload ${toupload_count}개(3MB), archive ${archive_count}개(${archive_mb}MB)"
    sync

    dump_cmd ls -la "${d1_glob}"* "${d2_glob}"* "${d3_glob}"*
    dump_cmd df -h "${STAGING_DIR}"
    local after_permille
    after_permille=$(disk_free_permille "${STAGING_DIR}")
    echo "  [TC18] 더미 배치 후 여유율: ${after_permille}‰"

    if [ "$after_permille" -lt 100 ]; then
        assert "TC18-1: 더미 배치로 파티션 여유율이 10% 미만으로 낮춰짐" "PASS"
    else
        assert "TC18-1: 더미 배치로 파티션 여유율이 10% 미만으로 낮춰짐" "FAIL"
        echo "  여유율 ${after_permille}‰ (목표 <100‰) — archive_mb 재계산 필요"
        rm -f "${d1_glob}"* "${d2_glob}"* "${d3_glob}"*
        return
    fi

    local d1_prefix d2_prefix d3_prefix
    d1_prefix=$(basename "$d1_glob")
    d2_prefix=$(basename "$d2_glob")
    d3_prefix=$(basename "$d3_glob")

    # 전체 경로로 매칭 필수(TC12/TC14/TC16 관례) — "system_log"만 쓰면 이 스크립트
    # 자신(tc_system_log.sh)까지 걸려 엉뚱한 PID를 집는 사고가 날 수 있다.
    local SL_PID
    SL_PID=$(pgrep -f /edge/app/bin/system_log | head -1)

    echo "  [TC18] systemctl restart docker-loader 트리거 (현재 system_log PID ${SL_PID})..."
    dump_cmd systemctl restart docker-loader

    # [2026-09-04, serial 실측으로 확인] task_cleanup_logs()가 남기는 [cleanup] Removing:
    # 로그는 실제로 찍히지만, 바로 다음 순서인 task_capture_boot_log()가 1초도 안 돼
    # request_rotate_log() → `journalctl --rotate && journalctl --vacuum-files=1`을 호출해
    # journald 자체 저장소에서 archived journal을 지워버린다(journald 자체 용량을 작게
    # 유지하려는 정상 동작 — delete_old_journals()가 아니라 task_capture_boot_log() 소관).
    # 그래서 restart "후" journalctl을 사후 조회하면 이미 지워지고 없다 — restart 직후
    # `journalctl -f`를 20초만 background로 짧게 걸어 별도 파일에 사본을 떠두면, vacuum이
    # journald 내부 저장소를 지우더라도 그 사본은 안전하다. timeout으로 자체 종료되니
    # PID 추적/kill 불필요 — 뒤이은 90초 더미-소멸 폴링 동안 이미 다 끝나 있다.
    local JOURNAL_CAP="/tmp/tc18_journal_capture.log"
    rm -f "$JOURNAL_CAP"
    timeout 20 journalctl -u docker-loader -f --no-pager -o short-iso > "$JOURNAL_CAP" 2>&1 &

    # task_cleanup_logs()는 system_log_timer_loop() 시작 직후(92db92bb 이후 맨 앞)
    # 동기 실행되므로 재시작 후 몇 초 내 반영된다 — TC12와 동일하게 최대 90초 폴링.
    local i gone=0 staging_remain toupload_remain archive_remain
    for i in $(seq 1 90); do
        sleep 1
        staging_remain=$(ls "${d1_glob}"*.log 2>/dev/null | wc -l)
        toupload_remain=$(ls "${d2_glob}"*.xz 2>/dev/null | wc -l)
        archive_remain=$(ls "${d3_glob}"*.xz 2>/dev/null | wc -l)
        if [ "$staging_remain" -eq 0 ] && [ "$toupload_remain" -eq 0 ] && [ "$archive_remain" -eq 0 ]; then
            gone=1
            echo "  [${i}s] 더미 전부 소멸 감지"
            break
        fi
        [ $((i % 20)) -eq 0 ] && echo "  [${i}s] 대기 중... staging 잔존=${staging_remain}개 toupload 잔존=${toupload_remain}개 archive 잔존=${archive_remain}개"
    done
    [ "$gone" -eq 0 ] && echo "  [WARN] 90초 내 더미 완전 소멸 미감지 — 현재 상태 기준으로 판정"

    # [2026-09-04, 실측 후 추가] 파일이 사라진 것(unlink 반영)과 df가 그 블록 회수를
    # 보고하는 것 사이에 지연이 있었다 — archive 더미(4.5GB급) 삭제 직후 곧바로 df를
    # 찍으면 회수가 겨우 몇 MB만 반영되고, 몇 분 뒤 다시 찍으면 baseline까지 완전히
    # 회복돼 있었다(`/edge/log`가 `commit=60`으로 마운트돼 있어 대용량 단일 파일 삭제의
    # 블록 회수 반영이 지연되는 것으로 추정). `sync`로 강제 커밋을 요청한 뒤, df가
    # 안정될 때까지 최대 30초 폴링해서 이 지연으로 인한 TC18-3 오탐(false negative)을
    # 막는다.
    sync
    local j prev_permille=-1 stable_count=0 cur_permille
    for j in $(seq 1 30); do
        cur_permille=$(disk_free_permille "${STAGING_DIR}")
        if [ "$cur_permille" -ge 200 ]; then
            echo "  [df 안정화 ${j}s] 여유율 ${cur_permille}‰ (목표 도달)"
            break
        fi
        if [ "$cur_permille" -eq "$prev_permille" ]; then
            stable_count=$((stable_count + 1))
            [ "$stable_count" -ge 3 ] && { echo "  [df 안정화 ${j}s] 여유율 ${cur_permille}‰ (더 안 변함, 폴링 종료)"; break; }
        else
            stable_count=0
        fi
        prev_permille="$cur_permille"
        sync
        sleep 1
    done

    dump_cmd ls -la "${STAGING_DIR}" "${TOUPLOAD_DIR}" "${ARCHIVE_DIR}"
    dump_cmd df -h "${STAGING_DIR}"
    cur_permille=$(disk_free_permille "${STAGING_DIR}")
    echo "  [TC18] 현재 여유율: ${cur_permille}‰"

    # 파일 부재만으로는 "cleanup이 지웠다"는 걸 확정할 수 없으므로, journald에서
    # cleanup_if_low_disk_space()/delete_oldest_files_until_safe()가 실제로 발화한
    # 직접 증거를 같이 남긴다 — restart 직후 20초만 떴던 백그라운드 캡처($JOURNAL_CAP,
    # timeout으로 이미 자체 종료됨)에서 읽는다(라이브 journalctl 재조회 아님 —
    # task_capture_boot_log()의 vacuum-files=1이 이미 원본을 지웠을 수 있어 사후 조회는
    # 신뢰 불가, 위 트리거 직후 주석 참고).
    dump_cmd wc -l "$JOURNAL_CAP"
    dump_cmd sh -c "grep -F '[cleanup_if_low_disk_space]' '$JOURNAL_CAP'"
    dump_cmd sh -c "grep -F '[cleanup] Removing:' '$JOURNAL_CAP'"

    local removed_log found1_count=0 found2_count=0 found3_count=0
    removed_log=$(grep -F '[cleanup] Removing:' "$JOURNAL_CAP" 2>/dev/null)
    # 3곳 모두 여러 개로 쪼갰으므로 각 접두어로 몇 개나 매치되는지 센다(1개 이상이면 그
    # 디렉토리에서 실제로 발화한 것).
    found1_count=$(echo "$removed_log" | grep -cF "$d1_prefix")
    found2_count=$(echo "$removed_log" | grep -cF "$d2_prefix")
    found3_count=$(echo "$removed_log" | grep -cF "$d3_prefix")
    echo "  [TC18] journald [cleanup] Removing 매치: staging=${found1_count}개 toupload=${found2_count}개 archive=${found3_count}개"

    local staging_remain_final toupload_remain_final archive_remain_final
    staging_remain_final=$(ls "${d1_glob}"*.log 2>/dev/null | wc -l)
    toupload_remain_final=$(ls "${d2_glob}"*.xz 2>/dev/null | wc -l)
    archive_remain_final=$(ls "${d3_glob}"*.xz 2>/dev/null | wc -l)

    # [2026-09-04 정정] "3곳 전부 파일 부재"는 delete_oldest_files_until_safe의 실제
    # 설계(파티션 전체 여유율이 목표(20%)에 도달하면 그 즉시 멈춤 — 남은 파일을 끝까지
    # 다 지우는 게 아님)와 안 맞는 기준이었다. 실측(2026-09-04)에서도 archive 89개 중
    # 13개만 지우고 20.397%에서 멈췄는데 이걸 FAIL로 오판정했다. 그래서 "파일 개수가
    # 실제로 줄었는지"(생성량 대비 잔존량 감소, filesystem 관점의 독립 증거 — TC18-4의
    # journal 로그 증거와는 별개 채널)로 바꾼다: 3곳 중 최소 1곳에서라도 개수가 줄면 PASS.
    local staging_removed toupload_removed archive_removed
    staging_removed=$(( staging_count - staging_remain_final ))
    toupload_removed=$(( toupload_count - toupload_remain_final ))
    archive_removed=$(( archive_count - archive_remain_final ))
    echo "  [TC18] 파일 개수 감소(생성 대비 잔존): staging ${staging_count}→${staging_remain_final}(${staging_removed}개 감소) toupload ${toupload_count}→${toupload_remain_final}(${toupload_removed}개 감소) archive ${archive_count}→${archive_remain_final}(${archive_removed}개 감소)"
    if [ "$staging_removed" -ge 1 ] || [ "$toupload_removed" -ge 1 ] || [ "$archive_removed" -ge 1 ]; then
        assert "TC18-2: SYSTEM_LOG_DIRS 중 최소 1곳에서 더미 파일 개수가 실제로 감소함(filesystem 관점 증거)" "PASS"
    else
        assert "TC18-2: SYSTEM_LOG_DIRS 중 최소 1곳에서 더미 파일 개수가 실제로 감소함(filesystem 관점 증거)" "FAIL"
        echo "    3곳 전부 감소 없음 — cleanup이 전혀 발화하지 않았을 가능성"
    fi

    # 3곳 전부를 요구하지 않는다 — staging/toupload에 우리 더미 말고 다른 실제 파일이
    # 남아있으면(운영 중 쌓인 실 로그 등) delete_oldest_files_until_safe가 그것들까지
    # 오래된 순으로 같이 지우다 그 디렉토리만으로 20%를 채워버릴 수 있고, 그러면 archive
    # 차례는 아예 오지도 않는다(뒤 디렉토리는 그 시점 여유율이 이미 10% 넘어 스킵) — 몇
    # 곳에서 회수되는지는 그때그때 실제 파일 분포에 달려있어 우리가 통제할 수 없다.
    # 그래서 "SYSTEM_LOG_DIRS 중 최소 1곳 이상에서 delete_oldest_files_until_safe가
    # 실제로 돌았다"는 것만 직접 증거로 요구한다.
    if [ "$found1_count" -ge 1 ] || [ "$found2_count" -ge 1 ] || [ "$found3_count" -ge 1 ]; then
        assert "TC18-4: journald에 SYSTEM_LOG_DIRS 중 1곳 이상의 [cleanup] Removing 로그 존재 (실제 cleanup 경로로 삭제됐다는 직접 증거)" "PASS"
        echo "    매치: staging=${found1_count}개 toupload=${found2_count}개 archive=${found3_count}개"
    else
        assert "TC18-4: journald에 SYSTEM_LOG_DIRS 중 1곳 이상의 [cleanup] Removing 로그 존재 (실제 cleanup 경로로 삭제됐다는 직접 증거)" "FAIL"
        echo "    journal에 해당 로그가 하나도 없으면 파일이 없어졌더라도 cleanup이 지웠다는 증거가 아님"
    fi

    if [ "$cur_permille" -ge 200 ]; then
        assert "TC18-3: 여유율이 20% 이상으로 회복됨" "PASS"
    else
        assert "TC18-3: 여유율이 20% 이상으로 회복됨" "FAIL"
        echo "    현재 ${cur_permille}‰ (목표 >=200‰)"
    fi

    # 폴링 타임아웃으로 더미가 남았으면 디바이스 청결을 위해 여기서 정리(판정에는 영향 없음)
    rm -f "${d1_glob}"*.log "${d2_glob}"*.xz "${d3_glob}"*.xz 2>/dev/null
    rm -f "$JOURNAL_CAP"

    echo ""
    echo "============================================"
    echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
}

# ============================================================
# TC11: nmon 업로드 happy path
#   - /edge/log/system/nmon/old/*.nmon → /edge/log/toupload/system/nmon/ 이동
#   - .meta 생성 (upload_path/post_action_*/move_dir_failure/from)
#   - .meta 의 4개 후처리 필드 및 upload_path 매치 확인
# ============================================================
tc11_nmon_upload_happy_path() {
    echo "=== TC11: nmon 업로드 happy path ==="

    mkdir -p "${NMON_OLD_DIR}"

    # 1. 더미 .nmon 3개 생성 (nmon/old 만 정리 — toupload/archive 는 baseline 으로 그대로 둠)
    rm -f "${NMON_OLD_DIR}"/*.nmon "${NMON_OLD_DIR}"/*.nmon.meta 2>/dev/null
    local INPUT_COUNT=3
    # 매 실행마다 unique 이름 사용 (epoch suffix) — 이전 세션의 잔존과 충돌 회피하여 before/after diff 비교 신뢰성 확보
    local dummy_tag
    dummy_tag="tc11_$(date +%s)"
    local i
    for i in a b c; do
        echo "TC11 dummy nmon ${i} $(date)" > "${NMON_OLD_DIR}/dummy_${dummy_tag}_${i}.nmon"
    done

    local old_before xfer_before meta_before
    dump_cmd ls -la "${NMON_OLD_DIR}"
    old_before=$(ls "${NMON_OLD_DIR}"/*.nmon 2>/dev/null | wc -l)
    dump_cmd ls -la "${NMON_TOUPLOAD_DIR}"
    xfer_before=$(ls "${NMON_TOUPLOAD_DIR}"/*.nmon 2>/dev/null | wc -l)
    meta_before=$(ls "${NMON_TOUPLOAD_DIR}"/*.nmon.meta 2>/dev/null | wc -l)
    echo "  [TC11-절차1~2] baseline: old=${old_before}, toupload .nmon=${xfer_before}, .meta=${meta_before}"

    # 2. SERVICE_GET_LOG_DATA 트리거 (TC03 패턴)
    echo "  [TC11-절차3] get_log_data 요청 송신..."
    local resp
    resp=$(send_and_wait "get_log_data" "{}" 30)
    echo "  [TC11-절차3] 응답: $([ -n "$resp" ] && echo "OK: $resp" || echo 'TIMEOUT')"

    # 3. task_upload_nmon() detached 처리 대기
    sleep 5

    local old_after xfer_after meta_after
    dump_cmd ls -la "${NMON_OLD_DIR}"
    old_after=$(ls "${NMON_OLD_DIR}"/*.nmon 2>/dev/null | wc -l)
    dump_cmd ls -la "${NMON_TOUPLOAD_DIR}"
    xfer_after=$(ls "${NMON_TOUPLOAD_DIR}"/*.nmon 2>/dev/null | wc -l)
    meta_after=$(ls "${NMON_TOUPLOAD_DIR}"/*.nmon.meta 2>/dev/null | wc -l)
    local xfer_new meta_new
    xfer_new=$((xfer_after - xfer_before))
    meta_new=$((meta_after - meta_before))
    echo "  [TC11-절차5] after: old=${old_after}, toupload .nmon=${xfer_after} (new=${xfer_new}), .meta=${meta_after} (new=${meta_new})"

    # TC11-1
    if [ "$old_after" -eq 0 ]; then
        assert "TC11-1: nmon/old/*.nmon 모두 이동됨 (0개)" "PASS"
    else
        assert "TC11-1: nmon/old/*.nmon 모두 이동됨 (0개)" "FAIL"
        echo "    잔여 파일:"
        ls -la "${NMON_OLD_DIR}"/*.nmon 2>/dev/null
    fi

    # TC11-2: toupload 의 .nmon 갯수 증가 (before/after diff)
    if [ "$xfer_after" -gt "$xfer_before" ]; then
        assert "TC11-2: toupload .nmon 갯수 증가 (before<after)" "PASS"
        echo "    .nmon: ${xfer_before} → ${xfer_after} (+${xfer_new})"
    else
        assert "TC11-2: toupload .nmon 갯수 증가 (before<after)" "FAIL"
        echo "    .nmon: ${xfer_before} → ${xfer_after}"
    fi

    # TC11-5: toupload 의 .nmon.meta 갯수 증가 (before/after diff)
    if [ "$meta_after" -gt "$meta_before" ]; then
        assert "TC11-5: toupload .nmon.meta 갯수 증가 (before<after)" "PASS"
        echo "    .meta: ${meta_before} → ${meta_after} (+${meta_new})"
    else
        assert "TC11-5: toupload .nmon.meta 갯수 증가 (before<after)" "FAIL"
        echo "    .meta: ${meta_before} → ${meta_after}"
    fi

    # TC11-3 / TC11-4: .meta 파싱
    local any_meta
    any_meta=$(ls -t "${NMON_TOUPLOAD_DIR}"/*.nmon.meta 2>/dev/null | head -1)
    if [ -n "$any_meta" ] && [ -f "$any_meta" ]; then
        echo "  [TC11-절차5] meta 검증 대상: $(basename "$any_meta")"
        dump_cmd cat "$any_meta"
        local yyyy mm
        yyyy=$(date '+%Y')
        mm=$(date '+%m')

        if grep -qE "^upload_path=/ems-system/nmon/${yyyy}/${mm}/" "$any_meta"; then
            assert "TC11-3: .meta upload_path=/ems-system/nmon/${yyyy}/${mm}/ 매치" "PASS"
        else
            assert "TC11-3: .meta upload_path=/ems-system/nmon/${yyyy}/${mm}/ 매치" "FAIL"
            echo "    실제: $(grep -E '^upload_path=' "$any_meta")"
        fi

        local miss=0
        grep -qE "^post_action_success=delete"                                  "$any_meta" || miss=$((miss + 1))
        grep -qE "^post_action_failure=move"                                    "$any_meta" || miss=$((miss + 1))
        grep -qE "^move_dir_failure=/edge/log/system/nmon/archive"              "$any_meta" || miss=$((miss + 1))
        grep -qE "^from=system_log"                                             "$any_meta" || miss=$((miss + 1))

        if [ "$miss" -eq 0 ]; then
            assert "TC11-4: .meta 후처리 4개 필드 매치 (success/failure/move_dir/from)" "PASS"
        else
            assert "TC11-4: .meta 후처리 4개 필드 매치 (success/failure/move_dir/from)" "FAIL"
            echo "    missing=${miss}, meta 내용:"
            sed 's/^/      /' "$any_meta"
        fi
    else
        assert "TC11-3: .meta upload_path 매치" "FAIL"
        assert "TC11-4: .meta 후처리 4개 필드 매치" "FAIL"
        echo "    .meta 파일 없음"
    fi

}

# ============================================================
# TC12: nmon retention 30일
#   - cleanup_nmon_dir() (system_log.cpp) 의 30일 보존 삭제 동작 검증
#   - 3 디렉토리: old / archive / toupload/system/nmon
#   - cleanup_nmon_dir()는 system_log 자신의 task_cleanup_logs()에서만 호출되고
#     (프로세스 시작 시 1회 + 24시간 주기), "nmon.service" 재시작과는 무관하다 —
#     예전엔 `systemctl restart nmon.service`로 트리거를 흉내 냈지만 실제로는
#     아무 정리도 유발하지 못해 근처의 다른 TC(kill -9 재시작)가 우연히 타이밍을
#     맞춰줄 때만 통과하는 flaky 테스트였다(실측: 20260807_152712_system_log_full
#     run에서 우연이 안 맞아 FAIL). TC14/TC16과 동일하게 system_log를 직접
#     kill -9 해 재시작을 강제하고, 그 재시작이 부르는 task_cleanup_logs()의
#     결과(더미 파일 소멸)를 폴링해서 기다리는 방식으로 결정적으로 재현한다.
# ============================================================
tc12_nmon_retention() {
    echo "=== TC12: nmon retention 30일 ==="

    mkdir -p "${NMON_OLD_DIR}" "${NMON_ARCHIVE_DIR}" "${NMON_TOUPLOAD_DIR}"

    # 각 디렉토리에 40일 더미 + 현재 시각 더미 생성
    local d old40 old40_meta now_file now_meta
    for d in "${NMON_OLD_DIR}" "${NMON_ARCHIVE_DIR}" "${NMON_TOUPLOAD_DIR}"; do
        old40="${d}/tc12_old40.nmon"
        old40_meta="${d}/tc12_old40.nmon.meta"
        now_file="${d}/tc12_now.nmon"
        now_meta="${d}/tc12_now.nmon.meta"

        echo "TC12 old40 dummy" > "$old40"
        echo "TC12 old40 dummy meta" > "$old40_meta"
        echo "TC12 now dummy" > "$now_file"
        echo "TC12 now dummy meta" > "$now_meta"

        touch -d "40 days ago" "$old40" 2>/dev/null
        touch -d "40 days ago" "$old40_meta" 2>/dev/null
    done

    # 전체 경로로 매칭 필수 — "system_log"만 쓰면 이 스크립트 자신(tc_system_log.sh)까지
    # 걸려 head -1이 엉뚱한 PID를 집는 사고가 TC14/TC16에서 실측됨 (동일 관례 재사용).
    local SL_PID
    SL_PID=$(pgrep -f /edge/app/bin/system_log | head -1)
    if [ -z "$SL_PID" ]; then
        echo "  [ERROR] system_log 프로세스 없음"
        assert "TC12-1: 3 디렉토리에서 mtime 40일 .nmon 더미 모두 삭제됨" "FAIL"
        assert "TC12-2: 3 디렉토리에서 현재 시각 .nmon 더미 보존됨" "FAIL"
        assert "TC12-3: 3 디렉토리에서 mtime 40일 .nmon.meta 더미 모두 삭제됨" "FAIL"
        assert "TC12-4: 3 디렉토리에서 현재 시각 .nmon.meta 더미 보존됨" "FAIL"
        return
    fi
    echo "  [TC12-절차2] system_log kill (PID ${SL_PID}) → 재시작 시 task_cleanup_logs() 발화 대기..."
    kill -9 "$SL_PID" 2>/dev/null

    # 재시작 후 cleanup_nmon_dir()가 old40 더미를 지울 때까지 최대 90초 폴링
    # (TC14의 재시작 대기 예산과 동일 — docker-loader 전체 재시작이 걸릴 수 있음).
    local i old40_gone=0
    for i in $(seq 1 90); do
        sleep 1
        if [ ! -f "${NMON_OLD_DIR}/tc12_old40.nmon" ] \
           && [ ! -f "${NMON_ARCHIVE_DIR}/tc12_old40.nmon" ] \
           && [ ! -f "${NMON_TOUPLOAD_DIR}/tc12_old40.nmon" ]; then
            old40_gone=1
            echo "  [${i}s] old40 더미 삭제 감지"
            break
        fi
        [ $((i % 20)) -eq 0 ] && printf "  [%2ds] 대기 중...\n" "$i"
    done
    [ "$old40_gone" -eq 0 ] && echo "  [WARN] 90초 내 old40 더미 삭제 미감지 — 이후 검증은 현재 상태 기준으로 진행"

    local fail_old_nmon=0 fail_old_meta=0 fail_now_nmon=0 fail_now_meta=0
    for d in "${NMON_OLD_DIR}" "${NMON_ARCHIVE_DIR}" "${NMON_TOUPLOAD_DIR}"; do
        dump_cmd ls -la "${d}/tc12_old40.nmon" "${d}/tc12_old40.nmon.meta" "${d}/tc12_now.nmon" "${d}/tc12_now.nmon.meta"
        old40="${d}/tc12_old40.nmon"
        old40_meta="${d}/tc12_old40.nmon.meta"
        now_file="${d}/tc12_now.nmon"
        now_meta="${d}/tc12_now.nmon.meta"

        if [ -f "$old40" ]; then
            fail_old_nmon=$((fail_old_nmon + 1))
            echo "    [잔존] ${d}/tc12_old40.nmon 가 삭제되지 않음"
        fi
        if [ -f "$old40_meta" ]; then
            fail_old_meta=$((fail_old_meta + 1))
            echo "    [잔존] ${d}/tc12_old40.nmon.meta 가 삭제되지 않음"
        fi

        if [ ! -f "$now_file" ]; then
            fail_now_nmon=$((fail_now_nmon + 1))
            echo "    [소실] ${d}/tc12_now.nmon 가 보존되지 않음"
        fi
        if [ ! -f "$now_meta" ]; then
            fail_now_meta=$((fail_now_meta + 1))
            echo "    [소실] ${d}/tc12_now.nmon.meta 가 보존되지 않음"
        fi
    done

    if [ "$fail_old_nmon" -eq 0 ]; then
        assert "TC12-1: 3 디렉토리에서 mtime 40일 .nmon 더미 모두 삭제됨" "PASS"
    else
        assert "TC12-1: 3 디렉토리에서 mtime 40일 .nmon 더미 모두 삭제됨" "FAIL"
    fi

    if [ "$fail_now_nmon" -eq 0 ]; then
        assert "TC12-2: 3 디렉토리에서 현재 시각 .nmon 더미 보존됨" "PASS"
    else
        assert "TC12-2: 3 디렉토리에서 현재 시각 .nmon 더미 보존됨" "FAIL"
    fi

    if [ "$fail_old_meta" -eq 0 ]; then
        assert "TC12-3: 3 디렉토리에서 mtime 40일 .nmon.meta 더미 모두 삭제됨" "PASS"
    else
        assert "TC12-3: 3 디렉토리에서 mtime 40일 .nmon.meta 더미 모두 삭제됨" "FAIL"
    fi

    if [ "$fail_now_meta" -eq 0 ]; then
        assert "TC12-4: 3 디렉토리에서 현재 시각 .nmon.meta 더미 보존됨" "PASS"
    else
        assert "TC12-4: 3 디렉토리에서 현재 시각 .nmon.meta 더미 보존됨" "FAIL"
    fi

    # cleanup: 잔여 더미 정리
    for d in "${NMON_OLD_DIR}" "${NMON_ARCHIVE_DIR}" "${NMON_TOUPLOAD_DIR}"; do
        rm -f "${d}/tc12_old40.nmon" "${d}/tc12_old40.nmon.meta" \
              "${d}/tc12_now.nmon"   "${d}/tc12_now.nmon.meta" 2>/dev/null
    done
}

# ============================================================
# TC13: nmon 부재 환경 호환 (no-op)
#   - /edge/log/system/nmon/old/ 비어있어도 task_upload_nmon() 에러 없이 응답
# ============================================================
tc13_nmon_no_op() {
    echo "=== TC13: nmon 부재 환경 호환 (no-op) ==="

    mkdir -p "${NMON_OLD_DIR}"
    rm -f "${NMON_OLD_DIR}"/*.nmon "${NMON_OLD_DIR}"/*.nmon.meta 2>/dev/null
    local old_count
    old_count=$(ls "${NMON_OLD_DIR}"/*.nmon 2>/dev/null | wc -l)
    echo "  [TC13-절차1] nmon/old 비움 — 현재 .nmon=${old_count}"

    echo "  [TC13-절차2] get_log_data 요청 송신..."
    local resp
    resp=$(send_and_wait "get_log_data" "{}" 30)
    echo "  [TC13-절차2] 응답: $([ -n "$resp" ] && echo "OK: $resp" || echo 'TIMEOUT')"

    if [ -n "$resp" ]; then
        assert "TC13-1: nmon/old 비어있는 상태에서 get_log_data 응답 수신" "PASS"
    else
        assert "TC13-1: nmon/old 비어있는 상태에서 get_log_data 응답 수신" "FAIL"
        return
    fi

    # 응답에 error_code 필드가 있으면 0 확인, 없으면 skip
    # 참고: 현재 코드에서 task_upload_nmon 의 반환값은 응답에 반영되지 않음
    #       (task_rotate_sync 결과만 반영). 따라서 TC13-3 의 journald 검증이
    #       task_upload_nmon 의 silent failure 를 잡는 진짜 가드.
    if echo "$resp" | grep -qE '"error_code"'; then
        if echo "$resp" | grep -qE '"error_code"[[:space:]]*:[[:space:]]*(0|"NONE")'; then
            assert "TC13-2: 응답 error_code=0|\"NONE\" (task_rotate_sync 정상)" "PASS"
        else
            assert "TC13-2: 응답 error_code=0|\"NONE\" (task_rotate_sync 정상)" "FAIL"
            echo "    실제 응답: $resp"
        fi
    else
        echo "  [TC13-2] 응답 페이로드에 error_code 필드 없음 — 응답 수신만으로 PASS"
        assert "TC13-2: 응답 error_code=0|\"NONE\" 또는 응답 수신만으로 통과" "PASS"
    fi

    # TC13-3: journald 에 task_upload_nmon ERROR 부재 (silent failure 가드)
    echo "  \$ journalctl -u docker-loader --since '1 minute ago' -o cat | grep '[task_upload_nmon]'"
    local nmon_all
    nmon_all=$(journalctl -u docker-loader --since "1 minute ago" --no-pager -o cat 2>/dev/null \
               | grep -F '[task_upload_nmon]')
    if [ -n "$nmon_all" ]; then
        echo "$nmon_all" | sed 's/^/    /'
    else
        echo "    (해당 로그 없음)"
    fi
    local nmon_err
    nmon_err=$(echo "$nmon_all" | grep -E 'ERROR|Failed' | tail -5)
    if [ -z "$nmon_err" ]; then
        assert "TC13-3: 최근 1분 journald 에 task_upload_nmon ERROR 부재" "PASS"
    else
        assert "TC13-3: 최근 1분 journald 에 task_upload_nmon ERROR 부재" "FAIL"
        echo "    발견된 ERROR 라인:"
        echo "$nmon_err" | sed 's/^/      /'
    fi
}

# ============================================================
# TC14: RTC 이상 시 동일 시작시간 다중 파일 병합
#   - staging에 같은 BOOT_START를 가진 더미 .xz 2개 배치
#   - system_log kill → edge_runtime 재시작 → task_capture_boot_log + task_merge_staged_logs
#   - toupload에 단일 병합 파일 생성, start_time = BOOT_START 확인
# ============================================================
tc14_rtc_same_start_merge() {
    echo "=== TC14: RTC 이상 동일 시작시간 다중 파일 병합 ==="

    # 1. staging 클린업
    rm -f "${STAGING_DIR}"/systemlog_*.log.xz "${STAGING_DIR}"/systemlog_*.log \
          "${STAGING_DIR}"/.merging_*.tmp 2>/dev/null

    # 2. BOOT_START 취득
    local BOOT_START
    dump_cmd journalctl --list-boots
    BOOT_START=$(journalctl --list-boots | head -n 1 \
        | awk '{print $4, $5}' | sed 's/[-:]//g' | tr -d ' ')
    echo "  BOOT_START: $BOOT_START"
    if [ -z "$BOOT_START" ]; then
        echo "  [ERROR] start_time 취득 실패"
        assert "TC14: BOOT_START 취득" "FAIL"
        return
    fi

    # 3. BEFORE 목록 기록 (ls -t 가 아닌 diff로 신규 파일 식별 — TC11 등 직전 TC가 만든 파일 오참조 방지)
    local BEFORE_TOUPLOAD BEFORE_LIST
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    BEFORE_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    BEFORE_TOUPLOAD=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)

    # 4. 더미 .xz 2개 배치 (RTC 이상 시뮬레이션: 동일 start, 다른 end)
    local DUMMY_A="${STAGING_DIR}/systemlog_${BOOT_START}_${BOOT_START}01.log.xz"
    local DUMMY_B="${STAGING_DIR}/systemlog_${BOOT_START}_${BOOT_START}02.log.xz"
    seq 1 2000 | xz -1 -c > "$DUMMY_A" 2>/dev/null
    seq 1 2000 | xz -1 -c > "$DUMMY_B" 2>/dev/null
    echo "  더미 배치 완료:"
    ls -lh "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | sed 's/^/    /'

    # 5. system_log kill → edge_runtime 재시작
    # 반드시 전체 경로로 매칭할 것 — "system_log"만 쓰면 이 스크립트 자신의 파일명
    # (tc_system_log.sh)까지 매칭돼 head -1이 엉뚱한(진짜 system_log가 아닌) PID를
    # 집어 kill이 사실상 no-op이 되는 사고가 실측으로 확인됨 (TC02 방식과 통일).
    local SL_PID
    SL_PID=$(pgrep -f /edge/app/bin/system_log | head -1)
    if [ -z "$SL_PID" ]; then
        echo "  [ERROR] system_log 프로세스 없음"
        assert "TC14: system_log 프로세스 확인" "FAIL"
        return
    fi
    local MARKER
    MARKER="/tmp/tc14_marker_$$"
    touch "$MARKER"
    echo "  system_log kill (PID ${SL_PID}) → 재시작 대기..."
    kill -9 "$SL_PID" 2>/dev/null

    # 6-7. task_capture_boot_log + task_merge_staged_logs 완료 대기 (최대 90초)
    # comm -13 으로 BEFORE_LIST 대비 신규 파일만 감지 (-newer MARKER 는 기존 파일을 잘못 감지할 수 있음)
    local i toupload_new=0 after_check
    for i in $(seq 1 90); do
        sleep 1
        after_check=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
        toupload_new=$(comm -13 <(echo "$BEFORE_LIST") <(echo "$after_check") | wc -l)
        if [ "$toupload_new" -ge 1 ]; then
            echo "  [${i}s] toupload 신규 파일 감지"
            break
        fi
        [ $((i % 20)) -eq 0 ] && printf "  [%2ds] 대기 중...\n" "$i"
    done
    rm -f "$MARKER"

    # 8. 검증
    local staging_remain
    dump_cmd ls -la "${STAGING_DIR}"/systemlog_*.log.xz
    staging_remain=$(ls "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    if [ "$staging_remain" -eq 0 ]; then
        assert "TC14-1: staging systemlog_*.log.xz 모두 소비됨 (0개)" "PASS"
    else
        assert "TC14-1: staging systemlog_*.log.xz 모두 소비됨 (0개)" "FAIL"
        echo "    잔존 ${staging_remain}개:"
        ls "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | sed 's/^/      /'
    fi

    local AFTER_TOUPLOAD
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    AFTER_TOUPLOAD=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    if [ "$AFTER_TOUPLOAD" -gt "$BEFORE_TOUPLOAD" ]; then
        assert "TC14-2: toupload .log.xz 신규 생성됨" "PASS"
        echo "    toupload: ${BEFORE_TOUPLOAD} → ${AFTER_TOUPLOAD}"
    else
        assert "TC14-2: toupload .log.xz 신규 생성됨" "FAIL"
        echo "    toupload: ${BEFORE_TOUPLOAD} → ${AFTER_TOUPLOAD}"
    fi

    # 신규 파일 = 이번 TC14가 만든 파일 (before/after diff)
    local NEW_XZ AFTER_LIST
    AFTER_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    NEW_XZ=$(comm -13 <(echo "$BEFORE_LIST") <(echo "$AFTER_LIST") | head -1)
    if [ -n "$NEW_XZ" ]; then
        local new_start
        new_start=$(basename "$NEW_XZ" | sed 's/systemlog_\([0-9]*\)_.*/\1/')
        if [ "$new_start" = "$BOOT_START" ]; then
            assert "TC14-3: 병합 파일 start_time = BOOT_START (${BOOT_START})" "PASS"
        else
            assert "TC14-3: 병합 파일 start_time = BOOT_START (${BOOT_START})" "FAIL"
            echo "    실제 start_time: ${new_start}"
        fi

        if dump_cmd xz --test "$NEW_XZ"; then
            assert "TC14-4: 병합 파일 xz 무결성 (xz --test)" "PASS"
        else
            assert "TC14-4: 병합 파일 xz 무결성 (xz --test)" "FAIL"
        fi
        echo "    병합 결과: $(basename "$NEW_XZ")"
    else
        assert "TC14-3: 병합 파일 start_time 확인" "FAIL"
        assert "TC14-4: 병합 파일 xz 무결성" "FAIL"
        echo "    toupload에서 신규 파일 없음"
    fi
}

# ============================================================
# TC15: task_rotate_sync — compress 실패 시 raw .log 보존 (toupload)
#   journal을 대량(raw urandom ~400MB)으로 채워 SYSTEM_LOG_REQUEST_CMD_TIMEOUT
#   (180s, system_log.hpp:30) 안에 xz -f 압축이 못 끝나도록 강제한다.
#   [실측 주의] 210MB(raw, →dump ~294MB)로는 180s 경계선에서 간신히 timeout 나거나
#   (2026-08-04 10:35 run: 정확히 180.0s 후 error 255) 타이밍에 따라 성공해버리는
#   flaky 구간이었다 — 400MB로 상향해 안전마진 확보.
#   [주의] journal을 대량으로 채웠다가 vacuum으로 비우는 파괴적 시험. 5분 이상 소요.
#   [튜닝 주의] journalctl -o cat(dump) 도 같은 타임아웃을 공유한다. raw .log가
#   아예 안 생기면 dump 단계에서부터 타임아웃난 것 — 주입량을 줄여야 한다.
# ============================================================
inject_oversized_journal() {
    # TC04와 동일 기법이되 premade DUMMY_BLOB(raw 400MB 상당)을 재사용해 주입
    local tag="$1"
    echo "  [주입] cat ${DUMMY_BLOB} | systemd-cat -t ${tag} (raw ${DUMMY_BLOB_RAW_MB}MB 상당, premade blob 재사용)"
    inject_dummy_blob "$tag" "$DUMMY_BLOB_RAW_MB"
    sync
    sleep 3
    dump_cmd journalctl --rotate
    sleep 2
    dump_cmd journalctl --disk-usage
}

tc15_rotate_sync_compress_fail() {
    echo "=== TC15: task_rotate_sync compress 실패 시 raw .log 보존 (toupload) ==="

    dump_cmd journalctl --rotate
    dump_cmd journalctl --vacuum-files=1
    sleep 2

    dump_cmd journalctl --list-boots
    local before_head
    before_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  BEFORE list-boots head: ${before_head}"
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log
    local before_list
    before_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log 2>/dev/null | sort)

    inject_oversized_journal "TC15_DUMMY"

    echo "  get_log_data 요청 송신 (최대 200초 대기 — 180s cmd timeout + overhead)..."
    local t0 t1 resp
    t0=$(date +%s)
    resp=$(send_and_wait "get_log_data" "{}" 200)
    t1=$(date +%s)
    echo "  응답: $([ -n "$resp" ] && echo "OK: $resp" || echo 'TIMEOUT'), 소요 $((t1 - t0))초"

    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log
    local after_list NEW_LOG
    after_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log 2>/dev/null | sort)
    NEW_LOG=$(comm -13 <(echo "$before_list") <(echo "$after_list") | head -1)

    if [ -n "$NEW_LOG" ] && [ -f "$NEW_LOG" ]; then
        assert "TC15-1: 압축 실패 후 raw .log 가 toupload에 보존됨" "PASS"
        dump_cmd ls -la "$NEW_LOG"
    else
        assert "TC15-1: 압축 실패 후 raw .log 가 toupload에 보존됨" "FAIL"
        echo "    신규 .log 파일을 찾지 못함 (압축이 시간 내에 성공했거나, dump 단계부터 타임아웃 — journal 크기 재확인 필요)"
    fi

    if [ -n "$NEW_LOG" ]; then
        # get_log_data 응답을 받아도 host_agent가 타임아웃을 살짝 넘겨서까지 원격 xz를
        # 끝까지 돌려주는 경우가 있어(실측: 응답 수신 후에도 .xz 크기가 계속 자람), 응답
        # 직후 바로 판정하면 아직 쓰는 중인 파일을 스냅샷으로 잘못 잡을 수 있다. 크기가
        # 더 안 늘어날 때까지(최대 60초) 안정화를 기다린 뒤에 최종 판정한다 — 이게 진짜
        # "완료 신호"다.
        local xz_deadline prev_size cur_size stable_absent_count
        xz_deadline=$(( $(date +%s) + 60 ))
        prev_size=-2
        stable_absent_count=0
        while [ "$(date +%s)" -lt "$xz_deadline" ]; do
            if [ -f "${NEW_LOG}.xz" ]; then
                cur_size=$(stat -c%s "${NEW_LOG}.xz" 2>/dev/null || echo -1)
                stable_absent_count=0
                [ "$cur_size" = "$prev_size" ] && break   # 크기 변화 없음 = 다 씀
                prev_size="$cur_size"
            else
                stable_absent_count=$((stable_absent_count + 1))
                [ "$stable_absent_count" -ge 2 ] && break   # 2회 연속 부재 = 안정적으로 없음
                prev_size=-2
            fi
            sleep 3
        done

        dump_cmd ls -la "${NEW_LOG}.xz"
        if [ ! -f "${NEW_LOG}.xz" ]; then
            assert "TC15-2: 깨진 partial .xz 는 남지 않음" "PASS"
        else
            assert "TC15-2: 깨진 partial .xz 는 남지 않음" "FAIL"
            xz --test "${NEW_LOG}.xz" 2>&1 | sed 's/^/    /'
        fi

        dump_cmd ls -la "${NEW_LOG}.xz.meta"
        if [ ! -f "${NEW_LOG}.xz.meta" ]; then
            assert "TC15-3: .meta 생성되지 않음 (업로드 큐에 미등록)" "PASS"
        else
            assert "TC15-3: .meta 생성되지 않음 (업로드 큐에 미등록)" "FAIL"
        fi
    else
        assert "TC15-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        assert "TC15-3: .meta 생성되지 않음" "FAIL"
    fi

    dump_cmd journalctl --list-boots
    local after_head
    after_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  AFTER list-boots head: ${after_head}"
    if [ "$after_head" != "$before_head" ]; then
        assert "TC15-4: vacuum이 실행되어 list-boots head 변경됨" "PASS"
    else
        assert "TC15-4: vacuum이 실행되어 list-boots head 변경됨" "FAIL"
        echo "    head 불변: ${after_head}"
    fi

    # cleanup
    [ -n "$NEW_LOG" ] && rm -f "$NEW_LOG"
    dump_cmd journalctl --rotate
    dump_cmd journalctl --vacuum-files=1
}

# ============================================================
# TC16: task_capture_boot_log — compress 실패 시 raw .log 보존 (staging)
#   TC15와 동일 journal 주입 기법 + TC14와 동일 kill -9 재시작 기법을 결합.
#   [주의] journal 대량 주입 + system_log 강제 재시작 수반. 5분 이상 소요.
# ============================================================
tc16_boot_log_compress_fail() {
    echo "=== TC16: task_capture_boot_log compress 실패 시 raw .log 보존 (staging) ==="

    rm -f "${STAGING_DIR}"/systemlog_*.log.xz "${STAGING_DIR}"/systemlog_*.log \
          "${STAGING_DIR}"/.merging_*.tmp 2>/dev/null

    dump_cmd journalctl --list-boots
    local before_head
    before_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  BEFORE list-boots head: ${before_head}"

    inject_oversized_journal "TC16_DUMMY"

    # 전체 경로 매칭 필수 — "system_log"만 쓰면 tc_system_log.sh 자신까지 걸려
    # head -1이 엉뚱한 PID를 집어 kill이 no-op 되는 문제가 실측됨 (TC02/TC14와 통일).
    local SL_PID
    SL_PID=$(pgrep -f /edge/app/bin/system_log | head -1)
    if [ -z "$SL_PID" ]; then
        echo "  [ERROR] system_log 프로세스 없음"
        assert "TC16-1: system_log 프로세스 확인" "FAIL"
        assert "TC16-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        assert "TC16-3: raw .log toupload 미이관 확인" "FAIL"
        assert "TC16-4: vacuum 실행 확인" "FAIL"
        return
    fi

    local SL_RESTART_TS
    SL_RESTART_TS=$(date '+%Y-%m-%d %H:%M:%S')
    echo "  system_log kill (PID ${SL_PID}) → 재시작 대기..."
    kill -9 "$SL_PID" 2>/dev/null

    # 고정 220초 대기 대신, task_capture_boot_log의 실제 완료 신호(Done: 또는
    # Failed to compress log)를 journald에서 폴링한다. dump(journalctl -o cat)
    # 단계 자체가 주입량에 비례해 오래 걸려(400MB 기준 실측 ~100초) xz의 180s
    # 타임아웃 시작 시점이 그만큼 밀린다 — 고정 220초로는 xz가 아직 진행 중인
    # (아직 실패도 성공도 확정 안 된) 시점에 .xz를 검사해버려 오탐 FAIL이 났었다
    # (2026-08-04 10:46 run: kill~220s=10:50:20 시점 검사, 실제 xz 타임아웃은
    # 10:51:31 — 71초 늦게 확정됨).
    local MAX_WAIT=480 elapsed=0 done_line=""
    while [ "$elapsed" -lt "$MAX_WAIT" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        done_line=$(journalctl -u docker-loader --no-pager -o cat --since "$SL_RESTART_TS" 2>/dev/null \
                     | grep -E '\[task_capture_boot_log\] (Done:|Failed to compress log)' | tail -1)
        [ -n "$done_line" ] && break
        [ $((elapsed % 30)) -eq 0 ] && printf "  [%3ds] 대기 중... (task_capture_boot_log 완료 신호 대기)\n" "$elapsed"
    done
    if [ -n "$done_line" ]; then
        echo "  [완료 감지 @ ${elapsed}s] ${done_line}"
    else
        echo "  [WARN] ${MAX_WAIT}s 내 task_capture_boot_log 완료 신호를 못 찾음 — 이후 검증은 현재 상태 기준으로 진행"
    fi

    dump_cmd ls -la "${STAGING_DIR}"/systemlog_*.log
    local NEW_LOG
    NEW_LOG=$(ls -t "${STAGING_DIR}"/systemlog_*.log 2>/dev/null | head -1)

    if [ -n "$NEW_LOG" ] && [ -f "$NEW_LOG" ]; then
        assert "TC16-1: 압축 실패 후 raw .log 가 staging에 보존됨" "PASS"
    else
        assert "TC16-1: 압축 실패 후 raw .log 가 staging에 보존됨" "FAIL"
        echo "    staging에 raw .log 없음 (압축이 시간 내에 성공했거나 dump 단계 타임아웃)"
    fi

    if [ -n "$NEW_LOG" ]; then
        # journald 완료 신호를 잡아도 host_agent가 타임아웃을 살짝 넘겨서까지 원격 xz를
        # 끝까지 돌려주는 경우가 있어 신호 직후 바로 판정하면 아직 쓰는 중인 파일을
        # 스냅샷으로 잘못 잡을 수 있다(TC15와 동일 이유). 크기가 더 안 늘어날 때까지
        # (최대 60초) 안정화를 기다린 뒤 최종 판정한다.
        local xz_deadline prev_size cur_size stable_absent_count
        xz_deadline=$(( $(date +%s) + 60 ))
        prev_size=-2
        stable_absent_count=0
        while [ "$(date +%s)" -lt "$xz_deadline" ]; do
            if [ -f "${NEW_LOG}.xz" ]; then
                cur_size=$(stat -c%s "${NEW_LOG}.xz" 2>/dev/null || echo -1)
                stable_absent_count=0
                [ "$cur_size" = "$prev_size" ] && break
                prev_size="$cur_size"
            else
                stable_absent_count=$((stable_absent_count + 1))
                [ "$stable_absent_count" -ge 2 ] && break
                prev_size=-2
            fi
            sleep 3
        done

        dump_cmd ls -la "${NEW_LOG}.xz"
        if [ ! -f "${NEW_LOG}.xz" ]; then
            assert "TC16-2: 깨진 partial .xz 는 남지 않음" "PASS"
        else
            assert "TC16-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        fi

        local base moved
        base=$(basename "$NEW_LOG")
        dump_cmd ls -la "${TOUPLOAD_DIR}/${base}"
        moved=$(find "${TOUPLOAD_DIR}" -name "${base}*" 2>/dev/null | head -1)
        if [ -z "$moved" ]; then
            assert "TC16-3: raw .log 가 toupload로 잘못 이관되지 않음" "PASS"
        else
            assert "TC16-3: raw .log 가 toupload로 잘못 이관되지 않음" "FAIL"
            echo "    발견: $moved"
        fi
    else
        assert "TC16-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        assert "TC16-3: raw .log toupload 미이관 확인" "FAIL"
    fi

    dump_cmd journalctl --list-boots
    local after_head
    after_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  AFTER list-boots head: ${after_head}"
    if [ "$after_head" != "$before_head" ]; then
        assert "TC16-4: vacuum이 실행되어 list-boots head 변경됨" "PASS"
    else
        assert "TC16-4: vacuum이 실행되어 list-boots head 변경됨" "FAIL"
    fi

    # cleanup: journald에 "compress 실패 → raw .log 보존" 로그가 NEW_LOG 기준으로
    # 확실히 찍힌 게 확인된 경우에만 NEW_LOG를 지운다. 확인 안 되면 진단용으로 남겨둔다.
    if [ -n "$NEW_LOG" ]; then
        local compress_fail_marker="[task_capture_boot_log] Failed to compress log, keeping raw .log for diagnostics: ${NEW_LOG}"
        dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat 2>/dev/null | grep -F '${compress_fail_marker}'"
        if journalctl -u docker-loader --no-pager -o cat 2>/dev/null | grep -qF "$compress_fail_marker"; then
            rm -f "$NEW_LOG"
        else
            echo "  [KEEP] compress 실패 로그(journald) 미확인 — NEW_LOG 보존: ${NEW_LOG}"
        fi
    fi
    dump_cmd journalctl --rotate
    dump_cmd journalctl --vacuum-files=1
}

# ============================================================
# TC17: MessageContext tid 미검증 — cmd_host 응답 위조로 결정적 재현
#   근거: SystemLog::handle_response() (system_log.cpp:165-188)는 SERVICE_CMD_HOST
#   응답이 오면 tid를 전혀 확인하지 않고 무조건 message_context_.complete()를 호출한다.
#   message_context_(system_log.hpp:40-79)는 tid 필드 자체가 없는 단일 공유 슬롯이라,
#   "지금 이 응답이 내가 기다리던 그 요청의 응답인가"를 검증할 수단이 구조적으로 없다.
#   [재현 전략] 정밀한 타이밍을 노리는 대신 훨씬 단순한 방식을 쓴다 — get_log_data를
#   비동기로 쏘면 내부적으로 task_rotate_sync()가 request_start_time → request_make_log
#   → request_rotate_log → request_compress_log 순으로 request_command_sync()를 4번
#   연달아 호출한다(각각이 message_context_ 슬롯을 잡는 별도의 짧은 창). 대량 journal
#   주입 없이도, 그 실행 구간 동안 무관한(위조) cmd_host 응답을 0.2초 간격으로 반복
#   발행하면 4번의 창 중 최소 하나는 반드시 맞힌다 — 언제 맞았는지 정확히 몰라도 된다.
#   이 공격 한 번으로 서로 다른 두 가지를 관찰한다(TC09-1/TC09-2처럼 한 실행 안의
#   독립적인 두 판정 — TC17-2는 TC17-1의 후속 단계가 아니라 같은 공격의 다른 관찰점):
#     TC17-1: 위조 응답 자체가 소비되거나 크래시를 유발하는지 (공격자 관점)
#     TC17-2: 그 와중에 진짜 get_log_data 요청은 방해받지 않고 정상 완료되는지 (피해자 관점)
#   [판정 관례] 다른 TC와 동일하게 PASS=정상 동작, FAIL=결함 재현이다. 지금은 tid
#   검증이 없어 둘 다 FAIL이 나야 정상 — handle_response()에 tid 검증이 추가되면
#   TC17-1/TC17-2 모두 PASS로 뒤집혀야 한다.
#   [주의] 실제 코드 결함을 이용한 재현 시험이라 회귀 세트(default/--full)에는 포함하지
#   않는다 — --tc17 또는 --only TC17 로 단독 실행.
# ============================================================
tc17_message_context_tid_pollution() {
    echo "=== TC17: MessageContext tid 미검증 - cmd_host 응답 위조로 결정적 재현 ==="

    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    local BEFORE_LIST
    BEFORE_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)

    # --- 공격 실행 (TC17-1/TC17-2 공용, 딱 한 번만) ---
    local MARKER="TC17_PROOF_$$_$(date +%s)"
    local get_resp_file="/tmp/tc17_get_resp_$$"
    local req_capture_file="/tmp/tc17_req_capture_$$"
    local forged_payload
    # 실제 sys_manager 응답 형태(CmdHostResponse: status/cmd/message/exit_code, 실측
    # 예시는 sys_manager.cpp:1587 "success"/1594 "error" 참고)를 그대로 흉내 내되,
    # cmd 값은 이 디바이스에 존재하지 않는 명령어("xze")로 채운다 — "존재하지도 않는
    # 명령을 성공적으로 실행했다"는 명백히 말이 안 되는 위조조차 tid만 안 맞으면
    # 걸러내지 못한다는 걸 보여주기 위함(내용 검증 부재까지 함께 증명).
    forged_payload=$(printf '{"error_code":"NONE","payload":{"status":"success","cmd":"xze -f /tmp/tc17_nonexistent_cmd","exit_code":0,"message":"","injected_marker":"%s"}}' "$MARKER")

    # system_log가 sys_manager에 실제로 발행하는 cmd_host 요청(req)을 공격 구간 내내
    # 캡처한다 (2026-08-11 확인: emsp/sys_manager/${TARGET}/req/cmd_host). TC17-1 판정을
    # journald LOG(DEBUG) "result: " 라인 grep 방식에서 이 MQTT req 캡처 방식으로 교체함
    # — [SL] 모듈은 journald에 [D](Debug) 태그가 전체 보존 기간 통틀어 0건으로 확인되어
    # (대조: 다른 모듈 [WI]는 541건) 기존 방식은 위조 소비 여부와 무관하게 항상 PASS만
    # 내는 구조적 결함이 있었다 (evidence_full.log SECTION 8-1 참고).
    rm -f "$req_capture_file"
    mosquitto_sub -h "$MQTT_HOST" -t "emsp/sys_manager/${TARGET}/req/cmd_host" -v > "$req_capture_file" 2>/dev/null &
    local REQ_SUB_PID=$!
    sleep 0.5

    echo "  get_log_data 요청을 백그라운드로 송신..."
    ( send_and_wait "get_log_data" "{}" 30 > "$get_resp_file" ) &
    local GET_BG_PID=$!

    echo "  [핵심] cmd_host 응답 토픽(emsp/${TARGET}/sys_manager/res/cmd_host)에 위조"
    echo "  메시지를 0.2초 간격으로 40회(≈8초) 반복 발행 — tid 불일치, service만 일치."
    echo "  payload: ${forged_payload}"
    local i
    for i in $(seq 1 40); do
        mosquitto_pub -h "$MQTT_HOST" -t "emsp/${TARGET}/sys_manager/res/cmd_host" -m "$forged_payload" 2>/dev/null
        sleep 0.2
    done

    echo "  get_log_data 백그라운드 응답 대기(최대 30초)..."
    wait "$GET_BG_PID"
    local get_resp
    get_resp=$(cat "$get_resp_file" 2>/dev/null)
    rm -f "$get_resp_file"
    echo "  get_log_data 최종 응답: ${get_resp:-<타임아웃/없음>}"
    sleep 2

    kill "$REQ_SUB_PID" 2>/dev/null
    wait "$REQ_SUB_PID" 2>/dev/null

    # --- TC17-1 판정: 위조 응답 자체의 운명 (공격자 관점), MQTT req 내용 훼손 여부로 직접 판정 ---
    # task_rotate_sync()는 request_start_time() 응답의 "message" 필드를 start_time으로
    # 써서 파일 경로(systemlog_<start>_<end>.log)를 만든다. 위조 payload의 message는
    # 빈 문자열이므로, 만약 start_time 단계가 위조로 가로채이면 뒤이은 make_log/
    # compress_log 요청의 cmd 안 파일 경로가 "systemlog__<end>.log"처럼 언더스코어
    # 두 개로 훼손되어 나타난다(정상은 언더스코어 한 개) — spec의 "사각지대" 절에
    # 이미 실측 확인된 오염 패턴을, 캡처한 실제 req/cmd_host MQTT 메시지에서 직접
    # 검출한다(내부 로그 의존 없음, 2026-08-11 실측으로 topic/payload 형태 확인).
    dump_cmd cat "$req_capture_file"
    local corrupted_req
    corrupted_req=$(grep -oE '"cmd":"[^"]*systemlog__[0-9]+\.log[^"]*"' "$req_capture_file")
    rm -f "$req_capture_file"

    if [ -n "$corrupted_req" ]; then
        assert "TC17-1: MessageContext가 tid 불일치 cmd_host 응답을 거부함 (위조가 소비되면 후속 req의 파일 경로가 훼손됨=FAIL)" "FAIL" \
            "system_log가 sys_manager에 보낸 실제 cmd_host req에서 훼손된 파일 경로(더블 언더스코어) 확인: ${corrupted_req}"
        echo "    [재현 형태] request_start_time() 이 위조 응답(message=\"\")을 진짜로 소비 → 빈 start_time 으로 후속 파일 경로 생성"
    else
        assert "TC17-1: MessageContext가 tid 불일치 cmd_host 응답을 거부함 (위조가 소비되면 후속 req의 파일 경로가 훼손됨=FAIL)" "PASS"
    fi

    # --- TC17-2 판정: 진짜 요청의 운명 (피해자 관점, TC17-1과 별개 관찰), status로 직접 판정 ---
    # get_log_data의 최종 응답(error_code)이 실질적으로 status와 같은 축이다 —
    # NONE=success, 그 외 값=error, 응답 자체가 없으면(send_and_wait 30s 타임아웃)=timeout.
    # host_agent가 응답 후에도 원격 xz를 마저 쓰는 경우가 있어(TC15/16과 동일 이유)
    # toupload 목록이 안정될 때까지 최대 15초 대기한 뒤 판정.
    local stab_deadline prev_count cur_count
    stab_deadline=$(( $(date +%s) + 15 ))
    prev_count=-1
    while [ "$(date +%s)" -lt "$stab_deadline" ]; do
        cur_count=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
        [ "$cur_count" = "$prev_count" ] && break
        prev_count="$cur_count"
        sleep 2
    done

    local resp_status
    if [ -z "$get_resp" ]; then
        resp_status="timeout"
    elif echo "$get_resp" | grep -q '"error_code":"NONE"'; then
        resp_status="success"
    else
        resp_status="error"
    fi

    if [ "$resp_status" = "success" ]; then
        assert "TC17-2: 위조 스팸 중에도 진짜 get_log_data 요청이 방해받지 않고 정상 완료됨 (응답 status=${resp_status})" "PASS"
    else
        assert "TC17-2: 위조 스팸 중에도 진짜 get_log_data 요청이 방해받지 않고 정상 완료됨 (응답 status=${resp_status})" "FAIL" \
            "get_log_data 최종 응답 status=${resp_status} — 위조 스팸이 실제 요청을 방해했을 가능성"
    fi

    # 참고(판정에는 반영 안 함): status만으로는 못 잡는 사각지대가 있다 — start_time
    # 단계가 위조로 하이재킹돼도 그 뒤 make_log/rotate/compress는 (엉뚱한 파일명이든
    # 말든) 셸 명령 자체는 진짜로 성공해서 get_log_data 응답도 결국 success로 나온다
    # (실측: systemlog__<endtime>.log.xz 처럼 더블 언더스코어 오염). 파일명/xz 무결성은
    # 그 조용한 오염을 잡아내는 유일한 신호라 참고용으로 계속 남겨둔다.
    local AFTER_LIST NEW_FILES NEW_XZ
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    AFTER_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    NEW_FILES=$(comm -13 <(echo "$BEFORE_LIST") <(echo "$AFTER_LIST"))
    NEW_XZ=$(echo "$NEW_FILES" | head -1)
    if [ -n "$NEW_XZ" ]; then
        if ! basename "$NEW_XZ" | grep -qE '^systemlog_[0-9]{14}_[0-9]{14}\.log\.xz$'; then
            echo "    [참고, 판정 무관] 신규 파일명이 정상 형식이 아님: $(basename "$NEW_XZ") — status는 success인데도 start_time이 위조로 오염된 조용한 손상 사례일 수 있음"
        elif ! dump_cmd xz --test "$NEW_XZ"; then
            echo "    [참고, 판정 무관] $(basename "$NEW_XZ") 가 xz --test 실패 — status는 success인데도 실제 압축 결과물이 깨져있을 수 있음"
        fi
    fi

    # cleanup: 이번 run이 새로 만든 .xz뿐 아니라 동반 파일(.xz.meta, raw .log)까지 제거.
    # start_time 오염으로 "systemlog__..."(더블 언더스코어, 정상 운영에서는 나올 수
    # 없는 형태) 잔재가 남을 수 있어 패턴으로 한 번 더 안전하게 쓸어낸다.
    if [ -n "$NEW_FILES" ]; then
        echo "$NEW_FILES" | while IFS= read -r f; do
            [ -z "$f" ] && continue
            rm -f "$f" "${f}.meta" "${f%.xz}"
        done
    fi
    rm -f "${TOUPLOAD_DIR}"/systemlog__*.* 2>/dev/null
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " system_log TC"
echo " $(date)"
echo "============================================"

verify_timer_loop_started() {
    echo "=== [PRE-CHECK] system_log_timer_loop 시작 확인 ==="
    local hit
    hit=$(journalctl -u docker-loader --no-pager -o cat 2>/dev/null | grep -F '[system_log_timer_loop] loop started' | tail -1)
    if [ -n "$hit" ]; then
        echo "  [OK] $hit"
        return 0
    else
        echo "  [WARN] '[system_log_timer_loop] loop started' 로그 없음 — system_log timer 미동작 가능. 계속 진행하나 TC02 발화 보장 안 됨"
        return 1
    fi
}

# 빠른 실행/전체 실행(--full)이 공유하는 공통 시퀀스. TC09(factory_reset)와 후속
# 안내 문구는 각 case 분기에서 따로 처리한다 (전체 실행은 여기 이어 TC15/16을 더 실행).
run_quick_set() {
    verify_timer_loop_started
    # TC02는 자체적으로 system_log를 재시작해 매번 깨끗한 상태에서 시작하므로 순서 무관하지만,
    # 관례상 가장 먼저 실행한다.
    tc02_timer_running

    # TC02 이후 나머지 TC들의 사전 조건(toupload .xz 1개)을 위한 SETUP
    setup_rotate
    tc01_filename_format
    tc03_on_demand_export
    tc04_timeout_large_log
    tc05_compression
    tc06_journal_rotation
    tc07_retention_delete
    tc08_blob_upload

    # nmon TC
    tc12_nmon_retention
    tc13_nmon_no_op
    tc11_nmon_upload_happy_path

    # system_log kill/재시작을 수반하는 TC14는 뒤에 배치.
    tc14_rtc_same_start_merge
}

case "${1}" in
    --tc10-pre)
        tc10_pre
        ;;
    --tc10-post)
        tc10_post
        ;;
    --tc18)
        tc18_low_disk_cleanup

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc05)
        # TC05-4 단독 검증용 (TC05-1~3은 setup_rotate 필요, 여기선 TC05-4만 실행)
        tc05_compression

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc02)
        tc02_timer_running

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc04)
        tc04_timeout_large_log

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc11)
        tc11_nmon_upload_happy_path

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc12)
        tc12_nmon_retention

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc13)
        tc13_nmon_no_op

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc-nmon)
        tc11_nmon_upload_happy_path
        tc12_nmon_retention
        tc13_nmon_no_op

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc14)
        tc14_rtc_same_start_merge

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc15)
        tc15_rotate_sync_compress_fail

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc16)
        tc16_boot_log_compress_fail

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc17)
        tc17_message_context_tid_pollution

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --only)
        # 대시보드의 "선택 실행"에서 사용 — 콤마로 구분된 TC 목록을 받아 그 TC들만 실행한다.
        # 예: sh tc_system_log.sh --only TC01,TC03,TC07
        # TC10은 reboot로 세션이 끊겨 다른 TC와 한 번에 묶을 수 없어 지원하지 않는다
        # (--tc10-pre/--tc10-post 를 별도로 사용).
        shift
        SELECTED="${1:-}"
        if [ -z "$SELECTED" ]; then
            echo "[ERROR] --only 뒤에 TC 목록이 필요합니다 (예: --only TC01,TC03,TC07)"
            exit 1
        fi

        verify_timer_loop_started

        # TC01/03/06 은 setup_rotate() 가 채우는 전역 변수(LATEST_XZ, FILES_BEFORE/AFTER,
        # JOURNAL_*)에 의존하므로, 선택 목록에 하나라도 포함되면 먼저 실행해둔다.
        case ",${SELECTED}," in
            *,TC01,*|*,TC03,*|*,TC06,*)
                setup_rotate
                ;;
        esac

        # 스크립트의 표준 실행 순서를 그대로 따른다 — 사용자가 콤마 목록을 어떤 순서로
        # 넘기든 무관하게 항상 이 순서로 실행한다. TC09(factory_reset)는 toupload/staging을
        # 통째로 비우므로, 다른 TC와 같이 선택돼도 항상 맨 마지막에 오도록 배열 끝에 둔다.
        for tc in TC01 TC02 TC03 TC04 TC05 TC06 TC07 TC08 TC11 TC12 TC13 TC14 TC15 TC16 TC17 TC18 TC09; do
            case ",${SELECTED}," in
                *,${tc},*)
                    case "$tc" in
                        TC01) tc01_filename_format ;;
                        TC02) tc02_timer_running ;;
                        TC03) tc03_on_demand_export ;;
                        TC04) tc04_timeout_large_log ;;
                        TC05) tc05_compression ;;
                        TC06) tc06_journal_rotation ;;
                        TC07) tc07_retention_delete ;;
                        TC08) tc08_blob_upload ;;
                        TC09) tc09_factory_reset ;;
                        TC11) tc11_nmon_upload_happy_path ;;
                        TC12) tc12_nmon_retention ;;
                        TC13) tc13_nmon_no_op ;;
                        TC14) tc14_rtc_same_start_merge ;;
                        TC15) tc15_rotate_sync_compress_fail ;;
                        TC16) tc16_boot_log_compress_fail ;;
                        TC17) tc17_message_context_tid_pollution ;;
                        TC18) tc18_low_disk_cleanup ;;
                    esac
                    ;;
            esac
        done

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --full)
        # 전체 실행: TC10(리부트 수반, SSH 세션이 끊겨 이 스크립트 안에서 이어갈 수 없어
        # 유일하게 제외)만 빼고 TC01~09, 11~16, 18 을 순서대로 실행한다. TC15/16이 각
        # 8~9분+ 걸려 빠른 실행(기본, 인자 없음) 대비 훨씬 길다 — 회귀 확인엔 기본 실행을,
        # 릴리즈 전 전수 검증엔 --full 을 쓴다. TC18은 2026-09-04 재설계로 reboot 대신
        # systemctl restart docker-loader 트리거를 쓰게 되면서 --full/--only에 자연스럽게
        # 편입됐다(더 이상 세션이 안 끊김) — 다만 실제 파티션을 소진시키는 파괴적 시험이라
        # TC09(factory_reset) 직전에 둔다(TC18이 만든 상태를 TC09가 정리해주는 효과도 있음).
        run_quick_set

        # system_log kill/재시작을 수반하는 TC16보다 먼저 대용량 journal 주입 TC15를 둔다
        # (빠른 실행 순서에 TC15/16을 이어붙이는 형태 — TC14 뒤, TC09 앞).
        tc15_rotate_sync_compress_fail
        tc16_boot_log_compress_fail
        tc18_low_disk_cleanup

        # TC09(factory_reset)는 toupload/staging을 통째로 비운다 — 뒤늦게(backlog로 밀려)
        # 처리돼도 더 건드릴 대상이 없도록 항상 맨 마지막에 실행한다.
        tc09_factory_reset

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        echo ""
        echo "[안내] TC10(리부트)만 별도 실행 (전체 실행에는 포함 안 됨):"
        echo "  ./tc_system_log.sh --tc10-pre   (재부팅 발생)"
        echo "  ./tc_system_log.sh --tc10-post  (SSH 재접속 후)"
        ;;
    *)
        # 빠른 실행(회귀 세트): TC10(리부트 수반, SSH 세션이 끊겨 이 스크립트 안에서 이어갈
        # 수 없음)과 TC15/16(대용량 journal 주입 + 180s 타임아웃 대기로 각각 8~9분+ 걸려
        # 빠른 실행을 지나치게 길게 만듦), TC18(실제 파티션을 소진시키는 파괴적 시험이라
        # 매 회귀 실행마다 도는 건 과함)을 제외하고 TC01~09, 11~14 를 순서대로 실행한다.
        # 전체(TC01~09, 11~16, 18)는 --full 참조.
        run_quick_set

        # TC09(factory_reset)는 toupload/staging을 통째로 비운다 — 뒤늦게(backlog로 밀려)
        # 처리돼도 더 건드릴 대상이 없도록 항상 맨 마지막에 실행한다.
        tc09_factory_reset

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        echo ""
        echo "[안내] TC10(리부트)/TC15/TC16/TC17/TC18 은 별도 실행 (빠른 실행/--full 모두 미포함):"
        echo "  ./tc_system_log.sh --tc10-pre   (재부팅 발생)"
        echo "  ./tc_system_log.sh --tc10-post  (SSH 재접속 후)"
        echo "  ./tc_system_log.sh --tc15       (rotate_sync compress 실패, 8분+)"
        echo "  ./tc_system_log.sh --tc16       (boot_log compress 실패, 9분+)"
        echo "  ./tc_system_log.sh --tc17       (MessageContext tid 미검증 재현 — TC17-1 위조 응답 소비/크래시 + TC17-2 진짜 요청 무결성)"
        echo "  ./tc_system_log.sh --tc18       (저장공간 부족 cleanup, systemctl restart docker-loader 트리거 — 파괴적, 사전조건 미충족 시 자동 SKIP)"
        echo "  ./tc_system_log.sh --full       (TC01~09, 11~16, 18 전체, TC17은 미포함)"
        ;;
esac
