---
spec_id: edge_runtime
suite: application
grade: A
phase: Phase 1
test_file: tcs/edge_runtime/tc_edge_runtime.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-EDGE_RUNTIME: edge_runtime — 애플리케이션 실행 순서/의존성 보장, Ready/Heartbeat 관리, 재부팅 처리

## 목적 (Objective)

`edge_runtime` 애플리케이션이 담당하는 다음 기능을 검증한다:

- `uniep_applist.conf` (및 project `.conf`) 기반 order 순서/의존성 보장 Application 실행
- 모든 Application의 Ready(`NOTI_READY`) 알림 취합 및 All App Ready(`NOTI_ALL_APPS_READY`) 브로드캐스트
- Ready 알림 대기 타임아웃 처리 (앱 총 Ready 대기 60초 / DB Manager Ready 대기 10초)
- Heartbeat(`NOTI_HEARTBEAT`) 수신 기반 Watchdog 관리, 9초 미수신 시 타임아웃/크래시 감지
- 외부(HMI 등) Application/System 재부팅 요청 처리(`request_reboot`) 및 종료 시퀀스, `reboot_info.txt` 기록

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "Edge Runtime" 카테고리 원본 7개 TC
(Key 177/178/180/182/183/185/186, `docs/tc_requirements/edge_runtime.md`)를 기준으로
작성했다. 원본은 Jira에서 추출한 서술형 문서라 같은 검증을 여러 TC에서 중복
서술하는 부분이 있고(원본 작성자도 G2T-18/G2T-27 참고 링크로 중복을 자인함),
본 문서에서는 같은 코드 경로를 검증하는 단계를 하나의 TC로 합치고 원본 Key와의
매핑을 문서 하단 근거 매핑 표에 남겼다.

**소스 기반 핵심 사실 (아래 모든 TC의 근거)**

- MQTT 토픽 규칙: `emsp/<target>/<source>/<req|res|noti>/<service>`
  (`base_app.cpp` `publish_request`/`publish_response`/`publish_notification`)
- `request_reboot` (`SERVICE_REBOOT_APPLICAITON`)은 **edge_runtime 자기 프로세스에
  `SIGTERM`을 보내는 컨테이너(`ac_system_gen2`) 재시작**이다. 물리 장비/호스트
  OS를 재부팅하는 `reboot -f`나 `SERVICE_REBOOT_SYSTEM`(`request_system_reboot`,
  `sys_manager`의 `SERVICE_REBOOT_HOST`를 거쳐 실제 호스트를 재부팅함)과는 다르다.
  원본 TC-1/TC-6이 사용하는 토픽은 `request_reboot` 이므로 본 문서의 재부팅 관련
  TC는 모두 **컨테이너 재시작**이며 호스트가 물리적으로 리부트되지는 않는다.
  (단, 컨테이너 재시작 동안 모든 EMS 애플리케이션·MQTT 브로커가 재기동되므로
  SSH 세션 자체는 끊기지 않지만 DUT의 EMS 기능은 수십 초간 정지한다.)
- Watchdog 타이밍 상수(`watchdog.hpp`): `WATCHDOG_BOOT_TIMEOUT=60`(최초 전체 앱
  Ready 대기), `WATCHDOG_TIMEOUT=3`(정상 상태 점검 주기), `WATCHDOG_LIMIT_SECONDS=9`
  (개별 앱 Heartbeat 미수신 허용 한계). DB Manager 전용 초기 서비스 체크는
  `check_initial_service()`에 하드코딩된 10초 루프(`EdgeRuntime::check_initial_service`).
- `EXIT_APP_TIMEOUT_SECONDS=30`(`edge_runtime.hpp`): 종료 요청 후 각 앱의 응답을
  기다리는 최대 시간.
- 로그 포맷: `[HH:MM:SS:mmm][레벨][앱태그] 메시지` (`edge_logger.cpp`).
  edge_runtime 태그는 `ER` (`EdgeLogger::get().set_app_name_mapping(client_id, "ER")`).

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `edge_runtime` 프로세스 실행 중 (`pgrep -f edge_runtime` 또는
  `docker exec ac_system_gen2 pgrep -f edge_runtime`)
- MQTT 브로커 동작 중 (`localhost:1883`), `mosquitto_pub` / `mosquitto_sub` 설치됨
- `journalctl -u docker-loader` 로 모든 앱의 stdout/stderr(EdgeLogger 출력) 확인 가능
- root 권한, `/edge/log/`, `/edge/devapp/bin/`, `/edge/devapp/files/` 읽기/쓰기 가능
- `docker`(또는 `podman`) CLI 로 `ac_system_gen2` 컨테이너를 stop/재시작할 권한
  (`docker stop ac_system_gen2` — restart policy에 의해 자동 재기동됨을 전제)

> **⚠️ 파괴적 시험 경고:** TC01/TC02/TC03/TC04/TC05/TC06/TC08/TC09/TC11은 실행 중
> `ac_system_gen2` 컨테이너를 재시작시키거나 재시작을 유발한다 — **모든 EMS
> Application이 수십 초~약 1분간 정지**한다(물리 장비 재부팅은 아님, 위 소스 기반
> 핵심 사실 참고). 운영 중인 DUT에서는 유지보수 시간대에만 실행할 것.
> TC05/TC06/TC11은 실행 전 `/edge/devapp/bin/`, `/edge/devapp/files/` 상태를
> 백업하고 종료 후 반드시 원복해야 한다(원복하지 않으면 이후 모든 부팅이 실패한다).

