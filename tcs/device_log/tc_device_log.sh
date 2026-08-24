#!/bin/bash
# TC: device_log
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}
#             emsp/all/{source}/noti/{event}
#
# 명세: tc_device_log.md (TC01~TC24, 연번). 검토/피드백 과정에서 일부 TC가 삭제되거나
#       인접 TC로 통합되어 결번이 생겼던 이력이 있으나, 번호를 모두 당겨 현재는 빈
#       번호 없이 연속된다.
#
# [중요] 장시간/파괴적 시험 안내
#   아래 TC는 기본 실행(인자 없음)에 포함되지 않으며 --tcNN 으로 개별 실행해야 한다.
#     - TC05  : logCreationTime(6시간) 자연 경과 대기 — 6시간+5분 소요
#     - TC09  : logpolicy.json fileCount 임시 수정 + docker-loader 재시작 (원복 로직 포함)
#     - TC18  : 시스템 시각을 23:49로 변경해 자정 루틴 유도 (원복 로직 포함)
#     - TC19  : 시스템 시각을 월말 23:49로 변경해 월 전환 루틴 유도 (원복 로직 포함)
#     - TC06/TC07 (--tc06-pre/--tc06-post) : DUT 재부팅 수반, 같은 파일명 이어쓰기 검증
#     - TC15  (--tc15-pre/--tc15-post)     : DUT 재부팅 수반, toupload 업로드 재개 검증
#     - TC20  (--tc20-pre/--tc20-post)     : DUT 재부팅 수반, logcount.json 값 유지 검증
#     - TC26  (--tc26-pre/--tc26-post)     : factory_reset(전체 로그 삭제) + DUT 재부팅 — 파괴적
#   TC27은 명세에 정의된 IPC 자체가 코드에 미구현이라 자동화 불가 (SKIP).
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
    echo "  \$ systemctl restart docker-loader"
    systemctl restart docker-loader
    echo "  device_log 재기동 대기 중..."
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if pgrep -f device_log > /dev/null 2>&1; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    dump_cmd pgrep -af device_log
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

network_block() {
    dump_cmd iptables -A OUTPUT -p tcp --dport 443 -j DROP
    dump_cmd iptables -A OUTPUT -p tcp --dport 80 -j DROP
    dump_cmd iptables -A OUTPUT -p tcp --dport 8883 -j DROP
    dump_cmd iptables -A OUTPUT -p udp --dport 53 -j DROP
    dump_cmd iptables -A OUTPUT -p icmp -j DROP
}

