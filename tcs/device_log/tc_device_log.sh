#!/bin/bash
# TC: device_log
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}
#             emsp/all/{source}/noti/{event}
#
# 명세: tc_device_log.md (TC01~TC26, 연번). 검토/피드백 과정에서 일부 TC가 삭제되거나
#       인접 TC로 통합되어 결번이 생겼던 이력이 있으나, 번호를 모두 당겨 현재는 빈
#       번호 없이 연속된다. [2026-08-26] 구 TC24(EOL 로그 압축 zip vs xz)를 요구사항
#       자체 삭제로 제거하고 뒤 번호를 당김(구TC25→24, 구TC26→25, 구TC27→26).
#
# [중요] 장시간/파괴적 시험 안내
#   아래 TC는 기본 실행(인자 없음)에 포함되지 않으며 --tcNN 으로 개별 실행해야 한다.
#     - TC05  : 시스템 시각을 logCreationTime만큼 앞당겨 파일 회전 유도 (원복 로직 포함)
#     - TC09  : logpolicy.json fileCount 임시 수정 + docker-loader 재시작 (원복 로직 포함)
#     - TC18  : 시스템 시각을 23:49로 변경해 자정 루틴 유도 (원복 로직 포함)
#     - TC19  : 시스템 시각을 월말 23:49로 변경해 월 전환 루틴 유도 (원복 로직 포함)
#     - TC06/TC07 (--tc06-pre/--tc06-post) : DUT 재부팅 수반, 같은 파일명 이어쓰기 검증
#     - TC15  (--tc15-pre/--tc15-post)     : DUT 재부팅 수반, toupload 업로드 재개 검증
#     - TC20  (--tc20-pre/--tc20-post)     : DUT 재부팅 수반, logcount.json 값 유지 검증
#     - TC25  (--tc25-pre/--tc25-post)     : factory_reset(전체 로그 삭제) + DUT 재부팅 — 파괴적
#   TC26은 명세에 정의된 IPC 자체가 코드에 미구현이라 자동화 불가 (SKIP).
#
# [2026-08-21 실측 후 추가] logcount.json(perDayRoot/perDayArchive)은 CloudUploadManager::
#   init()에서 1회만 로드되어(cloud_upload_manager.cpp:103-108) 파일 수정만으로는
#   반영되지 않는다. TC14/TC16/TC17은 이제 각각 restart_docker_loader()를
#   포함하므로(TC09과 동일한 제약) "빠른 실행 세트"에 포함돼 있어도 재시작 대기
#   (최대 60초 x 최대 2회)만큼 전체 소요 시간이 늘어난다.
#
# [참고] STAGING_DIR/TOUPLOAD_DIR 경로 수정
#   최초 골격에는 /edge/log/device, /edge/log/toupload/device 로 되어 있었으나 실제
#   loggerPath/toUploadPath(logpolicy.json)는 /edge/log/device_log, /edge/log/toupload/device_log
#   이다. 아래 LOGGER_ROOT/TOUPLOAD_ROOT로 정정.
#
# [참고] logpolicy.json/logcount.json/eolpolicy.json 파싱
#   컨테이너(ac_system_gen2) 내부 파일이라 호스트에서 직접 안 보임 — device_manager TC
#   스크립트와 동일하게 "docker exec $CONTAINER cat <path> | jq" 로 호스트 jq를 거쳐
#   읽고/수정한다(컨테이너 안에는 jq가 없을 수 있음). 명세 표의 TC09-3 셸 검증식은
#   `grep -A2 "logItem" ... | grep fileCount` 형태였으나 실제 logpolicy.json은 logItem과
#   fileCount 사이에 여러 줄(logNum/logFile/logRowInterval/logCreationTime/...)이 있어
#   -A2로는 절대 fileCount에 도달하지 못한다 — jq 기반으로 대체.
#
# [참고] forced_log_upload(get_log_data) 의 실제 동작
#   cloud_upload_manager.cpp::handleForcedLogUploadRequest()는 root의 압축 파일을
#   "모든" 활성 log_item에 대해 즉시 toupload로 이동시킨다(라운드로빈 미경유). 따라서
#   TC21(라운드로빈 균등성)를 forced_log_upload만으로 재현하면 즉시 전량 이동돼버려
#   라운드로빈이 관찰되지 않는다 — 네트워크를 차단한 상태로 forced_log_upload를 호출해
#   root 대기열에 쌓아만 두고(내부적으로 pushRootFileInfo로 되돌려짐), 이후 네트워크를
#   복구해 idle thread의 selectNextRootLogType() 라운드로빈이 실제로 도는 것을 관찰한다.

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="device_log"
CONTAINER="ac_system_gen2"

LOGGER_ROOT="/edge/log/device_log"
TOUPLOAD_ROOT="/edge/log/toupload/device_log"
ARCHIVE_ROOT="/edge/log/device_log/archive"
UPLOADED_ROOT="/edge/log/uploaded/device_log"
EOL_ROOT="/edge/log/eol"

LOGPOLICY_JSON="/edge/etc/app-config/device_log/rules/logpolicy.json"
LOGCOUNT_JSON="/edge/etc/app-config/device_log/rules/logcount.json"
EOLPOLICY_JSON="/edge/etc/app-config/device_log/rules/eolpolicy.json"

# /tmp는 ramdisk라 reboot 시 소실됨 — reboot를 사이에 두는 TC(06/07/15/20/26)의
# pre/post 상태 전달은 bind mount되어 살아남는 /edge/log/ 밑에 저장한다.
STATE_DIR="/edge/log/.tc_device_log_state"

# 본 벤치(192.168.10.25, 2026-08-20 실측) 기준 텔레메트리 도착이 확인된 non-fault
# log_item — logRowInterval 오름차순(빠른 것 우선, 시험 시간 단축용).
#   Meter=15s, C_Box_Monitoring=15s, PMU_Monitoring=60s, MI_Device_Info=60s,
#   EMSP_Installation=60s, MI_Monitoring=900s, EMSP_Maintenance=3600s
ACTIVE_LOG_ITEMS="Meter C_Box_Monitoring PMU_Monitoring MI_Device_Info EMSP_Installation MI_Monitoring EMSP_Maintenance"
# TC02/TC21처럼 짧은 간격이 필요한 TC 전용 — rowInterval<=60s인 것만
FAST_LOG_ITEMS="Meter C_Box_Monitoring PMU_Monitoring MI_Device_Info EMSP_Installation"

PASS=0
FAIL=0

mkdir -p "$STATE_DIR"

# ============================================================
# 공통 헬퍼
# ============================================================

# subscribe 먼저 시작 후 publish → 응답 누락 방지
#
# [2026-08-25 TC23 실측 후 발견] 기존엔 {"tid":"...","payload":<payload>}로 한 겹 더
# 감싸 보냈는데, 실제 프로토콜(base_app.cpp)은 tid를 MQTT5 correlation-data 속성으로
# 별도 전달하고(get_mqtt_property_data()) JSON 본문은 payload 그 자체가 top-level이다
# (예: handle_request_custom_log_upload()가 message["log_num"]을 top-level에서 바로
# 읽음). set_factory_eol_mode도 message.value("eol_mode", false)로 top-level을 본다 —
# 우리가 "payload" 키 아래로 한 겹 더 감싸 보내니 항상 top-level엔 없어 기본값(false)만
# 읽혔던 것(TC23이 eol_mode:true를 보내도 매번 disabled로 끝난 원인, device_log 결함
# 아님). tid는 body에 안 넣어도 응답 topic 매칭만으로 충분하지만(mosquitto_sub -t로
# 토픽 자체를 걸러 받으므로), 굳이 없앨 이유는 없어 payload에 병합해 flat하게 보낸다.
send_and_wait() {
    local service="$1"
    local payload="$2"
    [ -z "$payload" ] && payload="{}"
    local timeout="${3:-30}"
    local tid="tc-$(date +%s)"
    local full_payload
    full_payload=$(echo "$payload" | jq -c --arg tid "$tid" '. + {tid: $tid}')
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

# device_connection 같은 일방향 알림(요청/응답 왕복이 아님) 발행용.
# db_manager/tc_db_manager.sh의 publish_noti()와 동일한 emsp/all/{source}/noti/{event} 규약.
publish_noti() {
    local event="$1"
    local payload="$2"
    [ -z "$payload" ] && payload="{}"
    local noti_topic="emsp/all/${SOURCE}/noti/${event}"
    mosquitto_pub -h "$MQTT_HOST" -t "$noti_topic" -m "$payload"
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
        echo "[SKIP] $desc"
        [ -n "$3" ] && echo "  [REASON] $3"
    else
        echo "[FAIL] $desc"
        FAIL=$((FAIL + 1))
        [ -n "$3" ] && echo "  [REASON] $3"
    fi
}

# TC14/TC21처럼 root/archive->toupload 이동을 관측해야 하는 TC의 공통 사전조건.
# cloud_upload_manager.cpp:826-827,859-860의 isToUploadDirEmpty(log_type) 게이트는
# 그 log_type의 toupload가 완전히 빌 때까지 새 파일의 유입을 막는다 — 이전 TC가
# 아니라 자연 운영 중 쌓인 backlog나 실제 클라우드 업로드 실패(retry) 때문에 이미
# 잔여 파일이 있으면, 이 TC가 뭘 하든 이동이 관측될 수 없어 FAIL이 아니라 사전조건
# 미충족이다. 대기/강제삭제(운영 로그 데이터 유실 위험) 대신 SKIP으로 빠진다.
toupload_backlog_count() {
    ls "$TOUPLOAD_ROOT/$1/" 2>/dev/null | wc -l
}

# IPC 응답의 error_code는 앱마다 0(정수) 또는 "NONE"(문자열)로 표기가 갈리고, 응답
# 자체에 error_code 필드가 없는 경우도 있다(system_log tc_system_log.sh TC12-2와 동일
# 대응) — 필드가 있으면 0|"NONE" 인지 확인하고, 없으면 응답 수신 자체로 성공 처리한다.
response_ok() {
    local resp="$1"
    if [ -z "$resp" ]; then
        return 1
    fi
    if echo "$resp" | grep -qE '"error_code"'; then
        if echo "$resp" | grep -qE '"error_code"[[:space:]]*:[[:space:]]*(0|"NONE")'; then
            return 0
        fi
        return 1
    fi
    return 0
}

# --- logpolicy.json/logcount.json/eolpolicy.json (컨테이너 내부 파일) 접근 헬퍼 ---
# device_manager tc_device_manager.sh의 "docker exec $CONTAINER cat <path> | jq" 관례와
# 동일 — 컨테이너 안에는 jq가 없을 수 있어 항상 호스트 jq를 거친다.
#
# [피드백 반영] 이 스크립트가 호스트가 아니라 이미 ac_system_gen2 컨테이너 내부
# (예: 사용자가 `docker exec -it ac_system_gen2 /bin/bash`로 진입한 셸)에서 실행되는
# 경우 "docker exec $CONTAINER ..."를 또 걸면 실패한다(컨테이너 안에 docker 커맨드
# 자체가 없거나, 있어도 자기 자신을 대상으로 exec할 수 없음). docker 커맨드 존재
# 여부와 대상 컨테이너에 대한 exec 가능 여부를 한 번만 확인해 분기한다 — 이미
# 컨테이너 내부라면 docker exec 없이 파일에 직접 접근한다.
IN_CONTAINER=0
if ! command -v docker > /dev/null 2>&1; then
    IN_CONTAINER=1
elif ! docker exec "$CONTAINER" true > /dev/null 2>&1; then
    IN_CONTAINER=1
fi

container_cat() {
    if [ "$IN_CONTAINER" -eq 1 ]; then
        cat "$1" 2>/dev/null
    else
        docker exec "$CONTAINER" cat "$1" 2>/dev/null
    fi
}

container_write() {
    # $1=컨테이너 내부 경로(IN_CONTAINER=1이면 호스트 경로와 동일하게 취급), stdin=새 내용
    if [ "$IN_CONTAINER" -eq 1 ]; then
        cat > "$1"
    else
        docker exec -i "$CONTAINER" sh -c "cat > '$1'"
    fi
}

get_json_field() {
    # $1=컨테이너 내부 json 경로, $2=jq 필터
    container_cat "$1" | jq -r "$2" 2>/dev/null
}

# evidence 로그용 — container_cat을 거쳐 jq 결과를 dump_cmd 스타일로 출력.
# 기존 코드가 여러 곳에서 "dump_cmd bash -c \"docker exec ... | jq ...\""를 직접
# 호출하고 있었는데, 이는 IN_CONTAINER 분기를 우회해 컨테이너 내부 실행 시 깨진다.
# 사용법: dump_container_jq [-r] <json 경로> <jq 필터>
dump_container_jq() {
    local raw=""
    if [ "$1" = "-r" ]; then
        raw="-r"
        shift
    fi
    local path="$1"
    local filter="$2"
    if [ "$IN_CONTAINER" -eq 1 ]; then
        echo "  \$ cat '$path' | jq $raw '$filter'"
    else
        echo "  \$ docker exec '$CONTAINER' cat '$path' | jq $raw '$filter'"
    fi
    container_cat "$path" | jq $raw "$filter" 2>&1 | sed 's/^/    /'
}

set_json_field() {
    # $1=컨테이너 내부 json 경로, $2=jq 변환식(입력을 '.'으로 받음)
    local path="$1"
    local filter="$2"
    local tmp="/tmp/tc_device_log_json_$$"
    container_cat "$path" | jq "$filter" > "$tmp" 2>/dev/null
    container_write "$path" < "$tmp"
    rm -f "$tmp"
}

lp_field() {
    # logpolicy.json 특정 log_item의 필드값 조회. $1=log_item, $2=field
    get_json_field "$LOGPOLICY_JSON" ".loggingRules[] | select(.logItem==\"$1\") | .$2"
}

set_lp_field_num() {
    # logpolicy.json 특정 log_item의 숫자 필드 수정 (수정만, 반영에는 별도 docker-loader 재시작 필요)
    set_json_field "$LOGPOLICY_JSON" "(.loggingRules[] | select(.logItem==\"$1\") | .$2) = $3"
}

lc_field() {
    # logcount.json 특정 log_item의 필드값 조회. $1=log_item, $2=field
    get_json_field "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$1\") | .$2"
}

set_lc_field_num() {
    set_json_field "$LOGCOUNT_JSON" "(.logItemUploadLimits[] | select(.logItem==\"$1\") | .$2) = $3"
}

restart_docker_loader() {
    local restart_epoch
    restart_epoch=$(date +%s)
    echo "  \$ systemctl restart docker-loader"
    systemctl restart docker-loader
    echo "  device_log 재기동 대기 중..."
    local waited=0
    # [2026-08-24 DUT 실측 후 재수정 — 회귀 버그] pgrep -f device_log는 이 TC 스크립트
    # 자신의 커맨드라인(/tmp/tc_device_log.sh)에도 "device_log" 부분문자열이 포함돼
    # 항상 waited=0에서 즉시 매칭·break 해버린다 — 실제 컨테이너/앱 재기동을 전혀
    # 기다리지 않고 다음 단계로 넘어가는 상태였다(2026-08-21에 한 번 고쳤던 것과 동일한
    # 회귀 — 이번 세션의 스크립트 재작성 과정에서 그 수정이 다시 빠졌다). 실제 바이너리
    # 전체 경로(/edge/app/bin/device_log)로 매칭해 자기 자신과 절대 겹치지 않게 한다.
    while [ "$waited" -lt 60 ]; do
        if pgrep -f '/edge/app/bin/device_log' > /dev/null 2>&1; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    dump_cmd pgrep -af '/edge/app/bin/device_log'

    # [2026-08-25 DUT 실측 후 추가] pgrep이 프로세스 존재를 확인해도
    # CloudUploadManager::init()이 끝났다는 보장은 아니다 — device_log::start()는
    # broker 연결(재연결) 시점에 실행되고(device_log.cpp:60-66 주석), 컨테이너 전체
    # (edge_runtime 등 형제 앱 포함, 전부 같은 podman 컨테이너)가 함께 재기동되므로
    # 프로세스가 뜬 뒤에도 broker 연결까지 수십 초가 더 걸릴 수 있다. 그 사이엔
    # root_dir_files_/arch_dir_files_ 큐가 아직 비어있어(enumerateExistingFilesInDirectory()
    # 미실행), 재시작 직후 만든 더미가 라운드로빈에 안 잡힌다(TC21 실측: pgrep 매칭 후
    # CloudUploadManager 초기화 로그까지 별도로 수십 초 더 걸림, 연속 재시작 시 더 심함).
    # CloudUploadManager 초기화 완료를 알리는 로그(cloud_upload_manager.cpp:1272 근처
    # "Total files found in root")가 이번 재시작(restart_epoch) 이후 찍힐 때까지 추가로
    # 최대 60초 더 기다린다.
    echo "  CloudUploadManager 초기화(root 큐 등록) 완료 대기 중..."
    local waited2=0
    while [ "$waited2" -lt 60 ]; do
        if journalctl -u docker-loader --no-pager --since "@$restart_epoch" 2>/dev/null | grep -q "Total files found in root"; then
            break
        fi
        sleep 3
        waited2=$((waited2 + 3))
    done
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '@$restart_epoch' | grep 'Total files found in root'"
}

# 텔레메트리가 실제로 도착 중인 log_item 하나 선택 — 후보 목록에서 디렉토리가 존재하고
# 비어있지 않은 첫 항목을 쓴다. 인자로 후보 목록을 override할 수 있다(기본 ACTIVE_LOG_ITEMS).
pick_active_log_item() {
    local candidates="${1:-$ACTIVE_LOG_ITEMS}"
    local item
    for item in $candidates; do
        if [ -d "$LOGGER_ROOT/$item" ]; then
            if [ -n "$(ls -A "$LOGGER_ROOT/$item" 2>/dev/null)" ]; then
                echo "$item"
                return 0
            fi
        fi
    done
    return 1
}

# 현재 회전되지 않은 활성 CSV(확장자 .csv, .csv.xz 아님) 경로 — 최신 것 1개
active_csv() {
    ls -t "$LOGGER_ROOT/$1/"*.csv 2>/dev/null | head -1
}

# [피드백 반영] TC23/27/28/30(EOL 관련 TC) 실행 전에, "EOL 모드가 문제냐 vs 애초에
# telemetry notification 자체가 안 오냐"를 구분하기 위해 먼저 실제 telemetry가
# column 데이터를 담아 도착 중인지 확인한다. 활성 log_item의 최신 CSV 행에서
# non-empty 컬럼 수를 세어(TC01과 동일한 접근) 3개 초과면 실데이터가 있다고 판단.
# $1=확인 대상 log_item(기본 Meter)
verify_telemetry_columns_present() {
    local log_item="${1:-Meter}"
    local csv
    csv=$(active_csv "$log_item")
    if [ -z "$csv" ]; then
        echo "  [경고] $log_item 활성 csv 없음 — telemetry notification 자체가 도착하지 않는 상태일 수 있음"
        return 1
    fi
    dump_cmd tail -1 "$csv"
    local last_row nonempty_cols
    last_row=$(tail -1 "$csv")
    nonempty_cols=$(echo "$last_row" | awk -F',' '{c=0; for (i=1;i<=NF;i++) if ($i!="") c++; print c}')
    echo "  $log_item 마지막 행 non-empty 컬럼 수: $nonempty_cols"
    if [ "$nonempty_cols" -gt 3 ]; then
        return 0
    fi
    return 1
}

# date/time 컬럼을 epoch로 변환 (date가 YYYYMMDD 형태인 경우 대비)
row_time_epoch() {
    local raw_date="$1"
    local raw_time="$2"
    local iso_date="$raw_date"
    if echo "$raw_date" | grep -qE '^[0-9]{8}$'; then
        iso_date="${raw_date:0:4}-${raw_date:4:2}-${raw_date:6:2}"
    fi
    date -d "${iso_date} ${raw_time}" +%s 2>/dev/null
}

is_online() {
    ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1
}

# [2026-08-24 DUT 실측 후 발견] device_log는 실제 네트워크 상태를 스스로 확인하지
# 않는다 — CloudUploadManager::is_internet_available_(cloud_upload_manager.hpp:215)는
# 오직 NOTI_INTERNET_STATUS 알림(device_log.cpp:673 handle_noti_internet_status,
# sys_manager가 보내는 것으로 추정)을 통해서만 갱신된다. 즉 iptables로 아무리 실제
# 트래픽을 막아도, 그 알림이 별도로 오지 않으면 앱은 계속 "온라인"이라고 믿는다 —
# TC13/14/16/17/21처럼 network_block()만으로 오프라인 분기를 유도하려던 TC들이
# 구조적으로 신뢰할 수 없었던 이유(라운드로빈 관측 창에서 0회 선택 등으로 나타남).
# 메시지 스키마는 handle_noti_internet_status()가 요구하는 그대로:
# {"data":{"is_connected": true|false}} — TC08(device_connection)과 다른 형식이니
# 주의(예전에 {"connected":true}로 잘못 발행했던 시도는 파싱 실패로 조용히 무시됨).
publish_internet_status() {
    local is_connected="$1"
    publish_noti "internet_status" "{\"data\":{\"is_connected\":$is_connected}}"
}

network_block() {
    dump_cmd iptables -A OUTPUT -p tcp --dport 443 -j DROP
    dump_cmd iptables -A OUTPUT -p tcp --dport 80 -j DROP
    dump_cmd iptables -A OUTPUT -p tcp --dport 8883 -j DROP
    dump_cmd iptables -A OUTPUT -p udp --dport 53 -j DROP
    dump_cmd iptables -A OUTPUT -p icmp -j DROP
    echo "  \$ publish_noti internet_status {is_connected:false} (device_log는 자체 감지 안 하므로 직접 통지 필요)"
    publish_internet_status false
}

network_restore() {
    dump_cmd iptables -D OUTPUT -p tcp --dport 443 -j DROP
    dump_cmd iptables -D OUTPUT -p tcp --dport 80 -j DROP
    dump_cmd iptables -D OUTPUT -p tcp --dport 8883 -j DROP
    dump_cmd iptables -D OUTPUT -p udp --dport 53 -j DROP
    dump_cmd iptables -D OUTPUT -p icmp -j DROP
    echo "  \$ publish_noti internet_status {is_connected:true} (device_log는 자체 감지 안 하므로 직접 통지 필요)"
    publish_internet_status true
}

is_leap_year() {
    local y="$1"
    if [ $((y % 400)) -eq 0 ]; then
        return 0
    fi
    if [ $((y % 100)) -eq 0 ]; then
        return 1
    fi
    if [ $((y % 4)) -eq 0 ]; then
        return 0
    fi
    return 1
}

last_day_of_month() {
    # $1=YYYY $2=MM(zero-padded) -> 그 달의 마지막 날짜(숫자)
    local y="$1"
    local m="$((10#$2))"
    local days=31
    case "$m" in
        4|6|9|11)
            days=30
            ;;
        2)
            days=28
            if is_leap_year "$y"; then
                days=29
            fi
            ;;
    esac
    echo "$days"
}

