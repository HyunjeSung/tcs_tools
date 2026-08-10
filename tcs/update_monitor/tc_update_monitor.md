---
spec_id: update_monitor
suite: application
grade: A
phase: Phase 1
test_file: tcs/update_monitor/tc_update_monitor.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-UPDATE_MONITOR: update_monitor — SWU/OTA 원격 업데이트 처리

## 목적 (Objective)

`update_monitor` 애플리케이션의 SWU 파일 기반 로컬 배치 업데이트(`swupdate -i` 직접
실행), Azure Device Update(ADU) 연동에 의한 원격(OTA) 업데이트, 펌웨어 다운로드
세션의 영속화·재개(resume), 무결성/서명/HW 호환성 검증, 리소스 사전 점검, 진행률
알림(MQTT)까지 update_monitor가 책임지는 전 기능을 검증한다.

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "Remote Update" 카테고리 원본 16개
TC(Key 101-108, 128-135, `docs/tc_requirements/update_monitor.md`)를 기준으로
작성했다. 원본 다수가 사람이 Web HMI를 조작하거나 실제 Azure IoT Hub/ADU 클라우드
연동을 전제로 하므로, 본 문서는 그중 **DUT에 SSH/시리얼로 접속해 셸 스크립트로
자동 검증 가능한 부분만 TC로 재구성**했고, 클라우드/HMI 의존 항목은 TC12에
자동화 불가 항목으로 별도 명시했다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `update_monitor` 프로세스 실행 중 (`pgrep -f update_monitor`)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨
- `sys_manager` 프로세스 실행 중 (`SERVICE_CMD_HOST` 응답 담당 — 배치 업데이트가
  실제 `swupdate -i`를 실행하는 경로)
- root 권한 (`/tmp/edge/update/`, `/edge/etc/update-history/`,
  `/edge/docker/update_monitor/custom_downloader/` 쓰기 가능)
- `journalctl -u docker-loader` 로 update_monitor 로그 확인 가능

> **주의(파괴적 시험 가능성):** TC01/TC04/TC06/TC07/TC08/TC10/TC11 중 일부는
> `swupdate -i` 를 실제로 기동하거나 배치 큐 상태를 변경한다. 실제 신호서명된
> `.swu` 이미지가 없는 상태에서는 해당 서브스텝(실제 flash 완료까지 확인하는 부분)을
> **프로토콜/로그 레벨 검증으로 대체**했다 — 각 TC 절차에 이 대체 범위를 명시한다.

---

## TC01 — Batch Update 요청 프로토콜 (수락/거부/우선순위 정렬)

### 목적

`batch_update_request` IPC 요청이 파일 목록을 큐에 적재하고 `device_type` 기준
우선순위로 정렬하며, 이미 배치가 진행 중일 때 신규 요청을 거부하는지 확인한다.
(원본 Key101 "로컬 .swu 업데이트" 의 IPC 프로토콜 레벨 서브셋 — 실제 flash 완료까지의
검증은 실서명 `.swu` 필요로 범위 밖이며 TC12에 명시)

### 사전 조건

- 공통 전제 조건 충족
- update_monitor가 IDLE 상태(`batch_update_status` 응답의 배치 상태가 `NONE`)
- 더미 파일 경로 사용 가능 (`/tmp/tc_um_dummy_bms.swu`, `/tmp/tc_um_dummy_mpu.swu` 등 —
  실제 이미지 내용은 불필요, `file_path`/`device_type` 필드만 검증 대상)

### 절차

1. `batch_update_status` 요청으로 현재 배치 상태가 `NONE`(유휴)인지 확인
2. `files` 배열에 `device_type="mpu"`(우선순위 낮음, 나중 실행) 와
   `device_type="bms"`(우선순위 높음, 먼저 실행) 를 **mpu, bms 순서로** 담아
   `batch_update_request` 발행
3. 응답 수신 후 `batch_update_status` 조회 → 큐 내부 순서가 `bms → mpu` 로
   정렬되었는지 확인 (journald의 `[BATCH_UPDATE] Queue AFTER sort` 로그로 교차 확인)
4. 배치가 아직 `NONE`(또는 `COMPLETED`)으로 리셋되지 않은 상태에서 두 번째
   `batch_update_request` 를 즉시 발행 → 응답 `result` 필드가 `"rejected"`, `reason`이
   `"Batch update already in progress"` 인지 확인
5. `files` 배열을 빈 배열(`[]`)로 채운 요청 발행 → `"rejected"` + `"Missing or empty
   'files' array in request"` 확인
6. cleanup: 진행 중인 배치가 있다면 완료/타임아웃까지 대기하거나 update_monitor 재시작

### 기대 결과

