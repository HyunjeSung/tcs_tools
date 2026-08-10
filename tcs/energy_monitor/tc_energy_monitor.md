---
spec_id: energy_monitor
suite: application
grade: A
phase: Phase 1
test_file: tcs/energy_monitor/tc_energy_monitor.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-ENERGY_MONITOR: energy_monitor — 텔레메트리 수집 및 Azure IoT Hub 전송

## 목적 (Objective)

`energy_monitor` 애플리케이션이 `energy_link`로부터 IPC(`telemetry` notification)로
수신한 실시간 계측값을, `configuration.json`에 정의된 항목만 필터링하여 평균/누적/
소수점 처리 후 `CommonTelemetryDto` 페이로드로 가공하고, 설정된 주기마다
`send_d2c_message` IPC 요청(`azure_connector` 경유)으로 Azure IoT Hub에 전송하는
전 과정을 검증한다.

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "Telemetry foundation" 카테고리 원본 7개
TC(Key 138-144, `docs/tc_requirements/energy_monitor.md`)를 기준으로 작성했다. 원본
다수가 Azure IoT Hub Explorer(클라우드 포털) 화면 확인을 최종 검증 스텝으로 제시하지만,
이는 DUT 셸 스크립트로 자동화할 수 없으므로 본 문서는 **DUT 경계에서 관측 가능한
지점(energy_monitor가 실제로 발행하는 MQTT IPC 요청 및 journald 로그)까지를 자동화
범위**로 재구성했다. 클라우드 포털 확인이 필요한 서브스텝은 TC08에 목록으로만 남긴다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `energy_monitor` 프로세스 실행 중 (`pgrep -f energy_monitor`, 바이너리
  경로 `/edge/app/bin/energy_monitor`)
- `azure_connector` 프로세스도 실행 중 (`pgrep -f azure_connector`) — `energy_monitor`의
  `send_d2c_message` 요청은 `azure_connector`가 `SERVICE_SEND_D2C_MESSAGE` 핸들러를
  오퍼(offer)하지 않으면 라우팅 대상이 없어 그냥 드롭된다
  (`base_app.cpp::publish_request_routed` → `warn_throttled("no_handler:...")`)
- MQTT 브로커 동작 중 (`localhost:1883`), `mosquitto_pub` / `mosquitto_sub` 설치됨
- 설정 파일 `/edge/app/files/commonfile/configuration.json` 읽기 가능
  (`ConfigurationDocument` 스키마: `version`/`lastModifiedBy`/`lastModifiedAt`/
  `commonTelemetryVer`/`deviceList[].deviceMetricList[].readingType`)
- `journalctl -u docker-loader` 로 energy_monitor 로그 확인 가능 (energy_monitor는
  독립 systemd 유닛이 아니라 docker-loader가 구동하는 프로세스 중 하나)

### ⚠️ 요구사항 원본 대비 코드 드리프트 (사전 확인 필수)

요구사항 문서(`docs/tc_requirements/energy_monitor.md`)의 로그 예시·필드명은 현재
소스코드(`qcells/uniep/core/application/energy_monitor/`, 2025-08-07 기준)와 다음 5가지
지점에서 다르다. 아래 TC들은 **코드 기준으로 재작성**했다 — 요구사항 원본 그대로
믿고 로그를 grep하면 아무것도 안 잡힐 수 있다.

1. **로그 태그 `[EM]` → 실제는 `[ET]`**: 요구사항의 모든 로그 예시가 `[D][EM]`을
   사용하지만, 실제 코드는 `energy_monitor.cpp:24`
   `EdgeLogger::get().set_app_name_mapping(client_id, "ET")` 로 `[ET]` 태그를 사용한다
   (시스템 설정 키도 `log_level_et`). DUT 바이너리가 로컬 git 체크아웃보다 오래됐을
   가능성이 있으므로(project_dut_build_vs_git_checkout 참고), 실행 전
   `journalctl -u docker-loader | grep -oE '\[D\]\[[A-Z]+\]' | sort -u` 로 실제 태그를
   먼저 확인할 것을 권장한다.
