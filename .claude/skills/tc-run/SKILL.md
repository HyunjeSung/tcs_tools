---
name: tc-run
description: AC Gen2 EMS 디바이스(config.env의 DUT_HOST)에 시리얼(config.env의 SERIAL_COM_PORT)로 접속해 `tcs/<name>/tc_<name>.sh` TC 스크립트를 transfer + 실행 + 결과 회수 + evidence 갱신을 한 번에 수행하는 스킬. 인자로 TC 이름(예: system_log, device_log, update_monitor, ...) 받음. "TC 돌려", "TC 실행", "시리얼로 TC", "tc-run" 같은 키워드에서 활성화. reboot 포함 시나리오는 -pre/-post로 분리. app마다 다른 helper를 자동 분기해서 쓰므로 앱 이름만 바꿔서 그대로 재사용 가능.
version: 2.1.0
---

# TC 실행 자동화 스킬

`tcs/<name>/tc_<name>.sh` 스크립트를 시리얼로 디바이스에 전송 → 실행 → 결과 회수 → `tcs/<name>/tc_<name>_evidence_full.log` 갱신까지 자동화.

**두 가지 실행 경로가 있고, `<name>`에 따라 자동으로 갈린다:**

| `<name>` | 경로 | 이유 |
|---|---|---|
| `system_log` | **전용 경로** — `tools/serial/serial_helper.ps1`의 phase(`transfer`/`run_main`/`tc10pre`/`tc10post`) 사용 | journal/mqtt 백그라운드 캡처 + `[SL]`/`[SM]` 필터링 등 system_log 전용 evidence 수집 로직이 이미 검증되어 있음 — 그대로 유지 |
| 그 외 전부 (`device_log`, `update_monitor`, `sys_manager`, ...) | **범용 경로** — `tools/tc_dashboard/serial_run.ps1` 사용 (tc-dashboard가 내부적으로 쓰는 것과 동일한 메커니즘) | 앱마다 새 phase를 만들 필요 없이 `-ScriptPath`/`-Flag`만 바꿔서 그대로 재사용 가능. tc-dashboard에서 이미 여러 앱에 대해 검증된 경로 |

> **과거 함정 (2026-08-21):** `serial_helper.ps1`의 `run_main` phase는 system_log 전용 명령(`--tc-nmon`)과 필터 문자열(`[SL]`, `emsp/system_log`)이 하드코딩되어 있어서, 다른 앱에 그대로 쓰면 존재하지도 않는 플래그를 실행하고 아무것도 안 걸리는 필터로 빈 evidence를 만든다. **`system_log`가 아니면 절대 `run_main`/`tc10pre`/`tc10post` phase를 쓰지 말 것** — 반드시 아래 "경로 B"를 사용한다.

## 사전 조건 (공통)

- 레포 루트의 `config.env` 값이 본인 환경과 맞는지 확인 (`DUT_HOST`, `SSH_KEY_PATH`, `SERIAL_COM_PORT`, `WIN_KEY_PATH`, `WIN_TEMP_LOG_PATH`) — 다르면 직접 수정
- DUT(config.env의 `DUT_HOST`) 시리얼 콘솔이 Windows config.env의 `SERIAL_COM_PORT`에 연결되어 있을 것. **COM 포트는 PC 재부팅/USB 재연결마다 바뀔 수 있으므로 하드코딩하지 말고 매번 config.env에서 읽거나 `GetPortNames()`로 재확인할 것**
- WSL2 환경 — `wslpath -w`로 Windows 경로 변환 가능
- `tcs/<name>/tc_<name>.sh`가 작성되어 있고 busybox 호환 (TC 명세 + 스크립트는 `/tc-dev` 스킬 참조)

자세한 시리얼 접속/회복 절차는 `docs/device_ssh.md` 참조. 아래 모든 bash 블록은 **레포 루트에서 `source config.env` 실행 후**를 전제로 한다.

## 사용

