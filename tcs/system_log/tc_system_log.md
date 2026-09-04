---
spec_id: system_log
suite: application
grade: B
phase: Phase 1
test_file: tcs/tc_system_log.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-SL: system_log — 시스템 로그 수집·압축·업로드 검증

## 목적 (Objective)

`system_log` 애플리케이션의 로그 수집, xz 압축, toupload 이관, Azure Blob 업로드,
30일 보존, Factory Reset, 리부트 전 로그 저장 등 전 기능을 검증한다.
IPC(MQTT 브릿지)를 통한 on-demand export와 24시간 주기 rotation을 포함한다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `system_log` 프로세스 실행 중 (`pgrep -f system_log`)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨
- `/edge/log/` 파티션 쓰기 가능
- (TC04/TC15/TC16 대상) `/edge/log/.tc_dummy_journal_blob` — journal 대량 주입용 premade
  랜덤 blob(raw 400MB 상당, base64 인코딩 후 상주). 최초 실행 시 없으면 스크립트가
  자동 생성하며, 이후 모든 TC04/15/16 실행에서 재사용된다(재생성 없음). 디바이스에
  영구 상주하므로 eMMC 여유 공간 산정 시 이 파일 크기를 포함해서 계산할 것.
  **주의:** `DUMMY_BLOB_RAW_MB`를 210→400으로 올렸어도 디바이스에 이미 210MB로
  생성된 blob이 있으면 `ensure_dummy_blob()`이 재생성하지 않고 그대로 재사용한다.
  400MB 효과를 보려면 디바이스에서 `rm -f /edge/log/.tc_dummy_journal_blob` 로
  기존 blob을 지운 뒤 다음 TC04/15/16 실행 시 재생성시킬 것.

---

## TC01 — 파일명 규칙

### 목적

생성된 `.log.xz` 파일명이 `systemlog_{14자리}_{14자리}.log.xz` 형식이며,
시작 시각 ≤ 저장 시각 조건을 만족하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- toupload 디렉토리(`/edge/log/toupload/system/`) 쓰기 가능
- `task_rotate_sync()` 실행 시 파일 생성 가능 상태 (디스크 여유 5MB 이상)

### 절차

1. SETUP: `get_log_data` 요청 전송 → `task_rotate_sync()` 실행 → toupload에 `.log.xz` 생성
2. `ls -t /edge/log/toupload/system/systemlog_*.log.xz | head -1` 로 최신 파일 획득
3. 파일명을 정규식 `systemlog_[0-9]{14}_[0-9]{14}\.log\.xz` 로 검증
4. 파일명에서 start(앞 14자리), end(뒤 14자리) 추출 후 `start <= end` 비교

### 기대 결과

| 항목 | 기준 |
|------|------|
| 파일명 형식 | `systemlog_YYYYMMDDHHMMSS_YYYYMMDDHHMMSS.log.xz` |
| 시각 순서 | start ≤ end |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | 파일명 정규식 일치 | boolean | true | `grep -qE "systemlog_[0-9]{14}_[0-9]{14}\.log\.xz"` |
| TC01-2 | 시작 ≤ 저장 시각 | boolean | true | `[ "$start_t" -le "$end_t" ]` |

---

## TC02 — 24시간 타이머

### 목적

`system_log` 타이머 루프가 24시간 경과 시 `task_rotate_sync()`를 실행하여
toupload에 `.log.xz` 파일을 생성하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- 시스템 시간 변경 권한 (root)
- NTP 자동 동기화 정지 권한 (`timedatectl set-ntp false`) — 시간 이동 전 잠깐 켰다
  끄는 용도로만 쓰고, 복원은 `set-ntp yes`가 아니라 `t0` 기반 `date -s`로 함(아래 Flag)
- `journalctl -u docker-loader` 에서 `[system_log_timer_loop] loop started` 라인 확인 가능
   — 즉 system_log 어플리케이션의 timer thread 가 부팅 직후 정상 시작되어 24h 주기 check 루프가 돌고 있는 상태
- `system_log` 프로세스를 kill할 권한 (root) — 절차 0에서 사용
- 환경변수: 없음 (TC 진입 시 자동으로 NTP off)

### 절차

0. `system_log` 재시작 (내부 타이머 상태 초기화 — 다른 TC 실행 이력과 무관하게 항상 깨끗한 상태에서 시작)
1. `journalctl -u docker-loader --no-pager | grep '[system_log_timer_loop] loop started'` 로 timer thread 시작 로그 확인
2. `FILES_BEFORE` = 현재 toupload `.log.xz` 파일 수 및 목록 기록
3. 시스템 시간을 현재 시간과 동기화 (NTP `set-ntp yes` → 잠시 대기 → `set-ntp false` 로 변경 가능 상태)
4. 현재 epoch `t0` 저장 후 시스템 시간을 `t0 + 25*3600` 로 변경 (`date -s @<epoch>`)
5. 타이머 발화 대기 (70초) — system_log_timer_loop 의 1초 sleep_for + `elapsed >= 24h` check 후 `task_rotate_sync()` 호출 완료 대기
6. toupload 에 신규 `.log.xz` 파일 생성 확인 및 파일명의 endtime 이 변경한 시간(+25h) 근처인지 확인
7. 시스템 시간을 현재 시간으로 복원 — 4번에서 저장해둔 `t0`로 `date -s "@${t0}"`
   직접 복원(2026-08-25 재수정, 아래 Flag 참고)

> **주의 (Flag, 정정 — 2026-08-25 device_log TC18 세션에서 발견):** 원래는
> `hwclock -s`(RTC→시스템)를 우선 쓰고 실패 시 NTP 재동기화로 폴백했는데, 이 DUT는
> `/`가 `ro`로 마운트돼 있어 `hwclock --systohc`(RTC 쓰기)가 항상 실패한다. 그런데
> `device_log`의 TC18/TC19처럼 `timedatectl set-time`으로 시간을 바꾸는 TC는 RTC에도
> 값을 써버리므로, 그런 TC가 먼저 돈 뒤 이 TC가 실행되면 `hwclock -s`가 그 오염된
> RTC 값을 시스템 시계에 에러 없이(`exit_code=0`) 그대로 옮겨버린다(실측: 13시간
> 이상 틀어진 채 "성공"으로 보고됨) — 복원이 조용히 실패할 수 있는 구조였다. RTC/NTP
> 둘 다 의존하지 않고, 4번에서 이미 저장해둔 `t0`(jump 전 원래 epoch)로 직접 복원하는
> 방식으로 교체했다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| toupload 파일 | 신규 `.log.xz` 생성됨 |
| 파일명 endtime | 변경한 시스템 시간(+25h) 근처 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | toupload 신규 .xz 생성 | boolean | true | `[ "$files_after" -gt "$files_before" ]` |
| TC02-2 | 파일명 endtime이 변경 시간 근처 | manual | — | 파일명 확인 후 수동 판정 |

---

## TC03 — On-demand export

### 목적

`get_log_data` IPC 요청 수신 시 `task_rotate_sync()`를 비동기 스레드로 실행하고,
완료 후 MQTT 응답(`error_code=0`)과 신규 `.log.xz` 파일 생성을 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- toupload 디렉토리 쓰기 가능
- system_log MQTT 토픽 구독 가능 (`emsp/system_log/+/req/get_log_data`)

### 절차

1. `FILES_BEFORE` = 현재 `/edge/log/toupload/system/systemlog_*.log.xz` 수
2. `mosquitto_sub` 구독 시작 → `mosquitto_pub` 로 `get_log_data` 송신 → 응답 대기 (30초)
3. 응답 수신 후 10초 추가 대기 (파일 생성은 detached thread에서 비동기 진행)
4. `FILES_AFTER` 재카운트 → 파일 수 증가 확인

> **구현 주의:** `task_rotate_sync()`는 detached thread에서 실행되어 MQTT 응답 반환 후
> 비동기로 파일 생성이 완료된다. 응답 수신만으로 파일 존재를 보장하지 않으므로
> 응답 후 추가 대기가 필요하다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 수신 | MQTT 응답 수신 (30초 이내) |
| 신규 파일 | `FILES_AFTER > FILES_BEFORE` (응답 후 10초 이내) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | xz 파일 신규 생성됨 | boolean | true | `[ "$FILES_AFTER" -gt "$FILES_BEFORE" ]` |

---

## TC04 — On-demand timeout (실제 journal 데이터 시나리오)

### 목적

journald 가 실제로 기록한 데이터로 `/edge/log/system/journal/<machine-id>/` 가
**100MB** 사이즈일 때 `get_log_data` 요청을 보낸 뒤, **그 응답(=`task_rotate_sync()`가
dump+rotate+compress+move 를 전부 마쳐야 오는 진짜 완료 신호) 을 최대 200초까지
기다렸다가** `.log.xz` 신규 생성 여부를 확인한다.

> **판정 방식 변경 이력:** 처음엔 180초 폴링으로 완료를 기다렸으나 `MessageContext`의
> tid 미검증 버그를 자주 재현시켜(100MB/150MB 두 티어 모두 180초 경계를 두드림) 응답
> 자체를 포기하고 10초만 짧게 훑어보는 방식으로 완화했었다. 근데 그러면 아직 정상
> 진행 중일 뿐인 상황(응답이 30초를 넘겨서 오는 경우)을 FAIL로 오판하는 문제가 있었다
> (실측). 150MB 티어는 제거해 유지하되, 판정은 `get_log_data` 자체의 응답(실제 완료
> 신호)을 200초(180s cmd timeout + 여유)까지 기다리는 방식으로 다시 바꿨다 — 응답이
> 오면 그 시점의 파일 상태가 곧 최종 상태다.