---

## TC01 — Application Reboot 요청 시 전체 Application 정상 종료 (파괴적: 컨테이너 재시작)

### 목적

`request_reboot` (`SERVICE_REBOOT_APPLICAITON`) 요청 수신 시 edge_runtime이
`SERVICE_SHUTDOWN_APPLICATION`을 자신을 제외한 모든 앱에 브로드캐스트하고, 각 앱의
종료 응답을 취합해 정상 종료를 확인하는지 검증한다. (원본 TC-1 Action, TC-6 Step4와
동일 트리거 — 원본이 직접 중복을 명시)

### 사전 조건

- 공통 전제 조건 충족, 파괴적 시험 경고 인지
- DUT가 정상 부팅 완료 상태(`all_apps_ready_status` 응답 `is_ready=true`)

### 절차

1. SETUP: `mosquitto_pub -t "emsp/$TARGET/$SOURCE/req/all_apps_ready_status" -m '{}'`
   로 사전 상태 확인, `journalctl -u docker-loader -f` 캡처 시작
2. `mosquitto_pub -h $MQTT_HOST -t "emsp/edge_runtime/$SOURCE/req/request_reboot" -m '{"reason":"tc01_test_restart"}'`
3. 응답 대기: `emsp/$SOURCE/edge_runtime/res/request_reboot` 구독 (edge_runtime은
   종료 시퀀스 시작 전에 즉시 빈 payload로 응답함 — 응답 자체는 종료 완료를 의미하지
   않음, 후속 로그로 완료를 판정해야 함)
4. 최대 `EXIT_APP_TIMEOUT_SECONDS(30)`+여유 10초 동안 로그에서 `Shutdown Status:`
   블록 및 `All apps terminated: YES` 확인
5. 각 product 앱의 `cleanup()` 로그 확인 (`EnergyDispatcher cleanup`,
   `DeviceLog cleanup`, `TemplateApplication cleanup` 등 — 앱마다 문구는
   `<ClassName> cleanup` 패턴이 대부분이나 완전히 통일되어 있지는 않음)
6. 컨테이너 재기동 완료 확인: 새 `[I][ER] App is ready` (BaseApp::run() 진입) 로그 및
   `all_apps_ready_status` 재조회로 `is_ready=true` 복귀 확인 (최대 90초 대기)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 종료 요청 응답 | `request_reboot` 응답 수신(payload 무관, 수신 자체가 기준) |
| 종료 취합 로그 | `Shutdown Status:` ... `All apps terminated: YES` |
| 개별 앱 cleanup | 최소 1개 이상 product 앱의 `*cleanup*` 로그 확인 |
| 재기동 | 90초 이내 `all_apps_ready_status` 가 다시 `true` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | request_reboot 응답 수신 | boolean | true | `mosquitto_sub -C 1 -W 10 -t "emsp/$SOURCE/edge_runtime/res/request_reboot"` 타임아웃 없이 수신 |
| TC01-2 | 전체 앱 종료 완료 로그 | boolean | true | `journalctl -u docker-loader --no-pager \| grep -q "All apps terminated: YES"` |
| TC01-3 | 강제종료(SIGKILL) 없이 정상 종료 | boolean | true | 로그에 `TERMINATE_TIMEOUT_MS` 관련 `TERMINATE_TIMEOUT_MS -- pid:` 라인이 **없음** (있으면 일부 앱이 SIGTERM에 응답하지 않고 SIGKILL로 강제 종료된 것) |
| TC01-4 | 재기동 후 전체 Ready 복귀 | boolean | true | `mosquitto_pub -t emsp/edge_runtime/$SOURCE/req/all_apps_ready_status -m '{}'` 응답의 `is_ready == true` (90초 내) |

---

## TC02 — Application Reboot 요청 시 reboot_info.txt 기록 (TC01과 동일 트리거)

### 목적

재부팅 요청 처리 중 `write_reboot_info()`가 `/edge/log/reboot_info.txt`에 요청자·시각·사유를
정상 기록하는지 검증한다. (원본 TC-1 연속 스텝, TC-6 Step5와 동일 산출물 — 원본이
직접 중복을 명시)

### 사전 조건

- 공통 전제 조건 충족
- `/edge/log/reboot_info.txt` 읽기 가능 (없으면 최초 기록으로 간주)

### 절차

1. `LINES_BEFORE=$(wc -l < /edge/log/reboot_info.txt 2>/dev/null || echo 0)`
2. TC01과 동일하게 `mosquitto_pub ... req/request_reboot -m '{"reason":"tc02_test_restart"}'`
   전송 (source를 `$SOURCE`로 고정)
3. 컨테이너 재기동 대기 후 `/edge/log/reboot_info.txt` 재확인
4. 새로 추가된 라인에서 `"BY"` 필드가 `$SOURCE`, `"TYPE"` 필드에 `tc02_test_restart`가
   포함되는지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 파일 라인 수 | 요청 전보다 증가 |
| BY 필드 | 요청 시 사용한 source id와 일치 |
| TYPE 필드 | 요청 payload(reason 포함)가 그대로 기록됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | 신규 라인 추가 | boolean | true | `[ "$lines_after" -gt "$lines_before" ]` |
| TC02-2 | BY 필드 일치 | boolean | true | `tail -n 5 /edge/log/reboot_info.txt \| grep -q "\"BY\" : \"$SOURCE\""` |
| TC02-3 | TYPE 필드에 reason 포함 | boolean | true | `tail -n 5 /edge/log/reboot_info.txt \| grep -q "tc02_test_restart"` |