network_restore() {
    dump_cmd iptables -D OUTPUT -p tcp --dport 443 -j DROP
    dump_cmd iptables -D OUTPUT -p tcp --dport 80 -j DROP
    dump_cmd iptables -D OUTPUT -p tcp --dport 8883 -j DROP
    dump_cmd iptables -D OUTPUT -p udp --dport 53 -j DROP
    dump_cmd iptables -D OUTPUT -p icmp -j DROP
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
    : > "$TOUPLOAD_ROOT/$log_item/${fname}.meta"
    touch -d "@$end_epoch" "$TOUPLOAD_ROOT/$log_item/$fname" "$TOUPLOAD_ROOT/$log_item/${fname}.meta"
    echo "$TOUPLOAD_ROOT/$log_item/$fname"
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
# TC05 (SID0202, 장시간): 파일 생성 주기(logCreationTime) 정확성
#   logCreationTime(6시간) + 여유 5분 자연 경과 대기 — --tc05 로 개별 실행할 것
# ============================================================
tc05_creation_time_long() {
    echo "=== TC05: 파일 생성 주기(logCreationTime) 정확성 [장시간, 6시간+5분] ==="
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

    local wait_sec=$((ct + 300))
    echo "  ${wait_sec}초(logCreationTime+5분) 대기 — 실시간 자연 경과, date -s/재시작 없음"
    sleep "$wait_sec"

    dump_cmd ls -la "$LOGGER_ROOT/$log_item/"
    local rotated
    rotated=$(ls -t "$LOGGER_ROOT/$log_item/"*.csv.xz 2>/dev/null | head -1)
    if [ -z "$rotated" ]; then
        assert "TC05-1: 간격이 logCreationTime ±5%" "FAIL" "회전된(.csv.xz) 파일 없음"
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
        echo "[ERROR] $log_item 텔레메트리 미도착 — TC06/07 진행 불가"
        assert "TC06-1: 재부팅 전후 파일명 동일" "FAIL" "$log_item 텔레메트리 미도착"
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
    local i now oldest_file
    now=$(date +%s)
    for i in 1 2 3 4 5 6 7 8; do
        local f
        f=$(create_dummy_archive_file "$log_item" "$((now - (9 - i) * 60))" "TC09_$i")
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

    # [피드백 반영] 네트워크 차단+get_log_data로 실제 파일을 확보하는 대신,
    # create_dummy_archive_file()로 더미 파일을 만든 뒤 docker-loader를 재시작한다.
    # CloudUploadManager::arch_dir_files_ 큐는 enumerateExistingFilesInDirectory()가
    # "부팅 시 1회"(cloud_upload_manager.cpp:107) 채우는데, 이 "부팅"은 프로세스
    # 기동 시점이므로 docker-loader를 재시작하면 그 시점에 archive 디렉토리에 이미
    # 존재하는 더미 파일도 함께 스캔되어 정식으로 큐에 등록된다(TC09이 더미 파일들을
    # 만든 뒤 재시작해 FIFO 삭제를 성공적으로 검증한 것과 동일한 원리) — 재시작 없이
    # 디스크에만 만들면 앱이 그 존재를 몰라 deleteArchFileBasedOnTime()(:1701-1705)이
    # 절대 못 찾는다(이전 실측에서 확인된 함정).
    local dummy
    dummy=$(create_dummy_archive_file "$log_item" "$(date +%s)" "TC10")
    dump_cmd ls -la "$dummy"

    echo "  더미 파일을 arch_dir_files_ 추적 큐에 등록하기 위해 docker-loader 재시작"
    restart_docker_loader

    local expired_epoch=$(( $(date +%s) - retention - 3600 ))
    dump_cmd date -d "@$expired_epoch"
    echo "  \$ touch -d @$expired_epoch (retentionTime 초과로 되돌림)"
    touch -d "@$expired_epoch" "$dummy" "${dummy}.meta"

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
    echo "  [Director] 300초 주기 스캔 대기 (최대 310초 폴링)..."
    local waited=0
    while [ "$waited" -lt 310 ]; do
        local remaining=""
        local f
        for f in $new_files; do
            journalctl -u docker-loader --no-pager 2>/dev/null | grep '\[Director\]' | grep -q "$f" || remaining="$remaining $f"
        done
        [ -z "$remaining" ] && break
        sleep 10
        waited=$((waited + 10))
    done
    echo "  대기 시간: ${waited}s"

    local all_found=1
    local f
    for f in $new_files; do
        dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep '\[Director\]' | grep '$f'"
        if journalctl -u docker-loader --no-pager 2>/dev/null | grep '\[Director\]' | grep -q "$f"; then
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
    sleep 10

    dump_cmd ls -la "$ARCHIVE_ROOT/"
    local newest_archive
    newest_archive=$(find "$ARCHIVE_ROOT" -name '*.csv.xz' -newer "$marker" 2>/dev/null | head -1)
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
        network_restore
    fi

    # [피드백 반영] 네트워크 복구 후 수동 폴링만으로 재개를 기다리는 대신,
    # internet_status notification을 강제로 발행해 cloud_connected_action()을
    # 직접 트리거한다 — device_connection(TC08)과 동일한 publish_noti 패턴.
    echo "  \$ publish_noti internet_status {connected:true} (연결 상태 강제 통지)"
    publish_noti "internet_status" '{"connected":true}'
    sleep 5

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

    local target
    target=$(ls -t "$TOUPLOAD_ROOT/$log_item/"*.csv.xz 2>/dev/null | head -1)
    if [ -z "$target" ]; then
        target=$(ls -t "$ARCHIVE_ROOT/$log_item/"*.csv.xz 2>/dev/null | head -1)
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
    echo "  \$ logcount.json $log_item perDayRoot: $root_before -> 0"
    set_lc_field_num "$log_item" "perDayRoot" 0
    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$log_item\")"
    restart_docker_loader

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    local before_toupload
    before_toupload=$(ls "$TOUPLOAD_ROOT/$log_item/" 2>/dev/null)
    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/"
    local before_archive
    before_archive=$(ls "$ARCHIVE_ROOT/$log_item/" 2>/dev/null)

    network_block
    send_and_wait "get_log_data" "{}" 30 > /dev/null
    sleep 15
    network_restore

    echo "  idle thread 라운드로빈이 root 파일을 집을 때까지 대기 (최대 60초)..."
    sleep 60

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    local after_toupload new_toupload
    after_toupload=$(ls "$TOUPLOAD_ROOT/$log_item/" 2>/dev/null)
    new_toupload=$(comm -13 <(echo "$before_toupload" | sort) <(echo "$after_toupload" | sort) | grep -c '\.csv\.xz$')
    if [ "$new_toupload" -eq 0 ]; then
        assert "TC16-1: toupload 미이동" "PASS"
    else
        assert "TC16-1: toupload 미이동" "FAIL" "toupload에 신규 파일 ${new_toupload}개 발생"
    fi

    dump_cmd ls -la "$ARCHIVE_ROOT/$log_item/"
    local after_archive new_archive
    after_archive=$(ls "$ARCHIVE_ROOT/$log_item/" 2>/dev/null)
    new_archive=$(comm -13 <(echo "$before_archive" | sort) <(echo "$after_archive" | sort) | grep -c '\.csv\.xz$')
    if [ "$new_archive" -gt 0 ]; then
        assert "TC16-2: archive 이동 확인" "PASS"
    else
        assert "TC16-2: archive 이동 확인" "FAIL" "archive에 신규 파일 없음"
    fi

    echo "  logcount.json 원복: perDayRoot=$root_before"
    set_lc_field_num "$log_item" "perDayRoot" "$root_before"
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
    set_lc_field_num "$log_item" "perDayRoot" 0
    set_lc_field_num "$log_item" "perDayArchive" 0
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

    dump_cmd ls -la "$TOUPLOAD_ROOT/$log_item/"
    local after_toupload new_toupload
    after_toupload=$(ls "$TOUPLOAD_ROOT/$log_item/" 2>/dev/null)
    new_toupload=$(comm -13 <(echo "$before_toupload" | sort) <(echo "$after_toupload" | sort) | grep -c '\.csv\.xz$')
    if [ "$new_toupload" -eq 0 ]; then
        assert "TC17-1: toupload 미이동 유지" "PASS"
    else
        assert "TC17-1: toupload 미이동 유지" "FAIL" "toupload에 신규 파일 ${new_toupload}개 발생"
    fi

    echo "  logcount.json 원복: perDayRoot=$root_before perDayArchive=$archive_before"
    set_lc_field_num "$log_item" "perDayRoot" "$root_before"
    set_lc_field_num "$log_item" "perDayArchive" "$archive_before"
    restart_docker_loader
}

# ============================================================
# TC18 (SID0206, 시스템 시간 변경 — 별도 실행): 자정 루틴
#   시스템 시각을 23:49로 변경해 23:50 자정 루틴을 유도한다. --tc18 로 개별 실행할 것.
# ============================================================
tc18_midnight_routine() {
    echo "=== TC18: 자정 루틴(perDayRoot 초기화 및 잔여 quota archive 이월) [시스템 시간 변경] ==="
    local log_item="Meter"

    local root_before archive_before default_per_day
    root_before=$(lc_field "$log_item" "perDayRoot")
    archive_before=$(lc_field "$log_item" "perDayArchive")
    default_per_day=$(lc_field "$log_item" "defaultPerDay")
    echo "  원래값: perDayRoot=$root_before perDayArchive=$archive_before defaultPerDay=$default_per_day"

    local orig_epoch today_date target_epoch
    orig_epoch=$(date +%s)
    dump_cmd date
    today_date=$(date +%Y-%m-%d)
    target_epoch=$(date -d "${today_date} 23:49:00" +%s)
    if [ "$target_epoch" -lt "$orig_epoch" ]; then
        target_epoch=$(date -d "${today_date} 23:49:00 +1 day" +%s 2>/dev/null)
    fi
    echo "  \$ date -s (23:49:00으로 이동)"
    date -s "@${target_epoch}" > /dev/null
    dump_cmd date

    echo "  23:50 자정 루틴 도달 대기 (90초)..."
    sleep 90

    dump_container_jq "$LOGCOUNT_JSON" ".logItemUploadLimits[] | select(.logItem==\"$log_item\")"
    local root_after archive_after
    root_after=$(lc_field "$log_item" "perDayRoot")
    archive_after=$(lc_field "$log_item" "perDayArchive")
    echo "  결과: perDayRoot=$root_after perDayArchive=$archive_after"

    if [ "$archive_after" -eq "$((archive_before + root_before))" ]; then
        assert "TC18-1: perDayArchive 이월 계산 일치" "PASS"
    else
        assert "TC18-1: perDayArchive 이월 계산 일치" "FAIL" "expected=$((archive_before + root_before)) actual=$archive_after"
    fi

    if [ "$root_after" -eq "$default_per_day" ]; then
        assert "TC18-2: perDayRoot 초기화" "PASS"
    else
        assert "TC18-2: perDayRoot 초기화" "FAIL" "expected=$default_per_day actual=$root_after"
    fi

    echo "  \$ date -s (원래 시각으로 복원)"
    date -s "@${orig_epoch}" > /dev/null
    dump_cmd date
}

# ============================================================
# TC19 (SID0206, 시스템 시간 변경 — 별도 실행): 월 전환 시 로그 카운트 초기화
#   시스템 시각을 이번 달 말일 23:49로 변경해 자정 루틴에서 월 전환을 유도한다.
#   --tc19 로 개별 실행할 것.
# ============================================================
tc19_month_transition() {
    echo "=== TC19: 월 전환 시 로그 카운트 초기화 [시스템 시간 변경] ==="
    local log_item="Meter"

    local orig_epoch cur_year cur_month last_day target_epoch
    orig_epoch=$(date +%s)
    dump_cmd date
    cur_year=$(date +%Y)
    cur_month=$(date +%m)
    last_day=$(last_day_of_month "$cur_year" "$cur_month")
    target_epoch=$(date -d "${cur_year}-${cur_month}-${last_day} 23:49:00" +%s)
    echo "  이번 달 말일: ${cur_year}-${cur_month}-${last_day}"

    echo "  \$ date -s (월말 23:49:00으로 이동)"
    date -s "@${target_epoch}" > /dev/null
    dump_cmd date

    echo "  23:50 자정 루틴(월 전환) 도달 대기 (90초)..."
    sleep 90

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
# TC21 (SID0206, §AGSRS-498 AC1 관련): 라운드로빈 기반 균등 업로드 선택 확인
#   forced_log_upload는 온라인 상태에서 즉시 전량 이동시켜 라운드로빈을 우회하므로,
#   네트워크를 차단한 채로 root 대기열을 쌓은 뒤 복구해 idle thread의
#   selectNextRootLogType() 라운드로빈이 실제로 도는 것을 관찰한다.
#
#   [피드백 반영] "logpolicy.json 전체 log_type 수(32개) x 2바퀴"를 고정 sleep으로
#   기다리는 대신(32*2*5+30=350초 고정 대기), idle thread 사이클(5초)마다 toupload
#   카운트를 능동적으로 폴링해 어느 순간에 어느 log_item이 선택됐는지 시퀀스로
#   기록한다. 대상 log_item 전원이 관측되는 즉시 조기 종료해 수행시간을 단축한다.
# ============================================================
tc21_round_robin() {
    echo "=== TC21: 라운드로빈 기반 균등 업로드 선택 확인 ==="
    local items="$FAST_LOG_ITEMS"
    echo "  대상 log_item(들): $items"

    local blocked=0
    if is_online; then
        network_block
        blocked=1
        sleep 60
    fi

    local rep
    for rep in 1 2 3; do
        echo "  [$rep/3] get_log_data 발행 (오프라인 — root 대기열에만 쌓임)"
        send_and_wait "get_log_data" "{}" 30 > /dev/null
        sleep 70
    done

    if [ "$blocked" -eq 1 ]; then
        network_restore
    fi

    # [주의] archive/root->toupload 이동은 isToUploadDirEmpty(log_type)도 함께
    # 요구한다(:826,860) — 앞선 TC(TC12 등)가 Meter의 toupload에 미처리 파일을 남겨둔
    # 채로 이 TC가 실행되면, 라운드로빈이 Meter를 선택해도 파일이 archive로 새어
    # toupload delta가 과소평가될 수 있다. 이 오염 가능성을 배제하려면 TC21를
    # `--tc21`로 단독 실행할 것을 권장(명세에도 기록).
    local counts=""
    local item
    for item in $items; do
        local c
        c=$(ls "$TOUPLOAD_ROOT/$item/" 2>/dev/null | wc -l)
        counts="${counts}${item}=${c} "
    done
    echo "  폴링 시작 시 toupload 카운트: $counts"

    local sequence=""
    local cycle=0
    local max_cycles=40
    while [ "$cycle" -lt "$max_cycles" ]; do
        sleep 5
        cycle=$((cycle + 1))
        local new_counts=""
        for item in $items; do
            local prev cur
            prev=$(echo "$counts" | grep -oE "${item}=[0-9]+" | cut -d= -f2)
            cur=$(ls "$TOUPLOAD_ROOT/$item/" 2>/dev/null | wc -l)
            if [ "$cur" -gt "$prev" ]; then
                echo "  [cycle $cycle, $((cycle * 5))s] 선택됨: $item ($prev -> $cur)"
                sequence="$sequence $item"
            fi
            new_counts="${new_counts}${item}=${cur} "
        done
        counts="$new_counts"

        # 대상 log_item 전원이 시퀀스에 최소 1회 이상 등장하면 조기 종료(수행시간 단축)
        local all_covered=1
        for item in $items; do
            case " $sequence " in
                *" $item "*) ;;
                *) all_covered=0 ;;
            esac
        done
        if [ "$all_covered" -eq 1 ] && [ "$cycle" -ge 5 ]; then
            echo "  대상 log_item 전원 관측 완료 — 조기 종료 (${cycle}사이클, $((cycle * 5))초)"
            break
        fi
    done

    echo "  선택 시퀀스(${cycle}사이클, $((cycle * 5))초): $sequence"

    local all_selected=1
    for item in $items; do
        case " $sequence " in
            *" $item "*) ;;
            *)
                all_selected=0
                echo "  [경고] $item 은 관측 창에서 선택되지 않음"
                ;;
        esac
    done

    if [ "$all_selected" -eq 1 ]; then
        assert "TC21-1: 대상 log_item 전원이 관측 창에서 최소 1회 이상 선택됨(편중/기아 없음)" "PASS"
    else
        assert "TC21-1: 대상 log_item 전원이 관측 창에서 최소 1회 이상 선택됨(편중/기아 없음)" "FAIL" "sequence=$sequence"
    fi

    echo "  [TC21-2, manual] 아래 선택 시퀀스로 '동일 item이 연속 사이클에서 뭉쳐 선택되다 다른 item으로 전환'되는 패턴을 수동 확인할 것:"
    echo "    $sequence"
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
    # 구분하기 위해 먼저 확인 — TC24/28/30도 이 결과를 공유한다.
    echo "  \$ EOL 대상 telemetry notification의 column 데이터 도착 여부 사전 확인"
    if verify_telemetry_columns_present "Meter"; then
        assert "TC23-0: telemetry notification column 데이터 도착 확인(사전 확인용)" "PASS"
    else
        assert "TC23-0: telemetry notification column 데이터 도착 확인(사전 확인용)" "FAIL" "telemetry 자체가 도착하지 않는 상태 — 이후 TC23~28/30 결과가 EOL 기능이 아니라 이 환경 문제일 수 있음"
    fi

    dump_cmd ls -la "$EOL_ROOT/"
    local rows_1sec_before rows_1min_before
    rows_1sec_before=$(wc -l < "$EOL_ROOT/eol_1sec.csv" 2>/dev/null)
    rows_1min_before=$(wc -l < "$EOL_ROOT/eol_1min.csv" 2>/dev/null)
    [ -z "$rows_1sec_before" ] && rows_1sec_before=0
    [ -z "$rows_1min_before" ] && rows_1min_before=0
    echo "  이전 행 수: eol_1sec=$rows_1sec_before eol_1min=$rows_1min_before"

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
    dump_cmd wc -l "$EOL_ROOT/eol_1sec.csv" "$EOL_ROOT/eol_1min.csv"
    dump_cmd sh -c "journalctl -u docker-loader --no-pager | grep -E '\[EOL\]|\[loadEolPolicy\]|EOL logging enabled|EOL mode set to'"
    local rows_1sec_after rows_1min_after
    rows_1sec_after=$(wc -l < "$EOL_ROOT/eol_1sec.csv" 2>/dev/null)
    rows_1min_after=$(wc -l < "$EOL_ROOT/eol_1min.csv" 2>/dev/null)
    [ -z "$rows_1sec_after" ] && rows_1sec_after=0
    [ -z "$rows_1min_after" ] && rows_1min_after=0

    if [ "$rows_1sec_after" -gt "$rows_1sec_before" ]; then
        assert "TC23-1: eol_1sec.csv 행 증가" "PASS"
    else
        assert "TC23-1: eol_1sec.csv 행 증가" "FAIL" "before=$rows_1sec_before after=$rows_1sec_after"
    fi

    if [ "$rows_1min_after" -gt "$rows_1min_before" ]; then
        assert "TC23-2: eol_1min.csv 행 증가" "PASS"
    else
        assert "TC23-2: eol_1min.csv 행 증가" "FAIL" "before=$rows_1min_before after=$rows_1min_after"
    fi

    echo "  \$ send_and_wait set_factory_eol_mode {eol_mode:false}"
    send_and_wait "set_factory_eol_mode" '{"eol_mode":false}' 30 > /dev/null
}