```
/tc-run <name>                 # 기본(빠른/회귀) 세트 실행
/tc-run <name> --tcNN          # 개별 TC 하나만 실행
/tc-run <name> tcNN-pre        # reboot 시나리오 pre 단계 (reboot 발생)
/tc-run <name> tcNN-post       # reboot 후 post 단계
```

예: `/tc-run system_log`, `/tc-run device_log --tc09`, `/tc-run device_log tc07-pre` → `/tc-run device_log tc07-post`

## Phase 0 — ComPort 확정 (공통, 매번 먼저 실행)

```bash
source config.env   # DUT_HOST, SSH_KEY_PATH, SERIAL_COM_PORT, WIN_KEY_PATH, WIN_TEMP_LOG_PATH

PORTS=$(powershell.exe -NoProfile -Command "[System.IO.Ports.SerialPort]::GetPortNames()" 2>&1 | tr -d '\r')
echo "설정된 포트: $SERIAL_COM_PORT / 실제 인식된 포트: $PORTS"

if ! echo "$PORTS" | grep -q "^${SERIAL_COM_PORT}\$"; then
    # 1회만 좀비 프로세스 정리 후 재확인 — 그래도 안 잡히면 사용자에게 실제 포트를 물어볼 것
    # (USB 재연결 요구는 사용자에게만 — 반복 재시도로 시간 낭비하지 말 것)
    powershell.exe -NoProfile -Command "Stop-Process -Name powershell -Force -ErrorAction SilentlyContinue"
    PORTS=$(powershell.exe -NoProfile -Command "[System.IO.Ports.SerialPort]::GetPortNames()" 2>&1 | tr -d '\r')
fi
```

포트가 끝까지 안 잡히면 시리얼 대신 SSH fallback (아래 "SSH fallback" 절, `docs/device_ssh.md`의 3회 재시도 lockout 제한 반드시 준수).

---

## 경로 A — `system_log` 전용

`serial_helper.ps1` 위치: `tools/serial/serial_helper.ps1` (레포 루트 기준 상대경로)

### Phase A2 — 스크립트 transfer

```bash
md5sum tcs/system_log/tc_system_log.sh
WIN_PS=$(wslpath -w tools/serial/serial_helper.ps1)
mv "$WIN_TEMP_LOG_PATH"{,.prev} 2>/dev/null
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -ComPort "$SERIAL_COM_PORT" -Phase transfer 2>&1 | tr -d '\r' | tail -3
grep -a '<expected md5>' "$WIN_TEMP_LOG_PATH"
```

### Phase A3 — TC 실행 + 회수

```bash
cp "$WIN_TEMP_LOG_PATH"{,.transfer}
rm -f "$WIN_TEMP_LOG_PATH"
date '+RUN_START: %T'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -ComPort "$SERIAL_COM_PORT" -Phase run_main 2>&1 | tr -d '\r' | tail -10
date '+RUN_END: %T'
```

run_main은 디바이스에서: 노이즈 차단 → NTP 정지 → journal/mqtt 백그라운드 캡처 시작 → `/tmp/tc_system_log.sh --tc-nmon` 실행 → 캡처 정지 → `[SL]`/`[SM]`/`task_*` 필터링 → 작은 파일들 base64 dump.

### Phase A4 — base64 디코드

```bash
CON="$WIN_TEMP_LOG_PATH"
RUN=/tmp/system_log_run<n>
mkdir -p $RUN

for tag in tc_run_out tc_sl_filt tc_mqtt_filt; do
    tr -d '\r' < "$CON" \
        | awk -v b="M_DUMPBEG_$tag" -v e="M_DUMPEND_$tag" \
            'index($0,b){p=1;next} index($0,e){p=0} p' \
        | grep -oE '[A-Za-z0-9+/=]+' | tr -d '\n' \
        | base64 -d > $RUN/$tag.log 2>/dev/null
done
```

> 큰 파일은 시리얼 buffer overrun으로 corrupt 가능. 작은 필터 파일만 dump 권장.

### Phase A — `tc10-pre`/`tc10-post` (reboot 시나리오)

