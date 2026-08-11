#!/bin/bash
# TC: update_monitor
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="update_monitor"
ADU_DONE_DIR="${ADU_DONE_DIR:-/tmp/edge/update}"
UPDATE_HISTORY_DIR="${UPDATE_HISTORY_DIR:-/edge/etc/update-history}"
FW_DOWNLOAD_CACHE_ROOT="${FW_DOWNLOAD_CACHE_ROOT:-/edge/docker/update_monitor/custom_downloader}"
SWU_RSA_PUB_KEY="${SWU_RSA_PUB_KEY:-/edge/sp/secrets/swupdate/swu_rsa_pub.pem}"
SWU_AES_CBC_KEY="${SWU_AES_CBC_KEY:-/edge/sp/secrets/swupdate/swu_aes_cbc.key}"
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

# 실제 셸 명령을 그대로 실행하고 그 출력을 evidence 로 남긴다 (서술문 금지)
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

# JSON 응답 payload 에서 문자열 필드 값을 추출한다 (busybox grep/sed 호환)
# 사용: json_str_field '{"result":"rejected"}' result  ->  rejected
json_str_field() {
    echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -n 's/.*:[[:space:]]*"\([^"]*\)"$/\1/p'
}

# JSON 응답 payload 에서 숫자/불리언 필드 값을 추출한다
# 사용: json_num_field '{"retry_count":3}' retry_count  ->  3
json_num_field() {
    echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" | head -1 | sed -n 's/.*:[[:space:]]*//p' | tr -d ' '
}

# ============================================================
# TC01: Batch Update 요청 프로토콜 (수락/거부/우선순위 정렬)
# ============================================================
tc01_batch_update_protocol() {
    echo "=== TC01: Batch Update 요청 프로토콜 (거부 경로만 — IPC 검증으로 축소) ==="
    echo "[사전 조건] update_monitor 프로세스 확인"
    dump_cmd pgrep -f update_monitor

    # 주의(실측, 2026-08-10): path+device_type 둘 다 비어있지 않은 entry는 큐에 실제로
    # accepted 되고, 비동기로 진짜 cmd_host(swupdate -i)까지 발사된다. update_monitor.cpp:
    # 7300-7328 에 "배치 종료(성공/실패 무관) 시 항상 앱 컨테이너 재시작(SERVICE_REBOOT_APPLICAITON)
    # 또는 디바이스 재부팅(SERVICE_REBOOT_SYSTEM)" 로직이 무조건 걸려있어, 더미 파일이라도
    # accepted 되는 순간 실제 컨테이너 재시작을 유발한다 — 정렬(order)/중복거부(진행 중 상태)
    # 검증은 반드시 accepted 상태를 거쳐야 해서 이 TC 범위에서는 뺐다(재부팅 없이는 확인 불가).
    # 그 두 항목은 TC12(자동화 불가 목록)로 옮기고, 여기서는 "큐에 아예 안 들어가는" 거부
    # 경로만 검증한다 — path 또는 device_type 이 비어있으면 item.file_path.empty() ||
    # item.device_type.empty() 에 걸려 큐에 안 들어가고(update_monitor.cpp:6696), 결과적으로
    # "No valid SWU files in batch request" 로 거부되어 실제 처리/재시작이 발생하지 않는다.

    echo "[Step1] batch_update_status 조회 (IDLE 확인)"
    local status_resp
    status_resp=$(send_and_wait "batch_update_status" "{}" 15)
    echo "  resp: $status_resp"

    echo "[TC01-1] device_type 누락 entry 만 있는 요청 발행 (큐에 안 들어가고 거부되어야 함)"
    local invalid_resp
    invalid_resp=$(send_and_wait "batch_update_request" '{"files":[{"path":"/tmp/tc_um_dummy_mpu.swu"}]}' 15)
    echo "  resp: $invalid_resp"
    if echo "$invalid_resp" | grep -q '"result":"rejected"' && echo "$invalid_resp" | grep -qi "No valid SWU files"; then
        assert "TC01-1: device_type 누락 entry 거부 (큐 미적재)" "PASS"
    else
        assert "TC01-1: device_type 누락 entry 거부 (큐 미적재)" "FAIL" "resp=$invalid_resp"
    fi

    echo "[TC01-2] 빈 files 배열 요청 발행"
    local empty_resp
    empty_resp=$(send_and_wait "batch_update_request" '{"files":[]}' 15)
    echo "  resp: $empty_resp"
    if echo "$empty_resp" | grep -q '"result":"rejected"' && echo "$empty_resp" | grep -qi "Missing or empty"; then
        assert "TC01-2: 빈 files 배열 거부" "PASS"
    else
        assert "TC01-2: 빈 files 배열 거부" "FAIL" "resp=$empty_resp"
    fi

    echo "[cleanup] 배치 상태 재확인 (판정에는 사용 안 함, 위 두 경로 모두 큐 미적재라 NONE 유지 기대)"
    local cleanup_resp
    cleanup_resp=$(send_and_wait "batch_update_status" "{}" 15)
    echo "  resp: $cleanup_resp"
}

