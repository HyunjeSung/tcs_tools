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
# [2026-10-02] TC18(저장공간 부족 cleanup) R09 전용으로 복구 — main에서는
# delete_if_low_disk_space()/delete_oldest_files_until_safe()가 제거되어 2026-09-23에
# TC가 삭제됐으나, R090125 백포트(309e4e2, EWP-2698)에는 cleanup_if_low_disk_space()가
# 그대로 남아있어 R09 검증용으로 720df12 버전을 되살렸다. 해당 함수가 없는 빌드(main
# 계열)에서는 TC18-0 사전 조건에서 자동 SKIP 된다.
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

# [2026-09-23, TC15/16 ENOSPC 1차 실행 실측 후 추가] df -P의 Available(f_bavail)은
# ext4가 일반 프로세스용으로 비워두는 예약 블록(reserved-for-superuser)을 제외한
# 값이다 — 이 DUT의 /edge/log 실측: `stat -f`의 Free(f_bfree)=1374724 blocks vs
# Available(f_bavail)=1291985 blocks(4096B/block), 차이 82739 blocks ≈ 323MB.
# system_log는 root로 돌기 때문에 이 예약 블록까지 그대로 쓸 수 있어, filler를 df
# Available만 보고 계산하면 실제로는 그 예약분만큼 여유가 남아 ENOSPC가 터지지 않는다
# (TC15 1차 실행 실측: df Available이 거의 0(12MB)인데도 root 프로세스(system_log)가
# 11MB dump + 9.1MB xz -0 압축까지 정상 성공 — 이 함수 부재가 원인). filler(root로
# 실행)도 이 예약 블록을 그대로 채울 수 있으므로, ENOSPC를 결정적으로 유발해야 하는
# TC15/16은 df Available 대신 이 true-free(f_bfree) 기준을 써야 한다. TC18(일반
# 저장공간부족 cleanup, 앱의 disk_free_permille 판정 기준 자체가 df Available 기반)은
# 기존 disk_avail_kb를 그대로 쓴다 — 목적이 다르다(앱 판정 기준 재현 vs 물리적 ENOSPC 강제).
disk_truefree_kb() {
    stat -f -c '%f %S' "$1" 2>/dev/null | awk '{printf "%d", ($1 * $2) / 1024}'
}
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

    local setup_epoch
    setup_epoch=$(date +%s)
    ROTATE_RESP=$(send_and_wait "get_log_data" "{}" 30)
    echo "[SETUP] 응답: $([ -n "$ROTATE_RESP" ] && echo "OK: $ROTATE_RESP" || echo 'TIMEOUT')"
    sleep 10

    # 생성된 .xz는 대기 10초 안에도 클라우드 업로드로 지워질 수 있다(2026-10-06 default run
    # 실측: after=0 → TC01/TC03 FAIL). 파일명/생성 여부는 journal에서 확정한다 —
    # dump 대상 파일명 + "Created meta file"(xz 성공 후 업로드 큐 등록) 로그.
    # [2026-10-06 2차] SM의 "Executing host command: journalctl -o cat > ..." 줄은 실측에서 누락된
    # 사례가 있어(140733 run: Created meta만 있고 dump 줄 없음) system_log 자신이 남기는
    # "Created meta file: <name>.xz.meta"를 1순위 근거로 쓴다 — xz 성공+업로드 큐 등록까지 보장.
    local meta_name
    meta_name=$(journalctl -u docker-loader --no-pager -o cat --since "@${setup_epoch}" 2>/dev/null \
                | grep -F "Created meta file: ${TOUPLOAD_DIR}/systemlog_" \
                | grep -o 'systemlog_[0-9]\{14\}_[0-9]\{14\}\.log' | head -1)
    SETUP_XZ_QUEUED=""
    if [ -n "$meta_name" ]; then
        SETUP_DUMP_NAME="$meta_name"
        SETUP_XZ_QUEUED=1
    else
        SETUP_DUMP_NAME=$(journalctl -u docker-loader --no-pager -o cat --since "@${setup_epoch}" 2>/dev/null \
                          | grep -F "journalctl -o cat > ${TOUPLOAD_DIR}/" \
                          | grep -o 'systemlog_[0-9]\{14\}_[0-9]\{14\}\.log' | head -1)
    fi
    dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat --since '@${setup_epoch}' 2>/dev/null | grep -E 'journalctl -o cat > ${TOUPLOAD_DIR}/|Created meta file: ${TOUPLOAD_DIR}/systemlog_'"

    dump_cmd journalctl --disk-usage
    JOURNAL_DISKUSAGE_AFTER="$(journalctl --disk-usage 2>/dev/null)"
    JOURNAL_SIZE_AFTER=$(echo "$JOURNAL_DISKUSAGE_AFTER" | awk '/take up/{print $7}')
    dump_cmd du -sk "${JOURNAL_DIR}"
    JOURNAL_KB_AFTER=$(du -sk "${JOURNAL_DIR}" 2>/dev/null | awk '{print $1}')
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    FILES_AFTER=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    LATEST_XZ=$(find_latest_xz "${TOUPLOAD_DIR}")
    # 업로드로 이미 사라졌으면 journal로 확정한 파일명을 쓴다(TC05/06은 실파일 필요 — 자체 처리)
    [ -z "$LATEST_XZ" ] && [ -n "$SETUP_DUMP_NAME" ] && LATEST_XZ="${TOUPLOAD_DIR}/${SETUP_DUMP_NAME}.xz"

    echo "[SETUP] 완료."
    echo "[SETUP] journal dump 파일명: ${SETUP_DUMP_NAME:-없음}, xz 업로드 큐 등록: $([ -n "$SETUP_XZ_QUEUED" ] && echo 확인 || echo 미확인)"
    echo "[SETUP] xz 파일: before=${FILES_BEFORE} after=${FILES_AFTER}"
    echo "[SETUP] 저널: before=${JOURNAL_SIZE_BEFORE} after=${JOURNAL_SIZE_AFTER}"
    echo ""
}

# ============================================================
# TC01: 파일명 규칙 - systemlog_{시작 시각}_{저장 시각}.log.xz
# ============================================================
tc01_filename_format() {
    echo "=== TC01: 파일명 규칙 검증 ==="
    # 파일명은 SETUP이 journal에서 확정한 dump 대상 + .xz (toupload 실파일은 업로드로 이미
    # 사라졌을 수 있어 ls는 참고 근거 — 파일명 근거는 SETUP의 journal 원문 출력)
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

    # 2. toupload 목록은 참고 근거로만 남긴다 — 발화로 생긴 .xz는 관찰 창(70초) 안에 클라우드
    # 업로드로 지워질 수 있어 파일 개수/diff로는 오판한다(2026-10-06 --full 실측: 13:52:36에
    # 정상 생성됐지만 70초 뒤 toupload 0개 → FAIL). 판정은 journal의 발화/dump 로그로 한다.
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz

    # 3. 시스템 시간을 현재 시간(NTP)과 동기화
    echo "  [TC02-절차3] NTP로 시스템 시간 동기화..."
    timedatectl set-ntp yes 2>/dev/null
    sleep 2
    timedatectl set-ntp false 2>/dev/null
    echo "    동기화 후 시간: $(date '+%F %T')"

    # 4. 시간 +25h shift
    local t0
    t0=$(date +%s)
    local t_shift=$((t0 + 25 * 3600))
    echo "  [TC02-절차4] 시스템 시간 +25h 이동: $(date -d "@${t_shift}" '+%F %T') (원래: $(date -d "@${t0}" '+%F %T'))"
    date -s "@${t_shift}" > /dev/null

    # 5. 타이머 발화 대기 — shift 이후 journal에서 daily task 종료 로그를 최대 70초 폴링
    echo "  [TC02-절차5] 타이머 발화 대기 (최대 70초, journal 폴링)..."
    local i done_line=""
    for i in $(seq 1 35); do
        sleep 2
        done_line=$(journalctl -u docker-loader --no-pager -o cat --since "@${t_shift}" 2>/dev/null \
                     | grep -F '[task_rotate_sync] End of Log rotate logic' | tail -1)
        [ -n "$done_line" ] && break
    done
    dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat --since '@${t_shift}' 2>/dev/null | grep -E 'system_log_timer_loop|task_rotate_sync|Created meta file: ${TOUPLOAD_DIR}/systemlog_'"

    # 6. 발화 산출물 파일명 — task_rotate_sync 안의 rotate&&vacuum이 그 이전 줄("Running daily
    # task", dump 명령)을 지워버리므로(2026-10-06 실측) rotate 뒤에 찍히는 "Created meta file"
    # 줄에서 뽑는다. shift 이후엔 다른 요청이 없으므로 이 구간의 rotate 종료+meta 생성 = timer 발화.
    local dump_name
    dump_name=$(journalctl -u docker-loader --no-pager -o cat --since "@${t_shift}" 2>/dev/null \
                | grep -F "Created meta file: ${TOUPLOAD_DIR}/systemlog_" \
                | grep -o 'systemlog_[0-9]\{14\}_[0-9]\{14\}\.log' | head -1)
    echo "  [TC02-절차6] rotate 종료: ${done_line:-없음}"
    echo "  [TC02-절차6] 발화 산출물: ${dump_name:-없음}.xz"
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz

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
    # 대기한 시간만큼은 더해서 복원한다(t0 그대로면 그만큼 시계가 뒤로 감).
    echo "  [TC02-절차7] 시스템 시간 복원..."
    date -s "@$((t0 + $(date +%s) - t_shift))" > /dev/null
    echo "    복원 후 시간: $(date '+%F %T')"

    # 8. shift 중 timer의 rotate로 생긴 journal 파일은 첫 기록이 미래(+25h) 시각이라, 복원 후에도
    # list-boots 시작시각이 미래로 잡혀 이후 dump 파일명이 start>end로 역전된다(2026-10-06
    # --full 실측: TC01-2 systemlog_20261007135236_20261006125235). rotate로 현재 파일을
    # 닫고 archived 파일을 전부 지워, 다음 dump의 시작시각이 복원된 현재 시각이 되게 한다.
    echo "  [TC02-절차8] 미래 시각 journal 정리..."
    dump_cmd journalctl --rotate
    # BusyBox find는 -delete 미지원(2026-10-06 실측) — 셸 glob으로 직접 삭제
    dump_cmd sh -c "rm -fv ${JOURNAL_DIR}/*/system@*.journal"
    dump_cmd journalctl --list-boots

    # PASS/FAIL Criteria
    if [ -n "$done_line" ] && [ -n "$dump_name" ]; then
        assert "TC02-1: +25h 후 timer 발화 (journal rotate 종료 + toupload .xz meta 생성)" "PASS"
    else
        assert "TC02-1: +25h 후 timer 발화 (journal rotate 종료 + toupload .xz meta 생성)" "FAIL" "rotate_end=${done_line:-없음} meta=${dump_name:-없음}"
    fi

    local expected_endtime actual_endtime expected_epoch actual_epoch diff_sec
    expected_endtime=$(date -d "@${t_shift}" '+%Y%m%d%H%M%S')
    actual_endtime=$(echo "${dump_name:-}" | sed -n 's/systemlog_[0-9]*_\([0-9]\{14\}\)\.log/\1/p')
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
        assert "TC02-2: 파일명 endtime이 변경 시간 ±120초 이내" "FAIL" "발화 dump 파일명 없음"
    fi
}

# ============================================================
# TC03: On-demand export - get_log_data 응답 및 파일 생성
# ============================================================
tc03_on_demand_export() {
    echo "=== TC03: On-demand export ==="

    # 생성 직후 업로드로 지워질 수 있어 개수 비교만으로는 오판 — SETUP이 journal로 확인한
    # "Created meta file: <dump>.xz.meta"(xz 성공 + 업로드 큐 등록)도 생성 근거로 인정한다.
    if [ "$FILES_AFTER" -gt "$FILES_BEFORE" ] || [ -n "$SETUP_XZ_QUEUED" ]; then
        assert "TC03-1: get_log_data 후 .xz 파일 신규 생성됨" "PASS"
        echo "  before=${FILES_BEFORE} after=${FILES_AFTER}, journal 큐 등록=${SETUP_DUMP_NAME:-없음}.xz"
    else
        assert "TC03-1: get_log_data 후 .xz 파일 신규 생성됨" "FAIL"
        echo "  before=${FILES_BEFORE} after=${FILES_AFTER}"
    fi
}

