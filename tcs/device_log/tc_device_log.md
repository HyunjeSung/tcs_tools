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

# TC-APP-DL: device_log — 외부 디바이스 로그 수집·파일 관리·클라우드 업로드·EOL(양산) 로그 검증

## 목적 (Objective)

`device_log` 애플리케이션은 PCS/BMS/BPU/PMU/Advanced HUB 등 외부 디바이스 텔레메트리를
`logpolicy.json` 규칙에 따라 CSV로 수집하고(SID0201), 주기적으로 파일을 회전·명명하며
(SID0202), 오래된/초과 로컬 파일을 정리하고(SID0203), Azure Blob으로 업로드하며
(SID0204), 네트워크 단절 상황을 처리하고(SID0205), 1일/1달 업로드 트래픽을 제한하며
(SID0206), 웹에서 강제 업로드를 트리거할 수 있고(SID0207), 양산(EOL) 모드에서 별도의
로그를 생성하는(SID0208) 8개 기능 영역으로 구성된다.

본 TC 명세는 Jira AGSRS 프로젝트의 33개 이슈(Epic 7개 + Story 26개, 아래 근거 매핑 표
참고)를 1차 요구사항 소스로 하고, `application/device_log/source/*.cpp` 및
`application/device_log/rules/{logpolicy,logcount,eolpolicy}.json`을 2차 검증 자료로
사용해 작성되었다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `device_log` 프로세스 실행 중 (`pgrep -f device_log`)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨
- `/edge/log/` 파티션 쓰기 가능
- 정책 파일 경로: `/edge/etc/app-config/device_log/rules/logpolicy.json`(컨테이너 내부,
  활성 설정) — device_log는 호스트가 아니라 podman 컨테이너(`ac_system_gen2`) 안에서
  실행되므로 호스트에서 `find /`로는 보이지 않는다. `nsenter -t $(pgrep -f device_log) -m
  -- find / -iname logpolicy.json` 또는 `docker exec -it ac_system_gen2 find / -iname
  logpolicy.json`로 확인할 것. baked-in 기본값은 `/edge/app/files/device_log/logpolicy.json`
  (이미지 빌드 시점 값, 별개 파일)
- `tc_device_log.sh`는 호스트 셸과 `ac_system_gen2` 컨테이너 내부 셸 양쪽에서 실행
  가능해야 한다 — 호스트에서 실행되면 정책 파일 접근에 `docker exec ac_system_gen2`를
  거치고, 이미 컨테이너 내부(`docker exec -it ac_system_gen2 /bin/bash`로 진입한 상태)
  라면 `docker exec`를 또 걸지 않고 파일에 직접 접근한다(스크립트가 `docker` 커맨드
  존재 여부와 컨테이너 exec 가능 여부로 자동 판별, `IN_CONTAINER` 플래그)
- 외부 디바이스(PCS/BMS/BPU/PMU 등) 실물 연결이 없는 랩 환경에서는 MQTT로 텔레메트리
  notification을 직접 publish하여 대체 (`emsp/+/+/noti/...` 형식, 실제 topic은
  DUT의 `journalctl`에서 device_manager notification 경로를 참고)

---

## SID0201 — External device log data collection

## TC01 — 로그 데이터 필드 정확성

### 목적

수집된 CSV 행에 `date`, `time`, `serial_number`와 `logpolicy.json`의 해당 `logItem`
컬럼이 모두 채워지는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- 대상 log_item은 `PMU_Monitoring`으로 고정한다 — 최근 1 `logRowInterval` 이내에
  최소 1회 텔레메트리를 수신한 상태여야 함

### 절차

1. `logpolicy.json`에서 임의의 non-fault log_item 하나를 선택하고 해당 `patternGroups`의
   컬럼 목록을 기록
2. 해당 log_item에 대응하는 MQTT notification을 1회 이상 publish (또는 실 디바이스 연결
   대기)
3. `logRowInterval` + 여유시간 대기 후 `/edge/log/device_log/<logItem>/*.csv` 최신 파일의
   헤더와 마지막 행을 확인
4. 헤더에 `date,time,serial_number` + 1단계에서 기록한 컬럼명이 모두 포함되는지 확인
5. 마지막 데이터 행의 `date`, `time`, `serial_number` 필드가 공란이 아닌지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 헤더 컬럼 | `date,time,serial_number` + logpolicy.json patternGroups 컬럼 전체 포함 |
| 데이터 행 | `date`/`time`/`serial_number` 비어있지 않음 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | 헤더에 필수 컬럼 존재 | boolean | true | `head -1 "$csv" \| grep -q "date,time,serial_number"` |
| TC01-2 | 마지막 행 serial_number 비어있지 않음 | boolean | true | `tail -1 "$csv" \| awk -F',' '{print $3}' \| grep -qE '.+'` |

---

## TC02 — 로그 Row 기록 주기(logRowInterval) 정확성

### 목적

CSV의 연속된 두 데이터 행 사이 시간 간격이 `logpolicy.json`의 `logRowInterval`과
일치하는지 확인한다(순서 무결성/주기 축적).

### 사전 조건

- 공통 전제 조건 충족
- 대상 log_item은 `Meter`(logRowInterval=15초)로 고정한다 — 짧은 주기로 시험시간 단축

### 절차

1. 대상 log_item의 현재 활성 CSV 경로 확인
2. `logRowInterval * 3` 초 이상 대기하며 텔레메트리를 주기적으로 publish
3. CSV에서 마지막 3개 데이터 행의 `time` 컬럼을 epoch로 변환
4. 연속 행 간 시간차를 계산

### 기대 결과

| 항목 | 기준 |
|------|------|
| 행 간 시간차 | `logRowInterval` ± 10% 이내 (텔레메트리 도착 지연 감안) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | 행 간 시간차가 logRowInterval 근접 | boolean | true | `[ "$diff_sec" -ge "$((interval*90/100))" ] && [ "$diff_sec" -le "$((interval*110/100))" ]` |

---

## TC03 — 로그 타입별(prefix) 텔레메트리 도착 시 CSV 실데이터 기록 확인

### 목적

`logpolicy.json`에 정의된 주기적(non-fault) `logItem`이, 해당 외부 디바이스로부터 실제
텔레메트리가 수신되는 경우 CSV 파일에 실제로 데이터 행이 채워지는지 prefix(디바이스
그룹)별로 확인한다. Fault/FaultMon류(이벤트 기반 — `PCS_Fault_P01/P02`,
`BMS_Fault_P01/P02`, `BPU_Fault_P01/P02`, `PMU_Fault`, `Advanced_HUB_Fault`,
`PCS_Fault_Monitoring_Converter/Inverter_P01/P02`)는 주기적 로깅이 아니므로 본 TC
범위에서 제외한다.

> **판정 기준 정정:** "디렉토리/파일이 생기느냐"와 "내용이 채워지느냐"는 서로 다른
> 질문이다. `createFileDirectoryForAllRules()`가 앱 부팅 시 모든 logItem에 대해
> 디렉토리와 빈 CSV(헤더만)를 noti 수신 여부와 무관하게 먼저 만들어 두므로, 디렉토리나
> 파일 존재만으로는 "텔레메트리가 실제로 도착 중"임을 증명하지 못한다(대부분
> noti 없이도 시작 시 생성됨). 실제 텔레메트리 도착 여부는 CSV에 **데이터 행이
> 최소 1개 이상 채워지는지**(noti가 와야 row가 써짐)로 판정해야 정확하다 — 본 TC는
> 이 기준으로 재정의되었다.

### 사전 조건

- 공통 전제 조건 충족
- 대상 prefix 그룹에 해당하는 외부 디바이스(또는 device_manager를 통한 MQTT
  notification 시뮬레이션)가 실제로 텔레메트리를 주기적으로 발행 중이어야 로깅이
  시작됨 — 해당 디바이스가 이 벤치에 물리적으로 연결되어 있지 않으면 해당 서브케이스는
  SKIP

### 절차 (prefix 그룹별 반복)

1. `logpolicy.json`의 `loggingRules[].logItem` 중 Fault/FaultMon을 제외한 주기적 항목을
   prefix로 그룹핑 (아래 PASS/FAIL 표 참고)
2. 그룹 내 각 logItem에 텔레메트리가 최근 도착 중인지 확인 (미도착이면 해당 서브케이스
   SKIP)
3. `logRowInterval` + 여유시간 대기
4. 그룹 내 각 logItem의 활성 CSV(`/edge/log/device_log/<logItem>/*.csv`)에서
   `wc -l`로 전체 행 수를 확인 — 헤더 1행을 제외하고 데이터 행이 1개 이상인지 확인
   (디렉토리/파일 존재가 아니라 행 수로 판정)

### 기대 결과

| 항목 | 기준 |
|------|------|
| CSV 데이터 행 | 텔레메트리가 도착 중인 logItem은 모두 활성 CSV에 헤더 외 데이터 행 1개 이상 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | EMSP 그룹 CSV 데이터 행 존재 (EMSP_Maintenance, EMSP_Installation) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` (각 logItem 활성 csv) |
| TC03-2 | PMU 그룹 CSV 데이터 행 존재 (PMU_Monitoring) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` |
| TC03-3 | MI 그룹 CSV 데이터 행 존재 (MI_Monitoring, MI_Device_Info) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` |
| TC03-4 | PCS(CAN) 그룹 CSV 데이터 행 존재 (PCS_CAN_Monitoring_P01/P02) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` |
| TC03-5 | Advanced HUB 그룹 CSV 데이터 행 존재 (Advanced_HUB_Monitoring) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` |
| TC03-6 | Meter 그룹 CSV 데이터 행 존재 (Meter) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` |
| TC03-7 | BMS 그룹 CSV 데이터 행 존재 (Operation/LifeCycle/Monitoring_P01/P02, 6개) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` (6개 모두) |
| TC03-8 | BPU 그룹 CSV 데이터 행 존재 (BPU_CAN_Monitoring_P01/P02) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` |
| TC03-9 | C_Box 그룹 CSV 데이터 행 존재 (C_Box_Monitoring) | boolean | true | `[ "$(wc -l < "$csv")" -ge 2 ]` |