---

## TC03 — 부팅 시 uniep Application 실행 순서 (order 기반 fork/Ready 시퀀스, 파괴적)

### 목적

`uniep_applist.conf`의 `order` 값 순서대로 Application이 fork되고, 동일 `order`
그룹은 이전 그룹 전체가 Ready를 보낼 때까지 시작되지 않는지 확인한다.
(원본 TC-5 Step2~3, TC-7 Step3의 fork 로그와 동일 캡처 구간이므로 통합)

### 사전 조건

- 공통 전제 조건 충족, 파괴적 시험 경고 인지
- `/edge/app/files/edge_runtime/uniep_applist.conf`가 기본값(수정하지 않은 상태)

### 절차

1. `journalctl -u docker-loader -f` 캡처 시작 (타임스탬프 포함 저장)
2. `docker stop ac_system_gen2` (restart policy로 자동 재기동)
3. 재기동 완료(전체 Ready)까지 로그 수집
4. `Spawn App: <name>` / `app_fork - pid: <pid>` 라인에서 fork 순서 추출
5. `[I][<TAG>] App is ready` 라인에서 Ready 순서 및 타임스탬프 추출
6. `uniep_applist.conf`를 파싱해 앱별 `order`를 구하고, Ready 순서가 order
   오름차순과 모순되지 않는지 확인(동일 order 그룹 내부는 순서 무관)

### 기대 결과

| 항목 | 기준 |
|------|------|
| fork 로그 | `Spawn App:`/`app_fork - pid:` 쌍이 uniep_applist.conf의 모든 앱에 대해 존재 |
| Ready 순서 | order 오름차순, 동일 order 그룹 내부는 임의 순서 허용 |
| db_manager | edge_runtime 자신을 제외하고 가장 먼저 fork/Ready (order=2, 코드상 `start()`에서 별도 우선 fork) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | db_manager가 가장 먼저 fork됨 | boolean | true | `journalctl ... \| grep "Spawn App:" \| head -1 \| grep -q db_manager` |
| TC03-2 | 모든 uniep 앱 fork 로그 존재 | boolean | true | `uniep_applist.conf`의 각 name에 대해 `grep -q "Spawn App: $name"` |
| TC03-3 | Ready 순서가 order 오름차순과 모순되지 않음 | manual/script | true | Ready 타임스탬프를 order로 정렬 비교하는 파싱 스크립트 결과 |

---

## TC04 — 전체 Application Ready 시 All App Ready 알림 + LED 녹색 전환 (파괴적)

### 목적

모든(uniep + project) Application이 `NOTI_READY`를 보내면 edge_runtime이
`NOTI_ALL_APPS_READY`를 전체 앱에 브로드캐스트하고, `sys_manager`에 녹색 LED 제어
요청(`SERVICE_SET_LED_CONTROL`, `color: "0 255 0"`)을 보내는지 확인한다.
(원본 TC-2 Action + 연속 스텝1/2)

### 사전 조건

- 공통 전제 조건 충족, 파괴적 시험 경고 인지
- `/edge/devapp/bin/`에 앱 실행을 방해하는 빈 파일이 없는 정상 상태

### 절차

1. `emsp/+/edge_runtime/noti/all_apps_ready` 및
   `emsp/sys_manager/edge_runtime/req/set_led_control` 두 토픽을 동시에 구독 시작
2. `docker stop ac_system_gen2` 로 재기동 유발
3. 재기동 후 최대 90초 대기하며 두 토픽의 첫 메시지 수신 확인
4. `NOTI_ALL_APPS_READY` payload의 `app_ids` 배열 확인
5. (선택, 실제 LED까지 확인하려면) `sys_manager`에
   `mosquitto_pub -t "emsp/sys_manager/$SOURCE/req/get_led_status" -m '{"instance_id":0}'`
   요청 후 응답 payload의 `leds[0].color`가 `"0 255 0"`인지 확인 — 이 부분은
   sys_manager의 LED 구동 자체를 검증하는 것이므로 edge_runtime TC의 책임 범위를
   벗어나지만 교차 확인용으로 유용하다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| All App Ready 알림 | 재기동 후 전체 앱에 브로드캐스트됨 |
| LED 녹색 요청 | `color: "0 255 0"`, `brightness: 128` payload로 sys_manager에 요청 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | all_apps_ready 알림 수신 | boolean | true | `mosquitto_sub -C 1 -W 90 -t "emsp/+/edge_runtime/noti/all_apps_ready"` 수신 |
| TC04-2 | app_ids 배열에 uniep_applist.conf 전체 앱 포함 | boolean | true | payload `app_ids` ⊇ conf에 정의된 name 목록 |
| TC04-3 | 녹색 LED 제어 요청 발행 | boolean | true | 구독 로그에서 `"color":"0 255 0"` 포함 payload 수신 |
| TC04-4(선택) | 실제 LED 상태 반영 | boolean | true | `get_led_status` 응답 `leds[].color == "0 255 0"` |

---

## TC05 — 일부 Application Ready 실패 시 60초 Boot Watchdog 타임아웃 → LED 적색 + 컨테이너 재시작 (파괴적, bin 변조)

### 목적

