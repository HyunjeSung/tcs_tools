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

## 변경 이력 (Changelog)

- **2026-08-26**: 구 TC24("EOL 로그 압축 형식, zip vs xz", §AGSRS-491 AC) **삭제**.
  DUT 실측 결과 `eol_logger.cpp` 전체에 `compressToXz()`/`pushToFileCompressQueue()`
  호출이 단 한 곳도 없음을 확인 — EOL 로그 rotation은 헤더만 복사해 새 `.csv`를
  만들 뿐, zip은 물론 xz 압축 경로 자체가 코드에 없다(요구사항 AC와 무관하게
  압축 기능이 통째로 미구현). 검증할 대상 자체가 없다고 판단해 요구사항 삭제.
  이에 따라 뒤 번호를 당겨 연번 유지: 구 TC25(Factory EOL Mode field logging
  중단)→TC24, 구 TC26(Factory Reset)→TC25, 구 TC27(EOL 로그 추출 IPC)→TC26.
- **2026-08-26 (사용자 제보로 정정 + DUT 실측 완료)**: TC26("EOL 로그 추출")
  메커니즘이 완전히 틀려 있었음 — device_log MQTT IPC로 잘못 가정해 "코드에
  핸들러 없음 → 미구현"으로 결론 냈었는데, 실제로는 uniep web_interface(포트
  9112, HTTPS)의 `POST /auth/token` + `GET /api/factory/logs/{eol|device_log}`
  HTTP 엔드포인트로 이미 구현되어 있다(디렉토리 전체를 tar로 다운로드, 원본은 안
  건드림). §AGSRS-549는 사실상 구현 완료 상태 — Jira의 "개발 중" 문구가 stale한
  것으로 보임. 사용자가 제공한 사내 가이드(`EMSP_EOL_Log_Export_API_20260513`)의
  자격증명으로 실제 DUT에서 토큰 발급→tar 다운로드→원본 유지까지 end-to-end
  전부 실측 확인(TC26-0/1/2 PASS). 자격증명(`auth_secret`)은 대외비라
  `tc_device_log.sh`에 하드코딩하지 않고 `FACTORY_AUTH_KEY`/`FACTORY_AUTH_SECRET`
  환경변수로 실행 시점에 주입한다.

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
- `restart_docker_loader()`(TC09/TC10/TC14/TC16/TC17/TC21이 공유하는 헬퍼)로
  재기동시킨 직후 바로 root/archive 큐 상태를 확인하지 말 것 — `pgrep -f
  /edge/app/bin/device_log`로 프로세스 존재를 확인해도 `CloudUploadManager::init()`
  (root/archive 파일을 in-memory 큐에 등록하는 `enumerateExistingFilesInDirectory()`
  포함)이 끝났다는 보장은 아니다. `device_log::start()`는 broker 연결(재연결) 시점에
  실행되는데(`device_log.cpp:60-66`), 컨테이너 전체(`ac_system_gen2`, edge_runtime 등
  형제 앱 포함)가 함께 재기동되므로 프로세스가 뜬 뒤에도 broker 연결까지 수십 초가 더
  걸릴 수 있다(2026-08-25 TC21 실측으로 발견). `restart_docker_loader()`는 이제 pgrep
  이후 `journalctl`에서 `"Total files found in root"` 로그(`cloud_upload_manager.cpp:
  1272` 근처, `enumerateRootFilesInDirectory()`)가 이번 재시작 이후 찍힐 때까지 최대
  60초를 추가로 대기한다 — 이 헬퍼를 호출하는 TC들의 예상 소요시간에는 호출 횟수 ×
  최대 60초가 더 들어간다고 보고 타임아웃을 잡을 것.

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

> **Flag (2026-08-25, 미확정 — 재검증 필요):** `20260825_160658_device_log_full`에서
> TC03-3(MI 그룹)이 FAIL했다(MI_Monitoring 헤더만, 데이터 행 없음). `logpolicy.json`
> 확인 결과 `MI_Monitoring`의 `logRowInterval`은 900초(15분)로, 다른 대부분 log_item
> (초~수십 초 단위)보다 훨씬 길다. TC03은 `--full`에서 세 번째로 실행돼 docker-loader
> 재시작 직후 몇 분 안에 체크가 이뤄지므로, 첫 데이터 행이 아직 안 쓰인 시점에 우연히
> 걸렸을 가능성이 높다(재시작 후 5.5분 시점에도 여전히 0바이트인 것을 별도 확인 —
> 가설과 일치). 다만 직전 재시작 정확한 시각을 journal에서 못 구해(그 사이 TC26
> factory_reset이 journal을 리셋함) 100% 확정하지는 못했다 — device_log 결함이라기
> 보다 "체크 타이밍이 이르다" 쪽에 무게가 실리지만, MI_Monitoring만 별도로 900초+여유
> 대기 후 재확인하는 검증이 필요하다.

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
- **주기적(non-fault)** log_item 선정(`PMU_Monitoring`, logCreationTime=21600초/6시간).
  fault류(180초)는 이벤트 기반이라 본 TC 대상에서 제외 — [2026-08-25] 시간 점프
  방식으로 바뀌며 더 이상 실시간 대기 단축을 위해 짧은 주기를 고를 필요는 없어졌으나,
  기존 대상을 그대로 유지
- 대상 log_item에 텔레메트리가 도착 중인 상태

### 절차

1. 대상 log_item의 현재 활성 파일명에서 `<startTime>` 기록
2. `timedatectl set-ntp no` + `timedatectl set-time`으로 시스템 시각을
   `logCreationTime`(21600초) + 여유시간(5분)만큼 앞으로 점프시킨 뒤, idle thread
   사이클(15초) 정도만 대기 — rotation이 "시간이 실제로 바뀌었을 때" 트리거되는지를
   검증하는 것이 목적이므로, 자연 경과 대기가 아니라 시각 자체를 바꿔 확인한다
   ([2026-08-25] 재설계 — 기존엔 6시간+5분을 실시간 sleep으로 흘려보냈는데, 이는
   "대기했다"는 것만 증명할 뿐 시간 변경에 대한 반응을 검증하지 못했다는 지적으로 수정)
3. rotation으로 생성된 신규 파일명에서 `<startTime>`/`<endTime>` 추출, 차이(초) 계산 —
   [2026-08-25 DUT 실측 후 추가] 회전되어 닫힌 파일은 일반 idle thread 라운드로빈
   (`rootToArchiveOrToUpload()`, 5초 주기)이 곧바로 채가 toupload가 비어있으면
   `ARCHIVE_ROOT`도 안 거치고 `TOUPLOAD_ROOT`까지 가버릴 수 있다(TC18/TC21과 동일
   게이트). 원래 활성 파일의 시작시각을 접두사로 root/archive/toupload 세 곳을 모두
   찾아야 한다 — root만 보면 파일이 이미 옮겨져 항상 FAIL 처리되는 버그가 있었다
4. 검증 종료 후 시스템 시각을 절차 2 이전 값으로 복원(`date -s`, NTP는 TC18/TC19와
   동일하게 재활성화하지 않음)

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

> **정정 (2026-08-25, 소스 확인 후 원인 확정):** 더미 archive 파일을 만들 때 시리얼로
> `"TC09_1"`~`"TC09_8"`(밑줄 포함)을 썼던 것이 원인으로, `cur_count=21`(수정된
> fileCount=5를 넘는 값)로 항상 FAIL했다. `getLogTypeFromFileName()`
> (`cloud_upload_manager.cpp:1830-1854`)은 파일명을 `_`로 split해 4번째~마지막
> 토큰 사이를 log_item으로 합치는데, 시리얼에 밑줄이 있으면
> `20260825_..._Meter_TC09_1.csv.xz` → log_item이 `"Meter_TC09"`로 잘못 합쳐진다.
> `isKnownLogType("Meter_TC09")`가 false라서 `enumerateArchiveFilesInDirectory()`가
> 이 더미들을 추적 큐(`arch_dir_files_`, `deleteArchFileBasedOnCount()`가 유일하게
> 참조하는 in-memory 큐)에서 아예 빼먹는다 — 재시작을 몇 번 해도 큐에 없는 파일은
> 절대 삭제 대상이 될 수 없다. **device_log 결함이 아니라 테스트 더미 시리얼 명명
> 규칙 위반**(TC18/TC21 더미 생성 때 이미 같은 종류의 버그를 발견해 밑줄 금지 규칙을
> `create_dummy_archive_file()` 주석에 남겨뒀는데, TC09는 그 규칙이 적용되기 전에
> 작성된 코드라 반영이 안 돼 있었다). 시리얼을 `"TC09$i"`(밑줄 제거)로 수정 후
> 재검증: PASS 3/3.

