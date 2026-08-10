#!/bin/bash
# TC: db_manager
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}
#             emsp/all/{source}/noti/{event}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="db_manager"
DB_PATH="/edge/db/edge_storage.db"
SECURE_DB_PATH="/edge/sp/db/edge_storage.db"
TC06_SAVE="/edge/db/.tc06_before"
PASS=0
FAIL=0

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

# uplink_ready 같은 noti(req/res 왕복이 아닌 일방향 알림)를 보낸다. send_and_wait과
# 달리 응답을 기다리지 않고 발행만 한다 (TC02/TC10의 false->true 전이 시뮬레이션용).
publish_noti() {
    local event="$1"
    local payload="$2"
    [ -z "$payload" ] && payload="{}"
    local tid="tc-$(date +%s)"
    local full_payload
    full_payload=$(printf '{"tid":"%s","payload":%s}' "$tid" "$payload")
    local noti_topic="emsp/all/${SOURCE}/noti/${event}"
    mosquitto_pub -h "$MQTT_HOST" -t "$noti_topic" -m "$full_payload"
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

# select_all_records/select_records 응답 payload는 "db_manager.cpp"의 DbRecordResult
# 구조를 그대로 실어보내지만, msg_ipc 봉투("tid"/"payload" 등)에 얼마나 깊이 nesting
# 되는지는 res topic을 실측하기 전까지 확정할 수 없다. 어느 depth에 있든 "records"
# 배열을 찾아내도록 재귀 탐색한다 (TC01/TC03/TC04/TC06/TC07/TC08 공용).
PY_FIND_RECORDS='
import json, sys

def find_records(o):
    if isinstance(o, dict):
        if isinstance(o.get("records"), list):
            return o["records"]
        for v in o.values():
            r = find_records(v)
            if r is not None:
                return r
    return None
'

# ============================================================
# TC01: Configuration 테이블 생성 및 select_all_records 조회
# ============================================================
tc01_configuration_select_all() {
    echo "=== TC01: Configuration 테이블 생성 및 select_all_records 조회 ==="

    local resp
    resp=$(send_and_wait "select_all_records" '{"db":"edge_storage.db","table":"configuration"}' 10)
    echo "  응답: ${resp:-<empty>}"

    if [ -n "$resp" ]; then
        assert "TC01-1: 응답 수신" "PASS"
    else
        assert "TC01-1: 응답 수신" "FAIL"
        return
    fi

    if echo "$resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*true'; then
        assert "TC01-2: result=true" "PASS"
    else
        assert "TC01-2: result=true" "FAIL"
    fi

    if echo "$resp" | grep -qE '"table"[[:space:]]*:[[:space:]]*"configuration"'; then
        assert "TC01-3: table 필드 일치" "PASS"
    else
        assert "TC01-3: table 필드 일치" "FAIL"
    fi

    if echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d.get('records'), list) else 1)" 2>/dev/null; then
        assert "TC01-4: records 필드가 JSON 배열" "PASS"
    else
        assert "TC01-4: records 필드가 JSON 배열" "FAIL"
    fi
}