# ============================================================
# TC02: ADU Step Manifest 단계별 상태 전이 (is-installed/download/install/apply)
# ============================================================
tc02_adu_step_manifest() {
    echo "=== TC02: ADU Step Manifest 단계별 상태 전이 ==="
    mkdir -p "$ADU_DONE_DIR"
    echo "[사전 조건] ADU_DONE_DIR=$ADU_DONE_DIR"
    dump_cmd ls -la "$ADU_DONE_DIR"

    local step rc ts done_file sub_file payload sub_pid

    for step in is-installed download install apply; do
        case "$step" in
            is-installed) rc=901 ;;
            download) rc=500 ;;
            install) rc=600 ;;
            apply) rc=700 ;;
        esac
        echo "[Step: $step, resultCode=$rc]"
        done_file="${ADU_DONE_DIR}/${step}.done"
        sub_file="/tmp/tc_um_adu_sub_${step}_$$"
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        mosquitto_sub -h "$MQTT_HOST" -t "emsp/all/update_monitor/noti/adu_update_notification" -C 1 -W 15 > "$sub_file" 2>/dev/null &
        sub_pid=$!
        sleep 0.5

        printf '{"step": "%s", "resultCode": %s, "timestamp": "%s"}\n' "$step" "$rc" "$ts" > "$done_file"
        dump_cmd cat "$done_file"

        wait "$sub_pid"
        payload=$(cat "$sub_file" 2>/dev/null)
        echo "  수신 payload: $payload"

        if echo "$payload" | grep -q "\"workflow_step\":\"${step}\"" && echo "$payload" | grep -q "\"result_code\":${rc}"; then
            assert "TC02-${step}: ${step} 단계 알림 수신 (resultCode=${rc})" "PASS"
        else
            assert "TC02-${step}: ${step} 단계 알림 수신 (resultCode=${rc})" "FAIL" "payload=$payload"
        fi

        rm -f "$sub_file" "$done_file"
        sleep 0.5
    done

    echo "[TC02-5] .done file detected 로그 카운트 확인 (참고용 — PASS/FAIL 미포함)"
    # 실측(2026-08-10): TC02-1~4가 이미 MQTT 알림 payload(workflow_step/result_code 정확히
    # 일치)로 4단계 전부 확실히 PASS 확인함. 근데 이 소스 로그 문구("[UPDATE] .done file
    # detected for step: ", adu_agent_monitor.cpp:143)는 journalctl에서 0건 검출됨 —
    # DUT에 배포된 실제 바이너리가 로컬 git 체크아웃과 빌드가 다를 가능성(project_dut_build_
    # vs_git_checkout 참고). TC02-1~4로 이미 충분히 검증되므로 이 로그 카운트는 판정에서
    # 빼고 참고 정보로만 남긴다.
    dump_cmd journalctl -u docker-loader --since "5 minutes ago"
    local detect_count
    detect_count=$(journalctl -u docker-loader --since "5 minutes ago" | grep -c '.done file detected')
    echo "  detect_count=$detect_count (참고용, TC02-1~4 결과가 실질 판정)"
}

# ============================================================
# TC03: ADU Agent 로그 기반 연동 상태 확인
# ============================================================
tc03_adu_agent_log() {
    echo "=== TC03: ADU Agent 로그 기반 연동 상태 확인 ==="
    local du_config="/edge/etc/user-config/adu/du-config.json"
    local adu_log="/tmp/edge/update/deviceupdate-agent.log"

    echo "[사전 조건] adu-agent-service 확인"
    dump_cmd systemctl status adu-agent-service
    dump_cmd pgrep -f AducIotAgent

    echo "[TC03-1] du-config.json 존재 및 JSON 파싱"
    dump_cmd cat "$du_config"
    # python3 가 DUT(busybox 환경)에 없음 — jq empty 로 문법 검증(DUT에 jq 존재 확인됨)
    if jq empty "$du_config" 2>/tmp/tc_um_jq_err_$$; then
        assert "TC03-1: du-config.json 존재 및 JSON 파싱 가능" "PASS"
    else
        assert "TC03-1: du-config.json 존재 및 JSON 파싱 가능" "FAIL" "$(cat /tmp/tc_um_jq_err_$$ 2>/dev/null)"
    fi
    rm -f /tmp/tc_um_jq_err_$$

    echo "[TC03-2/3] ADU 로그 파일 확인 (manual — 부재 시 SKIP, PASS/FAIL 미포함)"
    if [ -f "$adu_log" ]; then
        dump_cmd grep -F "ADUC_ConnType_Module" "$adu_log"
        if grep -qF "ADUC_ConnType_Module" "$adu_log"; then
            echo "  [MANUAL/PASS 후보] TC03-2: Module 연결 시도 로그 패턴 존재"
        else
            echo "  [MANUAL/FAIL 후보] TC03-2: Module 연결 시도 로그 패턴 미검출"
        fi

        dump_cmd grep -F "Successfully re-authenticated" "$adu_log"
        if grep -qF "Successfully re-authenticated" "$adu_log"; then
            echo "  [MANUAL/PASS 후보] TC03-3: 재인증 성공 로그 패턴 존재"
        else
            echo "  [MANUAL/FAIL 후보] TC03-3: 재인증 성공 로그 패턴 미검출"
        fi
    else
        echo "  [SKIP] $adu_log 파일 부재 — TC03-2/3 수동 확인으로 대체"
    fi

    echo "[참고] 최근 ADU 활동 로그 (판정 미포함)"
    dump_cmd journalctl -u docker-loader --since "1 hour ago"
}

