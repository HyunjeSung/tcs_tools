---
name: tc-harness
description: AC Gen2 EMS 애플리케이션의 Spec 기반 TC 자동화 전체 사이클 dispatcher. `/tc-harness <app>` 한 명령으로 골격→명세→실행→결과까지 자동 진행하며, 사용자 input 필요한 지점 (spec 작성, 코드 수정 결정) 에서만 멈춘다. 새 app 의 TC 개발 시작, TC 사이클 재진입 시 사용. "하네스", "TC 자동화", "TC 시작", "TC 사이클" 같은 키워드에서 활성화.
version: 1.2.0
---

# AC Gen2 EMS TC Harness — Dispatcher + 6단계 매뉴얼

이 스킬은 두 가지 역할:
1. **Dispatcher** — `/tc-harness <app>` 또는 자연어 한 줄로 호출되면, 현재 상태를 보고 다음 단계 (bootstrap / dev / run / result) 를 자동 결정해 진행
2. **매뉴얼** — 6단계 절차 + 분기 조건 + 재사용 자산 위치를 상세 기재

---

## Dispatcher 동작 (호출 시 AI 가 따라야 할 흐름)

```
/tc-harness <app>  또는  "device_log TC 시작해줘"
```

1. **현재 상태 점검** — `tcs/<app>/tc_<app>.{md, sh, _result.md, _evidence_full.log}` 4 파일 존재 여부 확인.
2. **단계 결정 + 자동 실행:**
   ```
   ┌─ 4파일 없음                  → /tc-bootstrap <app> 호출 (골격 생성)
   │                                → 사용자에게 "요구사항 문서 있나요?" 질문 (STOP)
   │                                  ├─ 있음 (경로/내용 전달)
   │                                  │        → tc-plan agent spawn (요구사항 + 소스코드)
   │                                  │        → tc_<app>.md 초안 자동 작성 + 근거 매핑 표
   │                                  │        → 사용자에게 검토 요청 후 STOP
   │                                  │
   │                                  ├─ 없음 (code-only 선택)
   │                                  │        → tc-plan agent spawn (소스코드만, 경고 출력)
   │                                  │        → tc_<app>.md 초안 (Medium 신뢰도)
   │                                  │        → 사용자에게 검토 요청 후 STOP
   │                                  │
   │                                  └─ 사용자가 직접 작성 (agent 호출 안 함)
   │                                           → 사용자에게 spec 작성 요청 후 STOP
   │
   ├─ md 의 spec 본문 미완 (TODO 가득)  → 사용자에게 spec 채워달라 요청 후 STOP
   │                                       (또는 tc-plan agent 재호출 제안)
   │
   ├─ md 완성 / sh placeholder      → /tc-dev <app> 호출 (명세→스크립트)
   │                                → 자동 다음 단계로
   │
   ├─ sh 작성됨 / evidence 비어있음 → /tc-run <app> 호출 (DUT 실행)
   │                                → 자동 다음 단계로
   │
   ├─ evidence 채워짐 / result.md 미작성 → result.md 작성 (raw 근거 인용)
   │                                       → 사용자에게 검토 요청 후 STOP
   │
   └─ 사용자 Feedback 수신          → 분기:
                                       a. TC/Script 보정 → 명세/sh 수정 후 /tc-run 재실행
                                       b. App 결함     → 사용자에게 코드 수정 + 빌드 안내 후 STOP
                                                          → 빌드 완료 신호 받으면 /tc-run 재실행
                                       c. 모든 PASS     → 종료 선언
   ```
3. **STOP 지점:** 사용자 input 이 필요한 곳에서만 멈춤. 그 외는 단계 사이를 사용자 추가 명령 없이 자동 진행.

### 호출 형태

| 형태 | 의미 |
|---|---|
| `/tc-harness <app>` | 위 dispatcher 동작 |
| `"<app> TC 시작해줘"` 같은 자연어 | 동일 (AI 가 이 스킬을 매칭) |
| `/tc-harness` (인자 없음) | 매뉴얼만 표시 |

---

# 6단계 절차 매뉴얼

`tcs/<app>/` 의 4파일 패턴 (`tc_<app>.md`, `tc_<app>.sh`, `tc_<app>_result.md`, `tc_<app>_evidence_full.log`) 을 시작/실행/결과 정리/피드백 환류/코드 수정/종료 까지 전체 사이클로 운영하는 harness 매뉴얼.

```
   1. Test Case ──→ 2. Test Script ──→ 3. Test Log ──→ 4. Test Result
       (개발자)        (AI)               (AI)            (AI 작성/개발자 검토)
                                                              │
                                                       Feedback 분기
       ┌──────────────────────────────────┬───────────────────┤
       ↓ TC/Script 보정                    │ App 결함          │ 모든 PASS
       └→ step 1                           ↓                   ↓
                                     5. Code Fix        6. PASS (시험 완료)
                                  (개발자 + AI 보조)  (AI 집계 / 개발자 최종 승인)
                                           │
                                           └─→ step 1
```

