---
spec_id: db_manager
suite: application
grade: A
phase: Phase 1
test_file: tcs/db_manager/tc_db_manager.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-DB_MANAGER: db_manager — System Setting/Persistent State DB 관리

## 목적 (Objective)

`db_manager` 애플리케이션의 SQLite 기반 DB 관리(`edge_storage.db`/`configuration`,
`persistent_state`, `system_setting`, `device_info`, `register_map` 테이블 생성·조회·
갱신), 부팅 시점 DB 초기화, 변경 사항의 즉시 반영, 클라우드 재연결 시 미동기화
데이터(`SyncConfigurationRequest`/`SyncRegisterMapRequest`) 전송까지 db_manager가
책임지는 핵심 기능을 검증한다.

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "DB Manager" 카테고리 원본 12개 TC
(Key 76, 121-127, 145-147, 181, `docs/tc_requirements/db_manager.md`)를 기준으로
작성했다. 원본과 소스코드(`qcells/uniep/core/application/db_manager/`,
`qcells/uniep/core/common/base_app/`, `qcells/uniep/core/common/app_core/include/
msg_ipc.hpp`, `msg_ipc_payload.hpp`)를 대조한 결과 다음 특이사항이 발견되어 아래와
같이 재구성했다:

- **원본 Key76(TC-1)에 LED 인디케이터 매트릭스가 부착되어 있음** — "Configuration
  테이블 생성" 이후 연속 스텝으로 "MI 스캔/Power 생산/펌웨어 업데이트/Qcells Server
  연결" 시의 LED 색상표가 이어지는데, db_manager 소스 어디에도 LED 제어 로직이
  없다(다른 카테고리의 시험 항목이 엑셀 정리 과정에서 잘못 붙은 것으로 추정). db_manager
  범위가 아니므로 TC01에서 제외하고 TC11(자동화 불가 목록)에 원본 그대로 남긴다.
