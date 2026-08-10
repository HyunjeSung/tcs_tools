# Azure communication — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/uniep/core/application/azure_connector`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][Azure communication]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 153)

[AC GEN2][Unified Edge Platform][Azure communication] TLS 1.2 이상 지원

**Action:**

Cloud 연결 > EMS+ 로그 확인

**Expected Result:**

Cloud 연결을 TLS 1.2 버전 이상으로 해야 함

* [I][AZ] TLS Version Check Result:     Protocol  : TLSv1.2


## TC-2 (원본 Key 154)

[AC GEN2][Unified Edge Platform][Azure communication] Device Provisioning 요청

**Action:**

# Serial number 설정
## 현재는 임시로 /edge/db/serial_number 라는 파일을 만들어 해당 파일 내에 원하는 serial number를 설정

보통은 모바일 커미셔닝 과정을 통한 정식 경로로 쓰는것을 권함

**Expected Result:**

Seiral number가 설정된다


### (연속 스텝)

**Action:**

# {{Attempting device registration with DPS...}} 이후 {{Device registration successful}} 로그 확인

**Expected Result:**

로그가 확인된다


### (연속 스텝)

**Action:**

# 의도한 device id(serial number)가 Azure에 device로 등록되었는지 azure portal을 통해 확인
## 현재 기준 device 목록 위치: [+https://portal.azure.com/#@qcellsces.onmicrosoft.com/resource/subscriptions/811f70d5-01bb-4146-baed-4c1b9b7201a1/resourceGroups/resi-iot-hub-rg-dev/providers/Microsoft.Devices/IotHubs/dev-iot-hub-for-edge-test/DeviceExplorer+|https://portal.azure.com/#@qcellsces.onmicrosoft.com/resource/subscriptions/811f70d5-01bb-4146-baed-4c1b9b7201a1/resourceGroups/resi-iot-hub-rg-dev/providers/Microsoft.Devices/IotHubs/dev-iot-hub-for-edge-test/DeviceExplorer]

**Expected Result:**

의도한 Serial number로 Azure에 등록된다


## TC-3 (원본 Key 155)

[AC GEN2][Unified Edge Platform][Azure communication] EST 서버 x.509 인증서 요청

**Action:**

SSH > 인증서 파일 편집 (텍스트 삭제 또는 추가) 

* /edge/sp/secrets/dp 경로의 cacert_0.pem,  device_private_key.pem,  full_chain_cert.pem,  leafcert_0.pem

**Data:**

추후 파일 개수 및 파일 이름 변경 가능성 있음

**Expected Result:**

인증서가 손상 된 경우 다시 얻어와야 함


### (연속 스텝)

**Action:**

인증서 파일 삭제

**Expected Result:**

인증서가 존재하지 않을 경우 다시 얻어와야 함


### (연속 스텝)

**Action:**

SSH > 기기의 시간을 인증서 만료 기한 직전으로 변경 > EMS+ 로그 확인 

* # timedatectl set-ntp 0
* #  timedatectl set-time 2030-01-01

**Data:**

24시간 이상 대기해야해서 추후 환경 Setting 후 TEST예정

**Expected Result:**

인증서 기간이 얼마 남지 않은 경우 인증서를 Re Enroll 해야 함

* [perform_simplereenroll] Certificate renewal completed successfully


## TC-4 (원본 Key 156)

[AC GEN2][Unified Edge Platform][Azure communication] ACR 인증 정보 수신 및 업데이트 데이터 전달

**Action:**

* Requirement
** Requirement
Container Storage Service인 Azure Container Registry(ACR)에서 인증 정보를 받아 UniEP ADU Container에 전달하며, 업데이트 기능에 필요한 데이터 전달, 지원하는 역할을 해야 한다.

**Expected Result:**

요구 조건을 충족시킨다


### (연속 스텝)

**Action:**

h3. TC-SID0705-01: ACR 인증 토큰 정상 생성 및 저장 검증

h4. Test Objective

IoT Hub 연결 상태에서 ACR 토큰 요청 시, Azure로부터 정상적으로 토큰을 받아 로컬 파일에 저장되는지 검증한다.

h4. Preconditions