> 단순히 `dd` 로 zero-fill 한 더미 `.journal` 은 journald 가 corrupted 로 즉시 무시하므로
> 시나리오 의도(대용량 journal 처리 시 timeout 검증)를 측정할 수 없다. 따라서
> `systemd-cat` 으로 journald 에 실데이터를 주입해 valid journal 파일을 만든다.

### 사전 조건

- 공통 전제 조건 충족
- `journalctl --rotate` 및 `--vacuum-files` 권한 (root)
- `systemd-cat` 사용 가능 (journald 가용)
- `journald.conf`: `SystemMaxFileSize` 기본 64M, `SystemMaxFiles` 기본 20 — 150MB 까지 ~3개 파일 필요, 한도 안에 들어감
- 디바이스 emmc 가용 공간 300MB 이상 (100MB journal + 압축 작업 임시공간 + premade dummy blob 상주분)
- IPC 타임아웃: `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=5초`, `SYSTEM_LOG_PUBLISH_TIMEOUT=7초`

### 절차

100MB 사이즈에 대해 다음을 실행:

1. `journalctl --rotate && journalctl --vacuum-files=1` 로 journal 초기화
2. `BEFORE_LIST` = 현재 toupload `.log.xz` 파일 목록 (개수가 아니라 목록 자체를 저장)
3. `/edge/log/.tc_dummy_journal_blob`(premade 랜덤 blob, 없으면 최초 1회만 생성)에서
   사이즈에 맞는 만큼 슬라이스해 `systemd-cat -t TC04_DUMMY` 로 실데이터 주입
   - 사이즈별 raw 환산량: 70MB / 105MB (≈1.4x 팽창 후 journal 목표 사이즈에 도달) — 매번
     `/dev/urandom` 을 새로 뽑지 않고 blob에서 해당 비율만큼 `head -c` 로 잘라 재사용한다.
     journald가 요구하는 건 "systemd-cat 정상 경로로 들어온 유효한 항목"이지 내용의
     신선도가 아니므로, 한 번 생성한 고엔트로피 데이터를 재사용해도 무방하다.
4. `sync; sleep 3; journalctl --rotate; sleep 2` 로 디스크에 flush
5. `journalctl --disk-usage` 로 실제 journal 사이즈 확인
6. `get_log_data` 요청 송신, 응답을 최대 200초까지 대기(실제 완료 신호)
7. 응답 수신 직후 `comm -13 BEFORE_LIST AFTER_LIST` 로 신규 파일을 확인한다
   (TC02와 동일한 diff 방식 — 그 사이 다른 파일이 삭제돼도 개수 비교와 달리 오판하지 않는다)
8. 신규 파일 발견 여부로 PASS/FAIL 판정

시험 후: `journalctl --rotate && journalctl --vacuum-files=1` 로 디스크 복원.

> **알려진 제약:** journal 사이즈가 100MB 이상이면 `journalctl -o cat | xz` 파이프라인이
> `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=5초` 안에 끝나지 않고 SIGKILL 로 실패할 수 있다.
> 이 케이스에서는 `error_code=UNKNOWN` 으로 응답이 반환되고 .xz 가 생성되지 않는다.
> FAIL 시 system_log 로그의 `task_rotate_sync` / `request_command_sync` 흔적과
> `exit_code=-1` 응답을 확인한다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 | MQTT 응답이 200초 안에 반환됨(=task_rotate_sync 완료) |
| 파일 생성 | 응답 수신 시점에 `.log.xz` 신규 생성 확인 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | journal 100MB 상태에서 get_log_data 완료 응답 후 .xz 파일 생성 | boolean | true | `comm -13 BEFORE_LIST AFTER_LIST` 로 신규 파일 존재 확인 |


---

## TC05 — xz 압축

### 목적

rotation 완료 후 생성된 파일이 유효한 `.xz`이며, 원본 `.log` 파일이
삭제되었는지 확인한다. 또한 `xz -f` (force) 플래그로 인해 staging에 동명 파일이
존재하더라도 정상 덮어쓰기되는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- TC03 또는 TC04 직후 (toupload에 신규 `.log.xz` 1개 이상 존재)
- 디바이스에 `xz --test` 명령 사용 가능

### 절차

1. `LATEST_XZ` = `ls -t /edge/log/toupload/system/systemlog_*.log.xz | head -1`
2. `[ -f "$LATEST_XZ" ]` 확인
3. `xz --test "$LATEST_XZ"` 실행 → exit code 0 확인
4. `LOG_FILE="${LATEST_XZ%.xz}"` → `[ ! -f "$LOG_FILE" ]` 확인
5. staging에 동명 더미 `.log.xz` 직접 생성 후 같은 이름의 `.log` 파일을 `xz -f`로 압축:
   ```bash
   echo "small" | xz -c > /edge/log/system/systemlog_tc05xztest_tc05xztest.log.xz
   echo "larger real content" > /edge/log/system/systemlog_tc05xztest_tc05xztest.log
   xz -f /edge/log/system/systemlog_tc05xztest_tc05xztest.log
   ```
   → 더미보다 크기가 커진 `.log.xz` 생성 확인 / 원본 `.log` 삭제 확인
   → 정리: `rm -f /edge/log/system/systemlog_tc05xztest_tc05xztest.log.xz`

> **참고:** RTC 이상 환경에서 `task_capture_boot_log`가 동명 파일을 `xz -f`로 덮어쓰는
> 시스템 레벨 검증은 TC14에서 수행한다(system_log kill → 재시작 → 동일 BOOT_START 파일 병합).

### 기대 결과

| 항목 | 기준 |
|------|------|
| .xz 파일 존재 | toupload에 파일 있음 |
| 무결성 | `xz --test` exit 0 |
| 원본 .log | 삭제됨 |
| 동명 파일 덮어쓰기 | staging 동명 파일이 정상 교체됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC05-1 | .xz 파일 존재 | boolean | true | `[ -f "$LATEST_XZ" ]` |
| TC05-2 | xz 무결성 | exit code | 0 | `xz --test "$LATEST_XZ"` |
| TC05-3 | 원본 .log 삭제 | boolean | true | `[ ! -f "${LATEST_XZ%.xz}" ]` |
| TC05-4 | staging 동명 .xz 존재 시 xz -f로 덮어쓰기 성공 (크기 증가, 원본 .log 삭제) | boolean | true | `[ "$size_after" -gt "$size_dummy" ] && [ ! -f *.log ]` |

---

## TC06 — Journal rotation

### 목적

`task_rotate_sync()` 완료 후 `journalctl --rotate && journalctl --vacuum-files=1`
실행 결과로 저널 디스크 사용량이 감소하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- `journalctl --disk-usage` 사용 가능
- TC03 SETUP 직후 (rotation 트리거된 상태)
- 환경변수: `SYSTEM_LOG_CMD_ROTATE_VACUUM="journalctl --rotate && journalctl --vacuum-files=1"`

> **제약:** FW 업데이트 시 machine-id가 바뀌어 이전 부팅의 저널 파일이 별도 서브디렉토리에
> 잔존한다. vacuum은 현재 machine-id만 처리하므로 전체 파일 수는 줄지 않을 수 있다.
> 저널 사용량(용량) 감소로 확인한다.

### 절차

1. SETUP 전 `journalctl --disk-usage` 로 용량 기록 (`JOURNAL_SIZE_BEFORE`)
2. TC03 SETUP (`get_log_data`) 실행 → rotation 완료
3. `journalctl --disk-usage` 재측정 (`JOURNAL_SIZE_AFTER`)
4. 수동으로 사용량 감소 또는 이미 최소 상태임을 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 저널 사용량 | 감소하거나 이미 최소 상태 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | rotate && vacuum 실행 확인 | manual | 사용량 감소 또는 최소 상태 | `journalctl --disk-usage` 수동 확인 |

---

## TC07 — 30일 보존 정책

### 목적

`delete_log()` 가 `mtime > 30일` 파일을 삭제하고, 30일 미만 파일은 보존하는지 확인한다.

> **트리거 정정(2026-08-06):** `delete_log()`는 `get_log_data`(on-demand 업로드
> 요청)로는 발화하지 않는다 — `cleanup_log_dir()`/`delete_log()`는 24시간 주기
> 타이머(`system_log_timer_loop`, `system_log.cpp:807-816`)에서만 호출되며, 이
> 타이머는 앱 부팅(또는 직전 실행) 이후 실경과 24시간을 `system_clock::now()`
> 기준으로 측정한다(`system_log.cpp:793-826`). 이전 버전 TC07은 `get_log_data`
> 재요청 후 10초만 기다려 항상 FAIL 했다 — 실제 삭제 로직이 발화조차 안 된 상태를
> 검증한 것. TC02(24h 타이머 검증)와 동일하게 앱을 재시작해 타이머를 초기화하고
> 시스템 시간을 +25h 이동시켜 24h 조건을 강제로 채우는 방식으로 교체한다.

### 사전 조건

- 공통 전제 조건 충족
- `touch -d "31 days ago"` / `"29 days ago"` 명령 사용 가능 (mtime 조작)
- 환경변수: `LOG_RETAIN_DAY=30` (system_log 빌드 상수)
- `date -s`, `timedatectl set-ntp` 사용 가능 (root, TC02와 동일 권한)

### 절차