> **참고 (본 벤치 실측, 2026-08-20):** TC03-1(EMSP), TC03-2(PMU), TC03-3(MI),
> TC03-6(Meter), TC03-9(C_Box)는 텔레메트리 도착 확인됨 — 즉시 실행 가능. TC03-4(PCS
> CAN), TC03-5(Advanced HUB), TC03-7(BMS), TC03-8(BPU)는 이 벤치에 해당 서브시스템이
> 물리적으로 연결되어 있지 않으면 도착 안 됨(SKIP) — 실물 연결 또는 MQTT 시뮬레이터로
> 텔레메트리를 직접 publish해야 실행 가능. 디렉토리/빈 CSV 자체는 부팅 시 이미
> 만들어져 있으므로 이 SKIP 판단도 디렉토리가 아니라 데이터 행 존재로 내려야 한다.

---

## SID0202 — File creation & naming

## TC04 — 파일명 형식 검증

### 목적

생성된 로그 파일명이 `<startTime>_<endTime>_<logItem>_<serialNumber>.csv`(활성 파일)
또는 `.csv.xz`(회전/압축된 파일) 형식(각 시각 `YYYYMMDD_HHMMSS`)을 따르는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- 대상 log_item에 텔레메트리가 도착 중이어서 `/edge/log/device_log/<logItem>/`에 파일이
  이미 생성되어 있는 상태 (TC03과 동일 전제 — `forced_log_upload`로 회전을 유도할 필요
  없이 자연 생성된 활성/회전 파일을 그대로 검사)

### 절차

1. `/edge/log/device_log/<logItem>/` 디렉토리의 파일 목록 확인
2. 각 파일명을 정규식
   `^[0-9]{8}_[0-9]{6}_[0-9]{8}_[0-9]{6}_<logItem>_[0-9A-Za-z]+\.csv(\.xz)?$` 로 검증

### 기대 결과

| 항목 | 기준 |
|------|------|
| 파일명 형식 | `YYYYMMDD_HHMMSS_YYYYMMDD_HHMMSS_<logItem>_<serial>.csv(.xz)` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | 디렉토리 내 전체 파일명이 정규식 일치 | boolean | 0 | `ls /edge/log/device_log/<logItem>/ \| grep -vE '^[0-9]{8}_[0-9]{6}_[0-9]{8}_[0-9]{6}_.+_.+\.csv(\.xz)?$' \| wc -l` |

---

## TC05 — 파일 생성 주기(logCreationTime) 정확성

### 목적

파일명의 `<startTime>`~`<endTime>` 간격이 `logpolicy.json`의 `logCreationTime` ±5%
이내인지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- `logCreationTime`이 짧은 **주기적(non-fault)** log_item 선정 — 본 벤치 기준 non-fault
  logItem 중 최솟값은 21600초(6시간, 예: `PMU_Monitoring`). fault류(180초)는 이벤트
  기반이라 본 TC 대상에서 제외
- 대상 log_item에 텔레메트리가 도착 중인 상태

### 절차

1. 대상 log_item의 현재 활성 파일명에서 `<startTime>` 기록
2. `logCreationTime`(21600초) + 여유시간(예: 5분)만큼 실시간 대기 — device_log 재시작이나
   시스템 시각 조작(`date -s`) 없이 자연 경과만으로 진행 (짧은 주기 log_item을 고른 이유)
3. rotation으로 생성된 신규 파일명에서 `<startTime>`/`<endTime>` 추출, 차이(초) 계산

### 기대 결과

| 항목 | 기준 |
|------|------|
| start~end 간격 | `logCreationTime` ± 5% 이내 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC05-1 | 간격이 logCreationTime ±5% | boolean | true | `[ "$diff" -ge "$((ct*95/100))" ] && [ "$diff" -le "$((ct*105/100))" ]` |

---

## TC06 — 재부팅 후 로깅 재개 (동일 파일 이어쓰기)

### 목적

재부팅 시점에 활성 CSV의 `endTime`이 아직 지나지 않았다면, 새 파일을 만들지 않고 동일
파일에 로깅을 재개하는지 확인한다 (`createFileDirectoryForAllRules()` Case A —
`log_policy_manager.cpp`).

### 사전 조건

- 공통 전제 조건 충족
- `logCreationTime`이 긴 log_item(예: `EMSP_Installation`, 86400초) 선택 — 재부팅 시점에
  endTime 미도과 보장 용이

### 절차

1. 대상 log_item의 현재 활성 CSV 파일명(`<start>_<end>_...`) 기록
2. DUT 재부팅 (`reboot`), device_log 재기동 대기
3. 재부팅 후 동일 log_item 디렉토리의 활성 CSV 파일명 재확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 파일명 | 재부팅 전후 동일 (새 파일 미생성) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | 재부팅 전후 파일명 동일 | boolean | true | `[ "$name_before" = "$name_after" ]` |

---

## TC07 — 재부팅 후 빈 행 삽입

### 목적

재부팅 후 기존 파일에 로깅을 재개할 때, 헤더 유실 없이 빈 행(구분자)이 삽입된 후
로깅이 재개되는지 확인한다 (`writeFileHeaderWithColumnsName()` Case A —
`log_policy_manager.cpp:writeCsvRow({})`).

### 사전 조건

- 공통 전제 조건 충족 + TC06과 동일 대상 log_item

### 절차

1. TC06 절차로 재부팅 전 파일에 데이터 행이 최소 1개 존재함을 확인
2. 재부팅 후 동일 파일의 재부팅 시점 직후 라인들을 확인
3. 재부팅 전 마지막 데이터 행과 재부팅 후 첫 데이터 행 사이에 빈 줄(구분자)이 있는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 구분자 | 재부팅 전/후 데이터 행 사이에 빈 줄 1개 삽입 |
| 헤더 | 파일 최상단 헤더는 유지(재작성 없음) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | 재부팅 경계에 빈 줄 존재 | boolean | true | `sed -n "${boundary_line}p" "$csv" \| grep -qE '^$'` |
| TC07-2 | 헤더 라인 유지 | boolean | true | `head -1 "$csv" \| diff - <(echo "$header_before")` |

---

## TC08 — 외부 디바이스 연결 해제/재연결 시 빈 행 삽입 (§AGSRS-548 미구현 확인)

### 목적 (요구사항 §AGSRS-548)

CAN 등 외부 디바이스 연결이 끊겼다가 재연결될 때 로깅 파일에 빈 행이 삽입된 후 로깅이
재개되는지 확인한다. **본 TC는 아래 코드 근거상 §AGSRS-548이 구현되어 있지 않음을
확인하는 목적이며, DUT 실측 없이도 FAIL이 확정적이다.**

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. 대상 log_item의 활성 CSV에 데이터가 기록 중임을 확인
2. `mosquitto_pub`으로 `device_connection`(`NOTI_DEVICE_CONNECTION`) 알림을
   `{"protocol":"CAN","connected":false}` 페이로드로 발행 (연결 해제 재현)
3. `logRowInterval` 수 배 대기 후 `{"protocol":"CAN","connected":true}` 발행 (재연결
   재현)
4. 연결 해제~재연결 구간에서 CSV에 빈 행이 삽입되었는지 확인
5. `journalctl -u docker-loader --no-pager | grep "CAN connection state"`로 알림이
   실제로 수신되었는지 확인 (수신은 되지만 CSV에는 반영 안 될 것으로 예상) — 단,
   이 로그는 `LOG(DEBUG)`이므로 사전에 `system_setting.log_level_dl`을 0(DEBUG)로
   낮춰야 한다(아래 Flag 참고). 확인 후 원래 레벨로 원복할 것.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 빈 행 | (요구사항 AC) 연결 해제~재연결 구간에 빈 행 삽입 후 정상 로깅 재개 |
| 실제 코드 동작 | 알림은 수신되나(DEBUG 로그만 기록) CSV에는 어떤 변화도 없을 것으로 예상 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | 연결 해제 구간 빈 행 존재 (요구사항 AC 기준, 예상 FAIL) | boolean | true | `sed -n "${boundary_line}p" "$csv" \| grep -qE '^$'` |
| TC08-2 | device_connection 알림 수신 확인(참고용) | boolean | true | `journalctl -u docker-loader --no-pager \| grep -q "CAN connection state"` |

