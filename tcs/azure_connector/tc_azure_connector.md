---
spec_id: azure_connector
suite: application
grade: A
phase: Phase 1
test_file: tcs/azure_connector/tc_azure_connector.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-AZURE_CONNECTOR: azure_connector — Azure IoT Hub 연동 (Provisioning/X.509/Blob Storage)

## 목적 (Objective)

`azure_connector` 애플리케이션의 TLS 통신, DPS(Device Provisioning Service) 등록,
EST 서버 X.509 인증서 발급/재발급, Blob Storage 업로드, D2C 메시지 큐잉(오프라인
적재/재전송), C2D(서버→디바이스) 메시지 수신, IoT Hub 연결 상태 모니터링 기능을
검증한다.

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "Azure communication" 카테고리 원본 10개
TC(Key 153-159, 161-163, `docs/tc_requirements/azure_connector.md`)를 기준으로
작성했다. 원본 다수가 Azure Portal 접속 확인이나 Azure IoT Explorer 같은 외부 툴
조작을 전제로 하므로, 본 문서는 그중 **DUT에 SSH/시리얼로 접속해 로그·인증서
파일·MQTT로 자동 검증 가능한 부분만 TC로 재구성**했고, 클라우드 포털 의존 항목은
TC12에 자동화 불가 항목으로 별도 명시했다.

> **중요 (범위 정정): 원본 Key156 "ACR 인증 정보 수신"은 이 앱의 기능이 아니다.**
> 소스 전체(`grep -rn "ACR\|acr_token" qcells/uniep/core/application/azure_connector`)에서
> ACR 관련 코드가 전혀 발견되지 않았고, `acr_token`/`CreateTokenSuccessResponse` 등
> 요구사항이 언급한 문자열은 `qcells/products/ac_system_gen2/application/update_monitor/`
> 에서만 발견된다. Key156은 azure_connector가 아니라 **update_monitor 소관**으로
> 판단되며, `tcs/update_monitor/tc_update_monitor.md`에서 다뤄야 할 항목이다. 이
> 문서에서는 별도 TC를 만들지 않고 근거 매핑 표에 Flag로만 남긴다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `azure_connector` 프로세스 실행 중 (`pgrep -f azure_connector`)
- MQTT 브로커 동작 중 (`localhost:1883`), `mosquitto_pub`/`mosquitto_sub` 설치됨
- `journalctl -u docker-loader` 로 azure_connector 로그 확인 가능 (다른 앱과 동일한
  단일 유닛 하에서 실행됨 — `system_log`/`update_monitor` TC와 동일 관례)
- azure_connector가 이미 프로비저닝을 마치고 Azure IoT Hub에 정상 연결된 "정상
  운영" 상태 (`/edge/sp/secrets/dp/full_chain_cert.pem` 등 4개 인증서 파일 존재)
- root 권한 (`/edge/sp/secrets/dp/` 쓰기 가능, `iptables` 사용 가능)

> **주의(파괴적 시험 가능성):** TC03/TC04는 실제 디바이스 X.509 인증서 파일을
> 직접 손상/삭제한다. `CertificateProvisioner`가 덮어쓰기 전 `backup/` 폴더로
> 백업하지만, EST 서버 재발급이 실패하면 디바이스가 일시적으로 프로비저닝이 안 된
> 상태로 남을 수 있다 — 반드시 사전에 백업을 확인하고, 가능하면 스테이징/테스트용
> 디바이스에서 실행한다. TC10 연결 해제 서브스텝은 `iptables`로 아웃바운드를
> 차단하므로 실행 중 다른 클라우드 연동 시험과 병행하지 않는다.

---

## TC01 — TLS 1.2 이상 지원 (검토 필요 — 런타임 negotiated 버전 로그 없음)

> 요구사항이 근거로 제시한 `[I][AZ] TLS Version Check Result: Protocol : TLSv1.2`
> 로그는 소스 전체에서 발견되지 않는다. 실제로 azure_connector가 남기는 TLS 관련
> 로그는 `log_tls_connection_info()`(`source/azure_device_client.cpp:584`)의
> `"IoT Hub connection: uri=..., MQTT over TLS, X.509 client certificate"` 와
> `log_openssl_version_info()`의 `"OpenSSL: <version> (<platform>)"` 뿐이며, 이는
> **링크된 OpenSSL 라이브러리 버전(컴파일타임 능력치)** 을 보여줄 뿐 실제 협상된
> TLS 프로토콜 버전(런타임 상태)을 보여주지 않는다. 협상된 버전을 확인하려면
> `tcpdump`로 IoT Hub 포트(8883/443) ClientHello/ServerHello를 캡처해 `tshark`로
> TLS record version을 파싱해야 하는데, 이는 이 저장소의 다른 TC가 쓰는
> "로그 grep" 방식과 성격이 다른 별도 자동화 트랙이라 사전 조사 없이 본 초안에
> 포함하지 않는다. 개발자/네트워크 담당자 확인 후 내용을 채운다.