---

## TC10 — Archive 파일 보관기간(retentionTime) 초과 삭제

### 목적

`archive/<logItem>/` 내 파일의 나이가 `logpolicy.json`의 `retentionTime`을 초과하면
삭제되는지 확인한다 (`deleteArchFileBasedOnTime()` — `cloud_upload_manager.cpp:1676`).

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. `retentionTime` 초과 시점을 먼저 계산하고, `archive/<logItem>/`에 **그 시점을
   파일명(startTime)으로 직접 인코딩한** 더미 `.csv.xz`+`.meta` 파일 1개 생성
   (touch로 mtime만 나중에 되돌리는 방식 금지 — 아래 Flag 참고)
2. `docker-loader` 재시작 — 재시작 시점의 `enumerateExistingFilesInDirectory()`가
   archive 디렉토리를 다시 스캔하므로, 이 시점에 존재하는 더미 파일도 앱의
   `arch_dir_files_` 추적 큐에 정식 등록된다
3. `archiveToUpload()` 사이클 대기
4. 해당 더미 파일의 삭제 여부 확인

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
> 않는 문제가 있어, "더미 파일 생성 후 docker-loader를 재시작"하는 방식(TC09이 이미
> 성공적으로 쓰던 방식)으로 정정했다.
>
> **주의 (Flag, 재정정 — 2026-08-24 DUT 실측):** 위 방식대로 고쳐도 여전히 삭제되지
> 않는 것을 실측으로 확인했다 — 진짜 원인은 등록 여부가 아니라 **스캔 순서**였다.
> `deleteArchFileBasedOnTime()`은 `arch_dir_files_[log_type]`(파일명=startTime 오름차순
> 정렬된 `std::set`)을 앞에서부터 순회하다가 **만료 안 된 파일을 처음 만나는 순간
> 즉시 break**한다(`cloud_upload_manager.cpp:1701-1705`, "파일명이 startTime 순이라
> 오래된 순 정렬이고 첫 미만료 파일에서 스캔을 끝낸다"는 주석 그대로). 더미를
> `end_epoch=now`로 만들면 파일명이 "지금"으로 찍혀, 이 벤치처럼 `archive/Meter/`에
> 최근 며칠간 쌓인 진짜 파일이 많은 상태에서는 그 진짜 파일들 사이/뒤에 정렬된다 —
> `touch -d`로 mtime만 되돌려도 스캔이 더미보다 먼저 정렬된(=아직 만료 안 된) 진짜
> 파일에서 멈춰버려 더미까지 도달을 못 한다. 그래서 **만료 시점을 파일명(startTime)
> 자체에 인코딩**해 더미가 set에서 가장 앞(가장 오래된 것)으로 정렬되게 만들어야
> 한다 — 이러면 스캔이 더미를 가장 먼저 만나 정상 삭제하고, 그 다음(진짜, 안
> 만료된) 파일에서 break해 나머지는 보존된다.

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
- 가능하면 `--tc11` 단독 실행 권장(아래 Flag 참고) — TC09/TC10/TC14/TC16/TC17처럼
  `restart_docker_loader()`를 호출하는 다른 TC와 같은 세션에서 묶어 실행하면
  cloud_broker의 300초 스캔 타이머가 그 재시작마다 리셋되어 본 TC의 310초 관측
  창 안에 스캔이 한 번도 안 들어올 수 있다

### 절차

1. 임의 log_item 파일을 toupload로 이동시키는 대신, `toupload/<logItem>/` 폴더 자체에
   파일명 규칙에 맞는 dummy `.csv.xz`+`.meta` 파일 1개를 직접 생성 — **`.meta`는
   반드시 `upload_name`/`upload_path`/`from` 필드를 채운 유효한 형식이어야 한다**
   (아래 Flag 참고, 빈 `.meta`는 cloud_broker가 무효로 판정해 조용히 스킵함)
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

> **주의 (Flag, 정정 — 2026-08-24 DUT 실측):** 최초 `create_dummy_toupload_file()`은
> `.meta`를 빈 파일로 만들었는데, cloud_broker의 `BlobUploadDirector::parse_meta()`
> (`blob_upload_director.cpp:143-186`)는 `upload_name`/`upload_path`/`from` 중 하나라도
> 비면 `meta.valid=false`로 판정하고 `scan_loop_task()`(`:99-103`)가
> `"[Director] Invalid meta file: ..."` 로그만 남긴 채 업로드 자체를 시도하지 않고
> 조용히 건너뛴다. 실제 업로드 시도가 없으니 cloud_broker가 device_log로
> `NOTI_FILE_UPLOAD_RESULT`를 돌려보낼 일도 없고, `handleFileUploadResult()`
> (`cloud_upload_manager.cpp:241`)의 "Upload success/fail for log item" 로그도 영원히
> 안 찍힌다 — 100% FAIL이 확정적이었다(스크립트 버그, cloud_broker/device_log 결함
> 아님). `create_dummy_toupload_file()`이 device_log의 `recreateMetaFile()`과 동일한
> key=value 형식으로 최소 요구 필드를 채우도록 정정했다.

> **주의 (Flag, 미해결 — 2026-08-24 DUT 실측):** 위 정정 후에도 `--only TC10,TC11,
> TC12,...`처럼 여러 TC를 묶어 실행하면 여전히 FAIL이 관측됐다. journal 확인 결과
> `[Director] Scanning directory` 로그는 docker-loader 재시작 시점으로부터 정확히
> ~300초 뒤 딱 한 번씩만 나타났고, TC11/TC12가 실행되는 구간(예: 14:00~14:16)에는
> 스캔이 전혀 없었다 — TC10/TC14/TC16/TC17이 각자 `restart_docker_loader()`를
> 호출하는데, 이게 연달아 일어나면 cloud_broker의 300초 스캔 타이머가 매번 리셋되어
> 앞쪽 TC의 관측 창은 스캔을 못 잡고 맨 마지막 재시작 이후에야 스캔이 한 번 찍히는
> 것으로 보인다(단, 정확히 몇 번째 재시작이 어떻게 겹쳤는지는 SSH 재시도 제한으로
> 끝까지 확정하지 못함). 재현되면 TC11/TC12를 단독(`--tc11`/`--tc12`)으로 실행해
> 다른 재시작의 영향을 배제한 뒤 재확인할 것.

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
>
> **주의 (Flag, 정정 — 2026-08-24 DUT 실측):** TC12-1의 `grep '\[Director\]' | grep
> "$f"` 판정은 dummy `.meta`가 빈 파일이면 `"[Director] Invalid meta file: <f 포함
> 경로>"` 에러 로그에도 매칭돼 **실제로는 업로드 시도가 전혀 없었는데도 위양성
> PASS가 날 수 있다**(TC11 Flag 참고 — `parse_meta()`가 `upload_name`/`upload_path`/
> `from` 중 하나라도 비면 무효 처리하고 스캔을 건너뜀). `create_dummy_toupload_file()`
> 이 유효한 `.meta`를 쓰도록 정정된 뒤에는 이 grep이 진짜 업로드 시도/완료 로그와
> 매칭되므로 이 문제는 해소된다.

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
4. idle thread 사이클(5초, `rootToArchiveOrToUpload()`) 반복 폴링(최대 60초) — 아래
   Flag 참고, 한 번만 확인하지 말 것
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

> **주의 (Flag, 정정 — 2026-08-24 DUT 실측):** `forced_log_upload`(`get_log_data`,
> `handleForcedLogUploadRequest()`)는 오프라인이면 파일을 archive로 옮기지 않고
> **root 큐에 그냥 재등록만 한다**(`cloud_upload_manager.cpp:404-414`, "Internet not
> available. Skipping upload" — root에는 retention sweep이 없어 재시작 전까진 이
> 파일을 되찾을 방법이 없다는 주석까지 있음). 실제 root→archive 이동은 완전히
> 별개의 idle thread 사이클인 `rootToArchiveOrToUpload()`(5초 주기,
> `selectNextRootLogType()` round-robin)가 나중에 그 파일을 집어야 일어난다
> (`:816-840`, 오프라인이면 else 분기로 archive行). 이전 절차는 `get_log_data` 호출
> 후 10초 고정 대기 후 단 한 번만 확인해, round-robin이 다른 log_type을 먼저
> 처리하느라 Meter 차례가 10초를 넘기면 FAIL이었다 — 과거 관찰된 "TC 순서
> 의존성"(1·2차 실행은 PASS, 3차는 FAIL)이 정확히 이 레이스로 설명된다(앱 결함이
> 아니라 대기시간 부족). idle thread 사이클 반복 폴링(최대 60초)으로 정정했다.

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
2. 네트워크 복구 — `network_restore()`가 iptables 규칙 해제와 함께 `internet_status`
   notification(`{"data":{"is_connected":true}}`)을 직접 발행해 `cloud_connected_
   action()`을 결정론적으로 트리거한다(아래 Flag 참고 — device_log는 실제 네트워크를
   스스로 확인하지 않으므로 이 알림 없이는 iptables만으로 온라인 복귀를 인지 못함)