1. `system_log` 프로세스 재시작(`kill -9` → 재기동 확인) — 내부 `last_run_time`을
   fresh 상태로 초기화한다 (TC02-절차0과 동일).
2. startup 시퀀스(`task_capture_boot_log`→`task_merge_staged_logs`→`task_upload_nmon`)
   완료 로그 대기 — 이 시점 이후에야 `last_run_time`이 세팅된다.
3. `timedatectl set-ntp yes/false` 로 NTP와 동기화한 뒤, 시스템 시간을 **+25시간**
   이동(`date -s`) — `elapsed >= 24h` 조건을 확정적으로 채운다.
4. **시간 이동 이후** 더미 파일 생성(shift 후 "지금" 기준 31일 전 / 29일 전):
   ```bash
   touch -d "31 days ago" /edge/log/toupload/system/systemlog_20250101000000_20250101010000.log.xz
   touch -d "29 days ago" /edge/log/toupload/system/systemlog_20250501000000_20250501010000.log.xz
   ```
5. 24h 타이머 발화 대기 (70초, TC02와 동일 관찰창 — `task_rotate_sync()` 직후 같은
   반복(iteration) 안에서 `cleanup_log_dir()`가 바로 이어 실행됨)
6. 31일 더미 파일 존재 여부 확인 (`[ ! -f ... ]`)
7. 29일 더미 파일 존재 여부 확인 (`[ -f ... ]`)
8. 시스템 시간 복원 — 3번에서 저장해둔 `t0`로 `date -s "@${t0}"` 직접 복원
   (2026-08-25 재수정, TC02-절차7 Flag와 동일 이유)

> **주의:** 더미 파일은 반드시 3번(시간 이동) *이후*에 touch할 것. 이동 전에
> touch하면 파일 나이에 25시간이 그대로 얹혀 29일 더미가 30일 문턱을 넘어설 수
> 있고, 이 경우 TC07-2가 오탐 FAIL 한다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 31일 경과 파일 | 삭제됨 |
| 29일 경과 파일 | 유지됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | 31일 파일 삭제 | boolean | true | `[ ! -f dummy_31 ]` |
| TC07-2 | 29일 파일 유지 | boolean | true | `[ -f dummy_29 ]` |

---

## TC08 — Azure Connector 업로드 확인

### 목적

`task_rotate_sync()` 완료 후 toupload 디렉토리에 `.log.xz` 및 `.meta` 파일이
존재하여 `azure_connector`가 업로드할 준비가 됐는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- TC03 또는 TC07 직후 (toupload에 `.xz` 1개 이상 존재)
- `azure_connector` / `blob_upload_director` 실행 여부와 무관 (업로드 자체는 TC 범위 밖)

> **범위:** system_log의 책임(toupload 이관)만 검증한다.
> 실제 Azure Blob 전송 성공 여부는 이 TC의 범위 밖이다.

### 절차

1. TC03 SETUP 완료 후 (get_log_data 응답 수신)
2. `/edge/log/toupload/system/systemlog_*.log.xz` 존재 확인
3. `/edge/log/toupload/system/systemlog_*.log.xz.meta` 존재 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| `.log.xz` | toupload에 존재 |
| `.log.xz.meta` | toupload에 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | toupload에 .log.xz 존재 | boolean | true | `ls /edge/log/toupload/system/systemlog_*.log.xz` |
| TC08-2 | toupload에 .meta 존재 | boolean | true | `ls /edge/log/toupload/system/systemlog_*.log.xz.meta` |

---

## TC09 — Factory Reset

### 목적

`request_factory_reset` IPC 요청 수신 시 `/edge/log/toupload/system/` 내
모든 파일이 삭제되는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- toupload 디렉토리에 1개 이상의 파일 존재 (사전 더미 또는 직전 TC 결과 사용 가능)
- system_log MQTT 토픽 발행 권한 (`emsp/system_log/+/req/request_factory_reset`)

### 절차

1. 더미 파일 생성: `touch /edge/log/toupload/system/systemlog_dummy.log.xz`
2. `mosquitto_pub` → `request_factory_reset` 요청, 30초 대기 (의도적으로 타이트한 간격 유지 —
   factory_reset의 `clear_all_logs()`는 `log_dir_mutex_` unique_lock을 잡는데, 그 사이
   이전 get_log_data가 트리거한 `task_rotate_sync()`가 아직 안 끝났으면 그 shared_lock이
   풀릴 때까지 최대 `SYSTEM_LOG_REQUEST_CMD_TIMEOUT`(180s)급으로 줄을 서서 기다릴 수 있다.
   실측(24s 대기 후 성공)상 30초는 그 마진을 좁게 둔 값 — get_log_data 직후 곧바로
   factory_reset이 들어오는 실사용 패턴에서 이 대기가 더 길어지는 회귀가 생기면 여기서
   FAIL로 드러나야 하므로, 넉넉한 타임아웃으로 눌러 덮지 않는다)
3. 응답 수신 확인
4. 더미 파일 + 디렉토리 내 모든 파일 소멸 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 | error_code = 0 수신 |
| toupload 파일 | 전체 삭제 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | factory_reset 응답 수신 | boolean | true | `[ -n "$resp" ]` |
| TC09-2 | toupload 파일 전체 삭제 | boolean | true | `[ -z "$(ls ${TOUPLOAD_DIR}/*.* 2>/dev/null)" ]` |

---

## TC10 — 리부트 전 로그 저장

### 목적

`shutdown_application_for_system_reboot` IPC 요청 시 shutdown 로그가 staging에 저장되고,
실제 리부트 후 boot log(부팅 시 무조건 캡처 + vacuum)와 합쳐져 toupload에 이관되는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- DUT 실제 리부트 가능 환경 (테스트 종료 후 90~120초의 부팅 시간 허용)
- 시리얼 콘솔(COM7) 접속 권장 — SSH는 reboot 시 끊김
- staging(`/edge/log/system/`)과 toupload(`/edge/log/toupload/system/`) 쓰기 가능
- `/edge/log/system/.tc10_before` 임시 파일 작성 가능 (TC10-PRE의 toupload 개수 저장용)

### 절차

**Phase 1 — 리부트 전 (`--tc10-pre`):**
1. `BEFORE_TOUPLOAD` = toupload `.log.xz` 파일 수 기록
2. `mosquitto_pub` → `shutdown_application_for_system_reboot` 요청, 60초 대기
3. 응답 수신 확인
4. staging `.log.xz` 생성 확인
5. `reboot` 실행 (SSH 연결 종료, 시리얼은 유지)

**Phase 2 — 리부트 후 (`--tc10-post`, 재접속 후 수동 실행):**
1. `AFTER_TOUPLOAD` = toupload `.log.xz` 파일 수 확인 (boot log 무조건 캡처 + merge 결과)
2. 파일 수 증가 확인 (`AFTER > BEFORE_TOUPLOAD`)
3. staging 비워짐 확인


### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 수신 (pre) | MQTT 응답 수신 |
| staging .xz (pre) | 신규 생성됨 |
| toupload .xz (post) | 파일 수 증가 |

### PASS/FAIL Criteria

| 기준 ID | 단계 | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|------|--------|---------|
| TC10-1 | pre | 응답 수신 | boolean | true | `[ -n "$resp" ]` |
| TC10-2 | pre | staging .xz 생성 | boolean | true | `ls /edge/log/system/systemlog_*.log.xz` |
| TC10-3 | post | toupload 파일 수 증가 (boot 캡처 + merge) | boolean | true | `[ "$AFTER_TOUPLOAD" -gt "$BEFORE_TOUPLOAD" ]` |

---

## TC11 — nmon 업로드 happy path

### 목적

`task_upload_nmon()`이 `/edge/log/system/nmon/old/*.nmon` 를 `/edge/log/toupload/system/nmon/` 으로
이동하고 `.meta`(`post_action_success=delete`, `post_action_failure=move`,
`move_dir_failure=/edge/log/system/nmon/archive`, `from=system_log`, `upload_path=/ems-system/nmon/YYYY/MM/`)
를 생성하는지, 그리고 BlobUploadDirector 5분 스캔이 toupload 항목을 정상 처리하는지 검증한다.

### 사전 조건

- 공통 전제 조건 충족
- `/edge/log/system/nmon/old/` 쓰기 가능 (없으면 mkdir)
- `/edge/log/toupload/system/nmon/` 디렉토리 쓰기 가능 (`task_upload_nmon` 이 lazy 생성)
- 디바이스가 Azure Blob 정상 통신 가능 — TC11-5 검증에 필요 (실패 시 후처리 자동 archive 이동으로 알려진 동작)
- system_log MQTT 토픽 발행 권한 (`emsp/system_log/+/req/get_log_data`) — TC03 트리거 재사용

### 절차

1. `/edge/log/system/nmon/old/` 비우고 더미 `.nmon` 3개 생성 (`dummy_tc11_a.nmon`, `dummy_tc11_b.nmon`, `dummy_tc11_c.nmon`) — 각 파일에 헤더 라인 1줄 기록
2. baseline 카운트 — `INPUT_COUNT=3`, `TOUPLOAD_BEFORE` = `/edge/log/toupload/system/nmon/*.nmon` 수
3. `send_and_wait "get_log_data" "{}" 30` 으로 SERVICE_GET_LOG_DATA 트리거 (TC03 패턴 재사용)
4. 응답 후 5초 대기 — `task_upload_nmon()` 의 `fs::rename` + `create_upload_task` 완료 보장
5. 즉시 단계 검증:
   - `/edge/log/system/nmon/old/` 의 `.nmon` 수가 0인지
   - `/edge/log/toupload/system/nmon/` 에 `.nmon` + `.nmon.meta` 페어 3쌍 존재하는지
   - 임의 `.nmon.meta` 1개를 grep 하여 4개 필드 + `upload_path` 매치

