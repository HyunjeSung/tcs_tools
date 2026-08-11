#!/bin/bash
# TC: sys_manager
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="sys_manager"
TC12_SAVE="/edge/log/.tc12_uptime_before"
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
# TC01: 악성코드 점검(chkrootkit) 매일 02:00 자동 실행
# [주의] 시스템 시간을 임시로 조작한다 (NTP off -> 01:58 설정 -> 4분 대기 -> NTP 복원)
# ============================================================
tc01_chkrootkit_scheduled() {
    echo "=== TC01: 악성코드 점검(chkrootkit) 매일 02:00 자동 실행 ==="
    echo "  [주의] 시스템 시간을 임시로 조작합니다 (NTP off -> 01:58 설정 -> 4분 대기 -> NTP 복원)"

    dump_cmd date
    dump_cmd timedatectl
    timedatectl set-ntp false 2>/dev/null

    local SET_TIME
    SET_TIME=$(date '+%Y-%m-%d 01:58:00')
    dump_cmd date -s "$SET_TIME"

    echo "  [TC01] 02:00 통과 대기 (240초)..."
    sleep 240

    local log_since
    dump_cmd journalctl -u docker-loader --since "$SET_TIME"
    log_since=$(journalctl -u docker-loader --since "$SET_TIME" 2>/dev/null)

    if echo "$log_since" | grep -q "Executing scheduled security check"; then
        assert "TC01-1: 02시 스케줄 트리거 로그 출현" "PASS"
    else
        assert "TC01-1: 02시 스케줄 트리거 로그 출현" "FAIL"
    fi

    if echo "$log_since" | grep -qE "Security check completed with|No suspicious activity detected"; then
        assert "TC01-2: 보안 점검 완료 로그 출현" "PASS"
    else
        assert "TC01-2: 보안 점검 완료 로그 출현" "FAIL"
    fi

    echo "  [TC01] cleanup: NTP 복원"
    timedatectl set-ntp true 2>/dev/null
    dump_cmd date
}

# ============================================================
# TC02: 방화벽(iptables) 규칙 조회
# ============================================================
tc02_iptables_status() {
    echo "=== TC02: 방화벽(iptables) 규칙 조회 ==="
    local resp

    resp=$(send_and_wait "get_iptables_status" "{}" 30)
    echo "  get_iptables_status 응답: ${resp:-<empty>}"

    if [ -n "$resp" ]; then
        assert "TC02-1: get_iptables_status 응답 수신" "PASS"
    else
        assert "TC02-1: get_iptables_status 응답 수신" "FAIL"
    fi

    # get_iptables_status 응답 payload에는 "status" 필드가 없음(rules_text/service_active만
    # 있음, 실측 확인) — 이 서비스의 성공 여부는 envelope의 error_code로 판정한다.
    if echo "$resp" | grep -q '"error_code":"NONE"'; then
        assert "TC02-2: 응답 error_code가 NONE(성공)" "PASS"
    else
        assert "TC02-2: 응답 error_code가 NONE(성공)" "FAIL"
    fi

    dump_cmd iptables -L -n -v
    if iptables -L -n -v 2>/dev/null | grep -q "^Chain INPUT"; then
        assert "TC02-3: 직접 iptables 조회 시 INPUT 체인 존재" "PASS"
    else
        assert "TC02-3: 직접 iptables 조회 시 INPUT 체인 존재" "FAIL"
    fi
}