> **주의 (Flag, 미구현 확정):** `device_log.cpp:311`에서 `NOTI_DEVICE_CONNECTION`
> (서비스명 `device_connection`) 알림을 실제로 구독하고 있으나, 핸들러
> `handle_noti_device_connection()`(`device_log.cpp:639-644`)은 `protocol=="CAN"`일 때
> `LOG(DEBUG) << "CAN connection state: ..."` 한 줄만 남기고 끝난다.
> `LogPolicyManager`를 호출하지도, CSV에 어떤 조치도 하지 않는다. 빈 행 삽입은
> `writeFileHeaderWithColumnsName()` Case A에서 **재부팅 후 기존 파일을 재사용할 때만**
> 발생(TC07과 동일 코드 경로)하며, 연결 해제/재연결과는 무관하다. 즉 §AGSRS-548은
> 알림 수신 경로만 있고 실제 동작은 구현되어 있지 않음 — Jira 재확인/개발 이슈 등록
> 대상으로 보고할 것을 권장한다.

> **주의 (Flag, 정정 — 2026-08-21 실측):** TC08-2는 기본 설정에서 100% FAIL이
> 확정적이었다 — `edge_logger.cpp:63`의 기본 로그 레벨이 INFO(1)이고
> `factory_register_map.json`의 `log_level_dl` factory 기본값도 1(INFO)이라
> DEBUG(0) 로그가 걸러진다. `handle_noti_system_settings_changed()`
> (`device_log.cpp:233-251`)가 `log_level_dl` 변경을 재시작 없이 즉시 반영하므로,
> db_manager TC04/edge_runtime TC와 동일하게 `update_records`로 `log_level_dl=0`을
> 임시로 설정한 뒤 확인하고 원복하는 절차로 정정했다.

---

## SID0203 — Automatic file deletion

## TC09 — Archive 파일 개수(fileCount) 초과 시 FIFO 삭제

### 목적

`archive/<logItem>/` 파일 수가 `logpolicy.json`의 `fileCount`를 초과하면 가장 오래된
파일부터 삭제되는지 확인한다 (`deleteArchFileBasedOnCount()` —
`cloud_upload_manager.cpp:1615`).

### 사전 조건

- 공통 전제 조건 충족
- 실기 정책은 `fileCount=700`이라 대량 파일 생성이 비현실적 — DUT의 실제 정책 파일
  (`/edge/etc/app-config/device_log/rules/logpolicy.json`, podman 컨테이너 내부 경로이므로
  `nsenter -t $(pgrep -f device_log) -m` 또는 `docker exec -it ac_system_gen2`로 진입해
  수정)에서 대상 log_item의 `fileCount`를 임시로 작은 값(예: 5)으로 직접 수정 후, 적용을
  위해 컨테이너를 재시작(`systemctl restart docker-loader`)

### 절차

1. 대상 log_item(archive 폴더 대상)의 원래 `fileCount` 값을 백업 기록
2. `logpolicy.json`에서 해당 log_item의 `fileCount`를 작은 값(예: 5)으로 수정
3. `systemctl restart docker-loader`로 재기동해 변경된 정책 반영
4. `archive/<logItem>/`에 수정된 `fileCount`(5)보다 많은 파일이 쌓이도록 로그 생성/rotation
   반복 대기 (또는 기존 archive 파일 재활용)
5. `archiveToUpload()` 사이클(idle thread, 5초 주기) 대기
6. `archive/<logItem>/` 파일 수와 잔존 파일의 mtime 확인
7. `logpolicy.json`의 `fileCount`를 원래 값으로 복원 후 `systemctl restart docker-loader`로
   재적용해 원상복구

### 기대 결과

| 항목 | 기준 |
|------|------|
| 파일 수 | 수정된 `fileCount`(5) 이하로 수렴 |
| 삭제 순서 | 가장 오래된(mtime 최소) 파일부터 삭제(FIFO) |
| 복원 | 시험 종료 후 `fileCount` 원복 및 컨테이너 재시작 확인 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | 파일 수가 수정된 fileCount(5) 이하 | boolean | true | `[ "$(ls "$archive_dir" \| grep -c '\.csv\.xz$')" -le 5 ]` |
| TC09-2 | 가장 오래된 파일 삭제됨 | boolean | true | `[ ! -f "$oldest_file" ]` |
| TC09-3 | fileCount 원복 확인 | boolean | true | `grep -A2 "\"logItem\": \"$log_item\"" logpolicy.json \| grep '"fileCount"' \| grep -q ": *$original_count"` |

---

## TC10 — Archive 파일 보관기간(retentionTime) 초과 삭제

### 목적

`archive/<logItem>/` 내 파일의 나이가 `logpolicy.json`의 `retentionTime`을 초과하면
삭제되는지 확인한다 (`deleteArchFileBasedOnTime()` — `cloud_upload_manager.cpp:1676`).

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `archive/<logItem>/`에 파일명 규칙에 맞는 더미 `.csv.xz`+`.meta` 파일 1개 생성
2. `docker-loader` 재시작 — 재시작 시점의 `enumerateExistingFilesInDirectory()`가
   archive 디렉토리를 다시 스캔하므로, 이 시점에 존재하는 더미 파일도 앱의
   `arch_dir_files_` 추적 큐에 정식 등록된다
3. 그 더미 파일에 `touch -d`로 mtime을 `retentionTime` 초과 시점으로 강제 설정
4. `archiveToUpload()` 사이클 대기
5. 해당 더미 파일의 삭제 여부 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 만료 파일 | retentionTime 초과 파일 삭제됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC10-1 | 만료 파일 삭제 확인 | boolean | true | `[ ! -f "$expired_file" ]` |

> **주의 (Flag, 정정 이력):** 2026-08-21 실측에서는 디스크에 직접 만든 더미 파일이
> `CloudUploadManager::arch_dir_files_` 인메모리 큐에 등록되지 않아(부팅 시 1회만
> 채워짐, `enumerateExistingFilesInDirectory()` — `cloud_upload_manager.cpp:107`)
> `deleteArchFileBasedOnTime()`(`:1701-1705`)이 더미 파일의 존재 자체를 몰라 삭제되지
> 않는 문제가 있어, 앱이 정식 경로(`get_log_data`)로 옮긴 실제 파일을 쓰도록 정정한
> 바 있다. 이후 "더미 파일 생성 후 docker-loader를 재시작"하는 방식으로 다시
> 정정했다 — TC09이 이미 이 방식(더미 파일 생성 → 재시작 → FIFO 삭제 검증 성공)을
> 쓰고 있으므로, "부팅 시 1회"는 프로세스 최초 기동이 아니라 **재시작 시점마다**를
> 의미한다는 것이 확인됐다. 재시작을 매개로 하면 디스크에 직접 만든 더미 파일도
> 정식으로 큐에 등록되므로, 네트워크 차단 없이 더미 파일 생성만으로 재현 가능하다.

---

## SID0204 — Cloud upload and deletion

## TC11 — 업로드 성공/실패 journal 기록

### 목적

파일 업로드가 시도되면 성공/실패 로그 중 해당하는 하나가 journal에 기록되는지
확인한다 (`handleFileUploadResult()` — `cloud_upload_manager.cpp:241`). 실제 동작상 한
번의 업로드 시도에는 성공 또는 실패 로그 중 하나만 찍히므로, 양쪽을 모두 강제로
재현할 필요 없이 둘 중 하나가 존재하면 PASS로 판정한다.

### 사전 조건

- 공통 전제 조건 충족, `journalctl` 접근 가능

### 절차

1. 임의 log_item 파일을 toupload로 이동시키는 대신, `toupload/<logItem>/` 폴더 자체에
   파일명 규칙에 맞는 dummy `.csv.xz`+`.meta` 파일 1개를 직접 생성 — 실제 로그
   데이터가 아닌 최소한의 트리거만으로 BlobUploadDirector의 스캔 대상이 되도록 함
2. `journalctl -u docker-loader --no-pager | grep -iE "Upload success for log item|Upload fail for log item"`
   로 성공/실패 로그 중 하나가 기록되는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| journal 기록 | `Upload success for log item` 또는 `Upload fail for log item` 중 하나 이상 기록 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC11-1 | 성공/실패 로그 중 하나 기록 | boolean | true | `journalctl -u docker-loader --no-pager \| grep -qE "Upload success for log item|Upload fail for log item"` |

---

## TC12 — 다수 로그 파일 Azure 업로드 시도 확인

### 목적

하나의 log_item에서 toupload로 이동된 다수의 파일이 실제로 Azure 업로드가 시도되는지
`cloud_broker`(로그 태그 `CB`)의 `BlobUploadDirector`(`blob_upload_director.cpp`) journal
로그로 확인한다. `BlobUploadDirector`는 device_log와 동일한 `/edge/log/toupload`를
직접 스캔해 `.meta` 파일을 찾는다(`kUploadRoot` — `blob_upload_director.hpp:85`). 실제
Azure Blob 전송 자체는 `azure_connector`(별도 앱, IPC로 위임)가 수행하지만, device_log
관점에서 "업로드가 시도되었는지"는 cloud_broker의 `[Director]` 로그로 확인하는 것이
정확하다.

> **주의 (Flag, 정정 — 2026-08-21 실측):** 위 "발견하는 즉시 업로드를 시도한다"는
> 표현은 부정확했다. `BlobUploadDirector::scan_loop_task()`는 이벤트 트리거 없이
> `kScanIntervalSec = 300`초(`blob_upload_director.hpp:86`) 고정 주기로만 스캔한다
> (`blob_upload_director.cpp:66-76`). 즉 파일이 toupload에 막 도착해도 다음 스캔까지
> 최대 300초를 기다려야 `[Director]` 로그에 등장한다 — TC11/TC12 셸 검증 시
> 이 300초를 반드시 감안해 폴링 대기해야 한다(짧은 고정 sleep으로는 100% FAIL).

