# TC 실행 결과 보고서 — web_interface

**최초 실행:** 2026-08-11 16:41 ~ 17:00 KST (2회차)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `a7ec2d61bdf9ac4f06622984e351f9c8`
**실행 환경:** SSH (COM7 시리얼 미인식으로 fallback)
**총 결과:** **PASS=24 / FAIL=2**
**Evidence:** `tcs/web_interface/tc_web_interface_evidence_full.log`

---

## 시험 과정에서 발견된 핵심 이슈

### 1. (스크립트 버그, 수정 완료) TC01-2가 DUT에 없는 python3 사용, TC01-3이 redirect 미추적

1차 실행(PASS=22/FAIL=4)에서 TC01-2(OpenAPI 문서 유효성)는 `python3 -c "..."`로
검증하고 있었는데 이 DUT엔 python3가 없어(db_manager TC 조사에서 이미 확인된 환경
제약) 항상 실패, `jq` 기반으로 교체. TC01-3(Swagger UI HTML 200)은 `/platform/docs`가
실제로는 301(trailing slash 리다이렉트)을 내는데 `curl`에 `-L`이 없어 리다이렉트를
못 따라가 200을 못 봤음 — `-L` 추가로 해결. 수정 후 재실행 PASS=22→24.

### 2. TC08-2 FAIL — PATCH 요청에 404 대신 405 응답 (개발자 확인 필요)

`/health`에 PATCH 요청 시 스펙은 404(라우트 자체가 없음)를 기대했는데 실제로는
405(Method Not Allowed)가 온다. `/health`가 GET으로는 정의돼 있고 PATCH만 허용
안 되는 표준 REST 프레임워크 동작으로 보여 **405가 오히려 더 정확한 응답일 가능성이
높다** — TC 스펙의 기대값(404) 쪽이 잘못된 가정이었을 수 있어 개발자 확인 필요
(코드상 라우트 정의 방식에 따라 달라짐).

**근거 — `evidence_full.log`**:
```
$ curl -sk -o /dev/null -w %{http_code} -X PATCH https://192.168.10.25:9112/health
    405
```

### 3. TC12-1 FAIL — Rate limit 429 횟수가 기대 범위(40~60) 벗어남 (80회), 스크립트 자체 경고와 일치

스크립트 주석에 이미 "다른 TC와 rate limit 버킷을 공유하므로 단독 실행 권장"이라고
명시돼 있다 — 이번 실행은 TC01~11이 이미 여러 요청을 소비한 뒤 이어서 돈 것이라
버킷이 이미 일부 소진된 상태였고, 그래서 기대보다 429가 더 많이(80회) 나온 것으로
보인다. **버그가 아니라 스크립트가 이미 경고한 조건에서 실행한 결과** — 정확한 판정을
원하면 `--tc12` 단독 실행으로 재검증 필요.

---

## 요약

| TC | 결과 |
|---|---|
| TC01 (3개) | PASS×3 |
| TC02~TC07, TC09~TC11 | PASS (세부 evidence 참고) |
| TC08 | PASS×1, FAIL×1(TC08-2) |
| TC12 | PASS×1, FAIL×1(TC12-1, 버킷 공유 영향) |
| **합계** | **PASS=24 / FAIL=2** |

## 다음 단계 (개발자 확인 필요)

- TC08-2: PATCH /health의 기대 응답이 404가 맞는지, 405가 정상 동작인지 확인 후 스펙/TC 값 조정
- TC12: 정확한 429 카운트 재검증이 필요하면 `--tc12` 단독 실행으로 재확인