# ============================================================
# TC03: System Time 관리 (NTP on/off 및 상태 조회)
# ============================================================
tc03_ntp_control() {
    echo "=== TC03: System Time 관리 (NTP on/off) ==="
    local resp1 resp2 resp3 resp4

    resp1=$(send_and_wait "set_ntp" '{"enabled":false}' 30)
    echo "  set_ntp(false) 응답: ${resp1:-<empty>}"
    if echo "$resp1" | grep -q '"status":"success"'; then
        assert "TC03-1: set_ntp(false) 성공 응답" "PASS"
    else
        assert "TC03-1: set_ntp(false) 성공 응답" "FAIL"
    fi

    resp2=$(send_and_wait "get_ntp_status" "{}" 30)
    echo "  get_ntp_status 응답: ${resp2:-<empty>}"
    if echo "$resp2" | grep -q '"ntp_service":false'; then
        assert "TC03-2: get_ntp_status에서 ntp_service=false" "PASS"
    else
        assert "TC03-2: get_ntp_status에서 ntp_service=false" "FAIL"
    fi

    dump_cmd systemctl is-active systemd-timesyncd

    resp3=$(send_and_wait "set_ntp" '{"enabled":true}' 30)
    echo "  set_ntp(true) 응답: ${resp3:-<empty>}"
    if echo "$resp3" | grep -q '"status":"success"'; then
        assert "TC03-3: set_ntp(true) 성공 응답" "PASS"
    else
        assert "TC03-3: set_ntp(true) 성공 응답" "FAIL"
    fi

    resp4=$(send_and_wait "get_ntp_status" "{}" 30)
    echo "  get_ntp_status 응답: ${resp4:-<empty>}"
    if echo "$resp4" | grep -q '"ntp_service":true'; then
        assert "TC03-4: get_ntp_status에서 ntp_service=true" "PASS"
    else
        assert "TC03-4: get_ntp_status에서 ntp_service=true" "FAIL"
    fi

    sleep 3
    dump_cmd systemctl is-active systemd-timesyncd
    if systemctl is-active systemd-timesyncd 2>/dev/null | grep -q "^active$"; then
        assert "TC03-5: systemd-timesyncd 활성 상태 최종 복원" "PASS"
    else
        assert "TC03-5: systemd-timesyncd 활성 상태 최종 복원" "FAIL"
    fi
}

# ============================================================
# TC04: System Info 모니터링 (get_system_info)
# ============================================================
tc04_system_info() {
    echo "=== TC04: System Info 모니터링 (get_system_info) ==="
    local resp mem

    resp=$(send_and_wait "get_system_info" "{}" 30)
    echo "  get_system_info 응답: ${resp:-<empty>}"

    if echo "$resp" | grep -q '"is_valid":true'; then
        assert "TC04-1: get_system_info 응답 is_valid=true" "PASS"
    else
        assert "TC04-1: get_system_info 응답 is_valid=true" "FAIL"
    fi

    mem=$(echo "$resp" | jq '.payload.data.memory_usage' 2>/dev/null)
    echo "  memory_usage=${mem}"
    if [ -n "$mem" ] && [ "$mem" != "null" ] && awk -v m="$mem" 'BEGIN{exit !(m>=0 && m<=100)}' 2>/dev/null; then
        assert "TC04-2: memory_usage 0~100 범위" "PASS"
    else
        assert "TC04-2: memory_usage 0~100 범위" "FAIL"
    fi

    dump_cmd top -bn1
    if top -bn1 2>/dev/null | head -5 | grep -q "MiB Mem"; then
        assert "TC04-3: top 직접 조회 정상 출력" "PASS"
    else
        assert "TC04-3: top 직접 조회 정상 출력" "FAIL"
    fi
}

# ============================================================
# TC05: EEPROM Nameplate 관리 (get/set_eeprom_info)
# ============================================================
tc05_eeprom_info() {
    echo "=== TC05: EEPROM Nameplate 관리 (get/set_eeprom_info) ==="
    local resp before_date new_date after_date restored_date resp_set resp_restore

    resp=$(send_and_wait "get_eeprom_info" "{}" 30)
    echo "  get_eeprom_info 응답: ${resp:-<empty>}"
    if echo "$resp" | jq -e '.payload.data | has("major_revision") and has("production_date") and has("serial_number") and has("product_name") and has("product_option1") and has("product_option2")' >/dev/null 2>&1; then
        assert "TC05-1: get_eeprom_info 응답에 6개 필드 모두 존재" "PASS"
    else
        assert "TC05-1: get_eeprom_info 응답에 6개 필드 모두 존재" "FAIL"
    fi

    before_date=$(echo "$resp" | jq -r '.payload.data.production_date' 2>/dev/null)
    echo "  before_date=${before_date}"
    if [ -z "$before_date" ] || [ "$before_date" = "null" ]; then
        echo "  [SKIP] production_date 원본값 확인 실패 - TC05-2~4 스킵"
        return
    fi

    new_date="19991231"
    [ "$new_date" = "$before_date" ] && new_date="19990101"

    resp_set=$(send_and_wait "set_eeprom_info" "{\"production_date\":\"${new_date}\"}" 30)
    echo "  set_eeprom_info 응답: ${resp_set:-<empty>}"
    if echo "$resp_set" | grep -q '"error_code":"NONE"'; then
        assert "TC05-2: set_eeprom_info 성공 응답" "PASS"
    else
        assert "TC05-2: set_eeprom_info 성공 응답" "FAIL"
    fi

    resp=$(send_and_wait "get_eeprom_info" "{}" 30)
    after_date=$(echo "$resp" | jq -r '.payload.data.production_date' 2>/dev/null)
    echo "  after_date=${after_date}"
    if [ "$after_date" = "$new_date" ]; then
        assert "TC05-3: 변경값이 재조회에 반영됨" "PASS"
    else
        assert "TC05-3: 변경값이 재조회에 반영됨" "FAIL"
    fi

    resp_restore=$(send_and_wait "set_eeprom_info" "{\"production_date\":\"${before_date}\"}" 30)
    echo "  cleanup set_eeprom_info 응답: ${resp_restore:-<empty>}"
    resp=$(send_and_wait "get_eeprom_info" "{}" 30)
    restored_date=$(echo "$resp" | jq -r '.payload.data.production_date' 2>/dev/null)
    echo "  restored_date=${restored_date}"
    if [ "$restored_date" = "$before_date" ]; then
        assert "TC05-4: cleanup 후 원복 확인" "PASS"
    else
        assert "TC05-4: cleanup 후 원복 확인" "FAIL"
    fi
}

