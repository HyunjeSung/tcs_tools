---
spec_id: device_manager
suite: application
grade: A
phase: Phase 1
test_file: tcs/device_manager/tc_device_manager.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-DEVICE_MANAGER: device_manager — Modbus/CAN 기반 디바이스 연결 및 데이터 처리

## 목적 (Objective)

`device_manager` 애플리케이션이 `configuration.json` / `register_map.json`
(site JSON) 을 소스 코드 수정 없이 Load 하여 Device/Protocol 연결을 구성하고,
필수 파일 부재 시 정상적으로 미동작 상태를 유지하며, 주기적 Read 데이터를
`operation`/`periodMs` 설정에 따라 수신·반영하는지 검증한다.

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "Flexible connectivity" 카테고리 원본
3개 TC(Key 136/137/189, `docs/tc_requirements/device_manager.md`)를 기준으로
작성했다. 원본 TC 수가 적어 소스 코드에서 확인된 세부 동작 단위로 서브 TC를
분리했다.

**중요 — 아키텍처 상 전제:** `device_manager`는 site JSON(`configuration.json`,
`register_map.json`)의 실제 **파일 읽기/스키마 검증**을 직접 수행하지 않는다.
파일 읽기는 `db_manager`(`init_configuration()`/`init_register_map()`, 로그 태그
`[DB]`)가 담당하고, 실제 Modbus/CAN 주기적 폴링(Connection 계층)은 `energy_link`
(`connections/modbus_connection_base.cpp`, `can_connection.cpp`, `spi_connection.cpp`,
로그 태그 `[EL]`)가 담당한다. `device_manager`(로그 태그 `[DM]`)는 두 앱으로부터
IPC 응답/알림(`SERVICE_GET_CONFIGURATION_JSON`, `SERVICE_GET_REGISTER_MAP_JSON`,
`NOTI_DEVICE_CONNECTION`, `NOTI_DEVICE_CYCLE_DATA`)을 받아 자신의
`site_json_data_`/`device_manager_data_`에 반영하고, MI/CAN 디바이스 상세 조회
(`request_can_device_info`), Protocol 목록 조회(`get_protocol_list`) 등을 수행하는
**소비자(consumer) 겸 wrapper** 역할이다. 아래 TC는 이 역할 분담을 전제로,
`device_manager` 자신의 로그/IPC 응답을 1차 판정 기준으로 삼고, 필요한 경우
`[DB]`/`[EL]` 로그를 보조 근거로 사용한다.

> **README.md 아키텍처 섹션과의 불일치 주의:** `README.md`(`DeviceManagerHandler`,
> `MCUHandler`, `MIIPCHandler` 등)는 현재 `source/` 트리(`CanManager`, `SpiManager`,
> `DataCenter`, `TelemetryPublisher`, `OnDemandQueue`, `DeviceManagerIpcHandler`)와
> 클래스 구성이 다르다 — README가 과거 리팩터 이전 구조를 기술한 것으로 보인다.
> 본 TC는 실제 `source/*.cpp` 코드를 근거로 작성했으며, README 값은 참고만 했다.
> **Flag — README 최신화 필요 여부는 개발자 확인 권장.**

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `device_manager` 프로세스 실행 중 (`pgrep -f device_manager`)
- `db_manager`, `energy_link` 프로세스 실행 중 (site JSON 로드/디바이스 연결 담당)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨
- `journalctl -u docker-loader` 로 전체 앱 로그 확인 가능 — 각 앱 로그는
  `[DM]`(device_manager) / `[DB]`(db_manager) / `[EL]`(energy_link) 접두사로 자동
  태깅됨 (`EdgeLogger::set_app_name_mapping`)
- site JSON 파일 경로: `/edge/app/files/commonfile/configuration.json`,
  `/edge/app/files/commonfile/register_map.json` (요구사항 원문의 "RegisterMaps.json"과
  실제 파일명이 다름 — **Flag**, 아래 근거 매핑 참고)
- root 권한 (site JSON 파일 백업/치환, `reboot` 실행)

> **주의(파괴적 시험 가능성):** TC02/TC04는 `request_factory_reset` IPC로 EMS DB를
> 초기화하고, TC02/TC03/TC04는 실제 `reboot`를 수행한다. 시리얼 콘솔(COM7) 사용을
> 권장하며(SSH는 reboot 시 끊김), 시험 전 site JSON 파일을 반드시 백업할 것.

