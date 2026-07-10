---
name: tc-run
description: AC Gen2 EMS 디바이스(config.env의 DUT_HOST)에 시리얼(config.env의 SERIAL_COM_PORT)로 접속해 `tcs/<name>/tc_<name>.sh` TC 스크립트를 transfer + 실행 + 결과 회수 + evidence 갱신을 한 번에 수행하는 스킬. 인자로 TC 이름(예: system_log, device_log) 받음. "TC 돌려", "TC 실행", "시리얼로 TC", "tc-run" 같은 키워드에서 활성화. reboot 포함 TC10 같은 시나리오는 별도 phase로 분리.
version: 1.0.0
---

# TC 실행 자동화 스킬

`tcs/<name>/tc_<name>.sh` 스크립트를 시리얼(config.env의 SERIAL_COM_PORT) 로 디바이스에 전송 → 실행 → 결과 회수 → `tcs/<name>/tc_<name>_evidence_full.log` 갱신까지 자동화.

## 사전 조건

- 레포 루트에 `config.env` 존재 (`config.env.example` 복사 후 값 수정 — `DUT_HOST`, `SSH_KEY_PATH`, `SERIAL_COM_PORT`, `WIN_KEY_PATH`, `WIN_TEMP_LOG_PATH`)
- DUT(config.env의 DUT_HOST) 시리얼 콘솔이 Windows config.env의 SERIAL_COM_PORT 에 연결되어 있을 것
- `powershell.exe -Command "[System.IO.Ports.SerialPort]::GetPortNames()"` 결과에 config.env의 SERIAL_COM_PORT 있음
- WSL2 환경 — `wslpath -w` 로 Windows 경로 변환 가능
- `tools/serial/serial_helper.ps1` 존재 (레포에 포함됨)
- `tcs/<name>/tc_<name>.sh` 가 작성되어 있고 busybox 호환 (TC 명세 + 스크립트는 `/tc-dev` 스킬 참조)

자세한 시리얼 접속/회복 절차는 `docs/device_ssh.md` 참조. 아래 모든 bash 블록은 **레포 루트에서 `source config.env` 실행 후**를 전제로 한다.

## 사용

```
/tc-run <name>             # TC01~TC09 또는 SETUP+main TC 일괄
/tc-run <name> tc10-pre    # reboot 시나리오 pre 단계 (reboot 발생)
/tc-run <name> tc10-post   # reboot 후 post 단계
```

예: `/tc-run system_log`

## 실행 단계

### Phase 1 — 사전 점검 + 시리얼/SSH 분기

```bash
source config.env   # DUT_HOST, SSH_KEY_PATH, SERIAL_COM_PORT, WIN_KEY_PATH, WIN_TEMP_LOG_PATH

# 설정된 시리얼 포트 인식 확인
PORTS=$(powershell.exe -NoProfile -Command "[System.IO.Ports.SerialPort]::GetPortNames()" 2>&1 | tr -d '\r')
echo "$PORTS"

if echo "$PORTS" | grep -q "^${SERIAL_COM_PORT}$"; then
    MODE=serial
else
    # 설정된 시리얼 포트 미인식 → 자동 SSH fallback (사용자 합의된 분기)
    #   복구 시도 순서:
    #     1. 좀비 powershell 종료 (1회만): powershell.exe -NoProfile -Command "Stop-Process -Name powershell -Force -ErrorAction SilentlyContinue"
    #     2. 다시 GetPortNames() 확인 — 여전히 미인식이면 SSH fallback
    #   복구 안내는 했지만 USB 재연결 요구는 사용자에게만 — AI 가 자동 SSH 분기로 진행
    MODE=ssh
fi
```

| MODE | Phase 2~ 진행 |
|---|---|
| `serial` | helper.ps1 의 phase (`transfer` → `run_main` → ...) 호출 — 아래 Phase 2~5 표준 흐름 |
| `ssh` | scp 로 스크립트 전송 + `ssh root@$DUT_HOST '/tmp/tc_<name>.sh' > main.log` 로 실행 + 사후 ssh 로 ls/journalctl/xz 수집 — SSH fallback 흐름 (별도 절 참조) |

#### SSH fallback 흐름 (`MODE=ssh`)