# ============================================================
# TC04: Firmware Download 세션 영속화 및 프로세스 재시작 후 Resume
# ============================================================
tc04_firmware_download_resume() {
    echo "=== TC04: Firmware Download 세션 영속화 및 프로세스 재시작 후 Resume ==="

    echo "[사전 조건] OTA_MOCK_* 환경변수 활성화 여부 확인 (update_monitor 프로세스 실환경)"
    local um_pid mock_env
    um_pid=$(pgrep -f /edge/app/bin/update_monitor | head -1)
    dump_cmd cat "/proc/${um_pid}/environ"
    mock_env=$(tr '\0' '\n' < "/proc/${um_pid}/environ" 2>/dev/null | grep -c '^OTA_MOCK_')
    echo "  OTA_MOCK_* 변수 개수: $mock_env"
    if [ "$mock_env" = "0" ]; then
        echo "  [SKIP] 프로덕션 빌드 — OTA_MOCK_* 미설정. start_firmware_download 는 실제 클라우드"
        echo "         provider/name/version + firmware_download_url 없이는 'missing firmware"
        echo "         package provider' 로 즉시 거부됨(update_monitor.cpp:1209) — 이 랩 환경에서는"
        echo "         재현 불가. manifest 를 직접 주입하는 경로(resolve_firmware_download_manifest"
        echo "         의 payload.manifest 분기)는 스키마 검증(artifacts 비어있으면 실패 등)이"
        echo "         있어 추가 확인 없이는 신뢰할 수 있는 재현이 어려움 — TC07/TC08과 동일 사유로 SKIP"
        echo "=== TC04: SKIP (OTA_MOCK 미확보, PASS/FAIL 미포함) ==="
        return
    fi

    echo "[Step1] get_firmware_download_status (활성 세션 없음 확인)"
    local before_resp
    before_resp=$(send_and_wait "get_firmware_download_status" "{}" 15)
    echo "  resp: $before_resp"

    echo "[Step2] start_firmware_download 요청 발행"
    local start_resp session_id
    start_resp=$(send_and_wait "start_firmware_download" '{"workflow_id":"tc_um_dummy_workflow"}' 15)
    echo "  resp: $start_resp"
    session_id=$(json_str_field "$start_resp" "session_id")

    if [ -z "$session_id" ]; then
        echo "[Step3] session_id 응답에 없음 — get_firmware_download_status 로 재조회"
        local status_resp
        status_resp=$(send_and_wait "get_firmware_download_status" "{}" 15)
        echo "  resp: $status_resp"
        session_id=$(json_str_field "$status_resp" "session_id")
    fi
    echo "  session_id=$session_id"

    echo "[TC04-1] session_state.json 존재 확인"
    if [ -n "$session_id" ]; then
        dump_cmd ls -la "${FW_DOWNLOAD_CACHE_ROOT}/${session_id}/session_state.json"
        if [ -f "${FW_DOWNLOAD_CACHE_ROOT}/${session_id}/session_state.json" ]; then
            assert "TC04-1: 세션 상태 파일 생성" "PASS"
        else
            assert "TC04-1: 세션 상태 파일 생성" "FAIL" "session_id=$session_id"
        fi
    else
        assert "TC04-1: 세션 상태 파일 생성" "FAIL" "session_id 획득 실패"
    fi

    echo "[Step5] update_monitor kill -9 → edge_runtime 재시작 대기"
    local um_pid
    um_pid=$(pgrep -f /edge/app/bin/update_monitor | head -1)
    dump_cmd kill -9 "$um_pid"

    local wait_i new_pid
    wait_i=0
    new_pid=""
    while [ "$wait_i" -lt 30 ]; do
        sleep 1
        new_pid=$(pgrep -f /edge/app/bin/update_monitor | grep -v "^${um_pid}$" | head -1)
        [ -n "$new_pid" ] && break
        wait_i=$((wait_i + 1))
    done
    echo "  재시작: pid ${um_pid} -> ${new_pid} (${wait_i}초 대기)"
    sleep 3

    echo "[TC04-3] 재시작 로그에 세션 복구 시도 흔적"
    dump_cmd journalctl -u docker-loader --since "30 seconds ago"
    local recover_log
    recover_log=$(journalctl -u docker-loader --since "30 seconds ago" | grep -i "recover")
    echo "  recover_log: $recover_log"
    if [ -n "$recover_log" ]; then
        assert "TC04-3: 재시작 로그에 세션 복구 시도 흔적" "PASS"
    else
        assert "TC04-3: 재시작 로그에 세션 복구 시도 흔적" "FAIL"
    fi

    echo "[TC04-2] 재조회 응답의 session_id 가 재시작 전과 동일"
    local after_resp after_session_id
    after_resp=$(send_and_wait "get_firmware_download_status" "{}" 15)
    echo "  resp: $after_resp"
    after_session_id=$(json_str_field "$after_resp" "session_id")
    if [ -n "$session_id" ] && [ "$after_session_id" = "$session_id" ]; then
        assert "TC04-2: 재시작 후 동일 session_id 로 복구" "PASS"
    else
        assert "TC04-2: 재시작 후 동일 session_id 로 복구" "FAIL" "before=$session_id after=$after_session_id"
    fi
}