2. **메트릭 단위 상세 DEBUG 로그가 현재 코드에 없음**: 요구사항의
   `Stored metric [...] value=..., scaleFactor=..., periodMs=..., precision=...` 나
   `Processing telemetry payload with N metrics` 같은 per-metric 로그는
   `telemetry_manager.cpp::store_telemetry_metric` / `energy_monitor.cpp::handle_noti_telemetry`
   어디에도 없다(관련 LOG 줄은 주석 처리돼 있거나 애초에 없음 — 에러 발생 시에만
   `log_error_summary()`가 요약 로그 1줄 남김). 유일하게 살아있는 페이로드 전체 덤프
   로그는 `LOG(DEBUG) << "Generated Azure payload for N metric(s): " << payload.dump()`
   (`telemetry_manager.cpp` 약 2004행)이며 **DEBUG 레벨**이라 `log_level_et` 시스템
   설정이 DEBUG로 켜져 있지 않으면 journald에 나타나지 않는다. 이 때문에 아래 TC들은
   로그 레벨에 의존하지 않는 **MQTT 직접 캡처(`send_d2c_message` 요청 가로채기)를
   1차 판정 근거**로 삼고, journald DEBUG 로그는 보조 근거로만 사용한다.
3. **`points` 오브젝트 키는 metric name이 아니라 metric `rid`**: README.md 예시
   페이로드는 `points: {"pv_701_W": 12345.12}`처럼 사람이 읽기 쉬운 name을 키로
   쓰는 것처럼 보이지만, 실제 코드(`telemetry_manager.cpp::process_device_metrics_for_payload`)는
   `points[metric.rid] = value` 로 채운다. 판정 스크립트는 metric의 `name`이 아닌
   `rid` 문자열로 값을 찾아야 한다.
4. **최상위 `samplingRate` 필드는 파싱 구조에 없음**: TC04에서 상술.
5. **`[AZ]` 로그·`energyDirection`(INJ/ABS) 이름은 다른 앱/문서 소관**: `[AZ]` 태그와
   "Success to send message with headers" 로그는 energy_monitor가 아니라
   `azure_connector` 앱의 것이다(`azure_connector.cpp:135`,
   `set_app_name_mapping(client_id, "AZ")`). energy_monitor 자신의 책임 범위는
   `send_d2c_message` IPC 요청을 azure_connector로 발행하는 데까지이며, 그 뒤 실제
   Azure IoT Hub 전송 성공 여부·Explorer 상 값 확인은 TC08(자동화 불가) 참고. 또한
   README.md가 쓰는 `energyDirection`(INJ/ABS)이라는 필드명은 코드에 없고, 실제로는
   `readingType.flowDirectionType`(값: `"Positive"`/`"Negative"`/미지정)이 그 역할을
   한다(`telemetry_manager.cpp::should_accumulate_value`).

---

## TC01 — Report 항목 필터링

### 목적

`configuration.json`의 `deviceMetricList`에 정의되지 않은 `metricPath`로 들어온
telemetry 값은 Azure로 나가는 payload에서 제외되고, 정의된 항목만 `points`에
포함되는지 확인한다. (원본 Key138)

필터링은 두 단계로 일어난다: ① `TelemetryManager::store_telemetry_metric()` 이
`cached_used_metric_paths_`(설정에서 캐시된 metricPath 집합)에 없는 `metricPath`는
저장 자체를 건너뛴다(`telemetry_manager.cpp:318`), ② 저장됐더라도
`process_device_metrics_for_payload()`는 `device.deviceMetricList`를 순회하며
설정에 있는 메트릭에 대해서만 `points[metric.rid]`를 채운다. 본 TC는 이 두 단계를
합쳐 최종 payload 레벨에서 검증한다.

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`에서 임의 device 1개의 첫 metric을 선택해
  `CONFIGURED_RID`(`deviceMetricList[].rid`), `CONFIGURED_PATH`(`metricPath`),
  `TELEMETRY_PERIOD`(`readingType.telemetryPeriod`, 초 단위) 확보

### 절차

1. `mosquitto_sub -t "emsp/azure_connector/energy_monitor/req/send_d2c_message" -C 1 -W $((TELEMETRY_PERIOD+15))` 를
   백그라운드로 구독 시작, 결과를 파일로 저장
2. `mosquitto_pub -t "emsp/energy_monitor/tc_runner/noti/telemetry" -m '[
     {"metricPath":"'"$CONFIGURED_PATH"'","value":123.4},
     {"metricPath":"tc_unconfigured/bogus/path","value":999.9}
   ]'` 발행 (energy_link가 보내는 것과 동일한 형식의 배열; 두 번째 항목은
   `configuration.json`에 존재하지 않는 임의 경로)
