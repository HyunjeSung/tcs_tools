#!/bin/bash
# TC: energy_monitor
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}
# energy_monitor 는 send_d2c_message 요청을 azure_connector 로 발행한다:
#   emsp/{azure_connector}/{energy_monitor}/req/send_d2c_message
# energy_link 가 보내는 telemetry notification 형식을 흉내내어 주입한다:
#   emsp/{energy_monitor}/{source}/noti/telemetry

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="energy_monitor"
AZURE_CONNECTOR_APPID="azure_connector"
CONFIG_PATH="${CONFIG_PATH:-/edge/app/files/commonfile/configuration.json}"
CAPTURE_TOPIC="emsp/${AZURE_CONNECTOR_APPID}/${TARGET}/req/send_d2c_message"
TELEMETRY_NOTI_TOPIC="emsp/${TARGET}/${SOURCE}/noti/telemetry"
METRICS_FILE="/tmp/em_metrics_$$.json"
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

# apply_ten_multiplier: telemetry_manager.cpp::apply_ten_multiplier() 재현
#   tenMultiplier<0 : 소수점 -tenMultiplier 자리로 반올림
#   tenMultiplier>=0: 10^tenMultiplier 단위로 반올림
apply_ten_multiplier() {
    awk -v v="$1" -v tm="$2" 'BEGIN{
        if (tm < 0) {
            f = 10 ^ (-tm);
            r = int(v * f + (v >= 0 ? 0.5 : -0.5)) / f;
        } else {
            f = 10 ^ tm;
            r = int(v / f + (v >= 0 ? 0.5 : -0.5)) * f;
        }
        printf "%.10g", r;
    }'
}

# extract_point: 재파싱된 CommonTelemetryDto JSON 문자열($1)에서
# devices[].points[rid]($2) 값을 추출
extract_point() {
    echo "$1" | jq -r --arg rid "$2" '[.devices[]?.points[$rid]] | map(select(. != null))[0] // empty' 2>/dev/null
}