| 단계 | 주체 | 산출물 |
|---|---|---|
| 1. Test Case | 개발자 (요구사항 전달 + 초안 검토/수정) + AI Agent (`/tc-bootstrap` 골격, **`tc-plan` agent 초안 작성**, `/tc-dev` 명세 정련) | `tcs/<app>/tc_<app>.md` |
| 2. Test Script | AI Agent (`/tc-dev`) | `tcs/<app>/tc_<app>.sh` |
| 3. Test Log | AI Agent (`/tc-run <app>`) | `tcs/<app>/tc_<app>_evidence_full.log` |
| 4. Test Result | AI Agent (보고서 작성) / 개발자 (검토 + Feedback) | `tcs/<app>/tc_<app>_result.md` |
| 5. Code Fix | 개발자 (주도 수정) + AI Agent (분석/패치 보조) | application 소스 변경 (`qcells/uniep/core/application/...`) |
| 6. PASS | AI Agent (집계) / 개발자 (최종 승인) | result.md 의 합계 표 + 종료 선언 |

---

## 사용 방법

### 새 application 의 TC 시작 (예: `device_log`)

```bash
# 1. 골격 생성 — 4파일 보일러플레이트
/tc-bootstrap device_log

# 1.5. (신규) tc-plan agent 로 초안 생성
#      요구사항 문서 있으면 함께 전달 → 요구사항 + 소스코드 기반 초안
#      요구사항 없으면 code-only 모드 (경고 출력)
#      → tc_device_log.md 에 초안 + 근거 매핑 표 자동 작성
#      → 사용자는 Flag 항목부터 검토/수정

# 2. spec 보완 — 사용자가 tc-plan 초안을 검토/수정 (tc_device_log.md)
#    AI Agent 가 spec 을 읽어 TC 절차 / PASS-FAIL Criteria / sh assert 채움
/tc-dev device_log

# 3. 디바이스에서 실행 + evidence 수집
/tc-run device_log

# 4. 결과 보고서 raw 근거 인용으로 작성
#    (현재는 manual; 추후 /tc-result-gen 으로 자동화 예정)

# 5. 개발자 검토 → Feedback 분기
#    a. TC/Script 보정 필요 → 1번 또는 2번으로 환류 ("TC02-1 판정 기준 완화해" 같은 한 줄 지시)
#    b. App 결함 → 5번 (Code Fix) → 1번으로 환류
#    c. 모든 PASS → 6번 (종료)
```

### 기존 application 의 사이클 재진입

```bash
# Feedback 반영 후 재시험
/tc-run <app>            # 메인 TC 풀 (기본)
/tc-run <app> tc10-pre   # reboot 시나리오 pre
/tc-run <app> tc10-post  # reboot 시나리오 post
/tc-run <app> --tc<N>    # 단일 TC 분리 실행
```

---

## 재사용 가능한 자산

| 자산 | 위치 | 용도 |
|---|---|---|
| **tc-bootstrap 스킬** | `.claude/skills/tc-bootstrap/SKILL.md` | 새 app 의 4파일 골격 생성 |
| **tc-plan 에이전트** | `.claude/agents/tc-plan.md` | 요구사항(primary) + 소스코드(보완) 으로 TC 명세 초안 생성 + 근거 매핑 표 |
| **tc-dev 스킬** | `.claude/skills/tc-dev/SKILL.md` | TC 명세/스크립트 작성 패턴 |
| **tc-run 스킬** | `.claude/skills/tc-run/SKILL.md` | 시리얼/SSH 실행 + evidence 수집 |
| **시리얼 helper** | `tools/serial/serial_helper.ps1` | config.env의 SERIAL_COM_PORT phase 분기 (login/transfer/run_main/tc10pre/tc10post) |
| **SSH 키 사본** | config.env의 SSH_KEY_PATH (passphrase 제거) | 시리얼 disconnect 시 SSH fallback |
| **send_and_wait() bash 함수** | 각 `tc_<app>.sh` 안 (보일러플레이트) | MQTT req/res 패턴 |
| **evidence SECTION 구조** | `tcs/<app>_evidence_full.log` | S1~3 (stdout) + S4 (post_info) + S6 (raw) |

---

## 4파일 패턴 (요약)

```
tcs/
├── system_log/
│   ├── tc_system_log.md                  # Test Case 명세 (개발자 작성)
│   ├── tc_system_log.sh                  # 실행 스크립트 (AI 작성)
│   ├── tc_system_log_result.md           # 결과 보고서 (AI 작성, 개발자 검토)
│   └── tc_system_log_evidence_full.log   # 통합 evidence (AI 수집)
├── device_log/
│   └── ...  (동일 구조)
└── <new_app>/
    └── ...
```

자세한 4파일 구조는 [tc-dev SKILL](../tc-dev/SKILL.md) 참조.

---

## 환경 / 사전 조건

| 항목 | 값 |
|---|---|
| **DUT** | config.env의 DUT_HOST (AC Gen2, aarch64) |
| **시리얼** | config.env의 SERIAL_COM_PORT, 115200 8N1, root 자동 로그인 |
| **SSH** | `root@<DUT_HOST>`, key config.env의 SSH_KEY_PATH |
| **MQTT** | localhost:1883 (DUT 내) |
| **toupload** | `/edge/log/toupload/<app>/` |
| **journal** | `journalctl -u docker-loader` |