3. `TELEMETRY_PERIOD`초 대기 후 구독 결과 회수 → JSON 파싱(`message_type`,
   `message` 필드; `message`는 payload를 dump한 JSON 문자열이므로 재파싱 필요)
4. 파싱된 payload에서 `devices[].points` 전체를 순회해 `CONFIGURED_RID` 키가
   존재하는지, 그리고 `999.9` 값(혹은 `tc_unconfigured` 관련 키)이 payload 어디에도
   없는지 확인
5. (보조 근거, DEBUG 로그 켜진 경우만) `journalctl -u docker-loader --since "1 minute ago" | grep 'Generated Azure payload'` 로 동일 payload 덤프 교차 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 설정된 항목 | `points`에 `CONFIGURED_RID` 키 존재 |
| 미설정 항목 | `999.9` 값 또는 `tc_unconfigured` 관련 키가 payload 전체에 없음 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | 캡처된 send_d2c_message 요청 1건 이상 수신 | boolean | true | `[ -s "$capture_file" ]` |
| TC01-2 | payload의 points에 CONFIGURED_RID 키 존재 | boolean | true | `echo "$parsed_message" \| grep -q "\"$CONFIGURED_RID\""` |
| TC01-3 | 미설정 항목(999.9) 값이 payload에 없음 | boolean | true | `echo "$parsed_message" \| grep -qv "999.9"` (grep -c 결과 0) |

---

## TC02 — Azure IoT Hub 전송

### 목적

생성된 telemetry payload가 설정된 주기(`telemetryPeriod`)마다 `send_d2c_message`
IPC 요청(`message_type="ReportCommonTelemetry"`)으로 azure_connector에 발행되는지
확인한다. (원본 Key139)

energy_monitor 자신의 검증 범위는 `BaseApp::send_d2c_message()` →
`publish_request_routed(SERVICE_SEND_D2C_MESSAGE, payload)` 호출까지다
(`base_app.cpp:906-917`). 실제 Azure IoT Hub 도달 여부(azure_connector 이후 구간)는
TC08 참고.

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`에서 하나 이상의 metric의 `readingType.telemetryPeriod` 확인
  (`TELEMETRY_PERIOD`, 없으면 기본값 60초)

### 절차

1. `mosquitto_sub -t "emsp/azure_connector/energy_monitor/req/send_d2c_message" -v` 를
   `2*TELEMETRY_PERIOD + 20`초 동안 백그라운드로 구독, 파일에 순차 저장(타임스탬프 포함)
2. 대기 동안 아무 조작도 하지 않음 (정상 운영 상태에서 주기적 전송만 관찰)
3. 캡처 종료 후 파일에서 개별 메시지를 분리해 각각 파싱:
   - `message_type` 필드가 `"ReportCommonTelemetry"` 인지
   - `message` 필드(JSON 문자열)를 재파싱해 `"type":"CommonTelemetryDto"` 인지
4. 수신된 메시지가 2건 이상이면, 연속된 두 메시지의 도착 시각 차이를 계산해
   `TELEMETRY_PERIOD` ± 5초 이내인지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 전송 발생 | 관찰 구간 동안 2회 이상 send_d2c_message 요청 발행 |
| message_type | 매 요청마다 `"ReportCommonTelemetry"` |
| message 내용 | 매 요청마다 `"type":"CommonTelemetryDto"` 포함 |
| 전송 간격 | 연속 전송 시각 차이가 TELEMETRY_PERIOD ± 5초 이내 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | 관찰 구간 내 send_d2c_message 요청 2건 이상 | boolean | true | `grep -c "send_d2c_message" "$capture_file"` ≥ 2 |
| TC02-2 | 모든 요청의 message_type이 ReportCommonTelemetry | boolean | true | `grep -c '"message_type":"ReportCommonTelemetry"' "$capture_file"` == 캡처 건수 |
| TC02-3 | 모든 message 내용에 CommonTelemetryDto 포함 | boolean | true | `grep -c 'CommonTelemetryDto' "$capture_file"` == 캡처 건수 |
| TC02-4 | 연속 전송 간격이 TELEMETRY_PERIOD ± 5초 | boolean | true | `[ $interval_diff -le 5 ]` (interval_diff = 실측 간격 - TELEMETRY_PERIOD 절대값) |

---

## TC03 — 평균 값 계산

### 목적

`configuration.json`에서 `readingType.qualifier`가 `"Avg"`로 설정된 항목이, 순시값이
아니라 `telemetryPeriod` 동안 수신한 값들의 산술평균으로 report 되는지 확인한다.
(원본 Key140)

계산 로직은 `TelemetryManager::calculate_value_by_qualifier()`
(`telemetry_manager.cpp:386`)에서 `qualifier == "Avg"` 일 때
`sum(values) / values.size()` 로 확정되어 있고, 이후 `apply_ten_multiplier()`가
반올림을 적용한다(`calculate_metric_value()`, `telemetry_manager.cpp:366-384`).

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`에서 `readingType.qualifier == "Avg"` 인 metric 1개 선택 →
  `AVG_RID`, `AVG_PATH`, `AVG_TEN_MULTIPLIER`, `AVG_PERIOD`(telemetryPeriod)