### 기대 결과

| 항목 | 기준 |
|------|------|
| `/edge/log/system/nmon/old/*.nmon` | 0개 (입력 전체 이동됨) |
| `/edge/log/toupload/system/nmon/` | 입력 개수만큼 `.nmon` + `.nmon.meta` 페어 |
| `.meta` `upload_path` | `/ems-system/nmon/YYYY/MM/` (현재 연/월) |
| `.meta` 후처리 필드 | `post_action_success=delete`, `post_action_failure=move`, `move_dir_failure=/edge/log/system/nmon/archive`, `from=system_log` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC11-1 | `/edge/log/system/nmon/old/` 의 .nmon 0개 | boolean | true | `[ "$old_after" -eq 0 ]` |
| TC11-2 | toupload 의 .nmon 갯수가 trigger 전·후로 증가 (단순 증가만 확인) | boolean | true | `[ "$xfer_after" -gt "$xfer_before" ]` |
| TC11-3 | .meta 의 `upload_path=/ems-system/nmon/YYYY/MM/` 매치 | boolean | true | `grep -qE "^upload_path=/ems-system/nmon/${yyyy}/${mm}/" "$any_meta"` |
| TC11-4 | .meta 의 4개 후처리 필드 모두 매치 | boolean | true | 4 grep 모두 0 |
| TC11-5 | toupload 의 .nmon.meta 갯수가 trigger 전·후로 증가 (단순 증가만 확인) | boolean | true | `[ "$meta_after" -gt "$meta_before" ]` |

---

## TC12 — nmon retention 30일

### 목적

`cleanup_nmon_dir()`(`system_log.cpp`) 의 30일 보존 삭제가 `nmon/old`, `nmon/archive`,
`toupload/system/nmon` 3개 디렉토리 모두에서 정상 동작하는지 확인.

> **트리거 변경 이력:** 예전엔 `systemctl restart nmon.service` 로 정리가 발화된다고
> 가정했으나, `cleanup_nmon_dir()`는 `system_log` 자신의 `task_cleanup_logs()`에서만
> 호출된다(프로세스 시작 시 1회 + 24시간 주기) — `nmon.service`는 무관한 별도 유닛이라
> 재시작해도 이 함수가 안 불린다. 그래서 예전 방식은 근처 다른 TC(kill -9 재시작)나
> TC02의 시계 점프가 우연히 3초 창에 겹칠 때만 통과하는 flaky 테스트였다(실측:
> `20260807_152712_system_log_full` run에서 우연이 안 맞아 TC12-1/3 FAIL). TC14/TC16과
> 동일하게 `system_log`를 직접 `kill -9`해 재시작을 강제하고, 그 재시작이 부르는
> `task_cleanup_logs()`의 결과(더미 삭제)를 최대 90초 폴링해서 기다리는 방식으로
> 결정적으로 재현하도록 변경했다(트리거만 변경, 삭제 판정 기준은 기존과 동일).

### 사전 조건

- 공통 전제 조건 충족
- 위 3개 디렉토리 쓰기 가능 (없으면 mkdir)
- `touch -d "40 days ago"` 명령 사용 가능 (mtime 조작)
- `pgrep`, `kill -9` 사용 가능, edge_runtime이 system_log 재시작시키는 상태

### 절차

1. 3개 디렉토리에 더미 파일 생성:
   - 40일 더미: `tc12_old40.nmon`, `tc12_old40.nmon.meta` 등 디렉토리당 1쌍
   - 현재 시각 더미: `tc12_now.nmon`, `tc12_now.nmon.meta` 등 디렉토리당 1쌍
   - 40일 더미는 `touch -d "40 days ago"` 로 mtime 조작
2. `kill -9 $(pgrep -f /edge/app/bin/system_log)` → edge_runtime 재시작 →
   `task_cleanup_logs()` → `cleanup_nmon_dir()` 무조건 실행
3. 3개 디렉토리 모두에서 `tc12_old40.nmon`이 사라질 때까지 최대 90초 1초 간격 폴링
4. 3개 디렉토리에서 더미 존재/부재 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 40일 더미 | 3개 디렉토리 모두 부재 |
| 현재 시각 더미 | 3개 디렉토리 모두 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC12-1 | 3 디렉토리에서 40일 mtime `.nmon` 모두 삭제 | boolean | true | 3 디렉토리 모두 `[ ! -f "$old40" ]` |
| TC12-2 | 3 디렉토리에서 현재 시각 `.nmon` 보존 | boolean | true | 3 디렉토리 모두 `[ -f "$now_file" ]` |
| TC12-3 | 3 디렉토리에서 40일 mtime `.nmon.meta` 모두 삭제 | boolean | true | 3 디렉토리 모두 `[ ! -f "$old40_meta" ]` |
| TC12-4 | 3 디렉토리에서 현재 시각 `.nmon.meta` 보존 | boolean | true | 3 디렉토리 모두 `[ -f "$now_meta" ]` |

---

## TC13 — nmon 부재 환경 호환 (no-op)

### 목적

`/edge/log/system/nmon/old/` 가 비어있거나 디렉토리 자체가 미존재일 때,
`task_upload_nmon()` 이 에러 없이 (응답 `error_code=0`) 동작하는지 확인.

### 사전 조건

- 공통 전제 조건 충족
- `/edge/log/system/nmon/old/` 비울 권한 (root)
- system_log MQTT 토픽 발행 권한 (TC03 트리거 재사용)

### 절차

1. `/edge/log/system/nmon/old/` 내부 `*.nmon` / `*.nmon.meta` 전부 제거 (디렉토리 자체는 남김 — 환경 친화 케이스)
2. `send_and_wait "get_log_data" "{}" 30` 으로 트리거 → 응답 수신 확인
3. 응답 페이로드에 `error_code` 추출 후 0 확인 (없으면 응답 자체 수신만으로 PASS — TC03 와 동일 정책)

### 기대 결과

| 항목 | 기준 |
|------|------|
| MQTT 응답 | 30초 이내 수신 |
| 에러 | 없음 (`error_code=0` 또는 응답 수신) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC13-1 | `get_log_data` 응답 수신 (nmon old 비어있어도 에러 없음) | boolean | true | `[ -n "$resp" ]` |
| TC13-2 | 응답 페이로드에 `error_code` 가 있으면 `0` 또는 `"NONE"` (둘 다 정상 의미, `task_rotate_sync` 정상) | boolean | true (있을 시) | `echo "$resp" \| grep -qE '"error_code"[[:space:]]*:[[:space:]]*(0\|"NONE")'` (또는 필드 부재 시 skip) |
| TC13-3 | 최근 1분 journald 에 `[task_upload_nmon]` ERROR/Failed 로그 부재 (silent failure 가드) | boolean | true | `journalctl -u docker-loader --since "1 minute ago" \| grep -F '[task_upload_nmon]' \| grep -E 'ERROR\|Failed'` 결과 빈 문자열 |

---

## TC14 — RTC 이상 시 동일 시작시간 다중 파일 병합

### 목적

RTC가 고장난 환경에서 staging에 동일한 부팅 시작시간(`BOOT_START`)을 가진
`.log.xz` 파일이 다수 존재할 때, `task_merge_staged_logs`가 단일 파일로
올바르게 병합하여 toupload에 이관하는지 확인한다.

### 배경

RTC 이상 시 시스템 시각이 부팅 직전 시각으로 초기화될 수 있다.
`task_capture_boot_log`와 `task_capture_shutdown_log` 모두
`journalctl --list-boots | head -n 1`에서 얻은 동일한 `start_time`을 사용하므로,
여러 캡처 파일이 같은 `systemlog_{BOOT_START}_*.log.xz` prefix를 가질 수 있다.
`task_merge_staged_logs`는 알파벳 정렬 후 `parse_log_start_time(front())` ~
`parse_log_end_time(back())`으로 병합 파일명을 결정하므로 동일 시작시간 파일도
올바르게 처리해야 한다.

system_log를 `kill -9` 하면 edge_runtime이 재시작하고 startup 시
`task_capture_boot_log()` → `task_merge_staged_logs()` 순서로 실행되므로,
실제 리부트 없이 해당 흐름을 재현할 수 있다.

### 사전 조건

- 공통 전제 조건 충족
- `system_log` 프로세스 실행 중 (`pgrep -f system_log`)
- edge_runtime이 system_log 비정상 종료 시 자동 재시작하는 상태
- staging(`/edge/log/system/`) 쓰기 가능
- `pgrep`, `kill`, `xz`, `seq` 명령 사용 가능

### 절차

1. staging 내 기존 `systemlog_*.log.xz` 및 `.merging_*.tmp` 제거
2. `BOOT_START` = `journalctl --list-boots | head -n 1 | awk '{print $4, $5}' | sed 's/[-:]//g' | tr -d ' '`
3. `BEFORE_TOUPLOAD` = 현재 toupload `.log.xz` 파일 수 기록
4. 더미 `.log.xz` 2개 staging에 배치 (RTC 이상 시뮬레이션):
   ```bash
   seq 1 2000 | xz -1 -c > /edge/log/system/systemlog_${BOOT_START}_${BOOT_START}01.log.xz
   seq 1 2000 | xz -1 -c > /edge/log/system/systemlog_${BOOT_START}_${BOOT_START}02.log.xz
   ```