# ============================================================
# TC24 (SID0208, §AGSRS-491 AC 미구현 확인 — 예상 FAIL): EOL 로그 압축 형식(zip vs xz)
#   log_compress.cpp/hpp 전체에 compressToXz() 하나의 경로만 존재, zip 코드 없음 —
#   DUT 실측 없이도 FAIL 확정적. 현재 시점 /edge/log/eol 상태를 그대로 확인한다
#   (완전한 rotation 대기는 eol_1sec 기준 logCreationTime=900초 소요 — 필요 시
#   TC23 실행 후 900초를 추가로 기다린 뒤 재실행).
# ============================================================
tc24_eol_compress_format() {
    echo "=== TC24: EOL 로그 압축 형식(zip vs xz) [예상 FAIL — §AGSRS-491 AC 미구현] ==="

    # [피드백 반영] TC23과 동일 사전 확인 — telemetry column 데이터가 애초에 안
    # 오는 상태면 EOL 파일 자체가 못 생겨 아래 판정이 EOL 기능과 무관하게 FAIL할 수 있음
    if verify_telemetry_columns_present "Meter"; then
        assert "TC24-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "PASS"
    else
        assert "TC24-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "FAIL" "telemetry 미도착 — 아래 결과가 EOL 압축 기능과 무관할 수 있음"
    fi

    dump_cmd find "$EOL_ROOT" -name '*.zip'
    local zip_count
    zip_count=$(find "$EOL_ROOT" -name '*.zip' 2>/dev/null | wc -l)
    if [ "$zip_count" -gt 0 ]; then
        assert "TC24-1: zip 압축 파일 존재 확인(요구사항 AC 기준, 예상 FAIL)" "PASS"
    else
        assert "TC24-1: zip 압축 파일 존재 확인(요구사항 AC 기준, 예상 FAIL)" "FAIL" "zip 파일 없음 — 예상된 결과(log_compress.cpp에 zip 경로 없음, compressToXz만 존재)"
    fi

    dump_cmd find "$EOL_ROOT" -name '*.xz'
    local xz_count
    xz_count=$(find "$EOL_ROOT" -name '*.xz' 2>/dev/null | wc -l)
    if [ "$xz_count" -gt 0 ]; then
        assert "TC24-2: 실제로는 xz만 생성됨(참고용)" "PASS"
    else
        assert "TC24-2: 실제로는 xz만 생성됨(참고용)" "FAIL" "xz 파일도 아직 없음 — TC23 실행 후 rotation(eol_1sec 기준 900초) 대기 필요"
    fi
}

