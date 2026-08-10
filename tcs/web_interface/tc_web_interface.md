---
spec_id: web_interface
suite: application
grade: A
phase: Phase 1
test_file: tcs/web_interface/tc_web_interface.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-WEB_INTERFACE: web_interface — Web HMI/API 백엔드 (JWT/CORS/Rate Limit/MQTT-HTTP Bridge)

## 목적 (Objective)

`web_interface`는 Node.js 20 + Express 5(TypeScript) 로 작성된 UniEP의 Web HMI/API
백엔드로, HTTPS 리스너(기본 9112번 포트, `src/config/env.ts`) 위에서 API 문서 제공,
JWT 기반 인증/인가, MQTT-HTTP Bridge, TLS/암호화 스위트 강제, CORS, Rate Limit,
HSTS, Content-Type 검증, Injection/XSS/경로 순회 방어, Log Level Control을
수행한다. 다른 C++ BaseApp 계열 app과 달리 SSH/시리얼로 프로세스 내부를 조작하는
방식이 아니라, **DUT의 HTTPS 엔드포인트에 curl/openssl로 직접 요청을 보내 응답
상태코드/헤더/TLS 핸드셰이크 결과로 판정**하는 방식이다.

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "Web Interface" 카테고리 원본 15개
TC(Key 148-176, `docs/tc_requirements/web_interface.md`)를 기준으로 작성했다.
원본의 다수가 보안 항목(JWT/CORS/XSS/Injection/TLS)이지만, 실제 구현을 확인한
결과 전부 **정적 설정(HTTP 헤더 값, 상태 코드, TLS 파라미터) 검증**으로 귀결되어
curl/openssl만으로 자동화 가능했다 — Burp Suite/OWASP ZAP류의 별도 침투테스트
도구가 필요한 항목은 없었다. 다만 원본 Action이 비어 있거나("TEST 스크립트 첨부,
추후 수정예정") 마스킹 로직의 실제 위치가 이 저장소 밖(`@qcells/edge-core`, 외부
패키지)에 있어 확인 불가능한 2건(TC02, TC04)은 placeholder로 남겼다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, `https://<DUT_IP>:9112` 로 HTTPS 접근 가능 (자체
  서명 인증서 — 모든 curl 호출에 `-k` 필요)
- DUT에서 `web_interface` 프로세스 실행 중이며 `GET /health` 가 200 응답
  (이 엔드포인트는 인증/readiness 게이트를 모두 우회하도록 설계되어 있어 최초
  liveness 확인용으로 사용)
- MQTT 브로커 및 `db_manager`/`sys_manager` 등 web_interface가 의존하는 앱들이
  정상 기동 상태 (그렇지 않으면 `platformService.initialize()` 단계에서
  `bootSystem()` 이 재시도 루프에 머물러 대부분의 엔드포인트가 503으로 응답)
- readonly 권한 테스트 클라이언트의 `auth_key`/`auth_secret` 확보 — **주의**:
  개발 저장소의 `src/server.env` 기본값은 `AUTH_READONLY_KEY=qcells-readonly` 이며,
  원본 요구사항 문서(TC-5)의 예시 `auth_key: "readonly"` 와 이름이 다르다. 실제 DUT에
  배포된 값은 `PRODUCTION_CERT_PATH`(`/edge/sp/secrets/web_interface`)와 별도로
  주입되는 운영 설정을 따르므로, 본 TC 실행 전 QA가 실제 DUT의 값을 확인해
  `WI_AUTH_KEY`/`WI_AUTH_SECRET` 환경변수로 주입해야 한다 (하드코딩하지 않음)
- `curl`, `openssl` 설치된 실행 환경 (DUT와 HTTPS로 통신 가능한 호스트 — SSH 불필요)

> **주의(부하 시험 성격):** TC12(Rate Limit)는 60초 이내에 600회 초과 요청을
> 보내는 시험이라 다른 TC와 동시 실행하면 서로의 rate limit 버킷에 영향을 줄 수
> 있다. 단독 실행 권장, 또는 마지막 순서로 배치.

---

## TC01 — API 문서 제공 (Swagger/OpenAPI 문서 서버)

### 목적

REST API 명세가 문서화 도구(Swagger UI)를 통해 제공되고, 문서에 정의된 엔드포인트
경로가 실제 구현과 일치하는지 확인한다. (원본 Key148)

> **Flag — 경로 불일치**: 원본 요구사항은 `https://<IP>:9112/api/docs/` 를
> 명시하지만, 실제 코드(`src/config/openapi.ts`)는 Swagger UI를 `/platform/docs`
> (JSON: `/platform/docs.json`, YAML: `/platform/docs.yaml`)에 마운트한다. `/api`
> 경로는 `src/config/proxy.ts`에서 별도 내부 프록시(포트 9113)로 라우팅되는
> 완전히 다른 용도다. 아래 절차는 실제 구현 경로(`/platform/docs`)를 기준으로
> 작성했다 — QA 원본 문서(TestCase.xlsx Key148)의 URL 갱신을 권장한다.

### 사전 조건

- 공통 전제 조건 충족
- 인증 불필요 (`/platform/docs*` 는 `tokenWhitelistStore`/`readinessBypassStore`
  양쪽에 prefix bypass로 등록되어 있음)