# ============================================================
# TC06: Internet 연결 관리 (get_internet_status)
# ============================================================
tc06_internet_status() {
    echo "=== TC06: Internet 연결 관리 (get_internet_status) ==="
    local resp

    resp=$(send_and_wait "get_internet_status" "{}" 30)
    echo "  get_internet_status 응답: ${resp:-<empty>}"

    if [ -n "$resp" ]; then
        assert "TC06-1: get_internet_status 응답 수신" "PASS"
    else
        assert "TC06-1: get_internet_status 응답 수신" "FAIL"
    fi

    if echo "$resp" | grep -q '"is_valid":true'; then
        assert "TC06-2: is_valid=true" "PASS"
    else
        assert "TC06-2: is_valid=true" "FAIL"
    fi

    if echo "$resp" | jq -e '.payload.data | has("is_internet_connected")' >/dev/null 2>&1; then
        assert "TC06-3: is_internet_connected 필드 존재" "PASS"
    else
        assert "TC06-3: is_internet_connected 필드 존재" "FAIL"
    fi
}

# ============================================================
# TC07: Host Network Interface 관리 (조회 + DHCP 설정 + 서비스 재시작)
# ============================================================
tc07_network_interface() {
    echo "=== TC07: Host Network Interface 관리 ==="
    local resp

    resp=$(send_and_wait "get_network_info" "{}" 30)
    echo "  get_network_info 응답: ${resp:-<empty>}"
    if echo "$resp" | jq -e '.payload.data[] | select(.interface=="eth0")' >/dev/null 2>&1; then
        assert "TC07-1: get_network_info에 eth0 존재" "PASS"
    else
        assert "TC07-1: get_network_info에 eth0 존재" "FAIL"
    fi

    dump_cmd ip -j addr show
    dump_cmd ip route show

    resp=$(send_and_wait "set_ethernet_config" '{"interface":"eth0","type":"dhcp"}' 30)
    echo "  set_ethernet_config 응답: ${resp:-<empty>}"
    if echo "$resp" | grep -q '"status":"success"'; then
        assert "TC07-2: set_ethernet_config 성공 응답" "PASS"
    else
        assert "TC07-2: set_ethernet_config 성공 응답" "FAIL"
    fi

    dump_cmd cat /etc/systemd/network/eth0.network
    if cat /etc/systemd/network/eth0.network 2>/dev/null | grep -q "DHCP=ipv4"; then
        assert "TC07-3: eth0.network에 DHCP=ipv4 포함" "PASS"
    else
        assert "TC07-3: eth0.network에 DHCP=ipv4 포함" "FAIL"
    fi

    resp=$(send_and_wait "restart_network_service" "{}" 30)
    echo "  restart_network_service 응답: ${resp:-<empty>}"
    if echo "$resp" | grep -q '"error_code":"NONE"'; then
        assert "TC07-4: restart_network_service 성공 응답" "PASS"
    else
        assert "TC07-4: restart_network_service 성공 응답" "FAIL"
    fi

    sleep 5
    dump_cmd systemctl is-active systemd-networkd
    if systemctl is-active systemd-networkd 2>/dev/null | grep -q "^active$"; then
        assert "TC07-5: systemd-networkd 재시작 후 active" "PASS"
    else
        assert "TC07-5: systemd-networkd 재시작 후 active" "FAIL"
    fi
}

