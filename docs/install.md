# 설치 매뉴얼

`tcs_tools`를 신규 PC에 셋업하는 절차. 각 단계마다 목적과 확인 방법을 함께 기술한다.

**용어**
- **DUT**: 테스트 대상 장비 (AC Gen2 EMS 보드)
- **config.env**: PC 환경에 맞는 값(장비 IP, 키 파일 위치 등)을 적는 설정 파일. 레포에 기본값이 포함되어 있으며, 본인 환경이 다르면 직접 수정
- **SSH 키**: 비밀번호 대신 장비 로그인에 사용하는 인증 파일

## 사전 준비

- WSL2, Claude Code 설치
- Python 3 설치 (`python3 --version` 으로 확인)
- 테스트 장비가 연결된 랩 네트워크 접속 가능 (사내망 또는 VPN)

---

## 1단계 — 코드 받기

```bash
git clone https://github.com/HyunjeSung/tcs_tools
cd tcs_tools
```

## 2단계 — 설정 파일 확인

레포에 `config.env`가 이미 포함되어 있다. 시리얼 포트 번호, 계정 경로처럼 사용자마다 다를 수 있는 값이 들어있으므로, 본인 환경과 맞는지 확인 후 다르면 수정한다.

`config.env` 파일을 열어 다음 값을 확인/수정한다.

| 값 | 설명 | 수정 필요 여부 |
|---|---|---|
| `DUT_HOST` | 테스트 장비 IP 주소 | 불필요 — 팀 공용 장비인 경우 기본값 유지 |
| `SERIAL_COM_PORT` | 장비 시리얼 케이블이 연결된 PC의 COM 포트 번호 | 필요 — 아래 방법으로 확인 |
| `SSH_KEY_PATH` | 인증 키를 둘 경로 | 필요 (기본값 사용 가능) |
| `WIN_KEY_PATH` | 원본 인증 키 파일의 Windows 경로 | 필요 — Windows 계정명에 맞게 수정 |
| `WIN_TEMP_LOG_PATH` | 시리얼 통신 로그를 기록할 Windows 경로 | 필요 — 계정명만 수정 |

**COM 포트 번호 확인** — 장비 시리얼 케이블 연결 상태에서 PowerShell에 다음을 입력한다.
```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```
출력된 `COM3`, `COM7` 등의 값을 `SERIAL_COM_PORT`에 기입한다.

## 3단계 — 인증 키 준비

장비는 비밀번호 대신 키 파일로 로그인한다. 원본 키 파일(`emsplus_mass`, 보통 `key/AC_GEN2/emsplus_mass` 경로로 배포됨)은 passphrase(추가 잠금)가 걸려 있어, 자동화에 사용할 잠금 해제 사본을 최초 1회 생성해야 한다.

원본 키 파일과 passphrase는 레포에 포함되어 있지 않으므로 팀으로부터 별도로 전달받아, 파일은 `config.env`의 `WIN_KEY_PATH`에 지정한 경로에 둔다.

```bash
source config.env
cp "$WIN_KEY_PATH" "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
ssh-keygen -p -P '<전달받은 passphrase>' -N '' -f "$SSH_KEY_PATH"
```

- `$WIN_KEY_PATH` — 팀에서 전달받아 이미 갖고 있는 **원본** 키 파일 경로
- `$SSH_KEY_PATH` — 위 `cp` 명령이 **새로 생성**하는, passphrase를 제거해서 쓸 사본 경로

예시 — Windows 계정명이 `jane.doe`, WSL 계정명이 `jane`이라고 가정하면 (이 둘은 서로 다른 별개의 계정이며 이름이 같을 필요 없다), `cp "$WIN_KEY_PATH" "$SSH_KEY_PATH"`는 실제로 아래와 같이 해석된다:
```bash
cp "C:\Users\jane.doe\Desktop\key\AC_GEN2\emsplus_mass" "/home/jane/.ssh/emsplus_mass_nopass"
#  └─────────────── 원본 (WIN_KEY_PATH) ───────────────┘  └──── 새로 생성되는 사본 (SSH_KEY_PATH) ────┘
```

`emsplus_mass_nopass`라는 이름은 "`emsplus_mass` 원본 키에서 passphrase(잠금)를 제거(no-pass)한 사본"이라는 의미다. 자동화 스크립트는 매번 passphrase를 입력할 수 없으므로, 이 잠금 해제 사본을 최초 1회 만들어두고 이후 계속 재사용한다. 원본 `emsplus_mass` 파일은 그대로 둔다.

**확인:**
```bash
source config.env   # 새 터미널 창이면 다시 실행 — 안 하면 $SSH_KEY_PATH, $DUT_HOST 가 빈 값이 됨
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no root@$DUT_HOST 'echo OK'
```
`OK`가 출력되면 정상. 출력되지 않으면 하단 "문제 해결" 표를 참고한다.

## 4단계 — 대시보드 실행

```bash
pip install -r tools/tc_dashboard/requirements.txt
./tools/tc_dashboard/run.sh
```

터미널에 `Uvicorn running on http://0.0.0.0:8090`이 출력되면 정상 실행된 것이다. 브라우저에서 다음 주소를 연다.

```
http://localhost:8090
```

테스트 목록과 실행 버튼이 표시되면 정상.

(터미널에서 확인하는 경우: `curl -s http://localhost:8090/api/ping` 실행 후 `"reachable":true`가 출력되면 장비 연결까지 정상)

## 5단계 — Claude Code 연동 확인 (선택)

Claude Code에서 `tcs_tools` 폴더를 열면 내장된 자동화 스킬이 별도 설정 없이 인식된다. 확인 방법:

```
/tc-run system_log
```

장비로 테스트를 전송하는 과정이 시작되면 정상.

---

## 문제 해결

| 증상 | 원인 | 대처 |
|---|---|---|
| `Identity file  not accessible`, `Could not resolve hostname :` (값이 빈칸으로 나옴) | 현재 터미널에서 `config.env`를 아직 `source` 하지 않아 `$SSH_KEY_PATH`/`$DUT_HOST`가 빈 값임 | 레포 루트에서 `source config.env` 실행 후 재시도. 새 터미널 창을 열 때마다 다시 실행해야 함 |
| `pip install` 실패 | PC의 Python 환경 문제 (레포와 무관) | `python3 -m venv venv && source venv/bin/activate` 로 가상환경 구성 후 재시도 |
| `/api/ping` 이 `false` | 장비 네트워크 미연결 | 사내망/VPN 연결 확인, `config.env`의 `DUT_HOST` 확인 |
| SSH 접속 시 `Permission denied` | 키 파일 경로 오류 또는 권한 미설정 | `chmod 600 "$SSH_KEY_PATH"` 재실행 |
| COM 포트 미인식 | 다른 프로세스가 포트 점유 또는 케이블 문제 | 케이블 재연결, 상세 내용은 [device_ssh.md](device_ssh.md)의 "COM 포트 점유 문제" 참고 |
| Claude Code에서 `/tc-run` 등 스킬 미인식 | `tcs_tools` 폴더가 아닌 다른 위치에서 실행 중 | `.claude` 폴더가 보이는 `tcs_tools` 루트에서 Claude Code 재실행 |

위 항목으로 해결되지 않는 경우, 막힌 단계를 명시하여 팀에 문의한다.
