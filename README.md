# tcs_tools

AC Gen2 EMS 장비를 테스트할 때 반복되는 작업 — 스크립트를 장비에 전송하고, 실행하고, 결과 로그를 회수하는 것 — 을 자동화하는 도구 모음이다.

**주요 기능**
- 브라우저에서 테스트 실행 및 결과 확인 (`tools/tc_dashboard`) — 앱(system_log, device_log 등) 10종, DUT 2대(기본/테스트)를 서로 독립적으로 동시 실행 가능
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
`http://localhost:8090` 접속 시 대시보드가 표시되면 정상. 화면 사용법은 [docs/dashboard_guide.md](docs/dashboard_guide.md) 참고.

## 폴더 구조

| 폴더 | 내용 |
|---|---|
| `tcs/<app>/` | 앱별 TC 4종 세트 — 명세(`tc_<app>.md`), 실행 스크립트(`tc_<app>.sh`), evidence 로그, 결과 보고서(`tc_<app>_result.md`). 현재 system_log/device_log/update_monitor/sys_manager/db_manager/device_manager/azure_connector/edge_runtime/web_interface/energy_monitor 10개 앱 |
| `tools/tc_dashboard/` | 브라우저 기반 테스트 실행/확인 도구(FastAPI + 단일 HTML) — 동작 원리는 [docs/dashboard_architecture.md](docs/dashboard_architecture.md) |
| `tools/serial/` | 장비 시리얼(COM 포트) 통신 스크립트 |
| `docs/` | 설치, 대시보드 사용법/아키텍처, 장비 접속, TC 판정 근거 대조, 앱별 요구사항(`tc_requirements/`) 문서 |
| `.claude/skills/` | Claude Code가 인식하는 자동화 스킬 — `tc-bootstrap`(TC 4파일 골격 생성), `tc-dev`(TC 명세/스크립트 작성), `tc-harness`(골격→명세→실행→결과 전체 사이클), `tc-run`(디바이스에 실제 실행), `tc-dashboard`(대시보드 서버 개발 레퍼런스) |

## 관련 문서

- 설치 매뉴얼(단계별 절차/확인법/문제 해결): [docs/install.md](docs/install.md)
- 대시보드 사용법(버튼별 동작, 실시간 로그, 결과 다운로드): [docs/dashboard_guide.md](docs/dashboard_guide.md)
- 대시보드 아키텍처(앱 등록/실행 흐름/DUT별 동시성 모델/결과 처리, 다이어그램 포함): [docs/dashboard_architecture.md](docs/dashboard_architecture.md)
- 장비 접속 정보(SSH/시리얼) 및 트러블슈팅: [docs/device_ssh.md](docs/device_ssh.md)
- TC 판정 근거 대조 방법론(spec/리눅스 명령/journald): [docs/evidence_verification.md](docs/evidence_verification.md)
- 앱별 TC 명세(사전조건/절차/PASS·FAIL Criteria): `tcs/<app>/tc_<app>.md` (예: [tcs/system_log/tc_system_log.md](tcs/system_log/tc_system_log.md), [tcs/device_log/tc_device_log.md](tcs/device_log/tc_device_log.md))
- TC 명세 작성 전 요구사항 정리: `docs/tc_requirements/<app>.md`
