# 설치 매뉴얼

`tcs_tools`를 새 PC에 처음 셋업하는 절차. 각 단계마다 확인 명령을 포함한다.

## 0. 사전 요구사항

| 항목 | 확인 방법 |
|---|---|
| WSL2 | `wsl.exe -l -v` (Windows 쪽에서) |
| Python 3 | `python3 --version` |
| Claude Code | `claude --version` |
| DUT 네트워크 접근 | 랩 네트워크에 연결되어 있을 것 (VPN 등) |

## 1. Clone

```bash
git clone <repo-url> tcs_tools
cd tcs_tools
```

## 2. `config.env` 준비

```bash
cp config.env.example config.env
```

`config.env`를 열어 아래 값을 본인 환경에 맞게 수정한다.

| 변수 | 설명 | 보통 그대로 두는지 |
|---|---|---|
| `DUT_HOST` | DUT IP | 예 — 랩 공용 리소스라 팀 전체 동일 |
| `SSH_KEY_PATH` | SSH 키(passphrase 제거 사본)를 둘 WSL 경로 | 아니오 — 본인이 정한 경로로 |
| `SERIAL_COM_PORT` | DUT 시리얼이 잡히는 Windows COM 포트 | 아니오 — PC마다 다름, 3단계에서 확인 |
| `WIN_KEY_PATH` | passphrase 걸린 원본 키의 Windows 경로 | 아니오 — 본인 계정 경로로 |
| `WIN_TEMP_LOG_PATH` | 시리얼 콘솔 로그를 쓸 Windows 임시 경로 | 아니오 — 본인 계정 경로로 (사용자명만 바꾸면 됨) |

**COM 포트 확인:**
```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```
DUT 시리얼 어댑터가 연결된 상태에서 나온 `COM<n>` 값을 `SERIAL_COM_PORT`에 적는다.

## 3. SSH 키 준비

원본 키(`WIN_KEY_PATH`)는 passphrase가 걸려 있어 자동화에 바로 쓸 수 없다. **passphrase는 팀 내부 채널(사내 메신저 등)로 별도 전달받는다** — 레포/문서 어디에도 평문으로 남기지 않는다.

```bash
source config.env
cp "$WIN_KEY_PATH" "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
ssh-keygen -p -P '<전달받은 passphrase>' -N '' -f "$SSH_KEY_PATH"
```

**확인:**
```bash
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no root@$DUT_HOST 'echo OK'
# OK 출력되면 성공
```

자세한 트러블슈팅(시리얼 COM 점유, host key 변경 등)은 [device_ssh.md](device_ssh.md) 참고.

## 4. 대시보드 설치 + 실행

```bash
pip install -r tools/tc_dashboard/requirements.txt
./tools/tc_dashboard/run.sh
```

**확인:**
```bash
curl -s http://localhost:8090/api/tcs | head -c 100     # TC 카탈로그 JSON 나오면 성공
curl -s http://localhost:8090/api/ping                  # {"reachable":true,...} 나오면 DUT 연결 성공
```
브라우저로 `http://localhost:8090` 접속해서 UI 확인.

## 5. Claude Code 연동 확인

`tcs_tools` 폴더에서 Claude Code를 열고 아래 중 하나로 스킬이 인식되는지 확인:

```
/tc-run system_log
```

`tcs/system_log/tc_system_log.sh`를 DUT로 전송해 실행하는 흐름이 시작되면 정상. `.claude/skills/`와 `.claude/agents/tc-plan.md`가 프로젝트 스코프로 자동 로드되어 별도 등록 없이 바로 잡힌다.

## 트러블슈팅

| 증상 | 원인 | 대처 |
|---|---|---|
| `pip install` 실패 | 시스템 Python/pip 환경이 깨져 있음 (배포 무관, PC별 이슈) | `python3 -m venv venv && source venv/bin/activate` 후 재시도 |
| `/api/ping` 이 `false` | DUT 네트워크 미접속 또는 `DUT_HOST` 오타 | VPN/네트워크 확인, `config.env`의 `DUT_HOST` 재확인 |
| SSH `Permission denied` | 키 경로 오타 또는 chmod 안 함 | `chmod 600 "$SSH_KEY_PATH"` 확인 |
| COM 포트 인식 안 됨 | 다른 프로세스 점유 또는 USB 재연결 필요 | [device_ssh.md](device_ssh.md)의 "COM 포트 점유 문제" 참고 |
| Claude Code에서 `/tc-run` 등 스킬이 안 잡힘 | `tcs_tools` 폴더 자체를 프로젝트 루트로 안 열었음 | `.claude/`가 보이는 위치(레포 루트)에서 Claude Code 실행 |