# ============================================================
# TC25 (SID0208, §AGSRS-491 AC 미구현 확인 — 예상 FAIL): Factory EOL Mode ON 시
#   Field logging 중단 여부
# ============================================================
tc25_eol_field_logging_stop() {
    echo "=== TC25: Factory EOL Mode ON 시 Field logging 중단 여부 [예상 FAIL — §AGSRS-491 AC 미구현] ==="
    local log_item
    log_item=$(pick_active_log_item "$FAST_LOG_ITEMS")
    if [ -z "$log_item" ]; then
        assert "TC25-1: EOL 모드 중 field 로깅 중단 확인(요구사항 AC 기준, 예상 FAIL)" "FAIL" "빠른 주기 log_item 중 텔레메트리 도착 확인된 것 없음"
        assert "TC25-2: 실제로는 필드 로깅 계속됨(참고용)" "FAIL" "빠른 주기 log_item 중 텔레메트리 도착 확인된 것 없음"
        return
    fi

    # [피드백 반영] TC23과 동일 사전 확인 — 본 TC는 대상 log_item CSV의 행 수 증가로
    # 판정하므로 telemetry 자체가 없으면 EOL 기능과 무관하게 "중단됨"으로 오판할 수 있음
    if verify_telemetry_columns_present "$log_item"; then
        assert "TC25-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "PASS"
    else
        assert "TC25-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "FAIL" "telemetry 미도착 — 아래 결과가 EOL 기능과 무관할 수 있음"
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
        assert "TC25-1: EOL 모드 중 field 로깅 중단 확인(요구사항 AC 기준, 예상 FAIL)" "PASS"
    else
        assert "TC25-1: EOL 모드 중 field 로깅 중단 확인(요구사항 AC 기준, 예상 FAIL)" "FAIL" "before=$rows_before after=$rows_after — 예상된 결과(stopLogging() 미호출, device_log.cpp:455-461 참고)"
    fi

    if [ "$rows_after" -gt "$rows_before" ]; then
        assert "TC25-2: 실제로는 필드 로깅 계속됨(참고용)" "PASS"
    else
        assert "TC25-2: 실제로는 필드 로깅 계속됨(참고용)" "FAIL" "before=$rows_before after=$rows_after"
    fi

    echo "  \$ send_and_wait set_factory_eol_mode {eol_mode:false}"
    send_and_wait "set_factory_eol_mode" '{"eol_mode":false}' 30 > /dev/null
}