### 절차

1. `mosquitto_sub -t "emsp/azure_connector/energy_monitor/req/send_d2c_message" -C 1 -W $((AVG_PERIOD+15))` 백그라운드 구독 시작
2. `AVG_PERIOD` 동안 서로 다른 값 3~5개(예: 10.0, 20.0, 30.0)를 1~2초 간격으로
   `AVG_PATH`에 telemetry 알림으로 발행. 기대 평균값 `EXPECTED_AVG` 를 미리 계산
   (예: (10+20+30)/3 = 20.0)
3. `apply_ten_multiplier(EXPECTED_AVG, AVG_TEN_MULTIPLIER)` 와 동일한 반올림 규칙을
   셸에서 재현해 `EXPECTED_ROUNDED` 계산 (tenMultiplier<0: `10^(-tenMultiplier)` 자리로
   반올림, tenMultiplier>=0: `10^tenMultiplier` 단위로 반올림)
4. 캡처된 payload에서 `points[AVG_RID]` 값을 추출, `EXPECTED_ROUNDED` 와 부동소수
   오차 허용(예: ±0.5 × 최소 단위) 내 일치하는지 확인
5. 순시값이 아님을 별도로 확인: 마지막 발행값(30.0)이 아니라 평균(20.0 계열)임을
   확인 (마지막 값과 다르면 평균 계산이 실제로 동작 중이라는 근거)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 평균 계산 | payload의 값이 발행한 값들의 산술평균(반올림 적용)과 일치 |
| 순시값 아님 | payload 값이 마지막 발행값과 다름(입력값이 서로 다를 때) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | payload 값이 기대 평균(반올림 적용)과 일치 | boolean | true | `awk -v a="$reported" -v b="$EXPECTED_ROUNDED" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.01)}'` |
| TC03-2 | payload 값이 마지막 발행값(순시값)과 다름 | boolean | true | `[ "$reported" != "$LAST_INJECTED_VALUE" ]` |

---

## TC04 — 전송 주기 조절 (Flag — 요구사항의 `samplingRate` 필드가 코드에 없음)