# ============================================================
# SETUP: configuration.json 메트릭 목록 추출
# ============================================================
setup_config() {
    echo "=== SETUP: configuration.json 메트릭 추출 ==="
    if ! command -v jq > /dev/null 2>&1; then
        echo "  [ERROR] jq 미설치 — configuration.json 파싱 불가, 이후 TC 는 metric 미검출로 FAIL 처리됨"
    fi
    dump_cmd cat "$CONFIG_PATH"
    jq -c '[.deviceList[]? | .deviceMetricList[]? | {
        rid: .rid,
        metricPath: .metricPath,
        telemetryPeriod: (.readingType.telemetryPeriod // 60),
        qualifier: (.readingType.qualifier // ""),
        tenMultiplier: (.readingType.tenMultiplier // 0),
        accumulationType: (.accumulationType // ""),
        flowDirectionType: (.readingType.flowDirectionType // "")
    }]' "$CONFIG_PATH" > "$METRICS_FILE" 2>/dev/null
    [ -s "$METRICS_FILE" ] || echo "[]" > "$METRICS_FILE"
    dump_cmd cat "$METRICS_FILE"
}

# ============================================================
# TC01: Report 항목 필터링
# ============================================================
tc01_report_filtering() {
    echo "=== TC01: Report 항목 필터링 ==="
    local rid path period
    rid=$(jq -r '.[0].rid // empty' "$METRICS_FILE")
    path=$(jq -r '.[0].metricPath // empty' "$METRICS_FILE")
    period=$(jq -r '.[0].telemetryPeriod // 60' "$METRICS_FILE")

    if [ -z "$rid" ] || [ -z "$path" ]; then
        echo "  [SKIP] configuration.json 에서 사용 가능한 metric 을 찾지 못함"
        assert "TC01-1: 캡처된 send_d2c_message 요청 1건 이상 수신" "FAIL" "configured metric 없음"
        return
    fi
    echo "  CONFIGURED_RID=$rid CONFIGURED_PATH=$path TELEMETRY_PERIOD=$period"

    local capture_file="/tmp/em_tc01_capture_$$.log"
    mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -C 1 -W "$((period + 15))" > "$capture_file" 2>/dev/null &
    local sub_pid=$!
    sleep 0.5

    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" \
        -m "[{\"metricPath\":\"$path\",\"value\":123.4},{\"metricPath\":\"tc_unconfigured/bogus/path\",\"value\":999.9}]"

    wait "$sub_pid"
    dump_cmd cat "$capture_file"

    local raw parsed_message
    raw=$(cat "$capture_file")
    parsed_message=$(echo "$raw" | jq -r '.payload.message // empty' 2>/dev/null)

    if [ -s "$capture_file" ]; then
        assert "TC01-1: 캡처된 send_d2c_message 요청 1건 이상 수신" "PASS"
    else
        assert "TC01-1: 캡처된 send_d2c_message 요청 1건 이상 수신" "FAIL"
    fi

    if echo "$parsed_message" | grep -q "\"$rid\""; then
        assert "TC01-2: payload 의 points 에 CONFIGURED_RID 키 존재" "PASS"
    else
        assert "TC01-2: payload 의 points 에 CONFIGURED_RID 키 존재" "FAIL" "rid=$rid 미검출"
    fi

    local unconf_count
    unconf_count=$(echo "$parsed_message" | grep -c "999.9")
    if [ "$unconf_count" -eq 0 ]; then
        assert "TC01-3: 미설정 항목(999.9) 값이 payload 에 없음" "PASS"
    else
        assert "TC01-3: 미설정 항목(999.9) 값이 payload 에 없음" "FAIL" "999.9 값이 ${unconf_count}건 발견됨"
    fi

    rm -f "$capture_file"
}

# ============================================================
# TC02: Azure IoT Hub 전송
# ============================================================
tc02_azure_transmission() {
    echo "=== TC02: Azure IoT Hub 전송 ==="
    local period duration capture_file
    period=$(jq -r '.[0].telemetryPeriod // 60' "$METRICS_FILE")
    duration=$((2 * period + 20))
    capture_file="/tmp/em_tc02_capture_$$.log"
    echo "  TELEMETRY_PERIOD=$period, 관찰 시간=${duration}s"

    timeout "$duration" mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -v | while IFS= read -r line; do
        echo "$(date +%s) $line"
    done > "$capture_file" 2>/dev/null
    dump_cmd cat "$capture_file"

    local total mtype_count dto_count
    total=$(wc -l < "$capture_file" | awk '{print $1}')
    mtype_count=$(grep -c '"message_type":"ReportCommonTelemetry"' "$capture_file")
    dto_count=$(grep -c 'CommonTelemetryDto' "$capture_file")

    if [ "$total" -ge 2 ]; then
        assert "TC02-1: 관찰 구간 내 send_d2c_message 요청 2건 이상" "PASS"
    else
        assert "TC02-1: 관찰 구간 내 send_d2c_message 요청 2건 이상" "FAIL" "수신 건수=$total"
    fi

    if [ "$total" -gt 0 ] && [ "$mtype_count" -eq "$total" ]; then
        assert "TC02-2: 모든 요청의 message_type 이 ReportCommonTelemetry" "PASS"
    else
        assert "TC02-2: 모든 요청의 message_type 이 ReportCommonTelemetry" "FAIL" "mtype_count=$mtype_count total=$total"
    fi

    if [ "$total" -gt 0 ] && [ "$dto_count" -eq "$total" ]; then
        assert "TC02-3: 모든 message 내용에 CommonTelemetryDto 포함" "PASS"
    else
        assert "TC02-3: 모든 message 내용에 CommonTelemetryDto 포함" "FAIL" "dto_count=$dto_count total=$total"
    fi

    if [ "$total" -ge 2 ]; then
        local t1 t2 interval_diff
        t1=$(sed -n '1p' "$capture_file" | awk '{print $1}')
        t2=$(sed -n '2p' "$capture_file" | awk '{print $1}')
        interval_diff=$((t2 - t1 - period))
        [ "$interval_diff" -lt 0 ] && interval_diff=$((-interval_diff))
        if [ "$interval_diff" -le 5 ]; then
            assert "TC02-4: 연속 전송 간격이 TELEMETRY_PERIOD ± 5초" "PASS"
        else
            assert "TC02-4: 연속 전송 간격이 TELEMETRY_PERIOD ± 5초" "FAIL" "interval_diff=$interval_diff"
        fi
    else
        assert "TC02-4: 연속 전송 간격이 TELEMETRY_PERIOD ± 5초" "FAIL" "수신 건수 부족(total=$total)"
    fi

    rm -f "$capture_file"
}

# ============================================================
# TC03: 평균 값 계산
# ============================================================
tc03_average_calc() {
    echo "=== TC03: 평균 값 계산 ==="
    local rid path mult period
    rid=$(jq -r '[.[] | select(.qualifier=="Avg")][0].rid // empty' "$METRICS_FILE")
    path=$(jq -r '[.[] | select(.qualifier=="Avg")][0].metricPath // empty' "$METRICS_FILE")
    mult=$(jq -r '[.[] | select(.qualifier=="Avg")][0].tenMultiplier // 0' "$METRICS_FILE")
    period=$(jq -r '[.[] | select(.qualifier=="Avg")][0].telemetryPeriod // 60' "$METRICS_FILE")

    if [ -z "$rid" ] || [ -z "$path" ]; then
        echo "  [SKIP] readingType.qualifier==\"Avg\" 인 metric 없음"
        assert "TC03-1: payload 값이 기대 평균(반올림 적용)과 일치" "FAIL" "Avg qualifier metric 없음"
        assert "TC03-2: payload 값이 마지막 발행값(순시값)과 다름" "FAIL" "Avg qualifier metric 없음"
        return
    fi
    echo "  AVG_RID=$rid AVG_PATH=$path AVG_TEN_MULTIPLIER=$mult AVG_PERIOD=$period"

    local capture_file="/tmp/em_tc03_capture_$$.log"
    mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -C 1 -W "$((period + 15))" > "$capture_file" 2>/dev/null &
    local sub_pid=$!
    sleep 0.5

    local val last=""
    for val in 10.0 20.0 30.0; do
        dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" -m "[{\"metricPath\":\"$path\",\"value\":$val}]"
        last="$val"
        sleep 1
    done

    local expected_avg expected_rounded
    expected_avg=$(awk 'BEGIN{printf "%.10g", (10.0+20.0+30.0)/3}')
    expected_rounded=$(apply_ten_multiplier "$expected_avg" "$mult")

    wait "$sub_pid"
    dump_cmd cat "$capture_file"

    local raw parsed_message reported
    raw=$(cat "$capture_file")
    parsed_message=$(echo "$raw" | jq -r '.payload.message // empty' 2>/dev/null)
    reported=$(extract_point "$parsed_message" "$rid")
    echo "  EXPECTED_AVG=$expected_avg EXPECTED_ROUNDED=$expected_rounded REPORTED=$reported LAST_INJECTED_VALUE=$last"

    if [ -n "$reported" ] && awk -v a="$reported" -v b="$expected_rounded" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.01)}'; then
        assert "TC03-1: payload 값이 기대 평균(반올림 적용)과 일치" "PASS"
    else
        assert "TC03-1: payload 값이 기대 평균(반올림 적용)과 일치" "FAIL" "reported=$reported expected=$expected_rounded"
    fi

    if [ -n "$reported" ] && [ "$reported" != "$last" ]; then
        assert "TC03-2: payload 값이 마지막 발행값(순시값)과 다름" "PASS"
    else
        assert "TC03-2: payload 값이 마지막 발행값(순시값)과 다름" "FAIL" "reported=$reported last=$last"
    fi

    rm -f "$capture_file"
}

# ============================================================
# TC04: 전송 주기 조절 (Flag — 요구사항 samplingRate 필드가 코드에 없음)
# ============================================================
tc04_period_adjustment() {
    echo "=== TC04: 전송 주기 조절 ==="
    echo "  [INFO] 요구사항 원본의 최상위 samplingRate 필드는 실제 ConfigurationDocument 파싱 구조에 없음"
    echo "  [INFO] 실제 메커니즘은 metric 단위 readingType.telemetryPeriod — 본 TC 는 이 메커니즘 기준으로 검증"

    local periods_distinct short_rid short_period long_rid="" long_period="" single_only=0
    periods_distinct=$(jq -r '[.[].telemetryPeriod] | unique | length' "$METRICS_FILE")

    if [ "$periods_distinct" -ge 2 ]; then
        short_rid=$(jq -r '[.[]] | sort_by(.telemetryPeriod)[0].rid // empty' "$METRICS_FILE")
        short_period=$(jq -r '[.[]] | sort_by(.telemetryPeriod)[0].telemetryPeriod // empty' "$METRICS_FILE")
        long_rid=$(jq -r '[.[]] | sort_by(.telemetryPeriod) | .[-1].rid // empty' "$METRICS_FILE")
        long_period=$(jq -r '[.[]] | sort_by(.telemetryPeriod) | .[-1].telemetryPeriod // empty' "$METRICS_FILE")
    else
        single_only=1
        short_rid=$(jq -r '.[0].rid // empty' "$METRICS_FILE")
        short_period=$(jq -r '.[0].telemetryPeriod // 60' "$METRICS_FILE")
    fi

    if [ -z "$short_rid" ]; then
        echo "  [SKIP] configuration.json 에서 사용 가능한 metric 없음"
        assert "TC04-2: SHORT(또는 유일) 메트릭의 연속 등장 간격이 telemetryPeriod ± 5초" "FAIL" "metric 없음"
        return
    fi

    local duration
    if [ "$single_only" -eq 1 ]; then
        duration=$((2 * short_period + 20))
        echo "  단일 주기값만 존재 → SHORT_RID=$short_rid SHORT_PERIOD=$short_period (TC04-1 SKIP)"
    else
        duration=$((2 * long_period + 20))
        echo "  SHORT_RID=$short_rid SHORT_PERIOD=$short_period / LONG_RID=$long_rid LONG_PERIOD=$long_period"
    fi

    local capture_file="/tmp/em_tc04_capture_$$.log"
    timeout "$duration" mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -v | while IFS= read -r line; do
        echo "$(date +%s) $line"
    done > "$capture_file" 2>/dev/null
    dump_cmd cat "$capture_file"

    local short_count
    short_count=$(grep -c "\"$short_rid\"" "$capture_file")

    if [ "$single_only" -eq 1 ]; then
        echo "  [SKIP] TC04-1: 단일 주기값만 존재하여 SHORT_COUNT/LONG_COUNT 비교 불가"
    else
        local long_count
        long_count=$(grep -c "\"$long_rid\"" "$capture_file")
        echo "  SHORT_COUNT=$short_count LONG_COUNT=$long_count"
        if [ "$short_count" -gt "$long_count" ]; then
            assert "TC04-1: SHORT_COUNT > LONG_COUNT" "PASS"
        else
            assert "TC04-1: SHORT_COUNT > LONG_COUNT" "FAIL" "short_count=$short_count long_count=$long_count"
        fi
    fi

    local t1 t2 interval_diff
    t1=$(grep "\"$short_rid\"" "$capture_file" | sed -n '1p' | awk '{print $1}')
    t2=$(grep "\"$short_rid\"" "$capture_file" | sed -n '2p' | awk '{print $1}')

    if [ -n "$t1" ] && [ -n "$t2" ]; then
        interval_diff=$((t2 - t1 - short_period))
        [ "$interval_diff" -lt 0 ] && interval_diff=$((-interval_diff))
        if [ "$interval_diff" -le 5 ]; then
            assert "TC04-2: SHORT(또는 유일) 메트릭의 연속 등장 간격이 telemetryPeriod ± 5초" "PASS"
        else
            assert "TC04-2: SHORT(또는 유일) 메트릭의 연속 등장 간격이 telemetryPeriod ± 5초" "FAIL" "interval_diff=$interval_diff"
        fi
    else
        assert "TC04-2: SHORT(또는 유일) 메트릭의 연속 등장 간격이 telemetryPeriod ± 5초" "FAIL" "SHORT_RID 가 2회 미만 등장"
    fi

    echo "[INFO] TC04-Flag: 요구사항의 최상위 samplingRate 필드가 코드 파싱 구조(msg_ipc_payload.hpp)에 없음 — 개발자 확인 필요 (PASS/FAIL 집계 대상 아님)"

    rm -f "$capture_file"
}

# ============================================================
# TC05: 소수점 자릿수 조정 검증
# ============================================================
tc05_ten_multiplier() {
    echo "=== TC05: 소수점 자릿수 조정 검증 ==="
    local rid path mult period
    rid=$(jq -r '[.[] | select(.tenMultiplier < 0)][0].rid // empty' "$METRICS_FILE")
    path=$(jq -r '[.[] | select(.tenMultiplier < 0)][0].metricPath // empty' "$METRICS_FILE")
    mult=$(jq -r '[.[] | select(.tenMultiplier < 0)][0].tenMultiplier // empty' "$METRICS_FILE")
    period=$(jq -r '[.[] | select(.tenMultiplier < 0)][0].telemetryPeriod // 60' "$METRICS_FILE")

    if [ -z "$rid" ]; then
        echo "  [SKIP] tenMultiplier<0 인 metric 없음"
        assert "TC05-1: 음수 tenMultiplier 반올림 값 일치" "FAIL" "tenMultiplier<0 metric 없음"
    else
        echo "  TM_RID=$rid TM_PATH=$path TM_MULT=$mult TM_PERIOD=$period"
        local capture_file="/tmp/em_tc05_capture_$$.log"
        mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -C 1 -W "$((period + 15))" > "$capture_file" 2>/dev/null &
        local sub_pid=$!
        sleep 0.5
        dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" -m "[{\"metricPath\":\"$path\",\"value\":12.34567}]"
        wait "$sub_pid"
        dump_cmd cat "$capture_file"

        local expected raw parsed_message reported
        expected=$(apply_ten_multiplier "12.34567" "$mult")
        raw=$(cat "$capture_file")
        parsed_message=$(echo "$raw" | jq -r '.payload.message // empty' 2>/dev/null)
        reported=$(extract_point "$parsed_message" "$rid")
        echo "  EXPECTED=$expected REPORTED=$reported"

        if [ -n "$reported" ] && awk -v a="$reported" -v b="$expected" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<1e-6)}'; then
            assert "TC05-1: 음수 tenMultiplier 반올림 값 일치" "PASS"
        else
            assert "TC05-1: 음수 tenMultiplier 반올림 값 일치" "FAIL" "reported=$reported expected=$expected"
        fi
        rm -f "$capture_file"
    fi

    # TC05-2 (선택): 0/양수 tenMultiplier
    local rid2 path2 mult2 period2
    rid2=$(jq -r '[.[] | select(.tenMultiplier >= 0)][0].rid // empty' "$METRICS_FILE")
    path2=$(jq -r '[.[] | select(.tenMultiplier >= 0)][0].metricPath // empty' "$METRICS_FILE")
    mult2=$(jq -r '[.[] | select(.tenMultiplier >= 0)][0].tenMultiplier // empty' "$METRICS_FILE")
    period2=$(jq -r '[.[] | select(.tenMultiplier >= 0)][0].telemetryPeriod // 60' "$METRICS_FILE")

    if [ -z "$rid2" ]; then
        echo "  [SKIP] TC05-2: tenMultiplier>=0 인 metric 없음 (선택 항목)"
        return
    fi
    echo "  TM_RID2=$rid2 TM_PATH2=$path2 TM_MULT2=$mult2 TM_PERIOD2=$period2"
    local capture_file2="/tmp/em_tc05b_capture_$$.log"
    mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -C 1 -W "$((period2 + 15))" > "$capture_file2" 2>/dev/null &
    local sub_pid2=$!
    sleep 0.5
    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" -m "[{\"metricPath\":\"$path2\",\"value\":12.34567}]"
    wait "$sub_pid2"
    dump_cmd cat "$capture_file2"

    local expected2 raw2 parsed_message2 reported2
    expected2=$(apply_ten_multiplier "12.34567" "$mult2")
    raw2=$(cat "$capture_file2")
    parsed_message2=$(echo "$raw2" | jq -r '.payload.message // empty' 2>/dev/null)
    reported2=$(extract_point "$parsed_message2" "$rid2")
    echo "  EXPECTED2=$expected2 REPORTED2=$reported2"

    if [ -n "$reported2" ] && awk -v a="$reported2" -v b="$expected2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<1e-6)}'; then
        assert "TC05-2: (선택) 0/양수 tenMultiplier 반올림 값 일치" "PASS"
    else
        assert "TC05-2: (선택) 0/양수 tenMultiplier 반올림 값 일치" "FAIL" "reported2=$reported2 expected2=$expected2"
    fi
    rm -f "$capture_file2"
}

# ============================================================
# TC06: 누적값 계산
# ============================================================
tc06_accumulation() {
    echo "=== TC06: 누적값 계산 ==="
    local rid path flow_dir period
    rid=$(jq -r '[.[] | select(.accumulationType=="Cumulative" or .accumulationType=="DailyCumulative")][0].rid // empty' "$METRICS_FILE")
    path=$(jq -r '[.[] | select(.accumulationType=="Cumulative" or .accumulationType=="DailyCumulative")][0].metricPath // empty' "$METRICS_FILE")
    flow_dir=$(jq -r '[.[] | select(.accumulationType=="Cumulative" or .accumulationType=="DailyCumulative")][0].flowDirectionType // empty' "$METRICS_FILE")
    period=$(jq -r '[.[] | select(.accumulationType=="Cumulative" or .accumulationType=="DailyCumulative")][0].telemetryPeriod // 60' "$METRICS_FILE")

    if [ -z "$rid" ]; then
        echo "  [SKIP] accumulationType Cumulative/DailyCumulative 인 metric 없음"
        assert "TC06-1: 누적값 증가량이 기대 Wh 와 일치(오차 허용)" "FAIL" "누적 metric 없음"
        assert "TC06-2: 반대 방향 값 주입 후 누적값 불변" "FAIL" "누적 metric 없음"
        return
    fi
    echo "  CUM_RID=$rid CUM_PATH=$path CUM_FLOW_DIRECTION=$flow_dir CUM_PERIOD=$period"

    local sign=1
    [ "$flow_dir" = "Negative" ] && sign=-1

    # baseline (주입 전 자연 발행 값)
    local before_file="/tmp/em_tc06_before_$$.log"
    mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -C 1 -W "$((period + 15))" > "$before_file" 2>/dev/null
    dump_cmd cat "$before_file"
    local before_msg value_before
    before_msg=$(cat "$before_file" | jq -r '.payload.message // empty' 2>/dev/null)
    value_before=$(extract_point "$before_msg" "$rid")

    # periodMs=1000 명시한 값 3회 주입 (CUM_FLOW_DIRECTION 부호로)
    local sum_wh=0 v val_signed
    for v in 5.0 7.5 6.2; do
        val_signed=$(awk -v v="$v" -v s="$sign" 'BEGIN{printf "%.5f", v*s}')
        dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" -m "[{\"metricPath\":\"$path\",\"value\":$val_signed,\"periodMs\":1000}]"
        sum_wh=$(awk -v s="$sum_wh" -v v="$v" 'BEGIN{printf "%.10f", s + (v*1000/3600000)}')
        sleep 1
    done

    local after_file="/tmp/em_tc06_after_$$.log"
    mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -C 1 -W "$((period + 15))" > "$after_file" 2>/dev/null
    dump_cmd cat "$after_file"
    local after_msg value_after delta
    after_msg=$(cat "$after_file" | jq -r '.payload.message // empty' 2>/dev/null)
    value_after=$(extract_point "$after_msg" "$rid")
    echo "  VALUE_BEFORE=$value_before VALUE_AFTER=$value_after EXPECTED_WH=$sum_wh"

    if [ -n "$value_before" ] && [ -n "$value_after" ]; then
        delta=$(awk -v a="$value_after" -v b="$value_before" 'BEGIN{printf "%.10f", a-b}')
        if awk -v a="$delta" -v b="$sum_wh" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.01)}'; then
            assert "TC06-1: 누적값 증가량이 기대 Wh 와 일치(오차 허용)" "PASS"
        else
            assert "TC06-1: 누적값 증가량이 기대 Wh 와 일치(오차 허용)" "FAIL" "delta=$delta expected=$sum_wh"
        fi
    else
        assert "TC06-1: 누적값 증가량이 기대 Wh 와 일치(오차 허용)" "FAIL" "value_before=$value_before value_after=$value_after"
    fi

    # 방향 필터링: CUM_FLOW_DIRECTION 반대 부호 값 1개 추가 발행 → 값 불변 확인
    local opp_signed after2_file after2_msg value_after2
    opp_signed=$(awk -v s="$sign" 'BEGIN{printf "%.5f", 1.0*s*-1}')
    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" -m "[{\"metricPath\":\"$path\",\"value\":$opp_signed,\"periodMs\":1000}]"

    after2_file="/tmp/em_tc06_after2_$$.log"
    mosquitto_sub -h "$MQTT_HOST" -t "$CAPTURE_TOPIC" -C 1 -W "$((period + 15))" > "$after2_file" 2>/dev/null
    dump_cmd cat "$after2_file"
    after2_msg=$(cat "$after2_file" | jq -r '.payload.message // empty' 2>/dev/null)
    value_after2=$(extract_point "$after2_msg" "$rid")
    echo "  VALUE_AFTER_OPPOSITE=$value_after2"

    if [ -n "$value_after2" ] && [ "$value_after2" = "$value_after" ]; then
        assert "TC06-2: 반대 방향 값 주입 후 누적값 불변" "PASS"
    else
        assert "TC06-2: 반대 방향 값 주입 후 누적값 불변" "FAIL" "value_before_opposite=$value_after value_after_opposite=$value_after2"
    fi

    rm -f "$before_file" "$after_file" "$after2_file"
}

# ============================================================
# TC07: Telemetry 수신 (IPC 프로토콜 레벨) — malformed input 견고성
# ============================================================
tc07_ipc_robustness() {
    echo "=== TC07: Telemetry 수신 (IPC 프로토콜 레벨) ==="
    local mark
    mark=$(date '+%Y-%m-%d %H:%M:%S')
    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" -m '{"not":"an array"}'
    sleep 2

    local log1
    log1=$(journalctl -u docker-loader --since "$mark" 2>/dev/null)
    echo "  \$ journalctl -u docker-loader --since \"$mark\""
    echo "$log1" | sed 's/^/    /'

    if echo "$log1" | grep -q "Invalid telemetry message format"; then
        assert "TC07-1: 비배열 메시지 발행 후 ERROR 로그 확인" "PASS"
    else
        assert "TC07-1: 비배열 메시지 발행 후 ERROR 로그 확인" "FAIL"
    fi

    if pgrep -f energy_monitor > /dev/null 2>&1; then
        dump_cmd pgrep -f energy_monitor
        assert "TC07-2: 프로세스 생존 확인" "PASS"
    else
        assert "TC07-2: 프로세스 생존 확인" "FAIL"
    fi

    local mark2
    mark2=$(date '+%Y-%m-%d %H:%M:%S')
    dump_cmd mosquitto_pub -h "$MQTT_HOST" -t "$TELEMETRY_NOTI_TOPIC" -m '[{"metricPath":"tc_health_check/dummy","value":1.0}]'
    sleep 5

    local log2 err_count
    log2=$(journalctl -u docker-loader --since "$mark2" 2>/dev/null)
    echo "  \$ journalctl -u docker-loader --since \"$mark2\""
    echo "$log2" | sed 's/^/    /'
    err_count=$(echo "$log2" | grep -c "Invalid telemetry message format")

    if [ "$err_count" -eq 0 ]; then
        assert "TC07-3: 정상 배열 발행 후 추가 ERROR 로그 없음" "PASS"
    else
        assert "TC07-3: 정상 배열 발행 후 추가 ERROR 로그 없음" "FAIL" "err_count=$err_count"
    fi
}

# ============================================================
# TC08: 자동화 불가 항목 (Azure IoT Hub Explorer 클라우드 포털 확인) — 목록만, PASS/FAIL 집계 대상 아님
# ============================================================
tc08_cloud_portal_manual() {
    echo "=== TC08: SKIP (자동화 불가 — Azure IoT Hub Explorer 클라우드 포털 수동 확인, tc_energy_monitor.md TC08 참고) ==="
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " energy_monitor TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01) setup_config; tc01_report_filtering ;;
    --tc02) setup_config; tc02_azure_transmission ;;
    --tc03) setup_config; tc03_average_calc ;;
    --tc04) setup_config; tc04_period_adjustment ;;
    --tc05) setup_config; tc05_ten_multiplier ;;
    --tc06) setup_config; tc06_accumulation ;;
    --tc07) tc07_ipc_robustness ;;
    --tc08) tc08_cloud_portal_manual ;;
    *)
        setup_config
        tc01_report_filtering
        tc02_azure_transmission
        tc03_average_calc
        tc04_period_adjustment
        tc05_ten_multiplier
        tc06_accumulation
        tc07_ipc_robustness
        tc08_cloud_portal_manual
        ;;
esac

rm -f "$METRICS_FILE"

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