### 목적
<TODO — 개발자 확인 후 작성: (a) OpenSSL 링크 버전 로그로 "TLS 1.2 이상 능력"만
확인하는 약식 TC로 채택할지, (b) tcpdump+tshark 기반 실제 협상 버전 캡처 TC를
새로 설계할지 결정>

### 사전 조건
<TODO>

### 절차
<TODO>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC02 — Device Provisioning: edge_device_id 설정 및 DPS 등록 트리거 (로컬 프로토콜 레벨)

### 목적

`set_edge_device_id` IPC 요청으로 시리얼(=edge_device_id)이 설정되면
`initialize_certificate_provisioner()`가 호출되고, 이후 연결 상태 머신이
`PROVISIONING` 상태에서 `"Attempting device registration with DPS..."` 로그와 함께
DPS 등록을 시도해 `"Device registration successful"` 또는
`"Device registration failed, will retry later"` 로 결과를 남기는지 확인한다.
(원본 Key154 1~2번째 스텝)

> **정정:** 요구사항 원문은 "`/edge/db/serial_number` 파일을 만들어 시리얼을
> 설정"이라고 되어 있으나, azure_connector 소스에는 이 파일을 직접 읽는 코드가
> 없다. 실제로는 다른 컴포넌트(모바일 커미셔닝 경로 등)가 시리얼을 확보해
> `SERVICE_SET_EDGE_DEVICE_ID` IPC 요청(`{"edge_device_id":"<serial>"}`)으로
> azure_connector에 전달하는 구조다(`handle_request_set_edge_device_id`,
> `source/azure_connector.cpp:385`). 이 TC는 그 IPC 계약만 직접 재현한다.

### 사전 조건

- 공통 전제 조건 충족
- 테스트용 edge_device_id 문자열 준비 (실제 Azure DPS 개별/그룹 enrollment에
  등록되어 있지 않은 임의 값이어도 무방 — 이 TC는 "등록 시도 로그" 발생 여부만
  검증하고, 실제 Azure 측 승인 여부(`Device registration successful` vs
  `failed`)는 DPS 등록 상태에 따라 달라질 수 있음을 감안한다)
- azure_connector가 아직 해당 edge_device_id로 등록을 시도하지 않은 상태(재시작
  직후 권장) — 이미 연결된 상태라면 `edge_device_id_`가 비어있지 않아 요청이
  무시되지 않는지 로그로 확인 필요

### 절차

1. `mosquitto_pub -t emsp/azure_connector/tc_runner/req/set_edge_device_id -m '{"tid":"tc-1","payload":{"edge_device_id":"<TEST_SERIAL>"}}'`
2. 응답 토픽 `emsp/tc_runner/azure_connector/res/set_edge_device_id` 에서
   `payload.result=true` 확인
3. `journalctl -u docker-loader --since "10 seconds ago" | grep -F "edge_device_id set: <TEST_SERIAL>"` 확인
4. 최대 30초(등록 재시도 주기, `registration_retry_interval`) 대기 후
   `journalctl -u docker-loader --since "40 seconds ago"` 에서
   `"Attempting device registration with DPS..."` 로그 확인
5. 동일 구간에서 `"Device registration successful"` 또는
   `"Device registration failed, will retry later"` 중 하나가 출현하는지 확인
   (둘 다 PASS 취급 — 이 TC의 판정 대상은 "시도 자체"이지 Azure 측 승인 여부가
   아님)

### 기대 결과

| 항목 | 기준 |
|------|------|
| set_edge_device_id 응답 | `result=true` |
| DPS 등록 시도 로그 | `"Attempting device registration with DPS..."` 출현 |
| DPS 등록 결과 로그 | success/failed 로그 중 하나 출현 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | set_edge_device_id 응답 result=true | boolean | true | 응답 payload에 `"result":true` |
| TC02-2 | edge_device_id 설정 로그 존재 | boolean | true | `journalctl -u docker-loader --since "10 seconds ago" \| grep -F "edge_device_id set: <TEST_SERIAL>"` |
| TC02-3 | DPS 등록 시도 로그 존재 | boolean | true | `journalctl -u docker-loader --since "40 seconds ago" \| grep -F "Attempting device registration with DPS..."` |
| TC02-4 | DPS 등록 결과 로그 존재(성공/실패 무관) | boolean | true | 위 로그 구간에 `"Device registration successful"` 또는 `"will retry later"` 중 하나 포함 |

---

## TC03 — 인증서 파일 손상 시 재발급(Re-enrollment) 동작 확인

### 목적

`/edge/sp/secrets/dp/full_chain_cert.pem` 내용이 손상되면
`Certificate::is_valid()`가 `false`를 반환하고(`"[Certificate::is_valid] Failed to
load certificate"`), 연결 상태 머신이 이를 감지해 `certificate_enrollment()`로
재발급을 시도하는지 확인한다. (원본 Key155 1번째 스텝)

### 사전 조건

