#!/bin/bash
# TC: azure_connector
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="azure_connector"
SP_DP_DIR="/edge/sp/secrets/dp"
IOTHUB_DB_PATH="/edge/db/iothub_messages.db"
TELEMETRY_TABLE="iothub_msgs_telemetry"
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
# TC01: TLS 1.2 이상 지원 — 검토 필요(런타임 negotiated 버전 로그 없음), tc_azure_connector.md 참고
# ============================================================
tc01_tls_version() {
    echo "=== TC01: SKIP (개발자 검토 대기 — tc_azure_connector.md 참고) ==="
}

# ============================================================
# TC02: Device Provisioning - edge_device_id 설정 및 DPS 등록 트리거
# ============================================================
tc02_dps_registration() {
    echo "=== TC02: Device Provisioning - edge_device_id 설정 및 DPS 등록 트리거 ==="
    local test_serial resp
    test_serial="TC_AZ02_$(date +%s)"

    resp=$(send_and_wait "set_edge_device_id" "{\"edge_device_id\":\"${test_serial}\"}" 10)
    echo "  응답: $resp"
    if echo "$resp" | grep -q '"result":true'; then
        assert "TC02-1: set_edge_device_id 응답 result=true" "PASS"
    else
        assert "TC02-1: set_edge_device_id 응답 result=true" "FAIL" "response=$resp"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '10 seconds ago' | grep -F -- 'edge_device_id set: ${test_serial}'"
    if journalctl -u docker-loader --since "10 seconds ago" 2>/dev/null | grep -qF -- "edge_device_id set: ${test_serial}"; then
        assert "TC02-2: edge_device_id 설정 로그 존재" "PASS"
    else
        assert "TC02-2: edge_device_id 설정 로그 존재" "FAIL"
    fi

    echo "  [WAIT] DPS 등록 재시도 주기 대기 (최대 30초)..."
    sleep 30

    dump_cmd sh -c "journalctl -u docker-loader --since '40 seconds ago' | grep -F -- 'Attempting device registration with DPS...'"
    if journalctl -u docker-loader --since "40 seconds ago" 2>/dev/null | grep -qF -- "Attempting device registration with DPS..."; then
        assert "TC02-3: DPS 등록 시도 로그 존재" "PASS"
    else
        assert "TC02-3: DPS 등록 시도 로그 존재" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '40 seconds ago' | grep -E 'Device registration successful|will retry later'"
    if journalctl -u docker-loader --since "40 seconds ago" 2>/dev/null | grep -qE "Device registration successful|will retry later"; then
        assert "TC02-4: DPS 등록 결과 로그 존재(성공/실패 무관)" "PASS"
    else
        assert "TC02-4: DPS 등록 결과 로그 존재(성공/실패 무관)" "FAIL"
    fi
}