# ============================================================
# TC26 (SID0208, §AGSRS-491 AC, 재부팅+파괴적): Factory Reset 시 전체 로그 삭제
#   및 EOL 모드 해제
#   [경고] request_factory_reset은 /edge/log/eol, /edge/log/device_log,
#   /edge/log/toupload/device_log 를 전부 삭제한다 — --tc26-pre 로 명시 실행할 것.
# ============================================================
TC26_SAVE="$STATE_DIR/tc26_state"

tc26_pre() {
    echo "=== TC26-PRE: Factory Reset 실행 + 재부팅 준비 [파괴적 — 전체 로그 삭제] ==="
    local log_item
    log_item=$(pick_active_log_item "$FAST_LOG_ITEMS")
    [ -z "$log_item" ] && log_item="Meter"

    dump_cmd ls -la "$EOL_ROOT" "$LOGGER_ROOT" "$TOUPLOAD_ROOT"

    local resp
    resp=$(send_and_wait "request_factory_reset" "{}" 30)
    echo "  응답: $resp"
    if response_ok "$resp"; then
        assert "TC26-4: IPC 응답 OK" "PASS"
    else
        assert "TC26-4: IPC 응답 OK" "FAIL" "resp=$resp"
    fi

    sleep 5
    dump_cmd ls -la "$EOL_ROOT"
    if [ ! -d "$EOL_ROOT" ]; then
        assert "TC26-1: eol 디렉토리 삭제" "PASS"
    else
        assert "TC26-1: eol 디렉토리 삭제" "FAIL"
    fi

    dump_cmd ls -la "$LOGGER_ROOT"
    if [ ! -d "$LOGGER_ROOT" ]; then
        assert "TC26-2: device_log 디렉토리 삭제" "PASS"
    else
        assert "TC26-2: device_log 디렉토리 삭제" "FAIL"
    fi

    dump_cmd ls -la "$TOUPLOAD_ROOT"
    if [ ! -d "$TOUPLOAD_ROOT" ]; then
        assert "TC26-3: toupload/device_log 디렉토리 삭제" "PASS"
    else
        assert "TC26-3: toupload/device_log 디렉토리 삭제" "FAIL"
    fi

    {
        echo "LOG_ITEM=$log_item"
    } > "$TC26_SAVE"
    dump_cmd cat "$TC26_SAVE"

    echo ""
    echo "[TC26-PRE 완료] reboot 실행 중... 재접속 후 --tc26-post 실행"
    sync
    reboot
}