### 절차

1. `curl -sk -o /dev/null -w '%{http_code}' https://$HOST:$PORT/platform/docs.json`
   로 OpenAPI 스펙 JSON이 200으로 제공되는지 확인
2. 응답 바디를 저장해 `openapi` 최상위 필드와 `paths` 객체가 비어있지 않은
   유효한 OpenAPI 3.x 문서인지 확인
3. `curl -sk -o /dev/null -w '%{http_code}' https://$HOST:$PORT/platform/docs`
   로 Swagger UI HTML이 200으로 제공되는지 확인
4. `paths` 목록에서 이 문서의 다른 TC가 실제로 호출하는 엔드포인트
   (`/auth/token`, `/health`, `/health/system`, `/publish/{target}/{service}`,
   `/export/system/log`) 가 모두 선언되어 있는지 확인 (문서-구현 일치 교차검증)

### 기대 결과

| 항목 | 기준 |
|------|------|
| docs.json | HTTP 200, 유효한 OpenAPI 3.x JSON |
| docs (Swagger UI) | HTTP 200 |
| 경로 일치 | 다른 TC가 호출하는 5개 엔드포인트가 모두 `paths`에 선언됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | docs.json 200 응답 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' https://$HOST:$PORT/platform/docs.json` == `200` |
| TC01-2 | docs.json이 유효한 OpenAPI 문서 | boolean | true | `curl -sk https://$HOST:$PORT/platform/docs.json \| python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('openapi','').startswith('3.'); assert len(d.get('paths',{}))>0"` exit 0 |
| TC01-3 | Swagger UI HTML 200 응답 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' https://$HOST:$PORT/platform/docs` == `200` |
| TC01-4 | 5개 핵심 엔드포인트가 paths에 존재 | boolean | true | `curl -sk https://$HOST:$PORT/platform/docs.json \| grep -oE '"/(auth/token\|health\|health/system\|publish/\{target\}/\{service\}\|export/system/log)"'` 5줄 모두 출력 |

---

## TC02 — MQTT Disconnect 시 Error Response 처리 (검토 필요 — 원본 Action 미기재)

> 원본 요구사항(Key149)의 Action이 "TEST 스크립트 첨부 (추후 수정예정)"으로
> 비어 있어 무엇을 어떻게 검증해야 하는지 원본만으로는 알 수 없다. 코드 조사
> 결과, `web_interface`는 부팅 시 `mqttCore.connect()` 가 성공해야 `bootSystem()`
> 이 완료되고(`src/config/startup.ts`), 런타임 중 MQTT 연결이 끊기는 경우를 감지해
> 별도로 요청을 거부하는 게이트는 발견하지 못했다 — `isHttpServiceReady()` 는
> 부팅 완료 후 한 번 true로 설정되면 이후 MQTT 연결 상태와 무관하게 유지되는
> 것으로 보인다(`src/config/readiness.ts`에 MQTT 상태를 구독해 false로 되돌리는
> 코드 없음). 즉 MQTT가 끊긴 상태에서 `/publish/*`, `/platform/info` 등
> MQTT 응답이 필요한 엔드포인트를 호출하면 `mqttResponseManager.publishRequest`
> 가 내부적으로 타임아웃/에러를 반환할 것으로 추정되나, 그때의 정확한 HTTP
> 상태코드/에러코드는 `mqttResponseManager`(별도 모듈, 이번 조사 범위 밖)의
> 구현을 봐야 확정할 수 있다. 개발자 확인 후 절차를 채운다.

### 목적
<TODO — 개발자 확인 후 작성: MQTT 브로커/응답 타임아웃 시 어느 엔드포인트가 어떤
HTTP 상태코드·에러코드를 반환해야 하는지 명세 필요>

### 사전 조건
<TODO>

### 절차
<TODO — 후보: `mosquitto` 서비스를 DUT에서 일시 중지한 뒤 `/publish/sys_manager/get_system_info`
등을 호출해 응답을 관찰하는 방식이 유력하나, web_interface 자체 프로세스가 MQTT
연결 끊김을 어떻게 재시도/보고하는지 먼저 확인 필요>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC03 — MQTT-HTTP Bridge 지원

### 목적

`POST /auth/token` 으로 발급받은 Bearer 토큰을 사용해 `POST
/publish/{target}/{service}` 로 MQTT 요청을 발행하고, HTTP 응답으로 MQTT 응답이
그대로 반환되는지 확인한다. (원본 Key150)

### 사전 조건

- 공통 전제 조건 충족 (`WI_AUTH_KEY`/`WI_AUTH_SECRET` — readonly 클라이언트,
  `publish:message` 권한은 readonly 역할에 없으므로 이 TC는 **admin/service 역할
  토큰이 필요**하다. readonly 토큰으로는 TC05-3과 동일하게 403이 반환되어 이
  TC의 목적인 "정상 Bridge 동작"을 검증할 수 없다 — 별도 admin/service 계정 확보 필요)
- `db_manager` 정상 응답 가능 (`edge_storage.db` / `system_setting` 테이블 존재)

### 절차

1. `POST /auth/token` 으로 토큰 발급 (`auth_key`/`auth_secret` 은 admin/service
   역할의 값 사용)