| 항목 | 기준 |
|------|------|
| 큐 우선순위 정렬 | `bms`가 `mpu`보다 먼저 실행되도록 정렬됨 |
| 중복 요청 거부 | 진행 중 상태에서 신규 요청 시 `result="rejected"` |
| 빈 배열 거부 | `files` 배열 누락/공백 시 `result="rejected"` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | 큐 정렬 후 `bms`가 `mpu`보다 앞 인덱스 | boolean | true | `journalctl -u docker-loader --since "1 minute ago" \| grep -A5 '\[BATCH_UPDATE\] Queue AFTER sort'` 출력에서 `device=bms`가 `device=mpu`보다 먼저 출현 |
| TC01-2 | 중복 배치 요청 거부 | boolean | true | 두 번째 응답 payload에 `"result":"rejected"` 및 `"already in progress"` 포함 |
| TC01-3 | 빈 files 배열 거부 | boolean | true | 응답 payload에 `"result":"rejected"` 및 `"Missing or empty"` 포함 |

---

## TC02 — ADU Step Manifest 단계별 상태 전이 (is-installed/download/install/apply)

### 목적

ADU 업데이트 핸들러 스크립트(`microsoft/script:1`)가 각 단계 완료 시 남기는
`<step>.done` 파일을 update_monitor가 감지·파싱하여 MQTT로 상태를 알리는지
확인한다. (원본 Key102 "Script Manifest 단계별 상태 검증", Key133 "진행 단계별
result.json 생성" — 두 원본은 동일 메커니즘의 서로 다른 표현이라 하나의 TC로 통합)

> 원본 요구사항의 `simulation-script2.sh`는 저장소에 포함되어 있지 않아 재사용할
> 수 없다. 대신 그 스크립트가 최종적으로 만드는 산출물(`<step>.done` 파일 +
> 동일한 JSON 내용)을 직접 생성해 update_monitor의 감지 로직만 독립적으로 검증한다
> — 스크립트 자체의 정상 동작은 이 TC의 범위 밖이다.

### 사전 조건

- 공통 전제 조건 충족
- `/tmp/edge/update/` 디렉토리 쓰기 가능 (없으면 생성)
- update_monitor가 현재 활성 ADU work folder를 갖고 있지 않은 상태(정상 유휴 상태) —
  그래야 `.done` 탐색이 `/tmp/edge/update/<step>.done` 폴백 경로를 사용함
- `mosquitto_sub`로 `emsp/all/update_monitor/noti/adu_update_notification` 구독 가능

### 절차

각 단계(`is-installed`, `download`, `install`, `apply`)에 대해 반복:

1. `mosquitto_sub -t emsp/all/update_monitor/noti/adu_update_notification -C 1 -W 15` 를
   백그라운드로 구독 시작
2. 요구사항 원본과 동일한 JSON을 `/tmp/edge/update/<step>.done` 에 기록:
   ```json
   {"step": "<step>", "resultCode": <해당 코드>, "timestamp": "<ISO8601>"}
   ```
   (resultCode: is-installed=901, download=500, install=600, apply=700 — 원본 표 그대로)
3. update_monitor의 100ms 폴링 주기를 감안해 최대 3초 대기
4. 구독된 MQTT 알림 수신 확인 → payload의 `workflow_step`, `result_code` 가
   기록한 값과 일치하는지 확인
5. `journalctl -u docker-loader --since "10 seconds ago"` 에서
   `[UPDATE] .done file detected for step: <step>` 로그 확인
6. cleanup: 다음 단계 진행 전 `/tmp/edge/update/<step>.done` 삭제 (mtime 변경으로
   재감지되도록)

### 기대 결과

| 항목 | 기준 |
|------|------|
| MQTT 알림 | 각 단계마다 `adu_update_notification` 수신, `workflow_step`/`result_code` 일치 |
| 로그 | `.done file detected for step: <step>` 출현 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | is-installed 단계 알림 수신 (resultCode=901) | boolean | true | 수신 payload에 `"workflow_step":"is-installed"` 및 `"result_code":901` |
| TC02-2 | download 단계 알림 수신 (resultCode=500) | boolean | true | 수신 payload에 `"workflow_step":"download"` 및 `"result_code":500` |
| TC02-3 | install 단계 알림 수신 (resultCode=600) | boolean | true | 수신 payload에 `"workflow_step":"install"` 및 `"result_code":600` |
| TC02-4 | apply 단계 알림 수신 (resultCode=700) | boolean | true | 수신 payload에 `"workflow_step":"apply"` 및 `"result_code":700` |
| TC02-5 | 4단계 모두 `.done file detected` 로그 존재 | boolean | true | `journalctl -u docker-loader \| grep -c '.done file detected'` ≥ 4 |

---

## TC03 — ADU Agent 로그 기반 연동 상태 확인

### 목적

ADU Agent(`adu-agent-service`, 외부 바이너리)가 IoT Hub 모듈 연결을 시도·유지하는
과정에서 남기는 로그를, update_monitor가 자신의 로그 모니터링 스레드
(`aduLogPath_ = /tmp/edge/update/deviceupdate-agent.log`)로 관찰 가능한지 확인한다.
(원본 Key104 "ADU Agent 모듈 자동 생성"/"IoT Hub 연결 성공"의 로그 레벨 서브셋 — 실제
IoT Hub 등록·모듈 자동 생성 여부는 Azure 포털 확인이 필요해 범위 밖)

### 사전 조건

- 공통 전제 조건 충족
- `adu-agent-service` 가 systemd 유닛으로 존재 (`systemctl status adu-agent-service`
  또는 `pgrep -f AducIotAgent` 로 확인 — 미기동 상태라도 TC03-1/TC03-3 은 파일
  존재/설정값 확인만으로 판정 가능)
- `/tmp/edge/update/deviceupdate-agent.log` 읽기 가능 (adu-agent-service가 실행 중이면
  갱신됨)

### 절차

1. `/edge/etc/user-config/adu/du-config.json` 존재 및 `connectionType`/`manufacturer`
   / `model` 필드 확인 (update_monitor가 `sync_adu_model_from_configuration()`으로
   갱신하는 파일)
2. `/tmp/edge/update/deviceupdate-agent.log` 존재 여부 확인 (없으면 TC03-2/3는 skip 처리)
3. 존재 시 원본 요구사항이 제시한 로그 패턴 확인:
   - `Attempting to create connection to IoTHub using type: ADUC_ConnType_Module`
   - `Successfully re-authenticated the IoT Hub connection`
4. `journalctl -u docker-loader --since "1 hour ago"` 에서 update_monitor의
   `ADU Status Changed` / `Workflow ID updated to:` 로그 유무 확인 (최근 ADU 활동 여부)

### 기대 결과

| 항목 | 기준 |
|------|------|
| du-config.json | 존재하며 필수 필드 포함 |
| ADU 로그(존재 시) | Module 연결 시도/재인증 로그 패턴 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | du-config.json 존재 및 JSON 파싱 가능 | boolean | true | `python3 -c "import json;json.load(open('/edge/etc/user-config/adu/du-config.json'))"` exit 0 |
| TC03-2 | ADU 로그에 Module 연결 시도 로그 존재 (로그 파일 있을 시) | manual | — | `grep -F "ADUC_ConnType_Module" /tmp/edge/update/deviceupdate-agent.log` — 파일 부재 시 수동 확인으로 대체 |
| TC03-3 | ADU 로그에 재인증 성공 로그 존재 (로그 파일 있을 시) | manual | — | `grep -F "Successfully re-authenticated" /tmp/edge/update/deviceupdate-agent.log` — 파일 부재 시 수동 확인으로 대체 |

---

## TC04 — Firmware Download 세션 영속화 및 프로세스 재시작 후 Resume

### 목적

`start_firmware_download` 로 시작된 다운로드 세션이 `/edge/docker/update_monitor/
custom_downloader/<session_id>/` 하위에 `session_state.json` 등 영속 상태를 남기고,
update_monitor 프로세스가 재시작돼도(`kill -9` 후 edge_runtime 재기동) 동일
`session_id`로 세션을 복구하는지 확인한다. (원본 Key106 "중단, 이어받기, 재시작
지원" — ADU/`.swu` 이미지 다운로드가 아닌 **update_monitor 자체 펌웨어 다운로더**의
resume 기능. `docs/FIRMWARE_RESUME_DOWNLOAD_DESIGN.md` 에 설계 문서 존재)

### 사전 조건

- 공통 전제 조건 충족
- `/edge/docker/update_monitor/custom_downloader/` 쓰기 가능
- `get_firmware_download_status` / `start_firmware_download` MQTT 요청 가능
- `pgrep -f update_monitor`, `kill -9` 사용 가능, edge_runtime이 update_monitor
  비정상 종료 시 자동 재시작하는 상태

### 절차

1. `get_firmware_download_status` 요청 → 현재 활성 세션이 없는지(`active:false`) 확인
2. 테스트용 lookup 정보(존재하지 않아도 되는 워크플로 ID 등)로 `start_firmware_download`
   요청 발행 — 실제 원격 서버 접근이 실패하더라도 세션은 생성되고 상태 파일이 먼저
   기록되는지가 검증 대상
3. `session_id` 를 응답 또는 `get_firmware_download_status` 에서 획득
4. `/edge/docker/update_monitor/custom_downloader/<session_id>/session_state.json` 존재
   확인, `phase` 필드 기록
5. `kill -9 $(pgrep -f /edge/app/bin/update_monitor)` → edge_runtime 재시작 대기(최대 30초)
6. 재시작 후 `journalctl -u docker-loader --since "30 seconds ago"` 에서
   `recover_firmware_download_sessions` 관련 로그(세션 복구 시도) 확인
7. `get_firmware_download_status` 재조회 → 동일 `session_id` 가 다시 보고되는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 세션 상태 파일 | `session_state.json` 생성됨 |
| 재시작 후 복구 | 동일 `session_id` 로 세션 상태 재보고 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | 세션 상태 파일 생성 | boolean | true | `[ -f /edge/docker/update_monitor/custom_downloader/$SESSION_ID/session_state.json ]` |
| TC04-2 | 재시작 후 동일 session_id 로 복구 | boolean | true | 재조회 응답의 `session_id` 가 재시작 전 값과 동일 |
| TC04-3 | 재시작 로그에 세션 복구 시도 흔적 | boolean | true | `journalctl -u docker-loader --since "30 seconds ago" \| grep -i "recover"` 결과 비어있지 않음 |

---

## TC05 — 리소스 사전 점검 설정 (검토 필요 — 소스 내 미확인)

> Key107(`/etc/adu-resource-limit.conf`, `MIN_DISK_KB`/`MIN_MEM_KB`, resultCode 905001/905002)에
> 해당하는 구현을 update_monitor 소스 전체에서 찾지 못했다. 이 기능이 실제로 이 앱 소관인지,
> 다른 앱(sys_manager 등) 소관인지, 아니면 미구현 상태인지 개발자 확인 후 TC 내용을 채운다.

### 목적
<TODO — 개발자 확인 후 작성>

### 사전 조건
<TODO>

### 절차
<TODO>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC06 — 다운로드 중 네트워크 단절 시 재시도

### 목적

`FirmwarePackageDownloader` 가 HTTPS 전송 중 네트워크 오류를 만나면 재시도하고,
SAS URL 만료 시 원 lookup context로 새 manifest를 받아 동일 세션을 이어가는지
확인한다. (원본 Key108 "네트워크 장애 복구 지원")

### 사전 조건

- 공통 전제 조건 충족
- `iptables` 또는 `tc` 로 특정 목적지(다운로드 서버) 트래픽을 일시 차단할 권한
- TC04와 동일한 `start_firmware_download` 세션 구성 가능

### 절차

1. `start_firmware_download` 요청으로 다운로드 세션 시작
2. `get_firmware_download_status` 로 `phase="downloading"` 진입 확인
3. 다운로드 대상 호스트로의 아웃바운드 트래픽을 `iptables -A OUTPUT -d <host> -j DROP`
   으로 차단
4. `get_firmware_download_status` 를 반복 조회해 `retry_count` 증가 및
   `phase` 가 `downloading`/`retry` 관련 상태로 유지되는지 확인 (즉시 `failed`로
   전이되지 않아야 함)
5. `iptables -D OUTPUT -d <host> -j DROP` 로 차단 해제
6. 다운로드가 재개되어 `downloaded_bytes` 가 증가하는지 확인
7. cleanup: 세션 취소 또는 완료 대기, iptables 규칙 제거 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 차단 중 상태 | 즉시 실패하지 않고 retry_count 증가 |
| 차단 해제 후 | 다운로드 재개, downloaded_bytes 증가 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | 네트워크 차단 중 즉시 failed로 전이하지 않음 | boolean | true | 차단 후 30초 이내 상태 조회 결과 `phase != "failed"` |
| TC06-2 | retry_count 증가 | boolean | true | `[ "$retry_after" -gt "$retry_before" ]` |
| TC06-3 | 차단 해제 후 다운로드 재개 | boolean | true | `[ "$bytes_after_unblock" -gt "$bytes_before_unblock" ]` |
| TC06-4 | iptables 규칙 정리 완료 | boolean | true | `iptables -L OUTPUT -n \| grep -q "<host>"` 결과 없음 |

---

## TC07 — Manifest SHA256 해시 불일치 시 다운로드 차단

### 목적

`FirmwarePackageDownloader`가 artifact manifest의 `sha256`/`sha256Hash` 필드와
실제 다운로드된 파일의 해시가 불일치할 때 `hash_mismatch` 실패 클래스로 처리하고
설치로 진행하지 않는지 확인한다. (원본 Key129 "SHA256 해시 불일치 시 업데이트 실패"
서브항목)

> 기본 빌드는 manifest에 `sha256`이 없거나 형식이 안 맞아도 관대하게 통과시키는
> DEBUG 모드다 (`UPDATE_MONITOR_FW_DEBUG_REQUIRE_SHA256` 환경변수가 0/미설정이면
> 해시 검증을 스킵). 이 TC는 **의도적으로 잘못된 sha256 값을 manifest에 주입**해
> 불일치 검출 자체가 동작하는지 확인한다 — strict 모드 여부와 무관하게 "제공된
> 해시와 실제 다른 값"은 항상 실패로 처리되어야 한다.

### 사전 조건

- 공통 전제 조건 충족
- `start_firmware_download` 요청에 임의 manifest(또는 lookup 응답)를 주입할 수 있는
  테스트 경로 확보 — 실제 클라우드 lookup 서버 대신 로컬에서 manifest를 직접
  캐시 파일로 배치하거나, mock lookup(`OTA_MOCK_LOOKUP_INSECURE`)이 빌드에
  활성화된 테스트 바이너리 필요 (프로덕션 빌드에서는 이 서브스텝 자동화 불가 —
  아래 TC07-1만 프로덕션에서 재현 가능)

### 절차

1. (mock/test 빌드 전용) 정상 크기의 더미 파일을 준비하고, manifest의
   `sha256` 필드에 실제 해시가 아닌 임의 64자리 hex 값을 기입
2. `start_firmware_download` 요청 발행
3. `get_firmware_download_status` 로 `failure_class` 필드 확인
4. `journalctl -u docker-loader` 에서 해시 불일치 관련 로그(`hash mismatch`,
   `hash_mismatch`) 확인
5. `ready_to_install` 이 계속 `false` 로 유지되어 `install_ready_firmware` 로 이어지지
   않는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| failure_class | `hash_mismatch` |
| ready_to_install | `false` 유지 |
| 설치 전이 | install_ready_firmware 로 진행되지 않음 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | 상태 응답의 failure_class가 hash_mismatch | boolean | true | `echo "$status_resp" \| grep -qE '"failure_class"\s*:\s*"hash_mismatch"'` |
| TC07-2 | 로그에 해시 불일치 근거 존재 | boolean | true | `journalctl -u docker-loader --since "1 minute ago" \| grep -i "hash mismatch"` |
| TC07-3 | ready_to_install=false 유지 | boolean | true | `echo "$status_resp" \| grep -qE '"ready_to_install"\s*:\s*false'` |

---

## TC08 — .swu 서명/AES 키 훼손 파일 업데이트 차단 (수동 준비물 필요)

### 목적

RSA 서명 또는 AES 키가 훼손된 `.swu` 파일로 로컬 업데이트를 시도했을 때
`swupdate -i` 가 실패하고 update_monitor가 이를 배치 실패로 정확히 보고하는지
확인한다. (원본 Key105)

배치 실행 시 update_monitor가 실제로 실행하는 명령은 다음과 같이 코드에
고정되어 있다:

```
TMPDIR='/edge/etc/swupdate' swupdate -i <file> -k /edge/sp/secrets/swupdate/swu_rsa_pub.pem -K /edge/sp/secrets/swupdate/swu_aes_cbc.key
```

즉 이 TC는 ADU/Web HMI 없이 **`batch_update_request` 로 직접 로컬에서 재현
가능**하다. 다만 "RSA 서명이 훼손된 `.swu`"와 "AES 키가 훼손된 `.swu`" 자체는
정상 서명된 이미지를 변조해서 만들어야 하므로(원본 요구사항도 "용량 문제로 첨부
불가, Jira AGSRS-286 참고"로 되어 있어 이 저장소에는 포함되어 있지 않다), **해당
파일을 테스트 담당자가 사전에 준비해 DUT에 배치해야 자동 실행 가능**하다.

### 사전 조건

- 공통 전제 조건 충족
- 훼손된 `.swu` 파일 2종(RSA 서명 훼손, AES 키 훼손)을 DUT의 특정 경로에
  사전 배치 (예: `/tmp/tc_um_bad_sig.swu`, `/tmp/tc_um_bad_aes.swu`) — **본 TC 스크립트가
  자체 생성하지 않음, 준비물 부재 시 skip**
- `sys_manager` 를 통한 `SERVICE_CMD_HOST` 응답 경로 정상 동작

### 절차

각 훼손 파일에 대해:

1. `batch_update_request` 로 해당 파일 1개만 담아 요청 (device_type은 실제 파일에
   맞는 값 사용)
2. `batch_update_status` 를 폴링하며 완료(`result != "pending"`) 대기
3. `result="failed"` 확인, `error_msg` 필드 내용 확인
4. `journalctl -u docker-loader` 에서 원본이 명시한 로그 패턴 확인:
   - RSA 훼손: `EVP_DigestVerifyFinal failed`
   - AES 훼손: `Decryption error` / `bad decrypt`

### 기대 결과

| 항목 | 기준 |
|------|------|
| 배치 결과 | `result="failed"` |
| RSA 훼손 로그 | `EVP_DigestVerifyFinal failed` 패턴 확인 |
| AES 훼손 로그 | `bad decrypt` 패턴 확인 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | 준비물 부재 시 SKIP (FAIL 아님) | info | — | `[ -f /tmp/tc_um_bad_sig.swu ] \|\| echo SKIP_NO_ARTIFACT` |
| TC08-2 | RSA 서명 훼손 시 batch 결과 failed | boolean | true | `batch_update_status` 응답의 `result="failed"` |
| TC08-3 | RSA 훼손 로그 패턴 존재 | boolean | true | `journalctl -u docker-loader \| grep -F "EVP_DigestVerifyFinal failed"` |
| TC08-4 | AES 키 훼손 시 batch 결과 failed | boolean | true | `batch_update_status` 응답의 `result="failed"` |
| TC08-5 | AES 훼손 로그 패턴 존재 | boolean | true | `journalctl -u docker-loader \| grep -F "bad decrypt"` |

---

## TC09 — sw-description HW 호환성(hwrevision) 검사

### 목적

`.swu` 내부 `sw-description`에 선언된 hardware-compatibility 목록과 디바이스의
`/etc/hwrevision` 이 일치하지 않으면 SWUpdate가 install 단계 이전에 업데이트를
차단하는지 확인한다. (원본 Key132)

> 이 검사는 update_monitor 자체 로직이 아니라 **SWUpdate 바이너리의 네이티브
> 기능**이다 (`SWUPDATE_HW_COMPATIBILITY_FILE=/etc/hwrevision`, swupdate 빌드
> defconfig에 설정됨). update_monitor는 `swupdate -i` 를 그대로 호출할 뿐이므로,
> 이 TC는 SWUpdate 자체의 동작을 검증하되 트리거는 update_monitor의
> `batch_update_request` 경로를 사용한다.

### 사전 조건

- 공통 전제 조건 충족
- `/etc/hwrevision` 파일 존재 및 현재 값 확인 가능
- 디바이스 모델과 다른 hardware-compatibility 값을 선언한 테스트용 `.swu` 파일
  사전 준비 (본 TC 스크립트가 자체 생성하지 않음 — 서명 키가 필요하므로 준비물
  부재 시 skip)

### 절차

1. `cat /etc/hwrevision` 으로 현재 디바이스 HW 리비전 확인
2. (준비물 있을 시) 다른 hardware-compatibility 값을 가진 `.swu` 로
   `batch_update_request` 발행
3. `batch_update_status` 폴링 → `result="failed"` 확인
4. `journalctl -u docker-loader` 에서 SWUpdate의 HW 호환성 실패 로그(예:
   `not compatible with hardware`) 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| /etc/hwrevision | 존재하며 값 확인 가능 |
| 불일치 이미지 | (준비물 있을 시) install 이전 차단, batch result=failed |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | /etc/hwrevision 존재 | boolean | true | `[ -f /etc/hwrevision ]` |
| TC09-2 | 준비물 부재 시 SKIP (FAIL 아님) | info | — | `[ -f /tmp/tc_um_bad_hw.swu ] \|\| echo SKIP_NO_ARTIFACT` |
| TC09-3 | 준비물 있을 시: HW 불일치로 batch 실패 | manual | — | `batch_update_status` 응답 `result="failed"` + 로그 패턴 수동 확인 |

---

## TC10 — 업데이트 진행률 MQTT 알림

### 목적

update_monitor가 SWUpdate 진행률 소켓(`/edge/etc/swupdate/swupdateprog`)에서 받은
진행 정보를 `swupdate_progress` / `device_update_progress` / `adu_download_progress`
MQTT 알림으로 재발행하는지 확인한다. (원본 Key130 "업데이트 진행률 실시간 확인",
Key134 "외부 컨테이너 진행 상태 모니터링" 은 원본이 WebSocket을 전제하지만 코드
내 WebSocket 서버가 발견되지 않아 **MQTT 구독으로 재해석**했다 — 아래 매핑 표 Flag 참고)

### 사전 조건

- 공통 전제 조건 충족
- `mosquitto_sub` 로 `emsp/all/update_monitor/noti/+` 와일드카드 구독 가능
- 실제 업데이트가 트리거되어 진행 중인 상태 필요 (TC01/TC08 등에서 배치 업데이트를
  트리거한 직후 실행 권장 — 이 TC 단독으로는 진행률을 발생시키는 소스가 없음)

### 절차

1. `mosquitto_sub -t "emsp/all/update_monitor/noti/+" -v` 백그라운드 구독 시작,
   출력을 파일로 저장
2. TC01 또는 TC08 절차로 배치 업데이트(local `.swu`) 트리거
3. 최대 120초 동안 구독 로그 수집
4. 수집된 로그에서 `swupdate_progress` 또는 `device_update_progress` 토픽의
   `cur_percent`/`progress` 값을 시간순으로 추출
5. 값이 단조 비감소(0 → 100 방향)로 변화하는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 진행률 알림 | 1회 이상 수신 |
| 진행률 추세 | 시간순 비감소 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC10-1 | swupdate_progress 또는 device_update_progress 알림 1회 이상 수신 | boolean | true | 구독 로그 파일에 `noti/swupdate_progress` 또는 `noti/device_update_progress` 라인 존재 |
| TC10-2 | 진행률 값이 시간순 비감소 | boolean | true | 추출한 percent 값 배열이 정렬 순서와 동일 (`sort -n` 결과와 원본 비교) |

---

## TC11 — Docker 이미지 기반 배포 PRECHECK 및 컨테이너/볼륨 상태 확인

### 목적

Docker Pull/Load 방식 SWUpdate 핸들러(`swupdate-image-docker-pull`,
`swupdate-image-docker-load`)가 설치 전 update_monitor에 `update_precheck` MQTT
요청을 보내고 응답을 받는 연동 경로가 살아있는지, 그리고 업데이트 전후로 기존
컨테이너/Docker Volume이 보존되는지 확인한다. (원본 Key128 "컨테이너 기반 배포",
Key131 "기존 컨테이너 및 볼륨 데이터 보존", Key135 "Docker Load/Pull 지원" — 세
원본 모두 최종적으로 동일한 docker-pull/docker-load 핸들러 스크립트 경로를
공유하므로 하나의 TC로 통합)

> 핸들러 스크립트(`sources/meta-qcells-edge-apps/recipes-edge-update/
> swupdate-image-docker-{pull,load}/files/script-preinstall.sh`)는 `update_monitor`
> 소스가 아니라 SWUpdate 핸들러 레이어에 있다. 이 TC는 update_monitor가 노출하는
> `update_precheck` MQTT 서비스의 응답 프로토콜만 검증하고, 실제 `docker pull`/
> `docker load` 실행 및 이미지 다운로드 성공 여부는 실 `.swu` 이미지가 있어야
> 확인 가능해 범위 밖(TC12 참고)이다.

### 사전 조건

- 공통 전제 조건 충족
- `docker ps`, `docker images`, `docker volume ls` 사용 가능
- 최소 1개의 실행 중인 컨테이너와 마운트된 Volume 존재 (일반 EMS+ 운영 상태로 충분)

### 절차

1. `docker ps --format '{{.Names}}'` 로 `BEFORE_CONTAINERS` 스냅샷 기록
2. `docker volume ls --format '{{.Name}}'` 로 `BEFORE_VOLUMES` 스냅샷 기록
3. 핸들러 스크립트가 실제로 보내는 것과 동일한 형식으로 `update_precheck` 요청을
   `trigger_type="local_script"`, `source="swupdate_docker_pull_pre_script"` 로 직접
   발행 (핸들러 스크립트 실행 없이 프로토콜만 재현)
4. update_monitor의 응답(`emsp/host_script/update_monitor/res/update_precheck`)이
   15초 이내 수신되는지 확인
5. `docker ps`, `docker volume ls` 재조회 → `BEFORE_CONTAINERS`/`BEFORE_VOLUMES` 와
   동일한지 확인 (이 TC 자체는 실제 업데이트를 수행하지 않으므로 변화가 없어야
   정상 — "보존"의 baseline 검증)

### 기대 결과

| 항목 | 기준 |
|------|------|
| PRECHECK 응답 | 15초 이내 수신 |
| 컨테이너 목록 | PRECHECK 요청 전후 불변 |
| Volume 목록 | PRECHECK 요청 전후 불변 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC11-1 | update_precheck 응답 수신 | boolean | true | `[ -n "$precheck_resp" ]` |
| TC11-2 | 컨테이너 목록 불변 (이 TC 범위에서 실제 flash 미수행) | boolean | true | `diff <(echo "$BEFORE_CONTAINERS") <(docker ps --format '{{.Names}}')` 결과 없음 |
| TC11-3 | Volume 목록 불변 | boolean | true | `diff <(echo "$BEFORE_VOLUMES") <(docker volume ls --format '{{.Name}}')` 결과 없음 |

---

## TC12 — 자동화 불가 항목 목록 (클라우드 OTA 전체 흐름 / Web HMI 수동 조작)

이 항목들은 실제 Azure IoT Hub/ADU 포털 접근, 사람의 Web HMI 클릭 조작, 또는
대량 장비 그룹 배포처럼 단일 DUT 셸 스크립트로는 검증 불가능한 원본 요구사항이다.
TC로 변환하지 않고 목록으로만 남긴다 — 실행이 필요하면 QA가 수동으로 Azure
포털/Web HMI(`http://192.168.10.20:9111` 등)에 접속해 원본 문서
(`docs/tc_requirements/update_monitor.md`)의 절차를 그대로 따른다.

| 원본 Key | 항목 | 자동화 불가 사유 |
|----------|------|-------------------|
| Key101 (ADU Push 서브스텝) | ADU 클라우드에서 실제 Push 업데이트 배포 | Azure IoT Hub/ADU 포털 조작 필요 |
| Key103 전체 | ADU 기반 OTA 업데이트 End-to-End (Import Manifest 등록, 장비 그룹 배포, 이력 관리) | ADU 포털/IoT Hub 콘솔 조작 및 관측 필요, 다수 서브스텝이 "포털에서 확인됨"을 판정 기준으로 함 |
| Key105 원본 파일 | 훼손 `.swu` 원본 파일 자체 | Jira AGSRS-286 첨부 파일, 이 저장소·DUT에 없음 — TC08은 파일이 사전 준비된 경우만 자동 실행 |
| Key128/131/135 (실제 flash 완료 판정) | Docker Pull/Load 방식 설치가 최종적으로 애플리케이션 정상 동작까지 확인 | 실서명 `.swu`(Docker layer 포함) 필요 — TC11은 PRECHECK 프로토콜까지만 커버 |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `update_monitor` | MQTT 수신 대상 앱 ID |
| `ADU_DONE_DIR` | `/tmp/edge/update` | ADU step `.done` 파일 폴백 감시 경로 (TC02) |
| `UPDATE_HISTORY_DIR` | `/edge/etc/update-history` | 배치/OTA 업데이트 이력 (`history.jsonl`, `last_update.json`) |
| `FW_DOWNLOAD_CACHE_ROOT` | `/edge/docker/update_monitor/custom_downloader` | 펌웨어 다운로드 세션 영속 캐시 (TC04) |
| `SWU_RSA_PUB_KEY` | `/edge/sp/secrets/swupdate/swu_rsa_pub.pem` | 로컬 배치 업데이트 시 `swupdate -i -k` 인자 |
| `SWU_AES_CBC_KEY` | `/edge/sp/secrets/swupdate/swu_aes_cbc.key` | 로컬 배치 업데이트 시 `swupdate -i -K` 인자 |

---

## 자동화 등급 (Automation Grade)

🟡 **A (일부 준비물 의존)**

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | A (자동) | 프로토콜 레벨(큐/거부) 검증, 실제 flash 불필요 |
| TC02 | A (자동) | `.done` 파일 직접 생성으로 시뮬레이션, 4단계 모두 무인 실행 가능 |
| TC03 | B (반자동) | ADU 로그 파일 부재 시 일부 항목 수동 확인으로 대체 |
| TC04 | A (자동) | 세션 상태 파일 + kill -9 재시작 기법으로 무인 실행 가능 |
| TC05 | Flag | 소스코드에서 관련 로직 미발견 — 개발자 확인 후 내용 작성 대기 (본 초안에서는 placeholder) |
| TC06 | A (자동) | iptables 차단/해제로 네트워크 단절 재현 |
| TC07 | B (반자동) | 프로덕션 빌드에서는 mock lookup 경로 필요 — 없으면 일부 서브스텝 skip |
| TC08 | C (준비물 의존) | 훼손된 `.swu` 파일 사전 배치 필요, 부재 시 SKIP |
| TC09 | C (준비물 의존) | HW 불일치 `.swu` 파일 사전 배치 필요, 부재 시 SKIP (hwrevision 조회만 A) |
| TC10 | B (반자동) | 진행률 발생 소스(실제 업데이트 트리거)가 별도 TC 의존 |
| TC11 | A (자동) | PRECHECK 프로토콜 + 컨테이너/Volume 목록 불변성만 검증, 실 flash 불필요 |
| TC12 | 자동화 불가 | 목록만 제공, 실행은 QA 수동 |

---

## 관련 문서

- `tc_update_monitor_result.md` — 본 TC 실행 결과 보고서
- `tc_update_monitor_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/update_monitor.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx "Remote Update" 카테고리, Key 101-108/128-135, 16개 TC)
- `qcells/products/ac_system_gen2/application/update_monitor/docs/FIRMWARE_RESUME_DOWNLOAD_DESIGN.md` — 펌웨어 다운로드 resume 기능 설계서 (TC04/TC06/TC07 배경)