특정 앱이 기동 실패(바이너리 손상 등)로 `NOTI_READY`를 보내지 못하면, 최초
Watchdog 점검(부팅 후 60초 시점, `WATCHDOG_BOOT_TIMEOUT`)에서 관리 앱 수 불일치를
감지해 적색 LED 요청(`color: "255 0 0"`) 후 컨테이너를 재시작하는지 확인한다.
(원본 TC-2 연속 스텝3, TC-3 Action)

### 사전 조건

- 공통 전제 조건 충족, 파괴적 시험 경고 인지 — **시험 후 반드시 원복 필요**
- `/edge/devapp/bin/` 쓰기 가능 (devapp 오버레이가 `/edge/app/bin/`을 덮어씀 —
  `startup.sh`의 `copy_dev_bin()`)
- 대상 앱은 db_manager를 제외한 임의의 uniep 앱 권장(예: `energy_monitor`) — db_manager는
  TC06에서 별도의 10초 타임아웃 경로로 처리되므로 이 TC의 대상에서 제외

### 절차

1. BACKUP: `/edge/devapp/bin/` 기존 내용 백업(또는 비어있음 확인)
2. `touch /edge/devapp/bin/energy_monitor && chmod +x /edge/devapp/bin/energy_monitor`
   (빈 파일 — `posix_spawn`이 유효한 실행 파일이 아니므로 실패)
3. `journalctl -u docker-loader -f` 캡처 시작
4. `docker stop ac_system_gen2` 로 재기동 유발 (`startup.sh`가 devapp bin으로 덮어씀)
5. 최대 70초 대기하며 로그에서 `posix_spawn failed`(energy_monitor 대상) 및
   부팅 후 약 60초 시점의 watchdog 판정 로그 확인
6. `Some app did not be executed` 에러 로그, 적색 LED 요청, `reboot_conatiner` 확인
7. CLEANUP(필수): `rm -f /edge/devapp/bin/energy_monitor` 로 원복 후 컨테이너 재시작해
   정상 부팅(TC04 기준 충족) 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| fork 실패 | `posix_spawn failed` 로그 (energy_monitor) |
| 60초 판정 | `Some app did not be executed == It will be reset` 에러 로그 |
| LED | `color: "255 0 0"` 요청 발행 |
| 재시작 | `reboot_conatiner` 로그 후 컨테이너 재기동 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC05-1 | fork 실패 로그 | boolean | true | `grep -q "posix_spawn failed"` |
| TC05-2 | 앱 수 불일치 판정 로그 | boolean | true | `grep -q "Some app did not be executed"` |
| TC05-3 | 적색 LED 요청 발행 | boolean | true | 구독 로그에서 `"color":"255 0 0"` 포함 payload 수신 |
| TC05-4 | 컨테이너 재시작 트리거 | boolean | true | `grep -q "reboot_conatiner"` (최초 1회, 중복 방지 로그 `already in progress`는 없어야 함) |
| TC05-5(cleanup 검증) | 원복 후 정상 재부팅 | boolean | true | TC04-1 기준 재충족 |

---

## TC06 — DB Manager Ready 실패 시 10초 초기 서비스 타이머 타임아웃 → 컨테이너 재시작 (파괴적, bin 변조)

### 목적

`db_manager`가 fork 직후 10초 내 Ready를 보내지 못하면(`check_initial_service()`)
별도의 10초 하드코딩 타이머가 만료되어 적색 LED 요청 후 컨테이너를 재시작하는지
확인한다. TC05의 60초 전체 타임아웃과는 다른 코드 경로이므로 별도 TC로 분리한다.
(원본 TC-3 연속 스텝2)

### 사전 조건

- TC05와 동일 (대상만 `db_manager`로 고정), **시험 후 반드시 원복 필요**

### 절차

1. BACKUP 확인 후 `touch /edge/devapp/bin/db_manager && chmod +x /edge/devapp/bin/db_manager`
2. `journalctl -u docker-loader -f` 캡처 시작
3. `docker stop ac_system_gen2` 로 재기동 유발
4. db_manager fork 직후(`start_child_app`에서 db_manager 분기 로그
   `DB Manager started. Next step is for other service execution.` 및
   `If dbmgr is not ready until 10 sec, then EMS system will restart.`) 시각을 t0로 기록
5. t0+15초까지 대기하며 `Initial service timer by timeout` 로그, 적색 LED 요청,
   `reboot_conatiner` 확인
6. CLEANUP(필수): `rm -f /edge/devapp/bin/db_manager` 원복 후 컨테이너 재시작해
   정상 부팅 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 10초 타이머 만료 | `Initial service timer by timeout` (t0+10초 근처, ±2초 허용) |
| LED | `color: "255 0 0"` 요청 |
| 재시작 | `reboot_conatiner` 로그 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | 10초 타이머 시작 로그 | boolean | true | `grep -q "10 sec. timer starts for initial service"` |
| TC06-2 | 타임아웃 로그 발생 시각이 t0+10±2초 | boolean | true | 타임스탬프 파싱 비교 |
| TC06-3 | 적색 LED 요청 발행 | boolean | true | `"color":"255 0 0"` payload 수신 |
| TC06-4 | 컨테이너 재시작 트리거 | boolean | true | `grep -q "reboot_conatiner"` |
| TC06-5(cleanup 검증) | 원복 후 정상 재부팅 | boolean | true | TC04-1 기준 재충족 |

---