# ============================================================
# TC02: Configuration 이력 정보 클라우드 전달 (SyncConfigurationRequest)
# ============================================================
tc02_sync_configuration_cloud() {
    echo "=== TC02: Configuration 이력 정보 클라우드 전달 (SyncConfigurationRequest) ==="
    echo "  [사전조건] sqlite3 강제 insert로 unsynced 레코드 2건(version 0,1) 생성 후 uplink_ready false->true 주입"

    dump_cmd sqlite3 "$DB_PATH" ".schema configuration"

    local json0 json1
    json0='{"version":0,"tc_marker":"tc_db_manager_tc02"}'
    json1='{"version":1,"tc_marker":"tc_db_manager_tc02"}'
    dump_cmd sqlite3 "$DB_PATH" "INSERT INTO configuration (value) VALUES ('${json0}');"
    dump_cmd sqlite3 "$DB_PATH" "INSERT INTO configuration (value) VALUES ('${json1}');"

    local baseline
    baseline=$(date '+%Y-%m-%d %H:%M:%S')
    echo "  baseline=$baseline"

    publish_noti "uplink_ready" '{"ready":false}'
    sleep 1
    publish_noti "uplink_ready" '{"ready":true}'

    echo "  동기화 트리거 대기 (10초)..."
    sleep 10

    dump_cmd journalctl -u docker-loader --since "$baseline"
    local jlog
    jlog=$(journalctl -u docker-loader --since "$baseline" 2>/dev/null)

    if echo "$jlog" | grep -qF "Syncing configuration to IoT Hub"; then
        assert "TC02-1: 동기화 트리거 로그 출현" "PASS"
    else
        assert "TC02-1: 동기화 트리거 로그 출현" "FAIL"
    fi

    local unsynced_count
    unsynced_count=$(echo "$jlog" | grep -oE "Found [0-9]+ unsynced configuration records" | grep -oE "[0-9]+" | tail -1)
    if [ -n "$unsynced_count" ] && [ "$unsynced_count" -ge 2 ] 2>/dev/null; then
        assert "TC02-2: unsynced 레코드 수 >= 2" "PASS"
        echo "    unsynced_count=$unsynced_count"
    else
        assert "TC02-2: unsynced 레코드 수 >= 2" "FAIL"
        echo "    unsynced_count=${unsynced_count:-0}"
    fi

    local sent_count
    sent_count=$(echo "$jlog" | grep -c "Configuration data sent to IoT Hub successfully")
    if [ "$sent_count" -ge 2 ]; then
        assert "TC02-3: D2C 전송 시도 로그 2건 이상" "PASS"
        echo "    sent_count=$sent_count"
    else
        assert "TC02-3: D2C 전송 시도 로그 2건 이상" "FAIL"
        echo "    sent_count=$sent_count"
    fi
}