```bash
case "$2" in
    tc10-pre)
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -ComPort "$SERIAL_COM_PORT" -Phase tc10pre 2>&1
        until ping -c 1 -W 1 "$DUT_HOST" > /dev/null 2>&1; do sleep 2; done
        sleep 30   # boot 직후 task_capture_boot_log + task_merge_staged_logs 완료 대기
        ;;
    tc10-post)
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -ComPort "$SERIAL_COM_PORT" -Phase transfer   # /tmp는 ramdisk — reboot 후 스크립트 소실, 재전송 필요
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -ComPort "$SERIAL_COM_PORT" -Phase tc10post 2>&1
        ;;
esac
```

---

## 경로 B — 범용 (`system_log` 이외 전부: device_log, update_monitor, sys_manager, db_manager, device_manager, azure_connector, edge_runtime, web_interface, energy_monitor, 신규 앱...)

`serial_run.ps1` 위치: `tools/tc_dashboard/serial_run.ps1` — tc-dashboard(:8090)가 실제로 쓰는 것과 **동일한 스크립트**. 앱별 phase를 새로 안 만들어도, `-ScriptPath`(전송할 로컬 스크립트 경로)와 `-Flag`(디바이스에서 실행할 인자, 예: `--tc09`)만 바꾸면 어떤 앱이든 그대로 동작한다. **한 번 호출에 transfer+실행+base64 dump+디코드까지 전부 끝난다** — 별도 transfer phase 불필요, reboot 후에도 매 호출마다 재전송하므로 `/tmp` ramdisk 휘발 문제가 자동으로 해결된다.

### Phase B1 — 단일 TC(또는 default) 실행

```bash
NAME=device_log          # 예시
FLAG='--tc09'            # 개별 TC. default 세트를 돌리려면 빈 문자열: FLAG=''
TIMEOUT_MS=120000         # tools/tc_dashboard의 CATALOG_<APP>에 있는 timeout(초)*1000 참고

SCRIPT_WIN=$(wslpath -w "tcs/$NAME/tc_${NAME}.sh")
PS1_WIN=$(wslpath -w tools/tc_dashboard/serial_run.ps1)

RUN=/tmp/${NAME}_run<n>
mkdir -p "$RUN"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" \
    -ComPort "$SERIAL_COM_PORT" -ScriptPath "$SCRIPT_WIN" -Flag "$FLAG" \
    -TimeoutMs $TIMEOUT_MS -LogFile "$(wslpath -w "$WIN_TEMP_LOG_PATH")" \
    > "$RUN/main.log" 2>&1

tail -30 "$RUN/main.log"    # SERIAL_RUN_OK=True/False로 끝나는지 확인
```

`serial_run.ps1`의 stdout(`$RUN/main.log`)이 곧 evidence 원문이다 — 별도 marker 파싱/디코딩이 필요 없다(내부에서 이미 base64 디코드해서 UTF-8 텍스트로 출력함). `PASS=<N> FAIL=<N>` 요약 줄과 각 TC의 `[PASS]`/`[FAIL]` 라인, 그리고 스크립트가 자체적으로 찍는 `dump_cmd`류 실제 명령어 출력이 그대로 들어있다.

`-TimeoutMs`는 실행 자체가 걸릴 것으로 예상되는 시간(WaitFor 타임아웃)이다 — 부족하면 `SERIAL_RUN_OK=False`로 끝나며 마지막 dump는 안 될 수 있다. `tools/tc_dashboard/server.py`의 `CATALOG_<APP대문자>`에 이미 TC별로 검증된 timeout(초 단위)이 있으니 그대로 `*1000`해서 쓰면 된다(예: device_log TC05는 22500초=6h+여유이므로 `TimeoutMs=22500000`).

### Phase B2 — reboot 시나리오 (`tcNN-pre`/`tcNN-post`)

pre 호출은 리부팅으로 세션이 끊기면서 `SERIAL_RUN_OK=False`로 끝날 수 있는데, **정상**이다 — pre 단계 목적은 리부팅 전 상태를 남기는 것뿐이므로 이 값 자체는 판정에 안 쓴다.