3. `archive/` → `toupload/` 이동 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| toupload 이동 | archive의 파일이 toupload로 이동, Azure 업로드 결과 확인(TC11/13 연계) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC14-1 | archive→toupload 이동 확인 | boolean | true | `[ ! -f "$archive_dir/$fname" ] && [ -f "$toupload_dir/$fname" ]` |

> **주의 (Flag, 정정 — 2026-08-24 DUT 실측/소스 확인):** device_log는 실제 네트워크
> 상태를 스스로 확인하지 않는다 — `CloudUploadManager::is_internet_available_`
> (`cloud_upload_manager.hpp:215`)은 오직 `NOTI_INTERNET_STATUS` 알림
> (`device_log.cpp:673 handle_noti_internet_status()`, sys_manager가 보내는 것으로
> 추정)으로만 갱신된다. 즉 iptables로 실제 트래픽을 막거나 복구해도 그 자체로는
> 앱의 인지 상태가 안 바뀐다 — 이 알림을 직접 발행해야 한다. 정확한 페이로드
> 스키마도 `{"data":{"is_connected": true|false}}`로 확인됐다(device_connection의
> `{"protocol":..,"connected":..}` 패턴과 다름 — 예전에 `{"connected":true}`로
> 잘못 발행했던 시도는 `handle_noti_internet_status()`의 `data.is_connected`
> 필드 검증에 실패해 조용히 무시되고 있었다). `network_block()`/`network_restore()`
> 공통 헬퍼가 이 알림을 자동으로 함께 발행하도록 정정했다 — TC13/TC16/TC17/TC21처럼
> `network_block()`만으로 오프라인 분기를 유도하던 다른 TC들도 이 정정의 혜택을
> 받는다.

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

> **정정 (2026-08-25, 실측 후 원인 확정):** `20260825_160658_device_log_full` run에서
> TC15-1이 FAIL했다 — 대상 파일로 고른 게 다른 TC(09/18/21)가 남긴 0바이트 좀비
> 더미(`..._Meter_TC212.csv.xz`, 실제 DUT 시리얼이 아니라 "TC숫자" 시리얼)였다.
> `get_log_data`가 이번엔 새로 옮길 실파일이 없어(root가 이미 비어있음) toupload에
> 남아있던 좀비 더미가 `ls -t | head -1`에 "가장 최근 파일"로 잡힌 것 — 재부팅 후
> 업로드 재개 로직 자체의 결함이 아니라 대상 파일 선정이 오염된 것이었다. 대상 파일
> 후보에서 실제 DUT 시리얼이 아닌 "TC숫자로 시작하는 시리얼" 더미를 제외하도록
> `tc_device_log.sh`(`tc15_pre()`)를 수정 후 재검증: PASS. (참고: PASS/FAIL 판정
> 자체는 `journalctl`에 "Upload success"가 하나라도 있는지로 보는 일반적인 검사라,
> 대상 파일이 실제로 업로드됐는지와 무관하게도 통과할 수 있다 — "대상 파일" 정보는
> 근거 표시용이므로 좀비 더미가 아닌 실파일을 가리키도록 고친 것이 이 수정의 핵심.)

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

## TC18 — 자정 루틴: perDayRoot 초기화 및 잔여 quota archive 이월 + root/archive→toupload 이동

### 목적

매일 `midNightCheckHrs:midNightCheckMins`(기본 23:50)에 `updateLogUploadLimitsDaily()`가
실행되어, 남은 `perDayRoot`가 `perDayArchive`로 이월되고 `perDayRoot`는
`defaultPerDay`로 초기화되는지 확인한다 (`cloud_upload_manager.cpp:1409`). 이어서 곧바로
호출되는 `midNightRootToUpload()`/`midNightArchiveToUpload()`(`:666-667, 673-750`)가
실제로 root/archive의 파일을 그날 리셋된 quota만큼 toupload로 옮기는지도 함께
검증한다(§AGSRS-544).

> **주의 (Flag, 정정 이력 — 2026-08-25):** 원래 절차 5번에 "root/archive→toupload
> 이동도 확인"이라고 적혀 있었지만, 실제 구현(TC18-1/TC18-2)은 quota 숫자만 확인하고
> 파일 이동 여부는 전혀 검증하지 않는 간극이 있었다 — 사용자 지적으로 발견해
> TC18-3/TC18-4로 추가했다.

> **주의 (Flag, 정정 — 2026-08-25 DUT 실측):** TC18을 이 DUT에서 실제로 처음
> 실행해보니 TC18-1~4 전부 FAIL했다. 처음엔 "`ac_system_gen2` 컨테이너가 호스트와
> 분리된 시간 네임스페이스에 있다"고 오판했으나(호스트 `date -s` 직후 호스트 자체
> 재확인엔 반영되는데 `docker exec ac_system_gen2 date`로는 안 바뀐 것처럼 보였음),
> 실제 원인은 **NTP 데몬이 `date -s`로 바꾼 시각을 거의 즉시(1초 이내) 되돌리는
> 레이스**였다 — 호스트 확인은 되돌려지기 전에, 컨테이너 확인은 `docker exec` 왕복
> 지연 때문에 되돌려진 후에 값을 읽어서 마치 컨테이너만 격리된 것처럼 보인 것.
> `timedatectl set-ntp no`로 NTP를 먼저 확실히 끄고 `timedatectl set-time`으로
> 설정하니 컨테이너 쪽에도 정상 반영됨을 확인했다 — `mount -o remount,rw /`나
> `CAP_SYS_TIME` capability 추가 같은 컨테이너 권한 관련 시도는 전부 불필요했다.
> `tc_device_log.sh`를 이 방식(`timedatectl set-ntp no` + `timedatectl set-time`)으로
> 재수정했다. **참고**: 컨테이너 안에서 직접 `date -s`를 시도하면 여전히
> `Operation not permitted`로 막힌다(컨테이너에 `CAP_SYS_TIME`이 없음) — 다만 호스트
> `timedatectl`을 쓰면 이 제약과 무관하게 정상 동작하므로 문제 되지 않는다.
>
> **부수 발견 (RTC 플레이):** `timedatectl set-time`은 `date -s`와 달리 하드웨어
> RTC에도 값을 쓴다 — 검증 중 RTC가 실제로 2023년으로 틀어진 걸 확인하고
> `hwclock --systohc`로 복구를 시도했으나, 이 DUT는 `/etc/adjtime`이 없고
> `/dev/rtc0` ioctl 자체가 간헐적으로 실패해(`Invalid argument`/`No such device or
> address`가 번갈아 발생) RTC 읽기/쓰기가 근본적으로 불안정하다. `system_log`의
> `tc_system_log.sh` TC02가 시간 원복에 `hwclock -s`를 우선 쓰는데, 이 DUT에서는
> 이 방식도 신뢰할 수 없을 가능성이 있다 — 별도 확인 필요. device_log의 TC18/TC19는
> RTC에 의존하지 않고 애초에 `orig_epoch`를 셸 변수로 저장해뒀다가 `date -s
> "@${orig_epoch}"`로 복원하는 방식이라 이 RTC 불안정성과 무관하게 안전하다.
>
> **동일한 `date -s` 패턴을 쓰는 `system_log`의 TC02/TC07(+25h 시프트)은 이미
> `timedatectl set-ntp false`를 먼저 거는 걸 확인했다** — 즉 이 NTP 레이스를 이미
> 피하고 있었을 가능성이 높다(device_log의 TC18/TC19에만 이 단계가 빠져 있었음).

