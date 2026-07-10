#!/bin/bash
# TC: device_log
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="device_log"
STAGING_DIR="/edge/log/device"
TOUPLOAD_DIR="/edge/log/toupload/device"
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
    if [ "$result" = "PASS" ]; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
# TC01: <한 줄 요약>
# ============================================================
tc01_placeholder() {
    echo "=== TC01: <TODO> ==="
    # TODO: 명세 (tc_device_log.md) 의 TC01 절차/PASS-FAIL Criteria 에 맞춰 구현
    # 예시 스켈레톤:
    #   local resp
    #   resp=$(send_and_wait "<service_name>" "{}" 30)
    #   if [ -n "$resp" ]; then
    #       assert "TC01-1: <기준 설명>" "PASS"
    #   else
    #       assert "TC01-1: <기준 설명>" "FAIL"
    #   fi
    assert "TC01-1: <TODO>" "PASS"
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " device_log TC"
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