---

## TC01 — configuration.json 신규 Protocol 추가 → 코드 수정 없이 연결 시도 확인

### 목적

`configuration.json`에 새 Device/Protocol connection 정보를 추가하고 재부팅하면,
`device_manager` 소스 코드 수정 없이 해당 Protocol에 대한 연결 시도(연결 상태 알림
수신)가 이루어지는지 확인한다. (원본 TC-1, Key 136)

### 사전 조건

- 공통 전제 조건 충족
- `/edge/app/files/commonfile/configuration.json` 쓰기 가능, 원본 백업 완료
  (`cp configuration.json configuration.json.tc01.bak`)
- 기존 `configuration.json`의 `deviceList[].rid` 목록을 사전에 확보 (신규 rid와
  중복되지 않도록)

### 절차

1. 기존 `configuration.json`을 파싱해 `deviceList` 구조를 확인 (`ConfigDevice`:
   `rid`, `description`, `serialNum`, `manufacturer`, `model`, `deviceType`,
   `deviceSubType`, `deviceMetricList`, `connectionInfos` 등 필드)
2. 기존 Device 항목 하나를 복제해 `rid`를 신규 값(예: `tc01_test_device`)으로
   변경하고 `connectionInfos`(프로토콜/연결 정보)를 유지한 채 `deviceList`에 추가
   — **소스 코드는 전혀 수정하지 않음**
3. `journalctl -u docker-loader` 커서 위치 기록 (`--since` 시각 기록)
4. `db_manager`에 `request_factory_reset` IPC 요청 전송 (EMS DB 초기화 —
   `SERVICE_REQUEST_FACTORY_RESET` = `"request_factory_reset"`) 후 응답 수신 대기
5. `reboot` 실행 (시리얼 콘솔 권장)
6. 부팅 완료 후 `journalctl -u docker-loader --since "<4단계 시각>"` 에서
   `[DM]` 태그 로그 확인:
   - `"Site data ready, start connection threads"` (device_manager가 site JSON
     로드 완료를 인지했는지)
   - `"device_connection received:"` 로그 중 신규 device의 `protocol_rid`가
     포함된 항목 존재 여부 (`NOTI_DEVICE_CONNECTION` 알림 수신 — 연결 시도 결과)
7. device_manager에 `get_protocol_list` IPC 요청 전송 → 응답 payload의
   `protocols[]` 배열에 신규 Device의 protocol 항목(`rid`, `protocol`)이 포함되는지
   확인 (`SERVICE_GET_PROTOCOL_LIST` = `"get_protocol_list"`,
   `handle_get_protocol_list()`는 `site_json_data_.get_all_protocol_configs()`를
   그대로 반환)
8. TEARDOWN: `configuration.json.tc01.bak` 복원 후 재부팅

### 기대 결과

| 항목 | 기준 |
|------|------|
| factory_reset 응답 | 수신됨 |
| 재부팅 후 `[DM] Site data ready` 로그 | 존재 |
| `device_connection received:` 로그 | 신규 device의 protocol_rid 포함 항목 존재 |
| `get_protocol_list` 응답 | 신규 protocol 항목 포함 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | factory_reset 응답 수신 | boolean | true | `[ -n "$reset_resp" ]` |
| TC01-2 | site data ready 로그 존재 | boolean | true | `journalctl -u docker-loader --since "$T0" \| grep -q '\[DM\].*Site data ready'` |
| TC01-3 | 신규 protocol_rid 연결 알림 수신 | boolean | true | `journalctl -u docker-loader --since "$T0" \| grep 'device_connection received:' \| grep -q "$NEW_RID"` |
| TC01-4 | get_protocol_list 응답에 신규 protocol 포함 | boolean | true | `echo "$resp" \| jq -e '.payload.protocols[] \| select(.rid=="'"$NEW_RID"'")'` |

---

## TC02 — configuration.json / register_map.json 부재 시 부팅 동작 (검토 필요 — 원본 로그 태그 불일치)