- 공통 전제 조건 충족
- `/edge/sp/secrets/dp/full_chain_cert.pem` 존재 및 원본 백업(`cp`로 별도 보관 —
  `CertificateProvisioner`가 재발급 시 `backup/` 폴더에 자동 백업하지만, EST 서버
  응답 실패 시를 대비해 시험자도 별도 백업 권장)
- EST 서버(`get_est_server_url()`)에 네트워크로 도달 가능 (재발급이 실제로
  성공해야 후속 검증까지 가능)

### 절차

1. `full_chain_cert.pem` 원본을 `/tmp/tc_az_backup_full_chain.pem` 로 백업
2. 파일 마지막 줄을 잘라내 PEM 구조를 깨뜨림: `head -c -100 full_chain_cert.pem > /tmp/corrupt.pem && mv /tmp/corrupt.pem full_chain_cert.pem`
3. 최대 60초 대기 (다음 `PROVISIONING`/`CONNECTING` 루프 반복 및 연결 재시도
   백오프 주기 감안)
4. `journalctl -u docker-loader --since "70 seconds ago"` 에서
   `"[Certificate::is_valid] Failed to load certificate"` 확인
5. 동일 구간에서 `"Certificate is invalid, performing enrollment..."` 또는
   `"Certificate is invalid, performing full enrollment..."` 확인
6. 재발급 성공 시 `"Certificate enrollment completed successfully"` 또는
   `"Successfully connected after certificate enrollment"` 확인
7. `openssl x509 -in full_chain_cert.pem -noout -enddate` 로 파일이 실제로
   갱신(새 인증서로 교체)되었는지 확인
8. cleanup: 절차가 실패해 재발급이 안 됐다면 `/tmp/tc_az_backup_full_chain.pem` 을
   원위치로 복원

### 기대 결과

| 항목 | 기준 |
|------|------|
| 손상 감지 로그 | `Failed to load certificate` 출현 |
| 재발급 트리거 로그 | `performing enrollment` / `performing full enrollment` 출현 |
| 재발급 완료 | `Certificate enrollment completed successfully` 출현, 파일 갱신됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | 손상된 인증서 로드 실패 로그 | boolean | true | `journalctl -u docker-loader --since "70 seconds ago" \| grep -F "[Certificate::is_valid] Failed to load certificate"` |
| TC03-2 | 재발급(enrollment) 트리거 로그 | boolean | true | 동일 구간에 `grep -F "performing enrollment"` 또는 `grep -F "performing full enrollment"` |
| TC03-3 | 재발급 완료 로그 | boolean | true | `grep -F "Certificate enrollment completed successfully"` |
| TC03-4 | 파일이 유효한 PEM으로 복구됨 | boolean | true | `openssl x509 -in full_chain_cert.pem -noout -enddate` exit 0 |

---

## TC04 — 인증서 파일 삭제 시 재발급 동작 확인

### 목적

`full_chain_cert.pem`이 존재하지 않으면 `Certificate::is_valid()`가
`"[Certificate::is_valid] Certificate or key does not exist"` 로그와 함께
`false`를 반환하고, TC03과 동일한 재발급 경로가 트리거되는지 확인한다. (원본
Key155 2번째 스텝 — TC03과 로그 분기점(`does not exist` vs `Failed to load`)이
달라 별도 TC로 분리)

### 사전 조건

- TC03과 동일
- `full_chain_cert.pem` 백업 확보

### 절차

1. `full_chain_cert.pem` 백업
2. `rm -f full_chain_cert.pem`
3. 최대 60초 대기
4. `journalctl -u docker-loader --since "70 seconds ago"` 에서
   `"[Certificate::is_valid] Certificate or key does not exist"` 확인
5. 재발급 트리거/완료 로그 확인 (TC03 절차 5~7과 동일)
6. cleanup: 재발급 실패 시 백업에서 복원

### 기대 결과

| 항목 | 기준 |
|------|------|
| 파일 부재 감지 로그 | `Certificate or key does not exist` 출현 |
| 재발급 완료 | 파일이 새로 생성됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | 인증서 부재 감지 로그 | boolean | true | `journalctl -u docker-loader --since "70 seconds ago" \| grep -F "[Certificate::is_valid] Certificate or key does not exist"` |
| TC04-2 | 재발급 완료 로그 | boolean | true | `grep -F "Certificate enrollment completed successfully"` |
| TC04-3 | 파일이 재생성됨 | boolean | true | `[ -f full_chain_cert.pem ]` |

---

## TC05 — 인증서 만료 임박 시 Re-Enroll (검토 필요 — 24시간+ 실시간 대기 필요)

> 요구사항 원문도 "24시간 이상 대기해야 해서 추후 환경 Setting 후 테스트 예정"으로
> 명시하고 있다. 소스 확인 결과 이 유예 사유가 정확히 일치한다 — `cert_renewal_loop()`
> (`source/azure_connector.cpp:961`)가 **24시간 주기**로만 만료 임박(30일 이내)
> 여부를 검사하도록 하드코딩되어 있다 (`cert_check_interval =
> std::chrono::hours(24)`). 즉 시스템 시간을 인증서 만료 직전으로 앞당겨도, 실제
> 재발급 로그(`"Certificate expires within 30 days, attempting renewal..."` →
> `perform_simplereenroll_for_certificate` → `"Certificate renewal completed
> successfully"`)를 보려면 프로세스 기동 후 최대 24시간을 기다리거나
> `cert_renewal_loop`의 체크 주기를 테스트 빌드에서 단축해야 한다. 단일 TC 실행
> 시간 내로는 자동화가 비현실적이라 판단해 placeholder로 남긴다.