> 요구사항 원본은 `configuration.json` 최상위에 `"samplingRate": 60` 필드가 있고
> 그 값이 통째로 전송 주기를 결정한다고 기술한다. 그러나 실제
> `ConfigurationDocument`/`DeviceMetric`/`ReadingType` 파싱 구조
> (`msg_ipc_payload.hpp:1036-1117`)에는 최상위 `samplingRate` 필드가 없다.
> README.md·`docs/energy_monitor_functionality_analysis.md` 도 `samplingRate`를
> 언급하지만 실제 파싱 코드가 어디에도 없어 두 문서 모두 구버전 스펙을 베낀
> 것으로 보인다. **실제 동작 메커니즘은 메트릭 단위 `readingType.telemetryPeriod`
> (기본 60초)이며, `should_report_metric()`이 `elapsed_seconds % telemetryPeriod == 0`
> 조건으로 각 메트릭을 독립적으로 리포트한다** (`telemetry_manager.cpp:225-236`).
> 이 TC는 실제 메커니즘(telemetryPeriod)을 기준으로 작성했다 — **개발자 확인
> 필요: 전역 `samplingRate` 설정이 별도 경로(예: system_settings)로 존재하는지,
> 아니면 요구사항 문서가 폐기된 구버전 스펙인지.**

### 목적

메트릭마다 다른 `telemetryPeriod` 값을 설정할 수 있고, 실제 전송 간격이 그 값과
일치하는지 확인한다. (원본 Key141의 재해석)

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`에서 서로 다른 `telemetryPeriod` 값을 가진 metric 2개 확보
  시도 (`SHORT_RID`/`SHORT_PERIOD`, `LONG_RID`/`LONG_PERIOD`, `SHORT_PERIOD < LONG_PERIOD`).
  설정에 값이 하나뿐이면 TC04-2만 수행하고 TC04-1은 SKIP 처리

### 절차

1. `mosquitto_sub -t "emsp/azure_connector/energy_monitor/req/send_d2c_message" -v` 를
   `2*LONG_PERIOD + 20`초(단일 값만 있으면 `2*telemetryPeriod+20`초) 동안 백그라운드
   구독, 타임스탬프 포함 파일로 저장
2. 관찰 구간 종료 후, 캡처된 각 payload에서 `SHORT_RID`와 `LONG_RID`가 각각 등장한
   payload 개수를 카운트 (`SHORT_COUNT`, `LONG_COUNT`)
3. `SHORT_RID`가 처음 2회 등장한 시각 차이를 `SHORT_PERIOD`와, `LONG_RID`가 처음
   2회 등장한 시각 차이를 `LONG_PERIOD`와 각각 비교(± 5초 허용)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 등장 빈도 | `SHORT_COUNT` > `LONG_COUNT` (주기가 짧을수록 더 자주 등장) |
| 개별 간격 | 각 metric의 연속 등장 간격이 자신의 telemetryPeriod ± 5초 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | (2개 주기값 존재 시) SHORT_COUNT > LONG_COUNT | boolean | true | `[ "$SHORT_COUNT" -gt "$LONG_COUNT" ]` — 단일 주기값만 있으면 SKIP |
| TC04-2 | SHORT(또는 유일) 메트릭의 연속 등장 간격이 자신의 telemetryPeriod ± 5초 | boolean | true | `[ $interval_diff -le 5 ]` |
| TC04-Flag | 요구사항의 최상위 samplingRate 필드가 코드에 미존재함을 기록 | info | — | 상단 Flag 설명 참고, PASS/FAIL 판정 대상 아님 |

---

## TC05 — 소수점 자릿수 조정 검증

### 목적

`readingType.tenMultiplier` 설정에 따라 report되는 값의 소수점 이하 자릿수가
정확히 반올림되는지 확인한다. (원본 Key142)

반올림 로직은 `TelemetryManager::apply_ten_multiplier()`
(`telemetry_manager.cpp:347-364`)에 고정되어 있다:
`tenMultiplier < 0` 이면 `-tenMultiplier` 자리 소수점으로 반올림
(`round(value * 10^(-tenMultiplier)) / 10^(-tenMultiplier)`), `tenMultiplier >= 0`
이면 `10^tenMultiplier` 단위로 반올림한다. 요구사항 원본의 `tenMultiplier: -2 →
소수점 2자리` 표는 코드와 정확히 일치한다(High 신뢰도).

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`에서 `tenMultiplier`가 음수인 metric 1개 확보 →
  `TM_RID`, `TM_PATH`, `TM_MULT`(예: -2), `TM_PERIOD`(telemetryPeriod)
- 가능하면 `tenMultiplier`가 0 또는 양수인 metric도 추가로 1개 확보(선택, TC05-2)

### 절차