- **원본 Key126(TC-7, "Persistent state 초기화")과 Key127(TC-8, "System setting
  초기화")의 실제 Action/Expected Result 본문이 각각 Key145(TC-9)/Key146(TC-10)과
  글자 그대로 동일하다** — 제목은 "초기화"이지만 실제 내용은 동일한
  `select_all_records` 조회 스텝만 반복하며, `factory_reset`/`installer_reset` 같은
  실제 초기화 서비스를 호출하지 않는다. 이 문서는 요구사항 원문(Action/Expected
  Result)을 신뢰 기준으로 삼아 TC07/TC08에서 각각 두 원본을 병합했다 — "초기화" 자체를
  검증하려면 개발자 확인 후 `SERVICE_REQUEST_FACTORY_RESET`/`SERVICE_PERFORM_INSTALLER_RESET`
  기반 TC를 별도로 설계해야 한다(근거 매핑 표에 Flag 표시).
- **원본 Key181(TC-12)이 설명하는 DB 스키마가 현재 코드와 다르다** — 원본은
  "02.00.07 기준 RegisterMap은 system_setting 테이블 안에 `register_map`이라는 key로
  존재"라고 명시하지만, 현재 소스에는 이미 `register_map`이 별도 id_value 테이블
  (`TABLE_NAME_REGISTER_MAP`)로 분리되어 있다 — 원본이 예고한 "향후 버전" 상태가 이미
  적용된 것으로 보인다. TC10은 현재 스키마(별도 테이블) 기준으로 작성했다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `db_manager` 프로세스 실행 중 (`pgrep -f db_manager`)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨
- `sqlite3` CLI 사용 가능 (직접 DB 파일 검증/강제 insert용, TC02/TC07/TC08/TC09에서 사용)
- DB 파일 경로: 일반 파티션 `/edge/db/edge_storage.db`, Secure 파티션
  `/edge/sp/db/edge_storage.db` (`db_manager.hpp`의 `kDbDirectory`/`kSecureDbDirectory`/
  `kDatabaseName` 상수 기준)
- `journalctl` 로 db_manager 로그 확인 가능 (로그 태그 `[DB]` — `db_manager.cpp`
  생성자의 `set_app_name_mapping(client_id, "DB")`)

> **주의:** TC02/TC05/TC06/TC10은 프로세스 재시작 또는 리부트를 포함한다.
> `feedback_serial_vs_ssh_polling` 관례에 따라 재부팅을 포함하는 서브스텝은 SSH
> 폴링 대신 시리얼(`serial_helper.ps1`) 기반 확인을 권장한다.
> TC02/TC07/TC08/TC09는 `sqlite3`로 DB 파일에 직접 쓰기/읽기를 수행하므로, 시험
> 대상이 아닌 실제 운영 데이터를 건드리지 않도록 사전에 해당 테이블을 백업
> (`cp /edge/db/edge_storage.db /tmp/edge_storage.db.bak`) 해둘 것을 권장한다.

---

## TC01 — Configuration 테이블 생성 및 select_all_records 조회

### 목적

`db_manager`가 부팅 시 `edge_storage.db`에 `configuration` 테이블을 생성하고,
`select_all_records` MQTT 요청에 대해 해당 테이블 레코드를 정상적으로 반환하는지
확인한다. (원본 Key76 — LED 인디케이터 매트릭스 부분은 db_manager 범위 밖으로 판단해
제외, TC11 참고)

### 사전 조건

- 공통 전제 조건 충족
- `configuration` id_value 테이블이 이미 부팅 초기화(`init_configuration()`)로
  생성되어 있는 상태 (일반적인 정상 부팅 후 상태)

### 절차

1. `db_manager` req 토픽으로 `select_all_records` 요청 발행:
   - topic: `emsp/db_manager/<SOURCE>/req/select_all_records`
   - payload(message): `{"db":"edge_storage.db","table":"configuration"}`
     (`TableInfo{db,table}` 구조체 — `msg_ipc_payload.hpp:125`)
2. `emsp/<SOURCE>/db_manager/res/select_all_records` 응답 수신 (타임아웃 10초)
3. 응답 payload를 `DbRecordResult{db,table,result,records}` 구조로 파싱

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 수신 | 10초 이내 res 토픽 수신 |
| result 필드 | `true` |
| db/table 필드 | 요청과 동일 (`edge_storage.db` / `configuration`) |
| records | 배열 형태 (부팅 직후 값이 없으면 빈 배열도 정상) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | 응답 수신 | boolean | true | `[ -n "$resp" ]` |
| TC01-2 | result=true | boolean | true | `echo "$resp" \| grep -qE '"result"\s*:\s*true'` |
| TC01-3 | table 필드 일치 | boolean | true | `echo "$resp" \| grep -qE '"table"\s*:\s*"configuration"'` |
| TC01-4 | records 필드가 JSON 배열 | boolean | true | `echo "$resp" \| python3 -c "import json,sys; assert isinstance(json.load(sys.stdin).get('records'), list)"` |

---

## TC02 — Configuration 이력 정보 클라우드 전달 (SyncConfigurationRequest)

### 목적

`configuration` 테이블에 서로 다른 `version`을 가진 레코드가 여러 건 존재할 때,
클라우드 재연결(`uplink_ready` false→true 전이) 시 미동기화(unsynced) 레코드가
`SyncConfigurationRequest` D2C 메시지로 전송되는지 확인한다. (원본 Key121)

> 정상 IPC 경로(`set_configuration_json`)는 버전이 이전 값+1이 아니면 거부하므로
> (`validate_version_increment`), 원본 요구사항이 지시한 "version 0과 1로 강제
> insert"는 `sqlite3` CLI로 DB 파일에 직접 write해 버전 검증을 우회한다 — 원본
> Action 자체가 이 방식(강제 insert)을 명시하고 있어 이는 요구사항과 일치한다.
> 클라우드 서버가 실제로 `SyncConfigurationSuccessResponse`를 응답하는지(즉
> `mark_as_synced`까지 완료되는지)는 실 Azure IoT Hub 연동이 필요해 범위 밖이다 —
> 이 TC는 db_manager가 **D2C 전송을 시도하는 지점까지**만 검증한다.

### 사전 조건

- 공통 전제 조건 충족
- `sqlite3` 로 `/edge/db/edge_storage.db`의 `configuration` (id_value 테이블,
  컬럼: key(자동증가)/value/synced 등) 에 직접 INSERT 가능
- db_manager가 정상 기동 상태 (재기동 없이 진행 가능 — 프로세스 재시작 불필요, 알림
  주입만으로 트리거)

### 절차

1. `sqlite3 /edge/db/edge_storage.db ".schema configuration"` 로 실제 컬럼 구조 확인
2. 첨부된 configuration 예시 JSON을 `"version":0`, `"version":1` 두 건으로 복제해
   `sqlite3 /edge/db/edge_storage.db "INSERT INTO configuration (value) VALUES ('<json0>');"`
   / `'<json1>'` 로 각각 강제 insert (자동증가 key가 두 새 unsynced 레코드를 생성)
3. `journalctl -u docker-loader --since "10 seconds ago" | grep db_manager` 로
   현재 로그 위치 기록(baseline)
4. `uplink_ready` 알림을 false→true 순서로 주입해 재연결 전이를 시뮬레이션:
   - `emsp/all/<SOURCE>/noti/uplink_ready` 에 `{"ready":false}` 발행
   - 곧이어 같은 토픽에 `{"ready":true}` 발행 (`NOTI_UPLINK_READY` 핸들러는 이전
     상태와 비교해 false→true 전이에서만 동기화를 트리거함 — `db_manager.cpp`
     `handle_noti_uplink_ready`)
5. `journalctl -u docker-loader --since "10 seconds ago" | grep db_manager` 로
   `SyncConfigurationRequest` 전송 로그 확인 (최대 10초 대기)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 동기화 트리거 | uplink_ready true 전이 시 `Syncing configuration to IoT Hub` 로그 출현 |
| D2C 전송 시도 | 두 unsynced 레코드(version 0, 1) 각각에 대해 `Configuration data sent to IoT Hub` 로그 출현 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | 동기화 트리거 로그 출현 | boolean | true | `journalctl -u docker-loader --since "$baseline" \| grep -F "Syncing configuration to IoT Hub"` |
| TC02-2 | unsynced 레코드 수 ≥ 2 로그 확인 | boolean | true | `journalctl ... \| grep -E "Found [0-9]+ unsynced configuration records"` 에서 숫자 ≥ 2 |
| TC02-3 | D2C 전송 시도 로그 2건 이상 | boolean | true | `journalctl ... \| grep -c "Configuration data sent to IoT Hub successfully"` ≥ 2 |

---

## TC03 — Persistent State 변경 정보 전달 (update_records 즉시 반영)

### 목적

`persistent_state` 테이블 레코드를 `update_records` 요청으로 변경하면 즉시 DB에
반영되고, 재조회(`select_records`) 시 변경된 값이 유지되는지 확인한다. (원본 Key122
— 원본 Action은 Web HMI "Basic Setting" 페이지를 통한 조작(web → energy dispatcher
→ db manager 경로)을 전제하지만, db_manager 관점에서는 최종적으로 `update_records`
IPC 요청으로 귀결되므로 이 TC는 **Web HMI를 거치지 않고 db_manager를 직접 MQTT로
호출**해 그 최종 단계만 검증한다 — 프록시 검증, Web HMI 자체 동작은 범위 밖)

### 사전 조건

- 공통 전제 조건 충족
- 값을 변경해도 안전한 임의의 `persistent_state` 키 확보 (예: 기존 키 하나를 미리
  `select_all_records`로 조회해 재사용, 원복 가능하도록 원래 값 기록)

### 절차

1. `select_records` 요청(`{"db":"edge_storage.db","table":"persistent_state","keys":["<KEY>"]}`)
   으로 원래 값 기록
2. `update_records` 요청 발행:
   - payload: `{"db":"edge_storage.db","table":"persistent_state","records":[{"key":"<KEY>","value":"<NEW_VALUE>","type":<원래 type>}]}`
   (`RecordUpdateParams`/`UpdateRecordItem` — `msg_ipc_payload.hpp:158-171`)
3. 응답의 `result` 필드 확인
4. 다시 `select_records`로 동일 키 재조회 → 값이 `<NEW_VALUE>` 로 유지되는지 확인
5. cleanup: 1번에서 기록한 원래 값으로 `update_records` 재발행해 원복

### 기대 결과

| 항목 | 기준 |
|------|------|
| update 응답 | `result:true` |
| 재조회 값 | 변경한 `<NEW_VALUE>` 와 일치 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | update_records 응답 result=true | boolean | true | `echo "$update_resp" \| grep -qE '"result"\s*:\s*true'` |
| TC03-2 | 재조회 값이 변경값과 일치 | boolean | true | `echo "$reselect_resp" \| grep -qF "\"value\":\"$NEW_VALUE\""` |
| TC03-3 | cleanup 원복 성공 | boolean | true | 원복 후 재조회 값이 원래 값과 일치 |

---

## TC04 — System Setting 변경 정보 즉시 반영 (Log Level)

### 목적

`system_setting` 테이블의 `log_level_db` 키를 `update_records` 로 변경하면
db_manager 자신의 로그 레벨이 재기동 없이 즉시 반영되는지 확인한다. (원본 Key123
— 원본은 Web HMI Service 탭에서 Log Level 변경을 전제하지만, `log_level_db` 키는
db_manager 자신의 로그 레벨만 제어하므로(태그 `[DB]`) 이 TC는 db_manager 자신을
대상으로 검증한다. HA(Host Agent)는 원본이 명시한 대로 컨테이너 밖에 있어 DB 변경
영향을 받지 않으므로 검증 대상에서 제외.)

### 사전 조건

- 공통 전제 조건 충족
- `system_setting` 테이블에 `log_level_db` 키 존재 (부팅 시 기본값 세팅됨 — 없으면
  선행 `select_records`로 미존재 확인 후 skip)

### 절차

1. `select_records({"db":"edge_storage.db","table":"system_setting","keys":["log_level_db"]})`
   로 현재 값 기록 (`ORIGINAL_LEVEL`)
2. `update_records` 요청으로 `log_level_db` 를 `0`(Debug, `SettingType::UINT8`=1)으로
   변경
3. 응답 `result:true` 확인 후, `journalctl -u docker-loader --since "5 seconds ago"`에서
   `Log level changed via update_records: 0` 로그 확인
4. `journalctl -u docker-loader -f` 를 5초간 관찰 — db_manager 태그(`[DB]`)의
   `[D]`(Debug) 레벨 로그가 새로 출현하는지 확인 (Debug 레벨 미만이던 로그가 노출됨)
5. cleanup: `ORIGINAL_LEVEL` 로 `update_records` 재발행해 원복

### 기대 결과

| 항목 | 기준 |
|------|------|
| update 응답 | `result:true` |
| 즉시 반영 로그 | `Log level changed via update_records: 0` 출현 |
| 실제 로그 레벨 | db_manager 태그의 `[D]` 로그가 새로 출력됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | update_records 응답 result=true | boolean | true | `echo "$update_resp" \| grep -qE '"result"\s*:\s*true'` |
| TC04-2 | 로그 레벨 변경 로그 출현 | boolean | true | `journalctl ... \| grep -F "Log level changed via update_records: 0"` |
| TC04-3 | Debug 레벨 로그 실제 출력 확인 | boolean | true | `journalctl -u docker-loader -f --since now \| timeout 5 grep -m1 "\[D\]\[DB\]"` exit 0 |
| TC04-4 | cleanup 원복 성공 | boolean | true | 원복 후 재조회 값이 `ORIGINAL_LEVEL` 과 일치 |

---

## TC05 — Persistent State 부팅 시점 정보 전달 (검토 필요 — 로그 태그 불일치)

> 원본(Key124)은 부팅 완료 근거로 `[I][DM] DB initialization completed: all
> system_settings, persistent_states, and device_info are loaded` 로그를 명시한다.
> 소스에서 해당 문자열 자체는 확인된다(`core/common/base_app/source/db_cache.cpp:270`,
> `DbCache::check_and_notify_initialization_complete()`), 그러나 이 로그는
> **db_manager 전용이 아니라 `BaseApp`을 상속하는 모든 앱이 자신의 DbCache 로 3종
> 셀렉트(select_all_records 응답)를 모두 받았을 때 각자 자신의 로그 태그로** 출력한다.
> db_manager 자신의 태그는 `[DB]`이고(`db_manager.cpp:86`), 코드베이스 전체에서
> `DM` 태그를 쓰는 앱은 없다(`JT`/`EL`/`IT`/`ET`/`ER`/`TA`/`AZ`/`SM`/`DB`만 확인) —
> 원본의 `[DM]` 표기가 어느 앱을 가리키는지 특정할 수 없다. 어떤 앱의 로그를
> 기준으로 판정할지 개발자 확인 후 재작성 필요.

### 목적
<TODO — 개발자 확인 후 작성: 어떤 앱(client_id)의 로그 태그를 "부팅 완료" 판정
기준으로 삼을지 확정 필요>

### 사전 조건
<TODO>

### 절차
<TODO>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC06 — System Setting 부팅 시점 정보 전달 (Log Level 재부팅 후 유지)

### 목적

`log_level_db` 를 변경한 뒤 EMS(컨테이너) 재부팅을 거쳐도 설정이 DB에 유지되고,
db_manager가 부팅 시 `load_log_level_from_db()`로 동일 레벨을 재적용하는지 확인한다.
(원본 Key125)

> 재부팅을 포함하므로 `feedback_serial_vs_ssh_polling` 관례에 따라
> `serial_helper.ps1` 기반 확인을 권장한다(SSH 폴링은 DUT 고부하 구간에서
> false-negative 가능).

### 사전 조건

- 공통 전제 조건 충족
- 컨테이너 재부팅 권한 (`docker restart ac_system_gen2` 또는 동등 절차)
- TC04에서 사용한 `ORIGINAL_LEVEL` 복원 절차를 알고 있을 것 (재부팅 전후 비교 기준)

### 절차

1. `update_records` 로 `log_level_db` 를 `0`(Debug)으로 변경, 응답 `result:true` 확인
2. 컨테이너 재부팅 트리거 (`SERVICE_SHUTDOWN_APPLICATION_FOR_SYSTEM_REBOOT` 경유 또는
   `docker restart ac_system_gen2`)
3. 재부팅 완료 대기 (시리얼 helper 로 `db_manager` 프로세스 재기동 확인)
4. `journalctl -u docker-loader --since "<재부팅시각>"` 에서
   `Loaded log_level_db from DB: 0` 로그 확인 (`load_log_level_from_db()` — `start()`
   시퀀스 내 `init_register_map()` 직후 호출)
5. `select_records` 로 `log_level_db` 값이 `0` 으로 유지되는지 재확인
6. cleanup: 원래 레벨로 복원 (재부팅 불필요, `update_records`로 즉시 복원)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 재부팅 후 DB 값 | `log_level_db=0` 유지 |
| 재부팅 후 로그 | `Loaded log_level_db from DB: 0` 출현 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | 재부팅 후 DB 값 유지 | boolean | true | 재조회 응답에 `"value":"0"` |
| TC06-2 | 부팅 시 로드 로그 출현 | boolean | true | `journalctl -u docker-loader --since "<reboot_ts>" \| grep -F "Loaded log_level_db from DB: 0"` |

---

## TC07 — Persistent State 테이블 생성/조회 (select_all_records)

### 목적

`edge_storage.db` 내 `persistent_state` 테이블이 부팅 시 생성되고,
`select_all_records` 요청으로 조회 가능한지 확인한다. (원본 Key126 "Persistent
state 초기화" + Key145 "Persistent state 테이블 생성" — 두 원본의 Action/Expected
Result 본문이 동일한 `select_all_records` 조회이므로 병합. "초기화" 자체
(factory_reset/installer_reset)를 검증하려면 별도 TC 필요 — 근거 매핑 표 참고)

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `select_all_records` 요청 발행: `{"db":"edge_storage.db","table":"persistent_state"}`
2. 응답 수신, `result`/`records` 확인
3. 원본이 예시로 제시한 `persistence_list_sync_flag` 키가 `records` 배열에 포함되는지
   확인 (기본 시드 데이터 — `initializer/persistent_state.cpp` 참고)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 | `result:true`, `table:"persistent_state"` |
| 기본 시드 레코드 | `persistence_list_sync_flag` 키 포함 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | 응답 result=true | boolean | true | `echo "$resp" \| grep -qE '"result"\s*:\s*true'` |
| TC07-2 | table 필드 일치 | boolean | true | `echo "$resp" \| grep -qE '"table"\s*:\s*"persistent_state"'` |
| TC07-3 | 기본 시드 키 포함 | boolean | true | `echo "$resp" \| grep -qF '"persistence_list_sync_flag"'` |

---

## TC08 — System Setting 테이블 생성/조회 (select_all_records)

### 목적

`edge_storage.db` 내 `system_setting` 테이블이 부팅 시 생성되고,
`select_all_records` 요청으로 조회 가능한지 확인한다. (원본 Key127 "System setting
초기화" + Key146 "System setting 테이블 생성" — 두 원본의 Action/Expected Result
본문이 동일한 `select_all_records` 조회이므로 병합, TC07과 동일한 사유)

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `select_all_records` 요청 발행: `{"db":"edge_storage.db","table":"system_setting"}`
2. 응답 수신, `result`/`records` 확인
3. 원본이 예시로 제시한 `est_server_url`(type=10/STRING), `timezone`(type=10),
   `log_level_bc`(type=1/UINT8) 키가 포함되는지 확인 (기본 시드 데이터 —
   `initializer/system_setting.cpp` 참고, 사이트 설정에 따라 일부 키는 없을 수 있음)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 | `result:true`, `table:"system_setting"` |
| 기본 시드 레코드 | `timezone` 키 포함(type=10) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | 응답 result=true | boolean | true | `echo "$resp" \| grep -qE '"result"\s*:\s*true'` |
| TC08-2 | table 필드 일치 | boolean | true | `echo "$resp" \| grep -qE '"table"\s*:\s*"system_setting"'` |
| TC08-3 | timezone 키 포함, type=10 | boolean | true | `echo "$resp" \| python3 -c "import json,sys; r=json.load(sys.stdin)['records']; assert any(x['key']=='timezone' and x['type']==10 for x in r)"` |

---

## TC09 — DB 파일 생성/저장 위치 확인

### 목적

db_manager가 데이터 저장용 SQLite 파일을 정해진 경로에 생성하는지 확인한다.
(원본 Key147)

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `ls -la /edge/db/edge_storage.db` 실행 (일반 파티션, `kDbDirectory`)
2. `ls -la /edge/sp/db/edge_storage.db` 실행 (Secure 파티션, `kSecureDbDirectory` —
   원본에는 명시되지 않았으나 소스 상 시스템/영속 설정 중 보안 키는 이 파일에
   분리 저장됨, `db_manager.hpp:53-55`)
3. `sqlite3 /edge/db/edge_storage.db ".tables"` 로 테이블 목록 확인
4. `file /edge/db/edge_storage.db` 로 SQLite DB 포맷인지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 일반 DB 파일 | `/edge/db/edge_storage.db` 존재 |
| Secure DB 파일 | `/edge/sp/db/edge_storage.db` 존재 |
| 파일 포맷 | SQLite 3.x database |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | 일반 DB 파일 존재 | boolean | true | `[ -f /edge/db/edge_storage.db ]` |
| TC09-2 | Secure DB 파일 존재 | boolean | true | `[ -f /edge/sp/db/edge_storage.db ]` |
| TC09-3 | SQLite 포맷 확인 | boolean | true | `file /edge/db/edge_storage.db \| grep -qi "SQLite 3.x database"` |
| TC09-4 | 필수 테이블 존재 | boolean | true | `sqlite3 /edge/db/edge_storage.db ".tables" \| grep -qE "system_setting\|persistent_state\|configuration"` |

---

## TC10 — Register Map 최신 정보 Cloud Sync (SyncRegisterMapRequest)

### 목적

`register_map` 테이블(id_value)에 미동기화 레코드가 있을 때 클라우드 재연결
(`uplink_ready` false→true 전이) 시 `SyncRegisterMapRequest` D2C 메시지로 전송되는지
확인한다. (원본 Key181 — 원본이 설명하는 "system_setting 테이블 내 register_map
key" 스키마는 구버전 기준이며, 현재 코드는 `TABLE_NAME_REGISTER_MAP`(별도
id_value 테이블)을 사용하므로 이를 기준으로 재구성)

