# AC Gen2 디바이스 접속 정보 (SSH + 시리얼)

레포 루트에 `config.env`가 포함되어 있다. `DUT_HOST`, `SSH_KEY_PATH`, `SERIAL_COM_PORT`, `WIN_KEY_PATH`, `WIN_TEMP_LOG_PATH` 값이 본인 환경과 다르면 먼저 수정한 뒤 아래를 실행한다:

```bash
source config.env
```

## SSH 접속

- **Host**: config.env의 `DUT_HOST`
- **User**: root
- **Port**: 22
- **Key 파일**: config.env의 `SSH_KEY_PATH` (passphrase 제거된 사본, 아래 참조)

```bash
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -p 22 root@$DUT_HOST
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -P 22 <local> root@$DUT_HOST:<remote>
```

### SSH 키 사본 만들기 (최초 1회)

원본 키(`emsplus_mass`, 보통 `key/AC_GEN2/emsplus_mass` 경로로 배포됨, config.env의 `WIN_KEY_PATH`)는 passphrase가 걸려 있어 자동화에 그대로 쓸 수 없다. 원본 키 파일과 passphrase는 팀으로부터 별도로 전달받아 다음으로 사본을 만든다 (원본은 건드리지 않음):

```bash
cp "$WIN_KEY_PATH" "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
ssh-keygen -p -P '<전달받은 passphrase>' -N '' -f "$SSH_KEY_PATH"
```

### 리부트 후 host key 변경 시

```bash
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$DUT_HOST"
```

---

## 시리얼 콘솔

- **포트**: config.env의 `SERIAL_COM_PORT`
- **설정**: 115200 bps, 8N1, flow control none
- **로그인**: username `root` 입력 후 **패스워드 없이 바로 shell prompt** (`root@qcells-emsplus:~#`) 진입
- **장점**: reboot 중에도 콘솔 세션 유지됨 → TC10-pre/post 같은 reboot 시나리오를 한 세션에서 캡처 가능
- **노이즈**: docker-loader/iptables/audit 메시지가 console로 흘러나옴

### WSL2 한계와 우회

`/dev/ttyS*` 는 WSL2 에서 Windows COM 포트와 자동 매핑되지 않는다 (WSL1 에서만 가능).
**WSL bash 에서 시리얼 자동화는 `powershell.exe` 로 `[System.IO.Ports.SerialPort]($SERIAL_COM_PORT, 115200, 'None', 8, 'One')` 을 호출해서 처리**.

### 시리얼 helper 스크립트

레포에 포함되어 있음:
- `tools/serial/serial_helper.ps1` — `-Phase` 인자로 단계 분기 (`login_test` / `transfer` / `run_main` / `fetch_only` / `tc10pre` / `tc10post`), `-ComPort`/`-LogFile` 파라미터로 config.env 값 전달 가능
- `tools/serial/serial_get_runout.ps1` — `/tmp/tc_run.out` 단순 fetch (chunked dump 외 빠른 결과 회수용)

호출 예:
```bash
WIN_PS=$(wslpath -w tools/serial/serial_helper.ps1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -Phase transfer -ComPort "$SERIAL_COM_PORT" -LogFile "$WIN_TEMP_LOG_PATH"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS" -Phase run_main -ComPort "$SERIAL_COM_PORT" -LogFile "$WIN_TEMP_LOG_PATH"
```

### 시리얼 helper 의 핵심 패턴

1. **노이즈 차단**: `dmesg -n 1` (kernel msg 콘솔 출력 차단) + `stty -echo` (입력 echo 차단) + `export PS1="P> "` (prompt 단순화)
2. **marker 매칭**: `(?m)^MARKER` regex 로 라인 시작에 marker 가 있을 때만 매치 — 우리가 보낸 명령에 포함된 marker 가 false-match 하는 것 방지
3. **스크립트 transfer**: base64 chunked (chunk 512자, sleep 110ms) → 디바이스에서 `base64 -d` → md5sum 검증
4. **파일 dump**: 작은 파일은 `base64 -w 76` 한 번에, 큰 파일은 chunk 16K 로 split → for loop 으로 base64 dump
5. **시리얼 노이즈 corrupt 회피**: 큰 chunked dump (수백 KB+) 는 buffer overrun 으로 일부 손실 가능 — 가능하면 디바이스에서 `fgrep` 으로 필요한 라인만 추출 후 작은 파일로 dump

### COM 포트 점유 문제 발생 시

- Windows 측 PuTTY/TeraTerm 종료 후 다시 시도
- 그래도 안 되면 `Stop-Process -Name powershell -Force` 로 좀비 powershell 종료
- USB Serial 어댑터 disconnect → 재연결 (인식 안 되면 WSL 재시작 또는 장치 관리자 reset)
- `[System.IO.Ports.SerialPort]::GetPortNames()` 로 현재 COM 포트 목록 확인

### TC04 같은 장시간 작업 시 helper 의 `WaitFor` timeout 조정 필요 (기본 240s)

### TC02 후 NTP 자동 복원이 실패함

TC02 가 시스템 시간을 +25h 이동시킨 후 `timedatectl set-ntp true` 로 복원을 시도하지만,
read-only rootfs 에 의해 `Failed to set ntp: File /etc/systemd/system/dbus-org.freedesktop.timesync1.service: Read-only file system` 으로 실패.

수동 복원:
```bash
ssh -i "$SSH_KEY_PATH" root@$DUT_HOST 'systemctl start chronyd 2>/dev/null; systemctl start systemd-timesyncd 2>/dev/null'
```

TC10 (reboot 시나리오) 들어가기 전, 또는 시험 종료 후 시계 확인용으로 매번 호출 필요.

### USB-Serial 어댑터 enumeration 실패

USB-C 전용 노트북 + USB-A 시리얼 어댑터 + 변환기 구성에서 간헐적으로 enumeration 실패
(`VID 0000 PID 0002` = 장치 설명자 요청 실패)가 발생할 수 있다. 대부분 어댑터 커넥터
접촉 불량 또는 칩(PL2303) 일시적 stuck 이 원인 — 다른 어댑터/케이블로 교체하면 해결됨.

진단 명령:
```powershell
Get-PnpDevice -Class Ports -PresentOnly
[System.IO.Ports.SerialPort]::GetPortNames()
Get-PnpDevice | Where-Object { $_.Status -eq 'Error' -and $_.InstanceId -match 'USB' }
```

---

## 디바이스 사양 메모

- aarch64, Linux 6.6.114.1
- 디스크: `/dev/root` 2.1 GB (가용 1.6 GB), `/edge/log` 별도 마운트 (대부분 비어있음)
- journal: `/var/log/journal/`, 보통 `journalctl --disk-usage` 결과 ~8 MB 안정
- `/tmp`: ramdisk → reboot 시 모든 파일 소실 → 스크립트 transfer 는 매 reboot 후 다시 필요
- `/edge/log/system/.tc10_before` 같은 임시 파일은 `/edge/log/` 가 영구 저장소라 reboot 후에도 살아남음