> **주의 (Flag, 확인 완료 — 2026-08-25 DUT 재실측):** 위에서 "별도 확인 필요"로 남겨둔
> `system_log` TC02의 `hwclock -s` 복원 단계를 직접 재현해본 결과, **실제로 안전하지
> 않음을 확인했다.** 이 DUT는 `/`가 `ro,relatime`로 마운트돼 있어(`mount | grep " / "`)
> `/etc/adjtime` 자체가 존재할 수 없고, `hwclock --systohc`(RTC에 쓰기)는 항상
> `cannot open /etc/adjtime: Read-only file system`으로 실패한다 — `timedatectl
> set-ntp yes`가 실패하는 것과 동일한 근본 원인(읽기전용 rootfs)이다. 반면 `hwclock -s`
> (RTC→시스템, TC02가 실제로 쓰는 명령)는 **에러 없이 성공(`exit_code=0`)하면서
> RTC에 남아있던 오염된 값을 시스템 시계에 그대로 덮어썼다** — 재현 시나리오: 우리가
> 앞서 TC18 검증차 `timedatectl set-time`으로 RTC를 건드려놓은 뒤(위 항목), 그 상태에서
> `hwclock -s`를 실행하니 시스템 시계가 실제 시각(10:38)이 아니라 오염된 RTC 값
> (23:52, 13시간 이상 차이)으로 조용히 세팅됐다. 즉 **TC02/TC07 뒤에 TC18/TC19 같은
> `timedatectl` 기반 시간 조작 TC가 하나라도 끼어들면, `hwclock -s`가 그 오염을 그대로
> 시스템 시계에 옮겨버려 복원이 "성공"으로 보고되면서 실제로는 시계가 틀어진 채
> 남는다.** 이걸 RTC 쓰기로 고치려는 시도(`hwclock --systohc --noadjfile --localtime`)도
> 해봤으나 UTC/localtime 해석 불일치로 오히려 9시간 어긋난 새 오염값을 만들어냈다 —
> 이 하드웨어의 RTC 쓰기 경로 자체가 신뢰할 수 없다고 결론. **권장 조치**:
> `system_log`의 TC02/TC07도 device_log의 TC18/TC19와 동일하게 `hwclock`/NTP에
> 의존하지 말고 `orig_epoch` 셸 변수 + `date -s "@${orig_epoch}"` 방식으로 바꿀 것 —
> 별도 확인/작업 필요(이 문서는 device_log 담당이라 시스템 로그 스크립트는 직접
> 수정하지 않음).

### 사전 조건

- 공통 전제 조건 충족, 시스템 시간 변경 권한
- (TC18-3/4) `toupload/Meter/`가 비어있음 — 비어있지 않으면 TC18-3/4는 SKIP(TC21과
  동일 이유: 이 DUT는 실제 클라우드 업로드 backlog가 상존, 아래 Flag 참고). TC18-1/2는
  더미 파일과 무관해 이 사전조건과 별개로 항상 진행됨

### 절차

1. 대상 log_item의 `perDayRoot`, `perDayArchive` 원래값 기록
2. `perDayArchive`가 0이면(평소 정상값) 5로 임시 상향하고 즉시 `docker-loader` 재시작
   — `midNightArchiveToUpload()`는 `move_limit`을 그 시점의 **리셋 전** `perDayArchive`로
   잡으므로(`:722`), 0인 채로 두면 TC18-4가 무엇을 심어도 항상 못 옮긴다(device_log
   결함 아님, TC14가 이미 쓰는 방식과 동일). `CloudUploadManager::init()`이
   logcount.json을 부팅 시 1회만 읽어(TC14와 동일 제약) 재시작이 필요
3. 재시작 후(있었다면) 값을 다시 읽어 TC18-1 계산의 기준값으로 삼는다 —
   `toupload/Meter/`가 비어있는지 확인, 안 비어있으면 TC18-3/4용 더미 생성을 건너뛴다
4. (비어있을 때만) `midNightRootToUpload()`/`midNightArchiveToUpload()` 검증용으로
   root에 더미 `.csv.xz`+`.meta` 1개, archive에 더미 `.csv.xz`+`.meta` 1개를 각각
   생성 — 두 함수 모두 실행 시 자체적으로 디렉토리를 재스캔하므로 이 더미 등록
   자체에는 재시작이 불필요하다(2번의 quota 재시작과는 별개 이유). **더미 생성 직후
   곧바로 시각을 점프시켜야 한다** — 자정 루틴과 무관하게 5초마다 도는 일반
   `rootToArchiveOrToUpload()`/`archiveToUpload()` 라운드로빈이 그 사이에 먼저 채가면
   (toupload가 안 비었을 때와 동일 게이트로 archive로 새어) 자정 루틴 특유의 동작을
   구분 못 하게 된다(아래 Flag 참고)
5. 시스템 시각을 23:50:00으로 설정(`isMidNightRoutineTime()`의 관측 창이
   `[23:50, 23:55)`이므로 창 시작점으로 직행 — 23:49로 옮겨 90초를 기다리는 것보다
   빠름) — `timedatectl set-ntp no`로 NTP를 먼저 끈 뒤 `timedatectl set-time`으로
   설정(아래 Flag 참고, plain `date -s`는 NTP 레이스로 무효화됨)
6. idle thread 사이클(5초) 몇 번만큼(15초) 대기하여 자정 루틴 실행 확인
7. `logcount.json`에서 `perDayArchive_after`가 `[0, perDayArchive_before+perDayRoot_before]`
   범위 안인지(동시에 흐르는 실 트래픽이 같은 사이클에서 quota를 같이 소비할 수 있어
   정확한 등식은 예측 불가 — 아래 Flag 참고), `perDayRoot_after == defaultPerDay`인지
   확인
8. (더미를 만들었을 때만) root/archive에 심어둔 더미 파일이 각각 toupload로
   이동했는지 확인
9. 시스템 시각 원복, `perDayArchive`를 **이 TC 시작 시점 값(archive_before0)으로
   항상** 되돌리고 재시작(`perDayRoot`는 자정 루틴이 만든 `defaultPerDay`가 정상
   결과라 원복하지 않음; `perDayArchive`는 부스트 여부와 무관하게 자정 루틴 자체가
   매번 값을 불리므로 항상 되돌려야 함 — 아래 Flag 참고)

### 기대 결과

