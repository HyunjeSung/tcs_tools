---
spec_id: device_log
suite: application
grade: A
phase: Phase 1
test_file: tcs/tc_device_log.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-DL: device_log — <한 줄 설명, 예: 디바이스 fault log 수집·압축·업로드 검증>

## 목적 (Objective)

<TODO: device_log 애플리케이션의 주요 책임을 1~2 문단으로 기술. 예시 — fault log 수집, custom_upload_info 처리, cloud upload 등>

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `device_log` 프로세스 실행 중 (`pgrep -f device_log`)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨
- `/edge/log/` 파티션 쓰기 가능

---

## TC01 — <한 줄 요약>

### 목적

<TODO>

### 사전 조건

- 공통 전제 조건 충족
- <TODO>

### 절차

1. <TODO>
2. <TODO>

### 기대 결과

| 항목 | 기준 |
|------|------|
| <TODO> | <TODO> |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | <TODO> | boolean | true | `<TODO>` |

---

<!--
추가 TC 는 위와 동일 구조로 TC02, TC03, ... 으로 작성.

같은 함수의 서로 다른 산출물은 별도 TC ID 로 분리하기 (예: .log / .meta 분리).
`||` 로 묶지 말 것.
-->

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `device_log` | MQTT 수신 대상 앱 ID |
| `TOUPLOAD_DIR` | `/edge/log/toupload/device` | toupload 경로 (필요 시 수정) |

---

## 디렉토리 구조 참고

```
/edge/log/
├── device/                       ← STAGING_DIR (예시 — 실제 경로 확인 필요)
└── toupload/
    └── device/                   ← TOUPLOAD_DIR
```

<TODO: device_log 의 실제 디렉토리 구조를 코드/CLAUDE.md 에서 확인 후 갱신>

---

## 자동화 등급 (Automation Grade)

🟢 **A** (예상; 시험 추가에 따라 B 로 하향 가능)

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | A | 무인 실행 가능 |

---

## 관련 문서

- `tc_device_log_result.md` — 본 TC 실행 결과 보고서
- `tc_device_log_evidence_full.log` — 결과의 근거가 되는 통합 로그