### 사전 조건

- 공통 전제 조건 충족, 네트워크 연결

### 절차

1. 대상 log_item 1개를 선정해 파일 3개 이상을 `toupload/`로 이동시키는 대신,
   `toupload/<logItem>/` 폴더 자체에 dummy `.csv.xz`+`.meta` 파일 3개를 직접 생성
   (파일명이 서로 겹치지 않도록 시각/시리얼을 다르게 부여)
2. `journalctl -u docker-loader --no-pager | grep '\[Director\]'`로 cloud_broker의
   업로드 시도 로그에서 3개 파일명 각각이 등장하는지 확인 — BlobUploadDirector의
   300초 고정 스캔 주기를 감안해 최대 310초까지 폴링 대기할 것

### 기대 결과

| 항목 | 기준 |
|------|------|
| 업로드 시도 | toupload로 이동한 3개 파일명 각각에 대해 `[Director]` 업로드 시도/완료 로그 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC12-1 | 3개 파일 각각 업로드 시도 로그 확인 | boolean | true | `for f in "${files[@]}"; do journalctl -u docker-loader --no-pager \| grep '\[Director\]' \| grep -q "$f" \|\| exit 1; done` |

---

## TC13 — 네트워크 끊김 시 업로드 미시도 및 archive 누적

### 목적 (요구사항 §AGSRS-536, §AGSRS-537)

네트워크 오프라인 상태에서 root의 압축 파일이 idle thread에 의해 toupload와 archive
중 어디로 이동하는지 확인한다 (`rootToArchiveOrToUpload()` —
`cloud_upload_manager.cpp:816`).

> **병합 이력:** 별도 TC였던 "네트워크 중단 시 업로드 동작(root→archive 이동,
> §AGSRS-537)"은 검증 시나리오가 본 TC와 동일하여(네트워크 오프라인 상태에서 신규
> root 파일이 archive로 이동하는지) 여기로 통합되었다. 유일한 차이는 "toupload가
> 이미 비어있지 않은 상태(`isToUploadDirEmpty()`=false)에서 네트워크가 끊기는 경우"
> 였는데, 이는 아래 절차의 부가 확인 단계로 흡수했다. 별도 번호를 갖지 않고 본 TC로
> 흡수되었다.

### 사전 조건

- 공통 전제 조건 충족
- 현재 네트워크 상태 확인: 온라인이면 네트워크 차단(`iptables` 또는 물리적 단선) 수행,
  **이미 오프라인 상태이면 별도로 차단하지 않고 그대로 진행**

### 절차

1. (부가 확인, §AGSRS-537 흡수분) 네트워크 연결 상태에서 파일 1개를 toupload로
   이동시켜 둠 (`isToUploadDirEmpty()`가 false인 상태에서도 동일하게 동작하는지 함께
   확인)
2. 현재 네트워크 상태 확인 (온라인이면 위 사전조건대로 차단, 오프라인이면 skip)
3. 로그 생성 → `forced_log_upload` IPC로 root에 `.csv.xz` 생성
4. idle thread 사이클(5초) 대기
5. `toupload/`, `archive/` 두 디렉토리를 모두 조회해 신규 파일이 실제로 어느 쪽으로
   이동했는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 이동 위치 | 네트워크 오프라인 상태이므로 파일이 `archive/`로 이동 (실제 관찰 결과를 근거로 판정) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC13-1 | 신규 파일 이동 위치 확인 | boolean | archive | `if [ -f "$toupload_dir/$fname" ]; then echo toupload; elif [ -f "$archive_dir/$fname" ]; then echo archive; else echo none; fi` |

> **주의 (Flag, 정정, 병합분 인계):** device_log(`cloud_upload_manager.cpp`)
> 자체에는 고정 횟수(10회) 재시도 카운터가 없다 — `isInternetAvailable()`이 false면
> 즉시 archive로 이동시키고 이후 `uploadIdleThread()`의 5초 주기 무한 루프로 toupload
> 이동만 재시도한다(횟수 제한 없음). **"업로드 10회 재시도"는 device_log가 아니라
> toupload 이후 실제 업로드를 수행하는 `cloud_broker`(로그 태그 `CB`)의
> `BlobUploadDirector`에 구현되어 있다** — `blob_upload_director.cpp:26`의
> `kRetrySec{5,10,20,40,80,160,320,640,1280,2560}`(정확히 10개 값, 지수 백오프)와
> `retry_or_delete()`(`:233`)가 그 로직이다. `BlobUploadDirector`는 device_log와 동일한
> `/edge/log/toupload`를 스캔하므로(`blob_upload_director.hpp:85` `kUploadRoot`)
> device_log가 만든 파일도 여기서 재시도된다. 10회 초과 시 파일을 삭제하고
> `NOTI_FILE_UPLOAD_RESULT`(result=fail)를 device_log로 돌려보내는데, 이것이 TC11의
> "Upload fail for log item" 로그가 실제로 발생하는 경로다. 따라서 "10회 재시도" 자체의
> 검증은 device_log 단독 TC가 아니라 cloud_broker 쪽 TC 명세에서 다뤄야 하며, 본
> TC(TC13-1)는 device_log 책임 범위(root→archive 이동)만 검증한다.

---

## SID0205 — Handling network disruption

## TC14 — 네트워크 복구 시 자동 업로드 재개

### 목적 (요구사항 §AGSRS-513, §AGSRS-540)

네트워크 차단→복구 시 archive에 쌓인 파일들이 자동으로 toupload로 이동하는지 확인한다
(`cloud_connected_action()` — `cloud_upload_manager.cpp:449`).

> **병합 이력:** 별도 TC였던 "로컬 파일(archive) 업로드 주기적 재시도(§AGSRS-540)"는
> "네트워크가 연결된 상태에서 archive 파일이 idle thread에 의해 toupload로 이동하는지"
> 검증하는 것으로, 본 TC의 "복구 후 archive→toupload 이동" 검증과 동일한
> 관찰 대상(archive→toupload 이동)이라 여기로 통합되었다. 별도 번호를 갖지 않고 본
> TC로 흡수되었다.

### 사전 조건

- 공통 전제 조건 충족, TC13로 archive에 파일이 누적된 상태
- `logcount.json`의 대상 log_item `perDayArchive` > 0 (0이면 사전에 임시로 5 등으로
  설정 후 docker-loader 재시작 — 아래 Flag 참고)

### 절차

1. archive에 파일이 1개 이상 누적된 상태 확인
2. 네트워크 복구
3. `mosquitto_pub`으로 `internet_status` notification을 `{"connected":true}` 페이로드로
   강제 발행 — 실제 네트워크 폴링 주기를 수동적으로 기다리는 대신 `cloud_connected_
   action()`을 직접 트리거해 결정론적으로 재현
4. `archive/` → `toupload/` 이동 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| toupload 이동 | archive의 파일이 toupload로 이동, Azure 업로드 결과 확인(TC11/13 연계) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC14-1 | archive→toupload 이동 확인 | boolean | true | `[ ! -f "$archive_dir/$fname" ] && [ -f "$toupload_dir/$fname" ]` |

> **주의 (Flag):** `internet_status` notification의 정확한 payload 필드명/스키마는
> 코드에서 아직 확인되지 않았다(device_connection의 `{"protocol":..,"connected":..}`
> 패턴을 참고해 `{"connected":true}`로 잠정 구현) — 최초 실행 시 journal에서 실제
> 수신/반응 여부를 확인하고 다르면 정정할 것.

---

## TC15 — 재부팅 후 업로드 재개

### 목적

toupload에 파일이 남아있는 상태로 재부팅해도, 재기동 후 자동으로 업로드가 재개되는지
확인한다 (`enumerateExistingFilesInDirectory()`/`init()` — `cloud_upload_manager.cpp:96`).

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. toupload에 `.xz`+`.meta` 쌍이 존재하는 상태 확인 (업로드 완료 전 시점 포착이
   어려우면 네트워크를 잠시 차단한 채로 toupload에 파일을 둔 뒤 재부팅)
2. DUT 재부팅
3. 재기동 후 device_log가 toupload 파일을 인식하고 업로드를 재개하는지 확인
   (`journalctl`에서 업로드 성공 로그 또는 파일 소멸 확인)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 업로드 재개 | 재부팅 후 별도 수동 조치 없이 toupload 파일 업로드 처리됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC15-1 | 재부팅 후 toupload 파일 처리됨 | boolean | true | `journalctl -b 0 -u docker-loader \| grep -q "Upload success"` |

---

## SID0206 — Upload with data traffic calculation

## TC16 — 1일 root 폴더 업로드 개수 제한

### 목적

`logcount.json`의 대상 log_item `perDayRoot`를 0으로 설정하면, root의 압축 파일이
toupload로 이동하지 않고 archive로만 이동하는지 확인한다 (`isUploadAllowed()` —
`cloud_upload_manager.cpp:1338`).

### 사전 조건

- 공통 전제 조건 충족, `logcount.json` 편집 권한

### 절차

1. 대상 log_item의 `perDayRoot`를 0으로 설정 (`logcount.json` 직접 수정 또는 IPC)
2. 로그 생성 → root에 `.csv.xz` 발생
3. idle thread 사이클 대기 후 `toupload/`, `archive/` 상태 확인
4. 23:50(자정 루틴, TC18) 도달 시 `perDayRoot`가 `defaultPerDay`로 초기화되는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| toupload | 이동 없음 |
| archive | 이동됨 |
| 익일 초기화 | 자정 루틴 후 perDayRoot = defaultPerDay |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC16-1 | toupload 미이동 | boolean | true | `[ ! -f "$toupload_dir/$fname" ]` |
| TC16-2 | archive 이동 확인 | boolean | true | `[ -f "$archive_dir/$fname" ]` |