# ============================================================
# TC08: Host Agent와의 연동 (UDS 재연결 + LED 상태 조회)
# [주의] systemctl restart host-agent 로 실제 서비스를 재시작한다
# ============================================================
tc08_host_agent_reconnect() {
    echo "=== TC08: Host Agent와의 연동 (UDS 재연결 + LED 상태 조회) ==="
    echo "  [주의] systemctl restart host-agent 로 실제 host-agent 서비스를 재시작합니다"
    local resp_before resp_after resp_led led0_brightness sysfs_brightness

    resp_before=$(send_and_wait "get_system_info" "{}" 30)
    echo "  재시작 전 get_system_info 응답: ${resp_before:-<empty>}"
    if echo "$resp_before" | grep -q '"error_code":"NONE"'; then
        assert "TC08-1: host-agent 재시작 전 응답 성공" "PASS"
    else
        assert "TC08-1: host-agent 재시작 전 응답 성공" "FAIL"
    fi

    echo "  [TC08] systemctl restart host-agent 실행..."
    dump_cmd systemctl restart host-agent
    sleep 15

    resp_after=$(send_and_wait "get_system_info" "{}" 30)
    echo "  재시작 후 get_system_info 응답: ${resp_after:-<empty>}"
    if echo "$resp_after" | grep -q '"error_code":"NONE"'; then
        assert "TC08-2: host-agent 재시작 후 응답 성공(재연결)" "PASS"
    else
        assert "TC08-2: host-agent 재시작 후 응답 성공(재연결)" "FAIL"
    fi

    resp_led=$(send_and_wait "get_led_status" "{}" 30)
    echo "  get_led_status 응답: ${resp_led:-<empty>}"
    if echo "$resp_led" | jq -e '.payload.leds | length > 0' >/dev/null 2>&1; then
        assert "TC08-3: get_led_status 응답에 leds 배열 존재" "PASS"
    else
        assert "TC08-3: get_led_status 응답에 leds 배열 존재" "FAIL"
    fi

    led0_brightness=$(echo "$resp_led" | jq '.payload.leds[0].brightness' 2>/dev/null)
    dump_cmd cat /sys/class/leds/led1/brightness
    sysfs_brightness=$(cat /sys/class/leds/led1/brightness 2>/dev/null)
    if [ "$led0_brightness" = "$sysfs_brightness" ]; then
        assert "TC08-4: led1 brightness가 sysfs 값과 일치" "PASS"
    else
        assert "TC08-4: led1 brightness가 sysfs 값과 일치" "FAIL" "ipc=${led0_brightness} sysfs=${sysfs_brightness}"
    fi
}

# ============================================================
# TC09: Host Agent Event Logging (whitelist 차단 로그)
# ============================================================
tc09_whitelist_blocked_log() {
    echo "=== TC09: Host Agent Event Logging (whitelist 차단 로그) ==="
    local start_ts resp1 resp2 log_since

    start_ts=$(date '+%Y-%m-%d %H:%M:%S')
    dump_cmd date

    resp1=$(send_and_wait "cmd_host" '{"cmd":"hwclock --show"}' 30)
    echo "  whitelist 명령(hwclock --show) 응답: ${resp1:-<empty>}"
    if echo "$resp1" | grep -q '"status":"success"'; then
        assert "TC09-1: whitelist 명령(hwclock --show) 성공 응답" "PASS"
    else
        assert "TC09-1: whitelist 명령(hwclock --show) 성공 응답" "FAIL"
    fi

    resp2=$(send_and_wait "cmd_host" '{"cmd":"rm -rf /tmp/x"}' 30)
    echo "  비whitelist 명령 응답: ${resp2:-<empty>}"
    if echo "$resp2" | grep -qi "whitelist"; then
        assert "TC09-2: 비whitelist 명령 차단 응답" "PASS"
    else
        assert "TC09-2: 비whitelist 명령 차단 응답" "FAIL"
    fi

    sleep 2
    dump_cmd journalctl -u host-agent --since "$start_ts"
    log_since=$(journalctl -u host-agent --since "$start_ts" 2>/dev/null)
    if echo "$log_since" | grep -q "Shell command blocked by whitelist: rm -rf /tmp/x"; then
        assert "TC09-3: journalctl WARNING 차단 로그 출현" "PASS"
    else
        assert "TC09-3: journalctl WARNING 차단 로그 출현" "FAIL"
    fi
}