# ============================================================
# TC03: 인증서 파일 손상 시 재발급(Re-enrollment) 동작 확인 (파괴적 시험)
# ============================================================
tc03_cert_corrupt_reenroll() {
    echo "=== TC03: 인증서 파일 손상 시 재발급 동작 확인 (파괴적 시험) ==="
    local cert="${SP_DP_DIR}/full_chain_cert.pem"
    local backup="/tmp/tc_az_backup_full_chain.pem"

    if [ ! -f "$cert" ]; then
        assert "TC03-1: 손상된 인증서 로드 실패 로그" "FAIL" "cert not found: $cert"
        assert "TC03-2: 재발급(enrollment) 트리거 로그" "FAIL" "cert not found: $cert"
        assert "TC03-3: 재발급 완료 로그" "FAIL" "cert not found: $cert"
        assert "TC03-4: 파일이 유효한 PEM으로 복구됨" "FAIL" "cert not found: $cert"
        return
    fi

    dump_cmd cp "$cert" "$backup"
    dump_cmd sh -c "head -c -100 '${cert}' > /tmp/tc_az_corrupt.pem && mv /tmp/tc_az_corrupt.pem '${cert}'"

    echo "  [WAIT] 연결 재시도/등록 루프 대기 (최대 60초)..."
    sleep 60

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- '[Certificate::is_valid] Failed to load certificate'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "[Certificate::is_valid] Failed to load certificate"; then
        assert "TC03-1: 손상된 인증서 로드 실패 로그" "PASS"
    else
        assert "TC03-1: 손상된 인증서 로드 실패 로그" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -E 'performing enrollment|performing full enrollment'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qE "performing enrollment|performing full enrollment"; then
        assert "TC03-2: 재발급(enrollment) 트리거 로그" "PASS"
    else
        assert "TC03-2: 재발급(enrollment) 트리거 로그" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- 'Certificate enrollment completed successfully'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "Certificate enrollment completed successfully"; then
        assert "TC03-3: 재발급 완료 로그" "PASS"
    else
        assert "TC03-3: 재발급 완료 로그" "FAIL"
    fi

    dump_cmd openssl x509 -in "$cert" -noout -enddate
    if openssl x509 -in "$cert" -noout -enddate >/dev/null 2>&1; then
        assert "TC03-4: 파일이 유효한 PEM으로 복구됨" "PASS"
    else
        assert "TC03-4: 파일이 유효한 PEM으로 복구됨" "FAIL"
        echo "  [CLEANUP] 재발급 실패 — 백업에서 복원"
        dump_cmd cp "$backup" "$cert"
    fi
    rm -f "$backup"
}

# ============================================================
# TC04: 인증서 파일 삭제 시 재발급 동작 확인 (파괴적 시험)
# ============================================================
tc04_cert_missing_reenroll() {
    echo "=== TC04: 인증서 파일 삭제 시 재발급 동작 확인 (파괴적 시험) ==="
    local cert="${SP_DP_DIR}/full_chain_cert.pem"
    local backup="/tmp/tc_az_backup_full_chain_tc04.pem"

    if [ ! -f "$cert" ]; then
        assert "TC04-1: 인증서 부재 감지 로그" "FAIL" "cert not found before test: $cert"
        assert "TC04-2: 재발급 완료 로그" "FAIL" "cert not found before test: $cert"
        assert "TC04-3: 파일이 재생성됨" "FAIL" "cert not found before test: $cert"
        return
    fi

    dump_cmd cp "$cert" "$backup"
    dump_cmd rm -f "$cert"

    echo "  [WAIT] 연결 재시도/등록 루프 대기 (최대 60초)..."
    sleep 60

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- '[Certificate::is_valid] Certificate or key does not exist'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "[Certificate::is_valid] Certificate or key does not exist"; then
        assert "TC04-1: 인증서 부재 감지 로그" "PASS"
    else
        assert "TC04-1: 인증서 부재 감지 로그" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- 'Certificate enrollment completed successfully'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "Certificate enrollment completed successfully"; then
        assert "TC04-2: 재발급 완료 로그" "PASS"
    else
        assert "TC04-2: 재발급 완료 로그" "FAIL"
    fi

    dump_cmd ls -la "$cert"
    if [ -f "$cert" ]; then
        assert "TC04-3: 파일이 재생성됨" "PASS"
    else
        assert "TC04-3: 파일이 재생성됨" "FAIL"
        echo "  [CLEANUP] 재발급 실패 — 백업에서 복원"
        dump_cmd cp "$backup" "$cert"
    fi
    rm -f "$backup"
}

# ============================================================
# TC05: 인증서 만료 임박 시 Re-Enroll — 검토 필요(24시간+ 실시간 대기), tc_azure_connector.md 참고
# ============================================================
tc05_cert_renewal() {
    echo "=== TC05: SKIP (개발자 검토 대기 — tc_azure_connector.md 참고) ==="
}