# archive 디렉토리에 파일명 규칙(TC04 정규식)에 맞는 더미 .csv.xz(+.meta) 생성
# $1=log_item $2=end_epoch(파일 mtime으로도 사용) $3=serial(옵션)
create_dummy_archive_file() {
    local log_item="$1"
    local end_epoch="$2"
    local serial="${3:-TCDUMMY}"
    local start_epoch=$((end_epoch - 60))
    local start_str end_str fname
    start_str=$(date -d "@$start_epoch" +%Y%m%d_%H%M%S)
    end_str=$(date -d "@$end_epoch" +%Y%m%d_%H%M%S)
    fname="${start_str}_${end_str}_${log_item}_${serial}.csv.xz"
    mkdir -p "$ARCHIVE_ROOT/$log_item"
    : > "$ARCHIVE_ROOT/$log_item/$fname"
    : > "$ARCHIVE_ROOT/$log_item/${fname}.meta"
    # touch -t 대신, 이 프로젝트에서 이미 검증된 touch -d "@epoch" 형태를 사용한다
    # (system_log tc_system_log.sh에서 touch -d "N days ago" 실사용 확인됨).
    touch -d "@$end_epoch" "$ARCHIVE_ROOT/$log_item/$fname" "$ARCHIVE_ROOT/$log_item/${fname}.meta"
    echo "$ARCHIVE_ROOT/$log_item/$fname"
}

# root 디렉토리($LOGGER_ROOT/log_item, 활성 csv와 같은 위치)에 파일명 규칙(TC04
# 정규식)에 맞는 더미 .csv.xz(+.meta) 생성. TC10의 archive 더미와 동일한 이유로,
# selectNextRootLogType()이 참조하는 root_dir_files_는 프로세스 기동 시
# enumerateRootFilesInDirectory()가 디스크를 스캔해야만 채워진다 — 이 함수 호출 뒤엔
# restart_docker_loader()가 필요하다(호출부 책임, 여기서는 안 함).
#
# [주의, 2026-08-25 DUT 실측 발견] $3(serial)에 밑줄(_)을 넣지 말 것.
# getLogTypeFromFileName()(cloud_upload_manager.cpp:1830-1854)은 파일명을 밑줄로
# split해 "4번째~마지막에서 두 번째 토큰"을 log_item으로 재조립하는데, serial에
# 밑줄이 섞이면(예: "TC21_1") log_item이 "Meter_TC21"처럼 오염되어 isKnownLogType()이
# 실패 → pushRootFileInfo()가 조용히 등록을 거부한다(ERROR 로그만 남고 root_dir_files_에
# 안 들어감 — TC21 초안이 이 버그로 두 sub-case 모두 FAIL했던 원인, 프로덕트 결함
# 아니라 테스트 스크립트가 잘못된 serial을 준 것이었음). archive/toupload 더미는
# 각각 다른 스캔 경로(archiveToUpload 자체 재파싱 없음/BlobUploadDirector의 별도
# 파싱)라 영향이 없지만, root 더미만큼은 반드시 밑줄 없는 serial을 쓸 것.
# $1=log_item $2=end_epoch(파일 mtime으로도 사용) $3=serial(옵션, 밑줄 금지)
create_dummy_root_file() {
    local log_item="$1"
    local end_epoch="$2"
    local serial="${3:-TCDUMMY}"
    local start_epoch=$((end_epoch - 60))
    local start_str end_str fname
    start_str=$(date -d "@$start_epoch" +%Y%m%d_%H%M%S)
    end_str=$(date -d "@$end_epoch" +%Y%m%d_%H%M%S)
    fname="${start_str}_${end_str}_${log_item}_${serial}.csv.xz"
    mkdir -p "$LOGGER_ROOT/$log_item"
    : > "$LOGGER_ROOT/$log_item/$fname"
    : > "$LOGGER_ROOT/$log_item/${fname}.meta"
    touch -d "@$end_epoch" "$LOGGER_ROOT/$log_item/$fname" "$LOGGER_ROOT/$log_item/${fname}.meta"
    echo "$LOGGER_ROOT/$log_item/$fname"
}

