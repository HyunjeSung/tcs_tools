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
# configuration.json / register_map.json은 DUT 호스트가 아니라 ac_system_gen2
# 컨테이너 이미지 내부에만 존재함 (docker inspect 확인: /edge/app는 bind mount
# 아님, 컨테이너 자체 파일시스템). 그래서 이 경로에 대한 모든 파일 조작은
# docker exec "$CONTAINER" 를 통해 컨테이너 안에서 실행해야 한다.
CONTAINER="ac_system_gen2"
CONFIG_JSON_PATH="/edge/app/files/commonfile/configuration.json"
REGISTER_MAP_JSON_PATH="/edge/app/files/commonfile/register_map.json"
# /tmp는 ramdisk라 reboot 시 소실됨(reference_device_ssh 메모). TC03은 reboot를
# 사이에 두고 pre/post 상태(T0)를 넘겨야 하므로, bind mount되어 reboot 후에도
# 살아남는 /edge/log/ 밑에 저장한다 (실측: TC03_SAVE를 /tmp에 뒀다가 --tc03-pre
# 직후 reboot로 유실되는 걸 2026-08-12 세션에서 직접 확인 후 수정).
TC03_SAVE="/edge/log/.tc_device_manager_tc03_state"
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
    elif [ "$result" = "SKIP" ]; then
        # PASS/FAIL 카운트에 넣지 않음 — 자동화 불가/환경 제약으로 판정 자체가
        # 성립하지 않는 항목(TC01/TC02/TC05)을 대시보드 결과 현황판에 노출시키기
        # 위한 별도 상태. dump_cmd/PASS/FAIL과 같은 "TCxx-n:" 형식을 지켜야
        # server.py ASSERT_RE가 잡아서 현황판에 반영한다.
        echo "[SKIP] $desc"
        [ -n "$3" ] && echo "  [REASON] $3"
    else
        echo "[FAIL] $desc"
        FAIL=$((FAIL + 1))
        [ -n "$3" ] && echo "  [REASON] $3"
    fi
}

# ============================================================
# TC01/TC02: 이 DUT에서 자동화 불가 (환경 제약, 2026-08-12 확인)
#
# configuration.json/register_map.json이 있는 /edge/app/files/commonfile/은
# db_manager 소스(edge_site_json_data.hpp kConfigurationFilePath)가 매 boot/
# factory_reset마다 다시 읽는 진짜 source of truth가 맞다 — 하지만 이 경로는
# /edge/devapp, /edge/db, /edge/log와 달리 호스트에 bind mount되어 있지 않고
# docker-loader.sh가 "docker run --rm"으로 컨테이너를 매번 새로 만든다
# (재부팅뿐 아니라 "systemctl restart docker-loader"만으로도 재현).
# 그래서 TC01/TC02가 전제로 하는 "파일 수정 → reboot → 반영 확인" 자체가
# 이 DUT에서는 성립하지 않는다 — 어떤 수정을 하든 재기동 시 이미지의 pristine
# 상태로 되돌아간다.
#
# 실측 (2026-08-12): docker cp로 configuration.json에 __tc_marker 필드 삽입 →
# 값 확인됨 → "systemctl restart docker-loader" 실행 → 컨테이너 Created
# 타임스탬프 변경(재생성 확인) → 같은 파일 재조회 시 __tc_marker=null.
# (이 파일은 호스트 bind mount가 아니므로 jq도 컨테이너 안엔 없음 — 조회는
# 항상 "docker exec $CONTAINER cat <path> | jq ..."로 호스트 jq를 거쳐야 함)
#
# 이게 이 테스트 환경만의 프로비저닝 누락인지 실제 제품 배포 방식과 다른
# 것인지(=제품 버그)는 별도 확인 필요 — tc_device_manager.md 참고.
# ============================================================
tc01_pre() {
    echo "=== TC01: SKIP — 이 DUT에서 자동화 불가 (환경 제약) ==="
    echo "  사유: configuration.json이 있는 /edge/app/files/commonfile/은 호스트에"
    echo "  bind mount 안 됨 -> docker-loader.sh가 컨테이너를 --rm으로 재기동할 때마다"
    echo "  이미지의 pristine 상태로 되돌아감. 파일 수정 -> reboot 반영 검증 불가."
    echo "  상세 근거: tc_device_manager.md TC01 절 참고. reboot 실행하지 않음."
    assert "TC01-1: configuration.json 신규 Protocol 추가 반영 확인" "SKIP" "환경 제약 — /edge/app bind mount 없음, tc_device_manager.md TC01 참고"
}
tc01_post() {
    echo "=== TC01-POST: SKIP (TC01-PRE가 자동화 불가라 실행 대상 없음) ==="
}
tc02_pre() {
    echo "=== TC02: SKIP — 이 DUT에서 자동화 불가 (TC01과 동일 환경 제약) ==="
    echo "  상세 근거: tc_device_manager.md TC02 절 참고. reboot 실행하지 않음."
    assert "TC02-1: configuration.json/register_map.json 부재 시 부팅 동작" "SKIP" "환경 제약 — /edge/app bind mount 없음, tc_device_manager.md TC02 참고"
}
tc02_post() {
    echo "=== TC02-POST: SKIP (TC02-PRE가 자동화 불가라 실행 대상 없음) ==="
}