# ============================================================
# TC06: Blob Storage 업로드 (로컬 프로토콜/로그 레벨)
# ============================================================
tc06_blob_upload() {
    echo "=== TC06: Blob Storage 업로드 (로컬 프로토콜/로그 레벨) ==="
    local test_file="/tmp/tc_az_blob_test.txt"
    local dest_path="tc_test/tc_az_blob_test.txt"
    local payload resp

    dump_cmd sh -c "echo 'tc_azure_connector blob test $(date -Iseconds)' > ${test_file}"

    payload=$(printf '{"source_path":"%s","dest_blob_path":"%s"}' "$test_file" "$dest_path")
    resp=$(send_and_wait "upload_file_to_blob" "$payload" 30)
    echo "  응답: $resp"
    if echo "$resp" | grep -q '"error_code":"NONE"'; then
        assert "TC06-1: upload_file_to_blob 응답 error_code=NONE" "PASS"
    else
        assert "TC06-1: upload_file_to_blob 응답 error_code=NONE" "FAIL" "response=$resp"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '40 seconds ago' | grep -F -- '${test_file} -> ${dest_path}'"
    if journalctl -u docker-loader --since "40 seconds ago" 2>/dev/null | grep -qF -- "${test_file} -> ${dest_path}"; then
        assert "TC06-2: 업로드 요청 로그 존재" "PASS"
    else
        assert "TC06-2: 업로드 요청 로그 존재" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '40 seconds ago' | grep -F -- '[BlobTransport] SDK result: 0 (ok)'"
    if journalctl -u docker-loader --since "40 seconds ago" 2>/dev/null | grep -qF -- "[BlobTransport] SDK result: 0 (ok)"; then
        assert "TC06-3: SDK 업로드 성공 로그" "PASS"
    else
        assert "TC06-3: SDK 업로드 성공 로그" "FAIL"
    fi

    echo "  [MANUAL] TC06-4: Azure Portal Storage 컨테이너에서 ${dest_path} 실물 확인 필요 — TC12 참고 (자동 판정 대상 아님)"
    rm -f "$test_file"
}

# ============================================================
# TC07: Message Queueing Logic - Offline 상태에서 Telemetry 축적
#   (TC08과 이어서 실행 — iptables DROP 상태를 TC08로 넘김)
# ============================================================
tc07_offline_telemetry_queue() {
    echo "=== TC07: Message Queueing - Offline 상태에서 Telemetry 축적 ==="
    local db="$IOTHUB_DB_PATH" table="$TELEMETRY_TABLE"
    local before_count after1 after2

    dump_cmd sqlite3 "$db" "SELECT COUNT(*) FROM ${table};"
    before_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM ${table};" 2>/dev/null)
    [ -z "$before_count" ] && before_count=0
    echo "  BEFORE_COUNT=${before_count}"

    dump_cmd iptables -A OUTPUT -p tcp --dport 8883 -j DROP

    echo "  [WAIT] 연결 끊김 반영 대기 (최대 60초)..."
    sleep 60
    dump_cmd sh -c "journalctl -u docker-loader --since '60 seconds ago' | grep -F -- 'Disconnected from Azure IoT Hub.'"
    if journalctl -u docker-loader --since "60 seconds ago" 2>/dev/null | grep -qF -- "Disconnected from Azure IoT Hub."; then
        assert "TC07-1: 오프라인 전환 로그 확인" "PASS"
    else
        assert "TC07-1: 오프라인 전환 로그 확인" "FAIL"
    fi

    send_and_wait "send_message_iothub" '{"message":"{\"tc\":\"az07\"}","profile_key":"telemetry"}' 10 >/dev/null
    sleep 2
    dump_cmd sqlite3 "$db" "SELECT COUNT(*) FROM ${table};"
    after1=$(sqlite3 "$db" "SELECT COUNT(*) FROM ${table};" 2>/dev/null)
    if [ "$after1" = "$((before_count + 1))" ]; then
        assert "TC07-2: 1차 발행 후 telemetry 테이블 row +1" "PASS"
    else
        assert "TC07-2: 1차 발행 후 telemetry 테이블 row +1" "FAIL" "before=${before_count} after=${after1}"
    fi

    echo "  [WAIT] min_insert_interval_ms(45초) 경과 대기..."
    sleep 45
    send_and_wait "send_message_iothub" '{"message":"{\"tc\":\"az07b\"}","profile_key":"telemetry"}' 10 >/dev/null
    sleep 2
    dump_cmd sqlite3 "$db" "SELECT COUNT(*) FROM ${table};"
    after2=$(sqlite3 "$db" "SELECT COUNT(*) FROM ${table};" 2>/dev/null)
    if [ "$after2" = "$((before_count + 2))" ]; then
        assert "TC07-3: 45초 간격 2차 발행 후 row +1 추가" "PASS"
    else
        assert "TC07-3: 45초 간격 2차 발행 후 row +1 추가" "FAIL" "before=${before_count} after=${after2}"
    fi
    echo "  [NOTE] iptables DROP 규칙은 TC08(재연결 검증)로 넘김 — 여기서 해제하지 않음"
}