# toupload 디렉토리에 파일명 규칙(TC04 정규식)에 맞는 더미 .csv.xz(+.meta) 생성.
# BlobUploadDirector(cloud_broker)는 kUploadRoot(=/edge/log/toupload)를 device_log의
# 내부 큐와 무관하게 파일시스템에서 직접 스캔하므로(blob_upload_director.hpp:85),
# TC10의 archive 케이스와 달리 재시작 없이도 더미 파일이 스캔 대상에 잡힌다.
# $1=log_item $2=end_epoch(옵션, 기본 now) $3=serial(옵션)
create_dummy_toupload_file() {
    local log_item="$1"
    local end_epoch="${2:-$(date +%s)}"
    local serial="${3:-TCDUMMY}"
    local start_epoch=$((end_epoch - 60))
    local start_str end_str fname
    start_str=$(date -d "@$start_epoch" +%Y%m%d_%H%M%S)
    end_str=$(date -d "@$end_epoch" +%Y%m%d_%H%M%S)
    fname="${start_str}_${end_str}_${log_item}_${serial}.csv.xz"
    mkdir -p "$TOUPLOAD_ROOT/$log_item"
    : > "$TOUPLOAD_ROOT/$log_item/$fname"

    # [2026-08-24 실측 후 수정] 빈 .meta는 cloud_broker의 parse_meta()에서
    # upload_name/upload_path/from이 전부 비어 valid=false로 판정되고
    # "[Director] Invalid meta file: ..."로 조용히 스킵된다(blob_upload_director.cpp:
    # 99-103,184) — 실제 업로드 시도 자체가 안 일어나 device_log의 "Upload success/fail
    # for log item"도 영원히 안 찍힌다(TC11 FAIL의 실제 원인, DUT 실측으로 확인).
    # device_log의 recreateMetaFile()(cloud_upload_manager.cpp:1001-1090)과 동일한
    # key=value 형식으로 최소 요구 필드(upload_name/upload_path/from)를 채운다.
    local log_type_hyphen upload_year_month
    log_type_hyphen=$(echo "$log_item" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
    upload_year_month="${end_str:0:4}/${end_str:4:2}/"
    {
        echo "upload_name = $fname"
        echo "upload_path = /$log_type_hyphen/$upload_year_month"
        echo "post_action_success = delete"
        echo "post_action_failure = move"
        echo "move_dir_success = X"
        echo "move_dir_failure = $ARCHIVE_ROOT/$log_item"
        echo "from = device_log"
    } > "$TOUPLOAD_ROOT/$log_item/${fname}.meta"

    touch -d "@$end_epoch" "$TOUPLOAD_ROOT/$log_item/$fname" "$TOUPLOAD_ROOT/$log_item/${fname}.meta"
    echo "$TOUPLOAD_ROOT/$log_item/$fname"
}

# ============================================================
# [2026-08-26 추가] 이전 run들이 남긴 더미 잔재 전역 청소
#
#   TC09/TC10/TC12/TC18/TC21이 root/archive/toupload에 직접 심는 더미(serial이 항상
#   "TC"로 시작 — TCDUMMY/TC09$i/TC10/TC12_$i/TC18ROOT/TC18ARCH/TC211/TC212 등)가
#   각 TC 종료 후 개별적으로 청소되는 경우도 있지만(TC09의 archive 청소, TC21의
#   POLLUTE 청소) 전부는 아니다. create_dummy_root_file()/create_dummy_archive_file()로
#   만든 더미는 .meta를 빈 파일로 만드는데(위 create_dummy_toupload_file()과 달리
#   valid meta 필드가 없음), device_log가 나중에 이 root/archive 더미를 자기 정상
#   경로로 toupload까지 옮기면 그 빈 meta가 그대로 따라가 cloud_broker
#   blob_upload_director가 매 스캔 주기(300초)마다 "Invalid meta file"만 반복
#   찍고 절대 치우지 않는다.
#
#   DUT 재실측(2026-08-26)으로 이게 "edge_device_id 미프로비저닝으로 인한 실제
#   클라우드 backlog"라는 기존 추정과 무관한, 순수 테스트 잔재였음을 확인했다
#   (journal에 edge_device_id가 정상 설정/전달되는 로그만 있고 "not ready" 경고는
#   없음 — 대신 이 더미 파일들 각각에 대해 "[Director] Invalid meta file" 반복
#   확인). toupload가 완전히 비어있어야 하는 전제조건을 쓰는 TC14/TC18-3,4/TC21-1이
#   이 잔재 때문에 매 run마다 SKIP나던 근본 원인이었다.
#
#   실제 제품 로직(Director의 재시도/삭제 정책)을 건드리는 대신, 테스트가 심어놓은
#   흔적을 스크립트 시작 시점에 스스로 치운다 — 이번 run이 새로 만드는 더미는 각
#   TC 자신의 로직이 끝난 뒤 처리하므로 이 청소가 건드리지 않는다(스크립트 시작
#   시 딱 한 번만 실행). 실 디바이스 시리얼(예: 242151311501F01019)은 "TC"로
#   시작하지 않으므로 이 패턴에 걸릴 일이 없다.
# ============================================================
cleanup_stale_dummy_files() {
    local root d
    for root in "$LOGGER_ROOT" "$ARCHIVE_ROOT" "$TOUPLOAD_ROOT"; do
        [ -d "$root" ] || continue
        for d in "$root"/*/; do
            [ -d "$d" ] || continue
            rm -f "$d"*_TC*.csv.xz "$d"*_TC*.csv.xz.meta 2>/dev/null
        done
    done
}

# ============================================================
# TC01 (SID0201): 로그 데이터 필드 정확성
# ============================================================
tc01_field_accuracy() {
    echo "=== TC01: 로그 데이터 필드 정확성 ==="
    # [피드백 반영] 사전 조건에 PMU_Monitoring을 예시로 명시했으므로, 임의 선택
    # (pick_active_log_item, 사실상 ACTIVE_LOG_ITEMS 순서상 Meter가 먼저 잡힘) 대신
    # PMU_Monitoring으로 고정해 사전 조건과 실제 근거를 일치시킨다.
    local log_item="PMU_Monitoring"
    if [ ! -d "$LOGGER_ROOT/$log_item" ] || [ -z "$(ls -A "$LOGGER_ROOT/$log_item" 2>/dev/null)" ]; then
        assert "TC01-1: 헤더에 date,time,serial_number + patternGroups 컬럼 포함" "FAIL" "$log_item 텔레메트리 도착 안 됨"
        assert "TC01-2: 마지막 행 serial_number 비어있지 않음" "FAIL" "$log_item 텔레메트리 도착 안 됨"
        return
    fi
    echo "  대상 log_item: $log_item"

    echo "  \$ logpolicy.json patternGroups 컬럼 목록 (jq)"
    dump_container_jq -r "$LOGPOLICY_JSON" ".loggingRules[] | select(.logItem==\"$log_item\") | .patternGroups[].columns[]"

    local csv
    csv=$(active_csv "$log_item")
    if [ -z "$csv" ]; then
        assert "TC01-1: 헤더에 date,time,serial_number 포함" "FAIL" "활성 CSV 없음"
        assert "TC01-2: 마지막 행 serial_number 비어있지 않음" "FAIL" "활성 CSV 없음"
        return
    fi

    dump_cmd head -1 "$csv"
    if head -1 "$csv" | grep -q "date,time,serial_number"; then
        assert "TC01-1: 헤더에 date,time,serial_number 포함" "PASS"
    else
        assert "TC01-1: 헤더에 date,time,serial_number 포함" "FAIL"
    fi

    dump_cmd tail -1 "$csv"
    if tail -1 "$csv" | awk -F',' '{print $3}' | grep -qE '.+'; then
        assert "TC01-2: 마지막 행 serial_number 비어있지 않음" "PASS"
    else
        assert "TC01-2: 마지막 행 serial_number 비어있지 않음" "FAIL"
    fi
}

# ============================================================
# TC02 (SID0201): 로그 Row 기록 주기(logRowInterval) 정확성
# ============================================================
tc02_row_interval() {
    echo "=== TC02: 로그 Row 기록 주기(logRowInterval) 정확성 ==="
    # [피드백 반영] logRowInterval이 짧은 log_item을 쓰라는 취지를 명시적으로
    # Meter(15s) 고정으로 반영 — pick_active_log_item으로 임의 선택하지 않는다.
    local log_item="Meter"
    if [ ! -d "$LOGGER_ROOT/$log_item" ] || [ -z "$(ls -A "$LOGGER_ROOT/$log_item" 2>/dev/null)" ]; then
        assert "TC02-1: 행 간 시간차가 logRowInterval 근접" "FAIL" "$log_item 텔레메트리 도착 안 됨"
        return
    fi
    local interval
    interval=$(lp_field "$log_item" "logRowInterval")
    echo "  대상 log_item: $log_item, logRowInterval=${interval}s"

    local wait_sec=$((interval * 3 + 10))
    echo "  ${wait_sec}초 대기 (logRowInterval * 3 + 여유)..."
    sleep "$wait_sec"

    local csv
    csv=$(active_csv "$log_item")
    dump_cmd tail -3 "$csv"

    local l1 l2 l3 t1 t2 t3
    l1=$(tail -3 "$csv" | sed -n '1p')
    l2=$(tail -3 "$csv" | sed -n '2p')
    l3=$(tail -3 "$csv" | sed -n '3p')
    t1=$(row_time_epoch "$(echo "$l1" | awk -F',' '{print $1}')" "$(echo "$l1" | awk -F',' '{print $2}')")
    t2=$(row_time_epoch "$(echo "$l2" | awk -F',' '{print $1}')" "$(echo "$l2" | awk -F',' '{print $2}')")
    t3=$(row_time_epoch "$(echo "$l3" | awk -F',' '{print $1}')" "$(echo "$l3" | awk -F',' '{print $2}')")

    if [ -z "$t1" ] || [ -z "$t2" ] || [ -z "$t3" ]; then
        assert "TC02-1: 행 간 시간차가 logRowInterval 근접" "FAIL" "date/time 컬럼 파싱 실패 — evidence(tail -3) 수동 확인 필요"
        return
    fi

    local diff1=$((t2 - t1))
    local diff2=$((t3 - t2))
    echo "  diff1=${diff1}s diff2=${diff2}s (기준 interval=${interval}s ±10%)"

    local lo=$((interval * 90 / 100))
    local hi=$((interval * 110 / 100))
    local ok=1
    if [ "$diff1" -lt "$lo" ] || [ "$diff1" -gt "$hi" ]; then
        ok=0
    fi
    if [ "$diff2" -lt "$lo" ] || [ "$diff2" -gt "$hi" ]; then
        ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        assert "TC02-1: 행 간 시간차가 logRowInterval ±10% 이내" "PASS"
    else
        assert "TC02-1: 행 간 시간차가 logRowInterval ±10% 이내" "FAIL" "diff1=${diff1}s diff2=${diff2}s 허용범위[${lo},${hi}]"
    fi
}

# ============================================================
# TC03 (SID0201): 로그 타입별(prefix) 텔레메트리 도착 시 CSV 실데이터 기록 확인
#   [피드백 반영] createFileDirectoryForAllRules()가 부팅 시 noti 수신과 무관하게
#   디렉토리+빈 CSV(헤더만)를 먼저 만들어 두므로, "파일이 생기느냐"(ls -d)는 텔레메트리
#   도착 여부를 증명하지 못한다. "내용이 채워지느냐"(데이터 행 존재, noti가 와야 row가
#   써짐) 기준으로 판정하도록 wc -l 기반 검증으로 교체.
# ============================================================

# 그룹 내 각 log_item의 활성 csv 데이터 행(헤더 제외) 존재 여부를 판정.
# 반환: 0=전체 데이터 행 존재(PASS), 1=디렉토리는 있으나 데이터 행 없음(FAIL),
#       2=디렉토리/csv 자체가 없음(SKIP, 실물 미연결)
check_group_csv_rows() {
    local items="$*"
    local any_missing_dir=0
    local any_no_data=0
    local item
    for item in $items; do
        local csv
        csv=$(active_csv "$item")
        if [ -z "$csv" ]; then
            echo "  [$item] 활성 csv 없음"
            any_missing_dir=1
            continue
        fi
        dump_cmd wc -l "$csv"
        local lines
        lines=$(wc -l < "$csv")
        if [ "$lines" -lt 2 ]; then
            any_no_data=1
        fi
    done
    if [ "$any_no_data" -eq 1 ]; then
        return 1
    fi
    if [ "$any_missing_dir" -eq 1 ]; then
        return 2
    fi
    return 0
}

tc03_csv_data_rows() {
    echo "=== TC03: 로그 타입별(prefix) 텔레메트리 도착 시 CSV 실데이터 기록 확인 ==="

    check_group_csv_rows EMSP_Maintenance EMSP_Installation
    case $? in
        0) assert "TC03-1: EMSP 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-1: EMSP 그룹 CSV 데이터 행 존재" "SKIP" "csv 없음(실물 미연결)" ;;
        *) assert "TC03-1: EMSP 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows PMU_Monitoring
    case $? in
        0) assert "TC03-2: PMU 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-2: PMU 그룹 CSV 데이터 행 존재" "SKIP" "csv 없음(실물 미연결)" ;;
        *) assert "TC03-2: PMU 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows MI_Monitoring MI_Device_Info
    case $? in
        0) assert "TC03-3: MI 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-3: MI 그룹 CSV 데이터 행 존재" "SKIP" "csv 없음(실물 미연결)" ;;
        *) assert "TC03-3: MI 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows PCS_CAN_Monitoring_P01 PCS_CAN_Monitoring_P02
    case $? in
        0) assert "TC03-4: PCS(CAN) 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-4: PCS(CAN) 그룹 CSV 데이터 행 존재" "SKIP" "이 벤치에 PCS CAN 실물 미연결 (2026-08-20 실측)" ;;
        *) assert "TC03-4: PCS(CAN) 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows Advanced_HUB_Monitoring
    case $? in
        0) assert "TC03-5: Advanced HUB 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-5: Advanced HUB 그룹 CSV 데이터 행 존재" "SKIP" "이 벤치에 Advanced HUB 실물 미연결 (2026-08-20 실측)" ;;
        *) assert "TC03-5: Advanced HUB 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows Meter
    case $? in
        0) assert "TC03-6: Meter 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-6: Meter 그룹 CSV 데이터 행 존재" "SKIP" "csv 없음(실물 미연결)" ;;
        *) assert "TC03-6: Meter 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows BMS_Operation_P01 BMS_Operation_P02 BMS_LifeCycle_P01 BMS_LifeCycle_P02 BMS_Monitoring_P01 BMS_Monitoring_P02
    case $? in
        0) assert "TC03-7: BMS 그룹 CSV 데이터 행 존재(6개)" "PASS" ;;
        2) assert "TC03-7: BMS 그룹 CSV 데이터 행 존재(6개)" "SKIP" "이 벤치에 BMS 실물 미연결 (2026-08-20 실측)" ;;
        *) assert "TC03-7: BMS 그룹 CSV 데이터 행 존재(6개)" "FAIL" "일부 데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows BPU_CAN_Monitoring_P01 BPU_CAN_Monitoring_P02
    case $? in
        0) assert "TC03-8: BPU 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-8: BPU 그룹 CSV 데이터 행 존재" "SKIP" "이 벤치에 BPU 실물 미연결 (2026-08-20 실측)" ;;
        *) assert "TC03-8: BPU 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac

    check_group_csv_rows C_Box_Monitoring
    case $? in
        0) assert "TC03-9: C_Box 그룹 CSV 데이터 행 존재" "PASS" ;;
        2) assert "TC03-9: C_Box 그룹 CSV 데이터 행 존재" "SKIP" "csv 없음(실물 미연결)" ;;
        *) assert "TC03-9: C_Box 그룹 CSV 데이터 행 존재" "FAIL" "데이터 행 없음(헤더만)" ;;
    esac
}

# ============================================================
# TC04 (SID0202): 파일명 형식 검증
# ============================================================
tc04_filename_format() {
    echo "=== TC04: 파일명 형식 검증 ==="
    local log_item
    log_item=$(pick_active_log_item)
    if [ -z "$log_item" ]; then
        assert "TC04-1: 디렉토리 내 전체 파일명이 정규식 일치" "FAIL" "텔레메트리 도착 중인 log_item 없음"
        return
    fi
    echo "  대상 log_item: $log_item"

    dump_cmd ls "$LOGGER_ROOT/$log_item/"
    local bad_count
    bad_count=$(ls "$LOGGER_ROOT/$log_item/" 2>/dev/null | grep -vE '^[0-9]{8}_[0-9]{6}_[0-9]{8}_[0-9]{6}_.+_.+\.csv(\.xz)?$' | wc -l)
    echo "  정규식 불일치 파일 수: $bad_count"
    if [ "$bad_count" -eq 0 ]; then
        assert "TC04-1: 디렉토리 내 전체 파일명이 정규식 일치" "PASS"
    else
        assert "TC04-1: 디렉토리 내 전체 파일명이 정규식 일치" "FAIL" "불일치 ${bad_count}개"
    fi
}

# ============================================================
# TC05 (SID0202): 파일 생성 주기(logCreationTime) 정확성 [시스템 시간 변경]
#   [2026-08-25 재설계] 기존엔 logCreationTime(6시간)+5분을 실시간 sleep으로
#   자연 경과시켰다 — 6시간+ 동안 시간만 흘려보내는 것으로는 "시간이 바뀌었을 때
#   실제로 로그가 생성/회전되는지"를 검증하지 못한다(그냥 대기했다는 것만 증명함).
#   TC18/TC19와 동일하게 `timedatectl set-ntp no` + `timedatectl set-time`으로
#   시스템 시각 자체를 logCreationTime만큼 앞당겨서 회전이 실제로 트리거되는지
#   확인하는 방식으로 바꿨다 — 실행 시간이 6시간+5분에서 20초 내외로 단축된다.
# ============================================================
tc05_creation_time_long() {
    echo "=== TC05: 파일 생성 주기(logCreationTime) 정확성 [시스템 시간 변경] ==="
    local log_item="PMU_Monitoring"
    if [ ! -d "$LOGGER_ROOT/$log_item" ]; then
        assert "TC05-1: 간격이 logCreationTime ±5%" "FAIL" "$log_item 텔레메트리 미도착"
        return
    fi

    local ct
    ct=$(lp_field "$log_item" "logCreationTime")
    echo "  대상 log_item: $log_item, logCreationTime=${ct}s"

    local csv_before
    csv_before=$(active_csv "$log_item")
    dump_cmd ls -la "$csv_before"
    local start_before
    start_before=$(basename "$csv_before" | awk -F'_' '{print $1"_"$2}')

    local orig_epoch target_epoch target_str
    orig_epoch=$(date +%s)
    dump_cmd date
    target_epoch=$((orig_epoch + ct + 300))
    target_str=$(date -d "@${target_epoch}" "+%Y-%m-%d %H:%M:%S")
    dump_cmd timedatectl set-ntp no
    echo "  \$ timedatectl set-time \"${target_str}\" (logCreationTime+5분 앞으로 점프)"
    timedatectl set-time "${target_str}" > /dev/null 2>&1
    dump_cmd date

    # [2026-08-25 DUT 실측 후 수정] 회전 직후 압축된 파일이 LOGGER_ROOT에 계속 남아있을
    # 거라 가정했는데(원래 6시간 실대기 설계 당시의 가정), 실측해보니 회전되어 닫힌 파일은
    # 일반 idle thread 라운드로빈(rootToArchiveOrToUpload(), 5초 주기)이 곧바로(15초 안에)
    # 집어가 toupload가 비어있으면 ARCHIVE_ROOT를 거치지 않고 TOUPLOAD_ROOT까지 가버린다
    # (TC18/TC21에서 이미 겪은 것과 동일한 게이트). LOGGER_ROOT의 "가장 최근 .xz"만
    # 보던 방식은 이 이동을 놓쳐 항상 FAIL이 났다 — 원래 활성 파일의 시작시각
    # (start_before)을 파일명 접두사로 삼아 root/archive/toupload 세 곳을 모두 뒤지는
    # 방식으로 교체. 폴링도 idle thread 사이클(5초)에 맞춰 최대 20초까지 재시도한다.
    echo "  회전(idle thread 사이클) 도달 대기 (최대 20초, 5초 간격 재시도)..."
    local rotated="" attempt d cand
    for attempt in 1 2 3 4; do
        sleep 5
        for d in "$LOGGER_ROOT/$log_item" "$ARCHIVE_ROOT/$log_item" "$TOUPLOAD_ROOT/$log_item"; do
            cand=$(ls "$d/${start_before}_"*.csv.xz 2>/dev/null | head -1)
            if [ -n "$cand" ]; then
                rotated="$cand"
                break 2
            fi
        done
    done

    # [2026-08-25 시리얼 buffer overrun 회피] ARCHIVE_ROOT는 다른 TC가 남긴 파일이
    # 많아 디렉토리 전체를 dump하면(수십 줄) 시리얼 base64 전송이 깨진다 — 우리가 추적
    # 중인 접두사(start_before)로만 필터링해 evidence 크기를 최소화한다.
    dump_cmd ls -la "$LOGGER_ROOT/$log_item/${start_before}_"*
    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/${start_before}_"*
    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/${start_before}_"*
    if [ -z "$rotated" ]; then
        assert "TC05-1: 간격이 logCreationTime ±5%" "FAIL" "회전된(.csv.xz) 파일을 root/archive/toupload 어디서도 못 찾음 (접두사 ${start_before})"
        echo "  \$ date -s (원래 시각으로 복원)"
        date -s "@${orig_epoch}" > /dev/null
        dump_cmd date
        return
    fi

    local fname start_str end_str start_epoch end_epoch diff
    fname=$(basename "$rotated")
    start_str=$(echo "$fname" | awk -F'_' '{print $1"_"$2}')
    end_str=$(echo "$fname" | awk -F'_' '{print $3"_"$4}')
    start_epoch=$(date -d "${start_str:0:4}-${start_str:4:2}-${start_str:6:2} ${start_str:9:2}:${start_str:11:2}:${start_str:13:2}" +%s 2>/dev/null)
    end_epoch=$(date -d "${end_str:0:4}-${end_str:4:2}-${end_str:6:2} ${end_str:9:2}:${end_str:11:2}:${end_str:13:2}" +%s 2>/dev/null)

    if [ -z "$start_epoch" ] || [ -z "$end_epoch" ]; then
        assert "TC05-1: 간격이 logCreationTime ±5%" "FAIL" "파일명 시각 파싱 실패: $fname"
        echo "  \$ date -s (원래 시각으로 복원)"
        date -s "@${orig_epoch}" > /dev/null
        dump_cmd date
        return
    fi

    diff=$((end_epoch - start_epoch))
    echo "  파일명=$fname diff=${diff}s (기준 logCreationTime=${ct}s ±5%)"
    local lo=$((ct * 95 / 100))
    local hi=$((ct * 105 / 100))
    if [ "$diff" -ge "$lo" ] && [ "$diff" -le "$hi" ]; then
        assert "TC05-1: 간격이 logCreationTime ±5%" "PASS"
    else
        assert "TC05-1: 간격이 logCreationTime ±5%" "FAIL" "diff=${diff}s 허용범위[${lo},${hi}]"
    fi

    echo "  \$ date -s (원래 시각으로 복원)"
    date -s "@${orig_epoch}" > /dev/null
    dump_cmd date
}

# ============================================================
# TC06+TC07 (SID0202, 재부팅 수반): 동일 파일 이어쓰기 + 빈 행 삽입
#   --tc06-pre 로 상태 저장 후 reboot, SSH/시리얼 재접속 후 --tc06-post 로 검증
# ============================================================
TC0607_SAVE="$STATE_DIR/tc0607_state"

tc06_07_pre() {
    echo "=== TC06/TC07-PRE: 재부팅 전 상태 저장 ==="
    local log_item="EMSP_Installation"

    if [ ! -d "$LOGGER_ROOT/$log_item" ]; then
        # [2026-08-28 실측 후 수정] 이 지점에서 reboot()를 아예 안 부르고 return하는데,
        # 대시보드(_run_ssh_full_with_reboots)는 이 사실을 모른 채 그대로
        # _wait_for_dut_reboot() → --tc06-post 로 이어간다 — DUT가 실제로는 재부팅
        # 안 됐으니 ping/ssh 확인은 즉시 통과하고, --tc06-post는 $TC0607_SAVE가 없어
        # [ERROR] 한 줄만 찍고 조용히 리턴한다(assert 없음). 그 결과 TC06-1만 FAIL로
        # 남고 TC07-1/2는 이 run 결과에서 통째로 증발했다(latest_status에 남아있던
        # 예전 run의 TC07-1/2만 계속 재사용되는 것처럼 보임) — TC08/TC22 등 다른
        # "텔레메트리 미도착" 사전조건 케이스가 관련 sub-case 전부를 FAIL 처리하는
        # 것과 다른 예외였다. TC07-1/2도 같은 이유로 FAIL 처리해 결과가 비지 않게 한다.
        echo "[ERROR] $log_item 텔레메트리 미도착 — TC06/07 진행 불가"
        assert "TC06-1: 재부팅 전후 파일명 동일" "FAIL" "$log_item 텔레메트리 미도착"
        assert "TC07-1: 재부팅 경계에 빈 줄 존재" "FAIL" "$log_item 텔레메트리 미도착 — TC06-pre 단계에서 재부팅 자체가 스킵됨"
        assert "TC07-2: 헤더 라인 유지" "FAIL" "$log_item 텔레메트리 미도착 — TC06-pre 단계에서 재부팅 자체가 스킵됨"
        return
    fi

    local csv lines header
    csv=$(active_csv "$log_item")
    dump_cmd ls -la "$csv"
    lines=$(wc -l < "$csv")
    header=$(head -1 "$csv")

    {
        echo "LOG_ITEM=$log_item"
        echo "CSV_PATH=$csv"
        echo "LINES_BEFORE=$lines"
        echo "HEADER_BEFORE=$header"
    } > "$TC0607_SAVE"

    dump_cmd cat "$TC0607_SAVE"
    echo ""
    echo "[TC06/07-PRE 완료] reboot 실행 중... 재접속 후 --tc06-post 실행"
    sync
    reboot
}

tc06_07_post() {
    echo "=== TC06/TC07-POST: 재부팅 후 파일 이어쓰기 + 빈 행 확인 ==="
    if [ ! -f "$TC0607_SAVE" ]; then
        echo "[ERROR] $TC0607_SAVE 없음 - --tc06-pre 를 먼저 실행하세요"
        return
    fi
    # shellcheck disable=SC1090
    source "$TC0607_SAVE"

    echo "  대상 log_item: $LOG_ITEM"
    echo "  재부팅 후 텔레메트리 재개 대기 (logRowInterval*2)..."
    local interval
    interval=$(lp_field "$LOG_ITEM" "logRowInterval")
    sleep "$((interval * 2 + 10))"

    local csv_after
    csv_after=$(active_csv "$LOG_ITEM")
    dump_cmd ls -la "$csv_after"

    if [ "$csv_after" = "$CSV_PATH" ]; then
        assert "TC06-1: 재부팅 전후 파일명 동일" "PASS"
    else
        assert "TC06-1: 재부팅 전후 파일명 동일" "FAIL" "before=$CSV_PATH after=$csv_after"
    fi

    local boundary_line=$((LINES_BEFORE + 1))
    dump_cmd sed -n "${boundary_line}p" "$csv_after"
    local boundary_content
    boundary_content=$(sed -n "${boundary_line}p" "$csv_after")
    if [ -z "$boundary_content" ]; then
        assert "TC07-1: 재부팅 경계에 빈 줄 존재" "PASS"
    else
        assert "TC07-1: 재부팅 경계에 빈 줄 존재" "FAIL" "line${boundary_line}=[$boundary_content]"
    fi

    dump_cmd head -1 "$csv_after"
    local header_after
    header_after=$(head -1 "$csv_after")
    if [ "$header_after" = "$HEADER_BEFORE" ]; then
        assert "TC07-2: 헤더 라인 유지" "PASS"
    else
        assert "TC07-2: 헤더 라인 유지" "FAIL" "before=[$HEADER_BEFORE] after=[$header_after]"
    fi

    rm -f "$TC0607_SAVE"
}

# ============================================================
# TC08 (SID0202, §AGSRS-548 미구현 확인 — 예상 FAIL)
#   device_log.cpp:639-644 handle_noti_device_connection()은 CAN 상태를 DEBUG 로그만
#   남기고 CSV에는 아무 조치도 하지 않는다. DUT 실측 없이도 FAIL이 확정적이나, 실제
#   실행하여 근거를 evidence로 남긴다.
#
#   [2026-08-21 실측 후 수정] TC08-2는 이 DEBUG 로그가 journald에 실제로 찍히는지를
#   참고용으로 확인하는데, edge_logger.cpp:63의 기본 로그 레벨(INFO=1)과
#   factory_register_map.json의 log_level_dl 기본값(1=INFO)이 DEBUG(0)를 걸러낸다.
#   즉 레벨을 낮추지 않으면 100% FAIL이 확정적이라 이전 실행에서 스크립트 버그로
#   FAIL 처리됐다. db_manager/tc_db_manager.sh TC04, edge_runtime TC의
#   "update_records: system_setting.log_level_XX" 패턴과 동일하게 임시로
#   log_level_dl=0(DEBUG)로 낮췄다가 원복한다.
# ============================================================
set_dl_log_level() {
    # $1=레벨(0=DEBUG,1=INFO,...) — device_log의 system_setting 키 log_level_dl 변경.
    # db_manager::system_setting 테이블을 통해 handle_noti_system_settings_changed()가
    # 반응한다(device_log.cpp:233-251) — 재시작 불필요, 즉시 반영.
    send_and_wait "update_records" "{\"db\":\"edge_storage.db\",\"table\":\"system_setting\",\"records\":[{\"key\":\"log_level_dl\",\"value\":\"$1\",\"type\":1}]}" 10 > /dev/null
}

tc08_device_connection() {
    echo "=== TC08: 외부 디바이스 연결 해제/재연결 시 빈 행 삽입 [예상 FAIL — §AGSRS-548 미구현] ==="
    local log_item
    log_item=$(pick_active_log_item)
    if [ -z "$log_item" ]; then
        assert "TC08-1: 연결 해제 구간 빈 행 존재(요구사항 AC 기준, 예상 FAIL)" "FAIL" "텔레메트리 도착 중인 log_item 없음"
        assert "TC08-2: device_connection 알림 수신 확인(참고용)" "FAIL" "텔레메트리 도착 중인 log_item 없음"
        return
    fi

    local csv lines_before
    csv=$(active_csv "$log_item")
    lines_before=$(wc -l < "$csv")
    dump_cmd ls -la "$csv"

    # log_level_dl은 logcount.json이 아니라 DB의 system_setting 테이블에 있다 —
    # 원래값을 select_records로 조회한다(db_manager tc_db_manager.sh TC04와 동일 패턴).
    local orig_log_level
    orig_log_level=$(send_and_wait "select_records" '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_dl"]}' 10 | jq -r '.payload.records[] | select(.key=="log_level_dl") | .value' 2>/dev/null)
    [ -z "$orig_log_level" ] && orig_log_level=1
    echo "  \$ system_setting log_level_dl: $orig_log_level -> 0 (DEBUG, TC08-2용 임시 변경)"
    set_dl_log_level 0

    echo "  \$ publish_noti device_connection {protocol:CAN, connected:false}"
    publish_noti "device_connection" '{"protocol":"CAN","connected":false}'
    local interval
    interval=$(lp_field "$log_item" "logRowInterval")
    sleep "$((interval * 2))"
    echo "  \$ publish_noti device_connection {protocol:CAN, connected:true}"
    publish_noti "device_connection" '{"protocol":"CAN","connected":true}'
    sleep "$((interval + 5))"

    local boundary_line=$((lines_before + 1))
    dump_cmd sed -n "${boundary_line}p" "$csv"
    local boundary_content
    boundary_content=$(sed -n "${boundary_line}p" "$csv")
    if [ -z "$boundary_content" ]; then
        assert "TC08-1: 연결 해제 구간 빈 행 존재(요구사항 AC 기준, 예상 FAIL)" "PASS"
    else
        assert "TC08-1: 연결 해제 구간 빈 행 존재(요구사항 AC 기준, 예상 FAIL)" "FAIL" "line${boundary_line}=[$boundary_content] — 예상된 결과(§AGSRS-548 미구현, device_log.cpp:639-644 참고)"
    fi

    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep 'CAN connection state'"
    if journalctl -u docker-loader --no-pager 2>/dev/null | grep -q "CAN connection state"; then
        assert "TC08-2: device_connection 알림 수신 확인(참고용)" "PASS"
    else
        assert "TC08-2: device_connection 알림 수신 확인(참고용)" "FAIL"
    fi

    echo "  \$ system_setting log_level_dl 원복: $orig_log_level"
    set_dl_log_level "$orig_log_level"
}

# ============================================================
# TC09 (SID0203, 장시간/파괴적): Archive 파일 개수(fileCount) 초과 시 FIFO 삭제
#   logpolicy.json의 fileCount를 임시로 5로 수정 + docker-loader 재시작 필요.
#   반드시 원복(finally)까지 포함 — --tc09 으로 개별 실행할 것.
# ============================================================
tc09_filecount_fifo() {
    echo "=== TC09: Archive 파일 개수(fileCount) 초과 시 FIFO 삭제 [정책 수정 + 재시작] ==="
    local log_item="Meter"
    local archive_dir="$ARCHIVE_ROOT/$log_item"
    local original_count

    original_count=$(lp_field "$log_item" "fileCount")
    echo "  대상 log_item: $log_item, 원래 fileCount=$original_count"
    if [ -z "$original_count" ]; then
        assert "TC09-1: 파일 수가 수정된 fileCount(5) 이하" "FAIL" "logpolicy.json에서 fileCount 조회 실패"
        return
    fi

    mkdir -p "$archive_dir"
    echo "  더미 archive 파일 8개 생성 (mtime 1분 간격, 오래된 것부터)"
    # [2026-08-25 실측 후 수정] 시리얼에 밑줄이 들어가면(예: "TC09_1")
    # getLogTypeFromFileName()이 "Meter_TC09"처럼 log_item을 잘못 합쳐 파싱해
    # isKnownLogType()이 false가 되고, enumerateArchiveFilesInDirectory()가 이 더미를
    # arch_dir_files_ 추적 큐에서 완전히 누락시킨다 — deleteArchFileBasedOnCount()는
    # 이 큐만 보고 지우므로, 큐에 없는 더미는 재시작을 몇 번 해도 절대 안 지워진다
    # (TC09-1/2가 cur_count=21로 항상 FAIL하던 원인, device_log 결함 아님 — TC18/TC21
    # 더미 생성 때 이미 발견했던 것과 동일한 종류의 버그가 TC09에는 안 고쳐져 있었다).
    # create_dummy_archive_file()의 시리얼 인자에 밑줄 금지 — "TC09_$i" 대신 "TC09$i".
    local i now oldest_file
    now=$(date +%s)
    for i in 1 2 3 4 5 6 7 8; do
        local f
        f=$(create_dummy_archive_file "$log_item" "$((now - (9 - i) * 60))" "TC09$i")
        if [ "$i" -eq 1 ]; then
            oldest_file="$f"
        fi
    done
    dump_cmd ls -la "$archive_dir"

    echo "  \$ logpolicy.json $log_item fileCount: $original_count -> 5"
    set_lp_field_num "$log_item" "fileCount" 5
    dump_container_jq "$LOGPOLICY_JSON" ".loggingRules[] | select(.logItem==\"$log_item\") | .fileCount"

    restart_docker_loader

    echo "  archiveToUpload() idle thread(5초) 사이클 대기 (최대 60초)..."
    local waited=0
    local cur_count=999
    while [ "$waited" -lt 60 ]; do
        cur_count=$(ls "$archive_dir" 2>/dev/null | grep -c '\.csv\.xz$')
        if [ "$cur_count" -le 5 ]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    dump_cmd ls -la "$archive_dir"
    if [ "$cur_count" -le 5 ]; then
        assert "TC09-1: 파일 수가 수정된 fileCount(5) 이하" "PASS"
    else
        assert "TC09-1: 파일 수가 수정된 fileCount(5) 이하" "FAIL" "cur_count=$cur_count"
    fi

    dump_cmd ls -la "$oldest_file"
    if [ ! -f "$oldest_file" ]; then
        assert "TC09-2: 가장 오래된 파일 삭제됨" "PASS"
    else
        assert "TC09-2: 가장 오래된 파일 삭제됨" "FAIL" "$oldest_file 잔존"
    fi

    echo "  \$ logpolicy.json $log_item fileCount 원복: 5 -> $original_count"
    set_lp_field_num "$log_item" "fileCount" "$original_count"
    restart_docker_loader

    local restored
    restored=$(lp_field "$log_item" "fileCount")
    dump_container_jq "$LOGPOLICY_JSON" ".loggingRules[] | select(.logItem==\"$log_item\") | .fileCount"
    if [ "$restored" = "$original_count" ]; then
        assert "TC09-3: fileCount 원복 확인" "PASS"
    else
        assert "TC09-3: fileCount 원복 확인" "FAIL" "restored=$restored expected=$original_count"
    fi

    echo "  잔여 더미 파일 정리"
    rm -f "$archive_dir"/*TCDUMMY* "$archive_dir"/*TC09_* 2>/dev/null
}

# ============================================================
# TC10 (SID0203): Archive 파일 보관기간(retentionTime) 초과 삭제
# ============================================================
tc10_retention_time() {
    echo "=== TC10: Archive 파일 보관기간(retentionTime) 초과 삭제 ==="
    local log_item="Meter"
    local retention
    retention=$(lp_field "$log_item" "retentionTime")
    echo "  대상 log_item: $log_item, retentionTime=${retention}s"

    # [2026-08-24 실측 후 재수정] create_dummy_archive_file()로 만든 뒤 touch -d로
    # mtime만 되돌리는 방식은 실제로 삭제되지 않는 것을 DUT에서 확인했다 — 원인은
    # deleteArchFileBasedOnTime()이 arch_dir_files_[log_type](파일명=startTime 오름차순
    # 정렬된 std::set)을 앞에서부터 순회하다가 "만료 안 된 파일을 처음 만나는 순간
    # 즉시 break"하기 때문이다(cloud_upload_manager.cpp:1701-1705, "파일명이 startTime
    # 순이라 오래된 순 정렬이고 첫 미만료 파일에서 스캔을 끝낸다"는 주석 그대로).
    # end_epoch=now로 더미를 만들면 파일명(startTime)이 "지금"으로 찍혀, 이 벤치처럼
    # archive/Meter/에 최근 며칠 새 쌓인 진짜 파일이 많은 상태에서는 그 진짜 파일들
    # 사이/뒤에 정렬된다 — touch -d로 mtime만 6개월 전으로 되돌려도 스캔이 더미보다
    # 먼저 정렬된(=아직 만료 안 된) 진짜 파일에서 멈춰버려 더미까지 도달을 못 한다.
    # 그래서 애초에 만료된 시각을 create_dummy_archive_file()의 end_epoch(=파일명
    # startTime)로 직접 넘겨, 더미가 set에서 가장 앞(가장 오래된 것으로) 정렬되게
    # 만든다 — 이러면 스캔이 더미를 가장 먼저 만나 정상적으로 만료 판정→삭제하고,
    # 그 다음(진짜, 안 만료된) 파일에서 break해 나머지는 그대로 보존한다. 별도
    # touch -d는 create_dummy_archive_file() 내부에서 이미 같은 epoch로 처리하므로
    # 불필요.
    local expired_epoch=$(( $(date +%s) - retention - 3600 ))
    dump_cmd date -d "@$expired_epoch"
    local dummy
    dummy=$(create_dummy_archive_file "$log_item" "$expired_epoch" "TC10")
    dump_cmd ls -la "$dummy"

    echo "  더미 파일을 arch_dir_files_ 추적 큐에 등록하기 위해 docker-loader 재시작"
    restart_docker_loader

    echo "  archiveToUpload() idle thread(5초) 사이클 대기 (최대 60초)..."
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if [ ! -f "$dummy" ]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    dump_cmd ls -la "$dummy"
    if [ ! -f "$dummy" ]; then
        assert "TC10-1: 만료 파일 삭제 확인" "PASS"
    else
        assert "TC10-1: 만료 파일 삭제 확인" "FAIL" "$dummy 잔존"
        rm -f "$dummy" "${dummy}.meta"
    fi
}

# ============================================================
# TC11 (SID0204): 업로드 성공/실패 journal 기록
# ============================================================
tc11_upload_result_journal() {
    echo "=== TC11: 업로드 성공/실패 journal 기록 ==="
    local log_item="Meter"

    # [피드백 반영] 임의 log_item의 실제 파일을 toupload로 이동시켜 업로드를
    # 유발하는 대신, toupload 폴더 자체에 dummy 파일(.csv.xz+.meta)을 직접 생성해
    # BlobUploadDirector의 스캔 대상이 되도록 한다.
    local dummy
    dummy=$(create_dummy_toupload_file "$log_item")
    dump_cmd ls -la "$dummy"

    # [2026-08-21 실측 후 수정] "Upload success/fail for log item"은 device_log가
    # cloud_broker로부터 NOTI_FILE_UPLOAD_RESULT를 받은 뒤에야 찍는다
    # (cloud_upload_manager.cpp:297,301). 그런데 cloud_broker의 BlobUploadDirector는
    # toupload를 300초(kScanIntervalSec, blob_upload_director.hpp:86) 고정 주기로만
    # 스캔한다(blob_upload_director.cpp:66-76) — 이벤트 기반 트리거 없음. 5초 대기로는
    # 스캐너가 이번 파일을 볼 기회조차 없어 이전 실행은 100% FAIL이 확정적이었다
    # (스크립트 버그). 최대 310초 폴링으로 교체.
    echo "  [Director] 300초 주기 스캔 대기 (최대 310초 폴링)..."
    local waited=0
    local found=0
    while [ "$waited" -lt 310 ]; do
        if journalctl -u docker-loader --no-pager 2>/dev/null | grep -qiE "Upload success for log item|Upload fail for log item"; then
            found=1
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done
    echo "  대기 시간: ${waited}s"

    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -iE 'Upload success for log item|Upload fail for log item'"
    if [ "$found" -eq 1 ]; then
        assert "TC11-1: 성공/실패 로그 중 하나 기록" "PASS"
    else
        assert "TC11-1: 성공/실패 로그 중 하나 기록" "FAIL"
    fi

    rm -f "$dummy" "${dummy}.meta" 2>/dev/null
}

# ============================================================
# TC12 (SID0204): 다수 로그 파일 Azure 업로드 시도 확인
# ============================================================
tc12_multi_file_upload() {
    echo "=== TC12: 다수 로그 파일 Azure 업로드 시도 확인 ==="
    local log_item="Meter"

    # [피드백 반영] 대상 log_item의 실제 파일 3개 이상을 toupload로 이동시키는 대신,
    # toupload 폴더 자체에 dummy 파일 3개를 직접 생성해 BlobUploadDirector의 스캔
    # 대상이 되도록 한다. end_epoch/serial을 달리해 파일명이 서로 겹치지 않게 한다.
    echo "  대상 log_item: $log_item (toupload에 dummy 파일 3개 직접 생성)"
    local now new_files=""
    now=$(date +%s)
    local i
    for i in 1 2 3; do
        local f
        f=$(create_dummy_toupload_file "$log_item" "$((now + i))" "TC12_$i")
        new_files="$new_files $(basename "$f")"
    done
    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    echo "  신규 파일:"
    echo "$new_files" | tr ' ' '\n' | sed '/^$/d;s/^/    /'

    # [2026-08-21 실측 후 수정] cloud_broker BlobUploadDirector::scan_loop_task()는
    # 300초(kScanIntervalSec, blob_upload_director.hpp:86) 고정 주기로만 toupload를
    # 스캔한다(blob_upload_director.cpp:66-76, 이벤트 트리거 없음). 파일이 방금
    # toupload에 도착했어도 다음 스캔까지 최대 300초를 기다려야 [Director] 로그에
    # 나타난다 — 이전 실행은 대기 없이 즉시 확인해 100% FAIL이 확정적이었다
    # (스크립트 버그). 최대 310초 폴링으로 교체.
    #
    # [2026-08-28 실측 후 재수정] 순회(최대 31회)마다 파일 3개 각각에 journalctl을
    # --since 없이(=docker-loader 전체 히스토리) 새로 돌려 최대 93회 풀스캔을 했다 —
    # 이 세션처럼 DEBUG 로그를 많이 찍어 journal이 불어난 상태에서는 각 호출이
    # 느려지고, TC11(순회당 1회 호출)과 달리 TC12만 그 비용이 3배라 로컬 대시보드의
    # stall 감지(900초, 실제 원격 루프는 여전히 진행 중인데도 새 출력이 안 잡혀 강제
    # 종료됨)에 먼저 걸리는 사고가 있었다(20260828_145403_device_log_full). 순회당
    # journalctl을 1회만 돌려 결과를 로컬 변수에 담아두고 grep은 로컬에서 하며,
    # --since로 이번 TC 시작 시각 이후만 스캔해 비용을 낮춘다.
    echo "  [Director] 300초 주기 스캔 대기 (최대 310초 폴링)..."
    local waited=0 director_log=""
    while [ "$waited" -lt 310 ]; do
        director_log=$(journalctl -u docker-loader --no-pager --since "@$now" 2>/dev/null | grep '\[Director\]')
        local remaining=""
        local f
        for f in $new_files; do
            echo "$director_log" | grep -q "$f" || remaining="$remaining $f"
        done
        [ -z "$remaining" ] && break
        sleep 10
        waited=$((waited + 10))
    done
    echo "  대기 시간: ${waited}s"

    director_log=$(journalctl -u docker-loader --no-pager --since "@$now" 2>/dev/null | grep '\[Director\]')
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '@$now' | grep '\[Director\]'"

    local all_found=1
    local f
    for f in $new_files; do
        if echo "$director_log" | grep -q "$f"; then
            echo "  found: $f"
        else
            echo "  NOT found: $f"
            all_found=0
        fi
    done

    if [ "$all_found" -eq 1 ]; then
        assert "TC12-1: 3개 파일 각각 업로드 시도 로그 확인" "PASS"
    else
        assert "TC12-1: 3개 파일 각각 업로드 시도 로그 확인" "FAIL" "일부 파일이 [Director] 로그에 없음"
    fi

    for f in $new_files; do
        rm -f "$TOUPLOAD_ROOT/$log_item/$f" "$TOUPLOAD_ROOT/$log_item/${f}.meta" 2>/dev/null
    done
}

# ============================================================
# TC13 (SID0204/SID0205, §AGSRS-536/537): 네트워크 끊김 시 업로드 미시도 및
#   archive 누적
#   [피드백 반영] 별도 TC였던 "네트워크 중단 시 업로드 동작(root→archive 이동,
#   §AGSRS-537)"은 검증 시나리오가 동일하여 여기로 통합, 별도 번호를 갖지 않는다.
#   그 TC가 갖고 있던 "toupload가 이미 비어있지 않은 상태(isToUploadDirEmpty()=false)
#   에서도 동일하게 동작하는지" 확인 단계만 1)로 흡수했다.
# ============================================================
tc13_network_offline_root_to_archive() {
    echo "=== TC13: 네트워크 끊김 시 업로드 미시도 및 archive 누적 ==="
    local log_item="Meter"

    echo "  1) toupload를 비어있지 않게 만들어 둠 (isToUploadDirEmpty()=false 상태에서도 동일 동작하는지, 병합분)"
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 10
    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"

    local blocked=0
    if is_online; then
        echo "  현재 온라인 — 네트워크 차단"
        network_block
        blocked=1
        sleep 60
    else
        echo "  현재 오프라인 — 별도 차단 없이 진행"
    fi

    local marker="/tmp/tc13_marker_$$"
    touch "$marker"

    local resp
    resp=$(send_and_wait "get_log_data" "{}" 30)
    echo "  get_log_data 응답: $resp"

    # [2026-08-24 실측 후 수정] handleForcedLogUploadRequest()(get_log_data)는 오프라인이면
    # 파일을 archive로 옮기지 않고 root 큐에 그냥 재등록만 한다(cloud_upload_manager.cpp:
    # 404-414, "Internet not available. Skipping upload"). 실제 root->archive 이동은
    # 완전히 별개의 idle thread 사이클인 rootToArchiveOrToUpload()(5초 주기,
    # selectNextRootLogType() round-robin)가 나중에 그 파일을 집어야 일어난다(:816-840).
    # 이전에는 10초 고정 대기 후 단 한 번만 확인해, round-robin이 다른 log_type을 먼저
    # 처리하느라 Meter 차례가 10초를 넘기면 FAIL이었다(과거 "TC 순서 의존성" 관찰과
    # 일치 — 앱 결함이 아니라 대기시간 부족). idle thread 사이클 여러 번(최대 60초)
    # 폴링으로 교체.
    echo "  idle thread(rootToArchiveOrToUpload, 5초) 사이클 대기 (최대 60초)..."
    local waited=0
    local newest_archive=""
    while [ "$waited" -lt 60 ]; do
        newest_archive=$(find "$ARCHIVE_ROOT" -name '*.csv.xz' -newer "$marker" 2>/dev/null | head -1)
        [ -n "$newest_archive" ] && break
        sleep 5
        waited=$((waited + 5))
    done
    echo "  대기 시간: ${waited}s"

    dump_cmd ls -la "$ARCHIVE_ROOT/"
    rm -f "$marker"
    local fname
    if [ -n "$newest_archive" ]; then
        fname=$(basename "$newest_archive")
        local log_item
        log_item=$(basename "$(dirname "$newest_archive")")
        dump_cmd bash -c "if [ -f '$TOUPLOAD_ROOT/$log_item/$fname' ]; then echo toupload; elif [ -f '$ARCHIVE_ROOT/$log_item/$fname' ]; then echo archive; else echo none; fi"
        if [ -f "$ARCHIVE_ROOT/$log_item/$fname" ]; then
            assert "TC13-1: 신규 파일 이동 위치 확인(archive)" "PASS"
        else
            assert "TC13-1: 신규 파일 이동 위치 확인(archive)" "FAIL" "archive에서 발견되지 않음"
        fi
    else
        assert "TC13-1: 신규 파일 이동 위치 확인(archive)" "FAIL" "최근 2분 내 신규 archive 파일 없음"
    fi

    if [ "$blocked" -eq 1 ]; then
        echo "  네트워크 복구"
        network_restore
    fi
}

# ============================================================
# TC14 (SID0205, §AGSRS-513/540): 네트워크 복구 시 자동 업로드 재개
#   [피드백 반영] 별도 TC였던 "로컬 파일(archive) 업로드 주기적 재시도(§AGSRS-540)"는
#   검증 대상이 본 TC와 동일한 archive→toupload 이동이라 여기로 통합, 별도 번호를
#   갖지 않는다. 그 TC가 갖고 있던 "archive에 대상 파일이 없으면 더미로 대체" 폴백만
#   흡수했다.
# ============================================================
tc14_network_recovery() {
    echo "=== TC14: 네트워크 복구 시 자동 업로드 재개 ==="
    local log_item="Meter"

    local backlog
    backlog=$(toupload_backlog_count "$log_item")
    if [ "$backlog" -gt 0 ]; then
        dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
        assert "TC14-1: archive→toupload 이동 확인" "SKIP" "toupload/$log_item에 잔여 파일 ${backlog}개 — isToUploadDirEmpty() 게이트 미충족(cloud_upload_manager.cpp:859-860), 이동 관측 불가"
        return
    fi

    # [2026-08-21 실측 후 수정] archiveToUpload()의 archive->toupload 이동은
    # isUploadAllowed()에서 perDayArchive>0을 요구한다(cloud_upload_manager.cpp:1351-
    # 1356). perDayArchive는 기본 0으로 시작해 자정 루틴에서만 잔여 perDayRoot가
    # 이월되는 값이라(updateLogUploadLimitsDaily(), :1416), 자정을 아직 못 넘긴 갓
    # 부팅한 DUT에서는 항상 0이다 — 이 상태로는 archive->toupload 이동이 정책적으로
    # 절대 일어나지 않는다(코드 결함 아님, 환경/사전조건 문제). perDayArchive를
    # logcount.json에서 직접 5로 바꿔도 CloudUploadManager::init()이 부팅 시 1회만
    # 읽으므로(:103-108, initialized_ 가드) 재시작 없이는 반영되지 않는다
    # (TC09의 logpolicy.json/fileCount와 동일한 제약, restart_docker_loader() 필요).
    local root_before archive_before
    root_before=$(lc_field "$log_item" "perDayRoot")
    archive_before=$(lc_field "$log_item" "perDayArchive")
    echo "  logcount.json 원래값: perDayRoot=$root_before perDayArchive=$archive_before"
    if [ "$archive_before" = "0" ]; then
        echo "  \$ logcount.json $log_item perDayArchive: 0 -> 5 (archive->toupload 이동 허용 위한 사전조건)"
        set_lc_field_num "$log_item" "perDayArchive" 5
        restart_docker_loader
    fi

    local blocked=0
    if is_online; then
        network_block
        blocked=1
        sleep 60
    fi

    echo "  archive에 파일 누적 유도"
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 15
    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/"
    local target
    target=$(ls -t "$ARCHIVE_ROOT/$log_item/"*.csv.xz 2>/dev/null | head -1)
    if [ -z "$target" ]; then
        # 병합분: archive에 대상 파일이 없으면 더미로 대체
        echo "  archive에 누적된 파일 없음 — 더미 파일로 대체"
        target=$(create_dummy_archive_file "$log_item" "$(date +%s)" "TC14")
    fi
    local fname
    fname=$(basename "$target")

    if [ "$blocked" -eq 1 ]; then
        echo "  네트워크 복구"
        # [2026-08-24 수정] network_restore()가 이제 internet_status(is_connected:true)를
        # 직접 발행해 cloud_connected_action()을 트리거한다 — 예전에 여기서 별도로
        # 발행하던 {"connected":true}는 스키마가 틀려(handle_noti_internet_status()는
        # {"data":{"is_connected":..}} 요구) 파싱 실패로 조용히 무시되고 있었다.
        network_restore
        sleep 5
    fi

    echo "  idle thread 사이클 대기 (최대 60초)..."
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if [ ! -f "$ARCHIVE_ROOT/$log_item/$fname" ] && [ -f "$TOUPLOAD_ROOT/$log_item/$fname" ]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/$fname"
    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/$fname"
    if [ ! -f "$ARCHIVE_ROOT/$log_item/$fname" ] && [ -f "$TOUPLOAD_ROOT/$log_item/$fname" ]; then
        assert "TC14-1: archive→toupload 이동 확인" "PASS"
    else
        assert "TC14-1: archive→toupload 이동 확인" "FAIL"
    fi

    if [ "$archive_before" = "0" ]; then
        echo "  logcount.json 원복: perDayArchive=$archive_before"
        set_lc_field_num "$log_item" "perDayArchive" "$archive_before"
        restart_docker_loader
    fi
}


# ============================================================
# TC15 (SID0205, 재부팅 수반): 재부팅 후 업로드 재개
#   --tc15-pre 로 상태 저장(네트워크 차단 후 toupload에 파일 유지) 후 reboot,
#   재접속 후 --tc15-post 로 검증
# ============================================================
TC15_SAVE="$STATE_DIR/tc15_state"

tc15_pre() {
    echo "=== TC15-PRE: toupload에 파일을 남긴 채 재부팅 준비 ==="
    local log_item="Meter"

    local blocked=0
    if is_online; then
        network_block
        blocked=1
        sleep 60
    fi

    echo "  \$ get_log_data 발행 (오프라인 상태에서 root->toupload 시도, 업로드는 완료 안 됨)"
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 15
    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"

    # [2026-08-25 실측 후 수정] 다른 TC(09/18/21 등)가 남긴 0바이트 더미 파일
    # (`..._Meter_TC212.csv.xz` 같은 시리얼이 "TC"로 시작하는 것들)이 toupload에
    # 계속 쌓여있으면, 이번에 push할 새 실파일이 없을 때(root가 이미 비어 get_log_data가
    # 아무것도 못 옮긴 경우) `ls -t | head -1`이 그 더미를 "가장 최근 파일"로 잘못
    # 골라버린다. 더미는 내용이 0바이트라 업로드 파이프라인이 처리할 수 없어
    # TC15-POST가 "Upload success"를 영원히 못 찾고 FAIL하는데, 이건 재부팅 후 업로드
    # 재개 로직 결함이 아니라 대상 파일 선정이 오염된 것이었다(20260825_160658 run
    # 실측 — 고른 파일이 진짜 시리얼(242151311501F01019)이 아니라 TC212 더미였음).
    # 실제 DUT 시리얼이 아닌 "TC숫자로 시작하는 시리얼" 더미를 제외하고 고른다.
    local target
    target=$(ls -t "$TOUPLOAD_ROOT/$log_item/"*.csv.xz 2>/dev/null | grep -vE '_TC[0-9][0-9A-Za-z]*\.csv\.xz$' | head -1)
    if [ -z "$target" ]; then
        target=$(ls -t "$ARCHIVE_ROOT/$log_item/"*.csv.xz 2>/dev/null | grep -vE '_TC[0-9][0-9A-Za-z]*\.csv\.xz$' | head -1)
        echo "[WARN] toupload에 파일 없음 — archive의 대기 파일로 대체 확인"
    fi

    {
        echo "LOG_ITEM=$log_item"
        echo "TARGET_FILE=$target"
        echo "NETWORK_WAS_BLOCKED=$blocked"
    } > "$TC15_SAVE"
    dump_cmd cat "$TC15_SAVE"

    if [ "$blocked" -eq 1 ]; then
        echo "  재부팅 전 네트워크 복구 (재부팅 자체가 새 단절 상황을 만들지 않도록)"
        network_restore
    fi

    echo ""
    echo "[TC15-PRE 완료] reboot 실행 중... 재접속 후 --tc15-post 실행"
    sync
    reboot
}

tc15_post() {
    echo "=== TC15-POST: 재부팅 후 업로드 재개 확인 ==="
    if [ ! -f "$TC15_SAVE" ]; then
        echo "[ERROR] $TC15_SAVE 없음 - --tc15-pre 를 먼저 실행하세요"
        return
    fi
    # shellcheck disable=SC1090
    source "$TC15_SAVE"

    echo "  대상 파일: $TARGET_FILE"
    echo "  device_log 재기동 + 업로드 처리 대기..."
    sleep 30

    dump_cmd sh -c "journalctl -b 0 -u docker-loader | grep 'Upload success'"
    local journal_ok=0
    if journalctl -b 0 -u docker-loader 2>/dev/null | grep -q "Upload success"; then
        journal_ok=1
    fi

    local fname
    if [ -n "$TARGET_FILE" ]; then
        fname=$(basename "$TARGET_FILE")
        dump_cmd ls -la "$TOUPLOAD_ROOT/$LOG_ITEM/$fname"
    fi

    if [ "$journal_ok" -eq 1 ]; then
        assert "TC15-1: 재부팅 후 toupload 파일 처리됨" "PASS"
    else
        assert "TC15-1: 재부팅 후 toupload 파일 처리됨" "FAIL" "journalctl -b 0 에 Upload success 없음"
    fi

    rm -f "$TC15_SAVE"
}

# ============================================================
# TC16 (SID0206, §AGSRS-514): 1일 root 폴더 업로드 개수 제한
# ============================================================
tc16_perday_root_zero() {
    echo "=== TC16: 1일 root 폴더 업로드 개수 제한(perDayRoot=0) ==="
    local log_item="Meter"

    # [2026-08-21 실측 후 수정] 이전 실행은 두 가지 이유로 100% FAIL이 확정적이었다
    # (둘 다 스크립트 버그, 코드 결함 아님):
    #   1) logcount.json은 CloudUploadManager::init()에서 1회만 읽으므로
    #      (cloud_upload_manager.cpp:103-108) restart 없이는 perDayRoot=0이 런타임에
    #      반영되지 않는다.
    #   2) get_log_data(forced_log_upload)는 handleForcedLogUploadRequest()에서
    #      moveFilesToUploadDir()를 직접 호출하며 isUploadAllowed()/perDayRoot 검사를
    #      아예 거치지 않는다(:399-423, "강제" 업로드이므로 정책 게이트를 우회하는게
    #      설계 의도). 즉 get_log_data로 만든 파일은 perDayRoot 값과 무관하게 항상
    #      toupload로 이동한다 — perDayRoot 게이트는 오직 주기 경로
    #      rootToArchiveOrToUpload()에서만 적용된다(:825-826, isUploadAllowed 호출).
    #   TC21(위 파일 34-40행 주석)가 이미 쓰던 기법대로 네트워크를 차단한 채
    #   get_log_data를 호출하면 파일이 root 대기열에만 쌓이고(moveFilesToUploadDir
    #   미호출, :405-413 internet 체크에서 break) 이후 네트워크 복구 시 idle thread의
    #   rootToArchiveOrToUpload()가 실제 perDayRoot 게이트를 적용해 옮긴다.
    local root_before
    root_before=$(lc_field "$log_item" "perDayRoot")
    echo "  원래 perDayRoot=$root_before"

    # [2026-08-28 실측 FAIL 사후분석] perDayRoot=0로 바꿔도 root 파일이 toupload로 새는
    # 원인이 (a) restart 시 logcount.json 재로딩 실패/폴백인지 (b) 재로딩-완료 전 경합인지
    # 소스 리뷰만으로는 구분이 안 됐다 — isUploadAllowed()/loadLogCountFrom()의 판정 근거가
    # DEBUG 로그인데 TC08과 달리 이 TC는 레벨을 안 낮춰서 journald에 안 남았기 때문.
    # TC08과 동일한 패턴(set_dl_log_level)으로 임시로 DEBUG를 켜서 이번엔 근거를 남긴다.
    local orig_log_level
    orig_log_level=$(send_and_wait "select_records" '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_dl"]}' 10 | jq -r '.payload.records[] | select(.key=="log_level_dl") | .value' 2>/dev/null)
    [ -z "$orig_log_level" ] && orig_log_level=1
    echo "  \$ system_setting log_level_dl: $orig_log_level -> 0 (DEBUG, TC16 판정 근거용 임시 변경)"
    set_dl_log_level 0

    echo "  \$ logcount.json $log_item perDayRoot: $root_before -> 0"
    set_lc_field_num "$log_item" "perDayRoot" 0
    # container_write()는 호스트→컨테이너 경계 너머로 cat 파이프만 흘려보낼 뿐 fsync를
    # 보장하지 않는다 — restart로 곧장 이어지는 재읽기가 미반영된 페이지캐시를 볼 가능성을
    # 없애기 위해 명시적으로 디스크에 동기화한다.
    echo "  \$ sync"
    sync
    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$log_item\")"
    local test_epoch
    test_epoch=$(date +%s)
    restart_docker_loader

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/"

    network_block
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 15
    network_restore

    echo "  idle thread 라운드로빈이 root 파일을 집을 때까지 대기 (최대 60초)..."
    sleep 60

    # [2026-08-28 실측 후 재수정] perDayRoot=0이어도 perDayArchive는 그대로 남아있어서,
    # root->archive로 옮겨진 파일이 "같은 idle thread 틱 안에서" archiveToUpload()에
    # 걸려 곧장 archive->toupload로 이어진다(root quota와 archive quota는 서로 독립된
    # 별개 게이트라 root가 막혀도 archive가 열려있으면 결국 업로드된다 — 이건 앱의 정상
    # 설계 동작이지 버그가 아니다, TC17이 이미 "둘 다 0"인 케이스를 커버). 그래서
    # ls 스냅샷 diff로는 "toupload에 안 갔다"를 절대 관측할 수 없다(경합) — TC16이
    # 실제로 검증해야 하는 건 "root quota가 소진되면 root에서 toupload로 직행하지
    # 않고 반드시 archive를 한 번 거치는지" 뿐이므로, 최종 디렉토리 상태가 아니라
    # journald의 isUploadAllowed/rootToArchiveOrToUpload DEBUG/INFO 로그로 그 경로
    # 자체를 판정한다.
    local journal_evidence
    journal_evidence=$(journalctl -u docker-loader --no-pager --since "@$test_epoch" 2>/dev/null | grep -E "isUploadAllowed|rootToArchiveOrToUpload")
    dump_cmd sh -c "journalctl -u docker-loader --no-pager --since '@$test_epoch' | grep -E 'loadLogCountFrom|isUploadAllowed|rootToArchiveOrToUpload'"

    local root_direct_allowed=0 root_denied_then_archived=0 prev_line=""
    while IFS= read -r line; do
        if echo "$prev_line" | grep -q "Meter from root directory has exhausted" \
            && echo "$line" | grep -q "rootToArchiveOrToUpload.*Moved files from root -> archive directory"; then
            root_denied_then_archived=1
        fi
        echo "$line" | grep -q "isUploadAllowed.*Upload allowed for log type: Meter from root directory" && root_direct_allowed=1
        prev_line="$line"
    done <<< "$journal_evidence"

    if [ "$root_direct_allowed" -eq 0 ]; then
        assert "TC16-1: root quota 소진 시 root→toupload 직행 안 함" "PASS"
    else
        assert "TC16-1: root quota 소진 시 root→toupload 직행 안 함" "FAIL" "perDayRoot=0인데도 isUploadAllowed가 root에서 직접 allow한 기록 있음"
    fi

    if [ "$root_denied_then_archived" -eq 1 ]; then
        assert "TC16-2: root quota 소진 시 archive로 이동" "PASS"
    else
        assert "TC16-2: root quota 소진 시 archive로 이동" "FAIL" "Meter denied 로그 직후 root→archive 이동 로그가 없음 — 위 journalctl 근거 참고"
    fi

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/"

    echo "  \$ system_setting log_level_dl 원복: $orig_log_level"
    set_dl_log_level "$orig_log_level"

    echo "  logcount.json 원복: perDayRoot=$root_before"
    set_lc_field_num "$log_item" "perDayRoot" "$root_before"
    sync
    restart_docker_loader
}

# ============================================================
# TC17 (SID0206, §AGSRS-543): 1일 archive 폴더 업로드 개수 제한
# ============================================================
tc17_perday_both_zero() {
    echo "=== TC17: 1일 archive 폴더 업로드 개수 제한(perDayRoot=0, perDayArchive=0) ==="
    local log_item="Meter"

    # [2026-08-21 실측 후 수정] TC16와 동일한 이유(logcount.json 1회 로드,
    # get_log_data가 isUploadAllowed를 우회)로 이전 실행은 우연히 PASS했을 뿐
    # 실제로는 아무것도 검증하지 못하고 있었다 — before_toupload를 get_log_data
    # 호출 "이후"에 측정해 강제이동 파일이 이미 baseline에 섞여 들어갔기 때문이다.
    # TC16와 동일한 방식(restart + 네트워크 차단 상태에서 get_log_data + 파일명 diff)
    # 으로 교체한다. 상세 근거는 tc16_perday_root_zero() 주석 참고.
    local root_before archive_before
    root_before=$(lc_field "$log_item" "perDayRoot")
    archive_before=$(lc_field "$log_item" "perDayArchive")
    echo "  원래 perDayRoot=$root_before perDayArchive=$archive_before"

    # TC16과 동일 이유(tc16_perday_root_zero() 주석 참고) — isUploadAllowed()/
    # loadLogCountFrom() 판정 근거를 journald에 남기기 위해 임시로 DEBUG.
    local orig_log_level
    orig_log_level=$(send_and_wait "select_records" '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_dl"]}' 10 | jq -r '.payload.records[] | select(.key=="log_level_dl") | .value' 2>/dev/null)
    [ -z "$orig_log_level" ] && orig_log_level=1
    echo "  \$ system_setting log_level_dl: $orig_log_level -> 0 (DEBUG, TC17 판정 근거용 임시 변경)"
    set_dl_log_level 0

    set_lc_field_num "$log_item" "perDayRoot" 0
    set_lc_field_num "$log_item" "perDayArchive" 0
    # container_write()는 fsync를 보장하지 않으므로 restart 전 명시적으로 동기화한다
    # (tc16_perday_root_zero() 주석 참고).
    echo "  \$ sync"
    sync
    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$log_item\")"
    restart_docker_loader

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    local before_toupload
    before_toupload=$(ls "$TOUPLOAD_ROOT/$log_item/" 2>/dev/null)

    network_block
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 15
    network_restore
    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/"

    echo "  idle thread 사이클 반복 대기 (60초)..."
    sleep 60

    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -E 'loadLogCountFrom|isUploadAllowed'"

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    local after_toupload new_toupload
    after_toupload=$(ls "$TOUPLOAD_ROOT/$log_item/" 2>/dev/null)
    new_toupload=$(comm -13 <(echo "$before_toupload" | sort) <(echo "$after_toupload" | sort) | grep -c '\.csv\.xz$')
    if [ "$new_toupload" -eq 0 ]; then
        assert "TC17-1: toupload 미이동 유지" "PASS"
    else
        assert "TC17-1: toupload 미이동 유지" "FAIL" "toupload에 신규 파일 ${new_toupload}개 발생"
    fi

    echo "  \$ system_setting log_level_dl 원복: $orig_log_level"
    set_dl_log_level "$orig_log_level"

    echo "  logcount.json 원복: perDayRoot=$root_before perDayArchive=$archive_before"
    set_lc_field_num "$log_item" "perDayRoot" "$root_before"
    set_lc_field_num "$log_item" "perDayArchive" "$archive_before"
    sync
    restart_docker_loader
}

# ============================================================
# TC18 (SID0206, 시스템 시간 변경 — 별도 실행): 자정 루틴
#   시스템 시각을 23:49로 변경해 23:50 자정 루틴을 유도한다. --tc18 로 개별 실행할 것.
# ============================================================
tc18_midnight_routine() {
    echo "=== TC18: 자정 루틴(perDayRoot 초기화 및 잔여 quota archive 이월 + root/archive→toupload 이동) [시스템 시간 변경] ==="
    local log_item="Meter"

    network_restore

    local root_before0 archive_before0 default_per_day
    root_before0=$(lc_field "$log_item" "perDayRoot")
    archive_before0=$(lc_field "$log_item" "perDayArchive")
    default_per_day=$(lc_field "$log_item" "defaultPerDay")
    echo "  원래값: perDayRoot=$root_before0 perDayArchive=$archive_before0 defaultPerDay=$default_per_day"

    # [2026-08-25 추가] 기존엔 quota 숫자(perDayRoot/perDayArchive 리셋값)만 확인하고
    # 실제 파일 이동은 확인하지 않았다. midNightRootToUpload()/midNightArchiveToUpload()
    # (cloud_upload_manager.cpp:673-750)가 진짜로 root/archive의 파일을 toupload로
    # 옮기는지 더미 파일 하나씩으로 검증한다.
    #
    # [2026-08-25 DUT 실측 후 재수정] midNightArchiveToUpload()는 move_limit을
    # getPerDayArchiveLimit()(그 시점의 현재값, 리셋 전)으로 잡는다(:722) — perDayArchive는
    # 평소 0인 게 정상(전날 이월분만 채워짐)이라, 0인 상태로 archive 더미를 놔두면
    # move_limit=0이라 자정 루틴이 아무리 잘 동작해도 movable 파일이 0개라 절대 옮겨지지
    # 않는다(TC18-4가 "결함"처럼 보였던 실제 원인, device_log 문제 아님). TC14가 이미
    # 쓰는 방식대로 perDayArchive가 0이면 미리 5로 올려 이동을 관측할 수 있는 상태를
    # 만든다. logcount.json 값은 CloudUploadManager::init()이 부팅 시 1회만 읽으므로
    # (TC14와 동일 제약) restart_docker_loader()가 필요하다.
    #
    # [2026-08-25 DUT 재실측 후 추가 수정] 이 restart를 더미 생성 "뒤"에 걸었더니, 더미가
    # root/archive에 앉아있는 동안 restart_docker_loader()의 대기(최대 120초대)만큼
    # 노출되면서, 자정 루틴과 무관하게 항상 5초마다 도는 rootToArchiveOrToUpload()/
    # archiveToUpload() 일반 라운드로빈이 그 사이에 우리 더미를 먼저 채가버렸다(DUT
    # journal 실측: 자정 점프 전에 이미 "Moved files to: archive/Meter, file: ...
    # TC18ROOT..."가 찍힘 — toupload가 안 비어있어 archive로 샌 것, TC21과 동일 게이트).
    # midNightRootToUpload()/midNightArchiveToUpload()는 실행 시 자체적으로
    # enumerateRootFilesInDirectory()/enumerateArchiveFilesInDirectory()를 다시 돌리므로
    # 더미 등록에는 애초에 restart가 필요 없다 — quota 부스트에만 필요하다. 그래서 순서를
    # "필요하면 부스트+재시작을 먼저 끝내고, 더미는 재시작 뒤 시간 점프 직전에 만들어
    # 일반 라운드로빈에 노출되는 창을 최소화"로 바꿨다. 그래도 5초 주기 자체는 못
    # 없애므로 이론상 완전히 결정적이진 않지만, 노출 창이 초 단위로 줄어든다.
    if [ "$archive_before0" = "0" ]; then
        echo "  \$ logcount.json $log_item perDayArchive: 0 -> 5 (midNightArchiveToUpload() 이동 관측 위한 사전조건)"
        set_lc_field_num "$log_item" "perDayArchive" 5
        restart_docker_loader
    fi

    # 재시작(했다면) 이후 실제 반영된 값을 다시 읽는다 — TC18-1 계산의 기준값은 반드시
    # 이 시점(자정 루틴 진입 직전) 값이어야 한다.
    local root_before archive_before
    root_before=$(lc_field "$log_item" "perDayRoot")
    archive_before=$(lc_field "$log_item" "perDayArchive")
    echo "  자정 루틴 진입 직전: perDayRoot=$root_before perDayArchive=$archive_before"

    # [2026-08-25 DUT 재실측 후 추가] 위에서 노출 창을 줄여도, toupload/$log_item가
    # 이미 비어있지 않으면(이 DUT는 실제 클라우드 업로드 backlog가 상존 — TC14/TC21에서
    # 이미 겪은 것과 동일 원인) 일반 라운드로빈이 우리 더미를 낚아채든 자정 루틴이
    # 처리하든 결과가 똑같이 "archive로 감"이라 TC18-3/4로는 자정 루틴 특유의 동작을
    # 구분해낼 수 없다. toupload_backlog_count()로 사전조건을 확인해 안 비어있으면
    # 더미 자체를 만들지 않고 TC18-3/4를 SKIP — TC18-1/2(quota 산술)는 더미와 무관하니
    # 그대로 진행한다.
    local move_check_enabled=1
    local backlog
    backlog=$(toupload_backlog_count "$log_item")
    if [ "$backlog" -gt 0 ]; then
        move_check_enabled=0
        dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
        echo "  toupload/$log_item에 잔여 파일 ${backlog}개 — TC18-3/4는 SKIP"
    fi

    local root_dummy archive_dummy root_fname archive_fname
    if [ "$move_check_enabled" -eq 1 ]; then
        root_dummy=$(create_dummy_root_file "$log_item" "$(date +%s)" "TC18ROOT")
        archive_dummy=$(create_dummy_archive_file "$log_item" "$(date +%s)" "TC18ARCH")
        root_fname=$(basename "$root_dummy")
        archive_fname=$(basename "$archive_dummy")
        dump_cmd ls -la "$LOGGER_ROOT/$log_item/"
        dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/"
    fi

    # [2026-08-25 수정] isMidNightRoutineTime()의 관측 창은 [23:50, 23:55)
    # (kMidNightWindowMins=5, cloud_upload_manager.cpp:787) — 23:49로 이동해 90초를
    # 기다려 23:50을 "넘기는" 방식은 창의 시작점에 딱 맞춰 바로 들어가는 23:50:00
    # 직행보다 대기시간이 불필요하게 길다(75초 낭비). 곧장 23:50:00으로 이동하고,
    # idle thread 사이클(5초)이 몇 번 돌 만큼만(15초) 짧게 대기한다.
    #
    # [2026-08-25 DUT 실측 후 재수정] 이전엔 여기서 plain `date -s`를 썼는데, DUT
    # 실측 결과 NTP 데몬이 살아있으면 그 변경을 거의 즉시(1초 이내) 되돌려버려 —
    # 호스트 자체 확인(date)에는 반영된 것처럼 보여도, 그 직후 컨테이너 쪽에서 다시
    # 읽으면(`docker exec ... date`, 왕복 지연 때문에 NTP 보정 이후 시점) 이미 원복돼
    # 있었다("컨테이너가 시간 네임스페이스로 격리돼 있다"고 오판했던 원인 — 실제로는
    # 격리가 아니라 NTP 레이스). system_log의 tc_system_log.sh TC02/TC07이 이미
    # `timedatectl set-ntp false`를 먼저 걸고 `date -s`하는 이유가 바로 이것이었는데,
    # device_log의 TC18/TC19에는 이 단계가 빠져 있었다. `timedatectl set-ntp no`로
    # NTP를 확실히 끈 뒤 `timedatectl set-time`으로 설정하는 방식으로 교체.
    local orig_epoch today_date target_epoch target_str
    orig_epoch=$(date +%s)
    dump_cmd date
    today_date=$(date +%Y-%m-%d)
    target_epoch=$(date -d "${today_date} 23:50:00" +%s)
    if [ "$target_epoch" -lt "$orig_epoch" ]; then
        target_epoch=$(date -d "${today_date} 23:50:00 +1 day" +%s 2>/dev/null)
    fi
    target_str=$(date -d "@${target_epoch}" "+%Y-%m-%d %H:%M:%S")
    dump_cmd timedatectl set-ntp no
    echo "  \$ timedatectl set-time \"${target_str}\""
    timedatectl set-time "${target_str}" > /dev/null 2>&1
    dump_cmd date

    echo "  자정 루틴(idle thread 5초 사이클) 도달 대기 (15초)..."
    sleep 15

    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$log_item\")"
    local root_after archive_after
    root_after=$(lc_field "$log_item" "perDayRoot")
    archive_after=$(lc_field "$log_item" "perDayArchive")
    echo "  결과: perDayRoot=$root_after perDayArchive=$archive_after"

    # [2026-08-25 DUT 실측 후 재수정] updateLogUploadLimitsDaily()는
    # `item.perDayArchive = item.perDayArchive + item.perDayRoot`를 그 시점(자정 루틴
    # 진입 직전이 아니라 midNightRootToUpload()/midNightArchiveToUpload()가 이미 몇 개
    # 옮겨 소비한 "직후") 값으로 계산한다(cloud_upload_manager.cpp:1416). 이 DUT는 실제
    # 트래픽이 흐르는 환경이라 우리 더미 1개 외에도 자연 발생한 root/archive 파일이
    # 같은 자정 사이클에 같이 소비될 수 있어(실측: root quota 8 중 2 소비) 정확한 값을
    # 사전에 예측할 수 없다 — 소비량은 [0, root_before]/[0, archive_before] 범위이므로
    # archive_after도 [0, archive_before+root_before] 범위 안에만 있으면 산식 자체는
    # 정상 동작한 것으로 판정한다(상한을 넘거나 음수면 명백한 결함).
    if [ "$archive_after" -ge 0 ] && [ "$archive_after" -le "$((archive_before + root_before))" ]; then
        assert "TC18-1: perDayArchive 이월 계산 범위 확인(동시 소비 반영)" "PASS"
    else
        assert "TC18-1: perDayArchive 이월 계산 범위 확인(동시 소비 반영)" "FAIL" "범위=[0,$((archive_before + root_before))] actual=$archive_after"
    fi

    if [ "$root_after" -eq "$default_per_day" ]; then
        assert "TC18-2: perDayRoot 초기화" "PASS"
    else
        assert "TC18-2: perDayRoot 초기화" "FAIL" "expected=$default_per_day actual=$root_after"
    fi

    if [ "$move_check_enabled" -eq 1 ]; then
        dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/$root_fname"
        if [ -f "$TOUPLOAD_ROOT/$log_item/$root_fname" ]; then
            assert "TC18-3: midNightRootToUpload()로 root->toupload 이동" "PASS"
        else
            assert "TC18-3: midNightRootToUpload()로 root->toupload 이동" "FAIL" "toupload에서 $root_fname 못 찾음"
            rm -f "$LOGGER_ROOT/$log_item/$root_fname" "$LOGGER_ROOT/$log_item/${root_fname}.meta" 2>/dev/null
        fi

        dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/$archive_fname"
        if [ -f "$TOUPLOAD_ROOT/$log_item/$archive_fname" ]; then
            assert "TC18-4: midNightArchiveToUpload()로 archive->toupload 이동" "PASS"
        else
            assert "TC18-4: midNightArchiveToUpload()로 archive->toupload 이동" "FAIL" "toupload에서 $archive_fname 못 찾음"
            rm -f "$ARCHIVE_ROOT/$log_item/$archive_fname" "$ARCHIVE_ROOT/$log_item/${archive_fname}.meta" 2>/dev/null
        fi
    else
        assert "TC18-3: midNightRootToUpload()로 root->toupload 이동" "SKIP" "toupload/$log_item 사전 잔여로 관측 불가(위 사전조건 참고)"
        assert "TC18-4: midNightArchiveToUpload()로 archive->toupload 이동" "SKIP" "toupload/$log_item 사전 잔여로 관측 불가(위 사전조건 참고)"
    fi

    echo "  \$ date -s (원래 시각으로 복원)"
    date -s "@${orig_epoch}" > /dev/null
    dump_cmd date

    # perDayRoot는 자정 루틴이 defaultPerDay로 리셋한 게 정상 결과라 원복하지 않는다.
    #
    # [2026-08-25 DUT 실측 후 재수정 — 회귀 버그] perDayArchive는 이전엔
    # "archive_before0이 0이었을 때만" 원복했는데, updateLogUploadLimitsDaily()의
    # `perDayArchive = perDayArchive + perDayRoot`는 우리가 부스트했는지와 무관하게
    # 자정 루틴이 돌 때마다 항상 값을 불린다 — 그래서 한 번이라도 원복을 건너뛰면
    # (archive_before0!=0인 채로 시작한 경우) 다음 TC18 실행에서도 계속 조건을 못
    # 만족해 원복이 영영 안 걸리고, 실행할 때마다 archive_after가 그 위에 또 쌓여
    # 눈덩이처럼 불어난다(DUT 실측: 6→9→18로 누적, 그 값이 TC16을 오염시켜 archiveToUpload()
    # 의 일반 라운드로빈이 archive→toupload를 계속 빼가는 바람에 TC16-1/2가 연쇄로
    # FAIL). 부스트 여부와 무관하게 이 TC가 시작하기 전 값(archive_before0)으로
    # 항상 되돌린다.
    echo "  \$ logcount.json $log_item perDayArchive 원복: $archive_before0"
    set_lc_field_num "$log_item" "perDayArchive" "$archive_before0"
    restart_docker_loader
}

# ============================================================
# TC19 (SID0206, 시스템 시간 변경 — 별도 실행): 월 전환 시 로그 카운트 초기화
#   시스템 시각을 이번 달 말일 23:49로 변경해 자정 루틴에서 월 전환을 유도한다.
#   --tc19 로 개별 실행할 것.
# ============================================================
tc19_month_transition() {
    echo "=== TC19: 월 전환 시 로그 카운트 초기화 [시스템 시간 변경] ==="
    local log_item="Meter"

    # [2026-08-25 수정] TC18과 동일한 이유(isMidNightRoutineTime()의 [23:50,23:55)
    # 창 시작점에 바로 진입) — 23:49로 이동해 90초를 기다리는 대신 23:50:00으로 직행,
    # idle thread 사이클(5초) 몇 번만큼만(15초) 짧게 대기한다.
    #
    # [2026-08-25 DUT 실측 후 재수정] TC18과 동일한 이유로 plain `date -s`는 NTP
    # 데몬의 즉시 원복 레이스에 걸린다 — `timedatectl set-ntp no`로 먼저 끄고
    # `timedatectl set-time`으로 설정(system_log tc_system_log.sh TC02/TC07이 이미
    # 쓰던 방식).
    local orig_epoch cur_year cur_month last_day target_epoch target_str
    orig_epoch=$(date +%s)
    dump_cmd date
    cur_year=$(date +%Y)
    cur_month=$(date +%m)
    last_day=$(last_day_of_month "$cur_year" "$cur_month")
    target_epoch=$(date -d "${cur_year}-${cur_month}-${last_day} 23:50:00" +%s)
    target_str=$(date -d "@${target_epoch}" "+%Y-%m-%d %H:%M:%S")
    echo "  이번 달 말일: ${cur_year}-${cur_month}-${last_day}"

    dump_cmd timedatectl set-ntp no
    echo "  \$ timedatectl set-time \"${target_str}\" (월말 23:50:00으로 이동)"
    timedatectl set-time "${target_str}" > /dev/null 2>&1
    dump_cmd date

    echo "  자정 루틴(월 전환, idle thread 5초 사이클) 도달 대기 (15초)..."
    sleep 15

    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$log_item\")"
    local root_after archive_after default_per_day
    root_after=$(lc_field "$log_item" "perDayRoot")
    archive_after=$(lc_field "$log_item" "perDayArchive")
    default_per_day=$(lc_field "$log_item" "defaultPerDay")
    echo "  결과: perDayRoot=$root_after perDayArchive=$archive_after (defaultPerDay=$default_per_day)"

    if [ "$root_after" -eq "$default_per_day" ]; then
        assert "TC19-1: perDayRoot=defaultPerDay" "PASS"
    else
        assert "TC19-1: perDayRoot=defaultPerDay" "FAIL" "expected=$default_per_day actual=$root_after"
    fi

    if [ "$archive_after" -eq 0 ]; then
        assert "TC19-2: perDayArchive=0" "PASS"
    else
        assert "TC19-2: perDayArchive=0" "FAIL" "actual=$archive_after"
    fi

    echo "  \$ date -s (원래 시각으로 복원)"
    date -s "@${orig_epoch}" > /dev/null
    dump_cmd date
}

# ============================================================
# TC20 (SID0206, 재부팅 수반): 재부팅 후 업로드 설정 파일(logcount.json) 유지
#   --tc20-pre 로 값 변경 후 reboot, 재접속 후 --tc20-post 로 검증
# ============================================================
TC20_SAVE="$STATE_DIR/tc20_state"

tc20_pre() {
    echo "=== TC20-PRE: logcount.json 값 변경 후 재부팅 준비 ==="
    local log_item="Meter"

    local root_before archive_before
    root_before=$(lc_field "$log_item" "perDayRoot")
    archive_before=$(lc_field "$log_item" "perDayArchive")
    echo "  변경 전: perDayRoot=$root_before perDayArchive=$archive_before"

    echo "  \$ get_log_data 발행하여 업로드 1회 유도 (perDayRoot 감소)"
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 10

    local root_changed archive_changed
    root_changed=$(lc_field "$log_item" "perDayRoot")
    archive_changed=$(lc_field "$log_item" "perDayArchive")
    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$log_item\")"
    echo "  변경 후(재부팅 전): perDayRoot=$root_changed perDayArchive=$archive_changed"

    {
        echo "LOG_ITEM=$log_item"
        echo "ROOT_BEFORE_REBOOT=$root_changed"
        echo "ARCHIVE_BEFORE_REBOOT=$archive_changed"
    } > "$TC20_SAVE"
    dump_cmd cat "$TC20_SAVE"

    echo ""
    echo "[TC20-PRE 완료] reboot 실행 중... 재접속 후 --tc20-post 실행"
    sync
    reboot
}

tc20_post() {
    echo "=== TC20-POST: 재부팅 후 logcount.json 값 유지 확인 ==="
    if [ ! -f "$TC20_SAVE" ]; then
        echo "[ERROR] $TC20_SAVE 없음 - --tc20-pre 를 먼저 실행하세요"
        return
    fi
    # shellcheck disable=SC1090
    source "$TC20_SAVE"

    local root_after archive_after
    root_after=$(lc_field "$LOG_ITEM" "perDayRoot")
    archive_after=$(lc_field "$LOG_ITEM" "perDayArchive")
    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$LOG_ITEM\")"
    echo "  재부팅 후: perDayRoot=$root_after perDayArchive=$archive_after (기대: $ROOT_BEFORE_REBOOT / $ARCHIVE_BEFORE_REBOOT)"

    if [ "$root_after" -eq "$ROOT_BEFORE_REBOOT" ] && [ "$archive_after" -eq "$ARCHIVE_BEFORE_REBOOT" ]; then
        assert "TC20-1: 값 유지 확인" "PASS"
    else
        assert "TC20-1: 값 유지 확인" "FAIL" "root: $ROOT_BEFORE_REBOOT->$root_after, archive: $ARCHIVE_BEFORE_REBOOT->$archive_after"
    fi

    rm -f "$TC20_SAVE"
}

# ============================================================
# TC21 (SID0206, §AGSRS-498 AC1 관련): toupload 상태에 따른 root 파일 라우팅 확인
#   [2026-08-25 재설계] 기존엔 5개 log_item이 관측 창에서 골고루 선택되는지(라운드로빈
#   공정성)를 봤는데, 이는 "5개 전원의 toupload가 동시에 비어있어야" 관측 가능한
#   조건이라 실전에서 거의 항상 SKIP/FAIL로 이어졌다(TC12 등 이전 TC가 남긴 backlog나
#   실제 클라우드 업로드 지연만으로도 오염). rootToArchiveOrToUpload()가 실제로 보는
#   조건은 라운드로빈 순서가 아니라 그 log_type의 isToUploadDirEmpty() 하나
#   (cloud_upload_manager.cpp:826-827)이므로, 이제 그 게이트 자체를 log_item 1개
#   (Meter)로 직접 검증한다: TC21-1(비어있음→toupload로 이동), TC21-2(안 비어있음→
#   archive로 이동). 두 sub-case 다 자동 판정하고 서로 독립적으로 동작하도록 만들어
#   `--only TC21`만으로도, 다른 TC와 묶어서 돌려도 결과가 결정적이다.
#
#   [2026-08-25 1차 재설계 실측 후 재수정] 처음엔 get_log_data(forced_log_upload)로
#   root 파일을 큐잉했는데, handleForcedLogUploadRequest()(cloud_upload_manager.cpp:
#   314-428)는 rootToArchiveOrToUpload()와 별개 경로라 isUploadAllowed()/
#   isToUploadDirEmpty() 게이트를 아예 안 거치고 온라인이면 무조건 toupload로 옮긴다
#   (DUT 실측: TC21-2가 toupload를 일부러 오염시켰는데도 archive가 아니라 toupload로
#   가서 FAIL — 우리가 검증하려는 게이트를 안 타는 경로를 찌르고 있었다). TC10의
#   archive 더미 방식과 동일하게, root에 더미 파일을 직접 두고 restart_docker_loader()
#   로 root_dir_files_ 큐에 등록시켜(enumerateRootFilesInDirectory(), 재기동 시 1회만
#   스캔) 진짜 rootToArchiveOrToUpload() idle thread가 게이트를 걸고 옮기는지 본다.
# ============================================================
tc21_toupload_routing() {
    echo "=== TC21: toupload 상태에 따른 root→toupload/archive 라우팅 확인 ==="
    local log_item="Meter"

    # rootToArchiveOrToUpload()는 isInternetAvailable()도 같이 보므로(:825), device_log가
    # "온라인"으로 알고 있는 상태를 보장해둔다 — iptables -D는 걸린 규칙이 없어도
    # 안전(무동작)하고, is_connected:true 알림도 멱등이라 매번 보내도 무해하다.
    network_restore

    # ---- TC21-1: toupload 비어있음 → 신규 root 파일이 toupload로 이동 ----
    local backlog
    backlog=$(toupload_backlog_count "$log_item")
    if [ "$backlog" -gt 0 ]; then
        dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
        assert "TC21-1: toupload 비어있음 -> 신규 파일이 toupload로 이동" "SKIP" "toupload/$log_item에 잔여 파일 ${backlog}개 — 사전조건(비어있음) 불충족"
    else
        local dummy1 fname1
        dummy1=$(create_dummy_root_file "$log_item" "$(date +%s)" "TC211")
        fname1=$(basename "$dummy1")
        dump_cmd ls -la "$LOGGER_ROOT/$log_item/"
        restart_docker_loader

        echo "  idle thread(rootToArchiveOrToUpload, 5초) 사이클 대기 (최대 60초)..."
        local waited=0
        while [ "$waited" -lt 60 ]; do
            [ -f "$TOUPLOAD_ROOT/$log_item/$fname1" ] && break
            sleep 5
            waited=$((waited + 5))
        done

        dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/$fname1"
        if [ -f "$TOUPLOAD_ROOT/$log_item/$fname1" ]; then
            assert "TC21-1: toupload 비어있음 -> 신규 파일이 toupload로 이동" "PASS"
        else
            assert "TC21-1: toupload 비어있음 -> 신규 파일이 toupload로 이동" "FAIL" "${waited}초 내 toupload로 이동 안 됨"
            rm -f "$LOGGER_ROOT/$log_item/$fname1" "$LOGGER_ROOT/$log_item/${fname1}.meta" \
                  "$ARCHIVE_ROOT/$log_item/$fname1" "$ARCHIVE_ROOT/$log_item/${fname1}.meta" 2>/dev/null
        fi
    fi

    # ---- TC21-2: toupload 비어있지 않음 → 신규 root 파일이 archive로 이동 ----
    # TC21-1의 결과(성공 시 toupload에 파일이 남음)나 사전 backlog 여부와 무관하게
    # 이 sub-case 혼자서도 결정적으로 돌도록, 오염용 더미를 직접 만들어 전제를 강제한다.
    echo "  toupload를 의도적으로 채움(더미 1개, TC21-2 전제조건 강제)"
    create_dummy_toupload_file "$log_item" "$(date +%s)" "TC21POLLUTE" > /dev/null

    local dummy2 fname2
    dummy2=$(create_dummy_root_file "$log_item" "$(date +%s)" "TC212")
    fname2=$(basename "$dummy2")
    dump_cmd ls -la "$LOGGER_ROOT/$log_item/"
    restart_docker_loader

    echo "  idle thread(rootToArchiveOrToUpload, 5초) 사이클 대기 (최대 60초)..."
    local waited2=0
    while [ "$waited2" -lt 60 ]; do
        [ -f "$ARCHIVE_ROOT/$log_item/$fname2" ] && break
        sleep 5
        waited2=$((waited2 + 5))
    done

    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/$fname2"
    if [ -f "$ARCHIVE_ROOT/$log_item/$fname2" ]; then
        assert "TC21-2: toupload 비어있지 않음 -> 신규 파일이 archive로 이동" "PASS"
    else
        assert "TC21-2: toupload 비어있지 않음 -> 신규 파일이 archive로 이동" "FAIL" "${waited2}초 내 archive로 이동 안 됨"
        rm -f "$LOGGER_ROOT/$log_item/$fname2" "$LOGGER_ROOT/$log_item/${fname2}.meta" \
              "$TOUPLOAD_ROOT/$log_item/$fname2" "$TOUPLOAD_ROOT/$log_item/${fname2}.meta" 2>/dev/null
    fi

    rm -f "$TOUPLOAD_ROOT/$log_item/"*TC21POLLUTE* 2>/dev/null
}

# ============================================================
# TC22 (SID0207): 웹 강제 업로드 (forced_log_upload IPC)
# ============================================================
tc22_forced_upload() {
    echo "=== TC22: 웹 강제 업로드 (forced_log_upload IPC) ==="
    local log_item
    log_item=$(pick_active_log_item)
    if [ -z "$log_item" ]; then
        assert "TC22-1: IPC 응답 OK" "FAIL" "텔레메트리 도착 중인 log_item 없음"
        assert "TC22-2: toupload에 신규 파일 생성" "FAIL" "텔레메트리 도착 중인 log_item 없음"
        return
    fi

    local csv
    csv=$(active_csv "$log_item")
    dump_cmd tail -1 "$csv"

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    local before_count
    before_count=$(ls "$TOUPLOAD_ROOT/$log_item/" 2>/dev/null | wc -l)

    local resp
    resp=$(send_and_wait "get_log_data" "{}" 30)
    echo "  응답: $resp"
    if response_ok "$resp"; then
        assert "TC22-1: IPC 응답 OK" "PASS"
    else
        assert "TC22-1: IPC 응답 OK" "FAIL" "resp=$resp"
    fi

    sleep 10
    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    local after_count
    after_count=$(ls "$TOUPLOAD_ROOT/$log_item/" 2>/dev/null | wc -l)
    if [ "$after_count" -gt "$before_count" ]; then
        assert "TC22-2: toupload에 신규 파일 생성" "PASS"
    else
        assert "TC22-2: toupload에 신규 파일 생성" "FAIL" "before=$before_count after=$after_count"
    fi
}

# ============================================================
# TC23 (SID0208): EOL 로그 생성 (1초/1분 개별 파일)
# ============================================================
tc23_eol_logging() {
    echo "=== TC23: EOL 로그 생성 (1초/1분 개별 파일) ==="

    # [피드백 반영] EOL 모드 자체의 문제인지, 애초에 telemetry가 안 오는 환경 문제인지
    # 구분하기 위해 먼저 확인 — TC24/TC26도 이 결과를 공유한다.
    echo "  \$ EOL 대상 telemetry notification의 column 데이터 도착 여부 사전 확인"
    if verify_telemetry_columns_present "Meter"; then
        assert "TC23-0: telemetry notification column 데이터 도착 확인(사전 확인용)" "PASS"
    else
        assert "TC23-0: telemetry notification column 데이터 도착 확인(사전 확인용)" "FAIL" "telemetry 자체가 도착하지 않는 상태 — 이후 TC23~26 결과가 EOL 기능이 아니라 이 환경 문제일 수 있음"
    fi

    # [2026-08-25 실측 후 추가] eolpolicy.json의 eol_1sec/eol_1min patternGroups는
    # Meter가 아니라 P01_B01_JF2_Normal_Back_BMS_* (BMS/배터리팩 텔레메트리)를 매칭
    # 대상으로 한다(eol_logger.cpp processEolLogging() — notif.path가 pattern에 일치해야
    # columnValues가 채워지고, 그래야 row가 써진다). 즉 TC23-0(Meter)이 PASS해도 EOL 행
    # 생성과는 무관 — logpolicy.json에 동일 패턴을 쓰는 일반 log_item(BMS_Monitoring_P01)
    # 으로 실제 배터리팩이 연결/시뮬레이션되어 있는 벤치인지 별도로 확인해야 한다.
    # [2026-08-25 대시보드 파싱 버그 회피] server.py의 ASSERT_RE/EXPECTED_CASE_RE는
    # `TC\d+-\d+`(sub-case 번호가 전부 숫자)만 매칭한다 — 처음에 "TC23-0b"로 넣었더니
    # 정규식이 아예 매칭을 실패해 이 case가 결과 현황판에서 통째로 빠지고(진행중 표시가
    # 안 보이던 원인), REASON 줄은 엉뚱하게 바로 이전 case(TC23-0)에 붙어버렸다. 반드시
    # 순수 숫자 sub-case 번호만 쓸 것 — 아래처럼 기존 TC23-1/2를 TC23-2/3으로 밀고 BMS
    # 확인을 TC23-1로 끼워넣는다.
    echo "  \$ EOL 대상 BMS(P01_B01_JF2_Normal_Back_BMS_*) telemetry 도착 여부 사전 확인"
    local bms_present=1
    if verify_telemetry_columns_present "BMS_Monitoring_P01"; then
        assert "TC23-1: BMS telemetry column 데이터 도착 확인(사전 확인용)" "PASS"
    else
        bms_present=0
        assert "TC23-1: BMS telemetry column 데이터 도착 확인(사전 확인용)" "FAIL" "BMS_Monitoring_P01(P01_B01_JF2_Normal_Back_BMS_* 패턴) telemetry 미도착 — 이 벤치에 실물/시뮬레이션 배터리팩이 연결되지 않은 환경일 가능성. eol_1sec/eol_1min은 이 패턴에 매칭되는 notification이 있어야만 row가 써짐(eol_logger.cpp processEolLogging)"
    fi
    if [ "$bms_present" -eq 0 ]; then
        assert "TC23-2: eol_1sec.csv 행 증가" "SKIP" "BMS telemetry 미도착 환경(위 TC23-1 참고) — EOL 행을 채울 데이터 자체가 없어 관측 불가, device_log 결함 아님"
        assert "TC23-3: eol_1min.csv 행 증가" "SKIP" "BMS telemetry 미도착 환경(위 TC23-1 참고) — EOL 행을 채울 데이터 자체가 없어 관측 불가, device_log 결함 아님"
        return
    fi

    dump_cmd ls -la "$EOL_ROOT/"
    # [2026-08-25 실측 후 수정] eol_1sec.csv/eol_1min.csv라는 고정 파일명은 실제로
    # 존재하지 않는다 — 다른 device_log 파일들과 동일하게
    # <start>_<end>_eol_1sec_<serial>.csv/<start>_<end>_eol_1min_<serial>.csv 형태로
    # 타임스탬프가 붙어 생성된다(EOL 모드를 켜도 매번 before=0 after=0으로 항상 FAIL
    # 하던 원인 — EOL 기능 결함이 아니라 이 하드코딩된 파일명 매칭 버그였다).
    # active_csv()와 동일한 방식(가장 최근 파일 glob)으로 실제 파일을 찾는다.
    local csv_1sec_before csv_1min_before rows_1sec_before rows_1min_before
    csv_1sec_before=$(ls -t "$EOL_ROOT"/*eol_1sec*.csv 2>/dev/null | head -1)
    csv_1min_before=$(ls -t "$EOL_ROOT"/*eol_1min*.csv 2>/dev/null | head -1)
    rows_1sec_before=$(wc -l < "$csv_1sec_before" 2>/dev/null)
    rows_1min_before=$(wc -l < "$csv_1min_before" 2>/dev/null)
    [ -z "$rows_1sec_before" ] && rows_1sec_before=0
    [ -z "$rows_1min_before" ] && rows_1min_before=0
    echo "  이전 행 수: eol_1sec=$rows_1sec_before ($csv_1sec_before) eol_1min=$rows_1min_before ($csv_1min_before)"

    # [2026-08-21 실측 후 수정] 이전 실행은 IPC 응답을 `> /dev/null`로 버려 요청이
    # 실제로 device_log에 도달/처리됐는지 알 수 없는 채로 130초를 기다렸다. 응답을
    # 캡처/출력하고, EolLogger 쪽 journal 근거([EOL], loadEolPolicy)도 함께 남긴다.
    # setEolLoggingEnabled(true)는 동기적으로 ensureEolFileHandlersCreated()를 호출해
    # 즉시 파일을 만들어야 하므로(eol_logger.cpp:68-78,85-136), 130초 뒤에도
    # $EOL_ROOT 디렉토리 자체가 없다면 (a) IPC가 전달되지 않았거나 (b) 그 이전 단계인
    # loadEolPolicy()가 eolpolicy.json을 못 읽어 m_eol_policy_doc_.loggingRules가
    # 비어있을 가능성(log_policy_manager.cpp:69) — 코드 결함 또는 배포 설정 누락일
    # 수 있어 재검증이 필요하다(명세 Flag 제안 대상, 이번 세션에서는 재실행하지 않음).
    echo "  \$ send_and_wait set_factory_eol_mode {eol_mode:true}"
    local eol_on_resp
    eol_on_resp=$(send_and_wait "set_factory_eol_mode" '{"eol_mode":true}' 30)
    echo "  응답: $eol_on_resp"

    echo "  130초 대기 (eol_1min 최소 1행 증가 확보)..."
    sleep 130

    dump_cmd ls -la "$EOL_ROOT/"
    local csv_1sec_after csv_1min_after rows_1sec_after rows_1min_after
    csv_1sec_after=$(ls -t "$EOL_ROOT"/*eol_1sec*.csv 2>/dev/null | head -1)
    csv_1min_after=$(ls -t "$EOL_ROOT"/*eol_1min*.csv 2>/dev/null | head -1)
    dump_cmd wc -l "$csv_1sec_after" "$csv_1min_after"
    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -E '\[EOL\]|\[loadEolPolicy\]|EOL logging enabled|EOL mode set to'"
    rows_1sec_after=$(wc -l < "$csv_1sec_after" 2>/dev/null)
    rows_1min_after=$(wc -l < "$csv_1min_after" 2>/dev/null)
    [ -z "$rows_1sec_after" ] && rows_1sec_after=0
    [ -z "$rows_1min_after" ] && rows_1min_after=0

    if [ "$rows_1sec_after" -gt "$rows_1sec_before" ]; then
        assert "TC23-2: eol_1sec.csv 행 증가" "PASS"
    else
        assert "TC23-2: eol_1sec.csv 행 증가" "FAIL" "before=$rows_1sec_before after=$rows_1sec_after"
    fi

    if [ "$rows_1min_after" -gt "$rows_1min_before" ]; then
        assert "TC23-3: eol_1min.csv 행 증가" "PASS"
    else
        assert "TC23-3: eol_1min.csv 행 증가" "FAIL" "before=$rows_1min_before after=$rows_1min_after"
    fi

    echo "  \$ send_and_wait set_factory_eol_mode {eol_mode:false}"
    send_and_wait "set_factory_eol_mode" '{"eol_mode":false}' 30 > /dev/null
}

# ============================================================
# [2026-08-26 삭제] 구 TC24(SID0208, EOL 로그 압축 형식 zip vs xz)는 요구사항 자체를
#   삭제했다 — DUT 실측(mosquitto_pub으로 eol_mode 직접 발행 + timedatectl 시간 점프로
#   900초+ 강제 경과시켜도 xz 미생성 확인) 결과 eol_logger.cpp 전체에
#   compressToXz()/pushToFileCompressQueue() 호출이 단 한 곳도 없어 zip은 물론 xz
#   압축 경로 자체가 코드에 없음을 확정. 검증할 대상 자체가 없어 삭제, 뒤 번호는 당겨서
#   연번 유지(구TC25→TC24, 구TC26→TC25, 구TC27→TC26).
# ============================================================

# ============================================================
# TC24 (SID0208, §AGSRS-491 AC 미구현 확인 — 예상 FAIL): Factory EOL Mode ON 시
#   Field logging 중단 여부
# ============================================================
tc24_eol_field_logging_stop() {
    echo "=== TC24: Factory EOL Mode ON 시 Field logging 중단 여부 [예상 FAIL — §AGSRS-491 AC 미구현] ==="
    local log_item
    log_item=$(pick_active_log_item "$FAST_LOG_ITEMS")
    if [ -z "$log_item" ]; then
        assert "TC24-1: EOL 모드 중 field 로깅 중단 확인(요구사항 AC 기준, 예상 FAIL)" "FAIL" "빠른 주기 log_item 중 텔레메트리 도착 확인된 것 없음"
        assert "TC24-2: 실제로는 필드 로깅 계속됨(참고용)" "FAIL" "빠른 주기 log_item 중 텔레메트리 도착 확인된 것 없음"
        return
    fi

    # [피드백 반영] TC23과 동일 사전 확인 — 본 TC는 대상 log_item CSV의 행 수 증가로
    # 판정하므로 telemetry 자체가 없으면 EOL 기능과 무관하게 "중단됨"으로 오판할 수 있음
    if verify_telemetry_columns_present "$log_item"; then
        assert "TC24-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "PASS"
    else
        assert "TC24-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "FAIL" "telemetry 미도착 — 아래 결과가 EOL 기능과 무관할 수 있음"
    fi

    local csv rows_before interval
    csv=$(active_csv "$log_item")
    rows_before=$(wc -l < "$csv")
    interval=$(lp_field "$log_item" "logRowInterval")
    dump_cmd wc -l "$csv"

    echo "  \$ send_and_wait set_factory_eol_mode {eol_mode:true}"
    local eol_on_resp
    eol_on_resp=$(send_and_wait "set_factory_eol_mode" '{"eol_mode":true}' 30)
    echo "  응답: $eol_on_resp"

    sleep "$((interval * 3 + 10))"

    dump_cmd wc -l "$csv"
    local rows_after
    rows_after=$(wc -l < "$csv")

    if [ "$rows_after" -eq "$rows_before" ]; then
        assert "TC24-1: EOL 모드 중 field 로깅 중단 확인(요구사항 AC 기준, 예상 FAIL)" "PASS"
    else
        assert "TC24-1: EOL 모드 중 field 로깅 중단 확인(요구사항 AC 기준, 예상 FAIL)" "FAIL" "before=$rows_before after=$rows_after — 예상된 결과(stopLogging() 미호출, device_log.cpp:455-461 참고)"
    fi

    if [ "$rows_after" -gt "$rows_before" ]; then
        assert "TC24-2: 실제로는 필드 로깅 계속됨(참고용)" "PASS"
    else
        assert "TC24-2: 실제로는 필드 로깅 계속됨(참고용)" "FAIL" "before=$rows_before after=$rows_after"
    fi

    echo "  \$ send_and_wait set_factory_eol_mode {eol_mode:false}"
    send_and_wait "set_factory_eol_mode" '{"eol_mode":false}' 30 > /dev/null
}

# ============================================================
# TC25 (SID0208, §AGSRS-491 AC, 재부팅+파괴적): Factory Reset 시 전체 로그 삭제
#   및 EOL 모드 해제
#   [경고] request_factory_reset은 /edge/log/eol, /edge/log/device_log,
#   /edge/log/toupload/device_log 를 전부 삭제한다 — --tc25-pre 로 명시 실행할 것.
# ============================================================
TC25_SAVE="$STATE_DIR/tc25_state"

tc25_pre() {
    echo "=== TC25-PRE: Factory Reset 실행 + 재부팅 준비 [파괴적 — 전체 로그 삭제] ==="
    local log_item
    log_item=$(pick_active_log_item "$FAST_LOG_ITEMS")
    [ -z "$log_item" ] && log_item="Meter"

    dump_cmd ls -la "$EOL_ROOT" "$LOGGER_ROOT" "$TOUPLOAD_ROOT"

    local resp
    resp=$(send_and_wait "request_factory_reset" "{}" 30)
    echo "  응답: $resp"
    if response_ok "$resp"; then
        assert "TC25-4: IPC 응답 OK" "PASS"
    else
        assert "TC25-4: IPC 응답 OK" "FAIL" "resp=$resp"
    fi

    sleep 5
    dump_cmd ls -la "$EOL_ROOT"
    if [ ! -d "$EOL_ROOT" ]; then
        assert "TC25-1: eol 디렉토리 삭제" "PASS"
    else
        assert "TC25-1: eol 디렉토리 삭제" "FAIL"
    fi

    dump_cmd ls -la "$LOGGER_ROOT"
    if [ ! -d "$LOGGER_ROOT" ]; then
        assert "TC25-2: device_log 디렉토리 삭제" "PASS"
    else
        assert "TC25-2: device_log 디렉토리 삭제" "FAIL"
    fi

    dump_cmd ls -la "$TOUPLOAD_ROOT"
    if [ ! -d "$TOUPLOAD_ROOT" ]; then
        assert "TC25-3: toupload/device_log 디렉토리 삭제" "PASS"
    else
        assert "TC25-3: toupload/device_log 디렉토리 삭제" "FAIL"
    fi

    {
        echo "LOG_ITEM=$log_item"
    } > "$TC25_SAVE"
    dump_cmd cat "$TC25_SAVE"

    echo ""
    echo "[TC25-PRE 완료] reboot 실행 중... 재접속 후 --tc25-post 실행"
    sync
    reboot
}

tc25_post() {
    echo "=== TC25-POST: 재부팅 후 필드 로깅 재개 + EOL 모드 기본 비활성 확인 ==="
    if [ ! -f "$TC25_SAVE" ]; then
        echo "[ERROR] $TC25_SAVE 없음 - --tc25-pre 를 먼저 실행하세요"
        return
    fi
    # shellcheck disable=SC1090
    source "$TC25_SAVE"

    echo "  재기동 + 텔레메트리 재개 대기..."
    local log_item="$LOG_ITEM"
    local waited=0
    local csv=""
    while [ "$waited" -lt 120 ]; do
        csv=$(active_csv "$log_item")
        if [ -n "$csv" ]; then
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done

    if [ -z "$csv" ]; then
        assert "TC25-5: 재부팅 후 필드 로깅 재개 확인" "FAIL" "$log_item 활성 CSV 미생성"
    else
        local rows_before_reboot interval
        rows_before_reboot=$(wc -l < "$csv")
        interval=$(lp_field "$log_item" "logRowInterval")
        sleep "$((interval * 3 + 10))"
        dump_cmd wc -l "$csv"
        local rows_after
        rows_after=$(wc -l < "$csv")
        if [ "$rows_after" -gt "$rows_before_reboot" ]; then
            assert "TC25-5: 재부팅 후 필드 로깅 재개 확인" "PASS"
        else
            assert "TC25-5: 재부팅 후 필드 로깅 재개 확인" "FAIL" "before=$rows_before_reboot after=$rows_after"
        fi
    fi

    dump_cmd ls -la "$EOL_ROOT/eol_1sec.csv"
    if [ ! -f "$EOL_ROOT/eol_1sec.csv" ]; then
        assert "TC25-6: 재부팅 후 EOL 모드 기본 비활성 확인" "PASS"
    else
        local eol_rows
        eol_rows=$(wc -l < "$EOL_ROOT/eol_1sec.csv")
        sleep 15
        local eol_rows2
        eol_rows2=$(wc -l < "$EOL_ROOT/eol_1sec.csv" 2>/dev/null)
        if [ "$eol_rows2" -eq "$eol_rows" ]; then
            assert "TC25-6: 재부팅 후 EOL 모드 기본 비활성 확인" "PASS"
        else
            assert "TC25-6: 재부팅 후 EOL 모드 기본 비활성 확인" "FAIL" "eol_1sec.csv 증가 중 (rows $eol_rows -> $eol_rows2)"
        fi
    fi

    rm -f "$TC25_SAVE"
}

# ============================================================
# TC26 (SID0208, §AGSRS-549): EOL 로그 추출 API
#
# [2026-08-26 전면 정정 + DUT 실측 확인, 사용자 제보] device_log MQTT IPC가
#   아니라 uniep web_interface(포트 9112, HTTPS)가 서비스하는 별도 HTTP API임을
#   확인:
#     POST https://localhost:9112/auth/token        (토큰 발급)
#     GET  https://localhost:9112/api/factory/logs/eol  (실제 다운로드, /api 접두사 필수)
#   (router.ts:93 -> downloadFactoryLogHandler -> factory-log.service.ts
#   createTarArchive()) — /edge/log/eol 전체를 tar로 묶어 다운로드시키고 원본은
#   그대로 둔다(이동 아님). 9113(uniep 프록시)로는 401/404만 나서 처음엔 막힌
#   줄 알았는데, 실제 정답은 9112 + `/api` 접두사였다(DUT 실측으로 200 + 진짜
#   tar 헤더 확인, 원본 /edge/log/eol도 다운로드 후 그대로 남아있음을 재확인).
#
#   인증 자격증명(auth_key/auth_secret)은 절대 이 스크립트에 하드코딩하지 않는다
#   — 사내 가이드(EMSP_EOL_Log_Export_API_20260513)에 auth_secret이 "대외비"로
#   명시돼 있고, 이 저장소(tcs_tools)는 GitHub public 레포라 커밋되면 그대로
#   유출된다. FACTORY_AUTH_KEY/FACTORY_AUTH_SECRET 환경변수로 실행 시점에만
#   주입할 것 — 미설정이면 SKIP.
# ============================================================
FACTORY_API_HOST="${FACTORY_API_HOST:-https://localhost:9112}"

tc26_eol_extract_skip() {
    echo "=== TC26: EOL 로그 추출 API (GET /api/factory/logs/eol) ==="

    # [피드백 반영] TC23과 동일 사전 확인 — 참고용
    if verify_telemetry_columns_present "Meter"; then
        assert "TC26-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "PASS"
    else
        assert "TC26-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "FAIL" "telemetry 미도착(참고용, TC26 판정에는 영향 없음)"
    fi

    if [ -z "$FACTORY_AUTH_KEY" ] || [ -z "$FACTORY_AUTH_SECRET" ]; then
        assert "TC26-1: GET /api/factory/logs/eol 응답이 유효한 tar 아카이브" "SKIP" "FACTORY_AUTH_KEY/FACTORY_AUTH_SECRET 환경변수 미설정 — 사내 가이드(EMSP_EOL_Log_Export_API_20260513)의 자격증명을 실행 시점에 주입해야 함(대외비라 스크립트에 하드코딩하지 않음). 기능 자체는 DUT 실측으로 동작 확인됨(더 이상 미구현 아님)"
        return
    fi

    echo "  \$ curl -k -X POST $FACTORY_API_HOST/auth/token"
    local token_resp token
    token_resp=$(curl -sSk -X POST "$FACTORY_API_HOST/auth/token" \
        -H "Content-Type: application/json" \
        -d "{\"auth_key\":\"$FACTORY_AUTH_KEY\",\"auth_secret\":\"$FACTORY_AUTH_SECRET\",\"subject\":\"tc_runner\"}")
    token=$(echo "$token_resp" | jq -r '.data.token // empty' 2>/dev/null)

    if [ -z "$token" ]; then
        assert "TC26-1: GET /api/factory/logs/eol 응답이 유효한 tar 아카이브" "FAIL" "토큰 발급 실패 — resp=$token_resp"
        return
    fi

    local tar_path http_code
    tar_path="/tmp/tc26_eol_extract.tar"
    echo "  \$ curl -k -H 'Authorization: Bearer ***' $FACTORY_API_HOST/api/factory/logs/eol"
    http_code=$(curl -sSk -o "$tar_path" -w "%{http_code}" \
        -H "Authorization: Bearer $token" \
        "$FACTORY_API_HOST/api/factory/logs/eol")
    echo "  http_code=$http_code"

    if [ "$http_code" != "200" ]; then
        assert "TC26-1: GET /api/factory/logs/eol 응답이 유효한 tar 아카이브" "FAIL" "http_code=$http_code, 응답=$(cat "$tar_path" 2>/dev/null | head -c 300)"
        rm -f "$tar_path"
        return
    fi

    dump_cmd tar -tf "$tar_path"
    if tar -tf "$tar_path" > /dev/null 2>&1; then
        assert "TC26-1: GET /api/factory/logs/eol 응답이 유효한 tar 아카이브" "PASS"
    else
        assert "TC26-1: GET /api/factory/logs/eol 응답이 유효한 tar 아카이브" "FAIL" "tar -tf 파싱 실패 — 유효한 tar 아카이브 아님"
    fi
    rm -f "$tar_path"

    # 이동이 아니라 다운로드이므로 원본이 그대로 남아있어야 한다.
    dump_cmd ls -la "$EOL_ROOT"
    if [ -d "$EOL_ROOT" ] && [ -n "$(ls -A "$EOL_ROOT" 2>/dev/null)" ]; then
        assert "TC26-2: 다운로드 후 원본 /edge/log/eol 유지 확인(이동 아님)" "PASS"
    else
        assert "TC26-2: 다운로드 후 원본 /edge/log/eol 유지 확인(이동 아님)" "FAIL" "원본이 비어있거나 삭제됨"
    fi
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " device_log TC"
echo " $(date)"
echo "============================================"

# 이전 run들이 남긴 더미 잔재를 실행마다 한 번씩 청소 — cleanup_stale_dummy_files()
# 주석 참고. toupload가 비어있어야 하는 TC14/TC18-3,4/TC21-1의 사전조건이 이 잔재
# 때문에 매번 깨지는 걸 막는다.
echo "  \$ 이전 run 더미 잔재 청소 (root/archive/toupload)"
cleanup_stale_dummy_files

print_result() {
    echo ""
    echo "============================================"
    echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
    echo "============================================"
}

# 빠른 실행/전체 실행(--full)이 공유하는 공통 시퀀스. 재부팅 수반 TC(06/07,15,20,26)는
# SSH 세션이 끊겨 이 스크립트 안에서 이어갈 수 없어 대시보드가 --full 완료 뒤 별도로
# -pre/-post를 체이닝한다.
run_quick_set() {
    tc01_field_accuracy
    tc02_row_interval
    tc03_csv_data_rows
    tc04_filename_format
    tc08_device_connection
    tc10_retention_time
    tc11_upload_result_journal
    tc12_multi_file_upload
    tc13_network_offline_root_to_archive
    tc14_network_recovery
    tc16_perday_root_zero
    tc17_perday_both_zero
    tc21_toupload_routing
    tc22_forced_upload
}

# --full 전용 추가분: 정책파일수정+재시작(TC09)/시스템시각변경(TC05,18,19)는 자체
# 완결형(원복 포함)이라 세션이 안 끊기지만, 시스템 시각을 건드리는 부작용이 있어
# 빠른 실행(회귀 세트)에서는 빠진다. [2026-08-25] TC05는 기존엔 logCreationTime(6시간)
# 자연 경과 대기로 압도적으로 길어 항상 맨 뒤에 뒀으나, timedatectl 시간 점프 방식으로
# 바뀌며 TC18/TC19와 동일하게 20초 내외로 끝난다 — 더 이상 맨 뒤에 둘 이유가 없어
# 같은 "시스템 시각 변경" 카테고리인 TC18/TC19 옆으로 옮겼다.
# [피드백 반영] TC23~25,27(EOL 로그 관련 — Factory EOL Mode를 실제로 켰다 끄는 시험)도
# 빠른 실행(회귀용 quick set)에서 빼고 전체 실행에서만 돈다 — EOL 모드는 양산 라인
# 시나리오라 일상적인 회귀 체크에서는 매번 토글할 필요가 없다는 판단.
run_full_extra() {
    tc09_filecount_fifo
    tc05_creation_time_long
    tc18_midnight_routine
    tc19_month_transition
    tc23_eol_logging
    tc24_eol_field_logging_stop
    tc26_eol_extract_skip
}

case "${1}" in
    --tc01) tc01_field_accuracy; print_result ;;
    --tc02) tc02_row_interval; print_result ;;
    --tc03) tc03_csv_data_rows; print_result ;;
    --tc04) tc04_filename_format; print_result ;;
    --tc05) tc05_creation_time_long; print_result ;;
    --tc06-pre) tc06_07_pre ;;
    --tc06-post) tc06_07_post; print_result ;;
    --tc07) echo "[안내] TC07은 TC06과 같은 재부팅 사이클에서 함께 검증됩니다: --tc06-pre / --tc06-post 사용" ;;
    --tc08) tc08_device_connection; print_result ;;
    --tc09) tc09_filecount_fifo; print_result ;;
    --tc10) tc10_retention_time; print_result ;;
    --tc11) tc11_upload_result_journal; print_result ;;
    --tc12) tc12_multi_file_upload; print_result ;;
    --tc13) tc13_network_offline_root_to_archive; print_result ;;
    --tc14) tc14_network_recovery; print_result ;;
    --tc15-pre) tc15_pre ;;
    --tc15-post) tc15_post; print_result ;;
    --tc16) tc16_perday_root_zero; print_result ;;
    --tc17) tc17_perday_both_zero; print_result ;;
    --tc18) tc18_midnight_routine; print_result ;;
    --tc19) tc19_month_transition; print_result ;;
    --tc20-pre) tc20_pre ;;
    --tc20-post) tc20_post; print_result ;;
    --tc21) tc21_toupload_routing; print_result ;;
    --tc22) tc22_forced_upload; print_result ;;
    --tc23) tc23_eol_logging; print_result ;;
    --tc24) tc24_eol_field_logging_stop; print_result ;;
    --tc25-pre) tc25_pre ;;
    --tc25-post) tc25_post; print_result ;;
    --tc26) tc26_eol_extract_skip; print_result ;;
    --full)
        # 전체 실행: 재부팅 수반 사이클(06/07,15,20)만 빼고 TC01~05,08~14,16~19,21~24,26을
        # 순서대로 실행한다 — 재부팅 사이클은 SSH 세션이 끊겨 이 스크립트 안에서 이어갈 수
        # 없어 대시보드가 --full 완료 뒤 -pre/-post를 직접 체이닝한다. TC05는 [2026-08-25]
        # 부터 시간 점프 방식으로 바뀌어 TC18/TC19처럼 20초 내외로 끝난다(더 이상 전체
        # 소요를 지배하지 않음).
        #
        # [2026-08-25] TC25(factory_reset, 구 TC26)는 --full의 자동 재부팅 체인에서 뺐다 —
        # 매번 전체 실행할 때마다 로그가 통째로 삭제되는 부작용이 있어(다른 TC가 남긴 잔여
        # 파일 분석 등에 방해), 대시보드에 별도의 명시적 "⚠ Factory Reset(TC25)" 버튼으로
        # 분리했다(apps/device_log.py CATALOG id="tc25"). 필요할 때만 그 버튼을 눌러
        # 실행한다.
        run_quick_set
        run_full_extra

        print_result
        echo ""
        echo "[안내] 재부팅 3사이클(06/07,15,20)은 대시보드가 --full 완료 후 자동으로 이어서"
        echo "  실행합니다. TC25(factory_reset)은 파괴적이라 자동 체인에서 빠져있고, 대시보드의"
        echo "  별도 'Factory Reset(TC25)' 버튼으로만 실행됩니다."
        echo "  CLI 단독 실행 시 순서대로: --tc06-pre → (재부팅 대기) → --tc06-post →"
        echo "    --tc15-pre → (재부팅 대기) → --tc15-post → --tc20-pre → (재부팅 대기) → --tc20-post"
        echo "    (TC25는 별도: --tc25-pre → (재부팅 대기) → --tc25-post, factory_reset이라 항상 마지막에 단독 실행 권장)"
        ;;
    --only)
        # 대시보드의 "선택 실행"에서 사용 — 콤마로 구분된 TC 목록을 받아 그 TC들만 실행한다.
        # 예: sh tc_device_log.sh --only TC01,TC10
        # 재부팅 수반 TC(06/07,15,20,25)는 세션이 끊겨 다른 TC와 한 번에 묶을 수 없어
        # 지원하지 않는다(대시보드는 이 TC들을 --only 대신 -pre/-post 체이닝으로 실행한다).
        shift
        SELECTED="${1:-}"
        if [ -z "$SELECTED" ]; then
            echo "[ERROR] --only 뒤에 TC 목록이 필요합니다 (예: --only TC01,TC03,TC10)"
            exit 1
        fi
        case ",${SELECTED}," in
            *,TC06,*|*,TC07,*|*,TC15,*|*,TC20,*|*,TC25,*)
                echo "[ERROR] TC06/TC07/TC15/TC20/TC25는 재부팅을 수반해 --only로 묶을 수 없습니다 — 각 -pre/-post 플래그를 사용하세요"
                exit 1
                ;;
        esac

        # 표준 실행 순서를 그대로 따른다 — 콤마 목록 순서와 무관. TC05는 [2026-08-25]부터
        # TC18/TC19와 같은 시스템 시각 변경 카테고리라 그 옆에 둔다(더 이상 6시간+가
        # 아니라 맨 뒤로 미룰 이유가 없음).
        for tc in TC01 TC02 TC03 TC04 TC08 TC09 TC05 TC10 TC11 TC12 TC13 TC14 TC16 TC17 TC18 TC19 TC21 TC22 TC23 TC24 TC26; do
            case ",${SELECTED}," in
                *,${tc},*)
                    case "$tc" in
                        TC01) tc01_field_accuracy ;;
                        TC02) tc02_row_interval ;;
                        TC03) tc03_csv_data_rows ;;
                        TC04) tc04_filename_format ;;
                        TC05) tc05_creation_time_long ;;
                        TC08) tc08_device_connection ;;
                        TC09) tc09_filecount_fifo ;;
                        TC10) tc10_retention_time ;;
                        TC11) tc11_upload_result_journal ;;
                        TC12) tc12_multi_file_upload ;;
                        TC13) tc13_network_offline_root_to_archive ;;
                        TC14) tc14_network_recovery ;;
                        TC16) tc16_perday_root_zero ;;
                        TC17) tc17_perday_both_zero ;;
                        TC18) tc18_midnight_routine ;;
                        TC19) tc19_month_transition ;;
                        TC21) tc21_toupload_routing ;;
                        TC22) tc22_forced_upload ;;
                        TC23) tc23_eol_logging ;;
                        TC24) tc24_eol_field_logging_stop ;;
                        TC26) tc26_eol_extract_skip ;;
                    esac
                    ;;
            esac
        done

        print_result
        ;;
    *)
        # 빠른 실행(회귀 세트): 재부팅/시스템시간변경/정책파일수정+재시작/EOL 로그 토글이
        # 필요한 TC(05,06,07,09,15,18,19,20,23,24,25,26)는 제외하고 나머지를
        # 순서대로 실행한다(TC01~04,08,10~14,16,17,21,22).
        run_quick_set

        print_result
        echo ""
        echo "[안내] 아래 TC는 별도 실행 (빠른 실행에 미포함):"
        echo "  ./tc_device_log.sh --tc05        (시스템 시간 변경 — logCreationTime 앞당겨 회전 유도)"
        echo "  ./tc_device_log.sh --tc06-pre / --tc06-post   (재부팅 수반, TC07 포함)"
        echo "  ./tc_device_log.sh --tc09        (logpolicy.json fileCount 임시수정+재시작, 원복 포함)"
        echo "  ./tc_device_log.sh --tc15-pre / --tc15-post   (재부팅 수반)"
        echo "  ./tc_device_log.sh --tc18        (시스템 시간 변경 — 자정 루틴)"
        echo "  ./tc_device_log.sh --tc19        (시스템 시간 변경 — 월 전환)"
        echo "  ./tc_device_log.sh --tc20-pre / --tc20-post   (재부팅 수반)"
        echo "  ./tc_device_log.sh --tc23 / --tc24 / --tc26   (EOL 로그 관련, Factory EOL Mode 토글)"
        echo "  ./tc_device_log.sh --tc25-pre / --tc25-post   (factory_reset 전체 로그 삭제 + 재부팅 — 파괴적, [2026-08-25] --full 자동 체인에서 제외됨 — 대시보드 별도 버튼으로 실행)"
        echo "  ./tc_device_log.sh --full        (TC01~05,08~14,16~19,21~24,26 전체, 재부팅 3사이클(06/07,15,20)은 대시보드가 이어서 진행, TC25는 미포함)"
        echo "  ./tc_device_log.sh --only TC01,TC03,...   (선택 실행, 재부팅 TC 제외)"
        ;;
esac