### 목적
<TODO — 개발자 확인 후 작성: 테스트용 빌드에서 `cert_check_interval`을 단축하는
빌드 플래그/환경변수가 있는지, 아니면 `is_certificate_expiring_soon()`을 IPC로
직접 트리거할 테스트 훅을 추가할지 결정 필요>

### 사전 조건
<TODO>

### 절차
<TODO>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC06 — Blob Storage 업로드 (로컬 프로토콜/로그 레벨)

### 목적

`upload_file_to_blob` IPC 요청이 `BlobTransport`를 통해
`IoTHubDeviceClient_UploadToBlobAsync`를 호출하고, SDK 콜백에서 성공
(`FILE_UPLOAD_OK`)을 받으면 `GenericResponse.error_code="NONE"`으로 응답하는지
확인한다. (원본 Key157의 로컬에서 검증 가능한 절반 — **Azure Portal에서 실제
파일이 해당 컨테이너 경로에 보이는지는 사람이 포털에서 최종 확인해야 하며, 이
부분은 TC12에 별도 명시**)

### 사전 조건

- 공통 전제 조건 충족 (IoT Hub 연결된 상태 — Blob 업로드는 연결 필요)
- 업로드용 소형 테스트 파일 준비 (`/tmp/tc_az_blob_test.txt`, 임의 내용)

### 절차

1. 테스트 파일 생성: `echo "tc_azure_connector blob test $(date -Iseconds)" > /tmp/tc_az_blob_test.txt`
2. `mosquitto_pub -t emsp/azure_connector/tc_runner/req/upload_file_to_blob -m '{"tid":"tc-2","payload":{"source_path":"/tmp/tc_az_blob_test.txt","dest_blob_path":"tc_test/tc_az_blob_test.txt"}}'`
   (응답은 PUBACK 이후 비동기로 오므로 타임아웃을 넉넉히, 예: 30초)
3. 응답 토픽에서 `payload.error_code="NONE"` 확인
4. `journalctl -u docker-loader --since "40 seconds ago"` 에서
   `"[upload_file_to_blob] source: tc_runner, file: /tmp/tc_az_blob_test.txt -> tc_test/tc_az_blob_test.txt"` 확인
5. 동일 구간에서 `"[BlobTransport] SDK result: 0 (ok)"` 확인 (result 코드 0 =
   `FILE_UPLOAD_OK`)
6. **(수동)** Azure Portal(Test 서버면 `unieptest`, Dev 서버면 `devuniep` 계정
   아래) Storage 컨테이너에서 `tc_test/tc_az_blob_test.txt` 존재를 사람이 확인
   — 자동화 스크립트 판정 대상 아님, `TC12` 참고

### 기대 결과

| 항목 | 기준 |
|------|------|
| IPC 응답 | `error_code="NONE"` |
| 업로드 요청 로그 | source/dest 경로 포함 로그 출현 |
| SDK 업로드 결과 | `SDK result: 0 (ok)` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | upload_file_to_blob 응답 error_code=NONE | boolean | true | 응답 payload에 `"error_code":"NONE"` |
| TC06-2 | 업로드 요청 로그 존재 | boolean | true | `journalctl -u docker-loader --since "40 seconds ago" \| grep -F "tc_az_blob_test.txt -> tc_test/tc_az_blob_test.txt"` |
| TC06-3 | SDK 업로드 성공 로그 | boolean | true | `grep -F "[BlobTransport] SDK result: 0 (ok)"` |
| TC06-4 | Portal 실제 확인 | manual | — | 수동 — TC12에 판정 위임 |

---

## TC07 — Message Queueing Logic: Offline 상태에서 Telemetry 축적

### 목적

Cloud 연결이 끊긴 동안 `profile_key="telemetry"` (persistent 모드)로 발행한
`send_message_iothub` 요청이 즉시 실패하지 않고 로컬 sqlite DB에 큐잉되어 쌓이는지
확인한다. (원본 Key158 1번째 스텝)

> **정정:** 요구사항 원문은 `/edge/db/edge_storage.db` 의 `iothub_message_telemetry`
> 테이블을 근거로 제시하지만, 실제 구현(`D2cMessageOutbox`,
> `include/d2c_message_outbox.hpp:141`)은 별도 전용 DB
> `/edge/db/iothub_messages.db` 를 sqlite3로 열고, 큐별 테이블명은
> `iothub_msgs_<queue_id>` 로 생성한다. `queue_id="telemetry"` 프로파일은
> azure_connector 자신이 아니라 `cloud_broker`가 기동 시
> `SERVICE_SET_DELIVERY_PROFILES` 로 등록한다(`cloud_broker.cpp:410-422`,
> `max_rows=196000`, `overflow_policy="drop_oldest"`,
> `min_insert_interval_ms=45000`). 즉 실제 테이블은 `iothub_msgs_telemetry`.
> 또한 `min_insert_interval_ms=45000`(45초) 때문에 45초 이내 재발행은 조용히
> 버려지므로, 절차에서 발행 간격을 45초 이상으로 둔다.