2. 응답의 `data.token` 추출, `data.roles`에 요청한 역할이 포함되는지 확인
3. 발급받은 토큰으로 `POST /publish/db_manager/select_records` 호출
   (`{"db":"edge_storage.db","table":"system_setting","keys":["country_code"]}`)
4. 응답 `httpStatus`가 200이고 `data.responseMessage.records`에 조회 결과가
   포함되는지 확인
5. 존재하지 않는 target(`nonexistent_app`)으로 동일 요청 → 에러 응답(4xx/5xx)과
   `data.errorCode`가 채워지는지 확인 (Bridge가 실패도 동일한 포맷으로 전달하는지)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 토큰 발급 | 200, `data.token` non-empty |
| 정상 Bridge 요청 | 200, `data.responseMessage` 에 MQTT 응답 포함 |
| 존재하지 않는 target | 4xx/5xx, `data.errorCode` 채워짐 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | 토큰 발급 성공 | boolean | true | `curl -sk -X POST https://$HOST:$PORT/auth/token -H 'Content-Type: application/json' -d "{\"auth_key\":\"$WI_AUTH_KEY\",\"auth_secret\":\"$WI_AUTH_SECRET\",\"subject\":\"tc03\"}" \| python3 -c "import json,sys;d=json.load(sys.stdin);assert d['httpStatus']==200 and d['data']['token']"` exit 0 |
| TC03-2 | Bridge select_records 정상 응답 | boolean | true | `curl -sk -X POST https://$HOST:$PORT/publish/db_manager/select_records -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","keys":["country_code"]}' -o /dev/null -w '%{http_code}'` == `200` |
| TC03-3 | 존재하지 않는 target에 대해 에러코드 포함 응답 | boolean | true | 위와 동일 요청을 `nonexistent_app`으로 보낸 응답 바디에 `"errorCode"` 키 존재 (`grep -o '"errorCode"'`) |

---

## TC04 — 로깅 보안 (민감 정보 마스킹) (검토 필요 — 마스킹 로직 위치 미확인)

> 원본 요구사항(Key151)이 인용하는 로그 라인(`[MqttCore:publish] Success to
> publish MQTT message topic - ...`)의 `[MqttCore:...]` 태그는 `web_interface`
> 자체 코드가 아니라 의존 패키지 `@qcells/edge-core`(GitHub
> `qcells-hqct/edge_core_nodejs`, 이 저장소에 벤더링되어 있지 않음) 내부에서
> 찍히는 로그로 보인다. `web_interface/src` 전체를 grep해도 password/민감정보를
> `****` 로 치환하는 마스킹 함수를 찾지 못했다. 즉 마스킹이 실제로 존재한다면
> edge-core 쪽 구현이고, web_interface 입장에서는 이를 통해 간접적으로만 검증
> 가능하다 (예: `/publish/db_manager/upsert_records` 로 `qa_test_password` 같은
> 키를 담아 요청한 뒤 journald에서 실제 로그 라인을 육안 확인). 어느 로그 태그/
> 어느 필드명 패턴이 마스킹 대상인지 개발자 확인 후 채운다.

### 목적
<TODO — 개발자 확인 후 작성: 마스킹 대상 필드명 패턴(`password`, `secret`,
`token` 등)과 마스킹이 적용되는 로그 태그 확정 필요>

### 사전 조건
<TODO>

### 절차
<TODO — 후보: `POST /publish/db_manager/upsert_records` 로
`{"key":"qa_test_password","value":"실제값"}` 형태 요청을 보낸 뒤
`journalctl -u docker-loader`(SSH 필요, 순수 curl 범위 밖)에서 해당 값이 원문
그대로 노출되는지 `****` 로 마스킹되는지 확인>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC05 — JWT 토큰 검증

### 목적

JWT 토큰이 정상 발급되고, 토큰의 역할(role)에 부여된 권한 범위 내 API만
허용되며 권한 밖 API는 거부되는지 확인한다. (원본 Key152)

### 사전 조건

- 공통 전제 조건 충족 (`WI_AUTH_KEY`/`WI_AUTH_SECRET` — readonly 역할)
- readonly 역할의 권한 목록 확인 (`src/config/extern-env.ts` `PERMISSION_READONLY`):
  `health:read`, `platform:info:read`, `telemetry:read`, `notifications:read`
  — `publish:message`, `export:system:log` 는 **포함되지 않음**

### 절차

1. `POST /auth/token` 으로 readonly 토큰 발급, `data.roles == ["readonly"]` 확인
2. 발급 토큰으로 `curl --data '{}' https://.../health/system` 호출 (curl은
   `--data` 사용 시 자동으로 POST) → `openapi.yaml`에 `/health/system`은 `GET`만
   선언되어 있으므로 express-openapi-validator가 405를 반환하는지 확인
3. 발급 토큰으로 `POST /publish/sys_manager/get_platform_info` 호출(readonly
   역할에 없는 `publish:message` 권한 필요) → 권한 부족 응답 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 토큰 발급 | 200, roles=["readonly"] |
| 허용되지 않은 메서드(POST /health/system) | HTTP 405 |
| 권한 밖 API(POST /publish/sys_manager/get_platform_info) | HTTP 4xx (권한 거부) |