# ============================================================
# TC10: Host Command 지원 (cmd_host 화이트리스트 명령군)
# ============================================================
tc10_cmd_host_whitelist() {
    echo "=== TC10: Host Command 지원 (cmd_host 화이트리스트 명령군) ==="
    local resp1 resp2 resp3 resp4 temp_reported sysfs_temp diff

    resp1=$(send_and_wait "cmd_host" '{"cmd":"timedatectl"}' 30)
    echo "  timedatectl 응답: ${resp1:-<empty>}"
    if echo "$resp1" | grep -q '"status":"success"'; then
        assert "TC10-1: timedatectl 명령 성공" "PASS"
    else
        assert "TC10-1: timedatectl 명령 성공" "FAIL"
    fi

    resp2=$(send_and_wait "cmd_host" '{"cmd":"cat /etc/os-release"}' 30)
    echo "  os-release 응답: ${resp2:-<empty>}"
    if echo "$resp2" | grep -q "BUILD_MODEL="; then
        assert "TC10-2: os-release 명령 성공 및 BUILD_MODEL 포함" "PASS"
    else
        assert "TC10-2: os-release 명령 성공 및 BUILD_MODEL 포함" "FAIL"
    fi

    resp3=$(send_and_wait "cmd_host" '{"cmd":"hwclock --show"}' 30)
    echo "  hwclock 응답: ${resp3:-<empty>}"
    if echo "$resp3" | grep -q '"status":"success"'; then
        assert "TC10-3: hwclock 명령 성공" "PASS"
    else
        assert "TC10-3: hwclock 명령 성공" "FAIL"
    fi

    resp4=$(send_and_wait "get_system_info" "{}" 30)
    temp_reported=$(echo "$resp4" | jq '.payload.data.temperature[0].value' 2>/dev/null)
    dump_cmd cat /sys/class/thermal/thermal_zone0/temp
    sysfs_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    echo "  temp_reported=${temp_reported} sysfs_temp=${sysfs_temp}"
    if [ -n "$temp_reported" ] && [ "$temp_reported" != "null" ] && [ -n "$sysfs_temp" ]; then
        diff=$(awk -v a="$sysfs_temp" -v b="$temp_reported" 'BEGIN{d=a-b; if (d<0) d=-d; print d}')
        if awk -v d="$diff" 'BEGIN{exit !(d<5000)}'; then
            assert "TC10-4: 온도 값이 thermal_zone0과 근접" "PASS"
        else
            assert "TC10-4: 온도 값이 thermal_zone0과 근접" "FAIL" "diff=${diff}"
        fi
    else
        assert "TC10-4: 온도 값이 thermal_zone0과 근접" "FAIL"
    fi

    dump_cmd df -h /edge/log
    if df -h /edge/log 2>/dev/null | grep -q "/edge/log"; then
        assert "TC10-5: df -h /edge/log 정상 출력" "PASS"
    else
        assert "TC10-5: df -h /edge/log 정상 출력" "FAIL"
    fi
}

