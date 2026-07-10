#!/bin/bash
# repro_merge_bug.sh — task_merge_staged_logs 버그 재현 / fix 검증
# 실행 위치: DUT 호스트 (root@qcells-emsplus)

STAGING="/edge/log/system"
TOUPLOAD="/edge/log/toupload/system"

sl_pids() { ps aux | grep '[/]system_log' | awk '{print $1}'; }

kill_sl_nowait() {
    local pids; pids=$(sl_pids)
    if [ -n "$pids" ]; then
        echo "  kill -9: $(echo $pids)"
        echo "$pids" | xargs kill -9 2>/dev/null
    else
        echo "  system_log 없음"
    fi
}

# ── 0. 시스템 안정화 대기 (host_agent 연결 확인) ────────
echo "=== [0/3] 시스템 안정화 대기 ==="
for i in $(seq 1 60); do
    STATUS=$(journalctl -n 50 2>/dev/null | grep 'all_apps_ready\|host_agent_disconnected=false' | tail -1)
    HA=$(journalctl -n 100 2>/dev/null | grep 'host_agent_disconnected=false' | tail -1)
    if [ -n "$HA" ]; then
        echo "  host_agent 연결 확인 (${i}s)"
        break
    fi
    printf "  [%2ds] 대기 중...\r" "$i"
    sleep 1
done
echo ""

# ── 1. start_time 확인 ──────────────────────────────────
echo "=== [1/3] start_time 확인 ==="
START=$(journalctl --list-boots | head -n 1 \
  | awk '{print $4, $5}' | sed 's/[-:]//g' | tr -d ' ')
echo "  START = $START"
[ -z "$START" ] && { echo "  [에러] start_time 취득 실패"; exit 1; }

# ── 2. 파일 심기 (SL 실행 중 — task_merge는 startup-only이므로 안전) ──
echo ""
echo "=== [2/3] fake .xz 2개 심기 ==="
mkdir -p "$STAGING"
rm -f "$STAGING"/systemlog_*.log.xz "$STAGING"/systemlog_*.log "$STAGING"/.merging_*.tmp
rm -f /tmp/systemlog_*.log /tmp/systemlog_*.log.xz

seq 1 5000 > /tmp/fake.log
INPUT_SIZE=$(stat -c%s /tmp/fake.log)
echo "  입력 크기: ${INPUT_SIZE}B"

for SUFFIX in 01 02; do
    SRC="/tmp/systemlog_${START}_${START}${SUFFIX}.log"
    cp /tmp/fake.log "$SRC"
    xz -1 "$SRC"
    cp "${SRC}.xz" "$STAGING/"
done
ls -lh "$STAGING"/systemlog_*.log.xz | sed 's/^/  /'

# ── 3. SL kill → edge_runtime이 재시작하면서 staged 파일 발견 ──
echo ""
echo "=== [3/3] system_log kill → edge_runtime 재시작 대기 ==="
touch /tmp/repro_start_marker
kill_sl_nowait

# ── 4. 모니터링 ─────────────────────────────────────────
echo ""
echo "  예상 흐름:"
echo "    planted a : systemlog_${START}_${START}01.log.xz"
echo "    planted b : systemlog_${START}_${START}02.log.xz"
echo "    edge_runtime 재시작 → task_merge_staged_logs → 2개 병합"
echo "    [BUG] merged_log == b 압축해제 경로 → self-copy 무한 증가"
echo "    [FIX] .merging_*.tmp → rename → xz → toupload"
echo ""
echo "  [BUG] staging .log 파일 10MB 초과 감지"
echo "  [FIX] toupload에 .log.xz 신규 생성"
echo ""

THRESHOLD=$((1024 * 1024 * 10))

for i in $(seq 1 180); do
    sleep 1
    printf "[%2ds] " "$i"

    # staging: .merging tmp
    for f in "$STAGING"/.merging_*.tmp; do
        [ -f "$f" ] || continue
        printf ".merging_tmp=%dB  " "$(stat -c%s "$f" 2>/dev/null)"
    done

    # staging: .log (bug 감지)
    BUG=0
    for f in "$STAGING"/systemlog_*.log; do
        [ -f "$f" ] || continue
        SIZE=$(stat -c%s "$f" 2>/dev/null || echo 0)
        printf "$(basename $f)=%dB  " "$SIZE"
        [ "$SIZE" -gt "$THRESHOLD" ] && BUG=1
    done

    TOUPLOAD_NEW=$(find "$TOUPLOAD" -name "systemlog_*.log.xz" -newer /tmp/repro_start_marker 2>/dev/null | wc -l)
    printf "| toupload +%d개"  "$TOUPLOAD_NEW"
    echo ""

    if [ "$BUG" -eq 1 ]; then
        echo ""
        echo "=== [결과] BUG 재현 — .log 파일 비정상 증가 ==="
        exit 1
    fi

    if [ "$TOUPLOAD_NEW" -ge 1 ]; then
        echo ""
        echo "=== [결과] FIX 정상 동작 ==="
        echo "  신규 toupload 파일:"
        find "$TOUPLOAD" -name "systemlog_*.log.xz" -newer /tmp/repro_start_marker 2>/dev/null \
            | xargs ls -lht 2>/dev/null | head -5 | sed 's/^/  /'
        echo ""
        echo "  staging 최종 상태:"
        ls -lh "$STAGING"/ 2>/dev/null | sed 's/^/  /'
        exit 0
    fi

    if [ $((i % 20)) -eq 0 ]; then
        echo "  --- staging 상태 ---"
        ls -lh "$STAGING"/ 2>/dev/null | sed 's/^/  /'
    fi
done

echo ""
echo "180초 내 미확인"
echo "--- staging ---"
ls -lh "$STAGING"/ 2>/dev/null