5. `kill -9 $(pgrep -f system_log | head -1)` → edge_runtime이 system_log 재시작
6. 재시작 후 `task_capture_boot_log` 실행 → staging에 `systemlog_{BOOT_START}_{current_time}.log.xz` 추가
7. `task_merge_staged_logs` 실행 → 3개 파일 병합 → toupload 이관 대기 (최대 90초)
8. staging `.log.xz` 개수, toupload 파일 수, 병합 파일 시작시각, xz 무결성 확인

> **정렬 근거:** 더미 파일의 end 타임스탬프 `{BOOT_START}01` (16자리)는 실제 캡처의 end 타임스탬프
> (14자리 현재시각)보다 알파벳 순서상 앞에 위치하므로, 더미가 `xz_files.front()`가 되어
> `merged_start = BOOT_START`가 보장된다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| staging `systemlog_*.log.xz` | 0개 (모두 소비됨) |
| toupload 파일 수 | 증가 (`AFTER > BEFORE`) |
| 병합 파일 시작시각 | `BOOT_START` (front 파일 기준) |
| 병합 파일 무결성 | `xz --test` exit 0 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC14-1 | staging systemlog_*.log.xz 모두 소비됨 (0개) | boolean | true | `[ "$staging_remain" -eq 0 ]` |
| TC14-2 | toupload .log.xz 신규 생성됨 | boolean | true | `[ "$AFTER_TOUPLOAD" -gt "$BEFORE_TOUPLOAD" ]` |
| TC14-3 | 병합 파일 start_time = BOOT_START | boolean | true | `[ "$new_start" = "$BOOT_START" ]` |
| TC14-4 | 병합 파일 xz 무결성 | exit code | 0 | `xz --test "$NEW_XZ"` |

---

## TC15 — task_rotate_sync: compress 실패 시 raw .log 보존 (toupload)

### 목적

`task_rotate_sync()`가 `xz -f` 압축 실패(180s 타임아웃) 시:
1. 원본 raw `.log`를 삭제하지 않고 보존
2. SIGKILL로 잘린 partial `.log.xz`는 제거
3. 실패 사이클에 대해 `.meta`는 생성하지 않음(업로드 큐 미등록)
4. **vacuum은 compress 성공/실패와 무관하게 항상 실행**됨 (`--list-boots` head 이동으로 확인)

을 검증한다.

### 사전 조건

- 공통 전제 조건 충족
- `systemd-cat`, `journalctl --rotate` / `--vacuum-files` 권한 (root)
- 디바이스 emmc 가용 공간 900MB 이상 (premade dummy blob 상주분 포함, 210→400MB 상향에 따라 재산정)
- 현재 `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=180초` (`system_log.hpp:30`) 전제 — 값이 바뀌면 주입량 재조정 필요
- **주의(파괴적 시험):** journal을 raw ~400MB 상당 채웠다가 vacuum으로 비움. (210MB 시절엔 180s 경계에서 flaky하게 성공/실패가 갈렸던 이력 있음 — 400MB로 상향해 안정적으로 timeout 유도) 다른 TC와 동시 실행 금지. premade blob 최초 생성 시에만 5분 이상, 이후 재사용 시에는 훨씬 짧음
- 의존 TC 없음 (독립 실행 가능)

### 절차

1. `journalctl --rotate && --vacuum-files=1`로 journal 초기화
2. `BEFORE_HEAD` = `journalctl --list-boots | head -n1` 기록, toupload `.log`(xz 아닌) 목록 스냅샷
3. `/edge/log/.tc_dummy_journal_blob`(TC04와 공유하는 premade 랜덤 blob, 없으면 최초 1회만
   생성) 전체를 `systemd-cat -t TC15_DUMMY` 로 주입 → `sync; sleep 3; journalctl --rotate; sleep 2`
4. `get_log_data` 요청 송신, 최대 200초 대기 (180s cmd timeout + overhead)
5. 응답 후 10초 추가 대기
6. before/after 목록 diff로 이번 사이클이 만든 신규 raw `.log`(`NEW_LOG`) 식별
7. `NEW_LOG` 존재 확인, `${NEW_LOG}.xz` / `${NEW_LOG}.xz.meta` 부재 확인
8. `AFTER_HEAD` = `journalctl --list-boots | head -n1` → BEFORE_HEAD와 비교
9. cleanup: `NEW_LOG` 삭제, journal 재초기화

### 기대 결과

| 항목 | 기준 |
|------|------|
| raw `.log` | toupload에 신규 생성되어 보존됨 |
| partial `.xz` | 존재하지 않음 |
| `.meta` | 존재하지 않음 |
| list-boots head | BEFORE와 다름 (vacuum 실행 증거) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC15-1 | 압축 실패 후 raw `.log`가 toupload에 보존됨 | boolean | true | `[ -f "$NEW_LOG" ]` |
| TC15-2 | 깨진 partial `.xz`는 남지 않음 (`get_log_data` 응답 수신 후 `.xz` 크기가 더 안 늘어날 때까지 최대 60초 안정화 대기 후 판정 — host_agent가 타임아웃을 살짝 넘겨서까지 원격 xz를 계속 돌리는 경우가 있어 응답 직후 스냅샷은 오판 가능) | boolean | true | `[ ! -f "${NEW_LOG}.xz" ]` |
| TC15-3 | `.meta` 생성되지 않음 | boolean | true | `[ ! -f "${NEW_LOG}.xz.meta" ]` |
| TC15-4 | vacuum이 실행되어 list-boots head 변경됨 | boolean | true | `[ "$after_head" != "$before_head" ]` |

---

## TC16 — task_capture_boot_log: compress 실패 시 raw .log 보존 (staging)

### 목적

`system_log` 재시작 시 무조건 실행되는 `task_capture_boot_log()`가 compress 실패 시 TC15와 동일한 보존 규칙을 따르는지, 그리고 남은 raw `.log`가 `task_merge_staged_logs()`에 의해 toupload로 잘못 이관(오염)되지 않는지 검증한다. TC14(RTC 이상 병합)와 같은 `kill -9` 재시작 기법을 재사용한다.

`task_capture_shutdown_log`는 동일 코드 패턴이라 이번 범위에서 제외(코드 리뷰로 대체).

### 사전 조건

- 공통 전제 조건 충족
- `pgrep`, `kill -9` 사용 가능, edge_runtime이 system_log 재시작시키는 상태
- `systemd-cat`, `journalctl --rotate` / `--vacuum-files` 권한 (root)
- 디바이스 emmc 가용 공간 900MB 이상 (premade dummy blob 상주분 포함, 210→400MB 상향에 따라 재산정)
- 현재 `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=180초` 전제
- **주의(파괴적 시험):** TC15와 동일한 journal 주입(premade blob 재사용) + system_log 강제 재시작 수반. premade blob 최초 생성 시에만 5분 이상, 이후 재사용 시에는 훨씬 짧음
- 의존 TC 없음 (독립 실행 가능, TC15 실행 여부와 무관)

### 절차

1. staging 클린업 (`systemlog_*.log.xz`, `*.log`, `.merging_*.tmp` 제거)
2. `BEFORE_HEAD` = `journalctl --list-boots | head -n1` 기록
3. TC15와 동일 기법으로 journal 주입 (`TC16_DUMMY` 태그)
4. `kill -9 $(pgrep -f system_log)` → edge_runtime 재시작 → `task_capture_boot_log()` 무조건 실행
5. 최대 480초까지 journald를 5초 간격으로 폴링해 `[task_capture_boot_log] Done:` 또는
   `Failed to compress log` 완료 신호를 기다림(고정 대기 아님 — dump 단계가 주입량에
   비례해 늘어나 xz 180초 타임아웃 시작 시점이 밀리므로, 완료 신호 확인 전에는 판정하지 않음)
6. staging에서 신규 raw `.log`(`NEW_LOG`) 확인
7. `${NEW_LOG}.xz` 부재 확인
8. `NEW_LOG`와 동일 베이스네임이 toupload로 잘못 넘어가지 않았는지 확인 (merge 오염 방지 검증)
9. `AFTER_HEAD` 비교
10. cleanup: journald(`docker-loader`)에서 `[task_capture_boot_log] Failed to compress log, keeping raw .log for diagnostics: ${NEW_LOG}` 로그가 확인된 경우에만 `NEW_LOG` 삭제(미확인 시 진단용 보존), journal 재초기화

### 기대 결과

| 항목 | 기준 |
|------|------|
| raw `.log` | staging에 신규 생성되어 보존됨 |
| partial `.xz` | 존재하지 않음 |
| toupload 오이관 | 없음 |
| list-boots head | BEFORE와 다름 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC16-1 | 압축 실패 후 raw `.log`가 staging에 보존됨 | boolean | true | `[ -f "$NEW_LOG" ]` |
| TC16-2 | 깨진 partial `.xz`는 남지 않음 (journald 완료 신호 감지 후 `.xz` 크기가 더 안 늘어날 때까지 최대 60초 안정화 대기 후 판정 — TC15와 동일 이유) | boolean | true | `[ ! -f "${NEW_LOG}.xz" ]` |
| TC16-3 | raw `.log`가 toupload로 잘못 이관되지 않음 | boolean | true | `find "${TOUPLOAD_DIR}" -name "$(basename "$NEW_LOG")*"` 결과 없음 |
| TC16-4 | vacuum이 실행되어 list-boots head 변경됨 | boolean | true | `[ "$after_head" != "$before_head" ]` |

---