---

## TC17 — 1일 archive 폴더 업로드 개수 제한

### 목적 (요구사항 §AGSRS-543)

`perDayRoot`, `perDayArchive`를 모두 0으로 설정하면 archive에서도 업로드가 시도되지
않는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. 대상 log_item의 `perDayRoot=0`, `perDayArchive=0`으로 설정
2. 로그 생성 → root 파일 발생 → archive로 이동 확인(TC16와 동일 경로)
3. idle thread 사이클 반복 대기 후 archive → toupload 이동이 발생하지 않음을 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| toupload | archive 파일이 toupload로 이동하지 않음 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC17-1 | toupload 미이동 유지 | boolean | true | `[ ! -f "$toupload_dir/$fname" ]` |

> **주의 (Flag, 정정 — 2026-08-21 실측, TC14/TC16/TC17 공통):** 두 가지를
> 놓쳐 이전 실행에서 TC14-1/TC16-1이 FAIL했다(TC17은 아래 2번의 측정
> 순서가 우연히 어긋나지 않아 PASS했을 뿐, 같은 결함을 안고 있었다).
> 1. **재시작 필요:** `logcount.json`(perDayRoot/perDayArchive)은
>    `CloudUploadManager::init()`에서 `initialized_` 가드로 부팅 시 1회만 읽는다
>    (`cloud_upload_manager.cpp:103-108`). 파일만 고쳐서는 런타임에 반영되지 않고,
>    TC09(logpolicy.json/fileCount)과 동일하게 `docker-loader` 재시작이 필요하다.
>    TC14은 또한 `perDayArchive`가 기본 0(자정 롤오버 전에는 항상 0,
>    `updateLogUploadLimitsDaily()` 참고)이라 사전에 0보다 크게 설정 + 재시작해
>    둬야 archive→toupload 이동 자체가 정책적으로 허용된다.
> 2. **`get_log_data`(forced_log_upload)는 게이트를 우회한다:**
>    `handleForcedLogUploadRequest()`는 `moveFilesToUploadDir()`를 직접 호출하며
>    `isUploadAllowed()`(perDayRoot/perDayArchive 검사)를 거치지 않는다
>    (`cloud_upload_manager.cpp:399-423`) — "강제" 업로드이므로 정책 게이트를
>    우회하는 것이 설계 의도다. TC16/TC17처럼 perDayRoot=0의 효과를 검증하려면
>    네트워크를 차단한 채 `get_log_data`를 호출해(파일이 root 대기열에만 쌓이고
>    실제 이동은 발생하지 않음) 이후 네트워크를 복구, idle thread의
>    `rootToArchiveOrToUpload()`(이 경로는 `isUploadAllowed()`를 거침)가 처리하도록
>    유도해야 한다. TC21 절차(위 34-40행 주석)가 이미 쓰던 기법과 동일하다.

---

## TC18 — 자정 루틴: perDayRoot 초기화 및 잔여 quota archive 이월

### 목적

매일 `midNightCheckHrs:midNightCheckMins`(기본 23:50)에 `updateLogUploadLimitsDaily()`가
실행되어, 남은 `perDayRoot`가 `perDayArchive`로 이월되고 `perDayRoot`는
`defaultPerDay`로 초기화되는지 확인한다 (`cloud_upload_manager.cpp:1409`).

### 사전 조건

- 공통 전제 조건 충족, 시스템 시간 변경 권한

### 절차

1. 대상 log_item의 `perDayRoot`, `perDayArchive` 초기값 기록
2. 시스템 시각을 23:49로 설정
3. 23:50 도달 대기(또는 시각 전진)하여 자정 루틴 실행 확인
4. `logcount.json`에서 `perDayArchive_after == perDayArchive_before + perDayRoot_before`,
   `perDayRoot_after == defaultPerDay` 확인
5. 동시에 `midNightRootToUpload()`/`midNightArchiveToUpload()`로 root/archive에서
   toupload로의 이동(각 폴더 일일 한도 내)도 확인 (§AGSRS-544)
6. 시스템 시각 원복

### 기대 결과

| 항목 | 기준 |
|------|------|
| perDayArchive | 이전 perDayArchive + 이전 perDayRoot |
| perDayRoot | defaultPerDay로 초기화 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC18-1 | perDayArchive 이월 계산 일치 | boolean | true | `[ "$archive_after" -eq "$((archive_before + root_before))" ]` |
| TC18-2 | perDayRoot 초기화 | boolean | true | `[ "$root_after" -eq "$default_per_day" ]` |

---

## TC19 — 월 전환 시 로그 카운트 초기화

### 목적

월이 바뀌는 시점에는 일일 초기화 대신 `updateLogUploadLimitsMonthly()`가 실행되어
`perDayRoot=defaultPerDay`, `perDayArchive=0`으로 리셋되는지 확인한다
(`cloud_upload_manager.cpp:1432`).

### 사전 조건

- 공통 전제 조건 충족, 시스템 시간 변경 권한

### 절차

1. 시스템 시각을 월말 23:49(예: `2027-03-31 23:49:00`)로 설정
2. 23:50 자정 루틴 도달 대기 (월 전환 조건: `isMonthTransition()` — 현재 시각 ±60분 내
   월이 바뀌는지 확인)
3. `logcount.json`에서 `perDayRoot == defaultPerDay(10)`, `perDayArchive == 0` 확인
4. 시스템 시각 원복

### 기대 결과

| 항목 | 기준 |
|------|------|
| perDayRoot | defaultPerDay(10)로 초기화 |
| perDayArchive | 0으로 초기화 (이월 없음, 월간 리셋은 daily와 달리 완전 초기화) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC19-1 | perDayRoot=defaultPerDay | boolean | true | `[ "$root_after" -eq 10 ]` |
| TC19-2 | perDayArchive=0 | boolean | true | `[ "$archive_after" -eq 0 ]` |

---

## TC20 — 재부팅 후 업로드 설정 파일(logcount.json) 유지

### 목적

재부팅 후에도 `logcount.json`의 `perDayRoot`/`perDayArchive` 값이 그대로 유지되는지
확인한다 (`readLogCountJson()`/`writeToLogCountJson()`).

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. 임의 log_item의 `perDayRoot`/`perDayArchive` 값을 변경 (업로드 1회 발생시켜 카운트
   증감 유도)
2. 변경된 값을 기록
3. DUT 재부팅
4. 재기동 후 `logcount.json` 값을 재확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 값 유지 | 재부팅 전후 perDayRoot/perDayArchive 동일 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC20-1 | 값 유지 확인 | boolean | true | `[ "$root_before" -eq "$root_after" ] && [ "$archive_before" -eq "$archive_after" ]` |

---

## TC21 — 라운드로빈 기반 균등 업로드 선택 확인

### 목적 (요구사항 §AGSRS-498 AC1 관련)

`selectNextRootLogType()`가 여러 log_item에 pending 파일이 있을 때 특정 log_item에
편중되지 않고 골고루(라운드로빈) 선택하는지 확인한다. 요구사항 AC1은 "high-priority
logs first"를 명시하지만, `logpolicy.json`/`logcount.json`에 우선순위 필드가 없어
실제 구현은 우선순위가 아닌 라운드로빈이다(아래 Flag 참고). 본 TC는 우선순위 대신
**라운드로빈의 균등성(공정성, 특정 log_item 편중/기아 없음)**을 검증 대상으로 삼는다.

### 사전 조건

- 공통 전제 조건 충족
- 텔레메트리가 도착 중인 log_item 3개 이상 (본 벤치 기준: EMSP_Maintenance,
  EMSP_Installation, PMU_Monitoring, MI_Monitoring, MI_Device_Info, Meter,
  C_Box_Monitoring 중 선택)

### 절차

1. `forced_log_upload` IPC를 짧은 간격으로 3회 반복 발행해 대상 log_item들 각각에
   root 대기 파일을 여러 개 쌓아둠
2. idle thread 사이클(5초 주기)마다 각 log_item의 `toupload/<logItem>/` 파일 수를
   능동적으로 폴링해, 어느 사이클에 어느 log_item이 선택됐는지 시퀀스로 기록한다.
   고정된 긴 대기(예: 전체 log_type 수 × 2바퀴) 없이, 대상 log_item 전원이 최소
   1회 이상 시퀀스에 등장하는 즉시 조기 종료해 수행시간을 단축한다
3. 기록된 선택 시퀀스로 (a) 대상 log_item 전원이 관측 창에서 최소 1회 이상
   선택됐는지, (b) 동일 item이 연속 사이클에서 뭉쳐 선택되다 다른 item으로
   전환되는 패턴을 보이는지(수동 확인) 판정