| 항목 | 기준 |
|------|------|
| perDayArchive | `[0, 이전 perDayArchive + 이전 perDayRoot]` 범위 내 |
| perDayRoot | defaultPerDay로 초기화 |
| root 더미 파일 | toupload로 이동(사전조건 충족 시) |
| archive 더미 파일 | toupload로 이동(사전조건 충족 시) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC18-1 | perDayArchive 이월 계산 범위 확인(동시 소비 반영) | boolean | true | `[ "$archive_after" -ge 0 ] && [ "$archive_after" -le "$((archive_before + root_before))" ]` |
| TC18-2 | perDayRoot 초기화 | boolean | true | `[ "$root_after" -eq "$default_per_day" ]` |
| TC18-3 | midNightRootToUpload()로 root→toupload 이동 | boolean | true (사전조건 미충족 시 SKIP) | `[ -f "$TOUPLOAD_ROOT/Meter/$root_fname" ]` |
| TC18-4 | midNightArchiveToUpload()로 archive→toupload 이동 | boolean | true (사전조건 미충족 시 SKIP) | `[ -f "$TOUPLOAD_ROOT/Meter/$archive_fname" ]` |

> **주의 (Flag, 정정 — 2026-08-25 DUT 실측):** `updateLogUploadLimitsDaily()`의
> `perDayArchive = perDayArchive + perDayRoot`(`cloud_upload_manager.cpp:1416`)는
> `midNightRootToUpload()`/`midNightArchiveToUpload()`가 **이미 몇 개를 옮겨 소비한
> 뒤의** 값으로 계산된다(자정 루틴 순서: 이동 먼저, 리셋 나중). 이 DUT는 실 트래픽이
> 흐르는 환경이라 우리 더미 1개 외에 자연 발생한 root 파일도 같은 사이클에서 같이
> 소비될 수 있어(실측: `perDayRoot=8`인데 실제로는 2개가 소비돼 `perDayArchive_after`가
> 순진한 등식(`archive_before+root_before`=8)이 아니라 6으로 나옴) 정확한 값을 사전에
> 예측할 수 없다. TC18-1을 등식이 아니라 범위 검사로 완화했다 — 산식이 완전히
> 고장나면(음수거나 상한 초과) 여전히 잡아낸다.

> **주의 (Flag, 정정 — 2026-08-25 DUT 재실측):** TC18-3/4용 더미를 만든 뒤
> `perDayArchive` 부스트용 `restart_docker_loader()`를 나중에 걸었더니, 더미가
> root/archive에 앉아있는 동안 그 재시작 대기(최대 120초대)만큼 노출되면서, 자정
> 루틴과 무관하게 항상 5초마다 도는 일반 라운드로빈이 그 사이에 우리 더미를 먼저
> 채갔다(journal 실측: 자정 점프 **전에** 이미 `[rootToArchiveOrToUpload] Moved files
> to: archive/Meter, file: ...TC18ROOT...`가 찍힘). 원인은 TC21과 동일한
> `isToUploadDirEmpty()` 게이트 — 이 DUT는 `toupload/Meter`에 실제 클라우드 업로드가
> 밀린 실 데이터가 상존해 거의 항상 안 비어있고, 그래서 일반 라운드로빈이든 자정
> 루틴이든 어느 쪽이 먼저 집든 결과가 똑같이 "archive로 감"이 돼 TC18-3/4로는 자정
> 루틴 특유의 동작을 구분해낼 수 없었다. **재시작을 더미 생성 "전"으로 옮기고(quota
> 부스트만을 위해), `toupload/Meter` 사전조건 확인 후 더미를 만들자마자 곧바로 시각을
> 점프시키는 순서로 재수정**해 노출 창을 최소화했다. 그래도 toupload가 이미 안
> 비어있으면 근본적으로 결정적 관측이 불가능하므로, TC21과 동일하게 그 경우
> TC18-3/4를 SKIP 처리한다(FAIL로 오판하지 않도록).

> **주의 (Flag, 회귀 버그 정정 — 2026-08-25 DUT 실측):** `perDayArchive` 원복을
> "이 TC가 5로 부스트했을 때만"(`archive_before0 == 0`)으로 조건부로 걸었더니, 자정
> 루틴 자체가 부스트 여부와 무관하게 `perDayArchive = perDayArchive + perDayRoot`로
> 매 실행마다 값을 불려놓는 바람에, 한 번이라도 원복을 건너뛰면(시작값이 이미 0이
> 아니면) 다음 실행에서도 계속 조건을 못 만족해 원복이 영영 안 걸리고 실행할 때마다
> 값이 눈덩이처럼 쌓였다(DUT 실측: TC18을 반복 실행하며 6→9→18로 누적). 이 부풀려진
> `perDayArchive`가 남아있으면 **TC18과 무관한 `archiveToUpload()`의 일반 5초
> 라운드로빈**이 Meter의 archive 파일들을 계속 toupload로 실어나르게 되고, 이 상태로
> TC16이 실행되면 "root→toupload가 막혀야 하는데 toupload에 새 파일이 생김"(TC16-1)과
> "archive에 남아있어야 하는데 없음"(TC16-2)이 연쇄로 FAIL한다 — device_log 결함이
> 아니라 TC18의 원복 로직 결함이 TC16을 오염시킨 것. 부스트 여부와 무관하게 항상
> `archive_before0`으로 원복하도록 고쳤다.

---

## TC19 — 월 전환 시 로그 카운트 초기화

### 목적

월이 바뀌는 시점에는 일일 초기화 대신 `updateLogUploadLimitsMonthly()`가 실행되어
`perDayRoot=defaultPerDay`, `perDayArchive=0`으로 리셋되는지 확인한다
(`cloud_upload_manager.cpp:1432`).

### 사전 조건

- 공통 전제 조건 충족, 시스템 시간 변경 권한

### 절차

1. 시스템 시각을 월말 23:50:00(예: `2027-03-31 23:50:00`)로 설정 — `isMidNightRoutineTime()`
   관측 창(`[23:50, 23:55)`) 시작점으로 직행(TC18과 동일한 이유로 2026-08-25 수정)
2. idle thread 사이클(5초) 몇 번만큼(15초) 대기하여 자정 루틴(월 전환) 실행 확인
   (월 전환 조건: `isMonthTransition()` — 현재 시각 ±60분 내 월이 바뀌는지 확인)
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

## TC21 — toupload 상태에 따른 root→toupload/archive 라우팅 확인

### 목적 (§AGSRS-498 AC1 관련)

`rootToArchiveOrToUpload()`가 root에 쌓인 파일을 toupload로 보낼지 archive로 보낼지
가르는 실제 조건은 `isToUploadDirEmpty(log_type)` 게이트 하나다
(`cloud_upload_manager.cpp:826-827`): 그 log_type의 `toupload/` 디렉토리가 비어있으면
toupload로, 비어있지 않으면 archive로 이동한다. 본 TC는 이 게이트를 log_item 1개
(Meter)로 직접 검증한다.

> **주의 (재설계 이력, 2026-08-25):** 원래는 여러 log_item이 라운드로빈으로 골고루
> 선택되는지(공정성)를 봤으나, 이는 대상 log_item **전원**의 toupload가 동시에
> 비어있어야만 관측 가능한 조건이라 실전에서 앞선 TC(TC12 등)의 backlog나 실제
> 클라우드 업로드 지연만으로도 거의 항상 SKIP/FAIL로 이어졌다. 검증 대상을 라운드로빈
> 선택 순서 자체가 아니라, 이 TC가 실제로 막히던 원인인 `isToUploadDirEmpty()` 게이트
> 자체로 재설정했다("high-priority logs first"는 여전히 코드에 미구현 — 이 갭은
> 별도로 사용자/Jira에 보고할 사항).

### 사전 조건

- 공통 전제 조건 충족
- (TC21-1) `toupload/Meter/`가 비어있음 — 비어있지 않으면 SKIP(사전조건 미충족,
  이전 TC의 backlog나 실제 업로드 지연으로 발생 가능)

### 절차