1. `mosquitto_sub -t "emsp/azure_connector/energy_monitor/req/send_d2c_message" -C 1 -W $((TM_PERIOD+15))` 백그라운드 구독 시작
2. 소수점이 충분히 긴 값(예: `12.34567`)을 `TM_PATH`에 1회만 telemetry 알림으로 발행
   (해당 metric이 `qualifier=="Avg"`라도 값 1개만 주면 평균=그 값이 되어 반올림
   로직만 독립적으로 관찰 가능)
3. `EXPECTED = round(12.34567 * 10^(-TM_MULT)) / 10^(-TM_MULT)` 를 셸에서 미리 계산
   (예: TM_MULT=-2 → 12.35)
4. `TM_PERIOD` 대기 후 캡처된 payload에서 `points[TM_RID]` 추출, `EXPECTED`와 정확히
   일치(또는 부동소수 오차 1e-9 이내)하는지 확인
5. (선택) 두 번째 metric으로 동일 절차 반복, tenMultiplier 부호가 달라도 규칙이
   동일하게 적용됨을 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 반올림 자릿수 | payload 값이 tenMultiplier 규칙대로 반올림된 값과 일치 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC05-1 | 음수 tenMultiplier 반올림 값 일치 | boolean | true | `awk -v a="$reported" -v b="$EXPECTED" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<1e-6)}'` |
| TC05-2 | (선택) 0/양수 tenMultiplier 반올림 값 일치 | boolean | true | 동일 방식, 두 번째 metric 대상 |

---

## TC06 — 누적값 계산

### 목적

`accumulationType`이 `"Cumulative"`/`"DailyCumulative"`/`"DeltaData"`인 metric이
W(순시전력) 값을 Wh(전력량)로 환산해 누적되는지, 그리고 `flowDirectionType`
(`"Positive"`/`"Negative"`/미지정)에 따라 방향 필터링이 적용되는지 확인한다.
(원본 Key143)

W→Wh 환산은 `convert_w_to_wh(w_value, periodMs) = w_value * periodMs / 3600000`
(`telemetry_manager.cpp:1452-1454`), 방향 필터링은 `should_accumulate_value()`
(`Positive`: 값 ≥0만 누적, `Negative`: 값 <0만 누적하되 절대값으로 가산,
미지정: 부호 무관 전부 누적 — `telemetry_manager.cpp:1456-1468`,
`accumulate_with_flow_direction()` `telemetry_manager.cpp:1491-1497`)에서 처리된다.
누적값도 다른 metric과 동일하게 `points[metric.rid]`에 실려 report된다
(`get_metric_value_for_reporting()`가 `accumulationType`과 무관하게 통일된 경로 사용,
`telemetry_manager.cpp:777-784`).

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`에서 `accumulationType`이 `"Cumulative"` 또는
  `"DailyCumulative"`인 metric 1개 확보 → `CUM_RID`, `CUM_PATH`,
  `CUM_FLOW_DIRECTION`(readingType.flowDirectionType), `CUM_PERIOD`

### 절차

1. `mosquitto_sub` 로 `send_d2c_message` 요청을 `CUM_PERIOD` 동안 백그라운드
   구독 시작
2. `periodMs=1000` 을 명시한 telemetry 알림을 N회(예: 3회) 발행, 각 값은
   `CUM_FLOW_DIRECTION`에 맞는 부호로 구성(예: `Positive`면 양수만)
3. 기대 누적 증가량 계산: `sum(value_i * 1000 / 3600000)` (Wh)
4. `CUM_PERIOD` 대기 후 캡처된 payload에서 `points[CUM_RID]` 값 확인, 시험 시작
   전 baseline 값 대비 증가량이 기대치와 오차 범위 내 일치하는지 확인
5. 방향 필터링 확인: `CUM_FLOW_DIRECTION`과 반대 부호의 값 1개를 추가 발행 →
   다음 payload에서 값이 (필터링되어) 그대로 유지되는지, 즉 이전 값 대비 변화가
   없는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 누적 증가 | payload 값 증가량이 `sum(value_i * periodMs/3600000)` 기대치와 일치 |
| 방향 필터링 | flowDirectionType과 반대 부호 값은 누적에 반영되지 않음 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | 누적값 증가량이 기대 Wh와 일치(오차 허용) | boolean | true | `awk -v a="$delta" -v b="$EXPECTED_WH" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.01)}'` |
| TC06-2 | 반대 방향 값 주입 후 누적값 불변 | boolean | true | `[ "$value_after_opposite_sign" = "$value_before_opposite_sign" ]` |