> **주의 (Flag, 정정 이력):** `selectNextRootLogType()`은 대상으로 고른 5개
> log_item만 도는 게 아니라 `log_type_keys_`(logpolicy.json 전체 loggingRules, 이
> DUT에서 32개) 전체를 라운드로빈한다(cloud_upload_manager.cpp:1310-1322). 과거에는
> 이 때문에 "전체 log_type 수 × 2바퀴"만큼 고정 sleep으로 기다렸으나(32×2×5+30=350초),
> 능동 폴링 방식으로 바꾸면서 대상 log_item 전원이 관측되는 즉시 종료하도록 해
> 수행시간을 단축했다(사이클마다 즉시 확인하므로 전체 바퀴를 다 돌 때까지 기다릴
> 필요가 없어짐). 또한 archive/root→toupload 이동은 `isToUploadDirEmpty(log_type)`도
> 함께 요구하므로(cloud_upload_manager.cpp:826,860), 앞선 TC가 특정 log_item의
> toupload에 미처리 파일을 남겨둔 채 이 TC를 이어서 실행하면 라운드로빈 선택 자체는
> 일어나도 toupload 카운트에는 반영되지 않을 수 있다 — 가능하면 `--tc21` 단독 실행
> 권장.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 선택 분포 | 특정 log_item에 편중되지 않고 관측 창 내에서 대상 log_item 전원이 최소 1회 이상 선택됨 (기아 없음) |
| 선택 패턴(참고) | 동일 log_item이 연속 사이클에서 뭉쳐 선택되다 다른 item으로 전환되는 패턴(수동 확인) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC21-1 | 대상 log_item 전원이 관측 창에서 최소 1회 이상 선택됨(편중/기아 없음) | boolean | true | 사이클마다 `toupload/<item>/` 파일 수 증가를 기록한 시퀀스에 모든 대상 item이 등장하는지 확인 |
| TC21-2 | 선택 전환 패턴(연속 뭉침 후 전환) 확인 | manual | — | 기록된 선택 시퀀스를 evidence로 남겨 수동 확인 |

> **주의 (Flag, 정정):** `selectNextRootLogType()`/`selectNextArchLogType()`
> (`cloud_upload_manager.cpp:1310` 부근)을 확인한 결과, `log_type_keys_` 배열을
> `root_log_index_`로 순환하는 **라운드로빈** 방식이며 우선순위 필드나 정렬 로직은
> 없다. `logpolicy.json`/`logcount.json`에도 priority 필드가 없다. "High-priority logs
> first"는 현재 코드에 구현되어 있지 않지만, 사용자 확인 결과 본 TC의 검증 목표는
> 우선순위 자체가 아니라 **라운드로빈이 특정 log_item을 굶기지 않고 골고루 도는지**로
> 재설정되었다. AC1과의 격차(우선순위 미구현)는 별도로 사용자/Jira에 보고할 사항이다.

---

## SID0207 — System monitoring & reporting

## TC22 — 웹 강제 업로드 (forced_log_upload IPC)

### 목적

현재 기록 중인 활성 CSV 파일을 IPC 요청으로 즉시 강제 업로드할 수 있는지 확인한다
(`SERVICE_GET_LOG_DATA` → `handle_request_forced_log_upload()` — `device_log.cpp:463`,
`CloudUploadManager::handleForcedLogUploadRequest()` — `cloud_upload_manager.cpp:314`).

### 사전 조건

- 공통 전제 조건 충족, root에 아직 회전되지 않은 활성 CSV(데이터 행 1개 이상) 존재

### 절차

1. 대상 log_item의 활성 CSV 데이터 행 존재 확인
2. `mosquitto_pub`으로 `SERVICE_GET_LOG_DATA`(`get_log_data`) 요청 발행
3. 응답(OK) 수신 확인
4. `/edge/log/toupload/device_log/<logItem>/` 에 신규 `.xz`+`.meta` 생성 확인
5. Azure 업로드 결과 확인 (TC11/13 연계)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 | IPC 응답 OK 수신 |
| 파일 | 활성 CSV가 즉시 회전·압축되어 toupload로 이동 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC22-1 | IPC 응답 OK | boolean | true | `echo "$resp" \| grep -q '"error_code":0'` |
| TC22-2 | toupload에 신규 파일 생성 | boolean | true | `[ "$(ls "$toupload_dir" | wc -l)" -gt "$before_count" ]` |

---

## SID0208 — Mass Production Feature (EOL)

## TC23 — EOL 로그 생성 (1초/1분 개별 파일)

### 목적

Factory EOL Mode ON 시 `/edge/log/eol/`에 `eol_1sec.csv`, `eol_1min.csv`가 각각
1초/1분 주기로 행이 추가되는지 확인한다 (`EolLogger::processEolLogging()` —
`eol_logger.cpp:155`, `eolpolicy.json`). **`eol_10min`은 정책에서 삭제되어 본 TC 대상에서
제외한다** (`eolpolicy.json` 확인 결과 현재 `loggingRules`는 `eol_1min`, `eol_1sec` 2개만
존재).

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. **[피드백 반영] EOL 모드를 켜기 전에 먼저 telemetry notification이 실제 column
   데이터를 담아 도착 중인지 확인**(`Meter`의 최신 CSV 행에서 non-empty 컬럼 수로
   판정) — EOL 로그가 안 늘어나는 원인이 "EOL 기능 문제"인지 "애초에 telemetry가
   안 옴"인지 구분하기 위함. TC24/28/30도 이 확인을 동일하게 선행한다
2. `mosquitto_pub`으로 `SERVICE_SET_FACTORY_EOL_MODE`(`set_factory_eol_mode`)
   `{"eol_mode": true}` 발행
3. 2~5분 대기하며 텔레메트리 publish 지속
4. `/edge/log/eol/eol_1sec.csv`, `eol_1min.csv` 각각의 행 수와 마지막 행 시각 확인
5. `set_factory_eol_mode` `{"eol_mode": false}` 발행하여 종료

### 기대 결과

| 항목 | 기준 |
|------|------|
| eol_1sec.csv | 1초 간격으로 행 추가 |
| eol_1min.csv | 1분 간격으로 행 추가 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC23-0 | telemetry notification column 데이터 도착 확인(사전 확인용) | boolean | true | `Meter` 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC23-1 | eol_1sec.csv 행 증가 | boolean | true | `[ "$(wc -l < eol_1sec.csv)" -gt "$rows_before" ]` |
| TC23-2 | eol_1min.csv 행 증가 | boolean | true | `[ "$(wc -l < eol_1min.csv)" -gt "$rows_before" ]` |

> **참고:** IPC 요청 메시지 필드명이 요구사항 문서(AGSRS-516)에는
> `{"factory_eol_mode": true}`로 기재되어 있으나, 코드(`device_log.cpp:457`)는
> `message.value("eol_mode", false)`로 `eol_mode` 필드를 읽는다. 실제 IPC 발행 시
> `eol_mode` 필드명을 사용할 것 — 요구사항 문서의 필드명 표기 오탈자로 판단됨.

> **주의 (Flag, 재검증 필요 — 2026-08-21 실측):** DUT(192.168.10.25)에서 `set_factory_
> eol_mode {"eol_mode":true}` 발행 후 130초를 기다려도 `/edge/log/eol/` 디렉토리
> 자체가 생성되지 않았다(`ls: cannot access '/edge/log/eol/': No such file or
> directory`). `EolLogger::setEolLoggingEnabled(true)`는 동기적으로
> `ensureEolFileHandlersCreated()`를 호출해 즉시 파일을 만들어야 하므로
> (`eol_logger.cpp:68-78, 85-136`), 130초 뒤에도 디렉토리가 없다는 것은 이 경로가
> 전혀 실행되지 않았다는 뜻이다. 유력한 원인 두 가지:
> (1) 그 이전 단계인 `EolLogger::loadEolPolicy()`(`eol_logger.cpp:28-66`)가
> `eolpolicy.json`을 못 읽어 `m_eol_policy_doc_.loggingRules`가 비어 있으면
> `ensureEolFileHandlersCreated()`의 for 루프가 아무 것도 하지 않는다 —
> `loadEolPolicy()`는 `log_policy_manager.cpp:69`에서 앱 부팅 시 1회만 호출된다.
> (2) `set_factory_eol_mode` IPC 자체가 device_log에 전달되지 않았을 가능성 —
> 이전 스크립트가 IPC 응답을 확인 없이 버려서(`> /dev/null`) 구분이 불가능했다
> (2026-08-21 스크립트 수정으로 응답 캡처 + `journalctl` `[EOL]`/`[loadEolPolicy]`
> 근거 수집 추가함). §AGSRS-491의 "AC 미구현"(TC24/TC25) 범위를 넘어서는, EOL
> 로깅의 기본 파일 생성 메커니즘 자체가 이 빌드에서 동작하지 않는 것으로 보이는
> 정황이라 **재실행하여 위 두 가지 중 어느 쪽인지 확정 필요** (이번 세션에서는
> DUT 재접속 금지 지침에 따라 재실행하지 않음).

---

## TC24 — EOL 로그 압축 형식 (zip vs xz, §AGSRS-491 AC 미구현 확인)

### 목적 (요구사항 §AGSRS-491 AC: "EOL Log files are compressed into zip format")

EOL 로그 파일이 zip으로 압축되는지 확인한다. **본 TC는 아래 코드 근거상 AC가 구현되어
있지 않음을 확인하는 목적이며, DUT 실측 없이도 FAIL이 확정적이다** —
`log_compress.cpp`/`log_compress.hpp` 전체에 `compressToXz()`(liblzma 기반 `.xz`) 하나의
압축 경로만 존재하고, `zip` 관련 코드나 라이브러리 참조는 없다.

### 사전 조건

- TC23과 동일(telemetry notification column 데이터 도착 확인 포함), EOL 로그가
  rotation/compress 되는 시점까지 대기 가능