## TC07 — Heartbeat 수신 시 Watchdog 리스트 갱신 로그 (Debug 로그 레벨 필요)

> **Flag — 원본과 실제 로그 문구 불일치:** 원본은 `handler_noti_watchdog From: app_name`
> 라는 로그 문구를 기대하지만, 현재 소스(`edge_runtime.cpp:803`)의
> `handler_noti_watchdog()`에는 해당 로그 호출이 없다. 실제로 관찰 가능한 로그는
> `Watchdog::watchdog_list_update()`(`watchdog.cpp:132`)의
> `WatchDog Update APP: <app_id>` (DEBUG 레벨)이다. 아래 절차는 이 실제 로그를
> 기준으로 재구성했다 — 개발자에게 원본 문구 추가 여부(또는 원본 문서 자체의
> 구버전 코드 인용 여부) 확인 필요.

### 목적

각 Application의 3초 주기 Heartbeat(`NOTI_HEARTBEAT`) 수신 시 edge_runtime이
Watchdog 관리 리스트를 갱신하는지, DEBUG 로그 레벨에서 관찰 가능한지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- DUT가 정상 부팅 완료 상태(all_apps_ready)
- `db_manager`를 통해 `log_level_er` system_setting을 변경할 수 있음
  (`SERVICE_UPDATE_RECORDS`, `SettingType::UINT8=1`, `LogLevel::Debug=0`)

### 절차

1. 로그 레벨을 Debug로 변경:
   ```
   mosquitto_pub -t "emsp/db_manager/$SOURCE/req/update_records" -m \
     '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_er","value":"0","type":1}]}'
   ```
2. `handle_response_system_settings`/`handle_noti_system_settings_changed` 경로로
   `Log level changed: 0` 로그가 나타나는지 확인 (레벨 변경 자체의 근거)
3. `journalctl -u docker-loader -f` 캡처 시작
4. 60초 이상 대기하며 `WatchDog Update APP: <app_id>` 라인이 여러 앱에 대해
   반복적으로(대략 3초 간격) 나타나는지 확인
5. CLEANUP: `log_level_er`을 원래 레벨(예: `1`=Info)로 복원

### 기대 결과

| 항목 | 기준 |
|------|------|
| 로그 레벨 변경 확인 | `Log level changed: 0` |
| Heartbeat 갱신 로그 | uniep_applist.conf의 각 앱에 대해 `WatchDog Update APP: <app_id>` 반복 관찰 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | Debug 레벨 전환 확인 | boolean | true | `grep -q "Log level changed: 0"` |
| TC07-2 | 앱별 Watchdog 갱신 로그 존재 | boolean | true | uniep_applist.conf 각 name에 대해 `grep -q "WatchDog Update APP: $name"` |
| TC07-3 | 로그 레벨 원복 | boolean | true | `grep -q "Log level changed: 1"`(또는 원래 값) |

---

## TC08 — Heartbeat 9초 미수신(Application Crash 포함) 시 Watchdog 재부팅 (파괴적, kill -9)

### 목적

특정 앱이 `WATCHDOG_LIMIT_SECONDS(9초)` 동안 Heartbeat를 보내지 못하면(정지 또는
강제 종료) Watchdog이 이를 감지해 해당 앱을 dead_app으로 지정한 채 종료 시퀀스를
개시하고, 최종적으로 `reboot_info.txt`에 `"reason":"watchdog"` 사유로 기록되는지
확인한다. (원본 TC-4 연속 스텝2/5/6, TC-6 연속 스텝3과 동일 메커니즘 — 원본 TC-4
스텝6 "크래시 감지"도 스텝5와 "타임아웃 시 Core Container 재부팅 방법과 동일"이라고
명시하므로 통합)

### 사전 조건

- 공통 전제 조건 충족, 파괴적 시험 경고 인지
- DUT가 정상 부팅 완료 상태
- 대상 앱은 edge_runtime이 아닌 임의의 child 앱(예: `energy_dispatcher`)

### 절차

1. `ps -ef | grep energy_dispatcher` (또는 `docker exec ac_system_gen2 ps -ef | grep energy_dispatcher`)로 PID 확보
2. `journalctl -u docker-loader -f` 캡처 시작, 시각 t0 기록
3. `kill -9 <PID>`
4. t0+9~15초 사이 로그에서 `did not send heartbeat == It will be reset` 확인
5. 이후 `Reboot Now!!! Requested by edge_runtime, {"reason":"watchdog"...` 로그 확인
   (`write_reboot_info`가 그대로 로그로도 출력)
6. `/edge/log/reboot_info.txt`에 `"BY" : "edge_runtime"`, `"TYPE"`에 `watchdog` 포함
   라인 추가 확인
7. 컨테이너 재기동 후 정상 부팅(TC04 기준) 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 타임아웃 감지 | 9~15초 내 `did not send heartbeat == It will be reset` |
| 재부팅 사유 로그 | `Reboot Now!!! Requested by edge_runtime, {"reason":"watchdog"...` |
| reboot_info.txt | `BY: edge_runtime`, `TYPE`에 `watchdog` 포함 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | 9~15초 내 타임아웃 감지 | boolean | true | 타임스탬프 파싱, `grep -q "did not send heartbeat"` |
| TC08-2 | watchdog 사유 재부팅 로그 | boolean | true | `grep -q '"reason":"watchdog"'` |
| TC08-3 | reboot_info.txt 기록 | boolean | true | `grep -q "watchdog" /edge/log/reboot_info.txt` (최신 라인) |
| TC08-4 | 재기동 후 정상 복귀 | boolean | true | TC04-1 기준 재충족 |