tc26_post() {
    echo "=== TC26-POST: 재부팅 후 필드 로깅 재개 + EOL 모드 기본 비활성 확인 ==="
    if [ ! -f "$TC26_SAVE" ]; then
        echo "[ERROR] $TC26_SAVE 없음 - --tc26-pre 를 먼저 실행하세요"
        return
    fi
    # shellcheck disable=SC1090
    source "$TC26_SAVE"

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
        assert "TC26-5: 재부팅 후 필드 로깅 재개 확인" "FAIL" "$log_item 활성 CSV 미생성"
    else
        local rows_before_reboot interval
        rows_before_reboot=$(wc -l < "$csv")
        interval=$(lp_field "$log_item" "logRowInterval")
        sleep "$((interval * 3 + 10))"
        dump_cmd wc -l "$csv"
        local rows_after
        rows_after=$(wc -l < "$csv")
        if [ "$rows_after" -gt "$rows_before_reboot" ]; then
            assert "TC26-5: 재부팅 후 필드 로깅 재개 확인" "PASS"
        else
            assert "TC26-5: 재부팅 후 필드 로깅 재개 확인" "FAIL" "before=$rows_before_reboot after=$rows_after"
        fi
    fi

    dump_cmd ls -la "$EOL_ROOT/eol_1sec.csv"
    if [ ! -f "$EOL_ROOT/eol_1sec.csv" ]; then
        assert "TC26-6: 재부팅 후 EOL 모드 기본 비활성 확인" "PASS"
    else
        local eol_rows
        eol_rows=$(wc -l < "$EOL_ROOT/eol_1sec.csv")
        sleep 15
        local eol_rows2
        eol_rows2=$(wc -l < "$EOL_ROOT/eol_1sec.csv" 2>/dev/null)
        if [ "$eol_rows2" -eq "$eol_rows" ]; then
            assert "TC26-6: 재부팅 후 EOL 모드 기본 비활성 확인" "PASS"
        else
            assert "TC26-6: 재부팅 후 EOL 모드 기본 비활성 확인" "FAIL" "eol_1sec.csv 증가 중 (rows $eol_rows -> $eol_rows2)"
        fi
    fi

    rm -f "$TC26_SAVE"
}

