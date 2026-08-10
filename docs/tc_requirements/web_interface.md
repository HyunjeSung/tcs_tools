# Web Interface — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/uniep/web_interface`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][Web Interface]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 148)

[AC GEN2][Unified Edge Platform][Web Interface] API 문서 제공 적용

**Action:**

* [https://192.168.0.3:9112/api/docs/|https://192.168.0.3:9112/api/docs/] 접속 후 API 문서 상 제공되는 API end point request 를 확인한다.

**Expected Result:**

* 모든 REST API는 명세서(API 문서)에 정의된 대로 구현되어야 하며, Swagger 등 문서화 도구를 통해 명세(Document server)가 제공되어야 한다.


## TC-2 (원본 Key 149)

[AC GEN2][Unified Edge Platform][Web Interface] MQTT Disconnect 시 Error Response 처리

**Action:**

TEST 스크립트 첨부 (추후 수정예정)


## TC-3 (원본 Key 150)

[AC GEN2][Unified Edge Platform][Web Interface] MQTT-HTTP Bridge 지원

**Action:**

* Access Token 발급

* auth_key 및 auth_secret은 외부 공유 금지

{noformat}curl -k --location 'https://192.168.20.3:9112/auth/token' \
--header 'Content-Type: application/json' \
--data '{
    "auth_key":"qcells-factory",
    "auth_secret":"26DCAF017DE587E33509057C780A04434B4293754085F5D0757E935CD94DCAF4",
    "subject":"test"
}'{noformat}


### (연속 스텝)

**Action:**

* Request MQTT Bridge API

{noformat}curl -k --location 'https://192.168.20.3:9112/publish/db_manager/select_all_records' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer Bearer Token 값' \
--data '{
    "db": "edge_storage.db",
    "table": "system_setting",
    "records": [
        {
            "key": "qa_test_password",
            "type": 4
        }
    ]
}'{noformat}

**Expected Result:**

* Response