---

## TC07 — Telemetry 수신 (IPC 프로토콜 레벨)

### 목적

`energy_link`가 보내는 `telemetry` IPC notification(`NOTI_TELEMETRY`,
`emsp/energy_monitor/{source}/noti/telemetry`)을 energy_monitor가 정상 수신·처리하고,
형식이 잘못된 메시지는 안전하게 거부(크래시 없이 에러 로그만 남김)하는지 확인한다.
(원본 Key144)

`EnergyMonitor::handle_noti_telemetry()`(`energy_monitor.cpp:348-366`)는 메시지가
JSON 배열이 아니면 `LOG(ERROR) << "Invalid telemetry message format - expected array
of metrics"` 를 남기고 즉시 return하며, `site_json_data_.is_configuration_ready()`
가 false면 `LOG(WARN) << "Configuration not loaded yet, skipping telemetry"` 를
남기고 스킵한다. TC01/TC03/TC06이 이미 "정상 배열 수신 → 값 반영" 경로를
간접 검증하므로, 본 TC는 **수신측 견고성(malformed input 처리)** 에 집중한다.

### 사전 조건

- 공통 전제 조건 충족 (특히 `site_json_data_.is_configuration_ready()`가 true인
  정상 운영 상태 — Configuration not ready 케이스는 재현이 파괴적이라 범위 밖)

### 절차

1. `journalctl -u docker-loader --since "now"` 기준점 기록(타임스탬프)
2. `mosquitto_pub -t "emsp/energy_monitor/tc_runner/noti/telemetry" -m '{"not":"an array"}'`
   발행 (배열이 아닌 JSON object)
3. 2초 대기 후 `journalctl -u docker-loader --since "<기준점>"` 에서
   `"Invalid telemetry message format"` 로그 확인
4. `pgrep -f energy_monitor` 로 프로세스가 여전히 살아있는지 확인 (크래시 없음)
5. 정상 배열 형식으로 `mosquitto_pub -t "emsp/energy_monitor/tc_runner/noti/telemetry" -m '[{"metricPath":"tc_health_check/dummy","value":1.0}]'` 재발행
6. 이후 5초간 `journalctl -u docker-loader` 에서 새로운 `"Invalid telemetry message
   format"` 로그가 추가되지 않는지 확인 (정상 형식은 에러 없이 처리됨)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 잘못된 형식 처리 | ERROR 로그 발생, 프로세스 크래시 없음 |
| 정상 형식 처리 | 동일 시점 이후 ERROR 로그 추가 발생 없음 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | 비배열 메시지 발행 후 ERROR 로그 확인 | boolean | true | `journalctl -u docker-loader --since "$mark" \| grep -q "Invalid telemetry message format"` |
| TC07-2 | 프로세스 생존 확인 | boolean | true | `pgrep -f energy_monitor` exit 0 |
| TC07-3 | 정상 배열 발행 후 추가 ERROR 로그 없음 | boolean | true | `journalctl -u docker-loader --since "$mark2" \| grep -c "Invalid telemetry message format"` == 0 |

---

## TC08 — 자동화 불가 항목 목록 (Azure IoT Hub Explorer 클라우드 포털 확인)

요구사항 원본 7개 TC 모두 마지막 서브스텝으로 "Azure IoT Hub의 Explorer를 이용하여
Common-Telemetry 값을 확인한다"를 제시한다. 이는 실제 Azure 클라우드 포털 접속과
사람의 시각적 확인이 필요해 단일 DUT 셸 스크립트로는 검증 불가능하다. TC로
변환하지 않고 목록으로만 남긴다 — DUT 경계(azure_connector로의 IPC 요청 발행)까지는
TC01~TC07이 커버한다.