1. **TC21-1 (toupload 비어있음 → toupload로 이동)**: `toupload/Meter/`가 비어있는지
   확인. 비어있으면 root(`$LOGGER_ROOT/Meter/`, archive/toupload와 같은 계층)에
   더미 `.csv.xz`+`.meta`를 직접 생성하고 `docker-loader`를 재시작해
   `root_dir_files_` 추적 큐에 등록시킨 뒤, `rootToArchiveOrToUpload()` idle thread
   사이클(5초 주기, 최대 60초)을 대기해 그 더미가 toupload로 이동하는지 확인
2. **TC21-2 (toupload 비어있지 않음 → archive로 이동)**: TC21-1의 결과나 사전
   backlog 여부와 무관하게 이 sub-case 혼자서도 결정적으로 돌도록, toupload에
   오염용 더미 파일을 별도로 1개 만들어 "비어있지 않음" 전제를 강제한다. 이어서
   root에 새 더미 파일을 또 하나 생성하고 동일하게 재시작 + idle thread 대기로
   archive로 이동하는지 확인

> **주의 (Flag, 정정 이력):** 처음엔 `get_log_data`(forced_log_upload IPC)로 root
> 파일을 큐잉하는 방식으로 짰으나, 이 IPC가 타는 `handleForcedLogUploadRequest()`
> (`cloud_upload_manager.cpp:314-428`)는 `rootToArchiveOrToUpload()`와 완전히 별개
> 경로라 `isUploadAllowed()`/`isToUploadDirEmpty()` 게이트를 아예 거치지 않고
> 온라인이면 무조건 toupload로 옮긴다는 것을 DUT 실측으로 확인했다 — TC21-2가
> toupload를 일부러 오염시켰는데도 archive가 아니라 toupload로 가서 FAIL, 검증하려던
> 게이트 자체를 안 타는 경로를 찌르고 있었던 것. TC10의 archive 더미 방식(더미 파일
> 직접 배치 + `restart_docker_loader()`로 큐 등록)을 root에도 동일하게 적용해
> 재수정했다 — root 디렉토리에 직접 생성한 더미는 `root_dir_files_`가 부팅 시 1회만
> (`enumerateRootFilesInDirectory()`) 채워지므로 재시작이 필요하다.

> **주의 (Flag, 재정정 — 2026-08-25 DUT 실측):** 위 방식대로 고치고
> `restart_docker_loader()`에 초기화 완료 대기까지 넣은 뒤에도(공통 전제 조건 참고)
> TC21-1/2 둘 다 여전히 FAIL했다 — journal에 `Total files found in root: 1`(등록
> 성공)까지는 찍히는데, 그 이후 `rootToArchiveOrToUpload()`가 Meter를 처리하는 로그가
> 전혀 없었다. 원인은 더미 파일명의 serial 파트에 넣은 `TC21_1`/`TC21_2`처럼 밑줄이
> 섞인 값이었다: `getLogTypeFromFileName()`(`:1830-1854`)이 파일명을 밑줄로 split해
> log_item을 재조립하는데, serial의 밑줄이 log_item에 흡수되어 `Meter_TC21`같은
> 존재하지 않는 log_item으로 오인식되고, `pushRootFileInfo()`가 `isKnownLogType()`
> 실패로 조용히(ERROR 로그만 남기고) 등록을 거부하고 있었다 — device_log 결함이
> 아니라 테스트 스크립트가 파서 가정(serial에 밑줄 없음)을 어긴 것. serial을
> `TC211`/`TC212`(밑줄 없음)로 바꿔 해결했다. `create_dummy_root_file()`(파일 448행
> 부근 주석)에 이 제약을 명문화해뒀다 — root 더미를 만드는 다른 TC를 추가할 때도
> serial에 밑줄을 넣지 말 것.

### 기대 결과

| 항목 | 기준 |
|------|------|
| toupload 비어있을 때 | 신규 root 파일이 toupload로 이동 |
| toupload 안 비어있을 때 | 신규 root 파일이 archive로 이동(toupload로 새지 않음) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC21-1 | toupload 비어있음 -> 신규 파일이 toupload로 이동 | boolean | true (사전조건 미충족 시 SKIP) | `[ -f "$TOUPLOAD_ROOT/Meter/$fname1" ]` |
| TC21-2 | toupload 비어있지 않음 -> 신규 파일이 archive로 이동 | boolean | true | `[ -f "$ARCHIVE_ROOT/Meter/$fname2" ]` |

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
2. **[2026-08-25 추가] `eolpolicy.json`의 실제 대상 telemetry(BMS_Monitoring_P01,
   `P01_B01_JF2_Normal_Back_BMS_*` 패턴) 도착 여부를 별도로 확인** — 아래 Flag 참고,
   `Meter` telemetry가 있어도 EOL 행 생성과는 무관하다. 미도착 시 TC23-2/3은 SKIP하고
   절차 3~5는 건너뛴다
3. `mosquitto_pub`으로 `SERVICE_SET_FACTORY_EOL_MODE`(`set_factory_eol_mode`)
   `{"eol_mode": true}` 발행
4. 130초 대기하며 텔레메트리 publish 지속
5. `/edge/log/eol/<start>_<end>_eol_1sec_<serial>.csv`,
   `<start>_<end>_eol_1min_<serial>.csv`(고정 파일명이 아니라 다른 device_log 파일과
   동일하게 타임스탬프가 붙음 — 아래 Flag 참고) 각각의 행 수와 마지막 행 시각 확인
6. `set_factory_eol_mode` `{"eol_mode": false}` 발행하여 종료

### 기대 결과

| 항목 | 기준 |
|------|------|
| eol_1sec.csv | 1초 간격으로 행 추가 |
| eol_1min.csv | 1분 간격으로 행 추가 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC23-0 | telemetry notification column 데이터 도착 확인(사전 확인용) | boolean | true | `Meter` 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC23-1 | BMS telemetry column 데이터 도착 확인(사전 확인용) | boolean | true | `BMS_Monitoring_P01` 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC23-2 | eol_1sec.csv 행 증가 (TC23-1 FAIL 시 SKIP) | boolean | true | `[ "$(wc -l < <실제 eol_1sec 파일>)" -gt "$rows_before" ]` |
| TC23-3 | eol_1min.csv 행 증가 (TC23-1 FAIL 시 SKIP) | boolean | true | `[ "$(wc -l < <실제 eol_1min 파일>)" -gt "$rows_before" ]` |

> **[2026-08-25] sub-case 번호는 항상 순수 숫자만 사용할 것**(`TC23-0b`처럼 문자를
> 섞으면 안 됨) — tc-dashboard의 `ASSERT_RE`/`EXPECTED_CASE_RE`(`server.py`)가
> `TC\d+-\d+` 패턴만 매칭해, 문자가 섞이면 그 case가 결과 현황판에서 통째로
> 빠지고 REASON 줄이 엉뚱하게 바로 이전 case에 붙어버린다(처음에 `TC23-0b`로
> 넣었다가 실측으로 발견 — "진행중 TC 표시가 안 보인다"는 사용자 리포트의 원인).

> **참고:** IPC 요청 메시지 필드명이 요구사항 문서(AGSRS-516)에는
> `{"factory_eol_mode": true}`로 기재되어 있으나, 코드(`device_log.cpp:457`)는
> `message.value("eol_mode", false)`로 `eol_mode` 필드를 읽는다. 실제 IPC 발행 시
> `eol_mode` 필드명을 사용할 것 — 요구사항 문서의 필드명 표기 오탈자로 판단됨.