> 원본 요구사항은 "[EL] message"와 "Web HMI Energy Link 로그 레벨"을 근거로 들지만,
> 소스 코드 확인 결과 site JSON **파일 자체를 읽어 부재를 감지·로깅**하는 주체는
> `db_manager`이며 로그 태그는 `[DB]`다 (`db_manager.cpp`
> `init_configuration()`: `"[init_configuration] Failed to open configuration file: ..."`,
> `init_register_map()`: `"[init_register_map] Failed to open register map file: ..."`).
> `energy_link`(`EL`)는 `db_manager`로부터 IPC로 (빈 경우 `{}`) 응답만 받을 뿐,
> "파일 없음"을 직접 감지·로깅하지 않는다 — `is_site_data_ready()`가 false로
> 남아 `create_and_start_devices()`를 호출하지 않을 뿐, 명시적 에러 로그가 없다.
> `device_manager` 자신도 동일하게 `config_response_received_`/
> `regmap_response_received_`는 true가 되지만(응답 자체는 옴) `site_json_data_.
> is_site_data_ready()`가 false로 남아 `"Site data ready, start connection threads"`
> 로그가 찍히지 않는다. 원본이 말하는 "[EL] 메시지"가 실제로 존재하는지, 또는
> Web HMI 로그 레벨 페이지의 "Energy Link" 항목이 실제로는 다른 태그(예: `[DB]`)를
> 포함해서 보여주는지는 **개발자 확인 필요**. 아래는 소스로 확인된 실제 동작(`[DB]`
> 에러 로그 + `device_manager`의 "ready 로그 미출현")을 기준으로 작성했다.

### 목적

`configuration.json` 또는 `register_map.json` 파일이 없는 상태로 부팅 시,
`db_manager`가 파일 오픈 실패를 로깅하고, `device_manager`가 site data ready
상태로 전이하지 않는지 확인한다. (원본 TC-2, Key 137, 1번째 서브스텝)

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`, `register_map.json` 원본 백업 완료
- **파괴적**: DB에 이미 caching된 값이 있으면 `init_configuration()`/
  `init_register_map()`은 파일을 다시 읽지 않고 스킵하므로(`"already has value,
  skipping initialization"`), 이 TC는 반드시 `request_factory_reset` 직후
  (DB 테이블이 비워진 상태) 또는 신규 프로비저닝 상태에서만 유효

### 절차

1. `request_factory_reset` IPC 요청 → 응답 수신 대기 (EMS DB 초기화, TABLE_NAME_CONFIGURATION/
   TABLE_NAME_REGISTER_MAP 삭제)
2. `configuration.json`을 임시로 다른 이름으로 이동 (`mv configuration.json configuration.json.hidden`)
3. `journalctl -u docker-loader` 커서 시각 기록
4. `reboot` 실행
5. 부팅 완료 후 `journalctl -u docker-loader --since "<T0>"` 확인:
   - `[DB]` 태그 로그에 `"Failed to open configuration file:"` 존재
   - `[DM]` 태그 로그에 `"Site data ready"` 부재 (device_manager가 연결 스레드를
     시작하지 않음)
6. TEARDOWN: `configuration.json.hidden`을 원래 이름으로 복원, `request_factory_reset`
   재실행 후 재부팅하여 정상 상태 복구

### 기대 결과

| 항목 | 기준 |
|------|------|
| `[DB]` 파일 오픈 실패 로그 | 존재 |
| `[DM] Site data ready` 로그 | 부재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | db_manager 파일 오픈 실패 로그 존재 | boolean | true | `journalctl -u docker-loader --since "$T0" \| grep -q '\[DB\].*Failed to open configuration file'` |
| TC02-2 | device_manager site data ready 로그 부재 | boolean | true | `! journalctl -u docker-loader --since "$T0" \| grep -q '\[DM\].*Site data ready'` |

---

## TC03 — configuration.json / register_map.json 정상 로드 확인

### 목적

정상적인 `configuration.json`, `register_map.json` 파일이 존재하는 상태로
부팅하면 `device_manager`가 두 응답을 모두 수신하고 site data ready 상태로
전이하는지 확인한다. (원본 TC-2, Key 137, 2~3번째 서브스텝 — TC02의 대조군)

### 사전 조건

- 공통 전제 조건 충족
- `configuration.json`, `register_map.json` 정상 상태(TC02에서 백업한 원본 복원 완료)

### 절차