> **Flag — 상태코드 불일치**: 원본 요구사항은 권한 밖 API 호출 시 **401**
> (`"unauthorized(Permission denied)"`)을 기대하지만, 현재 코드
> (`src/domains/auth/auth.security.ts` `openapiPermissionHandler`)는 인증은
> 됐지만 권한이 없는 경우를 의도적으로 **403**으로 분리해서 반환하도록 구현돼
> 있다 (주석: "Returning false makes the validator fall back to 401 ... Throwing
> with an explicit status makes the response a 403"). 즉 코드가 401→403으로
> 의도적으로 변경된 이력이 있고 원본 QA 문서가 이를 반영하지 못한 것으로 보인다.
> 아래 PASS 기준은 **현재 코드 기준(403)**으로 작성했다 — 실제 DUT 응답이 403인지
> 재확인 후, QA 문서(TestCase.xlsx Key152)도 함께 갱신 권장.

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC05-1 | readonly 토큰 발급 성공 | boolean | true | `curl -sk -X POST https://$HOST:$PORT/auth/token -H 'Content-Type: application/json' -d "{\"auth_key\":\"$WI_AUTH_KEY\",\"auth_secret\":\"$WI_AUTH_SECRET\",\"subject\":\"tc05\"}" \| grep -o '"roles":\["readonly"\]'` non-empty |
| TC05-2 | POST /health/system → 405 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/health/system -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'` == `405` |
| TC05-3 | POST /publish/sys_manager/get_platform_info → 403(현재 코드 기준, Flag 참고) | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/publish/sys_manager/get_platform_info -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'` == `403` |
| TC05-4 | 잘못된 secret으로 토큰 발급 시도 → 401 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/auth/token -H 'Content-Type: application/json' -d "{\"auth_key\":\"$WI_AUTH_KEY\",\"auth_secret\":\"wrong\",\"subject\":\"tc05\"}"` == `401` |

---

## TC06 — 경로 순회 공격 방지

### 목적

URL 경로/쿼리 파라미터에 포함된 경로 순회(`../`) 및 널 바이트 페이로드가
임의 파일 접근으로 이어지지 않는지 확인한다. (원본 Key160)

> 코드 조사 결과 이 앱에는 `express.static` 등 정적 파일 서빙이 전혀 없고,
> 유일한 파일 다운로드 경로(`GET /export/system/log`,
> `src/domains/system-log/system-log.handler.ts`)도 파일명이
> `current_system_log.log` 로 **하드코딩**되어 있어 쿼리 파라미터나 URL 경로로
> 임의 파일명을 주입할 방법 자체가 없다. 즉 이 앱에서 경로 순회는 "입력값을
> 정제해서 막는" 구조가 아니라 "애초에 사용자 입력이 파일 경로로 흘러가는
> 지점이 없는" 구조다. 아래 TC06-2/3은 원본이 기대하는 401(미인증) 자체는
> 재현되지만, 그 이유가 "경로 순회 방어"가 아니라 "`/export/system/log`가
> 인증을 요구하기 때문"이라는 점에 유의 — TC06-2b로 인증된 상태에서 `file`
> 쿼리를 바꿔도 응답이 불변임을 추가로 검증해 구조적 안전성을 보강했다.

### 사전 조건

- 공통 전제 조건 충족
- TC06-2b용 유효한 Bearer 토큰(`export:system:log` 권한 필요 — readonly에는
  없으므로 TC03과 동일하게 admin/service 역할 토큰 필요, 없으면 TC06-2b는 skip)

### 절차

1. (URL Path Traversal) 인증 없이 다음 경로들을 호출:
   `/../../../etc/passwd`, `/..%2f..%2f..%2fetc/passwd`,
   `/..\..\..\etc\passwd`, `/.%00./.%00./.%00./etc/passwd` 등
2. (Query Parameter Traversal, 미인증) `/export/system/log?file=../../../etc/passwd`
   등 쿼리 변형을 인증 없이 호출
3. (Query Parameter Traversal, 인증됨 — 준비물 있을 시) 동일 쿼리 변형을 유효한
   토큰으로 호출, 매번 동일한 `current_system_log.log` 내용(또는 동일 길이)이
   반환되는지 확인 — `file` 파라미터가 응답에 전혀 영향을 주지 않아야 함
4. (Null Byte Injection) `/auth/token%00.jpg`, `/health%00../../etc/passwd` 등을
   인증 없이 호출

### 기대 결과

| 항목 | 기준 |
|------|------|
| URL Path Traversal | HTTP 404 (매칭되는 라우트 없음) |
| Query Param Traversal(미인증) | HTTP 401 |
| Query Param Traversal(인증됨) | `file` 값과 무관하게 동일 응답, `/etc/passwd` 내용 없음 |
| Null Byte Injection | HTTP 400 또는 404 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | URL Path Traversal 전부 4xx (실제 /etc/passwd 내용 미노출) | boolean | true | 각 페이로드에 대해 `curl -sk https://$HOST:$PORT/<payload>` 응답에 `root:` 문자열 미포함 && `curl -sk -o /dev/null -w '%{http_code}' ...` 가 `4\d\d` 패턴 |
| TC06-2 | Query Param Traversal(미인증) → 401 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/export/system/log?file=../../../etc/passwd"` == `401` |
| TC06-3 | Query Param Traversal(인증됨, 준비물 있을 시) → file 파라미터 무관하게 응답 불변 | boolean | true | `diff <(curl -sk https://$HOST:$PORT/export/system/log -H "Authorization: Bearer $TOKEN") <(curl -sk "https://$HOST:$PORT/export/system/log?file=../../../etc/passwd" -H "Authorization: Bearer $TOKEN")` 결과 없음 — 토큰 부재 시 SKIP |
| TC06-4 | Null Byte Injection 전부 4xx | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/auth/token%00.jpg"` 가 `4\d\d` 패턴 |

---

## TC07 — Injection 공격 방지

### 목적

`/auth/token` 의 `auth_key` 필드에 SQL Injection류 페이로드를 주입해도 인증
로직이 오동작(우회)하지 않는지 확인한다. (원본 Key164)

> `AuthRepository`(`src/domains/auth/auth.repository.ts`)는 클라이언트 목록을
> 부팅 시 환경변수에서 읽어 메모리 내 `Map`으로 관리하며 SQL을 전혀 사용하지
> 않는다(`getAuthClient()`는 `Map.get()` 단순 조회). 따라서 `auth_key`에 어떤
> 문자열을 넣어도 "등록된 클라이언트가 아님" 판정 외의 결과가 나올 수 없는
> 구조다 — SQL Injection 자체가 구조적으로 불가능하다.

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `curl -sk -i -X POST https://$HOST:$PORT/auth/token -H 'Content-Type: application/json' -d '{"auth_key":"admin OR 1=1--","auth_secret":"x","subject":"x"}'`
2. 응답 상태 코드 및 `data.reason` 필드 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 상태 | HTTP 401 |
| 실패 사유 | `data.reason == "client_not_found"` (토큰 미발급) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | SQL Injection 페이로드 → 401 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/auth/token -H 'Content-Type: application/json' -d '{"auth_key":"admin OR 1=1--","auth_secret":"x","subject":"x"}'` == `401` |
| TC07-2 | 응답에 토큰 미포함 | boolean | true | 위 요청 응답 바디에 `"token"` 키 없음 |

---

## TC08 — CORS

### 목적

CORS preflight 응답의 `Access-Control-Allow-Methods` 가 정확히
`GET,POST,PUT,DELETE,OPTIONS` 만 포함하고, 그 외 메서드(PATCH/HEAD/CONNECT/TRACE
등)는 허용 목록에 없는지 확인한다. (원본 Key165)

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `curl -sk -i -X OPTIONS https://$HOST:$PORT/health -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: GET'` 로 preflight 응답의 `Access-Control-Allow-Methods` 헤더 원문 확인
2. 동일 요청을 `Access-Control-Request-Method` 값만 `PATCH`/`HEAD`/`CONNECT`/`TRACE` 로 바꿔 반복 — 매번 동일한 `Access-Control-Allow-Methods` 헤더(목록 불변)인지 확인
3. 실제 `curl -X PATCH https://$HOST:$PORT/health` 를 보내 서버가 해당 메서드
   라우트를 아예 갖고 있지 않음을 교차 확인(404)

### 기대 결과

| 항목 | 기준 |
|------|------|
| Access-Control-Allow-Methods | 정확히 `GET,POST,PUT,DELETE,OPTIONS` |
| PATCH 실제 요청 | 매칭 라우트 없음(404) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | Allow-Methods 헤더 값 정확히 일치 | boolean | true | `curl -sk -i -X OPTIONS https://$HOST:$PORT/health -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: GET' \| grep -i 'Access-Control-Allow-Methods' \| tr -d '\r'` == `Access-Control-Allow-Methods: GET,POST,PUT,DELETE,OPTIONS` |
| TC08-2 | PATCH 실제 요청 시 404(라우트 없음) | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X PATCH https://$HOST:$PORT/health` == `404` |

---

## TC09 — SSL 암호화 스위트

### 목적

HTTPS 연결이 TLS 1.3으로 협상되는지 확인한다. (원본 Key166)

> **Medium — 특정 cipher 값은 클라이언트 의존적**: `src/config/https.ts`는
> `minVersion: 'TLSv1.3'` 만 명시하고 TLS 1.3 자체의 3개 기본 cipher suite
> (`TLS_AES_128_GCM_SHA256`/`TLS_AES_256_GCM_SHA384`/`TLS_CHACHA20_POLY1305_SHA256`)
> 는 Node가 제공하는 기본값을 그대로 사용한다(개별 비활성화 코드 없음). 즉 서버가
> `TLS_AES_256_GCM_SHA384`를 **지원**하는 것은 코드로 확정할 수 있지만, 클라이언트가
> cipher 우선순위를 지정하지 않은 채 접속했을 때 어떤 suite가 최종 선택되는지는
> 클라이언트(curl/openssl 빌드)의 기본 선호 순서에 달려 있다. 아래 TC09-2는 클라이언트
> 쪽에서 해당 suite를 명시적으로 강제해 "서버가 지원하는가"를 확정적으로 검증한다.

### 사전 조건

- 공통 전제 조건 충족
- `openssl` 버전이 TLS 1.3을 지원 (`openssl version` ≥ 1.1.1)

### 절차

1. `curl -vk https://$HOST:$PORT/health 2>&1 | grep -E "(SSL connection|Cipher)"` 로 협상된 프로토콜 버전 확인
2. `openssl s_client -connect $HOST:$PORT -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384 </dev/null 2>&1 | grep -E "Cipher|Protocol"` 로 해당 suite를 강제했을 때 핸드셰이크가 성공하는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 기본 접속 시 프로토콜 | TLSv1.3 |
| TLS_AES_256_GCM_SHA384 강제 접속 | 핸드셰이크 성공 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | 기본 접속이 TLSv1.3으로 협상됨 | boolean | true | `curl -vk https://$HOST:$PORT/health 2>&1 \| grep -c "SSL connection using TLSv1.3"` ≥ 1 |
| TC09-2 | TLS_AES_256_GCM_SHA384 강제 시 핸드셰이크 성공 | boolean | true | `openssl s_client -connect $HOST:$PORT -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384 </dev/null 2>&1 \| grep -c "Cipher.*TLS_AES_256_GCM_SHA384"` ≥ 1 |

---

## TC10 — TLS 1.3 강제 (구버전 TLS 거부)

### 목적

서버가 TLS 1.3 미만(1.0/1.1/1.2)의 핸드셰이크 요청을 거부하는지 확인한다.
(원본 Key168)

### 사전 조건

- 공통 전제 조건 충족
- `src/config/https.ts`의 `minVersion: 'TLSv1.3'` 및
  `secureOptions`(`SSL_OP_NO_TLSv1`/`_1`/`_2` 비트 OR)로 이미 코드 레벨에서 강제됨을
  확인함 — 이 TC는 실제 DUT 응답으로 재확인하는 용도

### 절차

1. TLS 1.0/1.1/1.2/1.3 각각을 강제해 `/health` 호출:
   `curl -sk --tls-max 1.0 -o /dev/null -w '%{http_code}\n' https://$HOST:$PORT/health` (1.1/1.2도 동일 패턴, curl 버전에 따라 `--tlsv1.0`/`--tlsv1.1` 사용)
2. 1.0/1.1/1.2는 핸드셰이크 자체가 실패해 curl이 빈 응답(HTTP 000, 즉 `%{http_code}`가 `000`)을 출력해야 함
3. 1.3만 정상 핸드셰이크 후 실제 HTTP 상태코드(200)를 출력해야 함

### 기대 결과

| 항목 | 기준 |
|------|------|
| TLS 1.0/1.1/1.2 | HTTP 000 (핸드셰이크 실패) |
| TLS 1.3 | HTTP 200 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC10-1 | TLS 1.0 접속 시 000 | boolean | true | `curl -sk --tls-max 1.0 -o /dev/null -w '%{http_code}' https://$HOST:$PORT/health` == `000` |
| TC10-2 | TLS 1.1 접속 시 000 | boolean | true | `curl -sk --tls-max 1.1 -o /dev/null -w '%{http_code}' https://$HOST:$PORT/health` == `000` |
| TC10-3 | TLS 1.2 접속 시 000 | boolean | true | `curl -sk --tls-max 1.2 -o /dev/null -w '%{http_code}' https://$HOST:$PORT/health` == `000` |
| TC10-4 | TLS 1.3 접속 시 200 | boolean | true | `curl -sk --tlsv1.3 -o /dev/null -w '%{http_code}' https://$HOST:$PORT/health` == `200` |

---

## TC11 — Content-Type 검증

### 목적

POST/PUT/PATCH 요청에서 `application/json`/`multipart/form-data`/
`application/octet-stream` 이외의 Content-Type이 415로 거부되는지 확인한다.
(원본 Key169) — `src/utils/types.ts`의 `SUPPORTED_CONTENT_TYPES` 로 코드에서
직접 확인됨. 이 검증(`validateContentType`, `src/config/middleware.ts`)은 라우팅
이전 전역 미들웨어라서, 대상 경로에 실제 POST 핸들러가 없어도(`/health`는
GET 전용) 항상 먼저 적용된다 — 원본 요구사항이 `/health`에 POST로 보내는
이유이기도 하다.

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `curl -X POST https://$HOST:$PORT/health -H "Content-Type: text/plain" -d "test data" -k -i` → 상태 코드 확인
2. `curl -X POST https://$HOST:$PORT/health -H "Content-Type: application/xml" -d "<test/>" -k -i` → 상태 코드 확인
3. `curl -X POST https://$HOST:$PORT/health -H "Content-Type: text/html" -d "<html></html>" -k -i` → 상태 코드 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| text/plain | HTTP 415 |
| application/xml | HTTP 415 |
| text/html | HTTP 415 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC11-1 | text/plain → 415 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/health -H "Content-Type: text/plain" -d "test data"` == `415` |
| TC11-2 | application/xml → 415 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/health -H "Content-Type: application/xml" -d "<test/>"` == `415` |
| TC11-3 | text/html → 415 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/health -H "Content-Type: text/html" -d "<html></html>"` == `415` |

---

## TC12 — Rate Limit

### 목적

`express-rate-limit` 기반 Rate Limit이 분당 600회(초당 10회, `src/config/
middleware.ts` `apiLimiter`)로 설정되어 있으며, 초과 요청에 429를 반환하는지
확인한다. (원본 Key170)

### 사전 조건

- 공통 전제 조건 충족
- 이 TC 실행 직전 1분 이내에 다른 TC가 같은 IP로 대량 요청을 보내지 않았을 것
  (버킷이 이미 소모된 상태로 시작하면 카운트가 어긋남)

### 절차

1. 60초 이내에 `/health` 로 650회 연속 GET 요청 발행, 각 응답 상태 코드를 기록
2. 상태 코드별 카운트 집계 (200 vs 429)
3. `RateLimit-*` 표준 헤더(`standardHeaders: true`)가 응답에 포함되는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 429 발생 시점 | 약 601번째 요청부터 |
| 429 총 개수 | 약 50회(650-600) |
| RateLimit 헤더 | `RateLimit-Limit`, `RateLimit-Remaining` 응답에 포함 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC12-1 | 650회 중 429 응답이 40~60회 범위로 발생 | boolean | true | `for i in $(seq 1 650); do curl -sk -o /dev/null -w '%{http_code}\n' https://$HOST:$PORT/health; done \| sort \| uniq -c \| awk '$2==429{print $1}'` 가 40 이상 60 이하 |
| TC12-2 | RateLimit-Limit 헤더 값 == 600 | boolean | true | `curl -sk -i https://$HOST:$PORT/health \| grep -i '^RateLimit-Limit' \| tr -d '\r'` == `RateLimit-Limit: 600` |

---

## TC13 — XSS

### 목적

`auth_key` 필드에 `<script>` 태그를 주입해도 인증 API가 정상적으로 4xx/5xx를
반환하며, 응답 Content-Type이 항상 `application/json`으로 고정되고 `helmet` 의
`X-Content-Type-Options: nosniff` 헤더가 존재하는지 확인한다. (원본 Key171)

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `curl -k -X POST https://$HOST:$PORT/auth/token -H "Content-Type: application/json" -d '{"auth_key": "<script>alert(1)</script>", "auth_secret": "test", "subject": "test"}' -i`
2. 응답 상태 코드, `Content-Type`, `X-Content-Type-Options` 헤더 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 상태 | HTTP 401 |
| Content-Type | `application/json; charset=utf-8` |
| X-Content-Type-Options | `nosniff` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC13-1 | 응답 상태 401 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/auth/token -H "Content-Type: application/json" -d '{"auth_key":"<script>alert(1)</script>","auth_secret":"test","subject":"test"}'` == `401` |
| TC13-2 | Content-Type이 application/json | boolean | true | `curl -sk -i -X POST https://$HOST:$PORT/auth/token -H "Content-Type: application/json" -d '{"auth_key":"<script>alert(1)</script>","auth_secret":"test","subject":"test"}' \| grep -i '^content-type' \| tr -d '\r'` == `Content-Type: application/json; charset=utf-8` |
| TC13-3 | X-Content-Type-Options: nosniff 존재 | boolean | true | `curl -sk -i -X POST https://$HOST:$PORT/auth/token -H "Content-Type: application/json" -d '{"auth_key":"<script>alert(1)</script>","auth_secret":"test","subject":"test"}' \| grep -ic 'X-Content-Type-Options: nosniff'` ≥ 1 |

---

## TC14 — HSTS

### 목적

`Strict-Transport-Security` 헤더가 `max-age=31536000; includeSubDomains; preload`
로 정확히 설정되는지 확인한다. (원본 Key172) — `src/config/middleware.ts`의
`helmet({ hsts: { maxAge: 60*60*24*365, includeSubDomains: true, preload: true } })`
로 코드에서 직접 확인됨(`60*60*24*365 == 31536000`).

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `curl https://$HOST:$PORT/health -k -v 2>&1 | grep -i "strict-transport"`

### 기대 결과

| 항목 | 기준 |
|------|------|
| Strict-Transport-Security | `max-age=31536000; includeSubDomains; preload` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC14-1 | HSTS 헤더 값 정확히 일치 | boolean | true | `curl -sk -i https://$HOST:$PORT/health \| grep -i '^strict-transport-security' \| tr -d '\r'` == `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload` |

---

## TC15 — Log Level Control

### 목적

`web_interface`의 로그 레벨이 DB 설정값(`system_setting.log_level_wi`) 변경을
통해 조작 가능하고, 변경값이 영속화되는지 확인한다. (원본 Key176)

> **자동화 범위 한정**: Web HMI의 "Service 탭 > Log Level" UI는 내부적으로
> `db_manager`의 `system_setting` 테이블을 갱신하고(`upsert_records`), 이 앱은
> `emsp/.../noti/changed_records` MQTT 알림을 받아 `logLevelService.applyLogLevel()`
> 로 즉시 반영한다(`src/config/mqtt-handler.ts`). 이 흐름을 그대로 MQTT-HTTP
> Bridge(TC03과 동일 API)로 재현하면 **설정값이 저장되었는지는 순수 HTTP로
> 확인 가능**하지만, 로거의 실제 출력 레벨이 바뀌었는지(예: DEBUG 로그가 실제로
> 찍히기 시작하는지)는 journald 로그 확인이 필요해 SSH가 있어야 한다 — 순수
> curl 범위에서는 "설정 반영(persist)"까지만 자동 검증하고, "런타임 효과"는
> 선택적 교차 확인으로 별도 표시했다.

### 사전 조건

- 공통 전제 조건 충족
- admin/service 역할 토큰 확보(`publish:message` 권한 필요, TC03과 동일 제약)
- 로그 레벨 값 매핑(`src/domains/platform/platform.types.ts` `LOG_LEVEL_MAP`):
  `'0'`=debug 미만 단계 ~ `'9'`=trace 등 순번 매핑 존재 — 정확한 문자열 값은
  `VALID_LOG_LEVELS` 정의(edge-core) 확인 필요, 이 TC는 값 자체보다 "쓰고 읽으면
  동일한 값이 나오는지"만 검증

### 절차

1. `POST /publish/db_manager/select_records` 로 현재 `log_level_wi` 값 조회 (원복용 백업)
2. `POST /publish/db_manager/upsert_records` 로 `log_level_wi` 값을 이전과 다른
   값으로 변경 (예: `'0'` ↔ `'2'`)
3. 다시 `select_records` 로 조회해 변경값이 그대로 반영됐는지 확인
4. (선택, SSH 필요 시) `journalctl -u docker-loader --since "10 seconds ago" | grep "Log level set to"` 로 런타임 반영 로그 확인
5. cleanup: 1번에서 백업한 원래 값으로 복원

### 기대 결과

| 항목 | 기준 |
|------|------|
| 설정 변경 | `upsert_records` 응답 200 |
| 설정 영속화 | 재조회 시 변경된 값 그대로 반환 |
| (선택) 런타임 반영 | journald에 `Log level set to:` 로그 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC15-1 | log_level_wi 변경 요청 200 | boolean | true | `curl -sk -o /dev/null -w '%{http_code}' -X POST https://$HOST:$PORT/publish/db_manager/upsert_records -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_wi","type":1,"value":"2"}]}'` == `200` |
| TC15-2 | 재조회 시 변경값 일치 | boolean | true | `curl -sk -X POST https://$HOST:$PORT/publish/db_manager/select_records -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_wi"]}' \| grep -o '"value":"2"'` non-empty |
| TC15-3 | (SSH 있을 시) 런타임 반영 로그 존재 | manual | — | `journalctl -u docker-loader --since "10 seconds ago" \| grep "Log level set to"` — SSH 미사용 환경에서는 skip |

---

## 자동화 불가 / 검토 필요 항목 목록

원본 15개 TC 모두 정적 설정(HTTP 헤더, 상태 코드, TLS 파라미터) 검증으로
귀결되어 Burp Suite/OWASP ZAP 같은 별도 침투테스트 도구가 필요한 항목은
없었다. 자동화가 막힌 2건은 **도구 부재가 아니라 스펙/근거 부재**가 원인이다.

| TC | 원본 Key | 사유 |
|----|----------|------|
| TC02 | Key149 (MQTT Disconnect 시 Error Response) | 원본 Action이 비어 있음("추후 수정예정"). MQTT 연결 끊김을 감지해 되돌리는 게이트를 `web_interface` 소스에서 찾지 못함 — `mqttResponseManager`(범위 밖 모듈)의 타임아웃 처리 확인 필요 |
| TC04 | Key151 (로깅 보안/마스킹) | 인용된 로그 태그(`MqttCore:publish`)가 `@qcells/edge-core`(외부 패키지, 이 저장소에 없음) 소속으로 추정됨. `web_interface` 자체에는 마스킹 함수가 없음 — 마스킹 대상 필드/구현 위치 확인 필요 |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `HOST` | `192.168.10.25` | DUT IP (CLAUDE.md 기준) |
| `PORT` | `9112` | web_interface HTTPS 포트 (`src/config/env.ts` `DEFAULT_HTTPS_PORT`) |
| `WI_AUTH_KEY` | (없음, 필수 주입) | readonly 역할 테스트 클라이언트 auth_key — DUT 실제 값 확인 후 주입, 하드코딩 금지 |
| `WI_AUTH_SECRET` | (없음, 필수 주입) | 위 클라이언트의 auth_secret (SHA-256 hex) |
| `WI_ADMIN_AUTH_KEY` / `WI_ADMIN_AUTH_SECRET` | (없음, 필수 주입) | TC03/TC06-3/TC15 등 `publish:message` 권한이 필요한 TC용 admin/service 역할 클라이언트 |
| `TOKEN` | (스크립트 내부에서 발급) | TC 실행 중 `/auth/token` 응답에서 추출한 Bearer 토큰 |

---

## 관련 문서

- `tc_web_interface_result.md` — 본 TC 실행 결과 보고서
- `tc_web_interface_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/web_interface.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx "Web Interface" 카테고리, Key 148-176, 15개 TC)
- `qcells/uniep/web_interface/openapi/openapi.yaml` — 실제 구현된 OpenAPI 3.x 스펙 (TC01 교차검증 기준)
- `qcells/uniep/web_interface/src/config/https.ts`, `middleware.ts`, `openapi.ts` — TLS/CORS/Rate Limit/HSTS/Content-Type 설정 근거
- `qcells/uniep/web_interface/src/domains/auth/` — JWT 발급/검증, 권한 체크, 실패 시도 잠금 로직