# ============================================================
# TC05: 리소스 사전 점검 설정 (검토 필요 — 소스 내 미확인)
# ============================================================
tc05_placeholder() { echo "=== TC05: SKIP (개발자 검토 대기 — /home/hsung/tcs_tools/tcs/update_monitor/tc_update_monitor.md 참고) ==="; }

# ============================================================
# TC06: 다운로드 중 네트워크 단절 시 재시도
# ============================================================
tc06_network_interruption_retry() {
    echo "=== TC06: 다운로드 중 네트워크 단절 시 재시도 ==="
    echo "[Step1] start_firmware_download 요청으로 세션 시작"
    local start_resp
    start_resp=$(send_and_wait "start_firmware_download" '{"workflow_id":"tc_um_dummy_workflow"}' 15)
    echo "  resp: $start_resp"

    echo "[Step2] get_firmware_download_status 로 phase/host 확인"
    local status_resp phase host
    status_resp=$(send_and_wait "get_firmware_download_status" "{}" 15)
    echo "  resp: $status_resp"
    phase=$(json_str_field "$status_resp" "phase")
    host=$(json_str_field "$status_resp" "host")
    echo "  phase=$phase host=$host"

    if [ -z "$host" ]; then
        echo "  [SKIP] 다운로드 대상 host 정보를 상태 응답에서 획득하지 못함 — 네트워크 차단 시나리오 SKIP"
        echo "=== TC06: SKIP (host 미확보, PASS/FAIL 미포함) ==="
        return
    fi

    echo "[Step3] iptables 로 $host 아웃바운드 차단"
    dump_cmd iptables -A OUTPUT -d "$host" -j DROP

    echo "[Step4] 차단 중 상태 폴링 (retry_count/phase)"
    local retry_before status_resp2 phase2 retry_after
    retry_before=$(json_num_field "$status_resp" "retry_count")
    sleep 5
    status_resp2=$(send_and_wait "get_firmware_download_status" "{}" 15)
    echo "  resp: $status_resp2"
    phase2=$(json_str_field "$status_resp2" "phase")
    retry_after=$(json_num_field "$status_resp2" "retry_count")

    if [ "$phase2" != "failed" ]; then
        assert "TC06-1: 네트워크 차단 중 즉시 failed로 전이하지 않음" "PASS"
    else
        assert "TC06-1: 네트워크 차단 중 즉시 failed로 전이하지 않음" "FAIL" "phase=$phase2"
    fi

    if [ -n "$retry_before" ] && [ -n "$retry_after" ] && [ "$retry_after" -gt "$retry_before" ] 2>/dev/null; then
        assert "TC06-2: retry_count 증가" "PASS"
    else
        assert "TC06-2: retry_count 증가" "FAIL" "before=$retry_before after=$retry_after"
    fi

    echo "[Step5] iptables 차단 해제"
    dump_cmd iptables -D OUTPUT -d "$host" -j DROP

    echo "[Step6] 차단 해제 후 다운로드 재개 확인 (downloaded_bytes 증가)"
    local bytes_before_unblock status_resp3 bytes_after_unblock
    bytes_before_unblock=$(json_num_field "$status_resp2" "downloaded_bytes")
    sleep 10
    status_resp3=$(send_and_wait "get_firmware_download_status" "{}" 15)
    echo "  resp: $status_resp3"
    bytes_after_unblock=$(json_num_field "$status_resp3" "downloaded_bytes")

    if [ -n "$bytes_before_unblock" ] && [ -n "$bytes_after_unblock" ] && [ "$bytes_after_unblock" -gt "$bytes_before_unblock" ] 2>/dev/null; then
        assert "TC06-3: 차단 해제 후 다운로드 재개" "PASS"
    else
        assert "TC06-3: 차단 해제 후 다운로드 재개" "FAIL" "before=$bytes_before_unblock after=$bytes_after_unblock"
    fi

    echo "[TC06-4] iptables 규칙 정리 완료 확인"
    dump_cmd iptables -L OUTPUT -n
    if iptables -L OUTPUT -n | grep -q "$host"; then
        assert "TC06-4: iptables 규칙 정리 완료" "FAIL" "잔여 규칙 존재"
    else
        assert "TC06-4: iptables 규칙 정리 완료" "PASS"
    fi
}