* MPU 정상 부팅 상태
* IoT Hub 연결 완료 (Azure Connector가 정상 동작 중)
* 네트워크 연결 정상
* Azure Portal에서 ACR 설정 완료 (Container Registry 준비됨)
* Update Monitor 애플리케이션 실행 중

**Data:**

h4. Test Data / Inputs

* *ACR 주소*: Azure Portal에서 확인 가능한 Registry URL (예: {{qcellsregistry.azurecr.io}})
* *Container 이름*: 업데이트 대상 컨테이너 이름
* *토큰 저장 경로*: {{/edge/acr/acr_token.json}} (기본 경로)

**Expected Result:**

h4. Preconditions을 충족시킨다


### (연속 스텝)

**Action:**

h4. Test Method / Procedure

*방법 A: Docker Pull 업데이트를 통한 자동 토큰 요청*

# Azure Portal 또는 ADU에서 Docker Pull 방식 업데이트 배포
# 장비에서 업데이트 수신
# 업데이트 시작 시 자동으로 ACR 토큰 요청됨
# 토큰 생성 및 저장 확인


### (연속 스텝)

**Action:**

# *토큰 요청 확인 (로그)*

* {{"Requesting ACR token"}}
* {{"IoT Hub token payload: ..."}}
* {{"CreateTokenSuccessResponse"}}

**Expected Result:**

토큰 요청을 확인한다


### (연속 스텝)

**Action:**

# *토큰 파일 생성 확인*

{noformat}# 파일 존재 확인
ls -la /edge/acr/acr_token.json

# 파일 내용 확인
cat /edge/acr/acr_token.json{noformat}

**Expected Result:**

토큰 파일 생성을 확인한다.

*예상 파일 내용 구조:*

{noformat}{
    "containerName": "컨테이너이름",
    "tokenName": "토큰이름",
    "acrAccessToken": "실제토큰값...",
    "expireTimestamp": "만료시간",
    "registryUrl": "레지스트리URL"
}{noformat}


### (연속 스텝)

**Action:**

*토큰 필드 검증*

* 파일에 다음 필드가 모두 존재해야 함:
* {{containerName}}: 요청한 컨테이너 이름
* {{tokenName}}: 토큰 식별자
* {{acrAccessToken}}: 실제 인증 토큰 (빈 값 아님)
* {{expireTimestamp}}: 만료 시간 (숫자 형식)
* {{registryUrl}}: ACR 주소 (예: {{qcellsregistry.azurecr.io}})

**Expected Result:**

Action란에 쓰인 필드가 모두 확인된다.


### (연속 스텝)

**Action:**

*IoT Hub 연결 상태 확인*

* 로그에서 {{"IoT Hub connected"}} 메시지 확인
* Azure Portal에서 장비 연결 상태가 "Connected"로 표시됨

**Expected Result:**

로그 메시지와 Connected상태가 확인된다.


### (연속 스텝)

**Action:**

h4. Pass Criteria

* [ ] IoT Hub가 "연결됨" 상태
* [ ] 로그에 {{"Requesting ACR token"}} 메시지 출력됨
* [ ] 로그에 {{"CreateTokenSuccessResponse"}} 메시지 출력됨
* [ ] 로그에 {{"Saving ACR token to file"}} 메시지 출력됨
* [ ] {{/edge/acr/acr_token.json}} 파일이 생성됨
* [ ] 토큰 파일에 필수 필드 5개가 모두 존재함
* [ ] {{acrAccessToken}} 필드가 빈 값이 아님 (실제 토큰 존재)
* [ ] {{registryUrl}}이 올바른 ACR 주소임
* [ ] 에러 메시지 없음

h4. Fail Criteria

* [ ] IoT Hub 연결 실패 또는 연결 끊김 상태
* [ ] 로그에 {{"CreateTokenErrorResponse"}} 메시지 출력됨
* [ ] 로그에 {{"ACR token creation failed"}} 메시지 출력됨
* [ ] 토큰 파일이 생성되지 않음
* [ ] 토큰 파일에 필수 필드가 누락됨 (5개 중 하나라도 없음)
* [ ] {{acrAccessToken}} 필드가 비어있음 또는 null
* [ ] 로그에 {{"Token payload missing required fields"}} 에러 표시
* [ ] {{registryUrl}}이 잘못되었거나 없음