1. `configuration.json`, `register_map.json` 정상 파일 존재 확인 (`ls`, `jq .`
   로 파싱 가능 여부)
2. `journalctl -u docker-loader` 커서 시각 기록
3. `reboot` 실행
4. 부팅 완료 후 `journalctl -u docker-loader --since "<T0>"` 확인:
   - `[DM]` 태그 로그에 `"Site data ready, start connection threads"` 존재
5. `db_manager`에 `get_configuration_json` / `get_register_map_json` IPC 요청 전송
   → 두 응답 payload가 비어있지 않은 JSON object 인지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| `[DM] Site data ready` 로그 | 존재 |
| `get_configuration_json` 응답 | 비어있지 않은 object |
| `get_register_map_json` 응답 | 비어있지 않은 object |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | site data ready 로그 존재 | boolean | true | `journalctl -u docker-loader --since "$T0" \| grep -q '\[DM\].*Site data ready'` |
| TC03-2 | configuration 응답 비어있지 않음 | boolean | true | `echo "$config_resp" \| jq -e '.payload \| length > 0'` |
| TC03-3 | register_map 응답 비어있지 않음 | boolean | true | `echo "$regmap_resp" \| jq -e '.payload \| length > 0'` |

---

## TC04 — 주기적 Read Data 처리 (검토 필요 — 실제 폴링 루프는 energy_link 소관)

> 원본(Key 189)은 `operation: "read"`, `periodMs` 설정에 따라 주기적으로 데이터를
> Read해야 한다고 요구한다. 소스 확인 결과, 이 값들이 정의된 스키마(`RegisterGroup`:
> `id`, `operation`(배열), `periodMs`(기본값 1000), `modbusRegType`, `registers`)는
> `register_map.json`의 공통 구조(`msg_ipc_payload.hpp` `RegisterGroup`)이고, 이
> 배열의 `operation`에 `"read"`가 포함된 그룹을 주기적으로 폴링하는 **실제 루프는
> `energy_link`의 `connections/modbus_connection_base.cpp` (Modbus),
> `connections/can_connection.cpp` (CAN), `connections/spi_connection.cpp` (SPI)에
> 구현되어 있다** — `device_manager` 자신은 이 폴링을 수행하지 않는다.
> `device_manager`는 폴링 결과를 `NOTI_DEVICE_CYCLE_DATA`(`"device_cycle_data"`)
> 알림으로 수신해 `handle_noti_telemetry()` → `dispatch_metrics()`로 반영하는
> **소비자**일 뿐이다 (device_manager는 `register_as_wrapper()`로 energy_link/
> virtual_link에 wrapper로 등록되어 있어 원시 read 결과를 직접 수신함).
> 따라서 "주기가 `periodMs`와 일치하는지"의 1차 근거는 `energy_link`(`[EL]`) 로그이며,
> `device_manager` 관점에서는 "`device_cycle_data` 알림을 `periodMs` 간격으로 지속
> 수신하는지"만 간접 검증 가능하다. **자동화 가능하나 판정 기준의 소유 앱이 다르므로
> 개발자 확인 후 최종 판정 주체(energy_link TC 문서로 이관할지 여부)를 결정할 것.**

### 목적

`register_map.json`의 `registerGroups[]` 중 `operation`에 `"read"`가 포함된
그룹이 `periodMs` 주기로 Read되어, `device_manager`가 해당 주기로
`device_cycle_data` 알림을 수신하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- `register_map.json`에서 `operation: ["read", ...]`이고 `periodMs`가 명시된
  RegisterGroup 최소 1개 존재 확인 (`jq '.. | objects | select(.operation? and
  (.operation | index("read"))) | {id, operation, periodMs}'`)
- 해당 RegisterGroup에 대응하는 물리 Modbus/CAN/SPI 디바이스가 실제로 연결되어
  응답 가능한 상태 (미연결 시 Read 실패로 알림 자체가 발생하지 않을 수 있음 —
  **하드웨어 의존**)

### 절차

1. `register_map.json`에서 테스트 대상 그룹의 `id`, `operation`, `periodMs` 값을
   확보 (예: `periodMs=1000`)
