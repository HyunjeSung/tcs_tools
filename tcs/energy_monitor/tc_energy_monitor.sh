#!/bin/bash
# TC: energy_monitor
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="energy_monitor"
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
# TC01: <한 줄 요약>
# ============================================================
tc01_placeholder() {
    echo "=== TC01: <TODO> ==="
    # TODO: 검증 로직
    assert "TC01-1: <TODO>" "PASS"
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " energy_monitor TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01)
        tc01_placeholder
        ;;
    *)
        tc01_placeholder
        # TODO: 추가 TC 호출
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