```bash
FLAG='--tc07-pre'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" \
    -ComPort "$SERIAL_COM_PORT" -ScriptPath "$SCRIPT_WIN" -Flag "$FLAG" -TimeoutMs 90000 \
    > "$RUN/tc07-pre.log" 2>&1

until ping -c 1 -W 1 "$DUT_HOST" > /dev/null 2>&1; do sleep 2; done
sleep 20   # 부팅 직후 서비스 기동 여유

FLAG='--tc07-post'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" \
    -ComPort "$SERIAL_COM_PORT" -ScriptPath "$SCRIPT_WIN" -Flag "$FLAG" -TimeoutMs 180000 \
    > "$RUN/tc07-post.log" 2>&1
tail -30 "$RUN/tc07-post.log"
```

> post 호출도 매번 스크립트를 재전송하므로 `/tmp` ramdisk 휘발 걱정 없이 그냥 다시 호출하면 된다. pre→post 사이 상태 전달은 TC 스크립트 내부가 `/edge/log/` 아래(영구 저장소)에 상태 파일을 남기는 방식으로 처리한다(TC 스크립트 구현 참고, `/tc-dev` 산출물).

### Phase B3 — evidence_full 갱신

```bash
FULL=tcs/$NAME/tc_${NAME}_evidence_full.log
{
    echo "############################################################"
    echo "# $NAME TC 통합 Evidence"
    echo "# 생성: $(date '+%F %T')"
    echo "# DUT: $DUT_HOST (ComPort $SERIAL_COM_PORT)"
    echo "# 스크립트 md5: $(md5sum tcs/$NAME/tc_${NAME}.sh | cut -d' ' -f1)"
    echo "############################################################"
    for f in "$RUN"/*.log; do
        echo ""
        echo "############################################################"
        echo "# FILE: $(basename "$f")  ($(wc -l < "$f") lines)"
        echo "############################################################"
        cat "$f"
    done
} > "$FULL"
```

`tcs/<name>/tc_<name>_result.md`는 4파일 패턴(`/tc-dev` 스킬 참조)에 따라 갱신. **인용은 반드시 `evidence_full.log`에 실제 있는 로그만.**

---

## SSH fallback (시리얼 완전 불가 시, 두 경로 공통)

```bash
SSH_KEY="$SSH_KEY_PATH"   # config.env에서 로드된, passphrase 제거된 사본
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"

scp -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    tcs/<name>/tc_<name>.sh root@$DUT_HOST:/tmp/<name>.sh
ssh $SSH_OPTS root@$DUT_HOST 'chmod +x /tmp/<name>.sh && md5sum /tmp/<name>.sh'

mkdir -p /tmp/<name>_full
ssh $SSH_OPTS root@$DUT_HOST '/tmp/<name>.sh 2>&1' > /tmp/<name>_full/main.log 2>&1
ssh $SSH_OPTS root@$DUT_HOST '/tmp/<name>.sh --tc11 2>&1' > /tmp/<name>_full/tc11.log   # 개별 TC 예시

# reboot 시나리오
timeout 360 ssh $SSH_OPTS root@$DUT_HOST 'sync; /tmp/<name>.sh --tcNN-pre' > /tmp/<name>_full/pre.log
sleep 20
until ping -c 1 -W 1 "$DUT_HOST" > /dev/null 2>&1; do sleep 2; done
until ssh $SSH_OPTS root@$DUT_HOST 'echo ALIVE' > /dev/null 2>&1; do sleep 3; done
scp -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    tcs/<name>/tc_<name>.sh root@$DUT_HOST:/tmp/<name>.sh    # /tmp는 ramdisk — 재전송
ssh $SSH_OPTS root@$DUT_HOST 'chmod +x /tmp/<name>.sh'
sleep 45
ssh $SSH_OPTS root@$DUT_HOST '/tmp/<name>.sh --tcNN-post 2>&1' > /tmp/<name>_full/post.log

# raw 근거 수집 (SECTION 6에 들어갈 자료)
ssh $SSH_OPTS root@$DUT_HOST '
echo "############ ls -la toupload ############"
ls -la /edge/log/toupload/<app>/
echo "############ xz --test ############"
for f in /edge/log/toupload/<app>/*.log.xz; do echo "$f: $(xz --test "$f" 2>&1 && echo OK)"; done
echo "############ boot 0 [SL] 로그 ############"
journalctl -b 0 -u docker-loader --no-pager -o short-iso 2>/dev/null | grep -F "[SL]"
echo "############ journal --disk-usage ############"
journalctl --disk-usage
' > /tmp/<name>_full/raw_evidence.log
```