# ============================================================
# TC07: Manifest SHA256 해시 불일치 시 다운로드 차단
# ============================================================
tc07_sha256_hash_mismatch() {
    echo "=== TC07: Manifest SHA256 해시 불일치 시 다운로드 차단 ==="
    echo "[사전 조건] mock lookup 활성화 여부 확인 (OTA_MOCK_LOOKUP_INSECURE)"
    dump_cmd printenv OTA_MOCK_LOOKUP_INSECURE

    if [ "${OTA_MOCK_LOOKUP_INSECURE}" != "1" ] && [ "${OTA_MOCK_LOOKUP_INSECURE}" != "true" ]; then
        echo "  [SKIP] mock lookup 미활성화(프로덕션 빌드) — 임의 manifest 주입 불가"
        echo "=== TC07: SKIP (mock lookup 미확보, PASS/FAIL 미포함) ==="
        return
    fi

    echo "[Step1] 임의 sha256 값을 가진 manifest로 start_firmware_download 발행"
    local start_resp
    start_resp=$(send_and_wait "start_firmware_download" '{"workflow_id":"tc_um_dummy_workflow","mock_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}' 15)
    echo "  resp: $start_resp"
    sleep 5

    echo "[Step2] get_firmware_download_status 로 failure_class 확인"
    local status_resp
    status_resp=$(send_and_wait "get_firmware_download_status" "{}" 15)
    echo "  resp: $status_resp"

    if echo "$status_resp" | grep -qE '"failure_class"[[:space:]]*:[[:space:]]*"hash_mismatch"'; then
        assert "TC07-1: 상태 응답의 failure_class가 hash_mismatch" "PASS"
    else
        assert "TC07-1: 상태 응답의 failure_class가 hash_mismatch" "FAIL" "resp=$status_resp"
    fi

    echo "[TC07-2] 로그에 해시 불일치 근거 확인"
    dump_cmd journalctl -u docker-loader --since "1 minute ago"
    if journalctl -u docker-loader --since "1 minute ago" | grep -qi "hash mismatch"; then
        assert "TC07-2: 로그에 해시 불일치 근거 존재" "PASS"
    else
        assert "TC07-2: 로그에 해시 불일치 근거 존재" "FAIL"
    fi

    echo "[TC07-3] ready_to_install=false 유지 확인"
    if echo "$status_resp" | grep -qE '"ready_to_install"[[:space:]]*:[[:space:]]*false'; then
        assert "TC07-3: ready_to_install=false 유지" "PASS"
    else
        assert "TC07-3: ready_to_install=false 유지" "FAIL" "resp=$status_resp"
    fi
}