### 사전 조건

- 공통 전제 조건 충족
- `cloud_broker` 프로세스 실행 중 (telemetry delivery profile을 등록해야
  `queue_id="telemetry"` 테이블이 생성됨) — `handle_request_set_delivery_profiles`
  적용 여부는 `journalctl -u docker-loader | grep -F "[DeliveryProfiles]"` 로 확인
- `sqlite3` CLI 사용 가능
- `iptables` 로 아웃바운드 차단 가능한 root 권한

### 절차

1. `sqlite3 /edge/db/iothub_messages.db "SELECT COUNT(*) FROM iothub_msgs_telemetry;"` 로 시작 row 수(`BEFORE_COUNT`) 확인 (테이블 없으면 0으로 간주하고 사전 조건 재확인)
2. Azure IoT Hub 목적지로의 아웃바운드 트래픽 차단: `iptables -A OUTPUT -p tcp --dport 8883 -j DROP` (443도 필요 시 함께)
3. `journalctl -u docker-loader --since "20 seconds ago"` 에서
   `"Disconnected from Azure IoT Hub."` 확인 (연결 끊김 반영 대기, 최대 60초)
4. `send_message_iothub` 요청을 `profile_key="telemetry"` 로 1회 발행:
   `mosquitto_pub -t emsp/azure_connector/tc_runner/req/send_message_iothub -m '{"tid":"tc-3","payload":{"message":"{\"tc\":\"az07\"}","profile_key":"telemetry"}}'`
5. `sqlite3 ... "SELECT COUNT(*) FROM iothub_msgs_telemetry;"` 로 row 수가
   `BEFORE_COUNT+1` 이 되었는지 확인
6. `min_insert_interval_ms`(45초) 경과 후 2회차 메시지 발행, row 수가 다시
   +1 되는지 확인 (오프라인 상태에서 계속 축적되는지 검증)
7. cleanup: `iptables -D OUTPUT -p tcp --dport 8883 -j DROP` (TC08에서 재연결
   검증을 이어서 할 경우 이 단계는 TC08로 넘긴다)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 오프라인 전환 | `Disconnected from Azure IoT Hub.` 로그 출현 |
| 1차 발행 후 row 증가 | `BEFORE_COUNT+1` |
| 45초 간격 2차 발행 후 row 증가 | `BEFORE_COUNT+2` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | 오프라인 전환 로그 확인 | boolean | true | `journalctl -u docker-loader --since "60 seconds ago" \| grep -F "Disconnected from Azure IoT Hub."` |
| TC07-2 | 1차 발행 후 telemetry 테이블 row +1 | boolean | true | `sqlite3 /edge/db/iothub_messages.db "SELECT COUNT(*) FROM iothub_msgs_telemetry;"` 결과가 `BEFORE_COUNT+1` |
| TC07-3 | 45초 간격 2차 발행 후 row +1 추가 | boolean | true | 동일 쿼리 결과가 `BEFORE_COUNT+2` |

---

## TC08 — Message Queueing Logic: Cloud 재연결 후 Telemetry 재발송

### 목적

TC07에서 오프라인 중 쌓인 telemetry 큐가, 네트워크 차단 해제(재연결) 후
`QueueProcessor` 가 순서대로 발송해 DB row가 소진(삭제)되는지 확인한다. (원본
Key158 2번째 스텝)

> **정정:** 요구사항은 "1분 대기 후 재전송"이라 되어 있으나, 코드상 재전송은
> "1분 주기"로 스케줄링되는 것이 아니라 `QueueProcessor`가 이미 `poll_interval_ms`
> (telemetry profile 기준 200ms)로 상시 폴링하다가 연결 복구를 감지하는 즉시
> 재개하는 구조다(`"[QueueProcessor] disconnected, holding queue '...'`" 로그가
> 차단 중 반복 출력됨). "1분"은 근사치로 보이며, 이 TC는 `ack_timeout_ms`
> (telemetry 기준 180초)를 감안해 최대 3분의 여유 있는 타임아웃으로 판정한다.

### 사전 조건

- TC07을 직접 이어서 실행 (동일 세션, `iptables` 차단이 걸린 상태에서 시작)
- TC07 종료 시점의 `iothub_msgs_telemetry` row 수(`QUEUED_COUNT`, 2 이상) 확보

### 절차

1. `iptables -D OUTPUT -p tcp --dport 8883 -j DROP` 로 차단 해제
2. `journalctl -u docker-loader --since "10 seconds ago"` 에서
   `"Connected to Azure IoT Hub."` 재출현까지 최대 60초 대기