# ============================================================
# TC08: Message Queueing Logic - Cloud 재연결 후 Telemetry 재발송
#   (TC07을 직접 이어서 실행해야 함 — TC07이 걸어둔 iptables DROP 상태 전제)
# ============================================================
tc08_reconnect_telemetry_drain() {
    echo "=== TC08: Message Queueing - Cloud 재연결 후 Telemetry 재발송 ==="
    local db="$IOTHUB_DB_PATH" table="$TELEMETRY_TABLE"

    dump_cmd iptables -D OUTPUT -p tcp --dport 8883 -j DROP

    echo "  [WAIT] 재연결 로그 대기 (최대 60초)..."
    sleep 60
    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- 'Connected to Azure IoT Hub.'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "Connected to Azure IoT Hub."; then
        assert "TC08-1: 재연결 로그 확인" "PASS"
    else
        assert "TC08-1: 재연결 로그 확인" "FAIL"
    fi

    echo "  [POLL] telemetry row 0 도달까지 최대 180초, 10초 간격 폴링..."
    local elapsed=0 remain=1
    while [ "$elapsed" -lt 180 ]; do
        dump_cmd sqlite3 "$db" "SELECT COUNT(*) FROM ${table};"
        remain=$(sqlite3 "$db" "SELECT COUNT(*) FROM ${table};" 2>/dev/null)
        [ -z "$remain" ] && remain=0
        [ "$remain" = "0" ] && break
        sleep 10
        elapsed=$((elapsed + 10))
    done
    if [ "$remain" = "0" ]; then
        assert "TC08-2: telemetry row가 재연결 후 0으로 감소" "PASS"
    else
        assert "TC08-2: telemetry row가 재연결 후 0으로 감소" "FAIL" "remaining=${remain}"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '3 minutes ago' | grep -F -- '[QueueProcessor]'"
    if journalctl -u docker-loader --since "3 minutes ago" 2>/dev/null | grep -qF -- "[QueueProcessor]"; then
        assert "TC08-3: QueueProcessor 발송 로그 존재" "PASS"
    else
        assert "TC08-3: QueueProcessor 발송 로그 존재" "FAIL"
    fi
}

# ============================================================
# TC09: 서버(C2D) 메시지 수신 로그 확인 (반자동 — 발신은 Azure IoT Explorer 수동 조작 필요)
# ============================================================
tc09_c2d_message_reception() {
    echo "=== TC09: 서버(C2D) 메시지 수신 로그 확인 (반자동) ==="
    echo "  [MANUAL] azure_connector 로그 레벨이 DEBUG 이상인지 사전 확인 필요"
    echo "  [MANUAL] 지금부터 60초 이내에 Azure IoT Explorer로 이 device id에"
    echo "  [MANUAL] payload에 'tc_az09_probe' 문자열을 포함한 C2D 메시지를 전송하세요."
    echo "  [WAIT] 60초 대기..."
    sleep 60

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- '[C2D] received'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "[C2D] received"; then
        assert "TC09-1: C2D 수신 로그 출현" "PASS"
    else
        assert "TC09-1: C2D 수신 로그 출현" "FAIL" "수동 발신 미실행 또는 로그 레벨이 DEBUG 미만일 수 있음"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- '[C2D] received' | grep -F -- 'tc_az09_probe'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -F -- "[C2D] received" | grep -qF -- "tc_az09_probe"; then
        assert "TC09-2: 수신 payload에 시험 식별자 포함" "PASS"
    else
        assert "TC09-2: 수신 payload에 시험 식별자 포함" "FAIL"
    fi
}

