#!/bin/bash
# TC: device_manager
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}
# 참고: request_factory_reset / get_configuration_json / get_register_map_json 은
#       db_manager 소관 서비스이므로 send_and_wait_db() 로 TARGET을 db_manager로
#       임시 전환해 호출한다 (get_protocol_list 등 device_manager 서비스는 기본
#       TARGET 그대로 send_and_wait() 사용).

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="device_manager"
CONFIG_JSON_PATH="/edge/app/files/commonfile/configuration.json"
REGISTER_MAP_JSON_PATH="/edge/app/files/commonfile/register_map.json"
TC01_SAVE="/tmp/tc_device_manager_tc01_state"
TC02_SAVE="/tmp/tc_device_manager_tc02_state"
TC03_SAVE="/tmp/tc_device_manager_tc03_state"
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

# request_factory_reset / get_configuration_json / get_register_map_json 은
# db_manager 소관 서비스라, 전역 TARGET을 잠시 db_manager로 바꿔 send_and_wait()를
# 그대로 재사용한다.
send_and_wait_db() {
    local service="$1"
    local payload="$2"
    local timeout="$3"
    local orig_target="$TARGET"
    TARGET="db_manager"
    local resp
    resp=$(send_and_wait "$service" "$payload" "$timeout")
    TARGET="$orig_target"
    echo "$resp"
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
# TC01-PRE: configuration.json 에 신규 device 추가 + factory_reset + reboot
# [주의] 실행 후 reboot 발생 → SSH 접속 끊김. 재접속 후 --tc01-post 실행
# ============================================================
tc01_pre() {
    echo "=== TC01-PRE: configuration.json 신규 Protocol 추가 준비 ==="
    echo "  사전조건: ${CONFIG_JSON_PATH} 백업, 신규 rid 미중복 확인"

    dump_cmd cp "$CONFIG_JSON_PATH" "${CONFIG_JSON_PATH}.tc01.bak"

    local new_rid new_config
    new_rid="tc01_test_device_$$"
    dump_cmd jq -e '.deviceList | length > 0' "$CONFIG_JSON_PATH"

    new_config=$(jq --arg rid "$new_rid" '.deviceList += [(.deviceList[0] | .rid = $rid)]' "$CONFIG_JSON_PATH" 2>/dev/null)
    if [ -n "$new_config" ]; then
        echo "$new_config" > "$CONFIG_JSON_PATH"
        echo "  신규 device rid=$new_rid 추가 완료 (소스 코드 미수정)"
    else
        echo "  [ERROR] deviceList 복제 실패 (jq)"
    fi

    local t0
    t0=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s\n%s\n' "$t0" "$new_rid" > "$TC01_SAVE"
    echo "  T0=$t0 NEW_RID=$new_rid 저장 (${TC01_SAVE})"

    local reset_resp
    reset_resp=$(send_and_wait_db "request_factory_reset" "{}" 30)
    dump_cmd echo "$reset_resp"
    if [ -n "$reset_resp" ]; then
        assert "TC01-1: factory_reset 응답 수신" "PASS"
    else
        assert "TC01-1: factory_reset 응답 수신" "FAIL" "timeout"
    fi

    echo ""
    echo "============================================"
    echo " 결과(pre): PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
    echo ""
    echo "[TC01-PRE 완료] reboot 실행 중... 재접속 후 --tc01-post 실행"
    sync
    reboot
}

# ============================================================
# TC01-POST: 재부팅 후 연결 시도 / get_protocol_list 확인 + teardown reboot
# ============================================================
tc01_post() {
    echo "=== TC01-POST: 재부팅 후 연결 시도 / protocol_list 확인 ==="
    if [ ! -f "$TC01_SAVE" ]; then
        echo "[ERROR] ${TC01_SAVE} 없음 - --tc01-pre 를 먼저 실행하세요"
        return
    fi

    local t0 new_rid
    t0=$(sed -n '1p' "$TC01_SAVE")
    new_rid=$(sed -n '2p' "$TC01_SAVE")
    echo "  T0=$t0 NEW_RID=$new_rid"

    dump_cmd journalctl -u docker-loader --since "$t0"
    local journal_since
    journal_since=$(journalctl -u docker-loader --no-pager -o cat --since "$t0" 2>/dev/null)

    if echo "$journal_since" | grep -q '\[DM\].*Site data ready'; then
        assert "TC01-2: site data ready 로그 존재" "PASS"
    else
        assert "TC01-2: site data ready 로그 존재" "FAIL"
    fi

    if echo "$journal_since" | grep 'device_connection received:' | grep -q "$new_rid"; then
        assert "TC01-3: 신규 protocol_rid 연결 알림 수신" "PASS"
    else
        assert "TC01-3: 신규 protocol_rid 연결 알림 수신" "FAIL"
    fi

    local resp
    resp=$(send_and_wait "get_protocol_list" "{}" 30)
    dump_cmd echo "$resp"
    if echo "$resp" | jq -e --arg rid "$new_rid" '.payload.protocols[] | select(.rid==$rid)' >/dev/null 2>&1; then
        assert "TC01-4: get_protocol_list 응답에 신규 protocol 포함" "PASS"
    else
        assert "TC01-4: get_protocol_list 응답에 신규 protocol 포함" "FAIL"
    fi

    if [ -f "${CONFIG_JSON_PATH}.tc01.bak" ]; then
        dump_cmd cp "${CONFIG_JSON_PATH}.tc01.bak" "$CONFIG_JSON_PATH"
        rm -f "${CONFIG_JSON_PATH}.tc01.bak"
    fi
    rm -f "$TC01_SAVE"

    echo ""
    echo "============================================"
    echo " TC01 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
    echo ""
    echo "[TC01-POST 완료] teardown reboot 실행 중..."
    sync
    reboot
}

# ============================================================
# TC02-PRE: configuration.json 은닉 + factory_reset + reboot
# [주의] 실행 후 reboot 발생 → SSH 접속 끊김. 재접속 후 --tc02-post 실행
# ============================================================
tc02_pre() {
    echo "=== TC02-PRE: configuration.json 부재 상태 준비 ==="
    echo "  사전조건: request_factory_reset 후 configuration.json 은닉 (DB caching 스킵 방지)"

    local reset_resp
    reset_resp=$(send_and_wait_db "request_factory_reset" "{}" 30)
    dump_cmd echo "$reset_resp"

    dump_cmd cp "$CONFIG_JSON_PATH" "${CONFIG_JSON_PATH}.tc02.bak"
    dump_cmd mv "$CONFIG_JSON_PATH" "${CONFIG_JSON_PATH}.hidden"

    local t0
    t0=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$t0" > "$TC02_SAVE"
    echo "  T0=$t0 저장 (${TC02_SAVE})"

    echo ""
    echo "[TC02-PRE 완료] reboot 실행 중... 재접속 후 --tc02-post 실행"
    sync
    reboot
}

# ============================================================
# TC02-POST: 파일 부재 부팅 동작 검증 + teardown reboot
# ============================================================
tc02_post() {
    echo "=== TC02-POST: 파일 부재 부팅 동작 검증 ==="
    if [ ! -f "$TC02_SAVE" ]; then
        echo "[ERROR] ${TC02_SAVE} 없음 - --tc02-pre 를 먼저 실행하세요"
        return
    fi

    local t0
    t0=$(cat "$TC02_SAVE")
    echo "  T0=$t0"

    dump_cmd journalctl -u docker-loader --since "$t0"
    local journal_since
    journal_since=$(journalctl -u docker-loader --no-pager -o cat --since "$t0" 2>/dev/null)

    if echo "$journal_since" | grep -q '\[DB\].*Failed to open configuration file'; then
        assert "TC02-1: db_manager 파일 오픈 실패 로그 존재" "PASS"
    else
        assert "TC02-1: db_manager 파일 오픈 실패 로그 존재" "FAIL"
    fi

    if echo "$journal_since" | grep -q '\[DM\].*Site data ready'; then
        assert "TC02-2: device_manager site data ready 로그 부재" "FAIL"
    else
        assert "TC02-2: device_manager site data ready 로그 부재" "PASS"
    fi

    if [ -f "${CONFIG_JSON_PATH}.hidden" ]; then
        dump_cmd mv "${CONFIG_JSON_PATH}.hidden" "$CONFIG_JSON_PATH"
    fi
    rm -f "${CONFIG_JSON_PATH}.tc02.bak"

    local reset_resp
    reset_resp=$(send_and_wait_db "request_factory_reset" "{}" 30)
    dump_cmd echo "$reset_resp"

    rm -f "$TC02_SAVE"

    echo ""
    echo "============================================"
    echo " TC02 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
    echo ""
    echo "[TC02-POST 완료] teardown reboot 실행 중..."
    sync
    reboot
}

# ============================================================
# TC03-PRE: 정상 configuration.json/register_map.json 상태로 reboot 준비
# [주의] TC02 teardown으로 정상 파일이 복원된 이후 실행할 것
# ============================================================
tc03_pre() {
    echo "=== TC03-PRE: 정상 파일 상태로 reboot 준비 ==="
    echo "  사전조건: TC02 teardown으로 configuration.json/register_map.json 정상 복원 완료"

    dump_cmd ls -la "$CONFIG_JSON_PATH" "$REGISTER_MAP_JSON_PATH"
    dump_cmd jq -e . "$CONFIG_JSON_PATH"
    dump_cmd jq -e . "$REGISTER_MAP_JSON_PATH"

    local t0
    t0=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$t0" > "$TC03_SAVE"
    echo "  T0=$t0 저장 (${TC03_SAVE})"

    echo ""
    echo "[TC03-PRE 완료] reboot 실행 중... 재접속 후 --tc03-post 실행"
    sync
    reboot
}

# ============================================================
# TC03-POST: 정상 로드 확인 (TC02 대조군)
# ============================================================
tc03_post() {
    echo "=== TC03-POST: configuration.json / register_map.json 정상 로드 확인 ==="
    if [ ! -f "$TC03_SAVE" ]; then
        echo "[ERROR] ${TC03_SAVE} 없음 - --tc03-pre 를 먼저 실행하세요"
        return
    fi

    local t0
    t0=$(cat "$TC03_SAVE")
    echo "  T0=$t0"

    dump_cmd journalctl -u docker-loader --since "$t0"
    local journal_since
    journal_since=$(journalctl -u docker-loader --no-pager -o cat --since "$t0" 2>/dev/null)

    if echo "$journal_since" | grep -q '\[DM\].*Site data ready'; then
        assert "TC03-1: site data ready 로그 존재" "PASS"
    else
        assert "TC03-1: site data ready 로그 존재" "FAIL"
    fi

    local config_resp
    config_resp=$(send_and_wait_db "get_configuration_json" "{}" 30)
    dump_cmd echo "$config_resp"
    if echo "$config_resp" | jq -e '.payload | length > 0' >/dev/null 2>&1; then
        assert "TC03-2: configuration 응답 비어있지 않음" "PASS"
    else
        assert "TC03-2: configuration 응답 비어있지 않음" "FAIL"
    fi

    local regmap_resp
    regmap_resp=$(send_and_wait_db "get_register_map_json" "{}" 30)
    dump_cmd echo "$regmap_resp"
    if echo "$regmap_resp" | jq -e '.payload | length > 0' >/dev/null 2>&1; then
        assert "TC03-3: register_map 응답 비어있지 않음" "PASS"
    else
        assert "TC03-3: register_map 응답 비어있지 않음" "FAIL"
    fi

    rm -f "$TC03_SAVE"

    echo ""
    echo "============================================"
    echo " TC03 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
}

# ============================================================
# TC04: 주기적 Read Data 처리 (하드웨어 의존, grade B)
# 판정 1차 근거는 device_manager 관점의 device_cycle_data 알림 간격.
# ============================================================
tc04_periodic_read() {
    echo "=== TC04: 주기적 Read Data 처리 확인 ==="
    echo "  사전조건: register_map.json 에 operation:read + periodMs RegisterGroup 존재, 물리 디바이스 연결 필요"

    dump_cmd jq '.. | objects | select(.operation? and (.operation | index("read"))) | {id, operation, periodMs}' "$REGISTER_MAP_JSON_PATH"

    local period_ms
    period_ms=$(jq -r '[.. | objects | select(.operation? and (.operation | index("read"))) | .periodMs] | first' "$REGISTER_MAP_JSON_PATH" 2>/dev/null)

    if [ -z "$period_ms" ] || [ "$period_ms" = "null" ]; then
        echo "  [WARN] operation:read + periodMs RegisterGroup 없음 - 하드웨어/사전조건 미충족, TC04 스킵"
        return
    fi
    echo "  대상 periodMs=$period_ms"

    local t0 capture_file
    t0=$(date '+%Y-%m-%d %H:%M:%S')
    capture_file="/tmp/tc04_capture_$$.log"
    : > "$capture_file"

    echo "  device_cycle_data 알림 30초간 캡처 중..."
    timeout 30 mosquitto_sub -h "$MQTT_HOST" -v -t 'emsp/+/+/noti/device_cycle_data' 2>/dev/null | \
    while IFS= read -r line; do
        echo "$(date +%s) $line" >> "$capture_file"
    done

    dump_cmd cat "$capture_file"

    local msg_count avg_interval_ms
    msg_count=$(wc -l < "$capture_file" | awk '{print $1}')
    avg_interval_ms=$(awk '{a[NR]=$1} END{if(NR<2){print 0; exit} sum=0; for(i=2;i<=NR;i++){sum+=(a[i]-a[i-1])}; printf "%.0f", (sum/(NR-1))*1000}' "$capture_file")
    echo "  msg_count=$msg_count avg_interval_ms=$avg_interval_ms"

    if [ "$msg_count" -ge 2 ]; then
        assert "TC04-1: device_cycle_data 알림 2회 이상 수신" "PASS"
    else
        assert "TC04-1: device_cycle_data 알림 2회 이상 수신" "FAIL"
    fi

    if awk -v p="$period_ms" -v avg="$avg_interval_ms" 'BEGIN{d=(avg>p?avg-p:p-avg); exit !(d <= p*0.2)}'; then
        assert "TC04-2: 평균 수신 간격이 periodMs ±20% 이내" "PASS"
    else
        assert "TC04-2: 평균 수신 간격이 periodMs ±20% 이내" "FAIL"
    fi

    dump_cmd journalctl -u docker-loader --since "$t0"
    local journal_since
    journal_since=$(journalctl -u docker-loader --no-pager -o cat --since "$t0" 2>/dev/null)
    if echo "$journal_since" | grep '\[EL\]' | grep -q 'Failed to read'; then
        assert "TC04-3: Read 에러 로그 없음" "FAIL"
    else
        assert "TC04-3: Read 에러 로그 없음" "PASS"
    fi

    rm -f "$capture_file"
}

# ============================================================
# TC05: 자동화 불가 항목 (Web HMI 수동 조작 / 개발자 확인 필요)
# ============================================================
tc05_manual_review() {
    echo "=== TC05: SKIP (자동화 불가 — tc_device_manager.md TC05 참고, Web HMI 수동 조작/개발자 확인 필요) ==="
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " device_manager TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01-pre)
        tc01_pre
        ;;
    --tc01-post)
        tc01_post
        ;;
    --tc02-pre)
        tc02_pre
        ;;
    --tc02-post)
        tc02_post
        ;;
    --tc03-pre)
        tc03_pre
        ;;
    --tc03-post)
        tc03_post
        ;;
    --tc04)
        tc04_periodic_read
        ;;
    --tc05)
        tc05_manual_review
        ;;
    *)
        echo "[안내] TC01~TC03은 reboot를 수반해 이 스크립트 안에서 이어갈 수 없음 (SSH 세션 끊김)."
        echo "  ./tc_device_manager.sh --tc01-pre   (configuration.json 수정 + factory_reset + reboot)"
        echo "  ./tc_device_manager.sh --tc01-post  (재접속 후 검증 + teardown reboot)"
        echo "  ./tc_device_manager.sh --tc02-pre   (configuration.json 은닉 + factory_reset + reboot)"
        echo "  ./tc_device_manager.sh --tc02-post  (재접속 후 검증 + teardown reboot)"
        echo "  ./tc_device_manager.sh --tc03-pre   (정상 파일 상태 확인 + reboot, TC02 teardown 이후 실행)"
        echo "  ./tc_device_manager.sh --tc03-post  (재접속 후 검증)"
        echo ""
        tc04_periodic_read
        tc05_manual_review
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