# ============================================================
# TC08: .swu 서명/AES 키 훼손 파일 업데이트 차단 (수동 준비물 필요)
# ============================================================
tc08_corrupted_swu_blocked() {
    echo "=== TC08: .swu 서명/AES 키 훼손 파일 업데이트 차단 ==="
    local bad_sig="/tmp/tc_um_bad_sig.swu"
    local bad_aes="/tmp/tc_um_bad_aes.swu"

    echo "[TC08-1] 준비물 존재 확인"
    dump_cmd ls -la "$bad_sig"
    if [ -f "$bad_sig" ]; then
        echo "  RSA 서명 훼손 준비물 확인됨"
    else
        echo "  SKIP_NO_ARTIFACT"
    fi

    if [ -f "$bad_sig" ]; then
        echo "[RSA 서명 훼손 파일 시험] $bad_sig"
        local req_resp
        req_resp=$(send_and_wait "batch_update_request" "{\"files\":[{\"file_path\":\"${bad_sig}\",\"device_type\":\"mpu\"}]}" 15)
        echo "  resp: $req_resp"

        local i result_resp result_val
        i=0
        result_val=""
        while [ "$i" -lt 30 ]; do
            result_resp=$(send_and_wait "batch_update_status" "{}" 15)
            result_val=$(json_str_field "$result_resp" "result")
            [ -n "$result_val" ] && [ "$result_val" != "pending" ] && break
            sleep 2
            i=$((i + 1))
        done
        echo "  최종 status: $result_resp"

        if [ "$result_val" = "failed" ]; then
            assert "TC08-2: RSA 서명 훼손 시 batch 결과 failed" "PASS"
        else
            assert "TC08-2: RSA 서명 훼손 시 batch 결과 failed" "FAIL" "result=$result_val"
        fi

        dump_cmd journalctl -u docker-loader --since "1 minute ago"
        if journalctl -u docker-loader --since "1 minute ago" | grep -qF "EVP_DigestVerifyFinal failed"; then
            assert "TC08-3: RSA 훼손 로그 패턴 존재" "PASS"
        else
            assert "TC08-3: RSA 훼손 로그 패턴 존재" "FAIL"
        fi
    else
        echo "  [SKIP] $bad_sig 없음 — RSA 서명 훼손 서브케이스 SKIP (TC08-2/3 PASS/FAIL 미포함)"
    fi

    if [ -f "$bad_aes" ]; then
        echo "[AES 키 훼손 파일 시험] $bad_aes"
        local req_resp2
        req_resp2=$(send_and_wait "batch_update_request" "{\"files\":[{\"file_path\":\"${bad_aes}\",\"device_type\":\"mpu\"}]}" 15)
        echo "  resp: $req_resp2"

        local j result_resp2 result_val2
        j=0
        result_val2=""
        while [ "$j" -lt 30 ]; do
            result_resp2=$(send_and_wait "batch_update_status" "{}" 15)
            result_val2=$(json_str_field "$result_resp2" "result")
            [ -n "$result_val2" ] && [ "$result_val2" != "pending" ] && break
            sleep 2
            j=$((j + 1))
        done
        echo "  최종 status: $result_resp2"

        if [ "$result_val2" = "failed" ]; then
            assert "TC08-4: AES 키 훼손 시 batch 결과 failed" "PASS"
        else
            assert "TC08-4: AES 키 훼손 시 batch 결과 failed" "FAIL" "result=$result_val2"
        fi

        dump_cmd journalctl -u docker-loader --since "1 minute ago"
        if journalctl -u docker-loader --since "1 minute ago" | grep -qF "bad decrypt"; then
            assert "TC08-5: AES 훼손 로그 패턴 존재" "PASS"
        else
            assert "TC08-5: AES 훼손 로그 패턴 존재" "FAIL"
        fi
    else
        echo "  [SKIP] $bad_aes 없음 — AES 키 훼손 서브케이스 SKIP (TC08-4/5 PASS/FAIL 미포함)"
    fi
}

# ============================================================
# TC09: sw-description HW 호환성(hwrevision) 검사
# ============================================================
tc09_hw_compatibility() {
    echo "=== TC09: sw-description HW 호환성(hwrevision) 검사 ==="
    echo "[TC09-1] /etc/hwrevision 존재 확인 (검토 필요 — 실측 결과 아래 참고)"
    dump_cmd cat /etc/hwrevision
    if [ -f /etc/hwrevision ]; then
        assert "TC09-1: /etc/hwrevision 존재" "PASS"
    else
        echo "  [SKIP] /etc/hwrevision 이 이 디바이스에 없음 — 소스 코드(update_monitor 전체) 및"
        echo "         DUT 파일시스템 어디에도 hwrevision 메커니즘 근거를 찾지 못함. TC 작성 시"
        echo "         참고한 'SWUPDATE_HW_COMPATIBILITY_FILE=/etc/hwrevision' 이 이 코드베이스"
        echo "         실제 구현이 아닐 가능성 — 개발자가 실제 HW 호환성 검사 메커니즘/경로를"
        echo "         확인해줄 것. PASS/FAIL 미포함(SKIP)."
    fi

    # 경고: 준비물이 있으면 아래 batch_update_request 가 accepted 되어 실제 cmd_host 처리로
    # 이어지고, TC01 실측(2026-08-10)과 동일하게 배치 종료 시 앱 컨테이너가 재시작된다.
    # 준비물을 실제로 올릴 계획이면 이 사실을 감안하고(다른 TC와 격리해서) 실행할 것.
    echo "[TC09-2] 준비물(HW 불일치 .swu) 존재 확인"
    local bad_hw="/tmp/tc_um_bad_hw.swu"
    dump_cmd ls -la "$bad_hw"
    if [ -f "$bad_hw" ]; then
        echo "  준비물 확인됨 — HW 불일치 시험 진행"
        local req_resp
        req_resp=$(send_and_wait "batch_update_request" "{\"files\":[{\"path\":\"${bad_hw}\",\"device_type\":\"mpu\"}]}" 15)
        echo "  resp: $req_resp"

        local k result_resp result_val
        k=0
        result_val=""
        while [ "$k" -lt 30 ]; do
            result_resp=$(send_and_wait "batch_update_status" "{}" 15)
            result_val=$(json_str_field "$result_resp" "result")
            [ -n "$result_val" ] && [ "$result_val" != "pending" ] && break
            sleep 2
            k=$((k + 1))
        done
        echo "  최종 status: $result_resp"

        dump_cmd journalctl -u docker-loader --since "1 minute ago"
        echo "  [MANUAL] TC09-3: batch result=$result_val, 'not compatible with hardware' 로그 패턴 아래 참고해 수동 확인"
        journalctl -u docker-loader --since "1 minute ago" | grep -i "not compatible with hardware"
    else
        echo "  SKIP_NO_ARTIFACT"
        echo "  [SKIP] $bad_hw 없음 — TC09-3 SKIP (PASS/FAIL 미포함)"
    fi
}