```bash
SSH_KEY="$SSH_KEY_PATH"   # config.env 에서 로드된 passphrase 제거 사본
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"

# 1. scp 로 스크립트 전송
scp -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    tcs/<name>/tc_<name>.sh root@$DUT_HOST:/tmp/<name>.sh
ssh $SSH_OPTS root@$DUT_HOST 'chmod +x /tmp/<name>.sh && md5sum /tmp/<name>.sh'

# 2. 메인 TC 실행 (stdout 캡처)
mkdir -p /tmp/sl_full
ssh $SSH_OPTS root@$DUT_HOST '/tmp/<name>.sh 2>&1' > /tmp/sl_full/main.log 2>&1

# 3. (선택) 단일 TC 분리 실행
ssh $SSH_OPTS root@$DUT_HOST '/tmp/<name>.sh --tc11 2>&1' > /tmp/sl_full/tc11.log

# 4. (TC10 reboot 시나리오)
timeout 360 ssh $SSH_OPTS root@$DUT_HOST 'sync; /tmp/<name>.sh --tc10-pre' > /tmp/sl_full/tc10pre.log
sleep 20
until ping -c 1 -W 1 "$DUT_HOST" > /dev/null 2>&1; do sleep 2; done
until ssh $SSH_OPTS root@$DUT_HOST 'echo ALIVE' > /dev/null 2>&1; do sleep 3; done
# /tmp 는 ramdisk라 reboot 후 스크립트 휘발 → scp 재전송
scp -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    tcs/<name>/tc_<name>.sh root@$DUT_HOST:/tmp/<name>.sh
ssh $SSH_OPTS root@$DUT_HOST 'chmod +x /tmp/<name>.sh'
sleep 45   # boot+merge 대기
ssh $SSH_OPTS root@$DUT_HOST '/tmp/<name>.sh --tc10-post 2>&1' > /tmp/sl_full/tc10post.log

# 5. raw 근거 수집 (SECTION 6 에 들어갈 자료)
ssh $SSH_OPTS root@$DUT_HOST '
echo "############ ls -la toupload ############"
ls -la /edge/log/toupload/<app>/
echo "############ xz --test ############"
for f in /edge/log/toupload/<app>/*.log.xz; do echo "$f: $(xz --test "$f" 2>&1 && echo OK)"; done
echo "############ boot 0 [SL] 로그 ############"
journalctl -b 0 -u docker-loader --no-pager -o short-iso 2>/dev/null | grep -F "[SL]"
echo "############ journal --disk-usage ############"
journalctl --disk-usage
' > /tmp/sl_full/raw_evidence.log
```

#### SSH 키 사본 (한 번만 생성)

원본 키 (config.env의 WIN_KEY_PATH) 에 passphrase 가 걸려 있어 자동화 불가. 다음으로 한 번 만들어 두면 이후 재사용 (대상 경로는 config.env의 SSH_KEY_PATH):

```bash
cp "$WIN_KEY_PATH" "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
ssh-keygen -p -P '<원본 passphrase>' -N '' -f "$SSH_KEY_PATH"
```

(passphrase 를 사용자가 알려준 경우에만 위 명령으로 사본 생성. 원본은 건드리지 않음.)

### Phase 2 — 스크립트 transfer

```bash
md5sum tcs/<name>/tc_<name>.sh
WIN_PS=$(wslpath -w tools/serial/serial_helper.ps1)   # 레포 루트에서 실행 기준
# 콘솔 로그 백업
mv "$WIN_TEMP_LOG_PATH"{,.prev} 2>/dev/null
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -Phase transfer 2>&1 | tr -d '\r' | tail -3
# md5 일치 확인:
grep -a '<expected md5>' "$WIN_TEMP_LOG_PATH"
```

helper 의 transfer phase 는 base64 chunked (chunk 512, sleep 110ms) 로 `tcs/<name>/tc_<name>.sh` 를 `/tmp/tc_system_log.sh` 에 작성. md5 검증까지 자동.

> **`<name>` 가 `system_log` 가 아닌 경우 helper 의 transfer 단계가 `/tmp/tc_system_log.sh` 고정 경로를 사용하므로, helper 의 `ScriptPath` 인자를 명시적으로 넘긴다 (배포판 이름 `Ubuntu-18.04`는 `wsl.exe -l -v` 로 확인해 본인 환경에 맞게 수정):**
> ```bash
> powershell.exe ... -File "$WIN_PS" -Phase transfer -ScriptPath "\\wsl.localhost\Ubuntu-18.04$(realpath tcs/<name>/tc_<name>.sh | tr / \\)"
> ```

### Phase 3 — TC 실행 + 회수

```bash
cp "$WIN_TEMP_LOG_PATH"{,.transfer}
rm -f "$WIN_TEMP_LOG_PATH"
date '+RUN_START: %T'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -Phase run_main 2>&1 | tr -d '\r' | tail -10
date '+RUN_END: %T'
```

helper 의 run_main 은 디바이스에서:
1. 노이즈 차단 (`dmesg -n 1`, `stty -echo`, `PS1=P>`)
2. NTP 정지 (`timedatectl set-ntp false`)
3. 백그라운드 capture 시작 (`journalctl -u docker-loader -f > /tmp/tc_journal.log &`, `mosquitto_sub > /tmp/tc_mqtt.log &`)
4. `/tmp/tc_system_log.sh` 실행 → `/tmp/tc_run.out`
5. capture 정지
6. `[SL]/[SM]/task_*` 등 필터링 → `/tmp/tc_sl_filt.log`, `/tmp/tc_mqtt_filt.log`
7. 명령어 결과 캡처 (`ls`, `xz --test`, `md5sum`, `journalctl --disk-usage`, `df -h`)
8. 작은 파일들을 base64 dump 로 콘솔에 출력 → 콘솔 로그에 캡처됨

### Phase 4 — base64 디코드