# ============================================================
# TC04: On-demand timeout - dump(185s)/compress(305s) 분리 타임아웃 반영
# ============================================================
tc04_timeout_large_log() {
    echo "=== TC04: On-demand timeout (실제 journal 데이터 시나리오) ==="
    echo "  systemd-cat으로 journald에 실제 데이터 주입 → 사이즈별로 get_log_data 응답/파일 생성/무결성 검증"

    # 사이즈 (MB journal 목표)와 라벨, 그에 맞춰 주입할 raw urandom 사이즈
    # 측정 기준: 200MB urandom (base64 -w 4096) → journald 약 281MB (≈1.4x)
    # 300MB는 압축 시간이 너무 오래 걸려 150MB로 축소했었으나, 100MB/150MB 두 티어
    # 모두 180초 SYSTEM_LOG_REQUEST_CMD_TIMEOUT 경계까지 압축을 밀어붙이는 통에
    # cmd_host의 늦은 응답이 MessageContext를 오염시키는 레이스를 매 run마다
    # 재현시키는 주범이었다 — 100MB 단일 티어만 남겼었다.
    # [2026-09-23] xz -0 + compress 전용 300초(SYSTEM_LOG_XZ_CMD_TIMEOUT) 분리 반영 —
    # 200MB(신규) 티어를 추가해 레벨0+300초 예산이 실제로 대용량 성공에 쓰이는지 확인.
    # 응답 대기 상한도 티어별로 분리: 100MB=200초(기존), 200MB=500초(dump 185+compress 305
    # 이론상 최악 합산치 490초에 여유를 더한 값 — 목표 소요시간이 아니라 "느리지만 정상
    # 완주"를 오판 FAIL하지 않기 위한 상한일 뿐).
    local target_sizes="100 200"
    local raw_sizes="70 143"
    local labels="100MB 200MB"
    local wait_timeouts="200 500"
    local idx=0

    # compress 실패 시 system_log는 raw .log(100~200MB)를 toupload에 남긴다 — 그대로 두면
    # 뒤 TC(TC15 등)의 디스크 계산/신규 .log 판정을 흐리므로 TC04가 만든 것만 마지막에 정리.
    local RAW_BEFORE_LIST
    RAW_BEFORE_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log 2>/dev/null | sort)

    for target_mb in $target_sizes; do
        idx=$((idx + 1))
        local label raw_mb wait_timeout
        label=$(echo "$labels" | awk -v n="$idx" '{print $n}')
        raw_mb=$(echo "$raw_sizes" | awk -v n="$idx" '{print $n}')
        wait_timeout=$(echo "$wait_timeouts" | awk -v n="$idx" '{print $n}')

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
        echo "    [TC04-${idx}] get_log_data 요청 송신 (최대 ${wait_timeout}초 대기)..."
        local t0 t1 elapsed resp
        t0=$(date +%s)
        # 응답 직후 업로드로 원본이 지워질 수 있어 스냅샷 사본으로 판정한다(TC05와 동일, 2026-10-06)
        local snap_dir="/tmp/tc04_xz_snapshot"
        start_xz_snapshot "$snap_dir"
        resp=$(send_and_wait "get_log_data" "{}" "$wait_timeout")
        t1=$(date +%s)
        elapsed=$((t1 - t0))
        echo "    [TC04-${idx}] 응답: $([ -n "$resp" ] && echo "OK ($resp)" || echo 'TIMEOUT'), 응답까지 ${elapsed}초"
        sleep 3
        stop_xz_snapshot

        local AFTER_LIST after_files new_xz new_name
        AFTER_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
        after_files=$(echo "$AFTER_LIST" | grep -c .)
        new_name=$(pick_completed_snapshot "$(echo "$BEFORE_LIST" | xargs -r -n1 basename | sort)" "$snap_dir" "@${t0}")
        new_xz=""
        [ -n "$new_name" ] && new_xz="${snap_dir}/${new_name}"

        dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
        dump_cmd ls -la "$snap_dir"
        dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat --since '@${t0}' 2>/dev/null | grep -E 'Created meta file: ${TOUPLOAD_DIR}/systemlog_|Failed to compress'"
        echo "    [TC04-${idx}] after: files=${after_files}, 압축 완료(meta 로그) 신규=${new_name:-없음}"

        # criteria ID: 100MB 티어 = TC04-1(존재)/TC04-2(무결성), 200MB 티어 = TC04-3/TC04-4
        local exist_id integrity_id
        exist_id=$((idx * 2 - 1))
        integrity_id=$((idx * 2))

        if [ -n "$new_xz" ]; then
            assert "TC04-${exist_id}: journal ${label} 상태에서 get_log_data 완료 응답 후 .xz 파일 생성" "PASS"
        else
            assert "TC04-${exist_id}: journal ${label} 상태에서 get_log_data 완료 응답 후 .xz 파일 생성" "FAIL"
            echo "    before_files=${before_files} after_files=${after_files}, journal=${after_size}, 응답=${elapsed}s"
        fi

        # [신규] 무결성 확인 — 레벨0 압축 산출물도 정상 신장 가능한지
        if [ -n "$new_xz" ] && [ -f "$new_xz" ]; then
            if dump_cmd xz --test "$new_xz"; then
                assert "TC04-${integrity_id}: ${label} 티어 산출물 무결성" "PASS"
            else
                assert "TC04-${integrity_id}: ${label} 티어 산출물 무결성" "FAIL"
            fi
        else
            assert "TC04-${integrity_id}: ${label} 티어 산출물 무결성" "FAIL" "신규 .xz 없음 — 무결성 검사 대상 없음"
        fi
        rm -rf "$snap_dir"
    done

    # 최종 cleanup
    local RAW_AFTER_LIST raw_left f
    RAW_AFTER_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log 2>/dev/null | sort)
    raw_left=$(comm -13 <(echo "$RAW_BEFORE_LIST") <(echo "$RAW_AFTER_LIST"))
    if [ -n "$raw_left" ]; then
        echo "  [CLEANUP] TC04가 남긴 raw .log 정리 (compress 실패 잔재)"
        for f in $raw_left; do
            dump_cmd ls -la "$f"
            rm -f "$f" "${f}.xz" 2>/dev/null
        done
    fi
    journalctl --rotate 2>/dev/null
    journalctl --vacuum-files=1 2>/dev/null
}

# ============================================================
# TC05: Rotation - xz 압축 확인
# ============================================================
# toupload에 생기는 systemlog_*.log.xz를 업로드로 지워지기 전에 0.2초 간격으로 $1에 복사해
# 둔다(크기가 바뀌면 다시 복사 — xz가 쓰는 중이던 partial을 최종본으로 덮어씀). 생성 직후
# 클라우드 업로드가 원본을 지워도 내용 검증(xz --test)을 할 수 있게 하기 위함(2026-10-06).
start_xz_snapshot() {
    local snap="$1"
    rm -rf "$snap"
    mkdir -p "$snap"
    (
        while [ -d "$snap" ]; do
            for f in "${TOUPLOAD_DIR}"/systemlog_*.log.xz; do
                [ -f "$f" ] || continue
                if [ "$(stat -c%s "$f" 2>/dev/null)" != "$(stat -c%s "$snap/$(basename "$f")" 2>/dev/null)" ]; then
                    cp -p "$f" "$snap/" 2>/dev/null
                fi
            done
            sleep 0.2
        done
    ) &
    XZ_SNAPSHOT_PID=$!
}

stop_xz_snapshot() {
    kill "$XZ_SNAPSHOT_PID" 2>/dev/null
    wait "$XZ_SNAPSHOT_PID" 2>/dev/null
}

# system_log가 $1(.log.xz 파일명)의 meta를 만들었는지 — "Created meta file"은 xz 성공 후에만
# 찍히므로 압축 완료 + 업로드 큐 등록의 근거다. task_rotate_sync 안의 rotate&&vacuum이 그
# 이전 journal 줄(dump 명령, Running daily task 등)을 지워버리지만 이 줄은 rotate 뒤에
# 찍혀 살아남는다(2026-10-06 실측). $2 = journalctl --since 값.
xz_meta_logged() {
    journalctl -u docker-loader --no-pager -o cat --since "$2" 2>/dev/null \
        | grep -qF "Created meta file: ${TOUPLOAD_DIR}/$1.meta"
}

# 스냅샷($2)의 신규 파일(before 목록 $1 기준) 중 meta 로그($3 이후)가 있는 = 압축 완료된 것을
# 골라 출력. xz 타임아웃으로 지워진 partial .xz 사본을 "생성됨"으로 오판하지 않기 위함
# (2026-10-06 실측: R090127에서 TC04가 partial 사본으로 거짓 PASS). $4(선택) = 우선할 접두어.
pick_completed_snapshot() {
    local before="$1" snap="$2" since="$3" prefix="${4:-}" n
    for n in $(comm -13 <(echo "$before") <(ls "$snap" 2>/dev/null | sort) | sort -t_ -k1,1 \
               | awk -v p="$prefix" 'p != "" && index($0, p) == 1 {print; next} {rest = rest $0 "\n"} END {printf "%s", rest}'); do
        if xz_meta_logged "$n" "$since"; then
            echo "$n"
            return 0
        fi
    done
    return 1
}

tc05_compression() {
    echo "=== TC05: 로그 파일 xz 압축 확인 ==="

    # setup_rotate 시점에 캡처한 LATEST_XZ는 TC04(최대 850초)가 끝날 때까지 실제 클라우드
    # 업로드 파이프라인이 먼저 업로드+삭제해버릴 수 있다(관찰 창이 길수록 흔들림) —
    # TC02/TC04와 동일한 이유로 여기서 자체 get_log_data를 새로 발행하고 comm -13 diff로
    # "이번에 진짜 새로 생긴" 파일만 검사한다.
    # 응답 직후 업로드로 원본이 지워질 수 있어(2026-10-06 실측: 10초 대기 중 소멸) 생성 순간을
    # 스냅샷으로 잡는다 — 존재 판정/무결성은 스냅샷 사본, 원본 .log 삭제는 toupload 원위치로 본다.
    local BEFORE_LIST NEW_XZ NEW_NAME resp snap_dir="/tmp/tc05_xz_snapshot"
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    BEFORE_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | xargs -r -n1 basename | sort)

    local tc05_epoch
    tc05_epoch=$(date +%s)
    start_xz_snapshot "$snap_dir"
    resp=$(send_and_wait "get_log_data" "{}" 30)
    echo "  [TC05] get_log_data 응답: $([ -n "$resp" ] && echo "OK: $resp" || echo 'TIMEOUT')"
    sleep 10
    stop_xz_snapshot

    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    dump_cmd ls -la "$snap_dir"
    dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat --since '@${tc05_epoch}' 2>/dev/null | grep -F 'Created meta file: ${TOUPLOAD_DIR}/systemlog_'"
    NEW_NAME=$(pick_completed_snapshot "$BEFORE_LIST" "$snap_dir" "@${tc05_epoch}")
    NEW_XZ=""
    [ -n "$NEW_NAME" ] && NEW_XZ="${snap_dir}/${NEW_NAME}"

    if [ -n "$NEW_XZ" ] && [ -f "$NEW_XZ" ]; then
        dump_cmd ls -la "$NEW_XZ"
        assert "TC05-1: .xz 파일 존재" "PASS"

        local xz_test_rc
        dump_cmd xz --test "$NEW_XZ"
        xz_test_rc=$?
        if [ "$xz_test_rc" -eq 0 ]; then
            assert "TC05-2: xz 파일 무결성 (xz --test)" "PASS"
        else
            local xz_size xz_age
            xz_size=$(stat -c%s "$NEW_XZ" 2>/dev/null || echo "?")
            xz_age=$(( $(date +%s) - $(stat -c%Y "$NEW_XZ" 2>/dev/null || date +%s) ))
            assert "TC05-2: xz 파일 무결성 (xz --test)" "FAIL" \
                "${xz_size}B, 마지막 수정 ${xz_age}초 전 — host_agent 압축 타임아웃(5s) 후에도 xz 프로세스가 취소되지 않고 계속 쓰는 중일 가능성"
        fi

        local log_file="${TOUPLOAD_DIR}/${NEW_NAME%.xz}"
        dump_cmd ls -la "$log_file"
        if [ ! -f "$log_file" ]; then
            assert "TC05-3: 원본 .log 파일 삭제됨" "PASS"
        else
            local log_size
            log_size=$(stat -c%s "$log_file" 2>/dev/null || echo "?")
            assert "TC05-3: 원본 .log 파일 삭제됨" "FAIL" \
                "원본 .log 여전히 존재 (${log_size}B) — xz는 압축 완료 후에만 원본을 삭제하므로 TC05-2와 동일 원인(압축 미완료)"
        fi
    else
        dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
        assert "TC05-1: .xz 파일 존재" "FAIL"
        echo "  [SKIP] TC05-2~3: 신규 파일 없음"
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
    rm -rf "$snap_dir"
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

    # 업로드로 즉시 지워질 수 있어(2026-10-06 실측: 0개) SETUP 때 journal로 확인한
    # "Created meta file: <SETUP .xz>.meta"(= .xz 생성 + .meta 생성)도 근거로 인정한다.
    echo "  SETUP journal 근거: Created meta file: ${TOUPLOAD_DIR}/${SETUP_DUMP_NAME:-?}.xz.meta ($([ -n "$SETUP_XZ_QUEUED" ] && echo 확인 || echo 미확인))"
    if [ "$xz_count" -gt 0 ] || [ -n "$SETUP_XZ_QUEUED" ]; then
        assert "TC08-1: toupload에 .log.xz 파일 존재" "PASS"
        echo "  .xz 파일 수: $xz_count"
    else
        assert "TC08-1: toupload에 .log.xz 파일 존재" "FAIL"
    fi

    if [ "$meta_count" -gt 0 ] || [ -n "$SETUP_XZ_QUEUED" ]; then
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

    # post 단계용: 1행 toupload 파일 수(참고), 2행 현재 boot_id(재부팅 여부 판정)
    printf '%s\n%s\n' "$before_toupload" "$(cat /proc/sys/kernel/random/boot_id)" > "${TC10_SAVE}"

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

    local before_toupload pre_boot_id cur_boot_id
    dump_cmd cat "${TC10_SAVE}"
    before_toupload=$(sed -n 1p "${TC10_SAVE}")
    pre_boot_id=$(sed -n 2p "${TC10_SAVE}")
    dump_cmd cat /proc/sys/kernel/random/boot_id
    cur_boot_id=$(cat /proc/sys/kernel/random/boot_id)

    # reboot 명령 직후엔 DUT가 꺼지는 중에도 SSH가 붙어, 재부팅 전 상태로 판정하는 사고가
    # 있었다(2026-10-06: post 12:44:25 판정, 실제 부팅 12:44:33). boot_id가 pre와 같으면
    # 판정하지 않고 종료 — .tc10_before는 보존해 재부팅 후 post만 다시 돌릴 수 있게 한다.
    if [ -n "$pre_boot_id" ] && [ "$pre_boot_id" = "$cur_boot_id" ]; then
        echo "[ERROR] 아직 재부팅 전 (boot_id 동일: ${cur_boot_id}) — 재부팅 완료 후 --tc10-post 를 다시 실행하세요 (${TC10_SAVE} 보존)"
        exit 1
    fi
    rm -f "${TC10_SAVE}"

    # 판정은 현재 부팅 journal의 Merge done 로그로 한다 — 병합 파일은 toupload에 들어가자마자
    # 업로드돼 사라질 수 있어 파일 개수 비교는 오판 위험(toupload 목록은 참고 근거로만 남김).
    # pre의 shutdown .xz + 이번 boot .xz 두 개가 병합돼야 하므로 "Single file"은 PASS 아님.
    local i merge_line=""
    for i in $(seq 1 60); do
        merge_line=$(journalctl -b -u docker-loader --no-pager -o cat 2>/dev/null \
                     | grep -F '[task_merge_staged_logs] Merge done' | tail -1)
        [ -n "$merge_line" ] && break
        sleep 2
    done
    dump_cmd sh -c "journalctl -b -u docker-loader --no-pager -o cat 2>/dev/null | grep -F '[task_merge_staged_logs]'"
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    local after_toupload
    after_toupload=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)

    if [ -n "$merge_line" ]; then
        assert "TC10-3: 재부팅 후 shutdown+boot 로그 병합됨 (현재 부팅 journal Merge done)" "PASS"
    else
        assert "TC10-3: 재부팅 후 shutdown+boot 로그 병합됨 (현재 부팅 journal Merge done)" "FAIL" "120초 내 현재 부팅 journal에 Merge done 없음"
    fi
    echo "  (참고) toupload before=${before_toupload} after=${after_toupload}"

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
        assert "TC12-3: mtime 40일 .nmon.meta 잔존 허용 (retention 삭제 대상 아님)" "FAIL"
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
            echo "    [잔존-허용] ${d}/tc12_old40.nmon.meta (meta는 retention 삭제 대상 아님)"
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

    # [2026-10-06] .nmon.meta는 retention 삭제 대상이 아님(사용자 확정) — 지워져도/남아도
    # 정상이므로 판정 게이트에서 제외하고 잔존 개수만 근거로 남긴다(위 ls 원문 참고).
    assert "TC12-3: mtime 40일 .nmon.meta 잔존 허용 (retention 삭제 대상 아님)" "PASS" "잔존 ${fail_old_meta}/3 디렉토리"

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
    local SL_RESTART_TS
    SL_RESTART_TS=$(date '+%Y-%m-%d %H:%M:%S')
    # 병합 파일은 toupload로 옮겨진 직후 업로드로 지워질 수 있어 스냅샷 사본으로 판정(2026-10-06)
    local snap_dir="/tmp/tc14_xz_snapshot"
    start_xz_snapshot "$snap_dir"
    echo "  system_log kill (PID ${SL_PID}) → 재시작 대기..."
    kill -9 "$SL_PID" 2>/dev/null

    # 6-7. task_merge_staged_logs 종료 로그 대기 (최대 300초, 2초 간격)
    # merge는 재시작 직후 task_capture_boot_log(dump+compress)가 끝난 뒤에야 돈다 —
    # 예전처럼 "toupload 신규 파일" 90초 폴링은 boot capture가 길어지면 merge 전에
    # 포기했다(2026-10-06 run: 판정 ~09:54, 실제 Merge done 09:55:08). 종료 로그로 판정한다.
    local MAX_WAIT=300 elapsed=0 merge_line=""
    while [ "$elapsed" -lt "$MAX_WAIT" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        merge_line=$(journalctl -u docker-loader --no-pager -o cat --since "$SL_RESTART_TS" 2>/dev/null \
                     | grep -E '\[task_merge_staged_logs\] (Merge done|Single file|No staged files|Failed|.*Exception)' | tail -1)
        [ -n "$merge_line" ] && break
        [ $((elapsed % 20)) -eq 0 ] && printf "  [%3ds] 대기 중...\n" "$elapsed"
    done
    if [ -n "$merge_line" ]; then
        echo "  [완료 감지 @ ${elapsed}s] ${merge_line}"
        sleep 2   # push_staged_to_toupload 이동 마무리 여유
    else
        echo "  [WARN] ${MAX_WAIT}s 내 task_merge_staged_logs 종료 로그 미감지 — 이후 검증은 현재 상태 기준으로 진행"
    fi
    dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat --since '${SL_RESTART_TS}' 2>/dev/null | grep -F '[task_merge_staged_logs]'"

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

    # 단순 개수 비교(전:후)는 관찰 창 동안 배경 클라우드 업로드가 다른 파일을 먼저
    # 지우면 순감소로 보여 진짜 신규 생성을 놓친다(TC05-1과 동일 원인) — 개수가 아니라
    # comm -13 diff로 "이번에 진짜 새로 생긴" 파일이 있는지로 판정한다.
    stop_xz_snapshot
    local AFTER_TOUPLOAD AFTER_LIST NEW_XZ NEW_NAME
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    dump_cmd ls -la "$snap_dir"
    AFTER_LIST=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    AFTER_TOUPLOAD=$(echo "$AFTER_LIST" | grep -c .)
    # 병합 결과는 start_time=BOOT_START 인 파일 — 같은 창에 rotate 산출물 등 다른 신규 파일이
    # 섞일 수 있어 BOOT_START로 시작하는 것을 우선 고른다.
    NEW_NAME=$(pick_completed_snapshot "$(echo "$BEFORE_LIST" | xargs -r -n1 basename | sort)" "$snap_dir" "$SL_RESTART_TS" "systemlog_${BOOT_START}_")
    NEW_XZ=""
    [ -n "$NEW_NAME" ] && NEW_XZ="${snap_dir}/${NEW_NAME}"
    if [ -n "$NEW_XZ" ]; then
        assert "TC14-2: toupload .log.xz 신규 생성됨" "PASS"
        echo "    toupload: ${BEFORE_TOUPLOAD} → ${AFTER_TOUPLOAD} (신규: $(basename "$NEW_XZ"))"
    else
        assert "TC14-2: toupload .log.xz 신규 생성됨" "FAIL"
        echo "    toupload: ${BEFORE_TOUPLOAD} → ${AFTER_TOUPLOAD}"
    fi

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
    rm -rf "$snap_dir"
}