**Expected Result:**

Pass 요건을 충족시켰을시 Pass, Fail요건을 충족시켰을시 Fail


### (연속 스텝)

**Action:**

h3. TC-SID0705-02: ACR 인증 토큰을 활용한 Docker Pull 업데이트 검증

h4. Test Objective

생성된 ACR 토큰을 사용하여 Docker Pull 방식 업데이트가 정상적으로 수행되는지 검증한다.

h4. Preconditions

* TC-SID0705-01 Pass (ACR 토큰이 정상적으로 생성되어 있음)
* {{/edge/acr/acr_token.json}} 파일 존재
* IoT Hub 연결 정상
* 업데이트 대상 Docker 이미지가 ACR에 업로드되어 있음
* SWUpdate 시스템 정상 동작

**Expected Result:**

h4. Preconditions을 충족한다.


### (연속 스텝)

**Action:**

*Web HMI로 수행 (지원되는 경우)*

# Web HMI 접속
# 업데이트 메뉴 → Docker Pull 업데이트 선택
# 업데이트 파일 선택 또는 URL 입력
# 업데이트 실행
# 완료 상태 확인

**Expected Result:**

# *ACR 인증 사용 확인 (로그)*

* 로그에서 다음 내용 확인:
* ACR 토큰 파일 읽기 성공
* Docker login 성공 (ACR 인증 사용)
* Docker pull 진행 메시지


### (연속 스텝)

**Action:**

# *Docker Pull 성공 확인*

{noformat}# Docker 이미지 확인
docker images{noformat}

**Expected Result:**

* ACR에서 pull한 이미지가 목록에 표시된다
* 이미지 태그가 목표 버전과 일치한다


### (연속 스텝)

**Action:**

# *업데이트 완료 확인*

* HMI 또는 로그에서 업데이트 완료 메시지 확인
* 컨테이너가 새 이미지로 재시작됨
* 애플리케이션 정상 동작 확인

**Expected Result:**

정상 동작이 확인된다.


### (연속 스텝)

**Action:**

# *컨테이너 동작 확인*

{noformat}# 실행 중인 컨테이너 확인
docker ps

# 컨테이너 로그 확인 (정상 기동 확인)
docker logs [container_name]{noformat}

**Expected Result:**

컨테이너 정상 동작이 확인된다.


### (연속 스텝)

**Action:**

h4. Pass Criteria

* [ ] 업데이트가 "완료" 또는 "성공"으로 종료됨
* [ ] 로그에 ACR 토큰 파일 읽기 성공 메시지
* [ ] 로그에 Docker login 성공 메시지 (ACR 인증)
* [ ] ACR에서 Docker 이미지 pull 성공
* [ ] {{docker images}}에 목표 이미지가 표시됨
* [ ] 이미지 태그가 목표 버전과 일치함
* [ ] 컨테이너가 새 이미지로 정상 실행됨
* [ ] 애플리케이션이 정상 동작함 (헬스체크 통과)
* [ ] 인증 관련 에러 없음

h4. Fail Criteria

* [ ] 업데이트 실패 (에러 메시지 표시)
* [ ] ACR 토큰 파일을 찾을 수 없음 (경로 오류)
* [ ] Docker login 실패 (인증 오류)
* {{"unauthorized: authentication required"}}
* {{"denied: permission denied"}}
* [ ] Docker pull 실패
* {{"pull access denied"}}
* {{"manifest unknown"}}
* [ ] 이미지가 pull되지 않음 ({{docker images}}에 없음)
* [ ] 이미지 태그가 잘못됨 (목표 버전 불일치)
* [ ] 컨테이너 시작 실패 또는 크래시
* [ ] 애플리케이션이 비정상 동작 (헬스체크 실패)

**Expected Result:**

Pass 조건을 충족시키면 Pass

Fail 조건을 충족시키면 Fail


## TC-5 (원본 Key 157)

[AC GEN2][Unified Edge Platform][Azure communication] Blob Storage 업로드

**Action:**