3. 최대 180초(ack_timeout_ms) 동안 10초 간격으로
   `sqlite3 /edge/db/iothub_messages.db "SELECT COUNT(*) FROM iothub_msgs_telemetry;"` 폴링
4. row 수가 0(또는 이 TC가 넣은 만큼 감소)이 될 때까지 감소 추세인지 확인
5. `journalctl -u docker-loader --since "3 minutes ago"` 에서
   `"[QueueProcessor]"` 관련 발송 로그 확인 (D2C 발송/ACK 처리 흔적)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 재연결 로그 | `Connected to Azure IoT Hub.` 재출현 |
| 큐 소진 | telemetry row 수가 재연결 후 감소해 0 도달 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | 재연결 로그 확인 | boolean | true | `journalctl -u docker-loader --since "70 seconds ago" \| grep -F "Connected to Azure IoT Hub."` |
| TC08-2 | telemetry row가 재연결 후 0으로 감소 | boolean | true | 180초 이내 `SELECT COUNT(*) FROM iothub_msgs_telemetry;` 결과 0 |
| TC08-3 | QueueProcessor 발송 로그 존재 | boolean | true | `journalctl -u docker-loader --since "3 minutes ago" \| grep -F "[QueueProcessor]"` |

---

## TC09 — 서버(C2D) 메시지 수신 로그 확인 (반자동 — 발신은 Azure IoT Explorer 수동 조작 필요)

### 목적

Azure IoT Hub에서 디바이스로 보낸 C2D(Cloud-to-Device) 메시지를
`c2d_received_message_callback`이 수신해 `on_message()`에서 로그를 남기는지
확인한다. (원본 Key159)

> **정정:** 요구사항이 근거로 제시한 `"Received IoT Hub message - ..."` 문자열은
> 소스에 없다. 실제 로그는 `on_message()`(`source/azure_connector.cpp:1173`)의
> `"[C2D] received - Header: <header>, Payload: <payload>"` 이며, **`LOG(DEBUG)`
> 레벨**이다 — 기본 로그 레벨 설정에 따라 journald에 안 남을 수 있으니 사전에
> azure_connector 로그 레벨이 DEBUG 이상인지 확인해야 한다. 메시지 발신 자체는
> 디바이스가 클라이언트이므로 로컬에서 재현할 수 없고, 요구사항 원문대로 Azure
> IoT Explorer로 사람이 직접 보내야 한다 — 이 TC는 "사람이 보낸 후" 로그 수신
> 여부만 스크립트로 판정한다.

### 사전 조건