> TC02와 동일하게, 실제 클라우드로부터 `SyncRegisterMapSuccessResponse` 를 받아
> `mark_as_synced` 까지 완료되는지는 실 Azure IoT Hub 연동이 필요해 범위 밖이다 —
> D2C 전송 시도 지점까지만 검증한다.

### 사전 조건

- 공통 전제 조건 충족
- `sqlite3` 로 `/edge/db/edge_storage.db` 의 `register_map` id_value 테이블에 직접
  INSERT 가능 (스키마 파악 위해 `.schema register_map` 우선 확인)
- 현재 register_map 스키마 검증(`SchemaType::REGISTER_MAP`)을 우회하기 위해
  sqlite3 직접 insert 사용 (IPC 경로인 `set_register_map_json`은 버전/스키마
  검증을 거치므로 임의 값 insert에는 부적합 — 원본이 요구하는 "아무 값이나 insert"에
  더 부합하는 것도 직접 DB write)

### 절차

1. `sqlite3 /edge/db/edge_storage.db "INSERT INTO register_map (value) VALUES ('{\"dummy\":true}');"`
   로 임의 값 강제 insert
2. `journalctl -u docker-loader --since "10 seconds ago"` 로 baseline 기록
3. TC02와 동일하게 `uplink_ready` 를 false→true 로 주입해 재연결 전이 시뮬레이션
4. `journalctl -u docker-loader --since "<baseline>"` 에서 `Syncing register map to
   IoT Hub` / `Register map data sent to IoT Hub successfully` 로그 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 동기화 트리거 | `Syncing register map to IoT Hub` 로그 출현 |