```bash
CON="$WIN_TEMP_LOG_PATH"
RUN=/tmp/<name>_run<n>     # 회차별 디렉토리
mkdir -p $RUN

for tag in tc_run_out tc_sl_filt tc_mqtt_filt; do
    tr -d '\r' < "$CON" \
        | awk -v b="M_DUMPBEG_$tag" -v e="M_DUMPEND_$tag" \
            'index($0,b){p=1;next} index($0,e){p=0} p' \
        | grep -oE '[A-Za-z0-9+/=]+' | tr -d '\n' \
        | base64 -d > $RUN/$tag.log 2>/dev/null
done
tr -d '\r' < "$CON" | awk '/M_CMDOUT_BEGIN/{p=1;next} /M_CMDOUT_END/{p=0} p' > $RUN/cmd_outputs.log
```

> 큰 파일은 시리얼 buffer overrun 으로 corrupt 가능. `[APP_TAG]` 등으로 필터링된 작은 파일만 dump 권장.

### Phase 5 — evidence_full + result.md 갱신

```bash
FULL=tcs/<name>/tc_<name>_evidence_full.log
{
    echo "############################################################"
    echo "# <name> TC 통합 Evidence"
    echo "# 생성: $(date '+%F %T')"
    echo "# DUT: $DUT_HOST"
    echo "# 스크립트 md5: $(md5sum tcs/<name>/tc_<name>.sh | cut -d' ' -f1)"
    echo "# 결과: PASS=<P> / FAIL=<F>"
    echo "############################################################"
    for f in tc_run_out.log tc_sl_filt.log tc_mqtt_filt.log cmd_outputs.log; do
        echo ""
        echo "############################################################"
        echo "# FILE: <name>_run<n>/$f  ($(wc -l < $RUN/$f) lines, $(wc -c < $RUN/$f) bytes)"
        echo "############################################################"
        cat $RUN/$f
    done
} > $FULL
```

`tcs/<name>/tc_<name>_result.md` 는 4파일 패턴 (`/tc-dev` 스킬 참조) 에 따라 갱신. **인용은 반드시 `evidence_full.log` 에 실제 있는 로그만**.

## 인자별 분기 (`tc10-pre` / `tc10-post`)

```bash
case "$2" in
    tc10-pre)
        # helper 의 tc10pre phase — reboot 발생
        powershell.exe ... -File "$WIN_PS" -Phase tc10pre 2>&1
        # ping 폴링으로 부팅 대기
        until ping -c 1 -W 1 "$DUT_HOST" > /dev/null 2>&1; do sleep 2; done
        sleep 30   # boot 직후 task_capture_boot_log + task_merge_staged_logs 완료 대기
        echo "Run /tc-run <name> tc10-post 다음"
        ;;
    tc10-post)
        # helper transfer 다시 — /tmp 가 ramdisk 라 reboot 후 스크립트 소실
        powershell.exe ... -File "$WIN_PS" -Phase transfer
        powershell.exe ... -File "$WIN_PS" -Phase tc10post 2>&1
        ;;
esac
```

> `/edge/log/<name>/.tc10_before` 같은 영구 파일은 reboot 후에도 살아남아 pre→post 간 상태 전달에 활용 가능.

## 시간 단축 팁

- TC 안의 `sleep 70` → `sleep 30` 으로 줄여도 정상 발화 (system_log 24h timer 의 1초 polling 기준 충분)
- helper 의 chunked 큰 파일 dump 제거 (sl_filt + mqtt_filt 작은 필터 파일로 대체) — corrupt 위험 + 시간 절약
- SETUP `sleep 10` → `sleep 5` 도 안전 (detached thread 의 file 생성은 보통 1초 안)
- base64 chunk 큰 라인 (`-w 32768`) 사용 시 systemd-cat 같은 데이터 주입 30~50배 빠름

## 실패 케이스 핸들링

| 증상 | 원인 | 대처 |
|---|---|---|
| 설정된 포트 "장치를 인식할 수 없습니다" | 좀비 powershell 또는 USB disconnect | `Stop-Process -Name powershell -Force` 후 USB 재연결 |
| "포트를 찾을 수 없습니다" | 다른 COM 번호로 인식됨 | `GetPortNames()` 로 확인, `config.env`의 `SERIAL_COM_PORT` 값 수정 |
| `M_TC09_DONE_END` 매칭 즉시 success | 콘솔에 우리가 보낸 명령이 그대로 echo back되어 marker false-match | `stty -echo` 적용 + `(?m)^M_` 라인 시작 매칭 |
| base64 디코드 일부만 됨 | 시리얼 buffer overrun | 작은 필터 파일로 dump (큰 파일 chunked dump 회피) |
| `/tmp/tc_*.sh` 없음 | reboot 후 ramdisk 휘발 | transfer phase 다시 실행 |
| 시간 +25h shift 후 timer 발화 안 함 | SETUP `task_rotate_sync` 가 `last_run_time` 갱신 가능 | 시간 민감 TC 를 SETUP 이전에 배치 |