- 공통 전제 조건 충족, azure_connector 로그 레벨이 DEBUG 이상으로 설정됨
- 시험자가 Azure IoT Explorer(또는 동등 툴)로 대상 device id에 C2D 메시지를 보낼
  준비가 되어 있음 (가이드: 사내 Confluence "azure-iot-explorer를 이용한 메세지
  수신 확인" 문서)

### 절차

1. `journalctl -u docker-loader -f` 를 백그라운드로 tail 시작, 출력을 파일로 저장
   (또는 시작 시각 `T0` 기록 후 폴링 방식 사용)
2. **(수동)** 시험자가 Azure IoT Explorer로 임의 payload("tc_az09_probe" 등 식별
   가능한 문자열 포함)를 해당 디바이스로 전송
3. 최대 60초 동안 로그 수집
4. 수집된 로그에서 `"[C2D] received"` 및 2번에서 보낸 식별 문자열이 함께
   출현하는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| C2D 수신 로그 | `[C2D] received - Header: ..., Payload: ...` 출현, payload에 시험 식별자 포함 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | C2D 수신 로그 출현 | manual-trigger / boolean | true | 발신 후 60초 이내 `journalctl -u docker-loader --since "70 seconds ago" \| grep -F "[C2D] received"` |
| TC09-2 | 수신 payload에 시험 식별자 포함 | boolean | true | 위 grep 결과 라인에 `tc_az09_probe` 포함 |

---

## TC10 — Azure IoT Hub 연결 상태 모니터링 (연결 확인 / 연결 해제 재현)

### 목적

정상 상태에서 `"Connected to Azure IoT Hub."` 로그와 MQTT 알림
(`changed_iothub_connection`, `connection=true`)이 발행되고, 네트워크 차단으로
연결이 끊기면 `"Disconnected from Azure IoT Hub. Reason: ..."` 로그와
`connection=false` 알림이 발행되는지 확인한다. (원본 Key161 + Key163 — 두 원본
모두 동일한 `iot_hub_connection_status_callback` 하나의 콜백을 근거로 하므로
하나의 TC로 통합)

> **정정:** 요구사항이 제시한 `[I][DB] Azure IoT Hub connection status:
> connected/disconnected` 로그는 azure_connector가 아니라
> `device_manager`(`qcells/products/ac_system_gen2/application/device_manager/
> source/device_manager.cpp:720`)에서 나오며, 태그도 `DB`가 아니라 `DM`이고
> **`LOG(DEBUG)` 레벨**이다(device_manager가 azure_connector의
> `NOTI_CHANGED_IOTHUB_CONNECTION` 알림을 구독해 자기 로그로 다시 남기는 구조로
> 추정). 이 TC는 1차 판정 기준을 azure_connector 자신의 로그
> (`"Connected"`/`"Disconnected from Azure IoT Hub."`, 태그 `AZ`, INFO/WARN 레벨)와
> MQTT 알림 payload로 삼고, device_manager 쪽 로그는 보조 확인으로만 언급한다.

### 사전 조건

- 공통 전제 조건 충족 (연결된 상태에서 시작)
- `iptables` 사용 가능한 root 권한
- `mosquitto_sub`로 `emsp/all/azure_connector/noti/changed_iothub_connection` 구독 가능

### 절차

1. 현재 연결 상태 확인: `journalctl -u docker-loader --since "5 minutes ago" | grep -F "Connected to Azure IoT Hub."` 최소 1건 확인
2. `mosquitto_sub -t emsp/all/azure_connector/noti/changed_iothub_connection -C 1 -W 5` 로 현재 retained 알림 조회, `connection=true` 확인
3. `iptables -A OUTPUT -p tcp --dport 8883 -j DROP` 로 연결 차단
4. 최대 60초 대기 후 `journalctl -u docker-loader --since "70 seconds ago"` 에서
   `"Disconnected from Azure IoT Hub. Reason:"` 확인
5. `mosquitto_sub -t emsp/all/azure_connector/noti/changed_iothub_connection -C 1 -W 70` 로 새 알림 수신, `connection=false` 확인
6. `iptables -D OUTPUT -p tcp --dport 8883 -j DROP` 로 차단 해제
7. 최대 60초 대기 후 `"Connected to Azure IoT Hub."` 재출현 및
   `connection=true` 알림 재수신 확인
8. **(보조, 선택)** `journalctl -u docker-loader | grep -F "IoT Hub connection status:"` 로 device_manager 측 반영 로그도 확인 (DEBUG 레벨 로그 노출 설정된 경우만)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 정상 연결 | `Connected to Azure IoT Hub.` 로그 + `connection=true` 알림 |
| 차단 후 해제 감지 | `Disconnected from Azure IoT Hub. Reason:` 로그 + `connection=false` 알림 |
| 차단 해제 후 재연결 | `Connected to Azure IoT Hub.` 재출현 + `connection=true` 재알림 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC10-1 | 초기 연결 로그 확인 | boolean | true | `journalctl -u docker-loader --since "5 minutes ago" \| grep -F "Connected to Azure IoT Hub."` |
| TC10-2 | 초기 알림 connection=true | boolean | true | retained 알림 payload에 `"connection":true` |
| TC10-3 | 차단 후 연결 해제 로그 | boolean | true | `journalctl -u docker-loader --since "70 seconds ago" \| grep -F "Disconnected from Azure IoT Hub. Reason:"` |
| TC10-4 | 차단 후 알림 connection=false | boolean | true | 수신 payload에 `"connection":false` |
| TC10-5 | 해제 후 재연결 로그 | boolean | true | `journalctl -u docker-loader --since "70 seconds ago" \| grep -F "Connected to Azure IoT Hub."` |
| TC10-6 | 재연결 알림 connection=true | boolean | true | 수신 payload에 `"connection":true` |

---

## TC11 — X.509 인증서 파일 존재 및 유효성 검사

### 목적

프로비저닝 완료 후 `/edge/sp/secrets/dp/` 에 4개 인증서 파일이 존재하고,
`full_chain_cert.pem`이 CA 체인에 대해 유효하며, `device_private_key.pem`이
`full_chain_cert.pem`의 공개키와 짝을 이루는지 확인한다. (원본 Key162)

### 사전 조건

- 공통 전제 조건 충족 (프로비저닝 완료 상태)
- `openssl` CLI 사용 가능

### 절차

1. `ls -la /edge/sp/secrets/dp/{cacert_0.pem,device_private_key.pem,full_chain_cert.pem,leafcert_0.pem}` 로 4개 파일 존재 확인
2. `cd /edge/sp/secrets/dp && openssl verify -CAfile cacert_0.pem -untrusted cacert_1.pem full_chain_cert.pem` 실행, 출력이 `full_chain_cert.pem: OK` 인지 확인 (`cacert_1.pem`이 없는 체인 구성이면 `-untrusted` 인자 생략하고 재시도)
3. `diff <(openssl x509 -in full_chain_cert.pem -noout -pubkey) <(openssl pkey -in device_private_key.pem -pubout)` 로 키페어 일치 확인 (`echo KEYPAIR_OK` 트리거)
4. `journalctl -u docker-loader --since "5 minutes ago" | grep -F "Connected to Azure IoT Hub."` 로 이 인증서로 실제 연결이 성립했는지 재확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 파일 4종 존재 | 모두 존재 |
| 체인 유효성 | `full_chain_cert.pem: OK` |
| 키페어 일치 | diff 결과 없음 (`KEYPAIR_OK`) |
| 연결 성립 | `Connected to Azure IoT Hub.` 로그 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC11-1 | 4개 인증서 파일 존재 | boolean | true | `ls /edge/sp/secrets/dp/{cacert_0.pem,device_private_key.pem,full_chain_cert.pem,leafcert_0.pem}` exit 0 |
| TC11-2 | full_chain_cert.pem 체인 검증 OK | boolean | true | `openssl verify ...` 출력에 `": OK"` 포함 |
| TC11-3 | 키페어 일치 | boolean | true | `diff <(...) <(...)` 출력 없음 (exit 0) |
| TC11-4 | 해당 인증서로 IoT Hub 연결 성립 | boolean | true | `journalctl -u docker-loader --since "5 minutes ago" \| grep -F "Connected to Azure IoT Hub."` |

---

## TC12 — 자동화 불가 항목 목록 (Azure Portal 확인 / 클라우드 전용 시험)

이 항목들은 실제 Azure Portal 접속, 실시간 네트워크 캡처 분석, 또는 24시간 이상의
실시간 대기처럼 단일 DUT 셸 스크립트로는 검증 불가능한 원본 요구사항이다. TC로
변환하지 않고 목록으로만 남긴다.

| 원본 Key | 항목 | 자동화 불가 사유 |
|----------|------|-------------------|
| Key153 (TC-1 본체) | 협상된 TLS 프로토콜 버전이 실제로 1.2 이상인지 | 코드에 런타임 negotiated 버전 로그 없음 — `tcpdump`+`tshark` 패킷 캡처 분석 필요 (TC01에 placeholder로 정리, 사전 조사 필요) |
| Key154 3번째 스텝 | Azure Portal Device Explorer에서 device id 등록 확인 | Azure Portal(qcellsces 테넌트) 접속 필요 |
| Key156 전체 (ACR 인증 정보) | ACR 토큰 발급/저장/Docker Pull 업데이트 연동 | azure_connector 소스에 해당 기능 없음 — `update_monitor` 소관으로 판단, 이 문서 범위 밖 |
| Key157 (TC-5 최종 확인) | Azure Portal Blob Storage에서 업로드 파일 실물 확인 | Azure Portal(Test: `unieptest` / Dev: `devuniep` 계정) 접속 필요 — TC06이 로컬 SDK 응답까지는 커버 |
| Key155 3번째 스텝 | 인증서 만료 임박 시 Re-Enroll (실시간 24h+ 대기) | `cert_renewal_loop`이 24시간 고정 주기로만 검사 (TC05에 placeholder로 정리) |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `azure_connector` | MQTT 수신 대상 앱 ID |
| `SP_DP_DIR` | `/edge/sp/secrets/dp` | X.509 인증서 저장 경로 (TC03/TC04/TC11) |
| `IOTHUB_DB_PATH` | `/edge/db/iothub_messages.db` | D2C 메시지 큐 sqlite DB (TC07/TC08) |
| `TELEMETRY_TABLE` | `iothub_msgs_telemetry` | telemetry persistent 큐 테이블명 (`cloud_broker`가 등록) |

---

## 자동화 등급 (Automation Grade)

🟡 **A (일부 준비물/실시간 의존)**

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | Flag | 런타임 negotiated TLS 버전 로그 없음 — 개발자 확인 후 내용 작성 대기 |
| TC02 | A (자동) | IPC 프로토콜 트리거 + 로그 확인, Azure 측 승인 여부 무관하게 판정 가능 |
| TC03 | B (반자동, 파괴적) | 실제 인증서 파일 손상, EST 서버 도달 가능해야 재발급까지 검증 |
| TC04 | B (반자동, 파괴적) | 실제 인증서 파일 삭제, TC03과 동일 제약 |
| TC05 | Flag | 24시간 고정 주기 코드 확인됨 — 단축 훅 필요, 개발자 확인 후 작성 |
| TC06 | B (반자동) | 로컬 SDK 응답/로그까지 자동, Portal 실물 확인은 수동(TC12 위임) |
| TC07 | A (자동) | iptables 차단 + sqlite 쿼리로 완전 자동화 |
| TC08 | A (자동) | TC07 연속, iptables 해제 + sqlite 폴링으로 완전 자동화 |
| TC09 | B (반자동) | 로그 판정은 자동, C2D 발신 자체는 Azure IoT Explorer 수동 조작 필요 |
| TC10 | A (자동) | iptables 차단/해제로 연결 단절 재현, 로그+MQTT 알림 모두 자동 판정 |
| TC11 | A (자동) | 파일 존재 + openssl verify + keypair diff, 완전 자동화 |
| TC12 | 자동화 불가 | 목록만 제공, 실행은 QA 수동 |

---

## 관련 문서

- `tc_azure_connector_result.md` — 본 TC 실행 결과 보고서
- `tc_azure_connector_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/azure_connector.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx "Azure communication" 카테고리, Key 153-159/161-163, 10개 TC)
