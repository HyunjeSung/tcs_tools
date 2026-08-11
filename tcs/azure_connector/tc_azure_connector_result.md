# TC 실행 결과 보고서 — azure_connector

**최초 실행:** 2026-08-11 13:18 ~ 13:27 KST (1회차)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `a440c0a2778777ff95ea7be4ac92ebec`
**실행 환경:** SSH (COM7 시리얼 미인식으로 fallback)
**총 결과:** **PASS=5 / FAIL=27**
**Evidence:** `tcs/azure_connector/tc_azure_connector_evidence_full.log`

> ⚠️ **DUT 상태 변경 주의(사용자 확인 필요)**: 이번 실행으로 이 DUT의
> `edge_device_id`가 테스트용 값(`TC_AZ02_1786421906`)으로 남았고,
> `/edge/sp/secrets/dp/` 인증서 디렉토리가 비어 있는 상태가 됐다. 아래 "핵심 이슈 1"
> 참고 — 원인 분석상 이 DUT는 애초에 Azure로 실제 프로비저닝된 적이 없는(개발용,
> `edge_device_id not ready`) 상태였을 가능성이 높지만, 100% 확신할 수 없어 우선
> 보고한다.

| TC | 결과 |
|---|---|
| TC01 | SKIP (스텁) |
| TC02-1/2 | PASS/PASS |
| TC02-3/4 | FAIL |
| TC03 (4개) | FAIL×4 (사전조건 자체가 이미 불충족 — 아래 참고) |
| TC04 (3개) | FAIL×3 (사전조건 자체가 이미 불충족) |
| TC05 | SKIP (스텁) |
| TC06-1 | FAIL |
| TC06-2 | PASS |
| TC06-3 | FAIL |
| TC07 (3개) | FAIL×3 |
| TC08-1 | FAIL |
| TC08-2 | PASS (단, 아래 "핵심 이슈 3" 참고 — 오탐 의심) |
| TC08-3 | FAIL |
| TC09 (2개) | FAIL×2 |
| TC10 (6개) | FAIL×6 |
| TC11-1/2 | FAIL/FAIL |
| TC11-3 | PASS (단, 아래 "핵심 이슈 3" 참고 — 오탐 의심) |
| TC11-4 | FAIL |

---

## 시험 과정에서 발견된 핵심 이슈

### 1. (중요, DUT 상태 영향) TC02 실행 후 인증서 디렉토리가 비어 실질적으로 모든 후속 TC가 연쇄 실패

TC02가 `set_edge_device_id`로 device_id를 테스트값(`TC_AZ02_1786421906`)으로 바꾸자
직후(같은 초, 13:18:26) `[AzureConnector] Device certificate validation published:
is_valid=false` 로그가 찍혔고, 그 이후 `/edge/sp/secrets/dp/`가 완전히 빈 디렉토리로
남았다(`ls`: `cacert_0.pem`/`device_private_key.pem`/`full_chain_cert.pem`/
`leafcert_0.pem` 전부 없음). TC03/TC04는 각각 시작 시점에 `[ ! -f "$cert" ]` precondition
체크를 먼저 하고, 이미 없으면 아무 것도 건드리지 않고 바로 FAIL 처리 후 return하는
구조라(코드 확인) **TC03/TC04 자체가 인증서를 지운 게 아니다** — 이미 TC02 직후
시점에 사라져 있었다.

가능성 있는 설명: device_id가 바뀌면 azure_connector가 (기존 인증서는 옛 identity로
발급된 것이므로) 자체적으로 무효화 → 재등록(enrollment)을 시도하는 게 정상 설계로
보이는데, 이 DUT가 실제 Azure DPS/IoT Hub에 도달할 수 없어(부팅 로그에도 `edge_device_id
not ready, skipping` — 애초에 실 identity가 설정된 적이 없었음) 재등록이 완료되지
못하고 인증서 없는 상태로 남은 것으로 추정된다. 즉 **이 앱의 "device_id 변경 시
기존 인증서 무효화" 동작 자체는 의도된 것일 가능성이 높지만, 재등록 실패 시 롤백
없이 인증서가 없는 상태로 남는 것이 의도인지는 확인 필요**하다. 확실한 것은 이 하나의
연쇄로 TC02-3/4, TC03 전체, TC04 전체, TC06(블롭 업로드), TC07/08(텔레메트리
큐잉/재연결), TC09(C2D), TC10(연결 상태), TC11(인증서 파일 검증)까지 27건 FAIL 중
대다수가 **같은 근본 원인 하나**로 수렴한다.