2. `mosquitto_sub`로 `device_manager`가 구독 중인 `device_cycle_data` 알림 토픽을
   30초간 캡처하며 각 메시지의 수신 타임스탬프 기록
   (`emsp/{target}/{source}/noti/device_cycle_data` 패턴 — 실제 토픽은 `energy_link`가
   `notify_mqtt()`로 발행하는 wrapper 대상 토픽 확인 필요)
3. 연속 수신된 메시지 간 시간 간격(interval) 계산
4. `journalctl -u docker-loader`에서 `[EL]` 태그의 Modbus/CAN/SPI 관련 에러
   로그(`"Failed to read register"`, `"Failed to read batch"` 등) 유무 확인
   (에러 없이 정상 폴링 중인지 참고 근거)

### 기대 결과

| 항목 | 기준 |
|------|------|
| `device_cycle_data` 수신 간격 | `periodMs` ± 허용 오차(예: ±20%) 이내로 반복 |
| `[EL]` Read 에러 로그 | 없음 (정상 폴링 시) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | device_cycle_data 알림 2회 이상 수신 | boolean | true | `[ "$msg_count" -ge 2 ]` |
| TC04-2 | 평균 수신 간격이 periodMs ±20% 이내 | boolean | true | `awk -v p="$PERIOD_MS" -v avg="$avg_interval_ms" 'BEGIN{d=(avg>p?avg-p:p-avg); exit !(d <= p*0.2)}'` |
| TC04-3 | Read 에러 로그 없음 | boolean | true | `! journalctl -u docker-loader --since "$T0" \| grep '\[EL\]' \| grep -q 'Failed to read'` |

---

## TC05 — 자동화 불가 / 검토 필요 항목 목록

이 항목들은 실제 물리 Modbus/CAN/SPI 디바이스 연결, 사람의 Web HMI 조작, 또는
개발자 확인이 선행되어야 하는 원본 요구사항 서브스텝이다. 별도 상세 TC로
전개하지 않고 목록으로만 남긴다.

| 원본 Key / TC | 항목 | 자동화 불가·보류 사유 |
|----------------|------|----------------------|
| Key136 (TC-1) 5번째 서브스텝 | "Source code 수정 없이 ... 검증" (일반 진술) | TC01의 절차/판정으로 대체 커버 — 별도 서브 TC 불필요 |
| Key137 (TC-2) 1번째 서브스텝 | Web HMI "System > Log Level > Energy Link" 설정 화면 확인 | Web HMI 수동 조작(브라우저) 필요, 셸 스크립트로 자동화 불가 |
| Key189 (TC-3) | Energy Link Log Level을 Debug로 변경 | Web HMI 수동 조작(또는 `log_level_dm`/`log_level_el` System Setting 키를 IPC로 변경 — 정확한 키/서비스명은 energy_link TC 문서에서 확인 필요) |
| TC04 전체 | 주기적 Read의 물리 디바이스 응답 정확성 | 실제 Modbus/CAN/SPI 슬레이브 디바이스 연결 필요, 미연결 보드에서는 Read 자체가 발생하지 않음 |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `device_manager` | MQTT 수신 대상 앱 ID |
| `CONFIG_JSON_PATH` | `/edge/app/files/commonfile/configuration.json` | site 구성 파일 (TC01/TC02/TC03) |
| `REGISTER_MAP_JSON_PATH` | `/edge/app/files/commonfile/register_map.json` | 레지스터 맵 파일 (TC02/TC03/TC04) |

---

## 자동화 등급 (Automation Grade)

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | A (자동) | configuration.json 수정 + reboot + 로그/IPC 응답 검증, 물리 디바이스 불필요 |
| TC02 | A (자동, 파괴적) | factory_reset + 파일 은닉 + reboot, 테어다운으로 원복 |
| TC03 | A (자동) | TC02의 대조군, 정상 파일 상태 검증 |
| TC04 | B (하드웨어 의존) | 실제 Modbus/CAN/SPI 디바이스 연결 필요, 판정 주체가 energy_link일 가능성 — 개발자 확인 후 재배치 검토 |
| TC05 | 자동화 불가 | 목록만 제공, 실행은 QA 수동 또는 개발자 확인 |

---

## 관련 문서

- `tc_device_manager_result.md` — 본 TC 실행 결과 보고서
- `tc_device_manager_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/device_manager.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx "Flexible connectivity" 카테고리, Key 136/137/189, 3개 TC)