# ============================================================
# TC27 (SID0208, §AGSRS-549): EOL 로그 추출 IPC — 자동화 불가 (미구현)
# ============================================================
tc27_eol_extract_skip() {
    echo "=== TC27: EOL 로그 추출 IPC ==="

    # [피드백 반영] TC23과 동일 사전 확인 — IPC 미구현으로 어차피 SKIP이지만,
    # /edge/log/eol 자체가 비어있는 상태(telemetry 미도착)인지 참고용으로 남긴다
    if verify_telemetry_columns_present "Meter"; then
        assert "TC27-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "PASS"
    else
        assert "TC27-0: telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인)" "FAIL" "telemetry 미도착(참고용, TC27 SKIP 판정에는 영향 없음)"
    fi

    echo "[SKIP] TC27: EOL 로그 추출 IPC 미구현 (개발 완료 후 활성화 대상, AGSRS-549 설명에 '개발 중' 명시)"
    assert "TC27-1: 추출 후 폴더 이동 확인" "SKIP" "IPC 핸들러 코드에 미존재 — 개발 완료 후 활성화 대상"
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " device_log TC"
echo " $(date)"
echo "============================================"

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
    tc21_round_robin
    tc22_forced_upload
    tc23_eol_logging
    tc24_eol_compress_format
    tc25_eol_field_logging_stop
    tc27_eol_extract_skip
}