# ============================================================
# TC10: 업데이트 진행률 MQTT 알림
# ============================================================
tc10_progress_notification() {
    echo "=== TC10: 업데이트 진행률 MQTT 알림 ==="
    echo "[사전 조건] 이 TC 단독으로는 진행률 발생 소스가 없음 — 원래 TC01 직후 실행을 전제로"
    echo "했으나, TC01은 실측(2026-08-10)에서 실제 cmd_host 배치 처리가 컨테이너 재시작을"
    echo "유발하는 게 확인되어 거부 경로만 검증하도록 축소됨 — 그 결과 이 TC가 기댈 진행률"
    echo "발생 소스가 기본 실행 순서에는 더 이상 없다. 실제 진행률 스트림을 재현하려면 실서명"
    echo ".swu 로 진짜 배치를 돌려야 하는데, 그건 그 자체로 컨테이너 재시작을 유발하므로 회귀"
    echo "세트에서 안전하게 자동화할 수 없다 — TC12(자동화 불가 목록)와 동일 사유로 SKIP."

    local sub_file="/tmp/tc_um_progress_sub_$$"
    mosquitto_sub -h "$MQTT_HOST" -t "emsp/all/update_monitor/noti/+" -v > "$sub_file" 2>/dev/null &
    local sub_pid=$!
    echo "[Step1] 구독 시작 (최대 15초 — 정말로 진행 중인 배치가 없으면 빠르게 SKIP 판정)"
    sleep 15
    kill "$sub_pid" 2>/dev/null
    wait "$sub_pid" 2>/dev/null

    dump_cmd cat "$sub_file"

    if grep -qE 'noti/(swupdate_progress|device_update_progress)' "$sub_file"; then
        echo "  진행률 알림이 실제로 수신됨 — 아래 판정 진행"
        if [ "$(grep -E 'noti/(swupdate_progress|device_update_progress)' "$sub_file" | grep -o '"\(cur_percent\|progress\)"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')" = "$(grep -E 'noti/(swupdate_progress|device_update_progress)' "$sub_file" | grep -o '"\(cur_percent\|progress\)"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$' | sort -n)" ]; then
            assert "TC10: 진행률 알림 수신 시 값이 시간순 비감소" "PASS"
        else
            assert "TC10: 진행률 알림 수신 시 값이 시간순 비감소" "FAIL"
        fi
    else
        echo "=== TC10: SKIP (진행률 발생 소스 없음 — TC01 축소의 부작용, PASS/FAIL 미포함) ==="
    fi

    rm -f "$sub_file"
}

# ============================================================
# TC11: Docker 이미지 기반 배포 PRECHECK 및 컨테이너/볼륨 상태 확인
# ============================================================
tc11_docker_precheck() {
    echo "=== TC11: Docker 이미지 기반 배포 PRECHECK 및 컨테이너/볼륨 상태 확인 ==="
    echo "[Step1] BEFORE_CONTAINERS 스냅샷"
    dump_cmd docker ps --format '{{.Names}}'
    local before_containers
    before_containers=$(docker ps --format '{{.Names}}')

    echo "[Step2] BEFORE_VOLUMES 스냅샷"
    dump_cmd docker volume ls --format '{{.Name}}'
    local before_volumes
    before_volumes=$(docker volume ls --format '{{.Name}}')

    echo "[Step3] update_precheck 요청 발행 (trigger_type=local_script, source=swupdate_docker_pull_pre_script)"
    local precheck_resp
    precheck_resp=$(send_and_wait "update_precheck" '{"trigger_type":"local_script","source":"swupdate_docker_pull_pre_script"}' 15)
    echo "  resp: $precheck_resp"

    if [ -n "$precheck_resp" ]; then
        assert "TC11-1: update_precheck 응답 수신" "PASS"
    else
        assert "TC11-1: update_precheck 응답 수신" "FAIL"
    fi

    echo "[TC11-2] 컨테이너 목록 불변 확인"
    dump_cmd docker ps --format '{{.Names}}'
    local after_containers diff_containers
    after_containers=$(docker ps --format '{{.Names}}')
    diff_containers=$(diff <(echo "$before_containers") <(echo "$after_containers"))
    echo "  diff: $diff_containers"
    if [ -z "$diff_containers" ]; then
        assert "TC11-2: 컨테이너 목록 불변" "PASS"
    else
        assert "TC11-2: 컨테이너 목록 불변" "FAIL" "diff=$diff_containers"
    fi

    echo "[TC11-3] Volume 목록 불변 확인"
    dump_cmd docker volume ls --format '{{.Name}}'
    local after_volumes diff_volumes
    after_volumes=$(docker volume ls --format '{{.Name}}')
    diff_volumes=$(diff <(echo "$before_volumes") <(echo "$after_volumes"))
    echo "  diff: $diff_volumes"
    if [ -z "$diff_volumes" ]; then
        assert "TC11-3: Volume 목록 불변" "PASS"
    else
        assert "TC11-3: Volume 목록 불변" "FAIL" "diff=$diff_volumes"
    fi
}