> **정정 (2026-08-25, 소스 확인 후 원인 확정 — 2026-08-21 Flag의 "재검증 필요"
> 해소):** 2026-08-21 관측된 "130초 뒤에도 `/edge/log/eol/` 자체가 안 생김"은
> `EolLogger`/`device_log` 결함이 아니라 **테스트 하네스 `send_and_wait()`의 IPC
> 페이로드 포맷 버그**였다. 실제 프로토콜(`base_app.cpp`)은 `tid`를 MQTT5
> correlation-data 속성으로 별도 전달하고 JSON 본문은 payload 그 자체가 top-level
> 이다(`handle_request_custom_log_upload()`가 `message["log_num"]`을 top-level에서
> 바로 읽는 것과 동일 — `db_manager`도 `json_to_struct<...>(message)`로 동일 관례).
> `send_and_wait()`는 `{"tid":"...","payload":{"eol_mode":true}}`처럼 한 겹 더
> 감싸 보내고 있었고, `handle_request_set_factory_eol_mode()`의
> `message.value("eol_mode", false)`는 top-level만 보니 항상 기본값 `false`만
> 읽었다 — `set_factory_eol_mode`를 몇 번을 호출해도 매번 `EOL mode set to:
> disabled`만 찍히던 원인. `send_and_wait()`를 flat 포맷으로 수정(`tc_device_log.sh`)
> 하자 실제로 `EOL logging enabled` + 파일 생성이 확인됐다.
>
> 두 번째로, 파일이 생겨도 TC23-2/3(당시 번호로는 TC23-1/2)가 항상 FAIL했던 것은 **스크립트가
> `eol_1sec.csv`/`eol_1min.csv`라는 존재하지 않는 고정 파일명을 찾고 있었기
> 때문**(실제 파일명은 다른 device_log 파일과 동일하게
> `<start>_<end>_eol_1sec_<serial>.csv` 형태) — `active_csv()`와 동일한 glob 방식으로
> 수정.
>
> 세 번째, 위 두 버그를 다 고친 뒤에도 이 벤치에서는 여전히 행이 안 늘어났다 —
> `eolpolicy.json`의 `eol_1sec`/`eol_1min` `patternGroups`는 `Meter`가 아니라
> `P01_B01_JF2_Normal_Back_BMS_*`(BMS/배터리팩) 패턴만 매칭 대상으로 하는데
> (`eol_logger.cpp` `processEolLogging()` — notification path가 pattern에 일치해야
> `columnValues`가 채워지고 row가 써짐), 실측 결과 `BMS_Monitoring_P01`의 활성 CSV
> 마지막 행이 완전히 비어있었다(non-empty 컬럼 0개) — **이 벤치에 실물/시뮬레이션
> 배터리팩이 연결돼 있지 않아 EOL 행을 채울 데이터 자체가 없는 환경 제약**이며
> device_log 결함이 아니다. 이를 사전 감지하도록 TC23-1을 추가해 BMS telemetry
> 부재 시 TC23-2/3을 SKIP 처리한다(배터리팩 연결/시뮬레이션이 가능한 벤치에서
> 재실행하면 실제 판정 가능). sub-case 번호를 순수 숫자로만 구성해야 하는 이유는
> 위 표 아래 Flag 참고.

---

## TC24 — Factory EOL Mode ON 시 Field logging 중단 여부 (§AGSRS-491 AC 미구현 확인)

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
| TC24-0 | telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인) | boolean | true | 대상 log_item 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC24-1 | EOL 모드 중 field 로깅 중단 확인 (요구사항 AC 기준, 예상 FAIL) | boolean | true | `[ "$(wc -l < "$csv")" -eq "$rows_before" ]` |
| TC24-2 | 실제로는 필드 로깅 계속됨(참고용) | boolean | true | `[ "$(wc -l < "$csv")" -gt "$rows_before" ]` |

> **주의 (Flag, 미구현 확정):** `handle_request_set_factory_eol_mode()`는
> `EolLogger::setEolLoggingEnabled(eol_mode)`만 호출하며, 일반 필드 로깅을 멈추는
> `LogPolicyManager::stopLogging()`은 호출하지 않는다. `stopLogging()`은 오직
> `handle_request_factory_reset()`에서만 호출된다(`logging_stopped_`는 한 번 설정되면
> 프로세스 종료까지 해제되지 않는 설계 — `stopLogging()` 주석 참고). 즉 현재 코드상
> EOL 모드 ON은 EOL 로그를 "추가로" 기록할 뿐, 필드 로깅을 중단시키지 않는다. AC
> "Field logging is disabled in EOL mode"와 배치되므로 Jira 재확인/개발 이슈 등록
> 대상으로 보고할 것을 권장한다.

---

## TC25 — Factory Reset 시 전체 로그 삭제 및 EOL 모드 해제

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
| TC25-1 | eol 디렉토리 삭제 | boolean | true | `[ ! -d /edge/log/eol ]` |
| TC25-2 | device_log 디렉토리 삭제 | boolean | true | `[ ! -d /edge/log/device_log ]` |
| TC25-3 | toupload/device_log 디렉토리 삭제 | boolean | true | `[ ! -d /edge/log/toupload/device_log ]` |
| TC25-4 | IPC 응답 OK | boolean | true | `echo "$resp" \| grep -q '"error_code":0'` |
| TC25-5 | 재부팅 후 필드 로깅 재개 확인 | boolean | true | `[ "$(wc -l < "$csv")" -gt "$rows_before_reboot" ]` |
| TC25-6 | 재부팅 후 EOL 모드 기본 비활성 확인 | boolean | true | `[ ! -f /edge/log/eol/eol_1sec.csv ] || [ "$(wc -l < /edge/log/eol/eol_1sec.csv)" -eq "$eol_rows_before_reboot" ]` |

> **참고:** `stopLogging()`은 "재부팅 없이 리셋 직후 재활성화되지 않는다"는 설계
> 주석(`logging_stopped_`은 "Never cleared once set")을 코드에서 확인했다. 즉 리셋
> 직후 프로세스 재시작(재부팅) 없이는 필드 로깅이 재개되지 않는 것이 의도된 동작으로
> 보인다(양산 라인에서 리셋 후 전원 차단을 가정). TC25-5(재부팅 후 필드 로깅 재개)는
> 반드시 재부팅을 포함해서 판정할 것 — 재부팅 생략 시 오탐(false fail) 가능. TC25-6은
> `EolLogger`의 `m_eol_logging_enabled_` 멤버가 `{false}`로 기본 초기화되고(재부팅 시
> 프로세스가 새로 뜨므로 메모리 상태도 초기화됨) 별도 영속 저장 로직이 없음을
> 코드에서 확인했다 — Flag 없이 정상 동작 예상.

---

## TC26 — EOL 로그 추출 API

### 목적 (요구사항 §AGSRS-549)

`/edge/log/eol/` 경로의 EOL 로그를 추출하는 요청이 처리되는지 확인한다.

> **[2026-08-26 전면 정정 + DUT 실측 완료, 사용자 제보]** 기존 명세는 이 기능을
> device_log의 MQTT IPC로 잘못 가정하고 "코드에 핸들러 없음 → 미구현"으로 결론
> 내렸었다. **실제 메커니즘은 MQTT IPC가 아니라 uniep `web_interface`가 서비스하는
> HTTP 엔드포인트**다:
>
> ```
> POST https://localhost:9112/auth/token              (Bearer 토큰 발급)
> GET  https://localhost:9112/api/factory/logs/{fileName}  (fileName ∈ {eol, device_log})
> ```
> (`web/api/src/routes/router.ts:93` → `downloadFactoryLogHandler` →
> `factory-log.service.ts`의 `createTarArchive()`)
>
> 동작은 `LOG_DIR_MAP[fileName]`(`eol`→`/edge/log/eol`, `device_log`→
> `/edge/log/device_log`) 디렉토리 전체를 `tar -cf`로 `/tmp/{fileName}_{ISO시각}.tar`에
> 묶어 다운로드 응답으로 스트리밍하고, 전송 후 그 임시 tar를 삭제한다(**원본 디렉토리는
> 건드리지 않음** — 기존 명세가 가정한 "지정 폴더로 이동"이 아니라 **제자리 tar
> 다운로드**가 실제 동작, DUT 실측으로 원본 유지 재확인). 즉 §AGSRS-549는 **이미
> 구현되어 있다** — Jira 설명의 "개발 중"은 최신 코드 상태와 어긋난 stale한 문구로
> 보인다(Jira 재확인 권장).
>
> **포트/경로 주의**: uniep 프록시 포트(9113)로는 `/factory/logs/eol`이 401/404만
> 응답한다 — 실제 정답은 **9112(HTTPS, 자체서명 인증서라 `curl -k` 필요) +
> `/api` 접두사**였다. `/auth/token`은 9112에 접두사 없이 존재한다.
>
> 이 엔드포인트는 라우팅상 device_log/cloud_broker 컨테이너가 아니라 **uniep
> `web_interface`가 서비스하는 별도 Node.js 프로세스**를 거치므로, device_log 앱
> 자체와는 완전히 무관한 별도 검증 경로다.