[https://growingenergylabs.atlassian.net/wiki/spaces/EnergySW/pages/10613556088/Blob+Storage+meta|https://growingenergylabs.atlassian.net/wiki/spaces/EnergySW/pages/10613556088/Blob+Storage+meta] 문서 참고 후 해당 문서를 blob storage에 업로드 한다.

**Expected Result:**

Azure portal에서 원하는 위치에 파일이 정상적으로 업로드 된다.

(만약 Test 서버가 아니라 Dev 서버에 연결이 된 상태라면 unieptest가 아니라 devuniep 계정 아래에서 확인해야 함)


## TC-6 (원본 Key 158)

[AC GEN2][Unified Edge Platform][Azure communication] Message Queueing Logic

**Action:**

Cloud Offline 상태

**Expected Result:**

Offline 상태에서 Telemetry Data가 축적 되어야 함 

* /edge/db/edge_storage.db 파일 내 iothub_message_telemetry 테이블


### (연속 스텝)

**Action:**

Cloud Online 후 1분 대기

**Expected Result:**

Cloud 재연결 이후 1분 telemetry data가 다시 서버로 발송 되어야 함 (1분 주기)


## TC-7 (원본 Key 159)

[AC GEN2][Unified Edge Platform][Azure communication] 서버 메시지 수신

**Action:**

* "Azure IoT Explorer" tool을 사용하여 edge 쪽에 메시지 전송
** 가이드 문서: [azure-iot-explorer를 이용한 메세지 수신 확인|https://growingenergylabs.atlassian.net/wiki/spaces/EnergySW/pages/10321888097/azure-iot-explorer]

**Expected Result:**

* AZ의 {{Received IoT Hub message - ...}} 로그를 확인한다


## TC-8 (원본 Key 161)

[AC GEN2][Unified Edge Platform][Azure communication] 연결 상태 모니터링

**Action:**

Azure IoT Hub 연결 > EMS+ 로그 확인

**Expected Result:**

Azure IoT Hub에 정상적으로 연결 되어야 함

* [I][DB] Azure IoT Hub connection status: connected


### (연속 스텝)

**Action:**

Azure IoT Hub 연결 해제 > EMS+ 로그 확인

**Expected Result:**

Azure IoT 연결이 정상적으로 해제 되어야 함 

* [I][DB] Azure IoT Hub connection status: disconnected


## TC-9 (원본 Key 162)

[AC GEN2][Unified Edge Platform][Azure communication] X.509 인증서를 통한 연결 및 관리

**Action:**

/edge/sp/secrets/dp 경로에 아래 파일 생성 확인 

* cacert_0.pem
* device_private_key.pem
* full_chain_cert.pem
* leafcert_0.pem

**Data:**

Provisioning 이후 생성

**Expected Result:**

인증서 파일이 정상적으로 생성 되어야 함


### (연속 스텝)

**Action:**

full_chain_cert.pem 파일 유효성 검사 

* # cd /edge/sp/secrets/dp
* # openssl verify -CAfile cacert_0.pem -untrusted cacert_1.pem full_chain_cert.pem

**Expected Result:**

유효성 검사 결과가 적합해야 함 

* full_chain_cert.pem: OK


### (연속 스텝)

**Action:**

device_private_key.pem 파일 유효성 검사 

* # cd /edge/sp/secrets/dp
* # diff <(openssl x509 -in full_chain_cert.pem -noout -pubkey) <(openssl pkey -in device_private_key.pem -pubout) && echo KEYPAIR_OK

**Expected Result:**

유효성 검사 결과가 적합 해야 함

* KEYPAIR OK


### (연속 스텝)

**Action:**

Azure IoT Hub 연결 확인 (EMS 로그)

**Expected Result:**

Azure IoT Hub로 연결 되어야 함 

* Connected to Azure IoT Hub


## TC-10 (원본 Key 163)

[AC GEN2][Unified Edge Platform][Azure communication] Azure IoT Hub 연결

**Action:**

Cloud 연결 > EMS 로그 확인

**Expected Result:**

Azure IoT Hub에 정상적으로 연결 되어야 함 

* [I][AZ] Connected to Azure IoT Hub