| D2C 전송 시도 | `Register map data sent to IoT Hub successfully` 로그 출현 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC10-1 | 동기화 트리거 로그 출현 | boolean | true | `journalctl -u docker-loader --since "$baseline" \| grep -F "Syncing register map to IoT Hub"` |
| TC10-2 | D2C 전송 시도 로그 출현 | boolean | true | `journalctl ... \| grep -F "Register map data sent to IoT Hub successfully"` |

---

## TC11 — 자동화 불가 항목 목록 (Web HMI 수동 조작 / 타 앱 LED 시나리오 / 실 클라우드 왕복)

이 항목들은 실제 사람의 Web HMI 클릭 조작, db_manager 범위 밖 하드웨어(LED)
시나리오, 또는 실 Azure IoT Hub 왕복 확인처럼 단일 DUT 셸 스크립트로는 검증
불가능한(또는 이 앱의 책임이 아닌) 원본 요구사항이다. TC로 변환하지 않고 목록으로만
남긴다.

| 원본 Key | 항목 | 자동화 불가/범위 제외 사유 |
|----------|------|-------------------|
| Key76 (LED 서브스텝 전체) | ALL LEDs 파워링/스캔/MI 연결/펌웨어 업데이트/Qcells Server 연결 상태별 색상 | db_manager 소스에 LED 제어 로직 없음 — 다른 카테고리(디바이스 상태 표시) 시험 항목이 잘못 병합된 것으로 추정, 개발자 확인 필요 |
| Key122 (TC-3 원본 스텝) | Web HMI `Basic Setting` 페이지 실제 클릭 조작 및 새로고침 확인 | 사람의 브라우저 조작 필요, TC03이 최종 IPC 단계만 프록시로 검증 |
| Key123 (TC-4 원본 스텝) | Web HMI `Service` 탭 Log Level 변경 UI 자체 | 사람의 브라우저 조작 필요, TC04가 최종 IPC 단계만 프록시로 검증 |
| Key125 (TC-6 원본 스텝) | Web HMI 상에서 Log Level 확인 (변경 후 화면 표시) | 사람의 브라우저 조작 필요, TC06이 DB/로그 레벨 값 자체만 검증 |
| Key121/181 (TC-2/TC-12 서버 응답 확인) | 실 Azure IoT Hub 로부터 `SyncConfigurationSuccessResponse`/`SyncRegisterMapSuccessResponse` 수신 및 `mark_as_synced` 완료 확인 | 실 클라우드 계정/네트워크 왕복 필요, TC02/TC10은 D2C 전송 시도까지만 커버 |
| Key76/126/145, Key127/146 Postman 스텝 | `/auth/token` Bearer Token 발급, REST 게이트웨이(`https://<IP>:9112/publish/...`) 경유 호출 | REST 게이트웨이 인증(auth_key/auth_secret)은 db_manager가 아닌 별도 게이트웨이 컴포넌트 소관 — 이 문서의 TC들은 MQTT로 db_manager를 직접 호출해 동일한 최종 서비스(`select_all_records` 등) 응답을 검증 |
| Key126/127 (제목상의 "초기화") | `Persistent state 초기화`/`System setting 초기화` 실제 동작(전체 삭제/기본값 복원) 검증 | 원본 Action 본문이 실제로는 초기화가 아닌 조회 스텝만 포함 — `SERVICE_REQUEST_FACTORY_RESET`/`SERVICE_PERFORM_INSTALLER_RESET` 기반의 진짜 "초기화" TC는 개발자 확인 후 별도 설계 필요 (Flag) |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `db_manager` | MQTT 수신 대상 앱 ID (`APPID_DB_MANAGER`) |
| `DB_PATH` | `/edge/db/edge_storage.db` | 일반 파티션 DB 파일 (`kDbDirectory`+`kDatabaseName`) |
| `SECURE_DB_PATH` | `/edge/sp/db/edge_storage.db` | Secure 파티션 DB 파일 (`kSecureDbDirectory`+`kDatabaseName`) |

