# tcs_tools

AC Gen2 EMS 디바이스용 TC(Test Case) 자동화 도구 모음 — TC 스펙/스크립트, 실행용 웹 대시보드, Claude Code 스킬을 묶어서 배포한다.

## 구성

```
tcs/                    # TC 스펙(.md) + 실행 스크립트(.sh) + 결과(.md) + evidence(.log)
tools/tc_dashboard/      # 브라우저에서 TC 실행/현황을 보는 FastAPI 대시보드
tools/serial/            # 시리얼(COM) 자동화 PowerShell 스크립트
docs/device_ssh.md        # DUT SSH/시리얼 접속 정보 + 트러블슈팅
.claude/skills/            # tc-bootstrap / tc-dev / tc-harness / tc-run
.claude/agents/             # tc-plan
```

## 셋업

빠른 요약:

```bash
git clone <repo-url> tcs_tools && cd tcs_tools
cp config.env.example config.env   # 값 수정 필요
pip install -r tools/tc_dashboard/requirements.txt
./tools/tc_dashboard/run.sh
```

각 단계별 상세 절차 + 확인 명령 + 트러블슈팅은 **[docs/install.md](docs/install.md)** 참고 (처음 셋업하는 사람은 이 문서를 따라갈 것).

## 참고

- 설치 매뉴얼: [docs/install.md](docs/install.md)
- TC 작성/실행 컨벤션: [CLAUDE.md](CLAUDE.md)
- DUT 접속/시리얼 트러블슈팅: [docs/device_ssh.md](docs/device_ssh.md)