# ============================================================
# TC10: Azure IoT Hub 연결 상태 모니터링 (연결 확인 / 연결 해제 재현)
# ============================================================
tc10_connection_monitoring() {
    echo "=== TC10: Azure IoT Hub 연결 상태 모니터링 ==="

    dump_cmd sh -c "journalctl -u docker-loader --since '5 minutes ago' | grep -F -- 'Connected to Azure IoT Hub.'"
    if journalctl -u docker-loader --since "5 minutes ago" 2>/dev/null | grep -qF -- "Connected to Azure IoT Hub."; then
        assert "TC10-1: 초기 연결 로그 확인" "PASS"
    else
        assert "TC10-1: 초기 연결 로그 확인" "FAIL"
    fi

    local noti
    noti=$(mosquitto_sub -h "$MQTT_HOST" -t "emsp/all/azure_connector/noti/changed_iothub_connection" -C 1 -W 5 2>/dev/null)
    dump_cmd echo "$noti"
    if echo "$noti" | grep -q '"connection":true'; then
        assert "TC10-2: 초기 알림 connection=true" "PASS"
    else
        assert "TC10-2: 초기 알림 connection=true" "FAIL" "noti=${noti}"
    fi

    dump_cmd iptables -A OUTPUT -p tcp --dport 8883 -j DROP
    echo "  [WAIT] 연결 해제 반영 대기 (최대 60초)..."
    sleep 60

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- 'Disconnected from Azure IoT Hub. Reason:'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "Disconnected from Azure IoT Hub. Reason:"; then
        assert "TC10-3: 차단 후 연결 해제 로그" "PASS"
    else
        assert "TC10-3: 차단 후 연결 해제 로그" "FAIL"
    fi

    noti=$(mosquitto_sub -h "$MQTT_HOST" -t "emsp/all/azure_connector/noti/changed_iothub_connection" -C 1 -W 70 2>/dev/null)
    dump_cmd echo "$noti"
    if echo "$noti" | grep -q '"connection":false'; then
        assert "TC10-4: 차단 후 알림 connection=false" "PASS"
    else
        assert "TC10-4: 차단 후 알림 connection=false" "FAIL" "noti=${noti}"
    fi

    dump_cmd iptables -D OUTPUT -p tcp --dport 8883 -j DROP
    echo "  [WAIT] 재연결 반영 대기 (최대 60초)..."
    sleep 60

    dump_cmd sh -c "journalctl -u docker-loader --since '70 seconds ago' | grep -F -- 'Connected to Azure IoT Hub.'"
    if journalctl -u docker-loader --since "70 seconds ago" 2>/dev/null | grep -qF -- "Connected to Azure IoT Hub."; then
        assert "TC10-5: 해제 후 재연결 로그" "PASS"
    else
        assert "TC10-5: 해제 후 재연결 로그" "FAIL"
    fi

    noti=$(mosquitto_sub -h "$MQTT_HOST" -t "emsp/all/azure_connector/noti/changed_iothub_connection" -C 1 -W 70 2>/dev/null)
    dump_cmd echo "$noti"
    if echo "$noti" | grep -q '"connection":true'; then
        assert "TC10-6: 재연결 알림 connection=true" "PASS"
    else
        assert "TC10-6: 재연결 알림 connection=true" "FAIL" "noti=${noti}"
    fi
}