---

## 자동화 등급 (Automation Grade)

🟡 **A (일부 준비물/개발자 확인 의존)**

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | A (자동) | `select_all_records` 직접 호출, LED 서브스텝 제외 |
| TC02 | A (자동) | `sqlite3` 강제 insert + `uplink_ready` 알림 주입으로 재현, 서버 ack까지는 범위 밖 |
| TC03 | B (프록시) | Web HMI 대신 db_manager MQTT 직접 호출로 최종 단계만 검증 |
| TC04 | A (자동) | `log_level_db` update_records + journalctl 즉시 반영 확인 |
| TC05 | Flag | 원본의 로그 태그(`[DM]`)가 코드베이스 어떤 앱과도 일치하지 않음 — 개발자 확인 후 내용 작성 대기 (본 초안에서는 placeholder) |
| TC06 | B (반자동) | 컨테이너 재부팅 포함, 시리얼 helper 권장 |
| TC07 | A (자동) | `select_all_records` 직접 호출, Key126+Key145 병합 |
| TC08 | A (자동) | `select_all_records` 직접 호출, Key127+Key146 병합 |
| TC09 | A (자동) | 파일 존재/포맷 확인 |
| TC10 | A (자동) | `sqlite3` 강제 insert + `uplink_ready` 알림 주입으로 재현, 서버 ack까지는 범위 밖 |
| TC11 | 자동화 불가 | 목록만 제공, 실행은 QA 수동 또는 개발자 확인 |