| 원본 Key | 항목 | 자동화 불가 사유 |
|----------|------|-------------------|
| Key138 (Explorer 서브스텝) | configuration.json의 deviceMetricList 항목이 Explorer에 실제로 나타나는지 확인 | Azure 포털 접속 및 사람의 시각적 확인 필요 |
| Key139 (Explorer 서브스텝) | Explorer에서 유효한 Common-Telemetry 값 확인 | 상동 |
| Key140 (Explorer 서브스텝) | Explorer에서 평균값으로 report됨을 확인 | 상동 — DUT 측 계산 로직은 TC03이 커버 |
| Key141 (Explorer 서브스텝) | Explorer에서 payload 전송 주기가 설정값과 일치함을 확인 | 상동 — DUT 측 발행 주기는 TC04가 커버 |
| Key142 (Explorer 서브스텝) | Explorer에서 항목 값 자릿수가 tenMultiplier와 일치함을 확인 | 상동 — DUT 측 반올림은 TC05가 커버 |
| Key143 전체 | Explorer 확인 방법 명시 없이 "정상적으로 증가하는지 확인"만 기술 | 클라우드 측 시계열 확인 필요 — DUT 측 증분 계산은 TC06이 커버 |
| Key144 (Explorer 서브스텝) | Explorer로 유효한 값 확인 + "APP을 통해 확인" | 상동 — "APP을 통해 확인"이 구체적으로 어떤 앱/화면인지 원본에 명시 없음, 개발자 확인 필요 |
| — | azure_connector → 실제 Azure IoT Hub 전송 성공 여부 (`[AZ] Success to send message with headers` 로그 포함) | azure_connector는 별도 앱으로 이 TC 문서의 범위 밖(azure_connector 자체 TC 문서 필요) |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `energy_monitor` | MQTT 수신 대상 앱 ID |
| `CONFIG_PATH` | `/edge/app/files/commonfile/configuration.json` | telemetry 설정 파일(`ConfigurationDocument`) 경로 |
| `AZURE_CONNECTOR_APPID` | `azure_connector` | `send_d2c_message` 요청의 라우팅 대상 앱 ID(요청 topic 구성에 사용) |
| `LOG_LEVEL_KEY` | `log_level_et` | energy_monitor 로그 레벨을 제어하는 system_settings 키 (DEBUG로 설정 시 페이로드 덤프 로그 노출) |

---

## 자동화 등급 (Automation Grade)

🟢 **A (대부분 자동화 가능, TC04만 요구사항-코드 필드명 불일치 Flag 존재)**

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | A (자동) | MQTT 알림 주입 + send_d2c_message 캡처로 필터링 검증, 실 하드웨어 불필요 |
| TC02 | A (자동) | 정상 운영 상태에서 관찰만으로 주기적 전송 확인 |
| TC03 | A (자동) | 알려진 값 주입 후 평균 계산 결과 캡처 |
| TC04 | A (자동, Flag) | 코드상 telemetryPeriod 메커니즘은 자동화 가능하나, 요구사항의 samplingRate 필드명과 불일치 — 개발자 확인 권장 |
| TC05 | A (자동) | apply_ten_multiplier 로직이 코드로 정확히 확인됨, 반올림 결과 검증 |
| TC06 | A (자동) | W→Wh 환산 공식과 방향 필터링 로직이 코드로 확인됨 |
| TC07 | A (자동) | malformed/정상 입력 각각에 대한 로그·생존 확인 |
| TC08 | 자동화 불가 | 목록만 제공, Azure 포털 확인은 QA 수동 |

---

## 관련 문서

- `tc_energy_monitor_result.md` — 본 TC 실행 결과 보고서
- `tc_energy_monitor_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/energy_monitor.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx "Telemetry foundation" 카테고리, Key 138-144, 7개 TC)
- `qcells/uniep/core/application/energy_monitor/README.md` — 애플리케이션 개요(일부 필드명이 구버전 스펙을 반영해 코드와 다름, 상단 드리프트 섹션 참고)
- `qcells/uniep/core/application/energy_monitor/docs/energy_monitor_functionality_analysis.md` — 기능 분석 문서(EmsDeviceManager/TelemetryPayloadGenerator 등 현재 코드에 없는 구버전 클래스명 다수 포함 — 참고만, 신뢰 금지)