# ============================================================
# TC03: Persistent State 변경 정보 전달 (update_records 즉시 반영)
# ============================================================
tc03_persistent_state_update_records() {
    echo "=== TC03: Persistent State 변경 정보 전달 (update_records 즉시 반영) ==="

    local all_resp
    all_resp=$(send_and_wait "select_all_records" '{"db":"edge_storage.db","table":"persistent_state"}' 10)
    echo "  select_all_records 응답: ${all_resp:-<empty>}"

    local pick
    pick=$(echo "$all_resp" | python3 -c "
${PY_FIND_RECORDS}
try:
    d = json.load(sys.stdin)
    recs = find_records(d) or []
    if recs:
        rec = recs[0]
        print('%s|%s|%s' % (rec.get('key', ''), rec.get('value', ''), rec.get('type', '')))
except Exception:
    pass
" 2>/dev/null)

    if [ -z "$pick" ]; then
        assert "TC03-0: 대상 키 확보 (select_all_records)" "FAIL" "persistent_state records 파싱 실패: $all_resp"
        return
    fi

    local key orig_value orig_type
    key=$(echo "$pick" | awk -F'|' '{print $1}')
    orig_value=$(echo "$pick" | awk -F'|' '{print $2}')
    orig_type=$(echo "$pick" | awk -F'|' '{print $3}')
    echo "  대상 키=${key}, 원래값=${orig_value}, type=${orig_type}"

    local new_value="tc03_$(date +%s)"
    local update_resp
    update_resp=$(send_and_wait "update_records" "{\"db\":\"edge_storage.db\",\"table\":\"persistent_state\",\"records\":[{\"key\":\"${key}\",\"value\":\"${new_value}\",\"type\":${orig_type}}]}" 10)
    echo "  update_records 응답: ${update_resp:-<empty>}"

    if echo "$update_resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*true'; then
        assert "TC03-1: update_records 응답 result=true" "PASS"
    else
        assert "TC03-1: update_records 응답 result=true" "FAIL"
    fi

    local reselect_resp
    reselect_resp=$(send_and_wait "select_records" "{\"db\":\"edge_storage.db\",\"table\":\"persistent_state\",\"keys\":[\"${key}\"]}" 10)
    echo "  재조회 응답: ${reselect_resp:-<empty>}"

    if echo "$reselect_resp" | grep -qF "\"value\":\"${new_value}\""; then
        assert "TC03-2: 재조회 값이 변경값과 일치" "PASS"
    else
        assert "TC03-2: 재조회 값이 변경값과 일치" "FAIL"
    fi

    # cleanup: 원래 값으로 원복
    send_and_wait "update_records" "{\"db\":\"edge_storage.db\",\"table\":\"persistent_state\",\"records\":[{\"key\":\"${key}\",\"value\":\"${orig_value}\",\"type\":${orig_type}}]}" 10 > /dev/null

    local reverify_resp
    reverify_resp=$(send_and_wait "select_records" "{\"db\":\"edge_storage.db\",\"table\":\"persistent_state\",\"keys\":[\"${key}\"]}" 10)
    echo "  원복 재조회 응답: ${reverify_resp:-<empty>}"

    if echo "$reverify_resp" | grep -qF "\"value\":\"${orig_value}\""; then
        assert "TC03-3: cleanup 원복 성공" "PASS"
    else
        assert "TC03-3: cleanup 원복 성공" "FAIL"
    fi
}

# ============================================================
# TC04: System Setting 변경 정보 즉시 반영 (Log Level)
# ============================================================
tc04_system_setting_log_level() {
    echo "=== TC04: System Setting 변경 정보 즉시 반영 (Log Level) ==="

    local select_resp
    select_resp=$(send_and_wait "select_records" '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_db"]}' 10)
    echo "  select_records 응답: ${select_resp:-<empty>}"

    if ! echo "$select_resp" | grep -qF '"log_level_db"'; then
        echo "  [SKIP] log_level_db 키가 system_setting에 없음 — TC04 스킵"
        return
    fi

    local original_level
    original_level=$(echo "$select_resp" | python3 -c "
${PY_FIND_RECORDS}
try:
    d = json.load(sys.stdin)
    recs = find_records(d) or []
    for rec in recs:
        if rec.get('key') == 'log_level_db':
            print(rec.get('value',''))
            break
except Exception:
    pass
" 2>/dev/null)
    echo "  ORIGINAL_LEVEL=${original_level}"

    local baseline
    baseline=$(date '+%Y-%m-%d %H:%M:%S')

    local update_resp
    update_resp=$(send_and_wait "update_records" '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_db","value":"0","type":1}]}' 10)
    echo "  update_records 응답: ${update_resp:-<empty>}"

    if echo "$update_resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*true'; then
        assert "TC04-1: update_records 응답 result=true" "PASS"
    else
        assert "TC04-1: update_records 응답 result=true" "FAIL"
    fi

    sleep 2
    dump_cmd journalctl -u docker-loader --since "$baseline"
    if journalctl -u docker-loader --since "$baseline" 2>/dev/null | grep -qF "Log level changed via update_records: 0"; then
        assert "TC04-2: 로그 레벨 변경 로그 출현" "PASS"
    else
        assert "TC04-2: 로그 레벨 변경 로그 출현" "FAIL"
    fi

    echo "  [TC04-3] Debug 레벨 로그 관찰 (5초)..."
    if timeout 5 journalctl -u docker-loader -f --since now 2>/dev/null | grep -m1 '\[D\]\[DB\]' > "/tmp/tc04_dlog_$$" 2>&1; then
        assert "TC04-3: Debug 레벨 로그 실제 출력 확인" "PASS"
        dump_cmd cat "/tmp/tc04_dlog_$$"
    else
        assert "TC04-3: Debug 레벨 로그 실제 출력 확인" "FAIL"
    fi
    rm -f "/tmp/tc04_dlog_$$"

    send_and_wait "update_records" "{\"db\":\"edge_storage.db\",\"table\":\"system_setting\",\"records\":[{\"key\":\"log_level_db\",\"value\":\"${original_level}\",\"type\":1}]}" 10 > /dev/null

    local reverify_resp
    reverify_resp=$(send_and_wait "select_records" '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_db"]}' 10)
    echo "  원복 재조회 응답: ${reverify_resp:-<empty>}"
    if echo "$reverify_resp" | grep -qF "\"value\":\"${original_level}\""; then
        assert "TC04-4: cleanup 원복 성공" "PASS"
    else
        assert "TC04-4: cleanup 원복 성공" "FAIL"
    fi
}

# ============================================================
# TC05: Persistent State 부팅 시점 정보 전달 (검토 필요 — 로그 태그 불일치)
# tc_db_manager.md TC05: 원본 로그 태그 [DM]이 코드베이스 어떤 앱과도 일치하지 않아
# 개발자 확인 후 재작성 대기 중 (Flag). 자동화 판정 없이 스킵만 한다.
# ============================================================
tc05_persistent_state_boot() {
    echo "=== TC05: SKIP (개발자 검토 대기 — tc_db_manager.md 참고) ==="
}

# ============================================================
# TC06-PRE: 재부팅 전 log_level_db 변경
# [주의] 실행 후 reboot 발생 → SSH 접속 끊김
#        재접속 후 --tc06-post 실행
# ============================================================
tc06_pre() {
    echo "=== TC06-PRE: 재부팅 전 log_level_db 변경 ==="

    local select_resp
    select_resp=$(send_and_wait "select_records" '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_db"]}' 10)
    echo "  select_records 응답: ${select_resp:-<empty>}"

    local original_level
    original_level=$(echo "$select_resp" | python3 -c "
${PY_FIND_RECORDS}
try:
    d = json.load(sys.stdin)
    recs = find_records(d) or []
    for rec in recs:
        if rec.get('key') == 'log_level_db':
            print(rec.get('value',''))
            break
except Exception:
    pass
" 2>/dev/null)

    if [ -z "$original_level" ]; then
        echo "  [SKIP] log_level_db 값 확인 실패 — TC06 스킵"
        return
    fi
    echo "$original_level" > "$TC06_SAVE"
    echo "  ORIGINAL_LEVEL=${original_level} (${TC06_SAVE}에 저장)"

    local update_resp
    update_resp=$(send_and_wait "update_records" '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_db","value":"0","type":1}]}' 10)
    echo "  update_records 응답: ${update_resp:-<empty>}"

    if echo "$update_resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*true'; then
        assert "TC06-0: 재부팅 전 log_level_db=0 변경 성공" "PASS"
    else
        assert "TC06-0: 재부팅 전 log_level_db=0 변경 성공" "FAIL"
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        return
    fi

    date '+%Y-%m-%d %H:%M:%S' > "${TC06_SAVE}.reboot_ts"

    echo ""
    echo "============================================"
    echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
    echo ""
    echo "[TC06-PRE 완료] reboot 실행 중... 재접속 후 --tc06-post 실행"
    sync
    reboot
}

# ============================================================
# TC06-POST: 재부팅 후 log_level_db 유지 확인
# 재접속 후 실행: ./tc_db_manager.sh --tc06-post
# ============================================================
tc06_post() {
    echo "=== TC06-POST: 재부팅 후 log_level_db 유지 확인 ==="

    if [ ! -f "$TC06_SAVE" ]; then
        echo "[ERROR] ${TC06_SAVE} 없음 - --tc06-pre 를 먼저 실행하세요"
        exit 1
    fi

    local original_level reboot_ts
    original_level=$(cat "$TC06_SAVE")
    reboot_ts=$(cat "${TC06_SAVE}.reboot_ts" 2>/dev/null)
    echo "  ORIGINAL_LEVEL=${original_level}, reboot_ts=${reboot_ts:-N/A}"

    local reselect_resp
    reselect_resp=$(send_and_wait "select_records" '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_db"]}' 10)
    echo "  재부팅 후 select_records 응답: ${reselect_resp:-<empty>}"

    if echo "$reselect_resp" | grep -qF '"value":"0"'; then
        assert "TC06-1: 재부팅 후 DB 값 유지 (log_level_db=0)" "PASS"
    else
        assert "TC06-1: 재부팅 후 DB 값 유지 (log_level_db=0)" "FAIL"
    fi

    if [ -n "$reboot_ts" ]; then
        dump_cmd journalctl -u docker-loader --since "$reboot_ts"
        if journalctl -u docker-loader --since "$reboot_ts" 2>/dev/null | grep -qF "Loaded log_level_db from DB: 0"; then
            assert "TC06-2: 부팅 시 로드 로그 출현" "PASS"
        else
            assert "TC06-2: 부팅 시 로드 로그 출현" "FAIL"
        fi
    else
        assert "TC06-2: 부팅 시 로드 로그 출현" "FAIL" "reboot_ts 기록 없음"
    fi

    send_and_wait "update_records" "{\"db\":\"edge_storage.db\",\"table\":\"system_setting\",\"records\":[{\"key\":\"log_level_db\",\"value\":\"${original_level}\",\"type\":1}]}" 10 > /dev/null
    echo "  cleanup: log_level_db를 ${original_level}로 원복"
    rm -f "$TC06_SAVE" "${TC06_SAVE}.reboot_ts"

    echo ""
    echo "============================================"
    echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
}

# ============================================================
# TC07: Persistent State 테이블 생성/조회 (select_all_records)
# ============================================================
tc07_persistent_state_select_all() {
    echo "=== TC07: Persistent State 테이블 생성/조회 (select_all_records) ==="

    local resp
    resp=$(send_and_wait "select_all_records" '{"db":"edge_storage.db","table":"persistent_state"}' 10)
    echo "  응답: ${resp:-<empty>}"

    if echo "$resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*true'; then
        assert "TC07-1: 응답 result=true" "PASS"
    else
        assert "TC07-1: 응답 result=true" "FAIL"
    fi

    if echo "$resp" | grep -qE '"table"[[:space:]]*:[[:space:]]*"persistent_state"'; then
        assert "TC07-2: table 필드 일치" "PASS"
    else
        assert "TC07-2: table 필드 일치" "FAIL"
    fi

    if echo "$resp" | grep -qF '"persistence_list_sync_flag"'; then
        assert "TC07-3: 기본 시드 키 포함 (persistence_list_sync_flag)" "PASS"
    else
        assert "TC07-3: 기본 시드 키 포함 (persistence_list_sync_flag)" "FAIL"
    fi
}

# ============================================================
# TC08: System Setting 테이블 생성/조회 (select_all_records)
# ============================================================
tc08_system_setting_select_all() {
    echo "=== TC08: System Setting 테이블 생성/조회 (select_all_records) ==="

    local resp
    resp=$(send_and_wait "select_all_records" '{"db":"edge_storage.db","table":"system_setting"}' 10)
    echo "  응답: ${resp:-<empty>}"

    if echo "$resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*true'; then
        assert "TC08-1: 응답 result=true" "PASS"
    else
        assert "TC08-1: 응답 result=true" "FAIL"
    fi

    if echo "$resp" | grep -qE '"table"[[:space:]]*:[[:space:]]*"system_setting"'; then
        assert "TC08-2: table 필드 일치" "PASS"
    else
        assert "TC08-2: table 필드 일치" "FAIL"
    fi

    if echo "$resp" | python3 -c "
${PY_FIND_RECORDS}
try:
    d = json.load(sys.stdin)
    recs = find_records(d) or []
    sys.exit(0 if any(r.get('key') == 'timezone' and r.get('type') == 10 for r in recs) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        assert "TC08-3: timezone 키 포함, type=10" "PASS"
    else
        assert "TC08-3: timezone 키 포함, type=10" "FAIL"
    fi
}

# ============================================================
# TC09: DB 파일 생성/저장 위치 확인
# ============================================================
tc09_db_file_location() {
    echo "=== TC09: DB 파일 생성/저장 위치 확인 ==="

    dump_cmd ls -la "$DB_PATH"
    if [ -f "$DB_PATH" ]; then
        assert "TC09-1: 일반 DB 파일 존재" "PASS"
    else
        assert "TC09-1: 일반 DB 파일 존재" "FAIL"
    fi

    dump_cmd ls -la "$SECURE_DB_PATH"
    if [ -f "$SECURE_DB_PATH" ]; then
        assert "TC09-2: Secure DB 파일 존재" "PASS"
    else
        assert "TC09-2: Secure DB 파일 존재" "FAIL"
    fi

    dump_cmd file "$DB_PATH"
    if file "$DB_PATH" 2>/dev/null | grep -qi "SQLite 3.x database"; then
        assert "TC09-3: SQLite 포맷 확인" "PASS"
    else
        assert "TC09-3: SQLite 포맷 확인" "FAIL"
    fi

    dump_cmd sqlite3 "$DB_PATH" ".tables"
    if sqlite3 "$DB_PATH" ".tables" 2>/dev/null | grep -qE "system_setting|persistent_state|configuration"; then
        assert "TC09-4: 필수 테이블 존재" "PASS"
    else
        assert "TC09-4: 필수 테이블 존재" "FAIL"
    fi
}

# ============================================================
# TC10: Register Map 최신 정보 Cloud Sync (SyncRegisterMapRequest)
# ============================================================
tc10_sync_register_map_cloud() {
    echo "=== TC10: Register Map 최신 정보 Cloud Sync (SyncRegisterMapRequest) ==="
    echo "  [사전조건] sqlite3 강제 insert로 register_map에 미동기화 레코드 생성 후 uplink_ready false->true 주입"

    dump_cmd sqlite3 "$DB_PATH" ".schema register_map"
    dump_cmd sqlite3 "$DB_PATH" "INSERT INTO register_map (value) VALUES ('{\"dummy\":true}');"

    local baseline
    baseline=$(date '+%Y-%m-%d %H:%M:%S')
    echo "  baseline=$baseline"

    publish_noti "uplink_ready" '{"ready":false}'
    sleep 1
    publish_noti "uplink_ready" '{"ready":true}'

    echo "  동기화 트리거 대기 (10초)..."
    sleep 10

    dump_cmd journalctl -u docker-loader --since "$baseline"
    local jlog
    jlog=$(journalctl -u docker-loader --since "$baseline" 2>/dev/null)

    if echo "$jlog" | grep -qF "Syncing register map to IoT Hub"; then
        assert "TC10-1: 동기화 트리거 로그 출현" "PASS"
    else
        assert "TC10-1: 동기화 트리거 로그 출현" "FAIL"
    fi

    if echo "$jlog" | grep -qF "Register map data sent to IoT Hub successfully"; then
        assert "TC10-2: D2C 전송 시도 로그 출현" "PASS"
    else
        assert "TC10-2: D2C 전송 시도 로그 출현" "FAIL"
    fi
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " db_manager TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01)
        tc01_configuration_select_all
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc02)
        tc02_sync_configuration_cloud
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc03)
        tc03_persistent_state_update_records
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc04)
        tc04_system_setting_log_level
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc05)
        tc05_persistent_state_boot
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc06-pre)
        # tc06_pre 내부에서 요약 출력 후 reboot 실행 (system_log --tc10-pre와 동일 패턴)
        tc06_pre
        ;;
    --tc06-post)
        # tc06_post 내부에서 요약 출력까지 완료 (system_log --tc10-post와 동일 패턴)
        tc06_post
        ;;
    --tc07)
        tc07_persistent_state_select_all
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc08)
        tc08_system_setting_select_all
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc09)
        tc09_db_file_location
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    --tc10)
        tc10_sync_register_map_cloud
        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
    *)
        # TC06(재부팅 수반, 세션 끊김)은 기본 실행에서 제외 — 별도 --tc06-pre/--tc06-post 사용.
        tc01_configuration_select_all
        tc02_sync_configuration_cloud
        tc03_persistent_state_update_records
        tc04_system_setting_log_level
        tc05_persistent_state_boot
        tc07_persistent_state_select_all
        tc08_system_setting_select_all
        tc09_db_file_location
        tc10_sync_register_map_cloud

        echo ""
        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        echo ""
        echo "[안내] TC06(리부트)은 별도 실행 (기본 실행에 미포함):"
        echo "  ./tc_db_manager.sh --tc06-pre   (재부팅 발생)"
        echo "  ./tc_db_manager.sh --tc06-post  (재접속 후)"
        ;;
esac