# ============================================================
# TC03-PRE: 정상 configuration.json/register_map.json 상태로 reboot 준비
# [주의] TC02 teardown으로 정상 파일이 복원된 이후 실행할 것
# ============================================================
tc03_pre() {
    echo "=== TC03-PRE: 정상 파일 상태로 reboot 준비 ==="
    echo "  사전조건: TC02 teardown으로 configuration.json/register_map.json 정상 복원 완료"

    dump_cmd docker exec "$CONTAINER" ls -la "$CONFIG_JSON_PATH" "$REGISTER_MAP_JSON_PATH"
    echo "  \$ docker exec $CONTAINER cat $CONFIG_JSON_PATH | jq empty (JSON 파싱 유효성만 확인, 무출력=OK)"
    docker exec "$CONTAINER" cat "$CONFIG_JSON_PATH" 2>/dev/null | jq empty 2>&1 | sed 's/^/    /'
    echo "    exit_code:${PIPESTATUS[1]}"
    echo "  \$ docker exec $CONTAINER cat $REGISTER_MAP_JSON_PATH | jq empty (JSON 파싱 유효성만 확인, 무출력=OK)"
    docker exec "$CONTAINER" cat "$REGISTER_MAP_JSON_PATH" 2>/dev/null | jq empty 2>&1 | sed 's/^/    /'
    echo "    exit_code:${PIPESTATUS[1]}"

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

    local jq_filter='.. | objects | select(.operation? and (.operation | index("read"))) | {id, operation, periodMs}'
    echo "  \$ docker exec $CONTAINER cat $REGISTER_MAP_JSON_PATH | jq '$jq_filter'"
    docker exec "$CONTAINER" cat "$REGISTER_MAP_JSON_PATH" 2>/dev/null | jq "$jq_filter" 2>&1 | sed 's/^/    /'
    echo "    exit_code:${PIPESTATUS[1]}"

    local period_ms
    period_ms=$(docker exec "$CONTAINER" cat "$REGISTER_MAP_JSON_PATH" 2>/dev/null | jq -r '[.. | objects | select(.operation? and (.operation | index("read"))) | .periodMs] | first' 2>/dev/null)

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
    assert "TC05-1: 자동화 불가 항목 목록 (Web HMI 수동 조작/개발자 확인 필요)" "SKIP" "설계상 자동화 대상 아님, tc_device_manager.md TC05 항목 표 참고"
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
    --only)
        # 대시보드의 "선택 실행"에서 사용 — TC01~03은 reboot를 수반해 지원하지 않는다
        # (--tc01-pre/-post ~ --tc03-pre/-post 사용). TC04/TC05만 선택 가능.
        # 예: sh tc_device_manager.sh --only TC04,TC05
        shift
        SELECTED="${1:-}"
        if [ -z "$SELECTED" ]; then
            echo "[ERROR] --only 뒤에 TC 목록이 필요합니다 (예: --only TC04,TC05)"
            exit 1
        fi
        for tc in TC04 TC05; do
            case ",${SELECTED}," in
                *,${tc},*)
                    case "$tc" in
                        TC04) tc04_periodic_read ;;
                        TC05) tc05_manual_review ;;
                    esac
                    ;;
            esac
        done
        ;;
    *)
        echo "[안내] TC01/TC02는 이 DUT에서 자동화 불가(환경 제약 — /edge/app bind mount 없음,"
        echo "  tc_device_manager.md 참고). --tc01-pre/-post, --tc02-pre/-post 는 SKIP 안내만 출력함."
        echo "  TC03은 reboot를 수반해 이 스크립트 안에서 이어갈 수 없음 (SSH 세션 끊김):"
        echo "  ./tc_device_manager.sh --tc03-pre   (정상 파일 상태 확인 + reboot)"
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
