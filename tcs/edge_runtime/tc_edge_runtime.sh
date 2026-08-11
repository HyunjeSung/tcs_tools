#!/bin/bash
# TC: edge_runtime
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}
#
# 주의: request_reboot(SERVICE_REBOOT_APPLICAITON)은 edge_runtime 자기 프로세스에
# SIGTERM을 보내는 컨테이너(ac_system_gen2) 재시작이다. 물리 장비 재부팅이 아니므로
# SSH 세션은 끊기지 않으나(시리얼 콘솔 기준으로 작성됨) DUT의 EMS 기능은 수십 초~약
# 1분간 정지한다. TC01~TC06/TC08/TC09/TC11 은 파괴적 시험이다 (tc_edge_runtime.md 참고).

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="edge_runtime"
DEVAPP_BIN_DIR="/edge/devapp/bin"
DEVAPP_FILES_DIR="/edge/devapp/files"
REBOOT_INFO_FILE="/edge/log/reboot_info.txt"
UNIEP_APPLIST="/edge/app/files/edge_runtime/uniep_applist.conf"
CONTAINER="ac_system_gen2"
PASS=0
FAIL=0

send_and_wait() {
    local service="$1"
    local payload="$2"
    [ -z "$payload" ] && payload="{}"
    local timeout="${3:-30}"
    local tid="tc-$(date +%s)"
    local full_payload
    # uniep BaseApp 핸들러는 message(=수신 JSON 전체)에서 필드를 바로 읽는다("payload"로
    # 감싸지 않음, tid는 MQTT5 프로퍼티에서 옴·JSON의 tid는 무시됨) — 그래서 payload
    # 필드를 최상위로 flatten해서 보낸다(실측 확인: nested면 "Missing required parameter").
    full_payload=$(printf '%s' "$payload" | jq -c --arg tid "$tid" '. + {tid: $tid}')
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

dump_cmd() {
    echo "  \$ $*"
    "$@" 2>&1 | sed 's/^/    /'
    echo "    exit_code:$?"
}

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "PASS" ]; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc"
        FAIL=$((FAIL + 1))
        [ -n "$3" ] && echo "  [REASON] $3"
    fi
}

# ============================================================
# 공용 헬퍼
# ============================================================

now_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

