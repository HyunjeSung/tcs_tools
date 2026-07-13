# tcs_tools

AC Gen2 EMS 장비를 테스트할 때 반복되는 작업 — 스크립트를 장비에 전송하고, 실행하고, 결과 로그를 회수하는 것 — 을 자동화하는 도구 모음이다.

**주요 기능**
- 브라우저에서 테스트 실행 및 결과 확인 (`tools/tc_dashboard`)
- Claude Code를 통한 자연어 명령("TC11 실행해줘")으로 테스트 실행 (`.claude/skills`)

최초 셋업은 아래 "시작하기"를 따른다. 상세 절차는 각 단계의 링크된 문서를 참고.

## 시작하기

**[docs/install.md](docs/install.md) — 설치 매뉴얼**

요약:
```bash
git clone <repo-url> tcs_tools && cd tcs_tools
# config.env 값이 본인 환경과 다르면 수정 (SERIAL_COM_PORT, WIN_KEY_PATH 등)
pip install -r tools/tc_dashboard/requirements.txt
./tools/tc_dashboard/run.sh
```
`http://localhost:8090` 접속 시 대시보드가 표시되면 정상.

## 폴더 구조

| 폴더 | 내용 |
|---|---|
| `tcs/` | 테스트 항목(스펙), 실행 스크립트, 실행 결과 |
| `tools/tc_dashboard/` | 브라우저 기반 테스트 실행/확인 도구 |
| `tools/serial/` | 장비 시리얼(COM 포트) 통신 스크립트 |
| `docs/` | 설치, 장비 접속, TC 판정 근거 대조 관련 문서 |
| `.claude/` | Claude Code가 인식하는 자동화 스킬 |

## 관련 문서

- 설치 매뉴얼(단계별 절차/확인법/문제 해결): [docs/install.md](docs/install.md)
- 장비 접속 정보(SSH/시리얼) 및 트러블슈팅: [docs/device_ssh.md](docs/device_ssh.md)
- TC 판정 근거 대조 방법론(spec/리눅스 명령/journald): [docs/evidence_verification.md](docs/evidence_verification.md)
- TC 작성/실행 규칙(개발자용): [CLAUDE.md](CLAUDE.md)