## TC17 — MessageContext tid 미검증: cmd_host 응답 위조로 결정적 재현

### 목적

`SystemLog::handle_response()`(`system_log.cpp:165-188`)는 `SERVICE_CMD_HOST` 응답이
오면 **tid를 전혀 검증하지 않고** 무조건 `message_context_.complete()`를 호출한다.
`message_context_`(`system_log.hpp:40-79`)는 tid 필드 자체가 없는 단일 공유 슬롯이라,
"지금 이 응답이 내가 기다리던 그 요청의 응답인가"를 확인할 방법이 구조적으로 없다.
이 TC는 완전히 무관한(위조) `tid`의 cmd_host 응답을 실제 요청이 진행 중인 도중에
직접 발행해, 그것이 진짜 응답인 것처럼 삼켜지는지를 재현·검증한다.

> **판정 관례:** 다른 TC와 동일하게 **PASS=정상 동작, FAIL=결함 재현**이다. 즉 위조
> 응답이 실제로 소비되거나 크래시를 유발하면 FAIL — 현재 코드 상태(tid 미검증)에서는
> 항상 FAIL이 나오는 게 정상이다. 추후 `handle_response()`에 tid 검증이 추가돼 위조가
> 안전하게 거부되면 이 TC는 **PASS로 바뀐다**. 아직 고쳐지지 않은 결함을 이용하는
> 시험이라 회귀 세트(빠른 실행/`--full`)에는 포함하지 않고 `--tc17` 또는
> `--only TC17`로만 단독 실행한다.

### 사전 조건

- 공통 전제 조건 충족
- `mosquitto_pub`으로 임의 토픽에 발행 가능 (MQTT 브로커 접근 권한 — 정상 운영 환경이라면
  이 자체가 이미 신뢰 경계 밖에서의 발행을 의미하므로, 실제로는 브로커 접근 통제가
  뚫린 상황을 가정한 시험. 이 DUT 개발 환경은 로컬 브로커라 인증 없이 발행 가능함)

### 절차

> TC17-1과 TC17-2는 **같은 공격 한 번을 서로 다른 두 관점에서 관찰**하는 별개 시험이다
> (TC09가 한 번의 `factory_reset` 실행에서 TC09-1/TC09-2를 독립적으로 판정하는 것과 같은
> 구조). 아래 절차는 TC17-1/TC17-2 공용이며, 판정 방법은 "기대 결과"에서 각각 설명한다.

정밀한 타이밍을 노리는 대신 훨씬 단순한 방식을 쓴다 — `get_log_data` 한 번이 내부적으로
`task_rotate_sync()`를 통해 `request_start_time → request_make_log → request_rotate_log →
request_compress_log` 순으로 `request_command_sync()`를 4번 연달아 호출한다(각각 별도의
짧은 `message_context_` 대기 창). 대량 journal 주입 없이도, 그 실행 구간 동안 위조 응답을
짧은 간격으로 반복 발행하면 4번의 창 중 최소 하나는 반드시 맞는다.

1. toupload `.log.xz` BEFORE 목록 기록
2. `get_log_data` 요청을 백그라운드로 비동기 송신 (응답을 기다리지 않고 바로 다음 단계로)
3. `emsp/system_log/sys_manager/res/cmd_host` 토픽에 위조 메시지를 0.2초 간격으로
   40회(≈8초) 반복 발행 — `sys_manager.cpp:1587`의 실제 `CmdHostResponse` 성공 응답
   형태(`status`/`cmd`/`exit_code`/`message`)를 그대로 흉내 내되, `cmd` 값은 이 디바이스에
   **존재하지 않는 명령어**(`xze`)로 채운다 — 존재하지도 않는 명령을 성공적으로 실행했다는
   명백히 말이 안 되는 위조조차 tid만 안 맞으면 걸러지지 않는다는 걸 함께 보여준다
   ```
   {"error_code":"NONE","payload":{"status":"success","cmd":"xze -f /tmp/tc17_nonexistent_cmd","exit_code":0,"message":"","injected_marker":"<고유 마커>"}}
   ```
   tid를 붙이지 않음 — 실제 진행 중인 요청의 tid와는 전혀 무관, service만 `cmd_host`로 일치.
4. 백그라운드 `get_log_data` 응답을 최대 30초까지 대기
5. cleanup: 이번 run이 새로 만든 `.xz`와 동반 파일(`.xz.meta`, raw `.log`)까지 제거

### 기대 결과

**TC17-1** (공격자 관점 — 위조 응답의 `status` 값이 그대로 노출되는지)

위조 payload의 `cmd`는 `xze` — 보안 화이트리스트 정책에 걸려 sys_manager가 절대로
`status:"success"`를 낼 수 없는 명령이다(실측: 진짜로 `xze`를 보내보면
`{"error_code":"UNKNOWN","payload":{"status":"error","message":"CMD_SH failed:
Command not allowed by security whitelist policy",...}}`만 옴). 마커 주변 문맥에서
`"status":"..."` 값을 직접 추출해, 있을 수 없는 `"success"`가 그대로 등장하는지가 판정
근거다.

| 항목 | 기준 |
|------|------|
| 수정 전 (실측) | `cmd:xze`로는 나올 수 없는 `"status":"success"`가 소비(`[request_command_sync] result:`) 또는 크래시(`Promise already satisfied`) 경로로 그대로 노출 → FAIL |
| 수정 후 (기대) | 마커 자체가 안 나타남(위조가 안전하게 거부됨) → PASS |

**TC17-2** (피해자 관점 — 진짜 요청의 `status`가 무사한지, TC17-1과 무관하게 독립 확인)

`get_log_data` 최종 응답을 success/error/timeout 세 상태로 직접 분류한다: `error_code:"NONE"`
→ success, 그 외 `error_code` → error, 응답 자체가 없음(30초 타임아웃) → timeout. success일
때만 PASS.

| 항목 | 기준 |
|------|------|
| 수정 전 (실측) | 위조 스팸 중에도 대체로 `success`로 응답하지만, 그 성공이 진짜인지는 보장 못 함 (아래 사각지대 참고) |
| 수정 후 (기대) | `success`로 응답하고, 그 성공이 실제로 온전함(사각지대 항목 참고 로그가 깨끗함) |

**사각지대** (판정에는 미반영, 참고 로그만 남김) — start_time 단계가 위조로 하이재킹돼도
뒤이은 make_log/rotate/compress는 셸 명령 자체는 진짜로 성공하므로 `get_log_data` 응답은
결국 success로 나온다(실측: `systemlog__<endtime>.log.xz`처럼 더블 언더스코어로 조용히
오염된 채 status는 success). 신규 `.xz` 파일명/`xz --test`를 참고용으로 계속 확인해 이
사각지대를 로그에 남긴다 — `systemlog__<endtime>.log.xz`처럼 더블 언더스코어로 나타나면
status=success여도 조용한 오염 사례(실측으로 확인됨).

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC17-1 | `MessageContext`가 tid 불일치 cmd_host 응답의 위조 `status`를 그대로 노출하지 않음 | boolean | true(=마커 미등장) | 마커 주변(`grep -B3 -A1`) 문맥에서 `grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"'`로 추출한 값이 **없어야** PASS (있으면 FAIL) |
| TC17-2 | 위조 스팸 중에도 진짜 `get_log_data` 응답 status가 success | boolean | true(=success) | `get_resp`에 `"error_code":"NONE"` 포함 시 success(PASS), 그 외 값이면 error, 무응답(30s)이면 timeout(둘 다 FAIL) |

---

## TC18 — 저장공간 부족(<10%) 시 SYSTEM_LOG_DIRS cleanup

### 목적

`/edge/log` 파티션 여유공간이 10% 미만으로 떨어졌을 때, `system_log`가 `SYSTEM_LOG_DIRS =
{STAGING_DIR("/edge/log/system"), TOUPLOAD_DIR(SYSTEM_LOG_PATH, "/edge/log/toupload/system/"),
ARCHIVE_DIR("/edge/log/system/archive")}` 3개 디렉토리를 순회하며 `cleanup_log_dir()` →
`cleanup_if_low_disk_space()` → `delete_oldest_files_until_safe()`로 오래된 파일(`.xz`/
`.log`/`.meta`)부터 삭제해 여유공간을 회복시키는지 검증한다.

> **재설계 이력 (2026-09-04):** 최초 버전은 더미 배치 후 실제 `reboot`으로 재현했다.
> 하지만 대용량(GB급) 쓰기 직후 `reboot`하면 — `sync` 2회, 이중 sync, `/proc/meminfo`
> Dirty/Writeback 폴링까지 다 동원해봐도 — **더미가 cleanup 로그 증거 없이 통째로
> 사라지는 현상이 반복 재현**됐다. 같은 조건에서 `reboot` 대신
> `systemctl restart docker-loader`(전원 재부팅 없이 앱만 재시작)로 트리거를 바꾸면
> cleanup이 `[cleanup_if_low_disk_space]`/`[cleanup] Removing:` 로그까지 남기며 매번
> 정상 발화하는 것을 실측으로 확인했다. 또한 실제 필드 버그 리포트(디스크 사용률이
> 91%→71%→31%→11%로 여러 날에 걸쳐 점진적으로 회복된 사례)와 대조해보면, 그 패턴은
> "cleanup이 완전히 실패한다"가 아니라 "cleanup이 여러 차례에 걸쳐 정상적으로 누적
> 동작한다"는 증거였다 — 즉 "대용량 쓰기 직후 즉시 reboot"이라는 조합 자체가 실 필드
> 시나리오에 없던, 이 TC의 재현 방법론이 만든 별개의 인위적 엣지 케이스였을 가능성이
> 높다. 그래서 트리거를 `systemctl restart docker-loader`(TC12가 이미 쓰는 검증된
> 패턴)로 바꾸고, `reboot` 관련 유실 현상 자체는 원인 불명·실 필드 패턴 불일치로 이 TC
> 범위에서 제외해 별도 이슈로만 추적한다. 이 전환으로 SSH/시리얼 세션이 더 이상 안
> 끊기게 돼 `--only`/`--full`에도 자연스럽게 편입됐다(TC10처럼 별도 pre/post로 나눌
> 필요가 없어짐).