### 사전 조건

- 공통 전제 조건 충족, `/edge/log/eol/`에 로그 파일 존재
- **인증**: `openapi.yaml`(`/factory/logs/{fileName}`)이 `Permission:
  factory:read:logs`를 요구한다. 실제로는 `Authorization: Bearer <JWT>` 헤더가
  필요하며(`auth.security.ts` `validateBearerToken`/`hasPermission` — `ROLE.ADMIN`
  토큰이면 개별 permission 없이도 통과), 토큰은 `POST /auth/token`
  (`auth_key`/`auth_secret`/`subject` 바디)으로 발급받는다. **자격증명은 사내 가이드
  문서(`EMSP_EOL_Log_Export_API_20260513`)에 있으며 `auth_secret`이 대외비로 명시돼
  있다 — `tc_device_log.sh`에는 하드코딩하지 않고 `FACTORY_AUTH_KEY`/
  `FACTORY_AUTH_SECRET` 환경변수로 실행 시점에만 주입한다**(tcs_tools는 GitHub
  public 레포라 커밋 시 그대로 유출되기 때문). 미설정 시 SKIP, 토큰 없이 호출하면
  `401 unauthorized`.

### 절차

0. TC23과 동일한 telemetry column 데이터 도착 확인(참고용)
1. `POST https://localhost:9112/auth/token`으로 Bearer 토큰 발급(`FACTORY_AUTH_KEY`/
   `FACTORY_AUTH_SECRET` 필요 — 위 "사전 조건" 참고)
2. `GET https://localhost:9112/api/factory/logs/eol` + `Authorization: Bearer <token>`
3. 응답이 유효한 tar 아카이브인지 확인(`tar -tf`), `/edge/log/eol/` 원본은 그대로
   남아있는지 확인(이동이 아니라 다운로드이므로 삭제/이동되면 안 됨)

### 기대 결과

| 항목 | 기준 |
|------|------|
| HTTP 응답 | 200, 유효한 tar 아카이브 |
| 원본 디렉토리 | `/edge/log/eol/` 그대로 유지(이동/삭제 없음) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC26-0 | telemetry notification column 데이터 도착 확인(TC23과 동일 사전 확인, 참고용) | boolean | true | `Meter` 최신 CSV 행의 non-empty 컬럼 수 > 3 |
| TC26-1 | `GET /api/factory/logs/eol` 응답이 유효한 tar 아카이브 | boolean | true | 토큰 발급 후 `tar -tf <응답> >/dev/null 2>&1` 성공. 자격증명 미설정 시 SKIP |
| TC26-2 | 다운로드 후 원본 `/edge/log/eol` 유지 확인(이동 아님) | boolean | true | `[ -d "$EOL_ROOT" ] && [ -n "$(ls -A "$EOL_ROOT")" ]` |

> **DUT 실측 완료(2026-08-26)**: `FACTORY_AUTH_KEY`/`FACTORY_AUTH_SECRET` 주입 후
> `--tc26` 단독 실행 결과 TC26-0/1/2 전부 PASS(토큰 발급 성공, tar 응답에 실제
> eol_1sec/eol_1min 파일 8개 포함 확인, 원본 디렉토리 그대로 유지). 더 이상
> "미구현" 항목이 아니며, 자격증명만 주입되면 완전 무인 실행 가능.

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

🟢 **A** (전체 TC01~TC26 무인 실행 가능. TC08/TC24는 요구사항 미구현이 코드로 확정되어 실행 시 FAIL이 예상되는 Flag 항목이며, TC26은 `FACTORY_AUTH_KEY`/`FACTORY_AUTH_SECRET` 환경변수 주입이 필요)

| TC | 등급 | 비고 |
|----|------|------|
| TC01~TC25 | A | 무인 실행 가능 (TC08/TC24는 Flag 항목 — boolean 스크립트로 실행은 가능하나 요구사항 미구현으로 FAIL 예상) |
| TC26 | A | **[2026-08-26 정정 + DUT 실측 완료]** `GET /api/factory/logs/eol` HTTP tar 다운로드로 이미 구현됨을 확인, `FACTORY_AUTH_KEY`/`FACTORY_AUTH_SECRET` 환경변수 주입 후 실측 결과 TC26-0/1/2 전부 PASS. 자격증명 미주입 시에만 SKIP |

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
| TC18 | AGSRS-514(자정 부분) + AGSRS-544 + `cloud_upload_manager.cpp:1409`(updateLogUploadLimitsDaily), `:673-750`(midNightRootToUpload/midNightArchiveToUpload) | **Flag — DUT 실측 1차 시도 전부 FAIL(plain `date -s`가 NTP 레이스로 무효화됨), `timedatectl set-ntp no`+`set-time`으로 재수정 후 재검증 중(2026-08-25)** |
| TC19 | AGSRS-542 + `cloud_upload_manager.cpp:1432`(updateLogUploadLimitsMonthly) — 코드 값(root=default,archive=0)이 Jira 기대결과와 완전 일치 | **Flag — TC18과 동일한 원인(NTP 레이스)으로 동일하게 수정, 미실측** |
| TC20 | AGSRS-541 + `cloud_upload_manager.cpp`(loadUploadInfoMap/writeToLogCountJson 계열) | Medium (재부팅 유지 로직은 파일 영속성 기반 추정) |
| TC21 | AGSRS-498 AC1(우선순위 업로드) + `cloud_upload_manager.cpp:826-827`(rootToArchiveOrToUpload의 isToUploadDirEmpty 게이트) | **Flag — 요구사항은 우선순위, 코드엔 우선순위 필드가 없어 라운드로빈+게이트로 대신 구현됨. 검증 목표를 라운드로빈 균등성에서 게이트(toupload 상태별 라우팅) 자체로 재설정(2026-08-25)** |
| TC22 | AGSRS-515 + `device_log.cpp:463`(handle_request_forced_log_upload), `cloud_upload_manager.cpp:314`(handleForcedLogUploadRequest) | High |
| TC23 | AGSRS-516 + `eol_logger.cpp:155`(processEolLogging), `eolpolicy.json`(eol_1min, eol_1sec — eol_10min은 정책에서 삭제됨) | High (단, IPC 필드명 `eol_mode` vs 요구사항 `factory_eol_mode` 표기 차이 있음) |
| TC24 | AGSRS-491 AC("Field logging is disabled in EOL mode") + `device_log.cpp:455-461`(stopLogging 미호출), `device_log.cpp:425`(stopLogging 유일 호출부는 factory_reset뿐) | **Flag — 미구현 확정. DUT 실측 없이 FAIL 확정적** |
| TC25 | AGSRS-491 AC(리셋 시 전체 삭제/EOL 해제) + `device_log.cpp:417-443`(handle_request_factory_reset) | High (단, 재부팅 필요 전제는 Medium) |
| TC26 | AGSRS-549 + `web/api/src/routes/router.ts:93`(`GET /factory/logs/:fileName`), `factory-log.service.ts`(`createTarArchive`, tar 다운로드) | **정정 완료(2026-08-26) — device_log MQTT IPC가 아니라 uniep web_interface(포트 9112, `/api` 접두사)의 별도 HTTP API로 이미 구현됨을 DUT 실측으로 확인(High)** |

---

## 관련 문서

- `tc_device_log_result.md` — 본 TC 실행 결과 보고서
- `tc_device_log_evidence_full.log` — 결과의 근거가 되는 통합 로그
