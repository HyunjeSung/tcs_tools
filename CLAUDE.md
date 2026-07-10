# tcs_tools — AC Gen2 EMS TC 자동화

## 디바이스 접속

DUT 접속 정보(SSH/시리얼)와 자동화 도구 위치는 [docs/device_ssh.md](docs/device_ssh.md) 참고. 실행 전 `config.env` 준비 필요 (`cp config.env.example config.env` 후 값 수정) — 자세한 건 [README.md](README.md) 참고.

## TC 작업 패턴

- 명세 (`*.md`): 사전 조건 + 절차 + 기대 결과 + PASS/FAIL Criteria 구조. "근거 코드" 인용은 두지 않음.
- 스크립트 (`*.sh`): bash + busybox 호환. 마커는 `(?m)^M_...` 라인 시작 매칭 가능하도록 작성.
- 결과 (`*_result.md`): evidence 단일 파일 `*_evidence_full.log` 의 `# FILE: <name>` 섹션을 인용.
- 디렉토리 분산 없이 evidence 는 통합 단일 `*_evidence_full.log` 한 파일에 모은다.

## 사용 가능한 스킬/에이전트

이 레포를 Claude Code로 열면 다음이 자동 인식된다:
- `/tc-bootstrap <app>` — 새 TC 4파일 골격 생성
- `/tc-dev <app>` — 명세 기반 스크립트 작성
- `/tc-run <app>` — 시리얼/SSH로 DUT 실행 + evidence 수집
- `/tc-harness <app>` — 위 사이클 전체를 한 번에 진행하는 dispatcher
- `tc-plan` 에이전트 — 요구사항 문서 + 소스코드 기반 TC 명세 초안 생성
