# DB Manager — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/uniep/core/application/db_manager`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][DB Manager]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 76)

[AC GEN2][Unified Edge Platform][DB Manager] Configuration 테이블 생성

**Action:**

Postman 실행 > 아래와 같이 설정 > Send 버튼 클릭 

* Type : Post 
* [https://192.168.10.8:9112/auth/token|https://192.168.10.8:9112/auth/token]
** 실제 할당 받은 장비 IP 주소 입력

**Expected Result:**

Bearer Token  정보가 정상적으로 출력 되어야 함


### (연속 스텝)

**Action:**

Postman 실행 > 아래와 같이 설정 후 Send 버튼 클릭 

* Type : Post
* [https://192.168.10.8:9112/publish/db_manager/select_all_records|https://192.168.10.8:9112/publish/db_manager/select_all_records]
** 실제 할당 받은 장비 IP 주소 입력
* Authorization 탭
**  Auth Type : Bearer Token
** Token : Step 1에서 출력된 Bearer Token 입력 
* Body 탭 > raw 선택 > 아래 값 입력 

{noformat}{
    "db": "edge_storage_db",
    "table": "configuration"
}{noformat}

**Expected Result:**

edge_storage_db 파일 내의 configuration 테이블 값이 정상적으로 출력 되어야 함 

{noformat}        "requestTarget": "db_manager",
        "requestService": "select_all_records",
        "requestMessage": "{\"db\":\"edge_storage_db\",\"table\":\"configuration\"}",
        "responseMessage": {
            "db": "edge_storage_db",
            "records": [],
            "result": true,
            "table": "configuration"
        }{noformat}


### (연속 스텝)

**Action:**

* ALL LEDs
** 파워링 중, 스캔 준비가  되기 전

**Expected Result:**

LED가 {color:#ff5630}RED - 깜빡임으로{color} 로 표시 된다


### (연속 스텝)

**Action:**

* ALL LEDs
** 파워링 완료, 스캔 준비가 됐을시

**Expected Result:**

LED가 {color:#36b37e}GREEN - 깜빡임으로 {color}로 표시 된다


### (연속 스텝)

**Action:**

* 연결된 MI 중 하나 이상 연결 되지 않을 경우

**Expected Result:**

LED가 {color:#ff5630}RED {color}로 유지 된다


### (연속 스텝)

**Action:**

* 연결된 MI들이 모드 정상 동작할시

**Expected Result:**

LED가 {color:#36b37e}GREEN{color} 으로 유지 된다


### (연속 스텝)

**Action:**

* MI가 스캔중일시

**Expected Result:**

LED가 {color:#36b37e}GREEN - 깜빡임으로 {color}로 표시 된다


### (연속 스텝)

**Action:**

* 어떤 MI도 스캔(응답)되지 않을시

**Expected Result:**

LED 꺼짐


### (연속 스텝)

**Action:**

* 한 쌍 이상의 MI이가 Power 생산하지 않을 시

**Expected Result:**

LED가 {color:#ff5630}RED {color}로 유지 된다


### (연속 스텝)

**Action:**

* 모든 연결 된 MI들이 Power 생산하고 있을 시

**Expected Result:**

LED가 {color:#36b37e}GREEN{color} 으로 유지 된다


### (연속 스텝)

**Action:**

* MI 펌웨어가 업데이트 중일떄

**Expected Result:**

LED가 {color:#36b37e}GREEN - 깜빡임으로 {color}로 표시 된다


### (연속 스텝)

**Action:**

* 한 쌍 이상의 MI이가 Power 생산하지 않을 시

**Expected Result:**

LED 꺼짐


### (연속 스텝)

**Action:**

Qcells Server에 연결 되지 않았을시

**Expected Result:**

LED가 {color:#ff5630}RED {color}로 유지 된다


### (연속 스텝)

**Action:**

Qcells Server에 연결 되었을시

**Expected Result:**

LED가 {color:#36b37e}GREEN - 깜빡임으로 {color}로 표시 된다


### (연속 스텝)

**Action:**

네트워크 자체가 연결 되지 않았을시

**Expected Result:**

LED 꺼짐


## TC-2 (원본 Key 121)

[AC GEN2][Unified Edge Platform][DB Manager] history 정보 전달

**Action:**

* 첨부된 configuration example을 복사하여 /edge/db/edge_storage.db 내 configuration 테이블에 "version":0 그리고 "version":1로 변경하여 두 개의 같은 데이터를 강제로 insert

**Expected Result:**

* 재 시작 또는 클라우드 재 연결 시 version 0과 1에 대한 configuration이 SyncConfigurationRequest이라는 메시지 타입으로 서버에 올리는지 확인한다


## TC-3 (원본 Key 122)

[AC GEN2][Unified Edge Platform][DB Manager]  Persistent state  변경 정보 전달

**Action:**

(대체용 TEST)

http://장비고유주소:9111 페이지 Menu > Configuration > Basic & installation settings 메뉴 Basic Setting 페이지 접속


### (연속 스텝)

**Action:**

Basic Setting을 변경

Apply Changes 시: web → energy dispatcher → db manager → db 저장

Page load 시: web → energy dispatcher → db manager → db 조회

**Expected Result:**

임의 값들을 적용 후 새로고침 했을 때 정상적으로 값이 남아있다.


## TC-4 (원본 Key 123)

[AC GEN2][Unified Edge Platform][DB Manager] System setting 변경 정보 전달

**Action:**

Web HMI > Service 탭 > Log Level 변경 > SSH > EMS 로그 확인

**Expected Result:**

Log Level이 정상적으로 변경 되어야 함 

* changed_records 
* SSH > journalctl -f  > 실제 출력되는 Log Level 확인

{color:#ff5630}(HA(Host Agent)의 경우 docker 내에 있지 않아 DB 변경에 영향을 받지 않는 것이 맞음){color}


## TC-5 (원본 Key 124)

[AC GEN2][Unified Edge Platform][DB Manager] Persistent state 시작 시점 정보 전달

**Action:**

SSH 세션 2개 연결 > 컨테이너 재부팅 후 EMS 로그 확인

* 세션 1 :  journalctl -f
* 세션 2 : docker stop ac_system_gen2

**Data:**

현재 로그만 확인 가능 추후 보완 예정

**Expected Result:**

부팅 시 Persistent state의 정보를 모든 Application이 전달 받아야 함

* [I][DM] DB initialization completed: all system_settings, persistent_states, and device_info are loaded


## TC-6 (원본 Key 125)

[AC GEN2][Unified Edge Platform][DB Manager] System setting 시작 시점 정보 전달

**Action:**

Web HMI > Log Level 변경

**Expected Result:**

Log Level이 정상적으로 변경 되어야 함


### (연속 스텝)

**Action:**

EMS 재부팅 > Log Level 확인

**Expected Result:**

재부팅 후에도 Log Level 설정이 유지 되어야 함 

* Web HMI 및 실제 출력되는 Log 확인


## TC-7 (원본 Key 126)

[AC GEN2][Unified Edge Platform][DB Manager] Persistent state 초기화

**Action:**

Postman 실행 > 아래와 같이 설정 후 Send 

* Type : Post
* URL : [https://192.168.10.20:9112/auth/token|https://192.168.10.20:9112/auth/token]  
* Body > Raw 

{noformat}{
    "auth_key":"qcells-factory",
    "auth_secret":"26DCAF017DE587E33509057C780A04434B4293754085F5D0757E935CD94DCAF4",
    "subject":"test"
}{noformat}

**Data:**

실제 IP 주소 입력

**Expected Result:**

Bearer Token이 정상적으로 발행 되어야 함


### (연속 스텝)

**Action:**

Postman > 아래와 같이 설정 후 Send

* Type : Post 
* URL : [https://192.168.10.20:9112/publish/db_manager/select_all_records|https://192.168.10.8:9112/publish/db_manager/select_all_records]
* Authorization > Token : 발행된 Bearer Token 입력 
* Body > Raw 

{noformat}{
    "db": "edge_storage_db",
    "table": "persistent_state"
}{noformat}

**Expected Result:**

Persistent State 테이블의 값이 정상적으로 출력 되어야 함


## TC-8 (원본 Key 127)

[AC GEN2][Unified Edge Platform][DB Manager] System setting 초기화


### (연속 스텝)

**Action:**

Postman 실행 > 아래와 같이 설정 후 Send 

* Type : Post
* URL : [https://192.168.10.20:9112/auth/token|https://192.168.10.20:9112/auth/token]  
* Body > Raw 

{noformat}{
    "auth_key":"qcells-factory",
    "auth_secret":"26DCAF017DE587E33509057C780A04434B4293754085F5D0757E935CD94DCAF4",
    "subject":"test"
}{noformat}

**Data:**

실제 IP 주소 입력

**Expected Result:**

Bearer Token이 정상적으로 발행 되어야 함


### (연속 스텝)

**Action:**

Postman > 아래와 같이 설정 후 Send

* Type : Post 
* URL : [https://192.168.10.20:9112/publish/db_manager/select_all_records|https://192.168.10.8:9112/publish/db_manager/select_all_records]
* Authorization > Token : 발행된 Bearer Token 입력 
* Body > Raw 

{noformat}{
    "db": "edge_storage_db",
    "table": "system_setting"
}{noformat}

**Expected Result:**

System Setting 테이블의 값이 정상적으로 출력 되어야 함


## TC-9 (원본 Key 145)

[AC GEN2][Unified Edge Platform][DB Manager] Persistent state 테이블 생성

**Action:**

Postman 실행 > 아래와 같이 설정 > Send 버튼 클릭 

* Type : Post 
* [https://192.168.10.8:9112/auth/token|https://192.168.10.8:9112/auth/token]
** 실제 할당 받은 장비 IP 주소 입력

**Expected Result:**

Bearer Token  정보가 정상적으로 출력 되어야 함


### (연속 스텝)

**Action:**

Postman 실행 > 아래와 같이 설정 후 Send 버튼 클릭 

* Type : Post
* [https://192.168.10.8:9112/publish/db_manager/select_all_records|https://192.168.10.8:9112/publish/db_manager/select_all_records]
** 실제 할당 받은 장비 IP 주소 입력
* Authorization 탭
**  Auth Type : Bearer Token
** Token : Step 1에서 출력된 Bearer Token 입력 
* Body 탭 > raw 선택 > 아래 값 입력 

{noformat}{
    "db": "edge_storage_db",
    "table": "persistent_state"
}{noformat}

**Expected Result:**

edge_storage_db 파일 내의 persistent_state 테이블 값이 정상적으로 출력 되어야 함 

{noformat}"requestTarget": "db_manager",
        "requestService": "select_all_records",
        "requestMessage": "{\"db\":\"edge_storage_db\",\"table\":\"persistent_state\"}",
        "responseMessage": {
            "db": "edge_storage_db",
            "records": [
                {
                    "key": "persistence_list_sync_flag",
                    "type": 1,
                    "value": "0"
                },
                {
...                {noformat}


## TC-10 (원본 Key 146)

[AC GEN2][Unified Edge Platform][DB Manager] System setting 테이블 생성

**Action:**

Postman 실행 > 아래와 같이 설정 > Send 버튼 클릭 

* Type : Post 
* [https://192.168.10.8:9112/auth/token|https://192.168.10.8:9112/auth/token]
** 실제 할당 받은 장비 IP 주소 입력

**Expected Result:**

Bearer Token  정보가 정상적으로 출력 되어야 함


### (연속 스텝)

**Action:**

Postman 실행 > 아래와 같이 설정 후 Send 버튼 클릭 

* Type : Post
* [https://192.168.10.8:9112/publish/db_manager/select_all_records|https://192.168.10.8:9112/publish/db_manager/select_all_records]
** 실제 할당 받은 장비 IP 주소 입력
* Authorization 탭
**  Auth Type : Bearer Token
** Token : Step 1에서 출력된 Bearer Token 입력 
* Body 탭 > raw 선택 > 아래 값 입력 

{noformat}{
    "db": "edge_storage_db",
    "table": "system_setting"
}{noformat}

**Expected Result:**

edge_storage_db 파일 내의 system_setting 테이블의 값이 정상적으로 출력 되어야 함 

{noformat}"requestTarget": "db_manager",
        "requestService": "select_all_records",
        "requestMessage": "{\"db\":\"edge_storage_db\",\"table\":\"system_setting\"}",
        "responseMessage": {
            "db": "edge_storage_db",
            "records": [
                {
                    "key": "est_server_url",
                    "type": 10,
                    "value": "https://est.portal.ezca.io/est/f67255a8-0525-4454-88a6-bf4216fffc68/64e7902e-131e-43f2-8234-fe9403c8c70b/westus"
                },
                {
                    "key": "timezone",
                    "type": 10,
                    "value": "Asia/Seoul"
                },
                {
                    "key": "log_level_bc",
                    "type": 1,
                    "value": "1"
......{noformat}


## TC-11 (원본 Key 147)

[AC GEN2][Unified Edge Platform][DB Manager] DB 파일 관

**Action:**

DB 파일 저장 확인

**Expected Result:**

Data 저장을 위한 DB 파일을 아래 경로에 생성 해야 함 

* /edge/db/edge_storage.db


## TC-12 (원본 Key 181)

[AC GEN2][Unified Edge Platform][DB Manager] 최신 정보 Cloud sync

**Action:**

* 02.00.07 기준 RegisterMap은 /edge/db/edge_storage.db 내 system_setting 테이블 안에 "register_map"이라는 key로 존재합니다. 해당 key의 값을 아무 값이나 inser한다
** (향후 버전에서는 /edge/db/edge_storage.db 내 register_map이라는 테이블로 분리할 예정

**Data:**

현재로써 제대로 된 테스트는 불가능, 로그를 통해 확인하는 임시 방법)


### (연속 스텝)

**Action:**

* 재부팅 또는 재시작 이후 azure connector(AZ)에서 SyncRegisterMapRequest로 서버에 전송하는지 확인


### (연속 스텝)

**Action:**

* 전송 이후 azure connector(AZ)에서 서버로부터 SyncRegisterMapSuccessResponse 또는 SyncRegisterMapErrorResponse를 수신하는지 확인


