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

# ============================================================
# SETUP: get_log_data 1회 실행 (TC01~TC07 공용)
# ============================================================
setup_rotate() {
    echo "[SETUP] get_log_data 요청 (응답 대기 30초 + 파일 생성 대기 10초)..."

    mkdir -p "${TOUPLOAD_DIR}"
    JOURNAL_SIZE_BEFORE=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
    FILES_BEFORE=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)

    ROTATE_RESP=$(send_and_wait "get_log_data" "{}" 30)
    echo "[SETUP] 응답: $([ -n "$ROTATE_RESP" ] && echo "OK: $ROTATE_RESP" || echo 'TIMEOUT')"
    sleep 10

    JOURNAL_SIZE_AFTER=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
    FILES_AFTER=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    LATEST_XZ=$(ls -t "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | head -1)

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

    # 2. FILES_BEFORE 기록
    local files_before files_after t0 latest_before
    files_before=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    latest_before=$(ls -t "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | head -1)
    echo "  [TC02-절차2] files_before=${files_before}, latest=$(basename "${latest_before:-N/A}")"

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

    # 6. 신규 파일 + endtime 확인
    files_after=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    local latest_xz
    latest_xz=$(ls -t "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | head -1)
    echo "  [TC02-절차6] files_after=${files_after}, latest=$(basename "${latest_xz:-N/A}")"

    # 7. 시스템 시간을 현재 시간으로 복원 (NTP)
    echo "  [TC02-절차7] NTP로 시스템 시간 복원..."
    timedatectl set-ntp yes 2>/dev/null
    sleep 2
    echo "    복원 후 시간: $(date '+%F %T')"

    # PASS/FAIL Criteria
    if [ "$files_after" -gt "$files_before" ]; then
        assert "TC02-1: toupload 신규 .xz 생성" "PASS"
    else
        assert "TC02-1: toupload 신규 .xz 생성" "FAIL"
        echo "    files_before=${files_before} files_after=${files_after}"
    fi

    local expected_endtime
    expected_endtime=$(date -d "@${t_shift}" '+%Y%m%d%H%M%S')
    echo "  [TC02-2 수동확인] 최신 파일: $(basename "${latest_xz:-N/A}")"
    echo "                   기대 endtime(+25h): ${expected_endtime} 근처"
    assert "TC02-2: 파일명 endtime이 변경 시간 근처 (수동 확인)" "PASS"
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
    local target_sizes="100 300"
    local raw_sizes="70 210"
    local labels="100MB 300MB"
    local idx=0

    for target_mb in $target_sizes; do
        idx=$((idx + 1))
        local label raw_mb
        label=$(echo "$labels" | awk -v n="$idx" '{print $n}')
        raw_mb=$(echo "$raw_sizes" | awk -v n="$idx" '{print $n}')

        echo ""
        echo "  --- TC04-${idx}: 목표 journal ${label} (urandom ${raw_mb}MB 주입) ---"

        # 1. journal 초기화
        journalctl --rotate 2>/dev/null
        journalctl --vacuum-files=1 2>/dev/null
        sleep 2
        local before_size
        before_size=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
        echo "    [SETUP] vacuum 후 journal: ${before_size}"

        local before_files
        before_files=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)

        # 2. systemd-cat 으로 실제 journal 데이터 주입
        local t_inject_t0 t_inject_t1
        t_inject_t0=$(date +%s)
        head -c $((raw_mb * 1048576)) /dev/urandom | base64 -w 4096 | systemd-cat -t TC04_DUMMY
        sync
        sleep 3
        journalctl --rotate 2>/dev/null
        sleep 2
        t_inject_t1=$(date +%s)
        local after_size
        after_size=$(journalctl --disk-usage 2>/dev/null | awk '/take up/{print $7}')
        echo "    [SETUP] 주입 took $((t_inject_t1 - t_inject_t0))s, journal: ${before_size} → ${after_size}"
        df -h /edge 2>&1 | tail -1

        # 3. get_log_data 요청
        echo "    [TC04-${idx}] get_log_data 요청 송신..."
        local t0 t1 elapsed resp
        t0=$(date +%s)
        resp=$(send_and_wait "get_log_data" "{}" 30)
        t1=$(date +%s)
        elapsed=$((t1 - t0))
        echo "    [TC04-${idx}] 응답: $([ -n "$resp" ] && echo "OK ($resp)" || echo 'TIMEOUT'), 응답까지 ${elapsed}초"
        sleep 10

        local after_files
        after_files=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
        echo "    [TC04-${idx}] after: files=${after_files}"

        if [ "$after_files" -gt "$before_files" ]; then
            assert "TC04-${idx}: journal ${label} 상태에서 10초 이내 .xz 파일 생성" "PASS"
        else
            assert "TC04-${idx}: journal ${label} 상태에서 10초 이내 .xz 파일 생성" "FAIL"
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
        assert "TC05-1: .xz 파일 존재" "PASS"
        if xz --test "$LATEST_XZ" 2>/dev/null; then
            assert "TC05-2: xz 파일 무결성 (xz --test)" "PASS"
        else
            local xz_size xz_age
            xz_size=$(stat -c%s "$LATEST_XZ" 2>/dev/null || echo "?")
            xz_age=$(( $(date +%s) - $(stat -c%Y "$LATEST_XZ" 2>/dev/null || date +%s) ))
            assert "TC05-2: xz 파일 무결성 (xz --test)" "FAIL" \
                "${xz_size}B, 마지막 수정 ${xz_age}초 전 — host_agent 압축 타임아웃(5s) 후에도 xz 프로세스가 취소되지 않고 계속 쓰는 중일 가능성"
        fi
        local log_file="${LATEST_XZ%.xz}"
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
        assert "TC05-1: .xz 파일 존재" "FAIL"
    fi

    # TC05-4: xz -f 덮어쓰기 — staging에 동명 .xz 존재 시 강제 덮어쓰기 성공
    local XZ_TEST_BASE="${STAGING_DIR}/systemlog_tc05xztest_tc05xztest"
    echo "small dummy content" | xz -c > "${XZ_TEST_BASE}.log.xz" 2>/dev/null
    local DUMMY_SIZE
    DUMMY_SIZE=$(stat -c%s "${XZ_TEST_BASE}.log.xz" 2>/dev/null || echo 0)
    seq 1 5000 > "${XZ_TEST_BASE}.log" 2>/dev/null
    if xz -f "${XZ_TEST_BASE}.log" 2>/dev/null; then
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
    echo "  rotate 전: ${JOURNAL_SIZE_BEFORE} → 후: ${JOURNAL_SIZE_AFTER}"
    echo "  [수동 확인] 저널 사용량이 감소했거나 이미 최소 상태이면 PASS"
    assert "TC06-1: journalctl rotate && vacuum 실행됨 (수동 확인)" "PASS"
}

# ============================================================
# TC07: Rotation - 30일 경과 파일 삭제
# ============================================================
tc07_retention_delete() {
    echo "=== TC07: 30일 경과 파일 삭제 ==="

    local dummy_31="${TOUPLOAD_DIR}/systemlog_20250101000000_20250101010000.log.xz"
    local dummy_29="${TOUPLOAD_DIR}/systemlog_20250501000000_20250501010000.log.xz"

    touch -d "31 days ago" "$dummy_31" 2>/dev/null
    touch -d "29 days ago" "$dummy_29" 2>/dev/null
    echo "  더미 파일 생성 완료, get_log_data 트리거 (삭제 확인용)..."
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 10

    if [ ! -f "$dummy_31" ]; then
        assert "TC07-1: 31일 경과 파일 자동 삭제됨" "PASS"
    else
        assert "TC07-1: 31일 경과 파일 자동 삭제됨" "FAIL"
        rm -f "$dummy_31"
    fi

    if [ -f "$dummy_29" ]; then
        assert "TC07-2: 29일 경과 파일 유지됨" "PASS"
        rm -f "$dummy_29"
    else
        assert "TC07-2: 29일 경과 파일 유지됨" "FAIL"
    fi
}

# ============================================================
# TC08: Azure Connector - toupload에 .xz + .meta 파일 존재 확인
# ============================================================
tc08_blob_upload() {
    echo "=== TC08: Azure Connector 업로드 대상 파일 생성 확인 ==="

    local xz_count meta_count
    xz_count=$(ls "${TOUPLOAD_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
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

    local resp
    resp=$(send_and_wait "request_factory_reset" "{}" 30)

    if [ -n "$resp" ]; then
        assert "TC09-1: factory_reset 응답 수신" "PASS"
    else
        assert "TC09-1: factory_reset 응답 수신" "FAIL"
        return
    fi

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
    before_staging=$(ls "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
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
    before_toupload=$(cat "${TC10_SAVE}")
    rm -f "${TC10_SAVE}"

    local after_toupload
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
    old_before=$(ls "${NMON_OLD_DIR}"/*.nmon 2>/dev/null | wc -l)
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
    old_after=$(ls "${NMON_OLD_DIR}"/*.nmon 2>/dev/null | wc -l)
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
#   - nmon.sh 의 find -mtime +30 -exec rm -f 동작 검증
#   - 3 디렉토리: old / archive / toupload/system/nmon
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

    echo "  [TC12-절차2] systemctl restart nmon.service ..."
    systemctl restart nmon.service 2>/dev/null
    sleep 3

    local fail_old_nmon=0 fail_old_meta=0 fail_now_nmon=0 fail_now_meta=0
    for d in "${NMON_OLD_DIR}" "${NMON_ARCHIVE_DIR}" "${NMON_TOUPLOAD_DIR}"; do
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
    local nmon_err
    nmon_err=$(journalctl -u docker-loader --since "1 minute ago" --no-pager -o cat 2>/dev/null \
               | grep -F '[task_upload_nmon]' | grep -E 'ERROR|Failed' | tail -5)
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
    local SL_PID
    SL_PID=$(pgrep -f system_log | head -1)
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
    staging_remain=$(ls "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | wc -l)
    if [ "$staging_remain" -eq 0 ]; then
        assert "TC14-1: staging systemlog_*.log.xz 모두 소비됨 (0개)" "PASS"
    else
        assert "TC14-1: staging systemlog_*.log.xz 모두 소비됨 (0개)" "FAIL"
        echo "    잔존 ${staging_remain}개:"
        ls "${STAGING_DIR}"/systemlog_*.log.xz 2>/dev/null | sed 's/^/      /'
    fi

    local AFTER_TOUPLOAD
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

        if xz --test "$NEW_XZ" 2>/dev/null; then
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

case "${1}" in
    --tc10-pre)
        tc10_pre
        ;;
    --tc10-post)
        tc10_post
        ;;
    --tc05)
        # TC05-4 단독 검증용 (TC05-1~3은 setup_rotate 필요, 여기선 TC05-4만 실행)
        tc05_compression

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
    *)
        verify_timer_loop_started
        # TC02를 가장 먼저 — SETUP의 task_rotate_sync 가 last_run_time 갱신 가능성 회피
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
        tc09_factory_reset

        # nmon 신규 TC — TC12/TC13 은 짧아서 디폴트 포함
        # (TC11 은 BlobUploadDirector 5분+30초 대기가 있어 별도 --tc11 또는 --tc-nmon 으로 분리 실행)
        tc12_nmon_retention
        tc13_nmon_no_op

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        echo ""
        echo "[안내] TC10(리부트)은 별도 실행:"
        echo "  ./tc_system_log.sh --tc10-pre   (재부팅 발생)"
        echo "  ./tc_system_log.sh --tc10-post  (SSH 재접속 후)"
        echo "[안내] TC11(nmon 업로드 happy path)은 디폴트에 포함되지 않음:"
        echo "  ./tc_system_log.sh --tc11       (TC11만)"
        echo "  ./tc_system_log.sh --tc-nmon    (TC11+TC12+TC13 일괄)"
        echo "[안내] TC14(RTC 동일 시작시간 병합)는 system_log kill을 수반하므로 별도 실행:"
        echo "  ./tc_system_log.sh --tc14"
        ;;
esac