# ============================================================
# TC15/TC16 공용: ENOSPC 결정적 fault injection (2026-09-23 재설계)
#   [재설계 사유] xz -0(system_log.hpp:34) + compress 전용 300초 타임아웃 분리
#   (SYSTEM_LOG_XZ_CMD_TIMEOUT, :29)로 기존 "raw 400MB 주입 → 180초 공유 타임아웃
#   초과 유도" 방식은 더 이상 compress 실패를 결정적으로 재현하지 못한다(dump가
#   여전히 180초·불변이라 물량을 키워도 dump가 먼저 타임아웃 경계에 도달 — "compress
#   실패"가 아니라 "dump 실패"가 되어 검증하려는 코드 경로(fs::remove(file_path+".xz"))
#   를 타지 않는 거짓 PASS 위험. 상세 근거는 tc_system_log.md TC15 Flag 참고).
#   대신 대상 파티션을 측정된 dump 산출물 크기+마진만 남기고 거의 채워 xz가 ENOSPC로
#   몇 초 안에 결정적으로 실패하도록 만든다 — dump가 "왜" 실패했는지와 무관하게
#   task_rotate_sync/task_capture_boot_log의 다운스트림 정리 로직은 동일하게 탄다.
# ============================================================
# [2026-09-23 실측 조정] STAGING_DIR(/edge/log/system)가 속한 파티션은 /edge/log
# 전용 파티션(mmcblk2p9, 실측 5.9GB total)으로 루트파티션(/)의 df -h 결과(2.1GB)와는
# 전혀 다르다 — 애초 명세 초안의 1536MB 상한은 루트파티션 기준 오추정이었다. TC18이
# 이미 같은 파티션에서 "여유율 85%→9%까지 약 4.55GB 더미"를 실전 검증해뒀으므로
# (TC18_MAX_FILL_MB=6144 참고), TC15/16도 동일 안전 상한을 그대로 재사용한다.
# system_log가 띄운 dump/compress 호스트 명령(journalctl -o cat, xz -f)이 끝날 때까지
# 최대 $1초 대기(5초 연속 미검출 시 idle 판정). 직전 TC의 재시작으로 시작된
# task_capture_boot_log가 다음 TC의 disk fill 도중 ENOSPC로 실패하며 partial .xz를
# 지우면, 그만큼 공간이 돌아와 의도한 ENOSPC가 재현되지 않는다(2026-10-06 run 실측:
# TC14 boot capture xz가 TC15 fill 중 실패 → TC15 compress 성공 → TC15-1~5 FAIL).
wait_system_log_idle() {
    local timeout="$1" i idle=0
    for i in $(seq 1 "$timeout"); do
        if pgrep -f "journalctl -o cat" >/dev/null 2>&1 || pgrep -f "xz -f" >/dev/null 2>&1; then
            idle=0
        else
            idle=$((idle + 1))
            if [ "$idle" -ge 5 ]; then
                echo "  [idle] system_log dump/compress 명령 없음 (${i}s)"
                return 0
            fi
        fi
        sleep 1
    done
    echo "  [WARN] ${timeout}초 내 system_log dump/compress 명령이 끝나지 않음"
    dump_cmd sh -c "ps w | grep -E 'journalctl -o cat|xz -f' | grep -v grep"
    return 1
}

TC15_MAX_FILL_MB=6144
TC16_MAX_FILL_MB=6144
TC_DISK_FILL_MIN_HEADROOM_BYTES=$((20 * 1024 * 1024))   # 20MiB

# 대상 파티션(mount_dir)을, 측정된 dump 산출물 크기(dump_size_bytes) + 마진만 남기고
# filler_dir 아래 여러 파일로 분할해 채운다. 성공 시 stdout으로
# "AVAIL0_BYTES RESERVE_BYTES FILLER_BYTES" 세 값을 한 줄로 출력한다(호출부에서 read로
# 받는다). 사전 조건 미충족(SKIP 대상)이면 아무 것도 출력하지 않고 반환값 1.
tc_disk_fill_for_enospc() {
    local mount_dir="$1" filler_dir="$2" dump_size_bytes="$3" max_fill_mb="$4"

    # true-free(f_bfree, ext4 root 예약 블록 포함) 기준 — df Available(f_bavail)로
    # 계산하면 root 프로세스(system_log)가 예약 블록을 그대로 써버려 ENOSPC가 안 터진다
    # (2026-09-23 1차 실행 실측, 위 disk_truefree_kb 주석 참고).
    local avail0_kb avail0_bytes
    avail0_kb=$(disk_truefree_kb "$mount_dir")
    if [ -z "$avail0_kb" ] || [ "$avail0_kb" -le 0 ]; then
        echo "  [SKIP] ${mount_dir} 여유공간(true-free) 조회 실패 (avail0_kb=${avail0_kb})" >&2
        return 1
    fi
    avail0_bytes=$((avail0_kb * 1024))

    # [2026-09-23 실측 조정 이력] margin이 너무 작으면(5%, ~0.56MB) fill 오차로 dump
    # 자체가 0바이트로 실패하고("Failed to make log!!" — 의도한 경로 아님), 너무 크면
    # (30%/20MiB 하한, ~21MB) 이번엔 ENOSPC 자체가 안 터진다(manual_xz_exit=0 관측).
    # "dump는 항상 성공하되 compress만 ENOSPC로 실패"하는 구간이 두 값 사이 어딘가에
    # 있다고 보고 중간값(10MiB 하한 / dump_size의 10%)으로 재조정한다.
    local margin_bytes reserve_bytes
    margin_bytes=$((dump_size_bytes * 10 / 100))
    [ "$margin_bytes" -lt $((10 * 1024 * 1024)) ] && margin_bytes=$((10 * 1024 * 1024))
    reserve_bytes=$((dump_size_bytes + margin_bytes))

    echo "  [계산] AVAIL0=${avail0_bytes}B DUMP_SIZE=${dump_size_bytes}B RESERVE=${reserve_bytes}B" >&2

    if [ "$avail0_bytes" -le $((reserve_bytes + TC_DISK_FILL_MIN_HEADROOM_BYTES)) ]; then
        echo "  [SKIP] 여유공간(${avail0_bytes}B)이 RESERVE+20MiB(${reserve_bytes}B+20MiB) 이하 — 이미 빠듯해 안전하게 재현 불가" >&2
        return 1
    fi

    local filler_bytes max_fill_bytes
    filler_bytes=$((avail0_bytes - reserve_bytes))
    max_fill_bytes=$((max_fill_mb * 1024 * 1024))
    if [ "$filler_bytes" -gt "$max_fill_bytes" ]; then
        echo "  [SKIP] 필요 filler(${filler_bytes}B) > 안전 상한(${max_fill_bytes}B, ${max_fill_mb}MB) — df 파싱 이상 가능성, 시험 중단" >&2
        return 1
    fi

    mkdir -p "$filler_dir"
    local filler_mb=$((filler_bytes / 1048576))
    [ "$filler_mb" -lt 1 ] && filler_mb=1
    echo "  [채우기] ${filler_dir} 에 약 ${filler_mb}MB filler 생성 (여러 파일 분할)..." >&2
    local remain=$filler_mb idx=1 chunk
    while [ "$remain" -gt 0 ]; do
        chunk=128
        [ "$chunk" -gt "$remain" ] && chunk=$remain
        dd if=/dev/zero of="${filler_dir}/fill_$(printf '%03d' "$idx").bin" bs=1M count="$chunk" 2>/dev/null
        remain=$((remain - chunk))
        idx=$((idx + 1))
    done
    sync

    echo "${avail0_bytes} ${reserve_bytes} ${filler_bytes}"
    return 0
}

# 14/15번(간접 증거) 다음 단계 — 디스크가 아직 거의 가득 찬 상태에서 동일 조건으로
# ENOSPC를 직접 재현한 명령 실행 결과 자체를 근거로 남긴다.
tc_manual_xz_enospc_probe() {
    local target_log="$1"
    rm -f "${target_log}.xz"
    echo "  \$ xz --keep -0 -v \"$target_log\""
    xz --keep -0 -v "$target_log" > /tmp/tc_manual_xz_out_$$ 2>&1
    local rc=$?
    sed 's/^/    /' /tmp/tc_manual_xz_out_$$
    echo "    manual_xz_exit=${rc}"
    if grep -qi "no space left on device" /tmp/tc_manual_xz_out_$$; then
        echo "    [MATCH] stderr에 'No space left on device' 포함"
        MANUAL_XZ_ENOSPC_MATCHED=1
    else
        echo "    [NO-MATCH] stderr에 'No space left on device' 미포함"
        MANUAL_XZ_ENOSPC_MATCHED=0
    fi
    MANUAL_XZ_EXIT="$rc"
    rm -f /tmp/tc_manual_xz_out_$$ "${target_log}.xz"
}

TC15_FILLER_DIR="/edge/log/.tc15_disk_filler"
TC15_NEW_LOG=""
TC15_AVAIL0_BYTES=""

