# TC 실행 결과 보고서 — energy_monitor

**최초 실행:** 2026-08-11 16:57 ~ 17:16 KST (기본 실행 1회차 + TC01 단독 재검증)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `9509863a0d52f29939ae07a4a5b549ce`
**실행 환경:** SSH (COM7 시리얼 미인식으로 fallback)
**총 결과:** **PASS=1 / FAIL=9** (TC02~04는 900초+ 실시간 대기가 필요해 `timeout 600`으로
미완주 — 별도 세션에서 충분한 시간을 두고 재실행 필요)
**Evidence:** `tcs/energy_monitor/tc_energy_monitor_evidence_full.log`

| TC | 결과 |
|---|---|
| TC01-1/2 | FAIL |
| TC01-3 | PASS |
| TC02 (4개) | FAIL×4 (1차 실행, SETUP 버그 영향 — 아래 참고) |
| TC03 (2개) | FAIL×2 (1차 실행, SETUP 버그 영향) |
| TC04 | 미완주 (`timeout 600` 도달, LONG_PERIOD=900s 대기 필요) |

---

## 시험 과정에서 발견된 핵심 이슈

### 1. (스크립트 버그, 수정 완료) SETUP의 `.[0]` 인덱스 선택이 계산식 기반 metric을 집을 수 있음

1차 실행에서 TC01이 "configured metric 없음"으로 즉시 SKIP+FAIL됐다. 원인: SETUP이
`configuration.json`의 `deviceMetricList[]`를 flatten한 배열에서 `.[0]`을 무조건
첫 항목으로 쓰는데, 이 DUT의 실제 `.[0]`(`pv_200_W`)은 `calculation`(다른 두
`metricPath`를 합산하는 계산식) 기반 metric이라 `metricPath` 필드 자체가 없다
(`metricPath:null`). `.[0]`이 아니라 **`metricPath`가 실제로 존재하는 첫 항목**을
고르도록 jq 필터 수정 → 재검증 결과 CONFIGURED_RID/PATH가 정상 선택됨(`load_200_W`,
TC01-3도 PASS로 전환).

**근거 (수정 전)**:
```
$ cat /tmp/em_metrics_17237.json
    [{"rid":"pv_200_W","metricPath":null,...}, ...]  ← .[0]이 metricPath:null
[SKIP] configuration.json 에서 사용 가능한 metric 을 찾지 못함
```
**근거 (수정 후)**:
```
CONFIGURED_RID=load_200_W CONFIGURED_PATH=qcells_mcu/read/PMU_Monitoring_Data_01/Tot_Load_Active_Power TELEMETRY_PERIOD=60
[PASS] TC01-3: 미설정 항목(999.9) 값이 payload 에 없음
```

이 수정으로 SETUP이 사용하는 METRICS_FILE 자체가 정상화됐으므로, 이 파일을 공유하는
TC02/TC03의 `period` 파생값도 함께 정상화된다 — 다만 TC02/TC03/TC04는 이번 회차에서
재검증하지 못함(아래 3번 참고).

### 2. TC01-1/2 FAIL — 주입한 telemetry notification이 send_d2c_message로 전달되는 게 관측 안 됨 (개발자 확인 필요)

SETUP 수정 후에도 `mosquitto_pub`으로 `noti/telemetry`에 유효한 `metricPath`/`value`를
주입했지만, 75초(period+15) 관찰 창에서 `send_d2c_message` 요청이 **한 건도** 캡처되지
않았다. 가능성: (a) energy_monitor가 단발성 notification이 아니라 일정 기간 누적된
실측 데이터가 있어야 리포트를 발행하는 구조일 수 있음, (b) 스크립트의 구독
타이밍(구독 시작 후 0.5초 뒤 발행)이 실제로는 아직 부족할 수 있음, (c) 이 DUT에
실제 MCU/PMU 데이터가 흐르지 않아(개발용 DUT) energy_monitor의 다른 선행 조건이
막혀 있을 수 있음. 이번 회차에서는 원인을 특정하지 못함 — 개발자 확인 필요.

**근거 — `evidence_full.log`**:
```
$ mosquitto_pub -h localhost -t emsp/energy_monitor/tc_runner/noti/telemetry -m [{"metricPath":"qcells_mcu/read/PMU_Monitoring_Data_01/Tot_Load_Active_Power","value":123.4},...]
$ cat /tmp/em_tc01_capture_18822.log
    (내용 없음)
[FAIL] TC01-1: 캡처된 send_d2c_message 요청 1건 이상 수신
```

### 3. TC02~TC04 — 실시간 대기가 길어 이번 회차에서 완주 못 함

TC02는 `2×period+20`(period=60 → 140초) 관찰, TC04는 SHORT_PERIOD=60 vs
LONG_PERIOD=900 비교라 최소 900초+ 실시간 대기가 필요한 구조다. 1차 실행은
`timeout 600`(10분)으로 걸어서 TC04 도중 강제 종료됐다(exit=124). 1차 실행에서의
TC02/TC03 FAIL은 SETUP 버그가 아직 있던 상태의 결과라 수정 후 재검증이 필요하고,
**TC02~04는 최소 20분 이상의 여유를 둔 별도 세션에서 재실행 권장**.

---

## 요약

| TC | 상태 |
|---|---|
| TC01 | PASS=1/FAIL=2 (SETUP 수정 후 재검증 완료) |
| TC02~TC04 | 미완주/SETUP 수정 전 결과라 재검증 필요 |

## 다음 단계 (개발자/사용자 확인 필요, 별도 세션 권장)

- TC01-1/2: 주입한 telemetry가 send_d2c_message로 전달 안 되는 원인 조사
- TC02~TC04: SETUP 수정판으로 최소 20분 이상 여유를 둔 별도 세션에서 재실행