### 절차

0. TC23과 동일한 telemetry column 데이터 도착 확인을 선행
1. TC23 절차로 EOL 로그(`eol_1sec.csv`/`eol_1min.csv`)가 생성되도록 유도
2. rotation/compress 시점까지 대기 (또는 `forced_log_upload`류 트리거가 EOL에도
   적용되는지 확인 후 사용)
3. `/edge/log/eol/` 하위에 생성된 압축 파일의 확장자 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 압축 확장자 | (요구사항 AC 기준) `.zip` |
| 실제 코드 동작 | `.xz`만 생성될 것으로 예상 (`compressToXz()` 단일 경로) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC24-0 | telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인) | boolean | true | `Meter` 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC24-1 | zip 압축 파일 존재 확인 (요구사항 AC 기준, 예상 FAIL) | boolean | true | `[ "$(find /edge/log/eol -name '*.zip' \| wc -l)" -gt 0 ]` |
| TC24-2 | 실제로는 xz만 생성됨(참고용) | boolean | true | `[ "$(find /edge/log/eol -name '*.xz' \| wc -l)" -gt 0 ]` |

> **주의 (Flag, 미구현 확정):** `log_compress.cpp`/`log_compress.hpp` 검토 결과
> device_log 전체가 `compressToXz()` 하나의 압축 경로만 사용하며, `zip` 관련 코드나
> 라이브러리 참조는 코드 전체에 없다. AC의 "zip format"은 현재 구현되어 있지 않음 —
> Jira 재확인/개발 이슈 등록 대상으로 보고할 것을 권장한다.

---

## TC25 — Factory EOL Mode ON 시 Field logging 중단 여부 (§AGSRS-491 AC 미구현 확인)

### 목적 (요구사항 §AGSRS-491 AC: "Field logging is disabled in EOL mode")

EOL 모드가 ON된 동안 일반 필드 로깅(SID0201의 정규 log_item)이 중단되는지 확인한다.
**본 TC는 아래 코드 근거상 AC가 구현되어 있지 않음을 확인하는 목적이며, DUT 실측
없이도 FAIL이 확정적이다** — `handle_request_set_factory_eol_mode()`
(`device_log.cpp:455`)는 `EolLogger::setEolLoggingEnabled(eol_mode)`만 호출하고,
필드 로깅을 멈추는 `LogPolicyManager::stopLogging()`은 호출하지 않는다. `stopLogging()`
호출부는 코드 전체에 `handle_request_factory_reset()`(`device_log.cpp:425`) 단 한 곳뿐이다.

### 사전 조건

- 공통 전제 조건 충족
- TC23과 동일한 telemetry notification column 데이터 도착 확인 선행(대상 log_item 기준)

### 절차

0. TC23과 동일한 telemetry column 데이터 도착 확인을 대상 log_item 기준으로 선행
1. 임의 field log_item(예: `PMU_Monitoring`)의 활성 CSV 행 수 기록
2. `set_factory_eol_mode` `{"eol_mode": true}` 발행
3. `logRowInterval` 수 배 대기하며 텔레메트리 지속 publish
4. field log_item CSV 행 수 변화 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 필드 로깅 | (요구사항 AC 기준) 행 수 변화 없음 (중단됨) |
| 실제 코드 동작 | `stopLogging()` 미호출이므로 행 수가 계속 증가할 것으로 예상 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC25-0 | telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인) | boolean | true | 대상 log_item 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC25-1 | EOL 모드 중 field 로깅 중단 확인 (요구사항 AC 기준, 예상 FAIL) | boolean | true | `[ "$(wc -l < "$csv")" -eq "$rows_before" ]` |
| TC25-2 | 실제로는 필드 로깅 계속됨(참고용) | boolean | true | `[ "$(wc -l < "$csv")" -gt "$rows_before" ]` |

> **주의 (Flag, 미구현 확정):** `handle_request_set_factory_eol_mode()`는
> `EolLogger::setEolLoggingEnabled(eol_mode)`만 호출하며, 일반 필드 로깅을 멈추는
> `LogPolicyManager::stopLogging()`은 호출하지 않는다. `stopLogging()`은 오직
> `handle_request_factory_reset()`에서만 호출된다(`logging_stopped_`는 한 번 설정되면
> 프로세스 종료까지 해제되지 않는 설계 — `stopLogging()` 주석 참고). 즉 현재 코드상
> EOL 모드 ON은 EOL 로그를 "추가로" 기록할 뿐, 필드 로깅을 중단시키지 않는다. AC
> "Field logging is disabled in EOL mode"와 배치되므로 Jira 재확인/개발 이슈 등록
> 대상으로 보고할 것을 권장한다.

---

## TC26 — Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제

### 목적 (요구사항 §AGSRS-491 AC: 로그 전체 삭제, 리셋 후 EOL 모드 비활성·필드 로깅
기본 활성)

`request_factory_reset` IPC 수신 시 `/edge/log/eol`, `/edge/log/device_log`,
`/edge/log/toupload/device_log`가 삭제되는지, 그리고 재부팅 후 EOL 모드가 기본
비활성 상태로 필드 로깅이 재개되는지 확인한다 (`handle_request_factory_reset()` —
`device_log.cpp:417`).

### 사전 조건

- 공통 전제 조건 충족, 각 대상 디렉토리에 로그 파일 존재 상태

### 절차

1. `/edge/log/eol`, `/edge/log/device_log`, `/edge/log/toupload/device_log`에 로그
   파일이 존재함을 확인
2. `SERVICE_REQUEST_FACTORY_RESET`(`request_factory_reset`) IPC 발행
3. 세 디렉토리가 삭제(또는 빈 상태)되었는지 확인
4. IPC 응답(OK) 수신 확인
5. DUT 재부팅(양산 라인 시나리오상 리셋 후 전원 차단 가정)
6. 재부팅 후 임의 field log_item(예: `PMU_Monitoring`)의 CSV 행 수를 기록하고
   `logRowInterval` 수 배 대기 후 재확인 (필드 로깅 재개 여부)
7. 재부팅 후 EOL 모드 상태 확인 — `set_factory_eol_mode`를 호출하지 않은 상태에서
   `/edge/log/eol/eol_1sec.csv`(또는 `eol_1min.csv`)가 새로 생성/증가하지 않는지 확인
   (기본값이 비활성인지 검증)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 디렉토리 삭제 | 3개 대상 디렉토리 모두 삭제됨 |
| IPC 응답 | OK |
| 재부팅 후 필드 로깅 | 행 수 증가 (재개됨) |
| 재부팅 후 EOL 모드 | 비활성(기본값) — EOL 로그 미생성/미증가 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC26-1 | eol 디렉토리 삭제 | boolean | true | `[ ! -d /edge/log/eol ]` |
| TC26-2 | device_log 디렉토리 삭제 | boolean | true | `[ ! -d /edge/log/device_log ]` |
| TC26-3 | toupload/device_log 디렉토리 삭제 | boolean | true | `[ ! -d /edge/log/toupload/device_log ]` |
| TC26-4 | IPC 응답 OK | boolean | true | `echo "$resp" \| grep -q '"error_code":0'` |
| TC26-5 | 재부팅 후 필드 로깅 재개 확인 | boolean | true | `[ "$(wc -l < "$csv")" -gt "$rows_before_reboot" ]` |
| TC26-6 | 재부팅 후 EOL 모드 기본 비활성 확인 | boolean | true | `[ ! -f /edge/log/eol/eol_1sec.csv ] || [ "$(wc -l < /edge/log/eol/eol_1sec.csv)" -eq "$eol_rows_before_reboot" ]` |

> **참고:** `stopLogging()`은 "재부팅 없이 리셋 직후 재활성화되지 않는다"는 설계
> 주석(`logging_stopped_`은 "Never cleared once set")을 코드에서 확인했다. 즉 리셋
> 직후 프로세스 재시작(재부팅) 없이는 필드 로깅이 재개되지 않는 것이 의도된 동작으로
> 보인다(양산 라인에서 리셋 후 전원 차단을 가정). TC26-5(재부팅 후 필드 로깅 재개)는
> 반드시 재부팅을 포함해서 판정할 것 — 재부팅 생략 시 오탐(false fail) 가능. TC26-6은
> `EolLogger`의 `m_eol_logging_enabled_` 멤버가 `{false}`로 기본 초기화되고(재부팅 시
> 프로세스가 새로 뜨므로 메모리 상태도 초기화됨) 별도 영속 저장 로직이 없음을
> 코드에서 확인했다 — Flag 없이 정상 동작 예상.

---

## TC27 — EOL 로그 추출 IPC

### 목적 (요구사항 §AGSRS-549)

`/edge/log/eol/` 경로의 EOL 로그를 추출하는 IPC 요청이 처리되는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족, `/edge/log/eol/`에 로그 파일 존재
- TC23과 동일한 telemetry notification column 데이터 도착 확인(참고용 — IPC 자체가
  미구현이라 SKIP 판정에는 영향 없음)

### 절차

0. TC23과 동일한 telemetry column 데이터 도착 확인(참고용)
1. `/edge/log/eol/`에 로그 파일 존재 확인
2. EOL 로그 추출 IPC 발행 (요구사항 문서 자체가 "IPC 개발 중"으로 명시 — 정확한
   topic/서비스명은 DUT의 `msg_ipc_ac_system_gen2.hpp` 최신 버전에서 재확인 필요)