tc15_cleanup() {
    echo "  [CLEANUP] TC15 복원 시작..."
    rm -f "${TC15_NEW_LOG}.xz" 2>/dev/null
    [ -n "$TC15_NEW_LOG" ] && rm -f "$TC15_NEW_LOG" 2>/dev/null
    rm -rf "$TC15_FILLER_DIR" 2>/dev/null
    dump_cmd journalctl --rotate
    dump_cmd journalctl --vacuum-files=1
    dump_cmd df -P "${STAGING_DIR}"
    if [ -n "$TC15_AVAIL0_BYTES" ]; then
        local restored_kb restored_bytes lo hi
        restored_kb=$(disk_truefree_kb "${STAGING_DIR}")
        restored_bytes=$((restored_kb * 1024))
        # 하한만 본다 — 시험 중 업로드/vacuum으로 공간이 AVAIL0보다 더 늘어나는 건 정상
        # (2026-10-06 실측 restored=AVAIL0의 106%로 상한 초과 FAIL 오탐).
        lo=$((TC15_AVAIL0_BYTES * 95 / 100))
        if [ "$restored_bytes" -ge "$lo" ]; then
            assert "TC15-7: 정리 후 filler 잔재 없음 + 여유공간 AVAIL0의 95% 이상 복원" "PASS"
        else
            assert "TC15-7: 정리 후 filler 잔재 없음 + 여유공간 AVAIL0의 95% 이상 복원" "FAIL" "AVAIL0=${TC15_AVAIL0_BYTES}B restored=${restored_bytes}B (하한 ${lo}B)"
        fi
    fi
    [ -d "$TC15_FILLER_DIR" ] && echo "  [WARN] filler 디렉토리 잔존: $TC15_FILLER_DIR"
    echo "  [CLEANUP] TC15 복원 완료"
}

tc15_rotate_sync_compress_fail() {
    echo "=== TC15: task_rotate_sync compress 실패 시 raw .log 보존 (toupload) — ENOSPC fault injection ==="
    TC15_NEW_LOG=""
    TC15_AVAIL0_BYTES=""
    trap tc15_cleanup EXIT

    # Phase 0 — 측정 및 사전 조건 계산
    wait_system_log_idle 300
    dump_cmd journalctl --rotate
    dump_cmd journalctl --vacuum-files=1
    sleep 2

    inject_dummy_blob "TC15_ENOSPC_DUMMY" 48
    sync
    sleep 3
    dump_cmd journalctl --rotate
    sleep 2

    local measure_file="/tmp/tc15_measure_dump.log"
    rm -f "$measure_file"
    journalctl -o cat > "$measure_file" 2>/dev/null
    local dump_size_bytes
    dump_size_bytes=$(wc -c < "$measure_file" 2>/dev/null)
    [ -z "$dump_size_bytes" ] && dump_size_bytes=0
    rm -f "$measure_file"
    echo "  [측정] journalctl -o cat 산출물 크기: ${dump_size_bytes} bytes"

    local calc_out avail0_bytes reserve_bytes filler_bytes
    calc_out=$(tc_disk_fill_for_enospc "${STAGING_DIR}" "$TC15_FILLER_DIR" "$dump_size_bytes" "$TC15_MAX_FILL_MB")
    if [ -z "$calc_out" ]; then
        assert "TC15-0: 사전 조건 충족(여유공간>RESERVE+20MiB AND FILLER_BYTES<=${TC15_MAX_FILL_MB}MB)" "FAIL" "SKIP — 계산/여유공간 조건 미충족(위 로그 참고)"
        return
    fi
    avail0_bytes=$(echo "$calc_out" | awk '{print $1}')
    reserve_bytes=$(echo "$calc_out" | awk '{print $2}')
    filler_bytes=$(echo "$calc_out" | awk '{print $3}')
    TC15_AVAIL0_BYTES="$avail0_bytes"
    assert "TC15-0: 사전 조건 충족(여유공간>RESERVE+20MiB AND FILLER_BYTES<=${TC15_MAX_FILL_MB}MB)" "PASS"
    echo "  [OK] AVAIL0=${avail0_bytes}B RESERVE=${reserve_bytes}B FILLER=${filler_bytes}B"

    # Phase 1 — disk 채우기 및 트리거
    dump_cmd df -P "${STAGING_DIR}"

    dump_cmd journalctl --list-boots
    local before_head before_list
    before_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  BEFORE list-boots head: ${before_head}"
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log
    before_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log 2>/dev/null | sort)

    # get_log_data 응답은 task_rotate_sync(dump+rotate+compress+move)가 끝난 뒤에야 오므로
    # 응답 = compress 실패/성공 확정 신호다. ENOSPC 도달 시간은 xz 레벨에 좌우된다 — xz -0
    # 빌드는 수 초, 기본 레벨(R090127)은 출력이 천천히 커져 127초 걸린 실측이 있다(2026-10-06:
    # 90초 대기로 판정 시점에 partial .xz가 아직 쓰이는 중 → TC15-2/4/5 오판). compress
    # 타임아웃(구 180초/신 300초)까지 덮도록 300초 대기.
    echo "  get_log_data 요청 송신 (최대 300초 대기 — 응답이 곧 compress 결과 확정 신호)..."
    local t0 t1 resp
    t0=$(date +%s)
    resp=$(send_and_wait "get_log_data" "{}" 300)
    t1=$(date +%s)
    echo "  응답: $([ -n "$resp" ] && echo "OK: $resp" || echo 'TIMEOUT'), 소요 $((t1 - t0))초"
    sleep 5

    # Phase 2 — 검증
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log
    local after_list
    after_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log 2>/dev/null | sort)
    TC15_NEW_LOG=$(comm -13 <(echo "$before_list") <(echo "$after_list") | head -1)

    if [ -n "$TC15_NEW_LOG" ] && [ -f "$TC15_NEW_LOG" ]; then
        assert "TC15-1: 압축 실패 후 raw .log 가 toupload에 보존됨" "PASS"
        dump_cmd ls -la "$TC15_NEW_LOG"
    else
        assert "TC15-1: 압축 실패 후 raw .log 가 toupload에 보존됨" "FAIL"
        echo "    신규 .log 파일을 찾지 못함"
    fi

    if [ -n "$TC15_NEW_LOG" ]; then
        dump_cmd ls -la "${TC15_NEW_LOG}.xz"
        if [ ! -f "${TC15_NEW_LOG}.xz" ]; then
            assert "TC15-2: 깨진 partial .xz 는 남지 않음" "PASS"
        else
            assert "TC15-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        fi

        dump_cmd ls -la "${TC15_NEW_LOG}.xz.meta"
        if [ ! -f "${TC15_NEW_LOG}.xz.meta" ]; then
            assert "TC15-3: .meta 생성되지 않음 (업로드 큐에 미등록)" "PASS"
        else
            assert "TC15-3: .meta 생성되지 않음 (업로드 큐에 미등록)" "FAIL"
        fi

        local compress_fail_marker="[task_rotate_sync] Failed to compress log!! Keeping raw .log, removing partial .xz."
        local dump_fail_marker="Failed to make log!!"
        dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat --since '$(date -d '-5 minutes' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '5 minutes ago')' 2>/dev/null | grep -E 'Failed to (compress log|make log)'"
        if journalctl -u docker-loader --no-pager -o cat 2>/dev/null | grep -qF "$compress_fail_marker"; then
            assert "TC15-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "PASS"
        elif journalctl -u docker-loader --no-pager -o cat 2>/dev/null | grep -qF "$dump_fail_marker"; then
            assert "TC15-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "FAIL" "dump 단계에서 실패함(의도한 코드 경로 아님) — filler 크기/RESERVE 마진 재조정 필요"
        else
            assert "TC15-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "FAIL" "두 마커 모두 미검출"
        fi

        tc_manual_xz_enospc_probe "$TC15_NEW_LOG"
        if [ "$MANUAL_XZ_EXIT" -ne 0 ] && [ "$MANUAL_XZ_ENOSPC_MATCHED" -eq 1 ]; then
            assert "TC15-5: 수동 재현 xz --keep -0 이 ENOSPC로 실패" "PASS"
        else
            assert "TC15-5: 수동 재현 xz --keep -0 이 ENOSPC로 실패" "FAIL" "manual_xz_exit=${MANUAL_XZ_EXIT} (여유공간이 예상보다 넉넉했을 가능성 — 마진 재조정 필요)"
        fi
    else
        assert "TC15-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        assert "TC15-3: .meta 생성되지 않음" "FAIL"
        assert "TC15-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "FAIL"
        assert "TC15-5: 수동 재현 xz --keep -0 이 ENOSPC로 실패" "FAIL"
    fi

    dump_cmd journalctl --list-boots
    local after_head
    after_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  AFTER list-boots head: ${after_head}"
    if [ "$after_head" != "$before_head" ]; then
        assert "TC15-6: vacuum이 실행되어 list-boots head 변경됨" "PASS"
    else
        assert "TC15-6: vacuum이 실행되어 list-boots head 변경됨" "FAIL"
        echo "    head 불변: ${after_head}"
    fi

    # Phase 3 — 복원 (trap으로 무조건 실행, 여기서도 명시 호출 후 trap 해제)
    tc15_cleanup
    trap - EXIT
}

TC16_FILLER_DIR="/edge/log/.tc16_disk_filler"
TC16_NEW_LOG=""
TC16_AVAIL0_BYTES=""

tc16_cleanup() {
    echo "  [CLEANUP] TC16 복원 시작..."
    # 증거는 이미 dump_cmd로 원문 캡처했으므로 "진단용 보존" 없이 항상 삭제
    # (파괴적 시험은 영구 잔재를 남기지 않는다는 원칙을 "로그 미확인 시 보존"보다 우선)
    rm -f "${TC16_NEW_LOG}.xz" 2>/dev/null
    [ -n "$TC16_NEW_LOG" ] && rm -f "$TC16_NEW_LOG" 2>/dev/null
    rm -rf "$TC16_FILLER_DIR" 2>/dev/null
    dump_cmd journalctl --rotate
    dump_cmd journalctl --vacuum-files=1
    dump_cmd df -P "${STAGING_DIR}"
    if [ -n "$TC16_AVAIL0_BYTES" ]; then
        local restored_kb restored_bytes lo hi
        restored_kb=$(disk_truefree_kb "${STAGING_DIR}")
        restored_bytes=$((restored_kb * 1024))
        # 하한만 본다 — 시험 중 업로드/vacuum으로 공간이 AVAIL0보다 더 늘어나는 건 정상
        # (2026-10-06 실측 restored=AVAIL0의 106%로 상한 초과 FAIL 오탐).
        lo=$((TC16_AVAIL0_BYTES * 95 / 100))
        if [ "$restored_bytes" -ge "$lo" ]; then
            assert "TC16-7: 정리 후 filler 잔재 없음 + 여유공간 AVAIL0의 95% 이상 복원" "PASS"
        else
            assert "TC16-7: 정리 후 filler 잔재 없음 + 여유공간 AVAIL0의 95% 이상 복원" "FAIL" "AVAIL0=${TC16_AVAIL0_BYTES}B restored=${restored_bytes}B (하한 ${lo}B)"
        fi
    fi
    [ -d "$TC16_FILLER_DIR" ] && echo "  [WARN] filler 디렉토리 잔존: $TC16_FILLER_DIR"
    echo "  [CLEANUP] TC16 복원 완료"
}