# --full 전용 추가분: 정책파일수정+재시작(TC09)/시스템시각변경(TC18,22)/6시간대기(TC05)는
# 자체 완결형(원복 포함)이라 세션이 안 끊기지만 소요시간이 커서 빠른 실행에서는 빠진다.
# TC05가 6시간+5분으로 압도적으로 길어 다른 TC 결과를 먼저 보여주도록 맨 뒤에 둔다.
run_full_extra() {
    tc09_filecount_fifo
    tc18_midnight_routine
    tc19_month_transition
    tc05_creation_time_long
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
    --tc21) tc21_round_robin; print_result ;;
    --tc22) tc22_forced_upload; print_result ;;
    --tc23) tc23_eol_logging; print_result ;;
    --tc24) tc24_eol_compress_format; print_result ;;
    --tc25) tc25_eol_field_logging_stop; print_result ;;
    --tc26-pre) tc26_pre ;;
    --tc26-post) tc26_post; print_result ;;
    --tc27) tc27_eol_extract_skip; print_result ;;
    --full)
        # 전체 실행: 재부팅 수반 4사이클(07/08,18,23,29)만 빼고 TC01~05,08~14,16~19,21~25,27을
        # 순서대로 실행한다 — 재부팅 4사이클은 SSH 세션이 끊겨 이 스크립트 안에서 이어갈 수
        # 없어 대시보드가 --full 완료 뒤 -pre/-post를 직접 체이닝한다(TC26는 파괴적이라 항상
        # 맨 마지막). TC05가 6시간+5분으로 전체 소요를 지배한다.
        run_quick_set
        run_full_extra

        print_result
        echo ""
        echo "[안내] 재부팅 4사이클은 대시보드가 --full 완료 후 자동으로 이어서 실행합니다."
        echo "  CLI 단독 실행 시 순서대로: --tc06-pre → (재부팅 대기) → --tc06-post →"
        echo "    --tc15-pre → (재부팅 대기) → --tc15-post → --tc20-pre → (재부팅 대기) → --tc20-post →"
        echo "    --tc26-pre → (재부팅 대기) → --tc26-post   (TC26는 factory_reset — 항상 마지막)"
        ;;
    --only)
        # 대시보드의 "선택 실행"에서 사용 — 콤마로 구분된 TC 목록을 받아 그 TC들만 실행한다.
        # 예: sh tc_device_log.sh --only TC01,TC10
        # 재부팅 수반 TC(06/07,15,20,26)는 세션이 끊겨 다른 TC와 한 번에 묶을 수 없어
        # 지원하지 않는다(대시보드는 이 TC들을 --only 대신 -pre/-post 체이닝으로 실행한다).
        shift
        SELECTED="${1:-}"
        if [ -z "$SELECTED" ]; then
            echo "[ERROR] --only 뒤에 TC 목록이 필요합니다 (예: --only TC01,TC03,TC10)"
            exit 1
        fi
        case ",${SELECTED}," in
            *,TC06,*|*,TC07,*|*,TC15,*|*,TC20,*|*,TC26,*)
                echo "[ERROR] TC06/TC07/TC15/TC20/TC26는 재부팅을 수반해 --only로 묶을 수 없습니다 — 각 -pre/-post 플래그를 사용하세요"
                exit 1
                ;;
        esac

        # 표준 실행 순서를 그대로 따른다 — 콤마 목록 순서와 무관. TC05(6시간+)는 항상 맨
        # 마지막(다른 선택 TC 결과를 먼저 보여주기 위함).
        for tc in TC01 TC02 TC03 TC04 TC08 TC09 TC10 TC11 TC12 TC13 TC14 TC16 TC17 TC18 TC19 TC21 TC22 TC23 TC24 TC25 TC27 TC05; do
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
                        TC21) tc21_round_robin ;;
                        TC22) tc22_forced_upload ;;
                        TC23) tc23_eol_logging ;;
                        TC24) tc24_eol_compress_format ;;
                        TC25) tc25_eol_field_logging_stop ;;
                        TC27) tc27_eol_extract_skip ;;
                    esac
                    ;;
            esac
        done

        print_result
        ;;
    *)
        # 빠른 실행(회귀 세트): 재부팅/시스템시간변경/정책파일수정+재시작/6시간대기가
        # 필요한 TC(05,06,07,09,15,18,19,20,26)는 제외하고 나머지를 순서대로 실행한다.
        run_quick_set

        print_result
        echo ""
        echo "[안내] 아래 TC는 별도 실행 (빠른 실행에 미포함):"
        echo "  ./tc_device_log.sh --tc05        (logCreationTime 6시간+5분 자연 경과 대기)"
        echo "  ./tc_device_log.sh --tc06-pre / --tc06-post   (재부팅 수반, TC07 포함)"
        echo "  ./tc_device_log.sh --tc09        (logpolicy.json fileCount 임시수정+재시작, 원복 포함)"
        echo "  ./tc_device_log.sh --tc15-pre / --tc15-post   (재부팅 수반)"
        echo "  ./tc_device_log.sh --tc18        (시스템 시간 변경 — 자정 루틴)"
        echo "  ./tc_device_log.sh --tc19        (시스템 시간 변경 — 월 전환)"
        echo "  ./tc_device_log.sh --tc20-pre / --tc20-post   (재부팅 수반)"
        echo "  ./tc_device_log.sh --tc26-pre / --tc26-post   (factory_reset 전체 로그 삭제 + 재부팅 — 파괴적)"
        echo "  ./tc_device_log.sh --full        (TC01~05,08~14,16~19,21~25,27 전체, 재부팅 4사이클은 대시보드가 이어서 진행)"
        echo "  ./tc_device_log.sh --only TC01,TC03,...   (선택 실행, 재부팅 TC 제외)"
        ;;
esac