---

## 관련 문서

- `tc_db_manager_result.md` — 본 TC 실행 결과 보고서
- `tc_db_manager_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/db_manager.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx "DB Manager" 카테고리, Key 76/121-127/145-147/181, 12개 TC)

---

## 근거 매핑

| 원본 TC | 원본 제목 | 매핑된 명세 TC | 근거 (요구사항 / 코드 파일:line) | 신뢰도 |
|---|---|---|---|---|
| TC-1 (Key76) | Configuration 테이블 생성 | TC01 | 요구사항 §TC-1 select_all_records 스텝 + `db_manager.cpp:296-328`(`handle_request_select_all_records`), `db_manager.cpp:109`(`init_configuration()`) | High (양쪽 일치, LED 서브스텝은 제외) |
| TC-1 (Key76) LED 서브스텝 | LED 인디케이터 매트릭스 | TC11 | 요구사항 §TC-1 연속 스텝 다수, db_manager 소스에 대응 로직 없음 | **Flag — db_manager 범위 아님, 원본 오류 추정** |
| TC-2 (Key121) | history 정보 전달 | TC02 | 요구사항 §TC-2 + `db_manager.cpp:2477-2515`(`sync_configuration_to_iothub`), `db_manager.cpp:1386-1390`(`handle_noti_uplink_ready` false→true 트리거), `db_manager.cpp:2532`(`send_d2c_message("SyncConfigurationRequest",...)`) | High (양쪽 일치, 서버 ack 왕복은 TC11에 별도 명시) |
| TC-3 (Key122) | Persistent state 변경 정보 전달 | TC03 | 요구사항 §TC-3 (Web HMI 경로) + `db_manager.cpp:366-488`(`handle_request_update_records`) | Medium (Web HMI 자체는 검증 밖, 최종 IPC 단계만 프록시 검증) |
| TC-4 (Key123) | System setting 변경 정보 전달 | TC04 | 요구사항 §TC-4 + `db_manager.cpp:403-406,467-470`(update_records 내 `log_level_db` 즉시 반영), `db_manager.cpp:1399-1418`(`handle_noti_system_settings_changed`) | High (양쪽 일치, HA 컨테이너 예외는 원본 그대로 반영해 검증 대상에서 제외) |
| TC-5 (Key124) | Persistent state 시작 시점 정보 전달 | TC05 | 요구사항 §TC-5 로그 문구 + `db_cache.cpp:264-271`(`check_and_notify_initialization_complete`, 문구 일치) vs. 태그 `[DM]`이 어느 앱인지 코드에서 특정 불가 | **Flag — 로그 문구는 일치하나 태그 불일치, 개발자 확인 필요** |
| TC-6 (Key125) | System setting 시작 시점 정보 전달 | TC06 | 요구사항 §TC-6 + `db_manager.cpp:112-113,2879-2906`(`load_log_level_from_db()`, `start()` 시퀀스 내 호출) | High (양쪽 일치) |
| TC-7 (Key126) | Persistent state 초기화 (제목) / 실제 내용은 select_all_records | TC07 | 요구사항 §TC-7 Action/Expected Result 본문이 Key145와 동일 + `db_manager.cpp:296-328` | Medium (제목 "초기화"와 실제 검증 내용 불일치 — 진짜 초기화 로직은 `handle_request_factory_reset`/`handle_request_perform_installer_reset`, `db_manager.cpp:1229-1356`, 별도 TC 필요) |
| TC-8 (Key127) | System setting 초기화 (제목) / 실제 내용은 select_all_records | TC08 | 요구사항 §TC-8 Action/Expected Result 본문이 Key146과 동일 + `db_manager.cpp:296-328` | Medium (TC-7과 동일 사유) |
| TC-9 (Key145) | Persistent state 테이블 생성 | TC07 (Key126과 병합) | 요구사항 §TC-9 select_all_records 응답 예시(`persistence_list_sync_flag`) + `initializer/persistent_state.cpp`, `db_manager.cpp:296-328` | High (양쪽 일치) |
| TC-10 (Key146) | System setting 테이블 생성 | TC08 (Key127과 병합) | 요구사항 §TC-10 select_all_records 응답 예시(`est_server_url`,`timezone`,`log_level_bc`) + `initializer/system_setting.cpp`, `db_manager.cpp:296-328` | High (양쪽 일치) |
| TC-11 (Key147) | DB 파일 관리 | TC09 | 요구사항 §TC-11 (`/edge/db/edge_storage.db`) + `db_manager.hpp:53-55`(`kDbDirectory`, `kDatabaseName`) | High (양쪽 일치, Secure 파티션 경로는 코드에서만 확인되어 보완 추가) |
| TC-12 (Key181) | 최신 정보 Cloud sync (Register Map) | TC10 | 요구사항 §TC-12 + `db_manager.cpp:2612-2650`(`sync_register_map_to_iothub`), `db_manager.cpp:2600`(`send_d2c_message("SyncRegisterMapRequest",...)`) — 단, 원본이 설명하는 DB 스키마(system_setting 내 key)는 구버전 기준이며 현재는 `TABLE_NAME_REGISTER_MAP` 별도 테이블 | Medium (동기화 메커니즘은 일치, 원본의 스키마 설명은 outdated — 현재 스키마로 재해석) |
| — | REST 게이트웨이 Postman 인증(`/auth/token`) | TC11 | 요구사항 §TC-1/7/8/9/10 Postman 스텝, db_manager 소스에 해당 로직 없음(별도 게이트웨이 컴포넌트) | Flag — db_manager 범위 아님, MQTT 직접 호출로 대체 |