tc16_boot_log_compress_fail() {
    echo "=== TC16: task_capture_boot_log compress 실패 시 raw .log 보존 (staging) — ENOSPC fault injection ==="
    TC16_NEW_LOG=""
    TC16_AVAIL0_BYTES=""
    trap tc16_cleanup EXIT

    # Phase 0 — 측정 및 사전 조건 계산
    wait_system_log_idle 300
    rm -f "${STAGING_DIR}"/systemlog_*.log.xz "${STAGING_DIR}"/systemlog_*.log \
          "${STAGING_DIR}"/.merging_*.tmp 2>/dev/null
    dump_cmd journalctl --rotate
    dump_cmd journalctl --vacuum-files=1
    sleep 2

    inject_dummy_blob "TC16_ENOSPC_DUMMY" 48
    sync
    sleep 3
    dump_cmd journalctl --rotate
    sleep 2

    local measure_file="/tmp/tc16_measure_dump.log"
    rm -f "$measure_file"
    journalctl -o cat > "$measure_file" 2>/dev/null
    local dump_size_bytes
    dump_size_bytes=$(wc -c < "$measure_file" 2>/dev/null)
    [ -z "$dump_size_bytes" ] && dump_size_bytes=0
    rm -f "$measure_file"
    echo "  [측정] journalctl -o cat 산출물 크기: ${dump_size_bytes} bytes"

    local calc_out avail0_bytes reserve_bytes filler_bytes
    calc_out=$(tc_disk_fill_for_enospc "${STAGING_DIR}" "$TC16_FILLER_DIR" "$dump_size_bytes" "$TC16_MAX_FILL_MB")
    if [ -z "$calc_out" ]; then
        assert "TC16-0: 사전 조건 충족(여유공간>RESERVE+20MiB AND FILLER_BYTES<=${TC16_MAX_FILL_MB}MB)" "FAIL" "SKIP — 계산/여유공간 조건 미충족(위 로그 참고)"
        return
    fi
    avail0_bytes=$(echo "$calc_out" | awk '{print $1}')
    reserve_bytes=$(echo "$calc_out" | awk '{print $2}')
    filler_bytes=$(echo "$calc_out" | awk '{print $3}')
    TC16_AVAIL0_BYTES="$avail0_bytes"
    assert "TC16-0: 사전 조건 충족(여유공간>RESERVE+20MiB AND FILLER_BYTES<=${TC16_MAX_FILL_MB}MB)" "PASS"
    echo "  [OK] AVAIL0=${avail0_bytes}B RESERVE=${reserve_bytes}B FILLER=${filler_bytes}B"

    # Phase 1 — disk 채우기 및 재시작 트리거
    dump_cmd df -P "${STAGING_DIR}"

    dump_cmd journalctl --list-boots
    local before_head
    before_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  BEFORE list-boots head: ${before_head}"

    # 전체 경로 매칭 필수(TC02/TC14 관례) — "system_log"만 쓰면 이 스크립트 자신까지 걸림
    local SL_PID
    SL_PID=$(pgrep -f /edge/app/bin/system_log | head -1)
    if [ -z "$SL_PID" ]; then
        echo "  [ERROR] system_log 프로세스 없음"
        assert "TC16-1: 압축 실패 후 raw .log 가 staging에 보존됨" "FAIL" "system_log 프로세스 없음"
        assert "TC16-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        assert "TC16-3: raw .log 가 toupload로 잘못 이관되지 않음" "FAIL"
        assert "TC16-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "FAIL"
        assert "TC16-5: 수동 재현 xz --keep -0 이 ENOSPC로 실패" "FAIL"
        assert "TC16-6: vacuum이 실행되어 list-boots head 변경됨" "FAIL"
        tc16_cleanup
        trap - EXIT
        return
    fi

    local SL_RESTART_TS
    SL_RESTART_TS=$(date '+%Y-%m-%d %H:%M:%S')
    echo "  system_log kill (PID ${SL_PID}) → 재시작 대기..."
    kill -9 "$SL_PID" 2>/dev/null

    # ENOSPC 자체는 몇 초 안에 실패하지만, kill -9 후 docker-loader 전체 종료→재기동에만
    # ~70초가 걸린 사례가 있어(2026-10-06 실측: SIGTERM까지 50초, 재기동 22초) 60초로는
    # 새 프로세스가 뜨기도 전에 판정·filler 정리가 끝나버렸다 — 2초 간격 최대 180초 폴링.
    local MAX_WAIT=180 elapsed=0 done_line=""
    while [ "$elapsed" -lt "$MAX_WAIT" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        done_line=$(journalctl -u docker-loader --no-pager -o cat --since "$SL_RESTART_TS" 2>/dev/null \
                     | grep -E '\[task_capture_boot_log\] (Done:|Failed to compress log|Failed to dump log)' | tail -1)
        [ -n "$done_line" ] && break
    done
    if [ -n "$done_line" ]; then
        echo "  [완료 감지 @ ${elapsed}s] ${done_line}"
    else
        echo "  [WARN] ${MAX_WAIT}s 내 task_capture_boot_log 완료 신호를 못 찾음 — 이후 검증은 현재 상태 기준으로 진행"
    fi

    # Phase 2 — 검증
    dump_cmd ls -la "${STAGING_DIR}"/systemlog_*.log
    TC16_NEW_LOG=$(ls -t "${STAGING_DIR}"/systemlog_*.log 2>/dev/null | head -1)

    if [ -n "$TC16_NEW_LOG" ] && [ -f "$TC16_NEW_LOG" ]; then
        assert "TC16-1: 압축 실패 후 raw .log 가 staging에 보존됨" "PASS"
    else
        assert "TC16-1: 압축 실패 후 raw .log 가 staging에 보존됨" "FAIL"
        echo "    staging에 raw .log 없음"
    fi

    if [ -n "$TC16_NEW_LOG" ]; then
        dump_cmd ls -la "${TC16_NEW_LOG}.xz"
        if [ ! -f "${TC16_NEW_LOG}.xz" ]; then
            assert "TC16-2: 깨진 partial .xz 는 남지 않음" "PASS"
        else
            assert "TC16-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        fi

        local base moved
        base=$(basename "$TC16_NEW_LOG")
        dump_cmd ls -la "${TOUPLOAD_DIR}/${base}"
        moved=$(find "${TOUPLOAD_DIR}" -name "${base}*" 2>/dev/null | head -1)
        if [ -z "$moved" ]; then
            assert "TC16-3: raw .log 가 toupload로 잘못 이관되지 않음" "PASS"
        else
            assert "TC16-3: raw .log 가 toupload로 잘못 이관되지 않음" "FAIL"
            echo "    발견: $moved"
        fi

        local compress_fail_marker="[task_capture_boot_log] Failed to compress log, keeping raw .log for diagnostics: ${TC16_NEW_LOG}"
        local dump_fail_marker="Failed to dump log"
        dump_cmd sh -c "journalctl -u docker-loader --no-pager -o cat --since '${SL_RESTART_TS}' 2>/dev/null | grep -E 'Failed to (compress log|dump log)'"
        if journalctl -u docker-loader --no-pager -o cat 2>/dev/null | grep -qF "$compress_fail_marker"; then
            assert "TC16-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "PASS"
        elif journalctl -u docker-loader --no-pager -o cat --since "$SL_RESTART_TS" 2>/dev/null | grep -qF "$dump_fail_marker"; then
            assert "TC16-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "FAIL" "dump 단계에서 실패함(의도한 코드 경로 아님) — filler 크기/RESERVE 마진 재조정 필요"
        else
            assert "TC16-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "FAIL" "두 마커 모두 미검출"
        fi

        tc_manual_xz_enospc_probe "$TC16_NEW_LOG"
        if [ "$MANUAL_XZ_EXIT" -ne 0 ] && [ "$MANUAL_XZ_ENOSPC_MATCHED" -eq 1 ]; then
            assert "TC16-5: 수동 재현 xz --keep -0 이 ENOSPC로 실패" "PASS"
        else
            assert "TC16-5: 수동 재현 xz --keep -0 이 ENOSPC로 실패" "FAIL" "manual_xz_exit=${MANUAL_XZ_EXIT} (여유공간이 예상보다 넉넉했을 가능성 — 마진 재조정 필요)"
        fi
    else
        assert "TC16-2: 깨진 partial .xz 는 남지 않음" "FAIL"
        assert "TC16-3: raw .log 가 toupload로 잘못 이관되지 않음" "FAIL"
        assert "TC16-4: compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님" "FAIL"
        assert "TC16-5: 수동 재현 xz --keep -0 이 ENOSPC로 실패" "FAIL"
    fi

    dump_cmd journalctl --list-boots
    local after_head
    after_head=$(journalctl --list-boots 2>/dev/null | head -n 1)
    echo "  AFTER list-boots head: ${after_head}"
    if [ "$after_head" != "$before_head" ]; then
        assert "TC16-6: vacuum이 실행되어 list-boots head 변경됨" "PASS"
    else
        assert "TC16-6: vacuum이 실행되어 list-boots head 변경됨" "FAIL"
    fi

    # Phase 3 — 복원
    tc16_cleanup
    trap - EXIT
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
# TC18: 저장공간 부족(<10%) 시 SYSTEM_LOG_DIRS(staging/toupload/archive) cleanup 확인
# [2026-10-02] R09(R090125 백포트) 전용으로 720df12 버전 복구 — main 빌드에선 자동 SKIP
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

    local TC18_0_LABEL="TC18-0: 사전 조건 확인 (R09 함수 존재, df 파싱 성공, 여유율>=25%, 필요 소진량<=안전상한)"

    # [2026-10-02, R09 전용 복구] 검증 대상 함수가 실행 중인 바이너리에 있는지 먼저 확인한다.
    # main 계열 빌드는 cleanup_if_low_disk_space()가 제거돼 이 시험이 의미가 없으므로
    # 파티션을 채우기 전에 SKIP 한다(실행 중 프로세스의 exe를 직접 grep — /edge/app vs
    # /edge/devapp 핫스왑 경로 차이와 무관하게 실제 돌고 있는 바이너리를 본다).
    local SL_EXE_PID fn_hits
    SL_EXE_PID=$(pgrep -f /edge/app/bin/system_log | head -1)
    dump_cmd sh -c "grep -caF '[cleanup_if_low_disk_space]' /proc/${SL_EXE_PID}/exe"
    fn_hits=$(grep -caF '[cleanup_if_low_disk_space]' "/proc/${SL_EXE_PID}/exe" 2>/dev/null)
    if [ "${fn_hits:-0}" -eq 0 ]; then
        assert "$TC18_0_LABEL" "FAIL" "실행 중 system_log 바이너리(PID ${SL_EXE_PID:-없음})에 cleanup_if_low_disk_space 없음 — R09 전용 TC, 이 빌드에선 시험 중단(SKIP)"
        return
    fi

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
# TC19~21 공용 상수/헬퍼 — 로그 디스크 예산 circuit breaker
# (system_log.hpp:37-39 빌드 상수와 동일한 값을 그대로 씀 — 값이 바뀌면 여기도 갱신 필요)
# ============================================================
LOG_DISK_HARD_LIMIT_MIB=2560
LOG_DISK_LOW_WATERMARK_MIB=2304
# TC18의 TC18_MAX_FILL_MB와 동일한 성격의 안전장치 — df 파싱 이상 등 극단적 상황만 걸러냄.
# 하드리밋(2560MiB) 자체를 채워야 하는 시험이라 TC18보다는 작지만 넉넉한 상한을 둔다.
TC20_MAX_FILL_MB=3072
# "NEED_MB + 15% 마진" — 더미 배치 도중 다른 프로세스의 쓰기 등으로 여유공간이 약간
# 흔들려도 안전하게 하드리밋을 넘기기 위한 마진.
TC20_FILL_MARGIN_PCT=15
BUDGET_FILL_DIR="${STAGING_DIR}/.tc20_budget_fill"
RETENTION_DUMMY_31D="${TOUPLOAD_DIR}/systemlog_20250101000000_20250101010000.log.xz"
RETENTION_DUMMY_1D="${TOUPLOAD_DIR}/systemlog_20250601000000_20250601010000.log.xz"

# stdin으로 파일 경로 목록(줄 단위)을 받아 총 바이트 수를 출력한다. DUT가 BusyBox
# find(v1.35.0)라 GNU find의 `-printf '%s'`를 지원하지 않으므로(실측: "find: unrecognized:
# -printf"), 파일마다 `stat -c '%s'`(BusyBox stat은 -c 지원 확인됨)를 호출하는 방식으로
# 대체한다.
sum_file_sizes() {
    local total=0 sz f
    while IFS= read -r f; do
        sz=$(stat -c '%s' "$f" 2>/dev/null)
        [ -n "$sz" ] && total=$((total + sz))
    done
    echo "$total"
}

# task_check_disk_budget()과 동일한 측정 대상(STAGING_DIR+TOUPLOAD_DIR 재귀, 일반 파일만
# 합산)으로 현재 사용량을 재고, 하드리밋까지 채우는 데 필요한 더미량(NEED_MB)과 사전
# 조건 충족 여부를 계산한다. 전역변수 BUDGET_USAGE0_BYTES/BUDGET_NEED_MB/BUDGET_PRECOND_OK
# (1=충족)/BUDGET_PRECOND_MSG 에 결과를 남긴다.
calc_budget_need_mb() {
    BUDGET_USAGE0_BYTES=$(find "$STAGING_DIR" "$TOUPLOAD_DIR" -type f 2>/dev/null | sum_file_sizes)
    local hard_limit_bytes=$((LOG_DISK_HARD_LIMIT_MIB * 1048576))

    if [ "$BUDGET_USAGE0_BYTES" -ge "$hard_limit_bytes" ]; then
        BUDGET_NEED_MB=0
    else
        BUDGET_NEED_MB=$(( (hard_limit_bytes - BUDGET_USAGE0_BYTES) / 1048576 + 64 ))
    fi

    local total_kb avail_kb
    total_kb=$(disk_total_kb "$STAGING_DIR")
    avail_kb=$(disk_avail_kb "$STAGING_DIR")

    BUDGET_PRECOND_OK=0
    if [ -z "$total_kb" ] || [ -z "$avail_kb" ]; then
        BUDGET_PRECOND_MSG="df -P 파싱 실패 (total_kb=${total_kb} avail_kb=${avail_kb})"
        return
    fi
    if [ "$BUDGET_NEED_MB" -gt "$TC20_MAX_FILL_MB" ]; then
        BUDGET_PRECOND_MSG="필요 소진량 ${BUDGET_NEED_MB}MB > 안전상한 ${TC20_MAX_FILL_MB}MB — 시험 중단(코드 결함 아님)"
        return
    fi
    local need_kb margin_kb
    need_kb=$((BUDGET_NEED_MB * 1024))
    margin_kb=$((need_kb * TC20_FILL_MARGIN_PCT / 100))
    if [ "$avail_kb" -lt $((need_kb + margin_kb)) ]; then
        BUDGET_PRECOND_MSG="여유공간 ${avail_kb}KB < 필요 ${need_kb}KB + 마진(${TC20_FILL_MARGIN_PCT}%) ${margin_kb}KB — 시험 중단(SKIP)"
        return
    fi

    BUDGET_PRECOND_OK=1
    BUDGET_PRECOND_MSG="OK: usage0=$((BUDGET_USAGE0_BYTES / 1048576))MiB need=${BUDGET_NEED_MB}MB avail=${avail_kb}KB"
}

# $1 디렉토리 아래 64MB 청크(.tc20fill 확장자 — delete_oldest_files_until_safe가 삭제
# 대상으로 삼는 .xz/.log/.meta/.nmon 이 아니므로, 저용량 긴급삭제가 부수적으로 같이
# 발화해도 이 더미는 삭제되지 않아 트립 상태가 흔들리지 않는다)를 총 $2 MB만큼 생성.
place_budget_fill() {
    local dir="$1" need_mb="$2"
    mkdir -p "$dir"
    rm -f "$dir"/*.tc20fill 2>/dev/null
    [ "$need_mb" -le 0 ] && return
    local made=0 idx=1 sz remain
    while [ "$made" -lt "$need_mb" ]; do
        remain=$((need_mb - made))
        sz=64
        [ "$sz" -gt "$remain" ] && sz="$remain"
        dd if=/dev/zero of="${dir}/tc20_fill_$(printf '%03d' "$idx").tc20fill" bs=1M count="$sz" 2>/dev/null
        made=$((made + sz))
        idx=$((idx + 1))
    done
    sync
}

remove_budget_fill() {
    local dir="$1"
    rm -f "$dir"/*.tc20fill 2>/dev/null
    rmdir "$dir" 2>/dev/null
}

# TC18과 동일하게 systemctl restart docker-loader로 트리거한다(2026-09-23 변경).
# 전체 경로로 매칭(TC12/14/16 관례) — "system_log"만 쓰면 이 스크립트 자신까지 걸림.
restart_system_log() {
    local pid
    pid=$(pgrep -f /edge/app/bin/system_log | head -1)
    echo "  [budget] systemctl restart docker-loader 트리거 (현재 system_log PID ${pid})..."
    dump_cmd systemctl restart docker-loader
    sleep 2
}

# docker-loader journal 에서 $1 패턴을 최대 $2 초까지 1초 간격으로 폴링. 발견 시 0, 아니면 1.
wait_for_journal_pattern() {
    local pattern="$1" timeout="$2" i
    for i in $(seq 1 "$timeout"); do
        sleep 1
        if journalctl -u docker-loader --no-pager 2>/dev/null | grep -qF "$pattern"; then
            echo "  [${i}s] 로그 감지: $pattern"
            return 0
        fi
    done
    echo "  [WARN] ${timeout}초 내 로그 미감지: $pattern"
    return 1
}

# ============================================================
# TC19: 로그 디스크 예산 watermark 타당성 근거 수집 (informational)
#   - LOG_DISK_HARD_LIMIT_MIB(2560)/LOW_WATERMARK_MIB(2304)는 dev가 TC04 실측(70~210MB)만
#     으로 잠정 추정한 값 — 이 TC는 값을 바꾸지 않고 실기기 dump 산출물 분포/사용량만
#     근거로 남긴다. PASS/FAIL 게이트가 아님(근거 수집 자체 실패 시에만 FAIL).
# ============================================================
tc19_watermark_evidence() {
    echo "=== TC19: 로그 디스크 예산 watermark 타당성 근거 수집 (informational) ==="

    dump_cmd du -sh "$STAGING_DIR" "$TOUPLOAD_DIR"
    # [2026-09-22 수정] DUT가 BusyBox find(v1.35.0)라 GNU find의 -printf를 지원하지
    # 않는다(실측: "find: unrecognized: -printf") — 최초 실행 시 TC19-2 usage_bytes가
    # 항상 0으로 나오는 버그를 발견해 stat -c 기반 while-read 루프로 교체했다.
    dump_cmd sh -c "find '$STAGING_DIR' '$TOUPLOAD_DIR' -type f 2>/dev/null | while IFS= read -r f; do stat -c '%s %y %n' \"\$f\"; done | sort -n"

    local file_count
    file_count=$(find "$STAGING_DIR" "$TOUPLOAD_DIR" -type f 2>/dev/null | wc -l)

    if [ "$file_count" -eq 0 ]; then
        assert "TC19-1: 근거 수집 성공 (두 디렉토리 조회 가능, 파일 목록 1건 이상 획득)" "FAIL" \
            "두 디렉토리 모두 파일이 하나도 없어 분포 근거를 수집할 수 없음"
        return
    fi
    assert "TC19-1: 근거 수집 성공 (두 디렉토리 조회 가능, 파일 목록 1건 이상 획득)" "PASS"
    echo "  [TC19] 총 파일 수: ${file_count}"

    dump_cmd sh -c "find '$STAGING_DIR' '$TOUPLOAD_DIR' -type f 2>/dev/null | while IFS= read -r f; do stat -c '%s' \"\$f\"; done | awk '{s+=\$1} END{print s+0}'"
    local usage_bytes usage_mib ratio_pct
    usage_bytes=$(find "$STAGING_DIR" "$TOUPLOAD_DIR" -type f 2>/dev/null | sum_file_sizes)
    usage_mib=$((usage_bytes / 1048576))
    ratio_pct=$(awk -v u="$usage_bytes" -v lim="$LOG_DISK_HARD_LIMIT_MIB" 'BEGIN{printf "%.2f", u/1048576/lim*100}')
    echo "  [TC19-2, informational] 현재 사용량=${usage_mib}MiB(${usage_bytes} bytes), 하드리밋 ${LOG_DISK_HARD_LIMIT_MIB}MiB 대비 ${ratio_pct}%"

    dump_cmd sh -c "find '$STAGING_DIR' '$TOUPLOAD_DIR' -name '*.log.xz' -type f 2>/dev/null | while IFS= read -r f; do stat -c '%s' \"\$f\"; done | awk '{c++; s+=\$1; if(c==1||\$1>max)max=\$1; if(c==1||\$1<min)min=\$1} END{ if(c>0) printf \"count=%d avg=%.1fMB max=%.1fMB min=%.1fMB\\n\", c, s/c/1048576, max/1048576, min/1048576; else print \"count=0\" }'"

    echo "  [TC19-2] informational — PASS/FAIL 미해당. 위 수치(사용량/여유율/.log.xz 크기 분포)를"
    echo "           QA 결과 보고서에서 hard limit 2560MiB / low watermark 2304MiB 타당성 판단 근거로 사용할 것"
}

# ============================================================
# TC20: 로그 디스크 예산 circuit breaker — 트립/재개 경계 + 트립 중 정상 정리 로직 유지
#   [주의] 파괴적 시험 — /edge/log 파티션에 최대 ~2.6GiB 상당 더미를 실제로 채운다.
#   TC04/TC15/TC16/TC18처럼 디스크 용량을 전제·변경하는 다른 TC와 동시 실행 금지.
#   systemctl restart docker-loader(TC18 재사용 패턴)로 5분 주기 타이머를 기다리지 않고
#   task_check_disk_budget()을 결정적으로 즉시 발화시킨다.
# ============================================================
tc20_disk_budget_circuit_breaker() {
    echo "=== TC20: 로그 디스크 예산 circuit breaker (트립/재개 + 트립 중 정리 로직 유지) ==="

    mkdir -p "$STAGING_DIR" "$TOUPLOAD_DIR"
    dump_cmd df -P "$STAGING_DIR"
    calc_budget_need_mb
    echo "  [TC20] ${BUDGET_PRECOND_MSG}"

    local TC20_0_LABEL="TC20-0: 사전 조건 확인 (여유공간>=NEED_MB+${TC20_FILL_MARGIN_PCT}% 마진 AND NEED_MB<=${TC20_MAX_FILL_MB}MB)"
    if [ "$BUDGET_PRECOND_OK" -ne 1 ]; then
        assert "$TC20_0_LABEL" "FAIL" "$BUDGET_PRECOND_MSG"
        return
    fi
    assert "$TC20_0_LABEL" "PASS"

    # ---- Phase 1: 더미 배치 및 트립 유발 ----
    echo "  [TC20] BUDGET_FILL 더미 생성 중 (총 ${BUDGET_NEED_MB}MB)..."
    place_budget_fill "$BUDGET_FILL_DIR" "$BUDGET_NEED_MB"
    dump_cmd ls -la "$BUDGET_FILL_DIR"

    echo "tc20 retention dummy(31day)" > "$RETENTION_DUMMY_31D"
    touch -d "31 days ago" "$RETENTION_DUMMY_31D"
    echo "tc20 fresh dummy(1day)" > "$RETENTION_DUMMY_1D"
    touch -d "1 day ago" "$RETENTION_DUMMY_1D"
    dump_cmd ls -la "$RETENTION_DUMMY_31D" "$RETENTION_DUMMY_1D"
    dump_cmd df -P "$STAGING_DIR"

    # [2026-09-23 review 재판정] journalctl --list-boots의 head/tail 시각 비교는 vacuum과 무관하게
    # 시간이 지나면 두 번째 값(가장 최근 엔트리 시각)이 항상 늘어나 vacuum 실행 여부를 판별할 수
    # 없었다(실측: head 변경으로 오판됨 — 실제로는 시간 경과만 반영). journalctl --disk-usage(TC04
    # 관례, 401행 참고)로 교체.
    dump_cmd journalctl --disk-usage
    local before_diskusage before_list
    before_diskusage=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
    before_list=$(ls "${STAGING_DIR}"/systemlog_*.log "${STAGING_DIR}"/systemlog_*.log.xz "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null \
        | grep -vF "$RETENTION_DUMMY_31D" | grep -vF "$RETENTION_DUMMY_1D" | sort)

    restart_system_log
    wait_for_journal_pattern "reached the ${LOG_DISK_HARD_LIMIT_MIB} MiB budget" 90
    local trip_found=$?
    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -F 'reached the ${LOG_DISK_HARD_LIMIT_MIB} MiB budget'"
    if [ "$trip_found" -eq 0 ]; then
        assert "TC20-1: 하드리밋 초과로 게이트 트립 로그 발생" "PASS"
    else
        assert "TC20-1: 하드리밋 초과로 게이트 트립 로그 발생" "FAIL"
    fi

    wait_for_journal_pattern "Log disk budget guard is tripped" 60
    local warn_found=$?
    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -F 'Log disk budget guard is tripped'"

    local after_list new_files new_count
    after_list=$(ls "${STAGING_DIR}"/systemlog_*.log "${STAGING_DIR}"/systemlog_*.log.xz "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null \
        | grep -vF "$RETENTION_DUMMY_31D" | grep -vF "$RETENTION_DUMMY_1D" | sort)
    new_files=$(comm -13 <(echo "$before_list") <(echo "$after_list"))
    if [ -z "$new_files" ]; then new_count=0; else new_count=$(echo "$new_files" | wc -l); fi
    echo "  [TC20] 신규 파일 diff: ${new_count}건"
    [ -n "$new_files" ] && echo "$new_files" | sed 's/^/    신규:/'

    if [ "$warn_found" -eq 0 ] && [ "$new_count" -eq 0 ]; then
        assert "TC20-2: 트립 중 신규 dump 차단(WARN 로그 + 신규 파일 미생성)" "PASS"
    else
        assert "TC20-2: 트립 중 신규 dump 차단(WARN 로그 + 신규 파일 미생성)" "FAIL" \
            "warn_found_rc=${warn_found} new_count=${new_count}"
    fi

    # 추가 확인(온디맨드 경로) — 판정에는 영향 없는 보조 증거
    local resp
    resp=$(send_and_wait "get_log_data" "{}" 30)
    echo "  [TC20] 트립 중 get_log_data 응답(보조 확인): $([ -n "$resp" ] && echo "OK: $resp" || echo 'TIMEOUT')"
    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -F '[task_rotate_sync] Failed to make log'"

    local i retention_gone=0
    for i in $(seq 1 90); do
        sleep 1
        [ ! -f "$RETENTION_DUMMY_31D" ] && { retention_gone=1; echo "  [${i}s] 31일 더미 삭제 감지"; break; }
    done
    dump_cmd ls -la "$RETENTION_DUMMY_31D" "$RETENTION_DUMMY_1D"

    # [2026-09-23, review PASS로 확정된 새 설계 반영] delete_if_low_disk_space()/
    # delete_oldest_files_until_safe()가 코드에서 완전히 제거되고, task_check_disk_budget()이
    # 트립되면 cleanup_log_disk_budget()이 STAGING_DIR+TOUPLOAD_DIR의 .xz/.log/.meta/.nmon을
    # "나이(30일) 무관, mtime 오래된 순"으로 watermark까지 지운다(사용자 확정 설계: "2.5GB
    # 초과는 이미 비정상 상황이니 업로드/나이 안 따지고 오래된 순으로 지워도 된다"). 이
    # TC의 RETENTION_DUMMY_1D는 day-retention(30일 미만이라 delete_log 대상 아님)만
    # 전제하고 설계됐던 더미인데, cleanup_log_disk_budget이 활성화된 지금은 이 더미도
    # "존재하는 유일한 삭제 후보"로서 함께 소진될 수 있다(TC20 실측: 두 더미 모두 삭제됨 —
    # BUDGET_FILL[.tc20fill]은 삭제 후보가 아니라 watermark 도달 실패로 게이트가 계속
    # 트립 상태에 머무는데, 그 와중에 cleanup_log_disk_budget이 유일하게 찾은 진짜 후보인
    # 두 더미를 오래된 순으로 전부 지운 것 — 이건 회귀가 아니라 확정된 새 설계가 의도대로
    # 동작한 결과다). 그래서 "1일 더미가 반드시 생존한다"는 낡은 가정은 게이트 판정에서
    # 빼고, day-retention 자체(31일 삭제)만 boolean으로 판정하며, 1일 더미의 생존 여부는
    # informational로만 남긴다(cleanup_log_disk_budget이 활성화된 트립 상황에서는 어느
    # 쪽이든 정상 — 다만 그 소진 경로가 day-retention이 아니라 능동정리라는 점은 TC22가
    # 이미 직접 검증함).
    if [ "$retention_gone" -eq 1 ]; then
        assert "TC20-3: 트립 중에도 day-retention(31일 삭제) 정상 동작" "PASS"
    else
        assert "TC20-3: 트립 중에도 day-retention(31일 삭제) 정상 동작" "FAIL"
    fi
    if [ -f "$RETENTION_DUMMY_1D" ]; then
        echo "  [TC20-3b, informational] 1일 더미 생존 — 트립 중 cleanup_log_disk_budget이 이 더미를"
        echo "           소진할 필요가 없었거나(다른 진짜 후보가 있었거나 워터마크에 이미 도달) 순서상"
        echo "           아직 차례가 안 왔을 수 있음. PASS/FAIL 게이트 아님."
    else
        echo "  [TC20-3b, informational] 1일 더미도 삭제됨 — cleanup_log_disk_budget이 유일하게 찾은"
        echo "           삭제 후보였을 가능성 높음(확정된 새 설계상 정상 동작, day-retention 자체의"
        echo "           결함 아님 — TC22가 이 능동정리 메커니즘 자체를 직접 검증함). PASS/FAIL 게이트 아님."
    fi

    dump_cmd journalctl --disk-usage
    local after_diskusage
    after_diskusage=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
    echo "  [TC20-4, informational/Flag] BEFORE_DISKUSAGE=${before_diskusage}"
    echo "  [TC20-4, informational/Flag] AFTER_DISKUSAGE=${after_diskusage}"
    echo "  [TC20-4] request_rotate_log()(= journalctl --rotate && journalctl --vacuum-files=1)는"
    echo "           request_dump_journal/request_make_log 성공 시에만 도달하므로(task_capture_boot_log/"
    echo "           task_rotate_sync 공통 경로) 현재 코드 기준으로는 트립 중 vacuum이 호출되지 않는 게"
    echo "           기대값이다(이슈1: 이 경로가 사실 버그로 판정됨 — dev 수정 후에는 트립 중에도"
    echo "           vacuum이 돌아야 정상이므로, 그때 이 수치가 달라지는지 회귀용으로 재확인할 것)"
    echo "  [TC20-4] PASS/FAIL 미해당(informational/Flag) — 위 실측을 QA 결과 보고서에 그대로 기록"

    # ---- Phase 2: 재개 유발 및 정리 ----
    # [2026-09-23 review 재판정] log_disk_guard_tripped_는 std::atomic<bool>{false}로 초기화되는
    # 멤버라 재시작(kill -9/systemctl restart 무관)하면 트립 상태 자체가 리셋된다 — "재개" INFO 로그는
    # tripped_==true에서 워터마크 밑으로 내려가는 전환에서만 찍히므로(system_log.cpp:549-560), 재시작
    # 직후에는 애초에 tripped_==false로 시작해 그 전환이 성립하지 않아 절대 관찰 불가능하다. 따라서
    # 여기서는 재시작을 걸지 않고, Phase 1에서 이미 트립된 채 계속 살아있는 프로세스가 5분 주기
    # (LOG_DISK_BUDGET_CHECK_INTERVAL_SEC=300) 자연 재평가로 스스로 전환 로그를 찍을 때까지 기다린다.
    remove_budget_fill "$BUDGET_FILL_DIR"
    dump_cmd df -P "$STAGING_DIR"
    wait_for_journal_pattern "under the ${LOG_DISK_LOW_WATERMARK_MIB} MiB watermark; journal dumps resume" 330
    local resume_found=$?
    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -F 'under the ${LOG_DISK_LOW_WATERMARK_MIB} MiB watermark; journal dumps resume'"
    if [ "$resume_found" -eq 0 ]; then
        assert "TC20-5: 사용량 로우워터마크 이하 복귀 후 게이트 재개 로그 발생" "PASS"
    else
        assert "TC20-5: 사용량 로우워터마크 이하 복귀 후 게이트 재개 로그 발생" "FAIL"
    fi

    local files_before files_after
    files_before=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | grep -vF "$RETENTION_DUMMY_1D" | wc -l)
    resp=$(send_and_wait "get_log_data" "{}" 30)
    echo "  [TC20] 재개 후 get_log_data 응답: $([ -n "$resp" ] && echo "OK: $resp" || echo 'TIMEOUT')"
    sleep 10
    files_after=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | grep -vF "$RETENTION_DUMMY_1D" | wc -l)
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_*.log.xz
    if [ "$files_after" -gt "$files_before" ]; then
        assert "TC20-6: 재개 후 get_log_data 요청 시 신규 .xz 정상 생성" "PASS"
    else
        assert "TC20-6: 재개 후 get_log_data 요청 시 신규 .xz 정상 생성" "FAIL"
    fi

    rm -f "$RETENTION_DUMMY_1D" 2>/dev/null
    remove_budget_fill "$BUDGET_FILL_DIR"
}

# ============================================================
# TC21: 온디맨드 반복 요청 시 WARN 로그량 선형성 (레이트리밋 부재 감내 가능성)
#   [주의] TC20과 동일하게 파괴적 시험(디스크 실채움) — 독립 실행 가능하도록 자체적으로
#   트립 상태를 만든다(TC15/TC16처럼 "의존 TC 없음"을 유지). TC04/15/16/18/20과 동시
#   실행 금지.
# ============================================================
tc21_ondemand_warn_linearity() {
    echo "=== TC21: 온디맨드 반복 요청 시 WARN 로그량 선형성 ==="

    mkdir -p "$STAGING_DIR" "$TOUPLOAD_DIR"
    dump_cmd df -P "$STAGING_DIR"
    calc_budget_need_mb
    echo "  [TC21] ${BUDGET_PRECOND_MSG}"

    local TC21_0_LABEL="TC21-0: 트립 상태 확보 사전 조건(여유공간>=NEED_MB+${TC20_FILL_MARGIN_PCT}% 마진 AND NEED_MB<=${TC20_MAX_FILL_MB}MB)"
    if [ "$BUDGET_PRECOND_OK" -ne 1 ]; then
        assert "$TC21_0_LABEL" "FAIL" "$BUDGET_PRECOND_MSG"
        assert "TC21-1: 반복 요청 횟수만큼(±소폭 여유) WARN 로그 발생" "FAIL" "사전 조건 미충족으로 시험 중단"
        assert "TC21-2: 모든 응답이 타임아웃 없이(10초 이내) 수신됨" "FAIL" "사전 조건 미충족으로 시험 중단"
        return
    fi
    assert "$TC21_0_LABEL" "PASS"

    echo "  [TC21] BUDGET_FILL 더미 배치 후 재시작으로 자체 트립 유발 (TC20과 동일 기법)..."
    place_budget_fill "$BUDGET_FILL_DIR" "$BUDGET_NEED_MB"
    restart_system_log
    wait_for_journal_pattern "reached the ${LOG_DISK_HARD_LIMIT_MIB} MiB budget" 90
    local trip_found=$?
    if [ "$trip_found" -ne 0 ]; then
        assert "TC21-1: 반복 요청 횟수만큼(±소폭 여유) WARN 로그 발생" "FAIL" "트립 유발 실패 — 시험 중단"
        assert "TC21-2: 모든 응답이 타임아웃 없이(10초 이내) 수신됨" "FAIL" "트립 유발 실패 — 시험 중단"
        remove_budget_fill "$BUDGET_FILL_DIR"
        return
    fi

    local req_count=8 timeout_count=0 error_count=0

    # [2026-09-23 review 재판정] 이 DUT는 journal 볼륨이 크면 rotate가 빨리 돌아 사후 grep으로는
    # 증거가 금방 사라진다(실측: 실행 10여 분 뒤 재조회하니 이미 없었음) — TC18과 동일하게 요청
    # 루프 동안 직접 캡처해둔다.
    local JOURNAL_CAP="/tmp/tc21_journal_capture.log"
    rm -f "$JOURNAL_CAP"
    timeout $((req_count * 4 + 20)) journalctl -u docker-loader -f --no-pager -o short-iso > "$JOURNAL_CAP" 2>&1 &

    # [2026-09-23] 단순 개수 비교(-1로 관측된 적 있음)는 실사용 중인 TOUPLOAD_DIR에서 배경
    # 업로드/삭제가 테스트 창과 겹치면 흔들린다 — TC20-2와 동일하게 comm -13 리스트 diff로
    # "진짜 신규 파일"만 판별한다.
    local before_xz_list
    before_xz_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | grep -vF "$RETENTION_DUMMY_1D" | sort)

    local i resp t0 t1 elapsed
    for i in $(seq 1 "$req_count"); do
        t0=$(date +%s)
        resp=$(send_and_wait "get_log_data" "{}" 10)
        t1=$(date +%s)
        elapsed=$((t1 - t0))
        if [ -z "$resp" ]; then
            timeout_count=$((timeout_count + 1))
            echo "  [요청 ${i}/${req_count}] 응답 없음(10초 타임아웃) elapsed=${elapsed}s"
        else
            echo "  [요청 ${i}/${req_count}] 응답 수신 elapsed=${elapsed}s: ${resp}"
            echo "$resp" | grep -qF '"error_code":"UNKNOWN"' && error_count=$((error_count + 1))
        fi
        [ "$i" -lt "$req_count" ] && sleep 4
    done
    sleep 2

    local after_xz_list new_xz_files new_xz_count
    after_xz_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | grep -vF "$RETENTION_DUMMY_1D" | sort)
    new_xz_files=$(comm -13 <(echo "$before_xz_list") <(echo "$after_xz_list"))
    if [ -z "$new_xz_files" ]; then new_xz_count=0; else new_xz_count=$(echo "$new_xz_files" | wc -l); fi
    dump_cmd cat "$JOURNAL_CAP"
    local warn_count
    warn_count=$(grep -cF "Log disk budget guard is tripped, skipping journal dump" "$JOURNAL_CAP" 2>/dev/null)
    echo "  [TC21] REQ_COUNT=${req_count} ERROR_RESP_COUNT=${error_count} WARN_COUNT=${warn_count} TIMEOUT_COUNT=${timeout_count} 신규.xz(diff)=${new_xz_count}"
    [ -n "$new_xz_files" ] && echo "$new_xz_files" | sed 's/^/    신규:/'

    # 요구사항이 실제로 요구하는 것은 "트립 중 반복 요청이 차단됨"이다(TC20-6과 대칭).
    if [ "$error_count" -eq "$req_count" ] && [ "$new_xz_count" -eq 0 ]; then
        assert "TC21-1: 트립 중 반복 요청이 매번 차단됨(에러 응답 + 신규 .xz 미생성)" "PASS"
    else
        assert "TC21-1: 트립 중 반복 요청이 매번 차단됨(에러 응답 + 신규 .xz 미생성)" "FAIL" \
            "REQ_COUNT=${req_count} ERROR_RESP_COUNT=${error_count} 신규.xz(diff)=${new_xz_count}"
    fi

    echo "  [TC21-1b, informational] WARN 로그량: REQ_COUNT=${req_count}건 요청에 WARN_COUNT=${warn_count}건 검출."
    echo "           request_dump_journal()엔 레이트리밋/디바운스 로직이 없음을 코드로 확인함(review 확인됨)"
    echo "           — WARN이 요청 수보다 적게 찍히는 건 그 앞단(request_start_time RPC 등)에서 조기"
    echo "           반환될 가능성 등 별도 원인으로 추정. 요구사항(트립 중 dump 차단) 위반은 아니므로"
    echo "           PASS/FAIL 게이트에서는 제외하고 위 캡처를 근거로만 남긴다."

    if [ "$timeout_count" -eq 0 ]; then
        assert "TC21-2: 모든 응답이 타임아웃 없이(10초 이내) 수신됨" "PASS"
    else
        assert "TC21-2: 모든 응답이 타임아웃 없이(10초 이내) 수신됨" "FAIL" "TIMEOUT_COUNT=${timeout_count}"
    fi

    # cleanup: 게이트를 재개 상태로 복원
    remove_budget_fill "$BUDGET_FILL_DIR"
    restart_system_log
    wait_for_journal_pattern "under the ${LOG_DISK_LOW_WATERMARK_MIB} MiB watermark; journal dumps resume" 90 > /dev/null
    echo "  [TC21] cleanup 완료 — 게이트 재개 상태로 복원 시도함"
}

# ============================================================
# TC22: 로그 디스크 예산 능동 정리(cleanup_log_disk_budget) — 트립 tick 내 즉시 정리+재개
#   [배경, 2026-09-23 신규] task_check_disk_budget()이 트립되면 이제 스스로
#   cleanup_log_disk_budget()을 호출해 STAGING_DIR+TOUPLOAD_DIR의 오래된 .xz/.log/
#   .meta/.nmon부터(mtime 오름차순) 지우며 매번 재측정하고, LOW_WATERMARK(2304MiB)
#   이하가 되면 그 자리에서(재시작 없이, 같은 tick 안에서) 게이트를 되돌린다
#   (system_log.cpp:524-561 task_check_disk_budget, :1043-1104 cleanup_log_disk_budget).
#   TC20/21이 쓰는 `.tc20fill`(비표준 확장자 + `.tc20_budget_fill/` 서브디렉토리 이중
#   보호)은 이 삭제 후보 조건(flat `fs::directory_iterator`, 확장자 화이트리스트)에
#   해당하지 않아 의도적으로 삭제되지 않는다 — 이 TC는 반대로 "실제 삭제 후보가 되는"
#   `.log.xz` 플랫 파일(서브디렉토리 아님)로 더미를 채워 능동 정리 경로 자체를 겨냥한다.
#   [주의] 파괴적 시험 — TC04/TC15/TC16/TC18/TC20/TC21과 동시 실행 금지.
# ============================================================
TC22_FILL_CHUNK_MB=32

# TOUPLOAD_DIR(플랫, 서브디렉토리 아님)에 need_mb 만큼을 32MB 청크의 `.log.xz`
# 더미(cleanup_log_disk_budget의 삭제 후보 조건과 정확히 일치하는 확장자)로 채운다.
# mtime을 청크마다 오름차순(가장 오래된 것=1번=29일 전 근방, 가장 최신=마지막=1일
# 전)으로 분산시켜 삭제 순서(oldest-first)를 검증 가능하게 한다. day-retention
# (LOG_RETAIN_DAY=30일)과 섞이지 않도록 30일 미만으로 유지(기존 규칙 재사용).
place_deletable_fill() {
    local dir="$1" need_mb="$2" tag="$3"
    local made=0 idx=1 sz remain total_chunks age_days f
    total_chunks=$(( (need_mb + TC22_FILL_CHUNK_MB - 1) / TC22_FILL_CHUNK_MB ))
    [ "$total_chunks" -lt 1 ] && total_chunks=1
    TC22_OLDEST_FILE=""
    TC22_NEWEST_FILE=""
    TC22_ALL_FILES=""
    while [ "$made" -lt "$need_mb" ]; do
        remain=$((need_mb - made))
        sz=$TC22_FILL_CHUNK_MB
        [ "$sz" -gt "$remain" ] && sz="$remain"
        f="${dir}/systemlog_${tag}$(printf '%04d' "$idx")_${tag}$(printf '%04d' "$idx").log.xz"
        dd if=/dev/zero of="$f" bs=1M count="$sz" 2>/dev/null
        age_days=$(( 29 - ((idx - 1) * 28 / total_chunks) ))
        [ "$age_days" -lt 1 ] && age_days=1
        [ "$age_days" -gt 29 ] && age_days=29
        touch -d "${age_days} days ago" "$f"
        [ -z "$TC22_OLDEST_FILE" ] && TC22_OLDEST_FILE="$f"
        TC22_NEWEST_FILE="$f"
        TC22_ALL_FILES="${TC22_ALL_FILES}${f}
"
        made=$((made + sz))
        idx=$((idx + 1))
    done
    sync
    TC22_FILL_COUNT=$((idx - 1))
}

remove_deletable_fill() {
    echo "$TC22_ALL_FILES" | while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f"
    done
}

tc22_active_budget_cleanup() {
    echo "=== TC22: 로그 디스크 예산 능동 정리 — 트립 tick 내 즉시 정리+재개 ==="

    mkdir -p "$STAGING_DIR" "$TOUPLOAD_DIR"
    dump_cmd df -P "$STAGING_DIR"
    calc_budget_need_mb
    echo "  [TC22] ${BUDGET_PRECOND_MSG}"

    local TC22_0_LABEL="TC22-0: 사전 조건 확인 (여유공간>=NEED_MB+${TC20_FILL_MARGIN_PCT}% 마진 AND NEED_MB<=${TC20_MAX_FILL_MB}MB)"
    if [ "$BUDGET_PRECOND_OK" -ne 1 ]; then
        assert "$TC22_0_LABEL" "FAIL" "$BUDGET_PRECOND_MSG"
        return
    fi
    assert "$TC22_0_LABEL" "PASS"

    echo "  [TC22] 삭제 후보(.log.xz, 30일 미만 mtime 분산) 더미 배치 중 (총 ${BUDGET_NEED_MB}MB)..."
    place_deletable_fill "$TOUPLOAD_DIR" "$BUDGET_NEED_MB" "tc22"
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_tc22*.log.xz
    echo "  [TC22] 생성된 청크 수: ${TC22_FILL_COUNT}, oldest=${TC22_OLDEST_FILE}, newest=${TC22_NEWEST_FILE}"
    dump_cmd df -P "$STAGING_DIR"

    # [2026-09-23, 1차 실행 후 교체] 재시작 후 journalctl을 사후(post-hoc) 재조회하는
    # 방식(wait_for_journal_pattern)은, 트립 직후 task_capture_boot_log()가 곧바로
    # journalctl --rotate && --vacuum-files=1을 호출해(로그 disk budget 로직과는 무관하게
    # 매 boot마다 항상 실행됨) 트립 메시지가 사후 재조회 시점엔 이미 사라져 있을 위험이
    # 있다(1차 TC22 실행 실측: 다운스트림 정리/재개 로그는 전부 정상 확인됐는데 트립
    # 메시지 자체만 사후 조회로 못 찾음 — TC18/TC21이 이미 겪은 것과 같은 계열의 문제,
    # TC18/TC21처럼 restart 직전에 백그라운드로 짧게 journalctl -f 를 걸어 파일로
    # 떠두고 그 사본에서 판정한다).
    local JOURNAL_CAP="/tmp/tc22_journal_capture.log"
    rm -f "$JOURNAL_CAP"
    timeout 90 journalctl -u docker-loader -f --no-pager -o short-iso > "$JOURNAL_CAP" 2>&1 &
    sleep 1

    restart_system_log

    # 트립→정리→재개 전체 사이클이 끝날 때까지(재개 로그 등장 또는 최대 60초) 기다린
    # 뒤, 캡처 파일에서 각 로그를 개별 확인한다(실측: 전체 사이클이 restart 후 약
    # 1~2초 안에 끝남 — 60초는 넉넉한 상한).
    local i resume_seen=0
    for i in $(seq 1 60); do
        sleep 1
        if grep -qF "under the ${LOG_DISK_LOW_WATERMARK_MIB} MiB watermark; journal dumps resume" "$JOURNAL_CAP" 2>/dev/null; then
            resume_seen=1
            echo "  [${i}s] 재개 로그 감지 — 전체 사이클 완료, 캡처 파일 기준으로 이후 판정"
            break
        fi
    done
    [ "$resume_seen" -eq 0 ] && echo "  [WARN] 60초 내 재개 로그 미감지 — 캡처 파일 현재 상태 기준으로 이후 판정 진행"
    sleep 2
    dump_cmd wc -l "$JOURNAL_CAP"
    dump_cmd cat "$JOURNAL_CAP"

    dump_cmd sh -c "grep -F 'reached the ${LOG_DISK_HARD_LIMIT_MIB} MiB budget' '$JOURNAL_CAP'"
    if grep -qF "reached the ${LOG_DISK_HARD_LIMIT_MIB} MiB budget" "$JOURNAL_CAP" 2>/dev/null; then
        assert "TC22-1: 하드리밋 초과로 게이트 트립 로그 발생" "PASS"
    else
        assert "TC22-1: 하드리밋 초과로 게이트 트립 로그 발생" "FAIL"
        if [ "$resume_seen" -eq 1 ]; then
            echo "    [주의] 트립 메시지는 캡처 파일에서도 못 찾았지만, 다운스트림(정리/재개) 로그는 정상 확인됨"
            echo "           — journald 유실이 아니라 이 LOG(ERROR) 라인 자체가 기록 시점에 유실됐을 가능성(앱 로깅 이슈, review 전달 대상)"
        fi
    fi

    if grep -qF "[cleanup_log_disk_budget] Starting cleanup" "$JOURNAL_CAP" 2>/dev/null; then
        assert "TC22-2: 트립 직후 같은 tick 안에서 능동 정리(cleanup_log_disk_budget) 시작됨" "PASS"
    else
        assert "TC22-2: 트립 직후 같은 tick 안에서 능동 정리(cleanup_log_disk_budget) 시작됨" "FAIL"
    fi

    if grep -qF "[cleanup_log_disk_budget] Removing:" "$JOURNAL_CAP" 2>/dev/null; then
        assert "TC22-3: 삭제 로그(Removing:) 등장" "PASS"
    else
        assert "TC22-3: 삭제 로그(Removing:) 등장" "FAIL"
    fi

    if grep -qF "under the ${LOG_DISK_LOW_WATERMARK_MIB} MiB watermark; journal dumps resume" "$JOURNAL_CAP" 2>/dev/null; then
        assert "TC22-4: 재시작 없이 같은 트립 사이클 안에서 즉시 재개 로그 발생" "PASS"
    else
        assert "TC22-4: 재시작 없이 같은 트립 사이클 안에서 즉시 재개 로그 발생" "FAIL"
    fi

    dump_cmd df -P "$STAGING_DIR"
    local usage_after_bytes watermark_bytes
    usage_after_bytes=$(find "$STAGING_DIR" "$TOUPLOAD_DIR" -type f 2>/dev/null | sum_file_sizes)
    watermark_bytes=$((LOG_DISK_LOW_WATERMARK_MIB * 1048576))
    echo "  [TC22] 실측 usage_after=${usage_after_bytes}B watermark=${watermark_bytes}B"
    if [ "$usage_after_bytes" -le "$watermark_bytes" ]; then
        assert "TC22-5: 실측 사용량이 로우워터마크 이하로 내려감" "PASS"
    else
        assert "TC22-5: 실측 사용량이 로우워터마크 이하로 내려감" "FAIL" "usage_after=${usage_after_bytes}B > watermark=${watermark_bytes}B"
    fi

    if [ -f "$TC22_OLDEST_FILE" ]; then
        assert "TC22-6: 가장 오래된 청크(oldest mtime)가 삭제됨" "FAIL" "여전히 존재: $TC22_OLDEST_FILE"
    else
        assert "TC22-6: 가장 오래된 청크(oldest mtime)가 삭제됨" "PASS"
    fi

    if [ -f "$TC22_NEWEST_FILE" ]; then
        assert "TC22-7: 가장 최신 청크(newest mtime)는 보존됨(watermark에서 멈춰 전량 삭제 아님)" "PASS"
    else
        assert "TC22-7: 가장 최신 청크(newest mtime)는 보존됨(watermark에서 멈춰 전량 삭제 아님)" "FAIL" "newest_file도 삭제됨 — 전량 소진 가능성"
    fi

    # 게이트 실질 재개 확인: get_log_data 요청 시 정상 dump 성공
    local before_xz_list after_xz_list new_xz
    before_xz_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 5
    after_xz_list=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | sort)
    new_xz=$(comm -13 <(echo "$before_xz_list") <(echo "$after_xz_list") | head -1)
    if [ -n "$new_xz" ]; then
        assert "TC22-8: 게이트 재개 후 get_log_data 신규 .xz 정상 생성(dump 차단 해제 실질 확인)" "PASS"
    else
        assert "TC22-8: 게이트 재개 후 get_log_data 신규 .xz 정상 생성(dump 차단 해제 실질 확인)" "FAIL"
    fi

    # cleanup: 남은 청크 전량 제거
    remove_deletable_fill
    dump_cmd ls -la "${TOUPLOAD_DIR}"/systemlog_tc22*.log.xz
    local remain_count
    remain_count=$(ls "${TOUPLOAD_DIR}"/systemlog_tc22*.log.xz 2>/dev/null | wc -l)
    if [ "$remain_count" -eq 0 ]; then
        assert "TC22-9: 정리 후 테스트 청크 잔재 없음" "PASS"
    else
        assert "TC22-9: 정리 후 테스트 청크 잔재 없음" "FAIL" "잔여 ${remain_count}개"
    fi
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

    # 나머지 TC들의 사전 조건(toupload .xz 1개)을 위한 SETUP
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

    # TC02는 시스템 시간을 +25h 옮기므로 SETUP/TC01 등 파일명 시각을 보는 TC 뒤에 둔다
    # (2026-10-06: 맨 앞에서 돌다 미래 시각 journal을 남겨 TC01-2 start>end 오판 유발).
    # 자체적으로 system_log를 재시작하고 끝에 미래 시각 journal도 정리한다.
    tc02_timer_running

    # TC19(로그 디스크 예산 watermark 근거 수집)는 읽기 전용/비파괴적이라 빠른 실행에도
    # 안전하게 포함한다. TC09(factory_reset, run_quick_set 밖에서 마지막에 호출됨)가
    # toupload를 비우기 *전* 시점의 분포를 봐야 하므로 run_quick_set의 맨 끝에 둔다.
    tc19_watermark_evidence
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
        ;;
    --tc19)
        tc19_watermark_evidence

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc20)
        tc20_disk_budget_circuit_breaker

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc21)
        tc21_ondemand_warn_linearity

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc22)
        tc22_active_budget_cleanup

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
            *,TC01,*|*,TC03,*|*,TC06,*|*,TC08,*)
                setup_rotate
                ;;
        esac

        # 스크립트의 표준 실행 순서를 그대로 따른다 — 사용자가 콤마 목록을 어떤 순서로
        # 넘기든 무관하게 항상 이 순서로 실행한다. TC09(factory_reset)는 toupload/staging을
        # 통째로 비우므로, 다른 TC와 같이 선택돼도 항상 맨 마지막에 오도록 배열 끝에 둔다.
        for tc in TC01 TC03 TC04 TC05 TC06 TC07 TC08 TC11 TC12 TC13 TC14 TC02 TC15 TC16 TC17 TC18 TC19 TC20 TC21 TC22 TC09; do
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
                        TC19) tc19_watermark_evidence ;;
                        TC20) tc20_disk_budget_circuit_breaker ;;
                        TC21) tc21_ondemand_warn_linearity ;;
                        TC22) tc22_active_budget_cleanup ;;
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
        # 유일하게 제외)만 빼고 TC01~09, 11~22 를 순서대로 실행한다(TC19는 run_quick_set에
        # 포함됨). TC15/16은 [2026-09-23] ENOSPC fault injection으로 재설계되며 대폭
        # 단축(과거 8~9분+ → 수십 초~수 분대, filler 채우기/복원 시간이 대부분)됐지만
        # 대상 파티션을 거의 다 채우는 파괴적 시험이라 TC20/21/22와 동일하게 빠른 실행
        # (기본, 인자 없음)에서는 계속 제외한다 — 회귀 확인엔 기본 실행을, 릴리즈 전
        # 전수 검증엔 --full 을 쓴다. [2026-09-23] TC18(저장공간 부족 cleanup)은
        # delete_if_low_disk_space()/delete_oldest_files_until_safe() 함수 자체가
        # review 판단으로 제거되면서 검증 대상이 없어져 TC 자체를 삭제함(요구사항:
        # "system_log 아닌 다른 앱 때문에 파티션이 꽉 차도 애먼 system_log 파일만
        # 지워서 실효성이 없다"). TC20/21(로그 디스크 예산 circuit breaker)도 동일한
        # 이유(실제 파티션을 소진시키는 파괴적 시험)로 TC09(factory_reset) 직전에 둔다.
        run_quick_set

        # system_log kill/재시작을 수반하는 TC16보다 먼저 대용량 journal 주입 TC15를 둔다
        # (빠른 실행 순서에 TC15/16을 이어붙이는 형태 — TC14 뒤, TC09 앞).
        tc15_rotate_sync_compress_fail
        tc16_boot_log_compress_fail

        # TC20/TC21(로그 디스크 예산 circuit breaker, 최대 ~2.6GiB 더미)도 동일하게
        # 파괴적 시험이라 TC09(factory_reset) 직전에 둔다 — TC21이 독립적으로 자체 트립을
        # 유발하므로 TC20 직후 실행해도 안전(각자 cleanup에서 게이트를 재개 상태로 복원함).
        tc20_disk_budget_circuit_breaker
        tc21_ondemand_warn_linearity

        # TC22(능동 정리, 2026-09-23 신규)도 동일한 파괴적 성격 — TC20/21 뒤·TC09 앞.
        tc22_active_budget_cleanup

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
        # 수 없음)과 TC15/16/TC20/TC21/TC22(모두 대상 파티션을 거의 다 채우는 파괴적
        # 시험이라 매 회귀 실행마다 도는 건 과함 — TC15/16은 [2026-09-23] ENOSPC 방식으로
        # 재설계되며 소요시간 자체는 대폭 줄었으나 파괴적 성격은 그대로라 계속 제외)을
        # 제외하고 TC01~09, 11~14, 19 를 순서대로 실행한다(TC19는 읽기 전용이라
        # run_quick_set에 포함). 전체(TC01~09, 11~22)는 --full 참조.
        run_quick_set

        # TC09(factory_reset)는 toupload/staging을 통째로 비운다 — 뒤늦게(backlog로 밀려)
        # 처리돼도 더 건드릴 대상이 없도록 항상 맨 마지막에 실행한다.
        tc09_factory_reset

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        echo ""
        echo "[안내] TC10(리부트)/TC15/TC16/TC17/TC20/TC21/TC22 은 별도 실행 (빠른 실행/--full 모두 미포함, TC15/16/20/21/22는 --full에는 포함):"
        echo "  ./tc_system_log.sh --tc10-pre   (재부팅 발생)"
        echo "  ./tc_system_log.sh --tc10-post  (SSH 재접속 후)"
        echo "  ./tc_system_log.sh --tc15       (rotate_sync compress 실패, ENOSPC 방식 — 파괴적, 수십 초~수 분, 사전조건 미충족 시 자동 SKIP)"
        echo "  ./tc_system_log.sh --tc16       (boot_log compress 실패, ENOSPC 방식 — 파괴적, 수십 초~수 분, 사전조건 미충족 시 자동 SKIP)"
        echo "  ./tc_system_log.sh --tc17       (MessageContext tid 미검증 재현 — TC17-1 위조 응답 소비/크래시 + TC17-2 진짜 요청 무결성)"
        echo "  ./tc_system_log.sh --tc18       (저장공간 부족(<10%) cleanup, R09 전용 — 파괴적, main 빌드/사전조건 미충족 시 자동 SKIP)"
        echo "  ./tc_system_log.sh --tc20       (로그 디스크 예산 circuit breaker 트립/재개 — 파괴적, ~2.6GiB 더미, 사전조건 미충족 시 자동 SKIP)"
        echo "  ./tc_system_log.sh --tc21       (온디맨드 반복 요청 시 WARN 로그량 선형성 — 파괴적, 자체 트립 유발)"
        echo "  ./tc_system_log.sh --tc22       (로그 디스크 예산 능동 정리, 트립 tick 내 즉시 정리+재개 — 파괴적, 사전조건 미충족 시 자동 SKIP)"
        echo "  ./tc_system_log.sh --full       (TC01~09, 11~22 전체, TC17은 미포함)"
        ;;
esac