3. 추출 결과(특정 폴더로 이동) 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 추출 결과 | EOL 로그가 지정 폴더로 이동 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC27-0 | telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인, 참고용) | boolean | true | `Meter` 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC27-1 | 추출 후 폴더 이동 확인 | manual | — | 개발 완료 후 확정 (아래 Flag 참고) |

> **주의 (Flag):** Jira AGSRS-549 설명 자체에 "EOL 로그 추출 IPC(개발 중)"이라고
> 명시되어 있다. 소스 트리(`device_log.cpp`의 `register_request_handler` 목록,
> `msg_ipc_ac_system_gen2.hpp`)를 검색한 결과 EOL 로그 추출 전용 IPC 핸들러를
> 찾지 못했다 — 요구사항과 코드 모두 "미구현"으로 일치하므로 본 TC는 **구현 완료 후
> 활성화** 대상으로 보류할 것을 권장한다.

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `device_log` | MQTT 수신 대상 앱 ID |
| `LOGGER_ROOT` | `/edge/log/device_log` | 로컬 로그 루트 (logpolicy.json `loggerPath`) |
| `TOUPLOAD_ROOT` | `/edge/log/toupload/device_log` | toupload 경로 (`toUploadPath`) |
| `ARCHIVE_ROOT` | `/edge/log/device_log/archive` | archive 경로 (`archivePath`) |
| `UPLOADED_ROOT` | `/edge/log/uploaded/device_log` | 업로드 완료 후 이동 경로 (`uploadedPath`) |
| `EOL_ROOT` | `/edge/log/eol` | EOL 로그 경로 |
| `LOGCOUNT_JSON` | `/edge/etc/app-config/device_log/rules/logcount.json` | 일일/월간 업로드 한도 설정 파일 (baked-in 기본값: `/edge/app/files/device_log/logcount.json`) |

---

## 디렉토리 구조 참고

```
/edge/log/
├── device_log/
│   ├── <logItem>/                ← LOGGER_ROOT/<logItem> (활성 CSV, root 압축 파일)
│   └── archive/
│       └── <logItem>/            ← ARCHIVE_ROOT/<logItem>
├── toupload/
│   └── device_log/
│       └── <logItem>/            ← TOUPLOAD_ROOT/<logItem> (.xz + .meta 쌍)
├── uploaded/
│   └── device_log/
│       └── <logItem>/            ← UPLOADED_ROOT/<logItem> (metaPostActionSuccess=move 인 경우)
└── eol/                          ← EOL_ROOT (eol_1sec.csv / eol_1min.csv / eol_10min.csv)
```

---

## 자동화 등급 (Automation Grade)

🟢 **A** (TC27만 IPC 미구현으로 실행 불가 — 나머지는 TC08/TC24/TC25 포함 boolean 스크립트로 무인 실행 가능. 단 TC08/TC24/TC25는 요구사항 미구현이 코드로 확정되어 실행 시 FAIL이 예상됨)

| TC | 등급 | 비고 |
|----|------|------|
| TC01~TC26 | A | 무인 실행 가능 (TC08/TC24/TC25는 Flag 항목 — boolean 스크립트로 실행은 가능하나 요구사항 미구현으로 FAIL 예상) |
| TC27 | B | EOL 로그 추출 IPC 자체가 미구현(Jira도 "개발 중" 명시) — 트리거할 대상이 없어 실행 불가, 구현 완료 후 활성화 대상 |

---

## 근거 매핑 (Evidence Mapping)

| TC ID | 근거 (Jira 키 + 코드 파일:line) | 출처 신뢰도 |
|---|---|---|
| TC01 | AGSRS-532 + `log_policy_manager.cpp:79`(buildHeaderColumns), `:558`(writeCsvColumnsValues) | High (양쪽 일치) |
| TC02 | AGSRS-533 + `log_policy_manager.cpp:196`(processTheMessage row interval), `logpolicy.json:logRowInterval` | High |
| TC03 | AGSRS-509, AGSRS-510 + `log_policy_manager.cpp:960`(createFileDirectoryForAllRules), `logpolicy.json`(주기적 non-fault 18개, prefix별 세분화) | High |
| TC04 | AGSRS-27 AC(파일명 형식) + `log_policy_manager.cpp:400`(replaceLogFileTemplateWithActualValue) | High |
| TC05 | AGSRS-27 AC(±5%) + AGSRS-534 + `logpolicy.json:logCreationTime` | High |
| TC06 | AGSRS-546 + `log_policy_manager.cpp:1028-1048`(Case A: existing_file 재사용) | High |
| TC07 | AGSRS-547 + `log_policy_manager.cpp:1103-1137`(writeFileHeaderWithColumnsName Case A 빈 행) | High |
| TC08 | AGSRS-548 + `device_log.cpp:311`(NOTI_DEVICE_CONNECTION 구독), `device_log.cpp:639-644`(handle_noti_device_connection, DEBUG 로그만 남기고 no-op) | **Flag — 미구현 확정. 알림 수신 경로는 있으나 CSV 조치 없음(빈 행 삽입은 재부팅 재사용 경로에서만 발생, TC07과 동일). DUT 실측 없이 FAIL 확정적** |
| TC09 | AGSRS-28 AC(FIFO) + AGSRS-511 + `cloud_upload_manager.cpp:1615`(deleteArchFileBasedOnCount) | High |
| TC10 | AGSRS-545 + `cloud_upload_manager.cpp:1676`(deleteArchFileBasedOnTime), `logpolicy.json:retentionTime` | High |
| TC11 | AGSRS-538 + `cloud_upload_manager.cpp:241`(handleFileUploadResult) | High |
| TC12 | AGSRS-512 + `cloud_upload_manager.cpp:133`(createMetaFile, uploadYearMonth), `cloud_broker/blob_upload_director.cpp`(kUploadRoot=/edge/log/toupload 스캔, 실제 업로드 시도 주체) | High |
| TC13 | AGSRS-536, AGSRS-537(통합) + `cloud_upload_manager.cpp:816`(rootToArchiveOrToUpload), `cloud_broker/blob_upload_director.cpp:26,233`(kRetrySec 10개, 실제 10회 재시도는 여기 구현) | High(경로 이동) / **Flag(정정 — "10회 재시도"는 device_log가 아닌 cloud_broker 책임으로 확인됨)** |
| TC14 | AGSRS-513, AGSRS-540(통합) + `cloud_upload_manager.cpp:449`(cloud_connected_action), `:847`(archiveToUpload) | High |
| TC15 | AGSRS-539 + `cloud_upload_manager.cpp:96`(init/enumerateExistingFilesInDirectory) | Medium (재기동 시나리오는 코드상 추정, 실측 필요) |
| TC16 | AGSRS-514 + `cloud_upload_manager.cpp:1338`(isUploadAllowed), `logcount.json:perDayRoot` | High |
| TC17 | AGSRS-543 + `cloud_upload_manager.cpp:1338`(isUploadAllowed archive 분기) | High |
| TC18 | AGSRS-514(자정 부분) + AGSRS-544 + `cloud_upload_manager.cpp:1409`(updateLogUploadLimitsDaily) | High |
| TC19 | AGSRS-542 + `cloud_upload_manager.cpp:1432`(updateLogUploadLimitsMonthly) — 코드 값(root=default,archive=0)이 Jira 기대결과와 완전 일치 | High |
| TC20 | AGSRS-541 + `cloud_upload_manager.cpp`(loadUploadInfoMap/writeToLogCountJson 계열) | Medium (재부팅 유지 로직은 파일 영속성 기반 추정) |
| TC21 | AGSRS-498 AC1(우선순위 업로드) + `cloud_upload_manager.cpp:1310`(selectNextRootLogType 라운드로빈) | **Flag — 요구사항은 우선순위, 코드는 라운드로빈. 검증 목표를 라운드로빈 균등성으로 재설정(사용자 확인)** |
| TC22 | AGSRS-515 + `device_log.cpp:463`(handle_request_forced_log_upload), `cloud_upload_manager.cpp:314`(handleForcedLogUploadRequest) | High |
| TC23 | AGSRS-516 + `eol_logger.cpp:155`(processEolLogging), `eolpolicy.json`(eol_1min, eol_1sec — eol_10min은 정책에서 삭제됨) | High (단, IPC 필드명 `eol_mode` vs 요구사항 `factory_eol_mode` 표기 차이 있음) |
| TC24 | AGSRS-491 AC("zip format") + `log_compress.cpp`(compressToXz만 존재, zip 미발견) | **Flag — 미구현 확정. DUT 실측 없이 FAIL 확정적** |
| TC25 | AGSRS-491 AC("Field logging is disabled in EOL mode") + `device_log.cpp:455-461`(stopLogging 미호출), `device_log.cpp:425`(stopLogging 유일 호출부는 factory_reset뿐) | **Flag — 미구현 확정. DUT 실측 없이 FAIL 확정적** |
| TC26 | AGSRS-491 AC(리셋 시 전체 삭제/EOL 해제) + `device_log.cpp:417-443`(handle_request_factory_reset) | High (단, 재부팅 필요 전제는 Medium) |
| TC27 | AGSRS-549 + 코드 전역 검색(핸들러 미발견) | **Flag — 요구사항 자체가 미구현 명시, 코드도 미구현 확인** |

---

## 관련 문서

- `tc_device_log_result.md` — 본 TC 실행 결과 보고서
- `tc_device_log_evidence_full.log` — 결과의 근거가 되는 통합 로그