# ============================================================
# TC11: HW별 Configuration 지원 (get_platform_info)
# ============================================================
tc11_platform_info() {
    echo "=== TC11: HW별 Configuration 지원 (get_platform_info) ==="
    local resp build_model_os version_id_os build_model_ipc version_id_ipc

    dump_cmd cat /etc/os-release
    build_model_os=$(grep '^BUILD_MODEL=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    version_id_os=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    echo "  os-release: BUILD_MODEL=${build_model_os} VERSION_ID=${version_id_os}"

    resp=$(send_and_wait "get_platform_info" "{}" 30)
    echo "  get_platform_info 응답: ${resp:-<empty>}"

    if echo "$resp" | jq -e '.payload.data.is_valid == true' >/dev/null 2>&1; then
        assert "TC11-1: get_platform_info 응답 is_valid=true" "PASS"
    else
        assert "TC11-1: get_platform_info 응답 is_valid=true" "FAIL"
    fi

    build_model_ipc=$(echo "$resp" | jq -r '.payload.data.build_host_model' 2>/dev/null)
    if [ "$build_model_ipc" = "$build_model_os" ]; then
        assert "TC11-2: build_host_model이 os-release와 일치" "PASS"
    else
        assert "TC11-2: build_host_model이 os-release와 일치" "FAIL" "ipc=${build_model_ipc} os-release=${build_model_os}"
    fi

    version_id_ipc=$(echo "$resp" | jq -r '.payload.data.version_id' 2>/dev/null)
    if [ "$version_id_ipc" = "$version_id_os" ]; then
        assert "TC11-3: version_id가 os-release와 일치" "PASS"
    else
        assert "TC11-3: version_id가 os-release와 일치" "FAIL" "ipc=${version_id_ipc} os-release=${version_id_os}"
    fi
}

# ============================================================
# TC12-PRE: Safe Reboot (request_system_reboot)
# [경고] 파괴적 시험 — 실제 DUT 재부팅을 유발한다. 기본(전체) 실행 경로에서 제외되며
#        --tc12-pre 로 요청 발행 후, DUT가 오프라인->온라인 전환하면 --tc12-post 로 이어서 실행한다.
# ============================================================
tc12_safe_reboot_pre() {
    echo "=== TC12-PRE: Safe Reboot (request_system_reboot) ==="
    echo "  [경고] 이 함수는 실제로 DUT를 재부팅시키는 파괴적 시험입니다."
    echo "  [경고] 발행 후 DUT가 재부팅됩니다 — 시리얼(COM7) 또는 ping 모니터링으로 온라인 복귀를 확인한 뒤 --tc12-post 를 실행하세요."

    dump_cmd uptime
    dump_cmd date
    local uptime_before_sec
    uptime_before_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    echo "$uptime_before_sec" > "$TC12_SAVE"

    local tid="tc-$(date +%s)"
    mosquitto_pub -h "$MQTT_HOST" -t "emsp/edge_runtime/${SOURCE}/req/request_system_reboot" \
        -m "$(printf '{"tid":"%s","payload":{}}' "$tid")"

    echo "[TC12-PRE 완료] reboot 요청 발행됨 (uptime_before=${uptime_before_sec}s). DUT 온라인 복귀 후 --tc12-post 실행."
}

# ============================================================
# TC12-POST: 재부팅 후 상태 확인
# SSH/시리얼 재접속 후 실행: ./tc_sys_manager.sh --tc12-post
# ============================================================
tc12_safe_reboot_post() {
    echo "=== TC12-POST: 재부팅 후 상태 확인 ==="

    if [ ! -f "$TC12_SAVE" ]; then
        echo "[ERROR] ${TC12_SAVE} 없음 - --tc12-pre 를 먼저 실행하세요"
        exit 1
    fi

    local uptime_before_sec uptime_after_sec fs_err_count ha_log
    uptime_before_sec=$(cat "$TC12_SAVE")
    rm -f "$TC12_SAVE"

    assert "TC12-1: DUT 재부팅 후 온라인 복귀 (post 스크립트 실행 중 = online)" "PASS"

    dump_cmd uptime
    dump_cmd date
    uptime_after_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    echo "  uptime_before=${uptime_before_sec}s uptime_after=${uptime_after_sec}s"

    if [ -n "$uptime_after_sec" ] && [ "$uptime_after_sec" -lt "$uptime_before_sec" ]; then
        assert "TC12-2: uptime 리셋 확인" "PASS"
    else
        assert "TC12-2: uptime 리셋 확인" "FAIL"
    fi

    dump_cmd dmesg
    fs_err_count=$(dmesg 2>/dev/null | grep -iE "error|corrupt|fsck" | wc -l)
    echo "  dmesg error/corrupt/fsck 라인 수: ${fs_err_count}"
    if [ "$fs_err_count" -eq 0 ]; then
        assert "TC12-3: 파일시스템 오류 로그 없음" "PASS"
    else
        assert "TC12-3: 파일시스템 오류 로그 없음" "FAIL" "화이트리스트 예외 가능성 있음 - 수동 판정 필요"
    fi

    dump_cmd journalctl -u host-agent -b
    ha_log=$(journalctl -u host-agent -b 2>/dev/null)
    if echo "$ha_log" | grep -qiE "remount|reboot syscall"; then
        assert "TC12-4: safe_reboot 실행 경로 로그 존재" "PASS"
    else
        assert "TC12-4: safe_reboot 실행 경로 로그 존재" "FAIL"
    fi
}

# ============================================================
# TC13: LED 밝기 경계값 제어 (sysfs 직접)
# ============================================================
tc13_led_brightness_boundary() {
    echo "=== TC13: LED 밝기 경계값 제어 (sysfs 직접) ==="
    local max_brightness write_err clamped

    dump_cmd cat /sys/class/leds/led1/max_brightness
    max_brightness=$(cat /sys/class/leds/led1/max_brightness 2>/dev/null)
    echo "  max_brightness=${max_brightness}"

    echo "  \$ echo -1 > /sys/class/leds/led1/brightness"
    write_err=$( (echo -1 > /sys/class/leds/led1/brightness) 2>&1 )
    echo "    ${write_err}"
    if echo "$write_err" | grep -qi "invalid argument"; then
        assert "TC13-1: 음수 입력 시 쓰기 오류" "PASS"
    else
        assert "TC13-1: 음수 입력 시 쓰기 오류" "FAIL"
    fi

    echo "  \$ echo 300 > /sys/class/leds/led1/brightness"
    echo 300 > /sys/class/leds/led1/brightness 2>/dev/null
    dump_cmd cat /sys/class/leds/led1/brightness
    clamped=$(cat /sys/class/leds/led1/brightness 2>/dev/null)
    if [ "$clamped" = "255" ]; then
        assert "TC13-2: 255 초과 입력 시 255로 클램프" "PASS"
    else
        assert "TC13-2: 255 초과 입력 시 255로 클램프" "FAIL" "clamped=${clamped}"
    fi

    echo "  [TC13] cleanup: 기본값(128) 복원"
    echo 128 > /sys/class/leds/led1/brightness 2>/dev/null
}

# ============================================================
# TC14: LED 상태 시나리오 (부팅/업데이트/네트워크/클라우드/운영 모드)
# SKIP — 소스 내 자동 트리거 로직(부팅 성공/실패 외)을 확정하지 못함 (tc_sys_manager.md 참고)
# ============================================================
tc14_led_scenario_stub() {
    echo "=== TC14: SKIP (개발자 검토 대기 — tc_sys_manager.md 참고) ==="
}

# ============================================================
# TC15: LED 제어 (밝기 0~255 + RGB 색상, IPC 경유)
# ============================================================
tc15_led_control_ipc() {
    echo "=== TC15: LED 제어 (밝기 0~255 + RGB 색상, IPC 경유) ==="
    local resp

    resp=$(send_and_wait "set_led_control" '{"instance_id":0,"brightness":0,"color":"0 0 0","trigger":"none"}' 30)
    echo "  brightness=0/Off 응답: ${resp:-<empty>}"
    dump_cmd cat /sys/class/leds/led1/brightness
    if [ "$(cat /sys/class/leds/led1/brightness 2>/dev/null)" = "0" ]; then
        assert "TC15-1: brightness=0 설정 후 sysfs 반영" "PASS"
    else
        assert "TC15-1: brightness=0 설정 후 sysfs 반영" "FAIL"
    fi

    resp=$(send_and_wait "set_led_control" '{"instance_id":0,"brightness":255,"color":"255 0 0","trigger":"none"}' 30)
    echo "  brightness=255/Red 응답: ${resp:-<empty>}"
    dump_cmd cat /sys/class/leds/led1/brightness
    if [ "$(cat /sys/class/leds/led1/brightness 2>/dev/null)" = "255" ]; then
        assert "TC15-2: brightness=255 설정 후 sysfs 반영" "PASS"
    else
        assert "TC15-2: brightness=255 설정 후 sysfs 반영" "FAIL"
    fi

    dump_cmd cat /sys/class/leds/led1/multi_intensity
    if cat /sys/class/leds/led1/multi_intensity 2>/dev/null | grep -q "255 0 0"; then
        assert "TC15-3: Red(255 0 0) 색상 sysfs 반영" "PASS"
    else
        assert "TC15-3: Red(255 0 0) 색상 sysfs 반영" "FAIL"
    fi

    resp=$(send_and_wait "set_led_control" '{"instance_id":0,"brightness":128,"color":"0 255 0","trigger":"none"}' 30)
    echo "  Green(0 255 0, 정상) 응답: ${resp:-<empty>}"
    dump_cmd cat /sys/class/leds/led1/multi_intensity
    if cat /sys/class/leds/led1/multi_intensity 2>/dev/null | grep -q "0 255 0"; then
        assert "TC15-4: Green(0 255 0) 색상 sysfs 반영" "PASS"
    else
        assert "TC15-4: Green(0 255 0) 색상 sysfs 반영" "FAIL"
    fi

    echo "  --- Yellow(255 200 0, 경고) ---"
    resp=$(send_and_wait "set_led_control" '{"instance_id":0,"brightness":128,"color":"255 200 0","trigger":"none"}' 30)
    echo "  Yellow 응답: ${resp:-<empty>}"
    dump_cmd cat /sys/class/leds/led1/multi_intensity

    echo "  --- White(255 255 255, 완료/중립) ---"
    resp=$(send_and_wait "set_led_control" '{"instance_id":0,"brightness":128,"color":"255 255 255","trigger":"none"}' 30)
    echo "  White 응답: ${resp:-<empty>}"
    dump_cmd cat /sys/class/leds/led1/multi_intensity

    echo "  --- Off(0 0 0) ---"
    resp=$(send_and_wait "set_led_control" '{"instance_id":0,"brightness":0,"color":"0 0 0","trigger":"none"}' 30)
    echo "  Off 응답: ${resp:-<empty>}"
    dump_cmd cat /sys/class/leds/led1/multi_intensity

    resp=$(send_and_wait "get_led_status" "{}" 30)
    echo "  get_led_status 응답: ${resp:-<empty>}"
    dump_cmd cat /sys/class/leds/led1/brightness
    if [ "$(echo "$resp" | jq '.payload.leds[0].brightness' 2>/dev/null)" = "$(cat /sys/class/leds/led1/brightness 2>/dev/null)" ]; then
        assert "TC15-5: get_led_status 응답이 sysfs와 일치" "PASS"
    else
        assert "TC15-5: get_led_status 응답이 sysfs와 일치" "FAIL"
    fi

    echo "  [TC15] cleanup: 부팅 성공 기본값(brightness=128, Green) 복원"
    send_and_wait "set_led_control" '{"instance_id":0,"brightness":128,"color":"0 255 0","trigger":"none"}' 30 > /dev/null
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " sys_manager TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01) tc01_chkrootkit_scheduled ;;
    --tc02) tc02_iptables_status ;;
    --tc03) tc03_ntp_control ;;
    --tc04) tc04_system_info ;;
    --tc05) tc05_eeprom_info ;;
    --tc06) tc06_internet_status ;;
    --tc07) tc07_network_interface ;;
    --tc08) tc08_host_agent_reconnect ;;
    --tc09) tc09_whitelist_blocked_log ;;
    --tc10) tc10_cmd_host_whitelist ;;
    --tc11) tc11_platform_info ;;
    --tc12-pre) tc12_safe_reboot_pre ;;
    --tc12-post) tc12_safe_reboot_post ;;
    --tc13) tc13_led_brightness_boundary ;;
    --tc14) tc14_led_scenario_stub ;;
    --tc15) tc15_led_control_ipc ;;
    --only)
        # 대시보드의 "선택 실행"에서 사용 — 콤마로 구분된 TC 목록을 받아 그 TC들만 실행한다.
        # 예: sh tc_sys_manager.sh --only TC01,TC03,TC07
        # TC12(Safe Reboot)는 세션이 끊겨 지원하지 않는다 (--tc12-pre/--tc12-post 사용).
        shift
        SELECTED="${1:-}"
        if [ -z "$SELECTED" ]; then
            echo "[ERROR] --only 뒤에 TC 목록이 필요합니다 (예: --only TC01,TC03,TC07)"
            exit 1
        fi
        for tc in TC01 TC02 TC03 TC04 TC05 TC06 TC07 TC08 TC09 TC10 TC11 TC13 TC14 TC15; do
            case ",${SELECTED}," in
                *,${tc},*)
                    case "$tc" in
                        TC01) tc01_chkrootkit_scheduled ;;
                        TC02) tc02_iptables_status ;;
                        TC03) tc03_ntp_control ;;
                        TC04) tc04_system_info ;;
                        TC05) tc05_eeprom_info ;;
                        TC06) tc06_internet_status ;;
                        TC07) tc07_network_interface ;;
                        TC08) tc08_host_agent_reconnect ;;
                        TC09) tc09_whitelist_blocked_log ;;
                        TC10) tc10_cmd_host_whitelist ;;
                        TC11) tc11_platform_info ;;
                        TC13) tc13_led_brightness_boundary ;;
                        TC14) tc14_led_scenario_stub ;;
                        TC15) tc15_led_control_ipc ;;
                    esac
                    ;;
            esac
        done
        ;;
    *)
        tc01_chkrootkit_scheduled
        tc02_iptables_status
        tc03_ntp_control
        tc04_system_info
        tc05_eeprom_info
        tc06_internet_status
        tc07_network_interface
        tc08_host_agent_reconnect
        tc09_whitelist_blocked_log
        tc10_cmd_host_whitelist
        tc11_platform_info
        # TC12(Safe Reboot)는 파괴적 시험이므로 기본 실행 경로에서 제외됨 — --tc12-pre / --tc12-post 로 개별 실행
        tc13_led_brightness_boundary
        tc14_led_scenario_stub
        tc15_led_control_ipc
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