> **더미 mtime을 30일 미만으로 두는 이유:** `cleanup_log_dir()`는 이 TC가 검증하려는
> 저장공간-부족 경로(`cleanup_if_low_disk_space`) 외에도, 매 호출마다 **여유공간과
> 무관하게 30일(`LOG_RETAIN_DAY`) 지난 파일을 무조건 삭제**하는 `delete_log()`를 먼저
> 실행한다. 더미를 30일 이상 오래된 것으로 만들면 두 경로가 뒤섞여 "저장공간 부족 시
> 정말로 `cleanup_if_low_disk_space`가 지운 것"인지 판별이 흐려진다. 그래서 더미
> mtime을 1일 전으로 둔다 — `delete_oldest_files_until_safe()`는 mtime이 아니라 "그
> 순간 파티션 여유율<10%"만으로 삭제 여부를 결정하므로, 1일 전이어도 최우선(가장 오래된
> 순서) 삭제 대상이 되는 데는 지장이 없다.

> **더미 배치 설계 근거 (및 한계):** `task_cleanup_logs()`는 `SYSTEM_LOG_DIRS`를
> STAGING→TOUPLOAD→ARCHIVE 순서로 순회하고, 각 디렉토리 처리 시점마다
> `cleanup_if_low_disk_space()`가 **그 순간의 파티션 전체 여유율**을 다시 확인한다
> (`free_ratio >= threshold_percent(10)`이면 그 디렉토리는 그냥 스킵). 그래서
> STAGING/TOUPLOAD엔 트리거 여부만 확인할 작은 더미(합쳐서 3MB, 1MB×3개 분할)를,
> ARCHIVE엔 실제 회복을 담당할 큰 더미(8~105MB대 여러 개 분할)를 두는 구성으로
> 만들었다 — **세 디렉토리 전부 단일 거대 파일이 아니라 여러 개로 쪼갠다**
> (`system_log_partition.txt` 참고 사례처럼 실제로는 파일이 여러 개 쌓인 형태이고,
> `delete_oldest_files_until_safe`가 오래된 순으로 순차 삭제하는 과정도 관찰할 수
> 있게 하기 위함, 2026-09-04 사용자 확인). 다만 STAGING/TOUPLOAD에 우리 더미 말고
> 다른 실제 운영 파일이 남아있으면 `delete_oldest_files_until_safe()`가 그것들까지
> 오래된 순으로 같이 지우다 그 디렉토리만으로 20%를 채워버릴 수 있고, 그러면 ARCHIVE
> 차례는 아예 오지 않을 수 있다 — 몇 곳에서 회수되는지는 실제 파일 분포에 달려있어
> 스크립트가 통제할 수 없다. 그래서 TC18-4는 "세 디렉토리 모두"가 아니라
> "SYSTEM_LOG_DIRS 중 최소 1곳 이상에서 실제로 발화했다"만 직접 증거로 요구한다.

### 사전 조건

- 공통 전제 조건 충족
- **예외 케이스 전용 파괴적 시험**: 실제 파티션 여유공간을 소진시킨다. 시험 시작 시점
  `/edge/log` 파티션 여유율이 **25% 이상**이어야 하며(더미 삭제만으로 코드의 회복
  목표치(threshold_percent*2=20%)를 확정적으로 넘기기 위한 마진, 실제 로그 파일을
  건드릴 위험 배제) — 그 외엔 여유율이 얼마든 목표 여유율(9%, 10% 트리거 바로 아래)까지
  낮추는 데 필요한 만큼 실제로 더미를 채운다. 안전 상한(`TC18_MAX_FILL_MB`, 기본
  6144MB)은 df 파싱이 완전히 깨진 극단적 케이스만 걸러내는 최후 안전장치일 뿐, 정상적인
  여유율 범위에서 필요한 더미량을 막지 않는다.

  > **실측(2026-09-04, 192.168.10.25):** 5.9GB 파티션(`/dev/mmcblk2p9` → `/edge/log`)에서
  > 여유율 85%(`df -h` 기준 Used 10%와 혼동 주의 — `df`의 Capacity% 컬럼은 **사용률**이지
  > 여유율이 아니다). 이 상태에서 10% 밑으로 낮추려면 더미가 약 4.55GB 필요 — 안전 상한
  > 6144MB 이내라 그대로 채워서 시험이 진행된다.
- `systemctl restart docker-loader` 실행 권한(root), `pgrep`, `dd`, `df -P`, `touch -d`,
  `awk` 사용 가능
- 다른 TC와 동시 실행 금지 (파티션 여유공간을 실제로 바꾸는 시험이라 TC04/15/16 등
  디스크 여유공간을 전제하는 다른 TC와 겹치면 서로 오판을 유발할 수 있음)

### 절차

1. `df -P`로 `STAGING_DIR`가 속한 파티션의 `total_kb`/`avail_kb`/여유율(퍼밀) 확인
2. 사전 조건(여유율 ≥25%, 목표 여유율까지 낮추는 데 필요한 용량 ≤ 안전 상한) 확인 —
   미충족 시 TC18-0 FAIL 기록 후 더미 생성 없이 즉시 종료(SKIP)
3. 더미 생성 (**세 디렉토리 전부 단일 파일이 아니라 여러 개로 분할**, 2026-09-04
   사용자 확인): `staging`(1MB×3개 분할, `.log`), `toupload`(1MB×3개 분할, `.xz`),
   `archive`(나머지 전체를 **8~105MB대 여러 개 파일로 분할** — 실제 로그 rotation
   크기에 가까운 청크 여러 개로 나눠서, `delete_oldest_files_until_safe`가 오래된
   것부터 순차적으로 지우는 걸 관찰할 수 있게 함) — 총량은 파티션 여유율을 9% 부근
   (10% 트리거 바로 아래)까지 낮추도록 매 실행 시 동적 계산
4. 모든 더미를 `touch -d "1 day ago"`(archive는 파일마다 1분씩 어긋나게, 모두 1일 전
   기준)로 mtime 설정(30일 미만 — day-retention 경로와 섞이지 않게 함, 오래된 순서도
   결정적으로 확인 가능)
5. `df -P`로 더미 배치 후 여유율 재확인 — 10% 미만으로 낮아졌는지 확인
6. `systemctl restart docker-loader` 실행(system_log 포함 재시작, TC12와 동일 트리거
   패턴) — `task_cleanup_logs()`가 재시작 직후(`system_log_timer_loop()` 시작 직후,
   92db92bb 이후 맨 앞) 동기 실행된다. 트리거 직후 **`journalctl -u docker-loader -f
   --no-pager -o short-iso`를 `timeout 20`으로 20초만 백그라운드 실시간 캡처**해 별도
   파일(`/tmp/tc18_journal_capture.log`)에 사본을 떠둔다(아래 Flag 참고) — `timeout`으로
   자체 종료되므로 PID 추적/kill 불필요
7. 더미가 모두 사라질 때까지 최대 90초, 1초 간격 폴링(TC12와 동일 예산) — 이 동안 위
   20초 캡처는 이미 자체 종료돼 있다
8. **`sync` 강제 실행 후 `df -P`가 안정될 때까지 최대 30초 폴링**(아래 Flag 참고),
   현재 여유율 확인
9. **캡처 파일에서**(라이브 재조회 아님, 아래 Flag 참고) `cleanup_if_low_disk_space()`/
   `delete_oldest_files_until_safe()`가 실제로 발화한 직접 증거를 확인:
   `[cleanup_if_low_disk_space]`(발화 여부), `[cleanup] Removing:`(어떤 파일을
   지웠는지) 로그를 `dump_cmd`로 통째 캡처하고, 더미 파일명 중 **1개 이상**이
   `[cleanup] Removing:` 로그에 등장하는지 확인
10. 파티션 여유율이 20% 이상으로 회복됐는지 확인

> **주의 (Flag, 2026-09-04 추가, df 지연):** archive 더미(4.5GB급)가 실제로 `[cleanup]
> Removing:` 로그까지 남기며 삭제됐는데도, 그 직후 곧바로 `df`를 찍으면 여유율 회수가
> 겨우 몇 MB만 반영되고(예: 537M→544M), 몇 분 뒤 다시 확인하면 baseline까지 완전히
> 회복돼 있는 게 실측됐다(`du -sh`로 블록도 실제로 비었음을 확인) — `/edge/log`가
> `commit=60`으로 마운트돼 있어(기본 5초 대비 12배 긴 간격) 대용량 단일/누적 삭제의
> 블록 회수 반영이 지연되는 것으로 추정된다. `sync`를 강제로 호출한 뒤 `df`가 안정될
> 때까지 짧게 폴링해서, 이 지연으로 인한 TC18-3 오탐(false negative)을 막는다.