---

## TC09 — 최초 Watchdog 점검(부팅 후 60초 시점) 관리 앱 총계 로그 (파괴적, TC04와 캡처 세션 공유 가능)

> **Flag — 원본 표현("3초마다 개수가 찍힌다")과 실제 동작 불일치:** 이 총계 로그
> (`total_app_size = ..., uniep_application_size = ..., other_application_size = ...`,
> `watchdog.cpp:64`)는 `timeout_watchdog()`의 `first_boot_` 분기 안에서만 출력되며
> `first_boot_`는 최초 1회 점검(부팅 후 `WATCHDOG_BOOT_TIMEOUT=60`초 시점) 후
> `false`로 바뀐다. 즉 **부팅 후 정확히 1회만** 출력되고, 이후 3초 주기 점검에서는
> 이 로그가 반복되지 않는다("3초마다 Watchdog 체크 동작"은 맞지만 "3초마다
> 개수가 찍힌다"는 원본 서술과는 다르다). 아래는 실제 동작 기준.

### 목적

정상 부팅(모든 앱 fork 성공) 시 최초 Watchdog 점검에서 관리 중인 앱 총수가
설정 파일 상 총 앱 수와 일치해 재부팅 없이 정상 통과하는지, 그리고 그 시점에
카운트 로그가 DEBUG 레벨로 1회 출력되는지 확인한다. (원본 TC-4 연속 스텝3/4)

### 사전 조건

- 공통 전제 조건 충족, 파괴적 시험 경고 인지
- 로그 레벨 Debug (TC07 절차 1 참고)
- `/edge/devapp/bin/`에 변조된 파일이 없는 정상 상태 (TC05/06 cleanup 확인 후 진행)

### 절차

1. Debug 레벨 전환 (TC07 절차 1)
2. `journalctl -u docker-loader -f` 캡처 시작
3. `docker stop ac_system_gen2` 로 재기동 유발, db_manager fork 시각을 t0로 기록
4. t0+60~70초 구간에서
   `total_app_size = N, uniep_application_size = M, other_application_size = K` 로그 확인
5. `N == M + K` 인지, 그리고 이 로그 직후 재부팅 로그가 **없는지**(정상 통과) 확인
6. `uniep_applist.conf`(+project conf)에 정의된 총 앱 수와 M+K 비교

### 기대 결과

| 항목 | 기준 |
|------|------|
| 카운트 로그 | t0+60~70초 구간에 정확히 1회 출력 |
| 카운트 일치 | `total_app_size == uniep_application_size + other_application_size` |
| 재부팅 없음 | 카운트 일치 시 `Some app did not be executed` 로그 없음 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | 카운트 로그 1회 출현 | boolean | true | `grep -c "total_app_size = "` == 1 |
| TC09-2 | 카운트 일치 | boolean | true | 로그에서 파싱한 N == M+K |
| TC09-3 | 정상 통과(재부팅 없음) | boolean | true | 카운트 로그 이후 `Some app did not be executed` 미출현 |

---

## TC10 — uniep_applist.conf 파일 형식 검증 (비파괴적)

### 목적

`/edge/app/files/edge_runtime/uniep_applist.conf`가 `order`/`name`/`tags` 필드를
갖는 JSON 배열이며, edge_runtime(order=1)과 db_manager(order=2)가 고정 순서인지
확인한다. (원본 TC-5 Action + 연속 스텝1)

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `docker exec ac_system_gen2 /bin/bash -c 'cat /edge/app/files/edge_runtime/uniep_applist.conf'`
   (SSH 세션이 이미 컨테이너 내부라면 `cat /edge/app/files/edge_runtime/uniep_applist.conf`)
2. `jq` 로 JSON 유효성 검증 및 `applications[]` 배열의 `order`/`name`/`tags` 필드 존재 확인
3. `name=="edge_runtime"` 항목의 `order==1`, `name=="db_manager"` 항목의 `order==2` 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| JSON 형식 | `{"applications":[{"order":N,"name":"...","tags":"..."},...]}` |
| edge_runtime order | 1 (고정) |
| db_manager order | 2 (고정) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC10-1 | JSON 파싱 성공 | boolean | true | `jq -e . uniep_applist.conf >/dev/null` |
| TC10-2 | edge_runtime order=1 | boolean | true | `jq -e '.applications[] \| select(.name=="edge_runtime") \| .order==1'` |
| TC10-3 | db_manager order=2 | boolean | true | `jq -e '.applications[] \| select(.name=="db_manager") \| .order==2'` |

---

## TC11 — devapp 오버라이드로 Application 실행 순서 변경 (파괴적, conf 변경 + 컨테이너 재시작)

### 목적

`/edge/devapp/files/`에 배치한 `uniep_applist.conf`가 컨테이너 재시작 시
`startup.sh`의 `copy_dev_bin()`에 의해 `/edge/app/files/edge_runtime/`로 복사(덮어쓰기)
되어 변경된 order대로 Application이 실행되는지 확인한다. (원본 TC-5 연속 스텝4/5)

### 사전 조건

- 공통 전제 조건 충족, 파괴적 시험 경고 인지
- **시험 후 반드시 원본 uniep_applist.conf로 원복 필요** (order 1=edge_runtime,
  2=db_manager 고정 규칙을 어기면 이후 부팅 자체가 실패할 수 있음 — 소스는 이
  규칙을 강제하지 않으므로 실수로 무너뜨리지 않도록 원본을 반드시 백업해 둘 것)

### 절차

1. BACKUP: `cp /edge/app/files/edge_runtime/uniep_applist.conf /tmp/uniep_applist.conf.bak`
2. `mkdir -p /edge/devapp/files && cp /tmp/uniep_applist.conf.bak /edge/devapp/files/uniep_applist.conf`
3. `/edge/devapp/files/uniep_applist.conf`에서 order 3 이상인 두 앱의 order를
   서로 교환 (예: `energy_link`(order 3)와 `sys_manager`(order 4) 중 하나를 개별
   order로 분리하거나 교환 — 1/2는 건드리지 않음)
4. `journalctl -u docker-loader -f` 캡처 시작
5. `docker stop ac_system_gen2` 재기동
6. `/edge/app/files/edge_runtime/uniep_applist.conf` 내용이 devapp본으로 교체됐는지 확인
7. Ready 로그 순서가 변경된 order를 따르는지 확인 (TC03과 동일 파싱 방식)
8. CLEANUP(필수): `cp /tmp/uniep_applist.conf.bak /edge/devapp/files/uniep_applist.conf`
   로 원복 후 재기동, 또는 `/edge/devapp/files/uniep_applist.conf` 삭제 후 재기동해
   기본값으로 복귀 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| conf 복사 | `/edge/app/files/edge_runtime/uniep_applist.conf`가 devapp본과 동일해짐 |
| 실행 순서 | 변경된 order 순서로 Ready 로그 관찰 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC11-1 | devapp conf가 app 경로로 복사됨 | boolean | true | `diff /edge/devapp/files/uniep_applist.conf /edge/app/files/edge_runtime/uniep_applist.conf` 결과 없음 |
| TC11-2 | 변경된 order대로 Ready 순서 관찰 | manual/script | true | Ready 타임스탬프 파싱 비교 |
| TC11-3(cleanup 검증) | 원복 후 기본 순서 복귀 | boolean | true | TC03-3 기준 재충족 |

---

## TC12 — 실행 중인 필수 Application 프로세스 목록 확인 (비파괴적)

### 목적

정상 부팅 후 `edge_runtime`이 fork한 모든 필수 uniep Application(및 관련 Node.js
프로세스)이 실행 중인지 `ps` 기반으로 확인한다. (원본 TC-6 연속 스텝2, TC-7 연속
스텝4 — 두 원본 TC가 동일한 `ps | grep edge` 절차와 동일 기대 결과를 사용하므로 통합)

### 사전 조건

- 공통 전제 조건 충족
- DUT가 정상 부팅 완료 상태

### 절차

1. `ps -ef | grep -E 'edge_runtime|db_manager|azure_connector|energy_link|energy_monitor|sys_manager|update_monitor|device_manager|energy_dispatcher' | grep -v grep`
2. `uniep_applist.conf` + project conf에 정의된 각 name에 대해 대응 프로세스가
   `ps` 출력에 있는지 확인
3. `/edge/app/bin/edge_runtime`, `node .../www.js`(uniep API/product API/HMI) 3개
   Node.js 프로세스도 함께 확인 (`startup.sh`가 fork)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 필수 앱 프로세스 | uniep_applist.conf 각 name에 대응하는 `/edge/app/bin/<name>` 프로세스 존재 |
| Node.js 프로세스 | uniep API / product API / product HMI 3개 node 프로세스 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC12-1 | 필수 앱 전체 프로세스 존재 | boolean | true | conf의 각 name에 대해 `ps -ef \| grep -q "/edge/app/bin/$name"` |
| TC12-2 | Node.js 3개 프로세스 존재 | boolean | true | `ps -ef \| grep -c "node .*\(www\|server_hmi\)\.js"` == 3 |

---

## TC13 — Configuration 기반 Project(non-uniep) Application 실행 (검토 필요 — 대상 conf 사전 확인)

> `EdgeRuntime::start()`는 `APPLICATIONS_LIST_DIRECTORY`(`/edge/app/files/edge_runtime/`)
> 를 스캔해 `uniep_applist.conf`가 아닌 `.conf` 파일이 있으면 project(non-uniep)
> Application 목록으로 로드하는 것이 소스로 확인된다(`edge_runtime.cpp:96-114`,
> `is_contain_project`). 다만 이 저장소에는 그런 project conf의 실제 예시 파일이
> 없고(`resi_applist.conf`는 헤더에 매크로만 정의되어 있고 실체 파일이 없음),
> 원본 요구사항도 "12/19 Daily 버전부터 테스트 가능"·"중복으로 보임(검토 필요)"라고
> 스스로 표시하고 있다. **DUT에 실제로 배포된 project conf 파일명을 먼저 확인한
> 뒤** 아래 TODO를 채운다.

### 목적
<TODO — DUT에서 `ls /edge/app/files/edge_runtime/*.conf` 로 uniep_applist.conf 외
추가 conf 파일 존재 여부와 파일명을 먼저 확인한 뒤 작성>

### 사전 조건
<TODO>

### 절차
<TODO — 확인되면 TC03/TC11과 동일한 fork/Ready 로그 검증 방식을 project 앱 목록에
적용하는 형태가 될 것으로 예상>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC14 — 자동화 불가 항목 목록

이 항목들은 실물 LED 육안 확인, `/edge/devapp/bin`에 임의 앱 바이너리를 흉내 낸
빈 파일을 두는 등 사람의 판단이나 사전 준비물이 필요해 단일 DUT 셸 스크립트만으로는
완전히 무인 자동화하기 어렵다고 판단한 항목이다. 실행이 필요하면 QA가
`docs/tc_requirements/edge_runtime.md`의 원본 절차를 그대로 수동으로 따른다.

| 원본 Key | 항목 | 자동화 불가/제한 사유 |
|----------|------|------------------------|
| Key178 (TC-2) LED 상태 확인 | 녹색/적색 LED **육안** 확인 | TC04/TC05는 edge_runtime이 보내는 MQTT 요청 payload(color 필드)까지만 자동 검증한다. sys_manager가 이를 실제 GPIO/sysfs LED로 올바르게 구동하는지의 최종 육안 확인은 사람의 눈 또는 별도 카메라 리그가 필요 — 부분적으로 TC04-4/TC04 선택 항목(`get_led_status`)으로 완화했으나 100% 대체는 아님 |
| Key185 (TC-6) 1번째 스텝 | Configuration 기반 Project Application 정상 fork | 원본 자체가 "해당 Step은 TC와 중복으로 보임(검토 필요)"라고 명시, 실제로는 TC03/TC13과 동일 메커니즘. TC13 참고 |
| Key186 (TC-7) 1~2번째 스텝 | `journalctl -f` 로그 출력 시작, `docker ps`로 컨테이너 ID 확인 | 단순 환경 확인 커맨드로 판정 기준이 없는 사전 준비 단계 — 본 문서에서는 각 파괴적 TC의 절차 내 setup 단계로 흡수 |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID (reboot_info.txt의 BY 필드에도 그대로 기록됨) |
| `TARGET` | `edge_runtime` | MQTT 수신 대상 앱 ID |
| `DEVAPP_BIN_DIR` | `/edge/devapp/bin` | TC05/TC06에서 빈 파일로 앱 실행을 실패시키는 오버레이 경로 |
| `DEVAPP_FILES_DIR` | `/edge/devapp/files` | TC11에서 `uniep_applist.conf` 오버라이드를 배치하는 경로 |
| `REBOOT_INFO_FILE` | `/edge/log/reboot_info.txt` | 재부팅 요청/사유 기록 파일 (TC02/TC08) |
| `UNIEP_APPLIST` | `/edge/app/files/edge_runtime/uniep_applist.conf` | uniep Application 실행 순서 설정 (TC03/TC10/TC11) |

---

## 자동화 등급 (Automation Grade)

🟡 **A (일부 파괴적 시험/사전 백업-원복 의존)**

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | A (자동, 파괴적) | MQTT 요청 1회 + 로그 grep, 컨테이너 재시작 유발 |
| TC02 | A (자동, 파괴적) | TC01과 동일 트리거 재사용 가능 |
| TC03 | A (자동, 파괴적) | 로그 타임스탬프 파싱 스크립트 필요 |
| TC04 | A (자동, 파괴적) | LED 선택 항목만 sys_manager 교차 확인 |
| TC05 | B (파괴적 + 원복 필수) | 원복 누락 시 이후 모든 부팅 실패 위험 |
| TC06 | B (파괴적 + 원복 필수) | TC05와 동일 위험 |
| TC07 | A (자동) | 컨테이너 재시작 불필요, 로그 레벨 변경만 필요 |
| TC08 | A (자동, 파괴적) | kill -9 로 크래시 재현, 원복 불필요(대상 프로세스는 재부팅으로 자동 복구) |
| TC09 | A (자동, 파괴적) | TC04와 캡처 세션 공유 가능 |
| TC10 | A (자동, 비파괴적) | 파일 형식 검증만 |
| TC11 | B (파괴적 + 원복 필수) | conf 오버라이드 원복 누락 위험 |
| TC12 | A (자동, 비파괴적) | ps 기반 확인 |
| TC13 | Flag | 소스상 project conf 로딩 메커니즘은 확인했으나 DUT 상의 실제 project conf 파일 부재로 대상 미확정 — 개발자/QA 확인 후 내용 작성 |
| TC14 | 자동화 불가 | 목록만 제공, 실행은 QA 수동(육안 LED 확인 등) |

---

## 관련 문서

- `tc_edge_runtime_result.md` — 본 TC 실행 결과 보고서
- `tc_edge_runtime_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/edge_runtime.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx
  "Edge Runtime" 카테고리, Key 177/178/180/182/183/185/186, 7개 TC)
- `qcells/uniep/core/application/edge_runtime/` — edge_runtime 소스
  (`edge_runtime.cpp/hpp`, `watchdog.cpp/hpp`, `edge_app_info.cpp/hpp`,
  `edge_app_registry.cpp/hpp`, `uniep_applist_debug.conf`, `uniep_applist_release.conf`)
- `qcells/uniep/core/common/base_app/` — BaseApp(MQTT IPC 공통 기반) 소스
- `qcells/uniep/core/common/app_core/include/msg_ipc.hpp` — 전체 서비스/알림
  토픽 이름 정의(SERVICE_*/NOTI_*)
- `tools/dockerfile/deploy-ac_system_gen2/startup.sh` — `/edge/devapp` →
  `/edge/app` 오버라이드 복사 로직 (TC05/TC06/TC11의 근거)