> **`docs/device_ssh.md`의 lockout 제한 준수 필수**: SSH/scp 연결 시도는 실패 시 1~2회만 재시도, 3회 이상 짧은 간격으로 재시도하면 DUT가 리부팅 전까지 SSH를 막아버린다. 의심되면 시리얼로만 상태 확인하고 사용자에게 리부트를 요청할 것.

### SSH 키 사본 (한 번만 생성)

원본 키(config.env의 `WIN_KEY_PATH`)에 passphrase가 걸려 있어 자동화 불가. 다음으로 한 번 만들어 두면 이후 재사용 (대상 경로는 config.env의 `SSH_KEY_PATH`):

```bash
cp "$WIN_KEY_PATH" "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
ssh-keygen -p -P '<원본 passphrase>' -N '' -f "$SSH_KEY_PATH"
```

(passphrase를 사용자가 알려준 경우에만 위 명령으로 사본 생성. 원본은 건드리지 않음.)

## 실패 케이스 핸들링

| 증상 | 원인 | 대처 |
|---|---|---|
| 설정된 COM 포트가 `GetPortNames()`에 없음 | 좀비 powershell, USB disconnect, 또는 포트 번호가 실제로 바뀜(PC 재부팅 등) | `Stop-Process -Name powershell -Force` 1회 → 재확인. 그래도 없으면 사용자에게 실제 포트 확인 요청(`config.env`도 갱신) |
| (경로 A) `M_TC09_DONE_END` 같은 marker 매칭 즉시 success | 콘솔에 우리가 보낸 명령이 echo back되어 false-match | `stty -echo` 적용 + `(?m)^M_` 라인 시작 매칭 (helper 내부에 이미 구현됨) |
| (경로 B) `SERIAL_RUN_OK=False` | `-TimeoutMs` 부족, 또는 reboot로 세션이 끊김(pre 단계면 정상) | timeout 늘려서 재시도, 또는 pre/post 분리했는지 확인 |
| base64 디코드 일부만 됨 / 텍스트 깨짐 | 시리얼 buffer overrun | 큰 파일 dump 피하고 작은 필터/요약만 dump. 경로 B는 결과 파일(`$RUN/main.log`) 하나만 dump하므로 원래 덜 취약함 |
| `/tmp/tc_*.sh` 없음 | reboot 후 ramdisk 휘발 | 경로 A는 transfer phase 재실행, 경로 B는 매 호출이 자동 재전송이라 신경 안 써도 됨 |
| (경로 A, system_log 한정) 시간 +25h shift 후 timer 발화 안 함 | SETUP의 `task_rotate_sync`가 `last_run_time` 갱신 가능 | 시간 민감 TC를 SETUP 이전에 배치 |

## 시간 단축 팁

- TC 안의 `sleep 70` → `sleep 30`으로 줄여도 정상 발화 (system_log 24h timer의 1초 polling 기준 충분)
- helper의 chunked 큰 파일 dump 제거 (sl_filt + mqtt_filt 작은 필터 파일로 대체) — corrupt 위험 + 시간 절약
- SETUP `sleep 10` → `sleep 5`도 안전 (detached thread의 file 생성은 보통 1초 안)
- base64 chunk 큰 라인(`-w 32768`) 사용 시 systemd-cat 같은 데이터 주입 30~50배 빠름