# journalctl -u docker-loader 를 since 시각부터 max_wait 초 동안 interval마다
# 폴링하며 pattern(고정 문자열)이 나타나면 즉시 0을 반환한다.
poll_journal_grep() {
    local pattern="$1" since="$2" max_wait="$3" interval="${4:-3}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "$pattern"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

# all_apps_ready_status 요청을 max_wait초 동안 5초 간격으로 폴링해 is_ready:true를 기다린다.
wait_all_apps_ready() {
    local max_wait="$1"
    local elapsed=0
    local resp=""
    while [ "$elapsed" -lt "$max_wait" ]; do
        resp=$(send_and_wait "all_apps_ready_status" "{}" 5)
        if echo "$resp" | grep -q '"is_ready"[[:space:]]*:[[:space:]]*true'; then
            echo "  all_apps_ready_status 응답(${elapsed}s): $resp"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "  all_apps_ready_status 마지막 응답: ${resp:-<없음>}"
    return 1
}

# ============================================================
# TC01: Application Reboot 요청 시 전체 Application 정상 종료 (파괴적)
# ============================================================
tc01_reboot_app_shutdown() {
    echo "=== TC01: Application Reboot 요청 시 전체 Application 정상 종료 (파괴적) ==="
    echo "  [사전조건] DUT 정상 부팅 완료, all_apps_ready=true 상태에서 시작 가정"

    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "emsp/${TARGET}/${SOURCE}/req/all_apps_ready_status" -m "{}"

    local since
    since=$(now_ts)

    # TC01-1: 응답 수신 (subscribe 먼저 시작 후 publish)
    local resp_file="/tmp/tc01_resp_$$"
    mosquitto_sub -h "$MQTT_HOST" -t "emsp/${SOURCE}/${TARGET}/res/request_reboot" -W 10 -C 1 > "$resp_file" 2>/dev/null &
    local sub_pid=$!
    sleep 0.5
    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "emsp/${TARGET}/${SOURCE}/req/request_reboot" -m '{"reason":"tc01_test_restart"}'
    wait "$sub_pid"
    local resp
    resp=$(cat "$resp_file" 2>/dev/null)
    rm -f "$resp_file"
    echo "  request_reboot 응답 payload: ${resp:-<없음>}"
    if [ -n "$resp" ]; then
        assert "TC01-1: request_reboot 응답 수신" "PASS"
    else
        assert "TC01-1: request_reboot 응답 수신" "FAIL" "10초 내 응답 없음"
    fi

    echo "  [대기] 종료 시퀀스 완료(EXIT_APP_TIMEOUT_SECONDS=30 + 여유10초=40초) 대기..."
    poll_journal_grep "All apps terminated: YES" "$since" 40 3
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'All apps terminated: YES'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "All apps terminated: YES"; then
        assert "TC01-2: 전체 앱 종료 완료 로그" "PASS"
    else
        assert "TC01-2: 전체 앱 종료 완료 로그" "FAIL" "40초 내 'All apps terminated: YES' 미확인"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'TERMINATE_TIMEOUT_MS -- pid:'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "TERMINATE_TIMEOUT_MS -- pid:"; then
        assert "TC01-3: 강제종료(SIGKILL) 없이 정상 종료" "FAIL" "TERMINATE_TIMEOUT_MS 라인 발견 — 일부 앱 SIGKILL 강제 종료"
    else
        assert "TC01-3: 강제종료(SIGKILL) 없이 정상 종료" "PASS"
    fi

    echo "  [대기] 컨테이너 재기동 후 전체 Ready 복귀(최대 90초) 대기..."
    if wait_all_apps_ready 90; then
        assert "TC01-4: 재기동 후 전체 Ready 복귀" "PASS"
    else
        assert "TC01-4: 재기동 후 전체 Ready 복귀" "FAIL" "90초 내 is_ready=true 미확인"
    fi
}

# ============================================================
# TC02: Application Reboot 요청 시 reboot_info.txt 기록 (TC01과 동일 트리거)
# ============================================================
tc02_reboot_info_file() {
    echo "=== TC02: Application Reboot 요청 시 reboot_info.txt 기록 ==="

    dump_cmd wc -l "$REBOOT_INFO_FILE"
    local lines_before
    lines_before=$(wc -l < "$REBOOT_INFO_FILE" 2>/dev/null)
    [ -z "$lines_before" ] && lines_before=0

    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "emsp/${TARGET}/${SOURCE}/req/request_reboot" -m '{"reason":"tc02_test_restart"}'

    echo "  [대기] 컨테이너 재기동(최대 90초) 대기..."
    wait_all_apps_ready 90 >/dev/null

    dump_cmd tail -n 5 "$REBOOT_INFO_FILE"
    local lines_after
    lines_after=$(wc -l < "$REBOOT_INFO_FILE" 2>/dev/null)
    [ -z "$lines_after" ] && lines_after=0

    if [ "$lines_after" -gt "$lines_before" ] 2>/dev/null; then
        assert "TC02-1: 신규 라인 추가" "PASS"
    else
        assert "TC02-1: 신규 라인 추가" "FAIL" "before=$lines_before after=$lines_after"
    fi

    if tail -n 5 "$REBOOT_INFO_FILE" 2>/dev/null | grep -qF "\"BY\" : \"$SOURCE\""; then
        assert "TC02-2: BY 필드 일치" "PASS"
    else
        assert "TC02-2: BY 필드 일치" "FAIL"
    fi

    if tail -n 5 "$REBOOT_INFO_FILE" 2>/dev/null | grep -qF "tc02_test_restart"; then
        assert "TC02-3: TYPE 필드에 reason 포함" "PASS"
    else
        assert "TC02-3: TYPE 필드에 reason 포함" "FAIL"
    fi
}

# ============================================================
# TC03: 부팅 시 uniep Application 실행 순서 (order 기반 fork/Ready 시퀀스, 파괴적)
# ============================================================
tc03_boot_order() {
    echo "=== TC03: 부팅 시 uniep Application 실행 순서 (파괴적) ==="
    echo "  [사전조건] $UNIEP_APPLIST 가 기본값(수정하지 않은 상태) 이어야 함"

    dump_cmd cat "$UNIEP_APPLIST"

    local since
    since=$(now_ts)
    dump_cmd docker stop "$CONTAINER"

    echo "  [대기] 재기동 후 전체 Ready(최대 90초) 대기..."
    wait_all_apps_ready 90 >/dev/null

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'Spawn App:'"
    local spawn_log
    spawn_log=$(journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -F "Spawn App:")

    local first_spawn
    first_spawn=$(echo "$spawn_log" | head -1)
    if echo "$first_spawn" | grep -qF "db_manager"; then
        assert "TC03-1: db_manager가 가장 먼저 fork됨" "PASS"
    else
        assert "TC03-1: db_manager가 가장 먼저 fork됨" "FAIL" "첫 fork: ${first_spawn:-<없음>}"
    fi

    local names name all_found=1
    names=$(jq -r '.applications[].name' "$UNIEP_APPLIST" 2>/dev/null)
    for name in $names; do
        if ! echo "$spawn_log" | grep -qF "Spawn App: $name"; then
            echo "  [MISSING] Spawn App: $name 로그 없음"
            all_found=0
        fi
    done
    if [ "$all_found" -eq 1 ]; then
        assert "TC03-2: 모든 uniep 앱 fork 로그 존재" "PASS"
    else
        assert "TC03-2: 모든 uniep 앱 fork 로그 존재" "FAIL"
    fi

    # TC03-3(script): fork(Spawn App) 출현 순서를 Ready 순서의 프록시로 사용해
    # conf order 오름차순과 모순되지 않는지 비교(동일 order 그룹 내부는 순서 무관 허용)
    local conf_pairs prev_order=0 order_ok=1 sp_name sp_order
    conf_pairs=$(jq -r '.applications[] | "\(.name) \(.order)"' "$UNIEP_APPLIST" 2>/dev/null)
    for sp_name in $(echo "$spawn_log" | sed 's/.*Spawn App: //' | awk '{print $1}'); do
        sp_order=$(echo "$conf_pairs" | awk -v n="$sp_name" '$1==n{print $2}')
        [ -z "$sp_order" ] && continue
        if [ "$sp_order" -lt "$prev_order" ] 2>/dev/null; then
            order_ok=0
            echo "  [순서위반] $sp_name (order=$sp_order) fork가 이전 order=$prev_order 보다 뒤에 발생"
        fi
        prev_order="$sp_order"
    done
    if [ "$order_ok" -eq 1 ]; then
        assert "TC03-3: fork(Ready proxy) 순서가 order 오름차순과 모순되지 않음" "PASS"
    else
        assert "TC03-3: fork(Ready proxy) 순서가 order 오름차순과 모순되지 않음" "FAIL"
    fi
}

# ============================================================
# TC04: 전체 Application Ready 시 All App Ready 알림 + LED 녹색 전환 (파괴적)
# ============================================================
tc04_all_ready_led_green() {
    echo "=== TC04: 전체 Application Ready 시 All App Ready 알림 + LED 녹색 전환 (파괴적) ==="

    local ready_file="/tmp/tc04_ready_$$"
    local led_file="/tmp/tc04_led_$$"
    mosquitto_sub -h "$MQTT_HOST" -t "emsp/+/${TARGET}/noti/all_apps_ready" -W 90 -C 1 > "$ready_file" 2>/dev/null &
    local ready_pid=$!
    mosquitto_sub -h "$MQTT_HOST" -t "emsp/sys_manager/${TARGET}/req/set_led_control" -W 90 -C 1 > "$led_file" 2>/dev/null &
    local led_pid=$!
    sleep 0.5

    dump_cmd docker stop "$CONTAINER"

    wait "$ready_pid"
    wait "$led_pid"

    local ready_payload led_payload
    ready_payload=$(cat "$ready_file" 2>/dev/null)
    led_payload=$(cat "$led_file" 2>/dev/null)
    rm -f "$ready_file" "$led_file"
    echo "  all_apps_ready payload: ${ready_payload:-<없음>}"
    echo "  set_led_control payload: ${led_payload:-<없음>}"

    if [ -n "$ready_payload" ]; then
        assert "TC04-1: all_apps_ready 알림 수신" "PASS"
    else
        assert "TC04-1: all_apps_ready 알림 수신" "FAIL" "90초 내 미수신"
    fi

    local names name all_found=1
    names=$(jq -r '.applications[].name' "$UNIEP_APPLIST" 2>/dev/null)
    for name in $names; do
        echo "$ready_payload" | grep -qF "$name" || { all_found=0; echo "  [MISSING] app_ids에 $name 없음"; }
    done
    if [ -n "$ready_payload" ] && [ "$all_found" -eq 1 ]; then
        assert "TC04-2: app_ids 배열에 uniep_applist.conf 전체 앱 포함" "PASS"
    else
        assert "TC04-2: app_ids 배열에 uniep_applist.conf 전체 앱 포함" "FAIL"
    fi

    if echo "$led_payload" | grep -q '"color"[[:space:]]*:[[:space:]]*"0 255 0"'; then
        assert "TC04-3: 녹색 LED 제어 요청 발행" "PASS"
    else
        assert "TC04-3: 녹색 LED 제어 요청 발행" "FAIL"
    fi

    # TC04-4(선택): sys_manager 교차 확인
    local led_status
    led_status=$(send_and_wait "get_led_status" '{"instance_id":0}' 10)
    echo "  get_led_status 응답: ${led_status:-<없음>}"
    if echo "$led_status" | grep -q '"color"[[:space:]]*:[[:space:]]*"0 255 0"'; then
        assert "TC04-4(선택): 실제 LED 상태 반영" "PASS"
    else
        assert "TC04-4(선택): 실제 LED 상태 반영" "FAIL" "sys_manager 응답: ${led_status:-<없음>}"
    fi
}

# ============================================================
# TC05: 일부 Application Ready 실패 시 60초 Boot Watchdog 타임아웃
#       → LED 적색 + 컨테이너 재시작 (파괴적, bin 변조)
# ============================================================
tc05_boot_watchdog_60s() {
    echo "=== TC05: 60초 Boot Watchdog 타임아웃 → LED 적색 + 컨테이너 재시작 (파괴적, bin 변조) ==="
    echo "  [경고] 시험 후 반드시 원복 필요 — 원복 누락 시 이후 모든 부팅 실패"

    dump_cmd ls -la "$DEVAPP_BIN_DIR"
    dump_cmd touch "$DEVAPP_BIN_DIR/energy_monitor"
    dump_cmd chmod +x "$DEVAPP_BIN_DIR/energy_monitor"

    local since led_file
    since=$(now_ts)
    led_file="/tmp/tc05_led_$$"
    mosquitto_sub -h "$MQTT_HOST" -t "emsp/sys_manager/${TARGET}/req/set_led_control" -W 70 -C 1 > "$led_file" 2>/dev/null &
    local led_pid=$!
    sleep 0.5

    dump_cmd docker stop "$CONTAINER"

    echo "  [대기] posix_spawn 실패 및 60초 watchdog 판정(최대 70초) 대기..."
    poll_journal_grep "posix_spawn failed" "$since" 70 3

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'posix_spawn failed'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "posix_spawn failed"; then
        assert "TC05-1: fork 실패 로그" "PASS"
    else
        assert "TC05-1: fork 실패 로그" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'Some app did not be executed'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "Some app did not be executed"; then
        assert "TC05-2: 앱 수 불일치 판정 로그" "PASS"
    else
        assert "TC05-2: 앱 수 불일치 판정 로그" "FAIL"
    fi

    wait "$led_pid"
    local led_payload
    led_payload=$(cat "$led_file" 2>/dev/null)
    rm -f "$led_file"
    echo "  set_led_control payload: ${led_payload:-<없음>}"
    if echo "$led_payload" | grep -q '"color"[[:space:]]*:[[:space:]]*"255 0 0"'; then
        assert "TC05-3: 적색 LED 요청 발행" "PASS"
    else
        assert "TC05-3: 적색 LED 요청 발행" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'reboot_conatiner'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "reboot_conatiner" \
        && ! journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "already in progress"; then
        assert "TC05-4: 컨테이너 재시작 트리거" "PASS"
    else
        assert "TC05-4: 컨테이너 재시작 트리거" "FAIL"
    fi

    echo "  [CLEANUP] 원복..."
    dump_cmd rm -f "$DEVAPP_BIN_DIR/energy_monitor"
    dump_cmd docker stop "$CONTAINER"
    echo "  [대기] 원복 후 정상 재부팅(최대 90초) 확인..."
    if wait_all_apps_ready 90; then
        assert "TC05-5(cleanup 검증): 원복 후 정상 재부팅" "PASS"
    else
        assert "TC05-5(cleanup 검증): 원복 후 정상 재부팅" "FAIL" "cleanup 후에도 is_ready=true 미확인 — 수동 점검 필요"
    fi
}

# ============================================================
# TC06: DB Manager Ready 실패 시 10초 초기 서비스 타이머 타임아웃
#       → 컨테이너 재시작 (파괴적, bin 변조)
# ============================================================
tc06_db_manager_10s_timeout() {
    echo "=== TC06: DB Manager Ready 실패 시 10초 초기 서비스 타이머 타임아웃 (파괴적, bin 변조) ==="
    echo "  [경고] 시험 후 반드시 원복 필요"

    dump_cmd ls -la "$DEVAPP_BIN_DIR"
    dump_cmd touch "$DEVAPP_BIN_DIR/db_manager"
    dump_cmd chmod +x "$DEVAPP_BIN_DIR/db_manager"

    local since led_file
    since=$(now_ts)
    led_file="/tmp/tc06_led_$$"
    mosquitto_sub -h "$MQTT_HOST" -t "emsp/sys_manager/${TARGET}/req/set_led_control" -W 30 -C 1 > "$led_file" 2>/dev/null &
    local led_pid=$!
    sleep 0.5

    dump_cmd docker stop "$CONTAINER"

    echo "  [대기] db_manager fork 직후 10초 타이머 시작 로그(t0) 확인(최대 30초)..."
    poll_journal_grep "10 sec. timer starts for initial service" "$since" 30 2
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' -o short-iso | grep -F '10 sec. timer starts for initial service'"
    local t0_line
    t0_line=$(journalctl -u docker-loader --no-pager --since "$since" -o short-iso 2>/dev/null | grep -F "10 sec. timer starts for initial service" | tail -1)
    if [ -n "$t0_line" ]; then
        assert "TC06-1: 10초 타이머 시작 로그" "PASS"
    else
        assert "TC06-1: 10초 타이머 시작 로그" "FAIL"
    fi

    echo "  [대기] t0+15초까지 타임아웃 로그 대기..."
    poll_journal_grep "Initial service timer by timeout" "$since" 20 2
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' -o short-iso | grep -F 'Initial service timer by timeout'"
    local timeout_line
    timeout_line=$(journalctl -u docker-loader --no-pager --since "$since" -o short-iso 2>/dev/null | grep -F "Initial service timer by timeout" | tail -1)

    if [ -n "$t0_line" ] && [ -n "$timeout_line" ]; then
        local t0_epoch tt_epoch
        t0_epoch=$(date -d "$(echo "$t0_line" | awk '{print $1}')" +%s 2>/dev/null)
        tt_epoch=$(date -d "$(echo "$timeout_line" | awk '{print $1}')" +%s 2>/dev/null)
        if [ -n "$t0_epoch" ] && [ -n "$tt_epoch" ]; then
            local diff=$((tt_epoch - t0_epoch))
            echo "  t0=${t0_epoch} timeout=${tt_epoch} diff=${diff}s"
            if [ "$diff" -ge 8 ] && [ "$diff" -le 12 ]; then
                assert "TC06-2: 타임아웃 로그 발생 시각이 t0+10±2초" "PASS"
            else
                assert "TC06-2: 타임아웃 로그 발생 시각이 t0+10±2초" "FAIL" "diff=${diff}s"
            fi
        else
            assert "TC06-2: 타임아웃 로그 발생 시각이 t0+10±2초" "FAIL" "date -d 파싱 실패 — evidence 로그(t0/timeout 라인) 수동 비교 필요"
        fi
    else
        assert "TC06-2: 타임아웃 로그 발생 시각이 t0+10±2초" "FAIL" "t0 또는 timeout 로그 미확인"
    fi

    wait "$led_pid"
    local led_payload
    led_payload=$(cat "$led_file" 2>/dev/null)
    rm -f "$led_file"
    echo "  set_led_control payload: ${led_payload:-<없음>}"
    if echo "$led_payload" | grep -q '"color"[[:space:]]*:[[:space:]]*"255 0 0"'; then
        assert "TC06-3: 적색 LED 요청 발행" "PASS"
    else
        assert "TC06-3: 적색 LED 요청 발행" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'reboot_conatiner'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "reboot_conatiner"; then
        assert "TC06-4: 컨테이너 재시작 트리거" "PASS"
    else
        assert "TC06-4: 컨테이너 재시작 트리거" "FAIL"
    fi

    echo "  [CLEANUP] 원복..."
    dump_cmd rm -f "$DEVAPP_BIN_DIR/db_manager"
    dump_cmd docker stop "$CONTAINER"
    echo "  [대기] 원복 후 정상 재부팅(최대 90초) 확인..."
    if wait_all_apps_ready 90; then
        assert "TC06-5(cleanup 검증): 원복 후 정상 재부팅" "PASS"
    else
        assert "TC06-5(cleanup 검증): 원복 후 정상 재부팅" "FAIL" "cleanup 후에도 is_ready=true 미확인 — 수동 점검 필요"
    fi
}

# ============================================================
# TC07: Heartbeat 수신 시 Watchdog 리스트 갱신 로그 (Debug 로그 레벨 필요)
#   Flag: 원본 문구 "handler_noti_watchdog From: app_name" 는 현재 소스에 없음.
#   실제 로그 "WatchDog Update APP: <app_id>" (watchdog.cpp:132, DEBUG) 기준.
# ============================================================
tc07_heartbeat_watchdog_log() {
    echo "=== TC07: Heartbeat 수신 시 Watchdog 리스트 갱신 로그 (Debug 로그 레벨 필요) ==="
    echo "  [Flag] 실제 로그 문구 'WatchDog Update APP: <app_id>' 기준으로 검증 (tc_edge_runtime.md 참고)"

    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "emsp/db_manager/${SOURCE}/req/update_records" \
        -m '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_er","value":"0","type":1}]}'

    local since
    since=$(now_ts)
    poll_journal_grep "Log level changed: 0" "$since" 15 2
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'Log level changed: 0'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "Log level changed: 0"; then
        assert "TC07-1: Debug 레벨 전환 확인" "PASS"
    else
        assert "TC07-1: Debug 레벨 전환 확인" "FAIL"
    fi

    echo "  [대기] 60초 이상 대기하며 WatchDog Update APP 로그 수집..."
    sleep 60

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'WatchDog Update APP:'"
    local wd_log names name all_found=1
    wd_log=$(journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -F "WatchDog Update APP:")
    names=$(jq -r '.applications[].name' "$UNIEP_APPLIST" 2>/dev/null)
    for name in $names; do
        echo "$wd_log" | grep -qF "WatchDog Update APP: $name" || { all_found=0; echo "  [MISSING] WatchDog Update APP: $name 없음"; }
    done
    if [ "$all_found" -eq 1 ]; then
        assert "TC07-2: 앱별 Watchdog 갱신 로그 존재" "PASS"
    else
        assert "TC07-2: 앱별 Watchdog 갱신 로그 존재" "FAIL"
    fi

    echo "  [CLEANUP] log_level_er 원복(1=Info)..."
    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "emsp/db_manager/${SOURCE}/req/update_records" \
        -m '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_er","value":"1","type":1}]}'
    poll_journal_grep "Log level changed: 1" "$since" 15 2
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'Log level changed: 1'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "Log level changed: 1"; then
        assert "TC07-3: 로그 레벨 원복" "PASS"
    else
        assert "TC07-3: 로그 레벨 원복" "FAIL"
    fi
}

# ============================================================
# TC08: Heartbeat 9초 미수신(Application Crash 포함) 시 Watchdog 재부팅
#       (파괴적, kill -9)
# ============================================================
tc08_heartbeat_timeout_crash() {
    echo "=== TC08: Heartbeat 9초 미수신(Crash 포함) 시 Watchdog 재부팅 (파괴적, kill -9) ==="

    dump_cmd sh -c "ps -ef | grep energy_dispatcher | grep -v grep"
    local pid
    pid=$(ps -ef 2>/dev/null | grep energy_dispatcher | grep -v grep | awk '{print $2}' | head -1)
    if [ -z "$pid" ]; then
        echo "  [ERROR] energy_dispatcher PID 확인 실패"
        assert "TC08-1: 9~15초 내 타임아웃 감지" "FAIL" "대상 프로세스 없음"
        assert "TC08-2: watchdog 사유 재부팅 로그" "FAIL"
        assert "TC08-3: reboot_info.txt 기록" "FAIL"
        assert "TC08-4: 재기동 후 정상 복귀" "FAIL"
        return
    fi

    local since
    since=$(now_ts)
    dump_cmd kill -9 "$pid"

    echo "  [대기] 9~15초 내 heartbeat 타임아웃 감지 대기(최대 20초)..."
    poll_journal_grep "did not send heartbeat" "$since" 20 2
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'did not send heartbeat'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "did not send heartbeat"; then
        assert "TC08-1: 9~15초 내 타임아웃 감지" "PASS"
    else
        assert "TC08-1: 9~15초 내 타임아웃 감지" "FAIL"
    fi

    poll_journal_grep '"reason":"watchdog"' "$since" 20 2
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F '\"reason\":\"watchdog\"'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF '"reason":"watchdog"'; then
        assert "TC08-2: watchdog 사유 재부팅 로그" "PASS"
    else
        assert "TC08-2: watchdog 사유 재부팅 로그" "FAIL"
    fi

    dump_cmd tail -n 5 "$REBOOT_INFO_FILE"
    if tail -n 5 "$REBOOT_INFO_FILE" 2>/dev/null | grep -qF "watchdog"; then
        assert "TC08-3: reboot_info.txt 기록" "PASS"
    else
        assert "TC08-3: reboot_info.txt 기록" "FAIL"
    fi

    echo "  [대기] 컨테이너 재기동 후 정상 복귀(최대 90초) 확인..."
    if wait_all_apps_ready 90; then
        assert "TC08-4: 재기동 후 정상 복귀" "PASS"
    else
        assert "TC08-4: 재기동 후 정상 복귀" "FAIL"
    fi
}

# ============================================================
# TC09: 최초 Watchdog 점검(부팅 후 60초 시점) 관리 앱 총계 로그
#       (파괴적, TC04와 캡처 세션 공유 가능)
#   Flag: 이 카운트 로그는 first_boot_ 분기 안에서 부팅 후 1회만 출력됨.
# ============================================================
tc09_first_boot_watchdog_count() {
    echo "=== TC09: 최초 Watchdog 점검 관리 앱 총계 로그 (파괴적) ==="
    echo "  [사전조건] /edge/devapp/bin/ 에 변조된 파일이 없는 정상 상태 (TC05/06 cleanup 확인 후 진행)"

    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "emsp/db_manager/${SOURCE}/req/update_records" \
        -m '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_er","value":"0","type":1}]}'
    sleep 2

    local since
    since=$(now_ts)
    dump_cmd docker stop "$CONTAINER"

    echo "  [대기] db_manager fork(t0) + t0+70초까지 카운트 로그 대기(최대 90초)..."
    poll_journal_grep "total_app_size = " "$since" 90 3

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'total_app_size = '"
    local count_log count_occurrences
    count_log=$(journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -F "total_app_size = ")
    count_occurrences=$(echo "$count_log" | grep -cF "total_app_size = ")
    if [ "$count_occurrences" -eq 1 ] 2>/dev/null; then
        assert "TC09-1: 카운트 로그 1회 출현" "PASS"
    else
        assert "TC09-1: 카운트 로그 1회 출현" "FAIL" "발생 횟수: ${count_occurrences:-0}"
    fi

    local n m k
    n=$(echo "$count_log" | head -1 | sed -n 's/.*total_app_size = \([0-9]*\).*/\1/p')
    m=$(echo "$count_log" | head -1 | sed -n 's/.*uniep_application_size = \([0-9]*\).*/\1/p')
    k=$(echo "$count_log" | head -1 | sed -n 's/.*other_application_size = \([0-9]*\).*/\1/p')
    echo "  N(total)=$n M(uniep)=$m K(other)=$k"
    if [ -n "$n" ] && [ -n "$m" ] && [ -n "$k" ] && [ "$n" -eq $((m + k)) ] 2>/dev/null; then
        assert "TC09-2: 카운트 일치 (N == M+K)" "PASS"
    else
        assert "TC09-2: 카운트 일치 (N == M+K)" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'Some app did not be executed'"
    if journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -qF "Some app did not be executed"; then
        assert "TC09-3: 정상 통과(재부팅 없음)" "FAIL" "'Some app did not be executed' 로그 발견됨"
    else
        assert "TC09-3: 정상 통과(재부팅 없음)" "PASS"
    fi

    echo "  [대기] 재기동 완료 확인(최대 90초)..."
    wait_all_apps_ready 90 >/dev/null

    echo "  [CLEANUP] log_level_er 원복(1=Info)..."
    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "emsp/db_manager/${SOURCE}/req/update_records" \
        -m '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_er","value":"1","type":1}]}'
}

# ============================================================
# TC10: uniep_applist.conf 파일 형식 검증 (비파괴적)
# ============================================================
tc10_uniep_applist_format() {
    echo "=== TC10: uniep_applist.conf 파일 형식 검증 (비파괴적) ==="

    dump_cmd jq -e . "$UNIEP_APPLIST"
    if jq -e . "$UNIEP_APPLIST" >/dev/null 2>&1; then
        assert "TC10-1: JSON 파싱 성공" "PASS"
    else
        assert "TC10-1: JSON 파싱 성공" "FAIL"
    fi

    dump_cmd sh -c "jq -e '.applications[] | select(.name==\"edge_runtime\") | .order==1' '$UNIEP_APPLIST'"
    if jq -e '.applications[] | select(.name=="edge_runtime") | .order==1' "$UNIEP_APPLIST" >/dev/null 2>&1; then
        assert "TC10-2: edge_runtime order=1" "PASS"
    else
        assert "TC10-2: edge_runtime order=1" "FAIL"
    fi

    dump_cmd sh -c "jq -e '.applications[] | select(.name==\"db_manager\") | .order==2' '$UNIEP_APPLIST'"
    if jq -e '.applications[] | select(.name=="db_manager") | .order==2' "$UNIEP_APPLIST" >/dev/null 2>&1; then
        assert "TC10-3: db_manager order=2" "PASS"
    else
        assert "TC10-3: db_manager order=2" "FAIL"
    fi
}

# ============================================================
# TC11: devapp 오버라이드로 Application 실행 순서 변경
#       (파괴적, conf 변경 + 컨테이너 재시작)
# ============================================================
tc11_devapp_order_override() {
    echo "=== TC11: devapp 오버라이드로 Application 실행 순서 변경 (파괴적) ==="
    echo "  [경고] 시험 후 반드시 원본 uniep_applist.conf로 원복 필요"

    local backup="/tmp/uniep_applist.conf.bak.$$"
    dump_cmd cp "$UNIEP_APPLIST" "$backup"
    dump_cmd mkdir -p "$DEVAPP_FILES_DIR"

    # order 3 이상인 두 앱을 골라 order를 서로 교환 (1/2 는 건드리지 않음)
    local swap_json
    swap_json=$(jq '
        (.applications | map(select(.order >= 3)) | sort_by(.order))[0:2] as $two |
        if ($two | length) == 2 then
            ($two[0].name) as $n0 | ($two[0].order) as $o0 |
            ($two[1].name) as $n1 | ($two[1].order) as $o1 |
            .applications |= map(
                if .name == $n0 then .order = $o1
                elif .name == $n1 then .order = $o0
                else . end
            )
        else . end
    ' "$backup")
    echo "$swap_json" > "$DEVAPP_FILES_DIR/uniep_applist.conf"
    dump_cmd cat "$DEVAPP_FILES_DIR/uniep_applist.conf"

    local since
    since=$(now_ts)
    dump_cmd docker stop "$CONTAINER"

    echo "  [대기] 재기동 완료(최대 90초) 대기..."
    wait_all_apps_ready 90 >/dev/null

    dump_cmd diff "$DEVAPP_FILES_DIR/uniep_applist.conf" "$UNIEP_APPLIST"
    if diff -q "$DEVAPP_FILES_DIR/uniep_applist.conf" "$UNIEP_APPLIST" >/dev/null 2>&1; then
        assert "TC11-1: devapp conf가 app 경로로 복사됨" "PASS"
    else
        assert "TC11-1: devapp conf가 app 경로로 복사됨" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since}' | grep -F 'Spawn App:'"
    local spawn_log conf_pairs prev_order=0 order_ok=1 sp_name sp_order
    spawn_log=$(journalctl -u docker-loader --no-pager --since "$since" 2>/dev/null | grep -F "Spawn App:")
    conf_pairs=$(jq -r '.applications[] | "\(.name) \(.order)"' "$UNIEP_APPLIST" 2>/dev/null)
    for sp_name in $(echo "$spawn_log" | sed 's/.*Spawn App: //' | awk '{print $1}'); do
        sp_order=$(echo "$conf_pairs" | awk -v n="$sp_name" '$1==n{print $2}')
        [ -z "$sp_order" ] && continue
        if [ "$sp_order" -lt "$prev_order" ] 2>/dev/null; then
            order_ok=0
        fi
        prev_order="$sp_order"
    done
    if [ "$order_ok" -eq 1 ]; then
        assert "TC11-2: 변경된 order대로 Ready(fork) 순서 관찰" "PASS"
    else
        assert "TC11-2: 변경된 order대로 Ready(fork) 순서 관찰" "FAIL"
    fi

    echo "  [CLEANUP] 원복..."
    dump_cmd cp "$backup" "$DEVAPP_FILES_DIR/uniep_applist.conf"
    local since2
    since2=$(now_ts)
    dump_cmd docker stop "$CONTAINER"
    echo "  [대기] 원복 후 기본 순서 복귀 확인(최대 90초)..."
    wait_all_apps_ready 90 >/dev/null
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '${since2}' | grep -F 'Spawn App:' | head -1"
    local first_after_restore
    first_after_restore=$(journalctl -u docker-loader --no-pager --since "$since2" 2>/dev/null | grep -F "Spawn App:" | head -1)
    if echo "$first_after_restore" | grep -qF "db_manager"; then
        assert "TC11-3(cleanup 검증): 원복 후 기본 순서 복귀" "PASS"
    else
        assert "TC11-3(cleanup 검증): 원복 후 기본 순서 복귀" "FAIL" "첫 fork: ${first_after_restore:-<없음>}"
    fi
    rm -f "$backup"
}

# ============================================================
# TC12: 실행 중인 필수 Application 프로세스 목록 확인 (비파괴적)
# ============================================================
tc12_running_process_check() {
    echo "=== TC12: 실행 중인 필수 Application 프로세스 목록 확인 (비파괴적) ==="

    dump_cmd sh -c "ps -ef | grep -E 'edge_runtime|db_manager|azure_connector|energy_link|energy_monitor|sys_manager|update_monitor|device_manager|energy_dispatcher' | grep -v grep"

    local names name all_found=1
    names=$(jq -r '.applications[].name' "$UNIEP_APPLIST" 2>/dev/null)
    for name in $names; do
        if ! ps -ef 2>/dev/null | grep -qF "/edge/app/bin/$name"; then
            echo "  [MISSING] /edge/app/bin/$name 프로세스 없음"
            all_found=0
        fi
    done
    if [ "$all_found" -eq 1 ]; then
        assert "TC12-1: 필수 앱 전체 프로세스 존재" "PASS"
    else
        assert "TC12-1: 필수 앱 전체 프로세스 존재" "FAIL"
    fi

    dump_cmd sh -c "ps -ef | grep -E 'node .*(www|server_hmi)\.js' | grep -v grep"
    local node_count
    node_count=$(ps -ef 2>/dev/null | grep -E "node .*(www|server_hmi)\.js" | grep -v grep | wc -l)
    if [ "$node_count" -eq 3 ] 2>/dev/null; then
        assert "TC12-2: Node.js 3개 프로세스 존재" "PASS"
    else
        assert "TC12-2: Node.js 3개 프로세스 존재" "FAIL" "관찰된 프로세스 수: $node_count"
    fi
}

# ============================================================
# TC13: Configuration 기반 Project(non-uniep) Application 실행
#   TODO — DUT에 실제 project conf 파일이 없어 대상 미확정 (tc_edge_runtime.md 참고)
# ============================================================
tc13_project_app() {
    echo "=== TC13: SKIP (개발자 검토 대기 — tc_edge_runtime.md 참고) ==="
}

# ============================================================
# TC14: 자동화 불가 항목 목록 (참고용 — PASS/FAIL 집계 제외)
# ============================================================
tc14_manual_items() {
    echo "=== TC14: 자동화 불가 항목 목록 (참고용, PASS/FAIL 집계 제외) ==="
    echo "  - Key178 (TC-2) LED 상태 확인: 녹색/적색 LED 육안 확인 (TC04-4/TC05-3으로 일부 대체)"
    echo "  - Key185 (TC-6) 1번째 스텝: Configuration 기반 Project Application 정상 fork (TC13 참고)"
    echo "  - Key186 (TC-7) 1~2번째 스텝: journalctl -f 로그 출력 시작 / docker ps 컨테이너 ID 확인 (각 파괴적 TC의 setup으로 흡수)"
    echo "  자동화 불가 항목은 QA가 docs/tc_requirements/edge_runtime.md 원본 절차로 수동 실행할 것"
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " edge_runtime TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01) tc01_reboot_app_shutdown ;;
    --tc02) tc02_reboot_info_file ;;
    --tc03) tc03_boot_order ;;
    --tc04) tc04_all_ready_led_green ;;
    --tc05) tc05_boot_watchdog_60s ;;
    --tc06) tc06_db_manager_10s_timeout ;;
    --tc07) tc07_heartbeat_watchdog_log ;;
    --tc08) tc08_heartbeat_timeout_crash ;;
    --tc09) tc09_first_boot_watchdog_count ;;
    --tc10) tc10_uniep_applist_format ;;
    --tc11) tc11_devapp_order_override ;;
    --tc12) tc12_running_process_check ;;
    --tc13) tc13_project_app ;;
    --tc14) tc14_manual_items ;;
    --only)
        # 대시보드의 "선택 실행"에서 사용 — 콤마로 구분된 TC 목록을 받아 그 TC들만 실행한다.
        # 예: sh tc_edge_runtime.sh --only TC01,TC08,TC09
        shift
        SELECTED="${1:-}"
        if [ -z "$SELECTED" ]; then
            echo "[ERROR] --only 뒤에 TC 목록이 필요합니다 (예: --only TC01,TC08,TC09)"
            exit 1
        fi
        for tc in TC01 TC02 TC03 TC04 TC05 TC06 TC07 TC08 TC09 TC10 TC11 TC12 TC13 TC14; do
            case ",${SELECTED}," in
                *,${tc},*)
                    case "$tc" in
                        TC01) tc01_reboot_app_shutdown ;;
                        TC02) tc02_reboot_info_file ;;
                        TC03) tc03_boot_order ;;
                        TC04) tc04_all_ready_led_green ;;
                        TC05) tc05_boot_watchdog_60s ;;
                        TC06) tc06_db_manager_10s_timeout ;;
                        TC07) tc07_heartbeat_watchdog_log ;;
                        TC08) tc08_heartbeat_timeout_crash ;;
                        TC09) tc09_first_boot_watchdog_count ;;
                        TC10) tc10_uniep_applist_format ;;
                        TC11) tc11_devapp_order_override ;;
                        TC12) tc12_running_process_check ;;
                        TC13) tc13_project_app ;;
                        TC14) tc14_manual_items ;;
                    esac
                    ;;
            esac
        done
        ;;
    *)
        tc01_reboot_app_shutdown
        tc02_reboot_info_file
        tc03_boot_order
        tc04_all_ready_led_green
        tc05_boot_watchdog_60s
        tc06_db_manager_10s_timeout
        tc07_heartbeat_watchdog_log
        tc08_heartbeat_timeout_crash
        tc09_first_boot_watchdog_count
        tc10_uniep_applist_format
        tc11_devapp_order_override
        tc12_running_process_check
        tc13_project_app
        tc14_manual_items
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