자세한 접속 정보는 `docs/device_ssh.md` 참조.

---

## step 별 상세

### step 1 — Test Case (개발자 + tc-plan agent)

- **0순위 (신규)**: `tc-plan` agent 에게 요구사항 문서 + 소스코드 위치 전달 → 초안 + 근거 매핑 표 자동 생성
  - 요구사항 문서 있음 → 양쪽 cross-check (High / Medium / Flag 신뢰도 표시)
  - 요구사항 문서 없음 → code-only fallback (경고 + Medium 이하 신뢰도)
- 개발자는 초안 중 **Flag 항목부터** 검토 → 메인 AI 에게 "TCxx 절차에서 Y 추가/제거" 한 줄로 수정 지시
- spec_id, suite, grade, phase, test_file 등 frontmatter 작성
- TC 별 4 단 구조: 목적 / 사전 조건 / 절차 / PASS/FAIL Criteria
- 같은 함수의 서로 다른 산출물은 **별도 TC ID 로 분리** (예: TC11-2 `.nmon` 증가 vs TC11-5 `.nmon.meta` 증가). `||` 로 묶지 말 것.

### step 2 — Test Script (AI Agent)

- bash + busybox 호환
- `send_and_wait()` 함수 (subscribe → publish → wait) 보일러플레이트 사용
- `assert()` 함수로 PASS/FAIL 카운트
- 마커 `M_...` 는 라인 시작 매칭 (`(?m)^M_`)
- 사전 격리는 최소화 — `nmon/old` 같은 trigger 입력 디렉토리만 정리하고 검증 대상 (toupload 등) 은 환경 그대로 둠
- 응답 코드 검증은 robust 하게: `(0|"NONE")` 두 형식 모두 인정

### step 3 — Test Log (AI Agent)

- `/tc-run <app>` 호출 → tc-run 스킬이 phase 분기 자동화
- 설정된 시리얼 포트(config.env의 SERIAL_COM_PORT) 미인식 시 **자동 SSH fallback** (개발자 개입 없음, 추후 구현 예정 — 현재는 수동 분기)
- reboot 시나리오 (`--tc10-pre` / `--tc10-post`) 는 별도 phase

### step 4 — Test Result (AI Agent + 개발자)

- `<app>_result.md` 의 각 TC 섹션은 **`TCxx-N 근거 —`** 라벨로 raw 인용 (스크립트 stdout 의 `[PASS]/[FAIL]` 만 인용하지 말고 `[SL]` 로그 / `ls -la` / `xz --test` / `journalctl --disk-usage` / `[IPC pub res]` 등 raw 명령 결과 위주)
- evidence_full.log 의 SECTION 별로 인용 위치 명시 (`SECTION 6 (ls -la ...)`)
- 한계 명시: "시험 종료 후 ls 만으로는 검증 시점 상태가 보존되지 않음" 같은 caveat

### step 5 — Code Fix (개발자 + AI)

- 개발자가 우선순위 판단 → AI 가 패치 제안 / 직접 수정
- application 소스 위치: `qcells/uniep/core/application/<app>/`
- 빌드/배포 후 step 1 로 환류 (TC 자체도 변경된 코드 기준으로 재검토)

### step 6 — PASS (AI + 개발자)

- AI: PASS/FAIL 집계 + result.md 합계 표 + evidence 완결성 점검
- 잔존 FAIL 의 허용 여부 (알려진 제약 vs 진짜 결함) 는 **개발자 판단**
- 종료 선언 또는 step 4 재진입

---

## 알려진 제약 패턴 (다음 app 도 비슷하면 같은 진단)

| 증상 | 원인 | 환류 단계 |
|---|---|---|
| `error_code=UNKNOWN`, `message=CMD_SH timed out after 5s` | `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=5s` 가 너무 짧음 | step 5 (앱 코드 매크로 조정) |
| 같은 이름 더미 overwrite 로 `xfer_new=0` | `fs::rename` 의 overwrite 동작 | step 1 (TC 더미 이름을 `<epoch>` suffix 로 unique 하게) |
| `[잔존]` 출력만 보고 `.nmon` / `.meta` 둘 중 어느 게 남았는지 구분 안 됨 | 검증 코드가 `||` 로 묶임 | step 1 (TC 기준 ID 분리) |
| 시리얼 포트 disconnect | USB 어댑터 dropping 또는 Windows 측 점유 | tc-run 안의 SSH fallback 분기 (자동) |

---

## 다음 application 시작 시 예상 소요 시간

| 작업 | 소요 |
|---|---|
| spec 작성 (개발자) | 1~2시간 |
| `/tc-bootstrap` + AI 가 spec 읽어 명세/스크립트 채움 | 10~20분 |
| `/tc-run` 1차 실행 + evidence 수집 | 5~10분 |
| result.md 작성 + raw 근거 인용 | 30분~1시간 |
| 피드백 사이클 (보정 1~3회) | 회당 5~10분 |
| **총 (spec 제외)** | **약 1~2시간** |