{noformat}{
    "httpStatus": 200,
    "meta": {
        "timestamp": "2022-04-28T22:15:56.499",
        "build_date": "2025/12/22 04:49:41",
        "build_main_tag": "DD2512220",
        "build_model": "AC_SYSTEM_GEN2",
        "build_type": "DEBUG",
        "build_version": "X021222"
    },
    "data": {
        "errorCode": 400,
        "requestTarget": "db_manager",
        "requestService": "select_all_records",
        "requestMessage": "{\"db\":\"edge_storage.db\",\"table\":\"system_setting\",\"records\":[{\"key\":\"qa_test_password\",\"type\":4}]}",
        "responseMessage": {
            "db": "edge_storage.db",
            "records": [
                {
                    "key": "country_code",
                    "type": 3,
                    "value": "0"
                },
                {{noformat}


## TC-4 (원본 Key 151)

[AC GEN2][Unified Edge Platform][Web Interface] 로깅 보안


### (연속 스텝)

**Action:**

* 로그에 포함되는 민감 정보를 마스킹 처리해야 하며, 개인정보 또는 인증 토큰 등이 노출되지 않는지 확인한다.
** password:, credit card 형태의 로그 출력
** 아래와 같이 민감 정보 마스킹 확인

{noformat}[18:10:59.916][D][WI] [MqttCore:publish]  Success to publish MQTT message topic - emsp/db_manager/web_interface/req/upsert_records 1 {"db":"edge_storage.db","table":"system_setting","records":[{"key":"qa_test_password","type":4,"value":"password: ****"},{"key":"","type":4,"value":"****-****-****-****"}]}{noformat}

**Expected Result:**

Action과 같은 Log가 확인된다.


## TC-5 (원본 Key 152)

[AC GEN2][Unified Edge Platform][Web Interface] JWT 토큰 검증

**Action:**

SSH >  아래 Command 입력 

{noformat}curl -k --location 'https://192.168.20.3:9112/auth/token' \
--header 'Content-Type: application/json' \
--data '{
 "auth_key": "readonly",
"auth_secret": "BF4BB6E2180F309F01F71873315F02F51A5565EDA47D4689E95F889B961E3216",
"subject": "test"
}'{noformat}

**Data:**

* JWT 토큰 발행
** auth_key, auth_secret은 외부 저장 금지
** readonly 권한 토큰 생성

**Expected Result:**

JWT 토큰이 정상적으로 발행 되어야 함 

{noformat}{
  "httpStatus":200,
  "meta":{
    "timestamp":"2022-04-28T20:59:43.589",
    "build_date":"2025/12/22 04:49:41",
    "build_main_tag":"DD2512220",
    "build_model":"AC_SYSTEM_GEN2",
    "build_type":"DEBUG",
    "build_version":"X021222"
  },
  "data":{
    "status":"success",
    "token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0IiwiaXNzIjoidW5pZXAtcGxhdGZvcm0iLCJhdWQiOiJ1bmllcC1zZXJ2aWNlcyIsImlhdCI6MTY1MTE3OTU4Mywicm9sZXMiOlsicmVhZG9ubHkiXSwicGVybWlzc2lvbnMiOlsicmVhZDpoZWFsdGgiLCJyZWFkOnN5c3RlbTpzdGF0dXMiLCJyZWFkOnBsYXRmb3JtOmluZm8iLCJyZWFkOnRlbGVtZXRyeSIsInJlYWQ6bm90aWZpY2F0aW9ucyIsInJlYWQ6dXBkYXRlOnN0YXR1cyIsInJlYWQ6c3lzdGVtOmxvZyJdLCJhcHBJZCI6InJlYWRvbmx5Iiwic2NvcGUiOltdLCJleHAiOjE2NTEyNjU5ODN9.SHuNbf1u0FoZqC9cDCc2t-3vwOWduZWgNCOX6VCCgNY",
    "expiresIn":"24h",
    "client":"Read Only Client",
    "roles":["readonly"]
  }
}{noformat}


### (연속 스텝)

**Action:**

SSH > 아래 Command 입력

{noformat}curl -k --location 'https://192.168.20.3:9112/health/system' \
--header 'Authorization: Bearer Bearer Token값' \
--header 'Content-Type: application/json' \
--data '{}'{noformat}

**Data:**

실제 할당 받은 IP 주소 , JWT Bearer Token 입력

API별 권한 테스트 - Available

**Expected Result:**

HTTP Error Code 401 외의  Error가 발생 해야 함

{noformat}{"httpStatus":405,"meta":{"timestamp":"2026-04-03T04:33:05.422","build_date":"2026/04/01 07:14:19","build_model":"AC_SYSTEM_GEN2","build_type":"RELEASE","build_version":"R050005"},"data":{"message":"POST method not allowed(Permission denied)","path":"/health/system","method":"POST","query":{},"body":{},"context":{"errors":[{"path":"/health/system","message":"POST method not allowed"}],"path":"/health/system"}{noformat}


### (연속 스텝)

**Action:**

SSH > 아래 Command 입력 

{noformat}curl -k --location --request POST 'https://192.168.20.3:9112/publish/sys_manager/get_platform_info' \
--header 'Authorization: Bearer Bearer Token값' \
--header 'Content-Type: application/json' \
--data '{}'{noformat}

**Data:**

실제 할당 받은 IP 주소 , JWT Bearer Token 입력

API별 권한 테스트 - Unavailable

**Expected Result:**

HTTP Error Code 401 발생 해야 함

{noformat}{"httpStatus":401,"meta":{"timestamp":"2026-04-03T04:34:43.079","build_date":"2026/04/01 07:14:19","build_model":"AC_SYSTEM_GEN2","build_type":"RELEASE","build_version":"R050005"},"data":{"message":"unauthorized(Permission denied)","path":"/publish/sys_manager/get_platform_info","method":"POST","query":{},"body":{},"context":{"errors":[{"path":"/publish/{target}/{service}","message":"unauthorized"}],"path":"/{noformat}


## TC-6 (원본 Key 160)

[AC GEN2][Unified Edge Platform][Web Interface] 경로 순회 공격 방지

**Action:**

Test 스크립트를 실행한다


### (연속 스텝)

**Action:**

1. URL Path Traversal 결과 확인

**Expected Result:**

HTTP 4XX Error가 반환 되어야 함

{noformat}=== Path Traversal Test ===

1. URL Path Traversal:
   ../../../etc/passwd -> HTTP 404
   ..%2f..%2f..%2fetc/passwd -> HTTP 404
   ....//....//....//etc/passwd -> HTTP 404
   %2e%2e%2f%2e%2e%2f%2e%2e%2fetc/passwd -> HTTP 404`
   ..\..\..\etc\passwd -> HTTP 404
   ..%5c..%5c..%5cetc%5cpasswd -> HTTP 404
   .%00./.%00./.%00./etc/passwd -> HTTP 404{noformat}


### (연속 스텝)

**Action:**

2. Query Parameter Traversal 결과 확인

**Expected Result:**

HTTP 4XX Error가 반환 되어야 함

{noformat}=== Path Traversal Test ===

2. Query Parameter Traversal:
   ?file=../../../etc/passwd -> HTTP 401
   ?file=..%2f..%2f..%2fetc/passwd -> HTTP 401
   ?file=....//....//....//etc/passwd -> HTTP 401
   ?file=%2e%2e%2f%2e%2e%2f%2e%2e%2fetc/passwd -> HTTP 401
   ?file=..\..\..\etc\passwd -> HTTP 401
   ?file=..%5c..%5c..%5cetc%5cpasswd -> HTTP 401
   ?file=.%00./.%00./.%00./etc/passwd -> HTTP 401{noformat}


### (연속 스텝)

**Action:**

3. Export Endpoint Traversal (if accessible) 결과 확인

**Expected Result:**

HTTP/1.1 4XX Error가 반환 되어야 함

{noformat}=== Path Traversal Test ===

3. Export Endpoint Traversal (if accessible):
   Normal request:
HTTP/1.1 401 Unauthorized
RateLimit-Policy: 600;w=60
RateLimit-Limit: 600
RateLimit-Remaining: 585
RateLimit-Reset: 60{noformat}


### (연속 스텝)

**Action:**

4. Null Byte Injection 결과 확인

**Expected Result:**

HTTP 4XX Error가 반환 되어야 함

{noformat}4. Null Byte Injection:
   file.txt%00.jpg -> HTTP 404
   ../../etc/passwd%00.log -> HTTP 404
   test.log%00../../etc/passwd -> HTTP 404
=== Test Complete ===
Expected: All traversal attempts should return 400 or 404, never the actual file content{noformat}


## TC-7 (원본 Key 164)

[AC GEN2][Unified Edge Platform][Web Interface] Injection 공격 방지

**Action:**

아래와 같이 터미널에 코드 입력한다 (본인 PC 주소입력)

{noformat}curl -s -i "https://192.168.0.3:9112/auth/token" -X POST \
    -H "Content-Type: application/json" \
    -d '{"auth_key": "admin OR 1=1--", "auth_secret": "x", "subject": "x"}' \
    -k | grep "HTTP"{noformat}

**Expected Result:**

Token API에 대한 401 거부 응답이 확인된다

*HTTP/1.1 401 Unauthorized*


## TC-8 (원본 Key 165)

[AC GEN2][Unified Edge Platform][Web Interface] CORS

**Action:**

* 첨부 된 테스트 스크릡트 파일 실행 (장비의 주소에 맞게 설정 변경)

**Expected Result:**

아래와 같은 LOG가 표시된다

* GET, POST, PUT, DELETE, OPTIONS 이외의 항목들은 Blocked 됨



{noformat}=== CORS Methods Test ===
Expected Allowed: GET, POST, PUT, DELETE, OPTIONS
GET: Allowed
POST: Allowed
PUT: Allowed
DELETE: Allowed
OPTIONS: Allowed
PATCH: Blocked
HEAD: Blocked
CONNECT: Blocked
TRACE: Blocked
=== Raw CORS Response ===
Access-Control-Allow-Methods: GET,POST,PUT,DELETE,OPTIONS{noformat}


## TC-9 (원본 Key 166)

[AC GEN2][Unified Edge Platform][Web Interface] SSL 암호화 스위트

**Action:**

SSH > 아래 Command 입력

* # curl -v [https://192.168.0.3:9112/health|https://192.168.10.20:9112/health] -k 2>&1 | grep -E "(SSL connection|Cipher)"

**Data:**

실제 할당 받은 IP 입력

**Expected Result:**

TLSv1.3로 동작 해야 함 

* # SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384


## TC-10 (원본 Key 168)

[AC GEN2][Unified Edge Platform][Web Interface] TLS 1.3

**Action:**

* Test 스크립트를 실행한다


### (연속 스텝)

**Action:**

* HTTP를 확인한다

**Data:**

{noformat}=== TLS Version Test ===
TLS 1.0: Connected (HTTP 000)
TLS 1.1: Connected (HTTP 000)
TLS 1.2: Connected (HTTP 000)
TLS 1.3: Connected (HTTP 401){noformat}

**Expected Result:**

* TLS 1.3만 HTTP XXX로 출력 된다
* 나머지 TLS는 HTTP 000으로 출력 된다


## TC-11 (원본 Key 169)

[AC GEN2][Unified Edge Platform][Web Interface] Content-Type 검증

**Action:**

SSH > 아래 command 입력 

{noformat}# text/plain
curl -X POST https://192.168.20.3:9112/health \
  -H "Content-Type: text/plain" \
  -d "test data" \
  -k -i 2>&1 | grep "HTTP"{noformat}

**Data:**

실제 할당 받은 IP 주소 입력

**Expected Result:**

415 Error가 발생 해야 함 

* HTTP/1.1 415 Unsupported Media Type


### (연속 스텝)

**Action:**

SSH > 아래 command 입력 

{noformat}# application/xml
curl -X POST https://192.168.20.3:9112/health \
  -H "Content-Type: application/xml" \
  -d "<test/>" \
  -k -i 2>&1 | grep "HTTP"{noformat}

**Data:**

실제 할당 받은 IP 주소 입력

**Expected Result:**

415 Error가 발생 해야 함 

* HTTP/1.1 415 Unsupported Media Type


### (연속 스텝)

**Action:**

SSH > 아래 command 입력

{noformat}# text/html  
curl -X POST https://192.168.0.3:9112/health \
  -H "Content-Type: text/html" \
  -d "<html></html>" \
  -k -i 2>&1 | grep "HTTP"{noformat}

**Data:**

실제 할당 받은 IP 주소 입력

**Expected Result:**

415 Error가 발생 해야 함

* HTTP/1.1 415 Unsupported Media Type


## TC-12 (원본 Key 170)

[AC GEN2][Unified Edge Platform][Web Interface] Rate Limit

**Action:**

Test 스크립트 실행

**Data:**

실제 할당 받은 IP 주소 입력

**Expected Result:**

API 요청 수가 제한되어 Rate Limited가 발생 해야 함

* Rate Limited (429): 50

{noformat}=== Rate Limit Test ===
Target: https://192.168.10.44:9112/health
Requests: 650

Progress: 50 / 650 (Success: 0, Limited: 0)
Progress: 100 / 650 (Success: 0, Limited: 0)
Progress: 150 / 650 (Success: 0, Limited: 0)
Progress: 200 / 650 (Success: 0, Limited: 0)
Progress: 250 / 650 (Success: 0, Limited: 0)
Progress: 300 / 650 (Success: 0, Limited: 0)
Progress: 350 / 650 (Success: 0, Limited: 0)
Progress: 400 / 650 (Success: 0, Limited: 0)
Progress: 450 / 650 (Success: 0, Limited: 0)
Progress: 500 / 650 (Success: 0, Limited: 0)
Progress: 550 / 650 (Success: 0, Limited: 0)
Progress: 600 / 650 (Success: 0, Limited: 0)
Rate limited at request #601
Progress: 650 / 650 (Success: 0, Limited: 50)

=== Results ===
Success (200): 0
Rate Limited (429): 50{noformat}


## TC-13 (원본 Key 171)

[AC GEN2][Unified Edge Platform][Web Interface] XSS

**Action:**

SSH 연결 > Parameter에 악성 script 주입

{noformat}curl -k -X POST https://192.168.10.20:9112/auth/token \
  -H "Content-Type: application/json" \
  -d '{"auth_key": "<script>alert(1)</script>", "auth_secret": "test", "subject": "test"}' \
  -k -v 2>&1 | grep -E "(Content-Type|<script>|HTTP)"{noformat}

**Data:**

실제 할당 된 IP 주소로 변경하여 입력

**Expected Result:**

Output이 정상적으로 출력 되어야 함 

* HTTP 4XX 또는 5XX Error가 발생 해야 함 
* Response Content Type이 application/json 으로 출력 되어야 함 

< HTTP/1.1 *401 Unauthorized*
< X-Content-Type-Options: nosniff
< *Content-Type: application/json*; charset=utf-8
{"httpStatus":401,"meta":{"timestamp":"2022-04-28T17:59:50.451","build_date":"2025/12/22 04:49:41","build_main_tag":"DD2512220","build_model":"AC_SYSTEM_GEN2","build_type":"DEBUG","build_version":"X021222"},"data":{"message":"Invalid auth credentials","origin":"[https://192.168.10.20:9112|https://192.168.10.20:9112]","path":"/auth/token","method":"POST","query":{},"body":{"auth_key":"<script>alert(1)</script>","auth_secret":"test","subject":"test"},"context":{"auth_key":"<script>alert(1)</script>"}}}


## TC-14 (원본 Key 172)

[AC GEN2][Unified Edge Platform][Web Interface] HSTS

**Action:**

SSH > 아래 Command 입력 

{noformat}# curl https://192.168.10.20:9112/health -k -v 2>&1 | grep -i "strict-transport"{noformat}

**Data:**

실제 할당 받은 IP 주소 입력

**Expected Result:**

아래와 같은 결과가 출력 되어야 함 

* max-age : 31536000 (1년) 확인
* includeSubDomains : 하위 엔드포인트 포함 확인
* preload : HSTS 등록 요청 확인

{noformat}# < Strict-Transport-Security: max-age=31536000; includeSubDomains; preload{noformat}


## TC-15 (원본 Key 176)

[AC GEN2][Unified Edge Platform][Web Interface]  Log Level Control

**Action:**

Service 탭 > Log Level 에서 Level조정 한다.

* 각 어플리케이션은 시스템 로그를 단계별로 표시 할 수 있어야 한다.

* 표시되는 어플리케이션의 로그는 단계를 지정하여 조작 할 수 있어야 한다.

**Data:**

* 각 단계는 다음과 같다
** DEBUG
*** 개발을 위한 테스트, 검증용 로그 단계
** INFO
*** 기본(Default)단계로 상태 변화, 길지 않은 주기의 반복 된 정보를 표시하는 로그 단계
** WARNING
*** 발생 시에 일반적인 상황이 아닌 걸 알리는 로그 단계
** ERROR
*** 발생 시에 반드시 개발자가 확인하고 수정해야 하는 걸 알리는 로그 단계

**Expected Result:**

각 어플리케이션별 조작 가능 및 저장 된다.