**근거 — `evidence_full.log`**:
```
Aug 11 13:18:26 ... [I][AZ] [handle_request_set_edge_device_id] edge_device_id set: TC_AZ02_1786421906
Aug 11 13:18:26 ... [I][AZ] [AzureConnector] Device certificate validation published: is_valid=false
```
(직접 확인, evidence 이후 시점) `ls -la /edge/sp/secrets/dp/` → `total 2`(디렉토리 자체만, 파일 0개)
(부팅 시점 비교) `Aug 10 17:08:03 ... [W][CB] push_identity_to_azure_connector: edge_device_id not ready, skipping`

### 2. TC02-3/4 FAIL — DPS 등록 시도/결과 로그 자체가 안 나타남

`Attempting device registration with DPS...` 로그가 30초 대기 후에도 전혀 안 나타남
— 이 DUT가 실제 Azure DPS 엔드포인트에 도달 가능한 네트워크/자격증명을 가진
환경인지부터 확인이 필요하다(개발용 로컬 DUT라 실제 클라우드 연동 없이 동작 중일
가능성).

### 3. (스크립트 견고성 문제) TC08-2/TC11-3이 sqlite3/파일 부재를 "성공"으로 오판

- **TC08-2** (`telemetry row가 재연결 후 0으로 감소`): db_manager와 마찬가지로 이
  DUT에 `sqlite3` CLI가 없어 `SELECT COUNT(*) ...`가 매번 빈 문자열을 반환하는데,
  스크립트가 `[ -z "$remain" ] && remain=0`으로 **빈 값을 "0행"과 동일하게 처리**해서
  실제로는 카운트를 전혀 못 했음에도 PASS로 오판됨.
- **TC11-3** (`키페어 일치`): `full_chain_cert.pem`/`device_private_key.pem` 둘 다
  없는 상태에서 `openssl x509`/`openssl pkey`가 각각 빈 출력(에러)을 내는데, 그
  빈 출력끼리 `diff`하면 "차이 없음"으로 판정되어 PASS로 오판됨. 두 오탐 모두
  **명령 실패(빈 출력/None)를 "정상값 0/일치"로 잘못 취급하는 동일 패턴의 결함** —
  db_manager TC02-2/TC09-4에서 발견한 sqlite3 부재 문제와 근본 원인은 다르지만
  (여긴 sqlite3가 진짜 없어서), 판정 로직이 "명령 실패"와 "정상적인 빈 결과"를
  구분하지 못하는 것은 공통된 스크립트 설계 결함이다. **스크립트 수정 완료**
  (`HAS_SQLITE3` 가드 추가로 TC08-2/3을 sqlite3 부재 시 명시적 FAIL 처리, TC11-1
  파일 부재 시 TC11-2~4를 스킵하고 FAIL 처리) — 단, 이 DUT의 인증서 상태(핵심 이슈 1)가
  그대로라 수정 스크립트로 재실행해도 PASS/FAIL 총계는 동일하게 나올 것으로 예상되어
  이번 회차에서는 **재실행으로 재검증하지 않음**(md5 위 수치는 수정 전 최초 실행 기준).

---

## 요약

| TC | 기준 수 | PASS | FAIL |
|---|---|---|---|
| TC02 | 4 | 2 | 2 |
| TC03 | 4 | 0 | 4 |
| TC04 | 3 | 0 | 3 |
| TC06 | 3(자동 3) | 1 | 2 |
| TC07 | 3 | 0 | 3 |
| TC08 | 3 | 1 | 2 |
| TC09 | 2 | 0 | 2 |
| TC10 | 6 | 0 | 6 |
| TC11 | 4(자동 4) | 1 | 3 |
| **합계** | **32** | **5** | **27** |

TC01/TC05는 스텁 SKIP. TC06-4/TC09(반자동)는 판정 대상 외 수동 확인 항목 별도.

## 다음 단계 (개발자/사용자 확인 필요)

- **[우선] 이 DUT의 `edge_device_id`/인증서를 원상 복구할지 여부 결정.** 사용자가
  이 DUT를 다른 용도로도 쓰고 있다면 실제 Azure 재프로비저닝(정상 device_id 재설정 +
  DPS 재등록)이 필요할 수 있음.
- azure_connector가 실제 Azure DPS/IoT Hub에 도달 가능한 테스트 환경인지 확인 —
  안 된다면 TC02/03/04/06/07/08/09/10/11 대부분은 애초에 이 DUT에서 자동 검증이
  불가능한 구조이므로 별도 테스트 환경(실 Azure 연동 가능한 DUT)이 필요
- TC08-2/TC11-3: 명령 실패를 성공으로 오판하는 스크립트 판정 로직 보강