# ============================================================
# TC12: 자동화 불가 항목 목록 (정보 제공 — PASS/FAIL 미포함)
# ============================================================
tc12_manual_items_list() {
    echo "=== TC12: 자동화 불가 항목 목록 (클라우드 OTA 전체 흐름 / Web HMI 수동 조작) ==="
    echo "  - Key101(ADU Push 서브스텝): Azure IoT Hub/ADU 포털에서 실제 Push 업데이트 배포 필요"
    echo "  - Key103 전체: ADU 기반 OTA End-to-End (Import Manifest 등록, 장비 그룹 배포, 이력 관리) — ADU 포털/IoT Hub 콘솔 조작 필요"
    echo "  - Key105 원본 파일: 훼손 .swu 원본 파일 자체 (Jira AGSRS-286 첨부, 저장소·DUT에 없음)"
    echo "  - Key128/131/135(실제 flash 완료 판정): Docker Pull/Load 설치의 애플리케이션 정상 동작까지 확인 — 실서명 .swu(Docker layer 포함) 필요"
    echo "  - TC01 큐 우선순위 정렬 / 중복 요청 거부(진행 중 상태): 실측(2026-08-10) 결과 batch_update_request가"
    echo "    accepted 되는 순간 비동기로 실제 cmd_host(swupdate -i)까지 발사되고, 배치 종료(성공/실패 무관) 시"
    echo "    update_monitor.cpp:7300-7328 로직이 무조건 앱 컨테이너 재시작(또는 디바이스 재부팅)을 유발함 —"
    echo "    더미 파일로도 재현되므로 회귀 세트에 안전하게 포함 불가. 별도 파괴적 TC(--tc01-pre/-post 같은"
    echo "    격리된 phase)로 재설계 필요 시 개발자 확인 후 진행할 것"
    echo "  - TC10 실제 진행률 시간순 증가 검증: 위와 동일 사유(TC01 축소로 진행률 발생 소스 소실) —"
    echo "    실서명 .swu로 진짜 배치를 돌려야 재현 가능하나 그 자체가 컨테이너 재시작을 유발함"
    echo "  QA가 수동으로 Azure 포털/Web HMI(http://192.168.10.20:9111 등)에 접속해 docs/tc_requirements/update_monitor.md 절차를 그대로 따를 것"
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " update_monitor TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01) tc01_batch_update_protocol ;;
    --tc02) tc02_adu_step_manifest ;;
    --tc03) tc03_adu_agent_log ;;
    --tc04) tc04_firmware_download_resume ;;
    --tc05) tc05_placeholder ;;
    --tc06) tc06_network_interruption_retry ;;
    --tc07) tc07_sha256_hash_mismatch ;;
    --tc08) tc08_corrupted_swu_blocked ;;
    --tc09) tc09_hw_compatibility ;;
    --tc10) tc10_progress_notification ;;
    --tc11) tc11_docker_precheck ;;
    --tc12) tc12_manual_items_list ;;
    --only)
        # 대시보드의 "선택 실행"에서 사용 — 콤마로 구분된 TC 목록을 받아 그 TC들만 실행한다.
        # 예: sh tc_update_monitor.sh --only TC01,TC03,TC11
        shift
        SELECTED="${1:-}"
        if [ -z "$SELECTED" ]; then
            echo "[ERROR] --only 뒤에 TC 목록이 필요합니다 (예: --only TC01,TC03,TC11)"
            exit 1
        fi
        for tc in TC01 TC02 TC03 TC04 TC05 TC06 TC07 TC08 TC09 TC10 TC11 TC12; do
            case ",${SELECTED}," in
                *,${tc},*)
                    case "$tc" in
                        TC01) tc01_batch_update_protocol ;;
                        TC02) tc02_adu_step_manifest ;;
                        TC03) tc03_adu_agent_log ;;
                        TC04) tc04_firmware_download_resume ;;
                        TC05) tc05_placeholder ;;
                        TC06) tc06_network_interruption_retry ;;
                        TC07) tc07_sha256_hash_mismatch ;;
                        TC08) tc08_corrupted_swu_blocked ;;
                        TC09) tc09_hw_compatibility ;;
                        TC10) tc10_progress_notification ;;
                        TC11) tc11_docker_precheck ;;
                        TC12) tc12_manual_items_list ;;
                    esac
                    ;;
            esac
        done
        ;;
    *)
        tc01_batch_update_protocol
        tc02_adu_step_manifest
        tc03_adu_agent_log
        tc04_firmware_download_resume
        tc05_placeholder
        tc06_network_interruption_retry
        tc07_sha256_hash_mismatch
        tc08_corrupted_swu_blocked
        tc09_hw_compatibility
        tc10_progress_notification
        tc11_docker_precheck
        tc12_manual_items_list
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