# ============================================================
# TC11: X.509 인증서 파일 존재 및 유효성 검사
# ============================================================
tc11_cert_validity() {
    echo "=== TC11: X.509 인증서 파일 존재 및 유효성 검사 ==="
    local dir="$SP_DP_DIR"

    dump_cmd ls -la "${dir}/cacert_0.pem" "${dir}/device_private_key.pem" "${dir}/full_chain_cert.pem" "${dir}/leafcert_0.pem"
    if [ -f "${dir}/cacert_0.pem" ] && [ -f "${dir}/device_private_key.pem" ] && [ -f "${dir}/full_chain_cert.pem" ] && [ -f "${dir}/leafcert_0.pem" ]; then
        assert "TC11-1: 4개 인증서 파일 존재" "PASS"
    else
        assert "TC11-1: 4개 인증서 파일 존재" "FAIL"
    fi

    local verify_out
    if [ -f "${dir}/cacert_1.pem" ]; then
        dump_cmd sh -c "cd '${dir}' && openssl verify -CAfile cacert_0.pem -untrusted cacert_1.pem full_chain_cert.pem"
        verify_out=$(cd "${dir}" && openssl verify -CAfile cacert_0.pem -untrusted cacert_1.pem full_chain_cert.pem 2>&1)
    else
        dump_cmd sh -c "cd '${dir}' && openssl verify -CAfile cacert_0.pem full_chain_cert.pem"
        verify_out=$(cd "${dir}" && openssl verify -CAfile cacert_0.pem full_chain_cert.pem 2>&1)
    fi
    if echo "$verify_out" | grep -q ": OK"; then
        assert "TC11-2: full_chain_cert.pem 체인 검증 OK" "PASS"
    else
        assert "TC11-2: full_chain_cert.pem 체인 검증 OK" "FAIL" "verify_out=${verify_out}"
    fi

    dump_cmd diff <(openssl x509 -in "${dir}/full_chain_cert.pem" -noout -pubkey 2>/dev/null) <(openssl pkey -in "${dir}/device_private_key.pem" -pubout 2>/dev/null)
    if diff <(openssl x509 -in "${dir}/full_chain_cert.pem" -noout -pubkey 2>/dev/null) <(openssl pkey -in "${dir}/device_private_key.pem" -pubout 2>/dev/null) >/dev/null 2>&1; then
        assert "TC11-3: 키페어 일치" "PASS"
    else
        assert "TC11-3: 키페어 일치" "FAIL"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --since '5 minutes ago' | grep -F -- 'Connected to Azure IoT Hub.'"
    if journalctl -u docker-loader --since "5 minutes ago" 2>/dev/null | grep -qF -- "Connected to Azure IoT Hub."; then
        assert "TC11-4: 해당 인증서로 IoT Hub 연결 성립" "PASS"
    else
        assert "TC11-4: 해당 인증서로 IoT Hub 연결 성립" "FAIL"
    fi
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " azure_connector TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01) tc01_tls_version ;;
    --tc02) tc02_dps_registration ;;
    --tc03) tc03_cert_corrupt_reenroll ;;
    --tc04) tc04_cert_missing_reenroll ;;
    --tc05) tc05_cert_renewal ;;
    --tc06) tc06_blob_upload ;;
    --tc07) tc07_offline_telemetry_queue ;;
    --tc08) tc08_reconnect_telemetry_drain ;;
    --tc09) tc09_c2d_message_reception ;;
    --tc10) tc10_connection_monitoring ;;
    --tc11) tc11_cert_validity ;;
    *)
        tc01_tls_version
        tc02_dps_registration
        tc03_cert_corrupt_reenroll
        tc04_cert_missing_reenroll
        tc05_cert_renewal
        tc06_blob_upload
        tc07_offline_telemetry_queue
        tc08_reconnect_telemetry_drain
        tc09_c2d_message_reception
        tc10_connection_monitoring
        tc11_cert_validity
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