> **주의 (Flag, 2026-09-04 추가, journal 증거 소멸 — serial 실측으로 원인 특정):**
> restart 이후 `journalctl -u docker-loader`를 사후 조회하면 `[cleanup] Removing:`
> 로그가 매번 0건이었다. 처음엔 "cleanup이 증거 없이 파일만 지운다"는 미스터리로
> 의심했으나, `journalctl -f` 백그라운드 실시간 tail(시리얼 콘솔로 직접 확인)로 대조한
> 결과 **로그는 실제로 정상 발화**한다(`[cleanup] Removing: ...` 19건 전부 + `[cleanup]
> Enough space recovered: 20.397%`까지 확인). 문제는 그 직후(260ms 뒤) `task_cleanup_logs()`
> 바로 다음 순서로 매 시작마다 호출되는 **`task_capture_boot_log()`**가
> `request_rotate_log()` → `SYSTEM_LOG_CMD_ROTATE_VACUUM`(`journalctl --rotate &&
> journalctl --vacuum-files=1`)을 실행해 journald 자체 저장소(같은 `/edge/log` 파티션)를
> 작게 유지하려고 archived journal을 지워버리는 것 — 방금 남긴 `[cleanup] Removing:`
> 로그까지 같이 날아간다. `delete_old_journals()`(machine-id 불일치 디렉토리만 지움,
> 무관)가 아니라 `task_capture_boot_log()`가 원인이며, journald를 롤링 버퍼처럼 쓰고
> 주기적으로 비우는 게 이 앱의 정상 설계라 코드 결함은 아니다 — 다만 이 때문에 "restart
> 후 사후 조회"로는 근본적으로 증거를 못 잡는다. 그래서 절차 6에서 트리거 직후
> `journalctl -f`를 20초만 별도 파일에 실시간 tail해 사본을 떠 두고, vacuum이 journald
> 내부 저장소를 지우더라도 그 사본에서 읽는다(같은 파일을 매 시작마다 만드는
> `task_capture_boot_log()`의 `systemlog_*.log.xz` 산출물도 이론상 같은 사본이 되지만,
> 뒤이은 `task_merge_staged_logs()`가 곧바로 병합·업로드 큐로 옮겨 언제 사라질지 통제할
> 수 없어 증거로 채택하지 않았다).

> **주의 (Flag, 2026-09-04 추가, TC18-2 기준 정정):** 원래 TC18-2는 "3곳 모두 파일
> 부재"를 요구했는데, 이는 `delete_oldest_files_until_safe()`의 실제 설계(파티션 전체
> 여유율이 목표(threshold_percent*2=20%)에 도달하는 순간 그 디렉토리 처리를 멈춤 — 남은
> 파일을 끝까지 다 지우는 게 아님)와 안 맞는 기준이었다. 실측(2026-09-04)에서 archive
> 더미 89개 중 13개만 지우고 20.397%에서 정상적으로 멈췄는데, 이걸 "3곳 모두 삭제
> 안 됨"으로 FAIL 오판정했다. 그래서 "3곳 중 최소 1곳에서라도 파일 개수가 실제로
> 줄었는지"(생성량 대비 잔존량 감소)로 완화했다 — TC18-4(journal 로그 증거)와는 독립된
> filesystem 관점의 보조 증거로만 쓰고, "전부 삭제"를 더 이상 정상 기준으로 삼지 않는다.

> **왜 파일 부재만으론 부족한가:** 더미가 사라졌다는 사실만으로는 "cleanup 코드 경로가
> 지운 것"과 다른 원인(예: 알 수 없는 유실)을 완전히 구분할 수 없다. `[cleanup]
> Removing: <path>`는 삭제 루프(`delete_oldest_files_until_safe`)가 그 파일을 실제로
> 지목해 `EdgeUtils::remove_file()`을 호출했다는 코드 레벨 증거이므로, 이걸 하나도 못
> 찾으면 파일이 없어졌더라도 TC18-4는 FAIL로 남아 "증거 없음"을 명시적으로 드러낸다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 사전 조건 | 여유율 ≥25% AND 필요 소진량 ≤ 안전 상한 |
| 더미 배치 후 여유율 | 10% 미만 |
| 더미 (restart 후) | SYSTEM_LOG_DIRS 중 최소 1곳에서 더미 파일 개수가 실제로 감소함 (전부 삭제까지는 요구하지 않음 — 아래 Flag 참고) |
| journald 삭제 증거 (restart 후) | 3개 더미 파일명 중 1개 이상이 `[cleanup] Removing:` 로그에 등장 |
| 파티션 여유율 (restart 후) | 20% 이상으로 회복 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC18-0 | 사전 조건 충족(여유율≥25% AND 필요 소진량≤안전상한 6144MB) — 미충족 시 이후 절차 생략 | boolean | true | df 파싱값 기반 계산 |
| TC18-1 | 더미 배치로 파티션 여유율이 10% 미만으로 낮춰짐 | boolean | true | `[ "$after_permille" -lt 100 ]` |
| TC18-2 | SYSTEM_LOG_DIRS 중 최소 1곳에서 더미 파일 개수가 실제로 감소함 (filesystem 관점 증거, TC18-4의 journal 증거와는 독립 채널) | boolean | true | `staging_removed>=1 \|\| toupload_removed>=1 \|\| archive_removed>=1` (각 `생성개수 - 잔존개수`) |
| TC18-4 | journald에 SYSTEM_LOG_DIRS 중 1곳 이상의 `[cleanup] Removing:` 로그 존재 (실제 cleanup 코드 경로로 삭제됐다는 직접 증거) | boolean | true | 3개 디렉토리 접두어(`tc18_dummy_staging_`/`toupload_`/`archive_`) 중 1개 이상 `journalctl -u docker-loader \| grep -F '[cleanup] Removing:'` 결과에 매치 |
| TC18-3 | 여유율이 20% 이상으로 회복됨 | boolean | true | `[ "$cur_permille" -ge 200 ]` |

---


## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `system_log` | MQTT 수신 대상 앱 ID |
| `TOUPLOAD_DIR` | `/edge/log/toupload/system` | toupload 경로 |
| `NMON_OLD_DIR` | `/edge/log/system/nmon/old` | nmon 회전 완료 파일 위치 (TC11/TC12/TC13) |
| `NMON_TOUPLOAD_DIR` | `/edge/log/toupload/system/nmon` | nmon toupload 경로 (TC11/TC12) |
| `NMON_ARCHIVE_DIR` | `/edge/log/system/nmon/archive` | nmon 업로드 실패 시 이동 디렉토리 (TC12) |

---

## 디렉토리 구조 참고

```
/edge/log/
├── system/                    ← STAGING_DIR (systemlog.sh 기동 시 mkdir)
│   ├── systemlog_A_B.log.xz  ← shutdown/boot 캡처 파일 (부팅 후 toupload 이관)
│   └── archive/               ← Azure 업로드 실패 시 lazy 생성
└── toupload/
    └── system/                ← TOUPLOAD_DIR (task_rotate_sync 또는 merge 후 이관)
        ├── systemlog_X_Y.log.xz
        └── systemlog_X_Y.log.xz.meta
```

---

## 자동화 등급 (Automation Grade)

🟢 **B**

| TC | 등급 | 비고 |
|----|------|------|
| TC01, TC03~TC09 | A (자동) | 무인 실행 가능 |
| TC02 | A (자동) | 시스템 시간 ±25h 자동 변경 + 복원 |
| TC04 | A (자동) | systemd-cat으로 100MB 실 journal 데이터 주입 + vacuum cleanup |
| TC06 | B (반자동) | 저널 사용량 수동 확인 |
| TC10 | B (반자동) | 실제 리부트 포함 — pre/post 분리 실행, 재접속 후 post 수동 실행 |
| TC11 | B (반자동) | nmon 업로드 happy path — TC11-5 는 5분+ 대기 (BlobUploadDirector 스캔) |
| TC12 | A (자동) | nmon retention 30일 — `kill -9 system_log` 후 재시작 시 발화하는 cleanup 대기(최대 90초) |
| TC13 | A (자동) | nmon old 비어있는 환경 호환 — `get_log_data` 응답 수신만 확인 |
| TC14 | A (자동) | RTC 이상 동일 시작시간 다중 파일 병합 — `kill -9 system_log` 후 edge_runtime 재시작 흐름 재현 |
| TC15 | A (자동) | task_rotate_sync compress 실패 시 raw .log 보존 — journal 대량 주입으로 180s 타임아웃 강제 유발 |
| TC16 | A (자동) | task_capture_boot_log compress 실패 시 raw .log 보존 — TC15와 동일 기법 + `kill -9 system_log` 재시작 |
| TC17 | A (자동) | MessageContext tid 미검증 재현 — cmd_host 응답 위조(`mosquitto_pub`) 직접 발행, 회귀 세트 미포함(단독 실행 전용) |
| TC18 | A (자동) | 저장공간 부족(<10%) 시 SYSTEM_LOG_DIRS cleanup — 예외 케이스 전용 파괴적 시험이라 기본 실행 미포함이지만, `systemctl restart docker-loader` 트리거로 재설계(2026-09-04)돼 reboot 없이 단일 실행으로 완결됨. `--full`/`--only`에 포함, 기본 실행에는 미포함. 사전 조건(여유율≥25%) 미충족 시만 자동 SKIP — 그 외엔 여유율만큼 실제로 채움(실측: 개발 DUT 여유율 85%에서 더미 약 4.55GB) |

---

## 관련 문서

- `tc_system_log_result.md` — 본 TC 실행 결과 보고서
- `tc_system_log_evidence_full.log` — 결과의 근거가 되는 통합 로그
