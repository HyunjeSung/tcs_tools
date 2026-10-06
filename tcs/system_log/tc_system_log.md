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
- **toupload 산출물 소멸 주의 (2026-10-06):** 인터넷 연결 상태에서는 toupload의 `.log.xz`가
  생성 직후(수 초 내) 클라우드 업로드로 지워진다. 따라서 "toupload에 파일이 남아 있는지"로
  판정하지 않는다 — 파일명/생성 여부는 journal 로그(dump 대상 파일명, `Created meta file`,
  `Merge done`, `Running daily task`)로, 내용 검증(`xz --test`)은 생성 순간 0.2초 간격으로
  복사해 두는 스냅샷 사본(`start_xz_snapshot`, TC04/05/14)으로 한다. 스냅샷 사본은 journal에
  `Created meta file: <name>.meta`(xz 성공 후에만 찍힘)가 있을 때만 "생성됨"으로 인정한다
  (`pick_completed_snapshot`) — xz 타임아웃으로 지워진 partial 사본의 거짓 PASS 방지. toupload `ls`는 참고 근거.
  TC08도 SETUP의 meta 로그를 근거로 인정한다.

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

1. SETUP: `get_log_data` 요청 전송 → `task_rotate_sync()` 실행 → toupload에 `.log.xz` 생성. 생성된 파일은
   대기 10초 안에도 클라우드 업로드로 지워질 수 있어(2026-10-06 실측), 파일명과 생성 여부는
   system_log의 `Created meta file: <name>.xz.meta` 로그(xz 성공+업로드 큐 등록)에서 확정한다
   (`SETUP_DUMP_NAME`/`SETUP_XZ_QUEUED`). SM의 `journalctl -o cat > ...` dump 줄은 누락 사례가 있어
   meta 줄이 없을 때만 파일명 보조 근거로 쓴다
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
| TC01-1 | 파일명 정규식 일치 | boolean | true | toupload 실파일, 없으면 journal로 확정한 `${SETUP_DUMP_NAME}.xz`에 `grep -qE "systemlog_[0-9]{14}_[0-9]{14}\.log\.xz"` |
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
2. toupload `.log.xz` 목록 기록 (참고 근거만 — 발화 산출물은 70초 안에 클라우드 업로드로 지워질 수 있어 판정에 쓰지 않음, 2026-10-06 실측)
3. 시스템 시간을 현재 시간과 동기화 (NTP `set-ntp yes` → 잠시 대기 → `set-ntp false` 로 변경 가능 상태)
4. 현재 epoch `t0` 저장 후 시스템 시간을 `t0 + 25*3600` 로 변경 (`date -s @<epoch>`)
5. 타이머 발화 대기 — `journalctl --since @<t_shift>`에서 `[task_rotate_sync] End of Log rotate logic`이
   나올 때까지 2초 간격 최대 70초 폴링
6. 같은 구간 journal의 `Created meta file: /edge/log/toupload/system/systemlog_<start>_<end>.log.xz.meta`에서
   파일명을 뽑아 endtime이 +25h ±120초인지 확인 (`Running daily task`·dump 명령 줄은 task_rotate_sync
   내부 `journalctl --rotate && --vacuum-files=1`이 지워버려 판정에 못 씀 — 2026-10-06 실측)
7. 시스템 시간을 현재 시간으로 복원 — 4번에서 저장해둔 `t0`에 대기 경과분을 더해 `date -s` 직접
   복원(2026-08-25 재수정, 아래 Flag 참고)
8. 미래 시각 journal 정리 — `journalctl --rotate` 후 `rm -f /var/log/journal/*/system@*.journal`로 archived
   전부 삭제(BusyBox `find`는 `-delete` 미지원). shift 중 timer rotate로 생긴 journal은 첫 기록이 +25h라, 남겨두면 이후 dump 파일명의
   시작시각이 미래로 잡혀 start>end 역전(2026-10-06 --full 실측: TC01-2 FAIL)

> **실행 순서 (2026-10-06):** 빠른/전체 실행과 `--only`에서 TC02는 SETUP·TC01·TC03~TC14 뒤에 실행한다
> (시간 이동 영향이 파일명 시각을 보는 TC에 번지지 않도록). 자체적으로 system_log를 재시작하므로
> 타이머 상태는 순서와 무관.

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
| timer 발화 | +25h 후 journal에 `Running daily task` + toupload dump 실행 |
| 파일명 endtime | 변경한 시스템 시간(+25h) 근처 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | +25h 후 timer 발화 (journal rotate 종료 + toupload .xz meta 생성) | boolean | true | `journalctl --since @t_shift` 에 `[task_rotate_sync] End of Log rotate logic` AND `Created meta file: .../systemlog_*.log.xz.meta` (task_rotate_sync 내부 rotate&&vacuum이 그 이전 줄 — `Running daily task`, dump 명령 — 을 지우므로 rotate 뒤에 찍히는 줄만 사용, 2026-10-06) |
| TC02-2 | dump 파일명 endtime이 변경 시간(+25h) ±120초 이내 | number | ≤120s | `\|endtime_epoch - t_shift\| <= 120` |

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
| TC03-1 | xz 파일 신규 생성됨 | boolean | true | `[ "$FILES_AFTER" -gt "$FILES_BEFORE" ]` OR journal `Created meta file: ${SETUP_DUMP_NAME}.xz.meta` (업로드로 즉시 소멸 대비) |

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
- `journald.conf`: `SystemMaxFileSize` 기본 64M, `SystemMaxFiles` 기본 20 — 100MB 티어는
  ~3개 파일, 200MB 티어는 ~4개 파일 필요, 둘 다 20개 한도 안에 들어감
- 디바이스 emmc 가용 공간: 100MB 티어 300MB 이상 / 200MB 티어(신규) 600MB 이상
  (journal 목표 사이즈 + dump/compress 임시공간 + premade dummy blob 상주분)
- IPC 타임아웃 (2026-09-23 갱신, `system_log.hpp:28-30`): dump/rotate 등 기본 경로는
  `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=180초`(IPC future 대기는 `+SYSTEM_LOG_TIMEOUT_MARGIN_SEC(5)`
  =185초), compress 전용은 `SYSTEM_LOG_XZ_CMD_TIMEOUT=300초`(대기 305초) — 이번 diff로
  compress만 별도 예산을 갖게 분리됨(이전엔 `SYSTEM_LOG_PUBLISH_TIMEOUT=185(고정)` 하나로
  전 커맨드 공유). 고정 매크로 `SYSTEM_LOG_PUBLISH_TIMEOUT`은 제거됨.

### 절차

**100MB(기존 회귀) / 200MB(신규, 2026-09-23 — xz -0 대용량 처리 + 신규 300초 compress
예산 검증) 두 사이즈에 대해 각각 다음을 실행:**

1. `journalctl --rotate && journalctl --vacuum-files=1` 로 journal 초기화
2. `BEFORE_LIST` = 현재 toupload `.log.xz` 파일 목록 (개수가 아니라 목록 자체를 저장)
3. `/edge/log/.tc_dummy_journal_blob`(premade 랜덤 blob, 없으면 최초 1회만 생성)에서
   사이즈에 맞는 만큼 슬라이스해 `systemd-cat -t TC04_DUMMY` 로 실데이터 주입
   - 사이즈별 raw 환산량: 70MB(100MB 티어) / ~143MB(200MB 티어, 신규) — 둘 다 ≈1.4x
     팽창 후 journal 목표 사이즈에 도달한다는 기존 실측 비율을 그대로 적용. 매번
     `/dev/urandom` 을 새로 뽑지 않고 blob에서 해당 비율만큼 `head -c` 로 잘라 재사용한다.
     journald가 요구하는 건 "systemd-cat 정상 경로로 들어온 유효한 항목"이지 내용의
     신선도가 아니므로, 한 번 생성한 고엔트로피 데이터를 재사용해도 무방하다.
4. `sync; sleep 3; journalctl --rotate; sleep 2` 로 디스크에 flush
5. `journalctl --disk-usage` 로 실제 journal 사이즈 확인
6. `get_log_data` 요청 송신, 응답을 최대 **100MB 티어는 200초, 200MB 티어는 500초**까지
   대기(실제 완료 신호). 500초는 dump(185초)+compress(305초) 이론상 최악 합산치(490초)에
   여유를 더한 값 — 정상 성공 경로에서는 이보다 훨씬 빠르게 끝나는 것이 기대치이며, 이
   상한은 "느리지만 정상 완주하는" 케이스를 오판 FAIL 하지 않기 위한 것일 뿐 목표 소요
   시간이 아니다(절대 수치를 성공 기준으로 어설션하지 않음)
7. 응답 수신 직후 `comm -13 BEFORE_LIST AFTER_LIST` 로 신규 파일을 확인한다
   (TC02와 동일한 diff 방식 — 그 사이 다른 파일이 삭제돼도 개수 비교와 달리 오판하지 않는다)
8. 신규 파일 발견 여부로 1차 PASS/FAIL 판정
9. **무결성 확인(신규):** 신규 파일에 대해 `xz --test "$NEW_XZ"` 실행 → exit code 0 확인,
   결과를 `dump_cmd`로 원문 캡처

시험 후: `journalctl --rotate && journalctl --vacuum-files=1` 로 디스크 복원.

> **알려진 제약 (2026-09-23 갱신 — 이전 버전의 "5초/7초" 서술은 현재 코드와 무관한
> 구버전 매크로값이라 삭제하고 현재 180초/300초 구조로 교체):** dump(`journalctl -o
> cat`) 단계는 `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=180초`(+5초 margin=185초) 예산을,
> compress(`xz -f -0`) 단계는 이번 diff로 분리된 `SYSTEM_LOG_XZ_CMD_TIMEOUT=300초`
> (+5초 margin=305초) 예산을 쓴다(`system_log.hpp:28-30`, `system_log.cpp:647-648`).
> `task_rotate_sync()` 안에서 두 커맨드는 순차 실행되며 각각 독립된 타임아웃 예산을
> 가지므로, 이론상 전체 응답은 최악의 경우 185+305=490초까지 걸릴 수 있다. dump가
> 180초를 넘기면 `journalctl -o cat` 이 SIGKILL 되어 `"Failed to make log!! Rotate
> logic is stopped."` 로 즉시 리턴하며 compress 단계 자체를 타지 않는다(compress
> 실패와는 다른 코드 경로). compress가 300초를 넘기면 `xz` 가 SIGKILL 되어
> `error_code=UNKNOWN` 응답과 함께 `.xz` 가 생성되지 않는다. 이 TC(TC04)는 정상 성공
> 경로만 다룬다 — 압축 실패(SIGKILL 포함 및 ENOSPC) 시 partial `.xz` 정리 로직의
> 결정적 검증은 TC15/TC16(ENOSPC fault injection으로 재설계, 2026-09-23)에서 다룬다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 (100MB) | MQTT 응답이 200초 안에 반환됨(=task_rotate_sync 완료) |
| 응답 (200MB, 신규) | MQTT 응답이 500초 안에 반환됨(=task_rotate_sync 완료, 신규 300초 compress 예산 안에서 정상 성공) |
| 파일 생성 | 응답 수신 시점에 `.log.xz` 신규 생성 확인 (양 티어 공통) |
| 무결성 (신규) | 신규 생성된 `.log.xz`가 `xz --test` 통과 (양 티어 공통) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | journal 100MB 상태에서 get_log_data 완료 응답 후 .xz 파일 생성 | boolean | true | `comm -13 BEFORE_LIST AFTER_LIST` 로 신규 파일 존재 확인 |
| TC04-2 (신규) | 100MB 티어 산출물 무결성 | exit code | 0 | `xz --test "$NEW_XZ"` |
| TC04-3 (신규) | journal 200MB 상태에서 get_log_data 완료 응답(≤500초) 후 .xz 파일 신규 생성 — 레벨0+300초 compress 예산이 실제로 대용량 성공에 쓰이는지 확인 | boolean | true | `comm -13 BEFORE_LIST AFTER_LIST` 로 신규 파일 존재 확인 |
| TC04-4 (신규) | 200MB 티어 산출물 무결성 | exit code | 0 | `xz --test "$NEW_XZ"` |


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
| TC05-1 | .xz 파일 존재 | boolean | true | 자체 `get_log_data` 동안 0.2초 간격 스냅샷(`start_xz_snapshot`)으로 잡은 신규 `.xz` 사본 존재 (업로드로 원본이 즉시 지워져도 판정 가능, 2026-10-06) |
| TC05-2 | xz 무결성 | exit code | 0 | 스냅샷 사본에 `xz --test` |
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
- `/edge/log/system/.tc10_before` 임시 파일 작성 가능 (TC10-PRE의 toupload 개수(참고용) + boot_id 저장용)

### 절차

**Phase 1 — 리부트 전 (`--tc10-pre`):**
1. `BEFORE_TOUPLOAD` = toupload `.log.xz` 파일 수 기록 (참고용), 현재 `/proc/sys/kernel/random/boot_id`와 함께 `.tc10_before`에 저장
2. `mosquitto_pub` → `shutdown_application_for_system_reboot` 요청, 60초 대기
3. 응답 수신 확인
4. staging `.log.xz` 생성 확인
5. `reboot` 실행 (SSH 연결 종료, 시리얼은 유지)

**Phase 2 — 리부트 후 (`--tc10-post`, 재접속 후 수동 실행):**
1. 현재 boot_id가 pre에서 저장한 값과 같으면 **아직 재부팅 전** → 판정 없이 `[ERROR]` 종료,
   `.tc10_before`는 보존(재부팅 후 post만 재실행 가능). reboot 직후 꺼지는 중에도 SSH가 붙어
   재부팅 전 상태로 판정한 사고(2026-10-06: post 12:44:25 판정, 실제 부팅 12:44:33) 방지
2. 현재 부팅 journal(`journalctl -b -u docker-loader`)에서 `[task_merge_staged_logs] Merge done`을
   2초 간격 최대 120초 폴링 — pre의 shutdown .xz + boot .xz 두 파일 병합이므로 `Single file`은 불인정
3. toupload `.log.xz` 목록/개수는 참고 근거로만 기록 (병합 파일이 즉시 업로드돼 사라질 수 있어
   개수 비교는 판정에 쓰지 않음)


### 기대 결과

| 항목 | 기준 |
|------|------|
| 응답 수신 (pre) | MQTT 응답 수신 |
| staging .xz (pre) | 신규 생성됨 |
| 병합 (post) | 현재 부팅 journal에 `Merge done` |

### PASS/FAIL Criteria

| 기준 ID | 단계 | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|------|--------|---------|
| TC10-1 | pre | 응답 수신 | boolean | true | `[ -n "$resp" ]` |
| TC10-2 | pre | staging .xz 생성 | boolean | true | `ls /edge/log/system/systemlog_*.log.xz` |
| TC10-3 | post | 재부팅 후 shutdown+boot 로그 병합됨 | boolean | true | boot_id ≠ pre AND `journalctl -b -u docker-loader -o cat \| grep -F "[task_merge_staged_logs] Merge done"` |

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
| TC12-3 | 40일 mtime `.nmon.meta` 잔존 허용 (retention 삭제 대상 아님, 2026-10-06 확정 — 판정 게이트 아님, 잔존 개수만 기록) | informational | 항상 PASS | 3 디렉토리 `ls -la` 원문 기록 |
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
7. `task_merge_staged_logs` 실행 → 3개 파일 병합 → toupload 이관. 재시작 시각 이후 journald에서
   `[task_merge_staged_logs] (Merge done|Single file|No staged files|Failed|Exception)` 종료 로그를
   2초 간격 최대 300초 폴링 (merge는 boot capture dump+compress 뒤에 돌아 90초 고정 대기로는
   부족했음 — 2026-10-06 run 실측)
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
| TC14-5 | 병합 결과에 더미 A/B가 정확히 1번씩 포함 — 재귀/자기복사 증가 없음 + `.merging_*.tmp` 잔존 없음 (2026-10-06 추가) | boolean | true | 더미 내용에 고유 마커(`TC14_DUMMY_A_n`/`TC14_DUMMY_B_n`, 각 2000줄)를 넣고 `xz -dc "$NEW_XZ" \| grep -c` 가 각각 정확히 2000. 병합은 .xz 스트림 바이트 연결이라, 예전 merge 버그(병합 결과 경로가 입력과 같아 자기복사 → 무한 증가, `repro_merge_bug.sh`)가 재발하면 중복돼 2000을 넘는다. 중복된 결과도 `xz --test`는 통과하므로 TC14-4만으로는 못 잡음(로컬 재현 확인) |

---

## TC15 — task_rotate_sync: compress 실패 시 raw .log 보존 (toupload)

> **⚠️ Flag — 인프라 재현 불안정 (2026-09-26 실측, qa 4회 시도 후 보류):** ENOSPC
> margin을 5%(~0.56MB) → 30%/20MiB 하한(~21MB) → 10%/10MiB 하한(중간값)으로 3차례
> 재조정하며 4번 실행한 결과: 1차 ENOSPC 전혀 미발생(정상 성공), 2차 dump 단계에서
> ENOSPC(TC15-4 FAIL, 의도한 compress 실패 경로 아님), 3차 다시 ENOSPC 미발생
> (manual_xz_exit=0), 4차(중간값) 다시 dump 단계 ENOSPC(TC15-4만 FAIL, 나머지 7개
> PASS) — "dump는 항상 성공하되 compress만 ENOSPC로 실패"하는 안정적인 margin 값을
> 4회 시도로 못 찾았다. dump_size 대비 margin 1~2MB 수준의 매우 좁은 구간(추정)을
> 정적 퍼센트/고정값으로 겨냥하는 현재 방식 자체의 한계로 보인다 — 후속 조치로
> "compress 시작 직전 실측 여유공간 기반 동적 계산"(예: 측정된 xz 실제 출력 크기의
> 1.2배만 남기고 compress 직전에 filler를 추가/조정하는 2단계 방식) 등 TC 로직 자체의
> 재설계가 필요할 수 있음 — 다음 세션에서 이어서 진행. **TC16도 TC15와 동일한
> `tc_disk_fill_for_enospc()` 메커니즘을 공유하므로 같은 불안정성이 있을 것으로
> 예상되며, 시간 관계상 이번 세션에서 별도 재현/재보정을 시도하지 않았다.** 이
> Flag가 해소되기 전까지 TC15/TC16의 compress-ENOSPC 특정 어설션(TC15-4/16-4)은
> "인프라 재현 불안정"으로 간주하고, TC15-1~3/5~7·TC16-1~3/5~7(파일 상태/수동
> 재현/vacuum/복원)이 매 실행 PASS라는 점으로 최소한의 신뢰도만 확보한다.

### 목적

`task_rotate_sync()`가 압축 실패 시:
1. 원본 raw `.log`를 삭제하지 않고 보존
2. 잘린 partial `.log.xz`는 제거
3. 실패 사이클에 대해 `.meta`는 생성하지 않음(업로드 큐 미등록)
4. **vacuum은 compress 성공/실패와 무관하게 항상 실행**됨 (`--list-boots` head 이동으로 확인)

을 검증한다.

> **Flag — 재설계 사유 (2026-09-23, xz -0 + compress 전용 300초 타임아웃 분리 반영):**
> `xz -f -0`(레벨0, `system_log.hpp:34`) + 압축 전용 타임아웃 분리
> (`SYSTEM_LOG_XZ_CMD_TIMEOUT=300초`, `:29`)로 인해 기존 "raw 400MB 주입 → dump+compress
> 합쳐 (구)180초 공유 타임아웃 초과 유도" 방식은 더 이상 compress 실패를 결정적으로
> 재현하지 못한다. 근거:
> - `task_rotate_sync()`는 `request_make_log()`(dump, `journalctl -o cat`, 타임아웃
>   180초·이번 diff로 불변, `system_log.cpp:427-431`) → `request_compress_log()`(xz,
>   이번 diff로 300초+레벨0, `:438-444`) 순서로 **서로 다른 예산을 가진 독립된 두
>   커맨드**를 순차 호출한다. dump가 실패하면 `"Failed to make log!!"`로 즉시 리턴하며
>   compress 단계 자체를 타지 않는다 — 이 경우 이 TC가 검증하려는 "compress 실패 시
>   partial `.xz` 정리"(`fs::remove(file_path + ".xz")`, `:441-443`) 코드는 아예
>   실행되지 않는다 — 겉보기 증상(raw `.log`는 남고 `.xz`는 없음)은 비슷해도 의도한
>   코드 경로를 타지 않는 거짓 PASS 위험이 있다.
> - 실측 처리량: dump(`journalctl -o cat`) ≈ 4MB/s(raw 400MB 기준 ~100초), xz -0 ≈
>   8.8MB/s(field 샘플 129MB→14.8초) — xz가 dump보다 빠르므로 주입량을 키워도 dump
>   (180초, 불변)가 xz(300초)보다 먼저 타임아웃 경계에 도달한다. 계산상 dump가 180초에
>   걸리려면 raw ≈720MB 필요, xz -0이 300초에 걸리려면 raw ≈2.64GB 필요 —
>   journald 기본 설정(`SystemMaxFileSize 64M × SystemMaxFiles 20 ≈ 1.28GB`)상 2.64GB는
>   애초에 달성 불가능하고, 720MB도 디바이스 여유공간(관측 1.6GB, premade blob 상주분
>   포함)상 안전마진이 부족하다. raw 400MB를 그대로 두면 dump(~100초 성공) →
>   compress(레벨0, 300초 예산 내 실측 처리량 기준 수십 초 내 성공 가능) → **정상 성공
>   경로**가 될 가능성이 높아 TC15-2("partial `.xz` 없어야 함")가 실제로는 정상 `.xz`가
>   생겨 FAIL로 오판정될 위험이 크다.
> - 요구사항 문서가 제시한 3가지 대안((a) ENOSPC 결정적 fault injection, (b) raw를
>   dump가 180초를 넘는 지점(~700~900MB대)까지 올려 재현선회, (c) 목적 재정의+별도 TC
>   신설) 중 **(a)를 채택**했다. (b)는 "compress 실패"가 아니라 "dump 실패"를 재현하게
>   되어 TC 목적(요구사항 자체가 "compress 실패" 시나리오)과 검증 코드 경로가 어긋나고,
>   디바이스 여유공간(1.6GB)상 720MB+ 주입은 안전마진이 부족하다. (c)는 회귀와 신규
>   경로를 분리하는 장점은 있으나, (a)로 새 TC 신설 없이도 몇 초 안에 동일한 결정성을
>   달성할 수 있어 불필요한 분리로 판단했다. (a)는 TC18(저장공간 부족 cleanup)이 같은
>   파티션에 대해 "동적 계산 + 안전 상한 + 복원 검증" 패턴을 이미 실전 검증해둔 전례가
>   있어 재사용 리스크가 낮고, compress가 "왜" 실패했는지와 무관하게 다운스트림 정리
>   로직이 동일하게 타므로 검증 목적에 더 정확히 부합한다(요구사항 원문 판단과 동일).

### 사전 조건

- 공통 전제 조건 충족
- `systemd-cat`, `journalctl --rotate`/`--vacuum-files` 권한(root)
- `df -P`, `dd`(또는 `fallocate`), `stat -c %d`(device id 비교용) 사용 가능
- **예외 케이스 전용 파괴적 시험 — TC18/TC20보다 공격적임(대상 파티션 여유공간을
  일시적으로 0%에 가깝게까지 소진):** `/edge/log`(`SYSTEM_LOG_STAGING_DIR`가 속한
  파티션) 여유공간을, 측정된 dump 산출물 크기 + 안전마진만 남기고 거의 다 채운다.
  안전 상한(`TC15_MAX_FILL_MB`, 기본 6144MB — **2026-09-23 실측 조정**: `/edge/log`는
  루트파티션(`/`)과 별개인 전용 파티션(`mmcblk2p9`, 실측 5.9GB total)이라 최초 초안의
  1536MB 상한은 루트파티션 df 기준 오추정이었다. TC18이 같은 파티션에서 "여유율
  85%→9%까지 약 4.55GB 더미"를 이미 실전 검증했으므로 `TC18_MAX_FILL_MB=6144`를
  그대로 재사용)을 넘기면 df 파싱 이상 등 극단적 상황으로 보고 더미 생성 없이 SKIP.
  시험 시작 시점 여유공간이 예상 dump 산출물 크기(절차 2~3번, raw 8MB 기준 수 MB대) +
  최소 여유마진(20MiB) 미만이면 진행 자체가 무의미하므로 SKIP. **실측 참고**: 판정
  자체(ENOSPC 유발~복구 확인)는 수 초~수십 초 안에 끝나지만, GB급 filler 채우기/삭제
  (`dd`)가 TC18과 비슷한 규모로 대부분의 소요 시간(수 분~10분대)을 차지한다.
- **filler는 반드시 `SYSTEM_LOG_STAGING_DIR`(`/edge/log/system`)와 `SYSTEM_LOG_PATH`
  (`/edge/log/toupload/system/`) 트리 바깥에 배치**(`/edge/log/.tc15_disk_filler/` —
  기존 premade blob(`/edge/log/.tc_dummy_journal_blob`)과 동일한 "형제 디렉토리" 위치
  관례). 이 두 트리 안에 filler를 두면 최근 반영된 로그 디스크 예산 circuit breaker
  (`task_check_disk_budget()`, `system_log.hpp:38-40`, `system_log.cpp:524-561`,
  하드리밋 2560MiB)가 먼저 트립돼 `request_dump_journal()` 자체가
  `log_disk_guard_tripped_`에 막혀 스킵되는(TC20과 동일 코드 경로) 별개 실패 사유가
  섞일 수 있다 — 이 TC가 검증하려는 "compress ENOSPC 실패"와 무관한 오염이므로 반드시
  회피할 것.
- 측정용 임시 덤프 위치(`/tmp/tc15_measure_dump.log`)가 `/edge/log`와 **다른 파티션
  (device id)**인지 `stat -c %d`로 사전 확인 — 같은 파티션이면 측정 자체가 타깃
  여유공간을 갉아먹으므로 SKIP(TC18이 `/tmp/tc18_journal_capture.log`를 이미 같은
  전제로 사용 중인 전례를 재사용)
- 다른 TC와 동시 실행 금지(TC04/TC12/TC18/TC20 등 같은 파티션을 전제하는 TC 전부)
- 의존 TC 없음 (독립 실행 가능)

### 절차

**Phase 0 — 측정 및 사전 조건 계산**

0. `wait_system_log_idle 300` — system_log의 `journalctl -o cat`/`xz -f` 호스트 명령이 5초 연속
   안 보일 때까지 최대 300초 대기. 직전 TC 재시작으로 시작된 boot capture가 fill 도중 ENOSPC로
   실패하며 partial .xz를 지우면 공간이 돌아와 ENOSPC가 재현되지 않음(2026-10-06 run 실측)

1. `journalctl --rotate && journalctl --vacuum-files=1`로 journal 초기화
2. `/edge/log/.tc_dummy_journal_blob`(TC04와 공유하는 premade 랜덤 blob, 없으면 최초
   1회만 생성)에서 `head -c 48M`으로 48MB 슬라이스해 (2026-09-23 실측 조정: 8MB는 dump/compress 안전 마진이 너무 좁아 fill 오차로 dump 단계에서부터 ENOSPC 발생 — 48MB로 상향해 안전 구간 확보) `systemd-cat -t TC15_ENOSPC_DUMMY`
   로 주입(예전처럼 400MB 전체를 주입할 필요 없음 — ENOSPC 유발에는 소량이면 충분하고,
   raw 400MB 상당 원본 blob 자체는 TC04와 공유하므로 그대로 둔다) →
   `sync; sleep 3; journalctl --rotate; sleep 2`
3. **측정 덤프**: `journalctl -o cat > /tmp/tc15_measure_dump.log` 실행 후
   `DUMP_SIZE_BYTES` = 파일 크기 확인, 파일 삭제. 같은 journal 상태에서 앱이 내부적으로
   실행할 것과 동일한 커맨드를 미리 한번 실행해보는 것이므로, 실제 트리거 시 산출물
   크기와의 편차는 그 사이 수 초간 유입되는 소량의 일반 시스템 로그뿐이다.
4. `df -P /edge/log`로 `AVAIL0_BYTES`(현재 여유 바이트) 확인
5. `RESERVE_BYTES` = `DUMP_SIZE_BYTES` + `max(256KiB, DUMP_SIZE_BYTES*5%)` (dump
   산출물 자체 + 측정-실행 사이 오차 마진)
6. 사전 조건 확인: `AVAIL0_BYTES > RESERVE_BYTES + 20MiB`(SKIP 문턱) AND
   `(AVAIL0_BYTES - RESERVE_BYTES) <= TC15_MAX_FILL_MB*1MiB`(6144MB, 안전 상한) —
   미충족 시 TC15-0 FAIL 기록 후 더미 생성 없이 즉시 종료(SKIP)
7. `FILLER_BYTES` = `AVAIL0_BYTES - RESERVE_BYTES`

**Phase 1 — disk 채우기 및 트리거**

8. `mkdir -p /edge/log/.tc15_disk_filler` 후 `dd if=/dev/zero
   of=/edge/log/.tc15_disk_filler/fill_NN bs=1M count=... conv=fsync` (또는
   `fallocate -l`) 반복으로 `FILLER_BYTES`만큼 채움 — 여러 개 파일로 분할(TC18 관례,
   단일 거대 파일보다 중간 실패 시 진행 상태를 진단하기 쉬움)
9. `df -P /edge/log`로 채운 후 여유공간이 `RESERVE_BYTES` 근방인지 확인 — `dump_cmd`로
   원문 캡처
10. `BEFORE_HEAD` = `journalctl --list-boots | head -n1` 기록, toupload `.log`(xz
    아닌) 목록 스냅샷(`BEFORE_LIST`)
> **[2026-10-06] keep-full 재충전:** journal이 `/var/log` → `/edge/log/system`, 즉 filler로 채우는 같은
> 파티션에 있다. system_log는 dump → `journalctl --rotate && --vacuum-files=1` → xz 순서라 vacuum이 지난
> journal(주입한 48MB 포함)을 지우며 공간이 다시 생겨 xz가 성공해버리는 비결정성이 있었다(R090127 실측
> 4회 중 2회 성공). 트리거 직전 archived journal 목록이 사라지는 순간(= vacuum 완료)부터 백그라운드
> (`start_keep_full`)가 0.5초마다 true-free를 16MB만 남기고 다시 채워(`keep_*.bin`, filler 디렉토리 안)
> 이후 xz를 결정적으로 ENOSPC로 만든다. vacuum 전에는 손대지 않아 dump는 계획한 RESERVE 안에서 성공한다.
> 16MB는 journald가 판정 근거 로그를 계속 기록할 여유. 재충전 기록은 cleanup 직전 output.log에 남긴다.

11. `get_log_data` 요청 송신, 최대 300초 대기 — 응답은 task_rotate_sync 종료 후에 오므로 곧 compress
    결과 확정 신호. ENOSPC 도달 시간은 xz 레벨에 좌우(xz -0 빌드는 수 초, 기본 레벨 R090127은 127초
    실측)되어, 90초 대기로는 partial .xz가 아직 쓰이는 중에 판정한 오판이 있었음(2026-10-06)
12. 응답 후 5초 추가 대기(안정화)
13. before/after 목록 diff로 이번 사이클이 만든 신규 raw `.log`(`NEW_LOG`) 식별

**Phase 2 — 검증**

14. `NEW_LOG` 존재 확인, `${NEW_LOG}.xz` / `${NEW_LOG}.xz.meta` 부재 확인
15. journald(`docker-loader`)에서 `"[task_rotate_sync] Failed to compress log!!
    Keeping raw .log, removing partial .xz."` ERROR 로그를 `dump_cmd`로 캡처(코드
    원문 `system_log.cpp:440`과 정확히 일치 — dump 실패 메시지(`"Failed to make
    log!!"`)가 대신 나타나면 이 TC가 의도한 코드 경로가 아니므로 별도 FAIL로 구분 기록)
16. **결정적 재확인 (명령 실행 결과 근거):** 디스크가 아직 거의 가득 찬 상태에서
    `xz --keep -0 -v "$NEW_LOG"; echo "manual_xz_exit=$?"` 를 직접 실행해 stderr에
    `"No space left on device"` 문자열과 exit code≠0을 `dump_cmd`로 그대로 캡처 —
    14/15번이 간접 증거(파일 상태·앱 로그)인 데 반해 이 단계는 동일 조건에서 ENOSPC를
    직접 재현한 명령 실행 결과 자체를 근거로 남긴다(수동 재시도가 우연히 성공하면
    — 여유공간이 예상보다 넉넉했다는 뜻이므로 — 그 결과도 있는 그대로 기록하고
    마진 재조정이 필요함을 evidence에 남김)
17. `AFTER_HEAD` = `journalctl --list-boots | head -n1` → `BEFORE_HEAD`와 비교

**Phase 3 — 복원 (반드시 실행, 실패/조기종료 경로 포함)**

18. 16번의 수동 `xz --keep` 시도가 만든 산출물 정리: `rm -f "${NEW_LOG}.xz"`
19. `rm -rf /edge/log/.tc15_disk_filler` — filler 전량 삭제
20. `NEW_LOG` 삭제
21. `journalctl --rotate && journalctl --vacuum-files=1`로 journal 재초기화
22. `df -P /edge/log`로 여유공간이 `AVAIL0_BYTES` 근방(±5%)으로 복원됐는지 확인 —
    복원 실패 시 즉시 사용자에게 알리고 잔존 filler 유무 재확인(영구 잔재 방지가 이
    TC의 필수 요건)

> **주의(스크립트 구현 필수 요건):** 18~22번(복원)은 14~16번의 PASS/FAIL 결과와
> 무관하게 **항상** 실행돼야 한다(`trap ... EXIT` 또는 동등한 구조로 tc-dev가 구현).
> 이 TC는 파괴적 시험이므로 도중에 스크립트가 죽거나 assertion이 FAIL해도 디바이스에
> filler/raw 더미가 영구 잔존해서는 안 된다.

### 기대 결과

| 항목 | 기준 |
|------|------|
| raw `.log` | toupload에 신규 생성되어 보존됨 |
| partial `.xz` | 존재하지 않음 |
| `.meta` | 존재하지 않음 |
| ERROR 로그 | compress 실패 경로(`Failed to compress log!!`) 로그 등장, dump 실패 경로 아님 |
| 수동 재현 | `xz --keep` 재시도가 `No space left on device`로 실패(exit≠0) |
| list-boots head | BEFORE와 다름 (vacuum 실행 증거) |
| 복원 | filler 전량 삭제, 여유공간 `AVAIL0_BYTES` 근방 회복 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC15-0 | 사전 조건 충족(여유공간>RESERVE+20MiB AND FILLER_BYTES≤6144MB) — 미충족 시 이후 절차 생략(SKIP) | boolean | true | df/측정값 기반 계산 |
| TC15-1 | 압축 실패 후 raw `.log`가 toupload에 보존됨 | boolean | true | `[ -f "$NEW_LOG" ]` |
| TC15-2 | 깨진 partial `.xz`는 남지 않음 | boolean | true | `[ ! -f "${NEW_LOG}.xz" ]` |
| TC15-3 | `.meta` 생성되지 않음 | boolean | true | `[ ! -f "${NEW_LOG}.xz.meta" ]` |
| TC15-4 | compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님 | boolean | true | `journalctl -u docker-loader \| grep -F "[task_rotate_sync] Failed to compress log!!"` 매치 AND `Failed to make log!!` 없음 |
| TC15-5 | 수동 재현: `xz --keep -0` 이 ENOSPC로 실패 | boolean | true | `manual_xz_exit -ne 0` AND stderr에 `No space left on device` 포함 |
| TC15-6 | compress 실패와 무관하게 vacuum 실행됨 | boolean | true | 트리거 직전 `/var/log/journal/*/system@*.journal`(archived) 목록 ≥1개가 트리거 후 전부 삭제됨(`comm -12` 잔존 0). 예전 판정(`list-boots` 첫 줄 비교)은 시간만 지나도 바뀌어 vacuum 여부와 무관하게 PASS 났음(2026-10-06 교체) |
| TC15-7 | 정리 후 filler 잔재 없음 + 여유공간 AVAIL0의 95% 이상 복원 | boolean | true | `[ ! -d /edge/log/.tc15_disk_filler ]` AND `df -P /edge/log` 재확인값 ≥ AVAIL0×95% (상한 없음 — 업로드/vacuum으로 늘어나는 건 정상) |

---

## TC16 — task_capture_boot_log: compress 실패 시 raw .log 보존 (staging)

### 목적

`system_log` 재시작 시 무조건 실행되는 `task_capture_boot_log()`가 compress 실패 시 TC15와 동일한 보존 규칙을 따르는지, 그리고 남은 raw `.log`가 `task_merge_staged_logs()`에 의해 toupload로 잘못 이관(오염)되지 않는지 검증한다. TC14(RTC 이상 병합)와 같은 `kill -9` 재시작 기법을 재사용한다.

`task_capture_shutdown_log`는 동일 코드 패턴이라 이번 범위에서 제외(코드 리뷰로 대체).

> **Flag — 재설계 사유 (2026-09-23):** TC15와 동일 이유(xz -0 + compress 전용 300초
> 타임아웃 분리로 기존 "raw 400MB 주입 → 180초 공유 타임아웃 초과" 방식이 더 이상
> compress 실패를 결정적으로 재현하지 못함)로, TC15와 동일한 ENOSPC 결정적 fault
> injection 방식으로 전환한다. 상세 근거는 TC15 목적 섹션의 Flag 참고 — 여기서는
> 반복하지 않는다. `task_capture_boot_log()`의 compress 실패 처리
> (`system_log.cpp:733-739`)는 `task_rotate_sync()`와 동일한 패턴
> (`fs::remove(log_path + ".xz")` + raw `.log` 보존)이므로 TC15와 같은 기법이 그대로
> 적용된다.
>
> **추가 Flag — kill -9 재시작 특유의 확인 필요 사항:** TC16은 재시작을 트리거로 쓰므로,
> `task_capture_boot_log()` 실행 전에 시작 시퀀스의 앞 단계들
> (`delete_old_journals()`→`task_cleanup_logs()`→`task_check_disk_budget()`,
> `system_log.cpp:900-936`, TC20 문서 참고)이 먼저 돈다. 이 중
> `task_cleanup_logs()`가 부르는 `cleanup_if_low_disk_space()`(여유율<10%에서 발화)는
> 이 TC의 filler로 인해 함께 트립될 수 있으나, `SYSTEM_LOG_DIRS`(archive/toupload/
> staging)만 순회하고 filler는 그 바깥에 있어 filler 자체는 삭제 대상이 아니다(TC18과
> 동일 근거). 다만 staging/toupload/archive에 이 TC가 만든 것 외의 잔존 파일이 있으면
> 그걸 지워 여유공간을 우리가 계산한 것보다 더 회복시킬 수 있고, 이론상 compress가
> 성공할 여지를 조금 넓힐 수 있다 — 그래서 절차 1번에서 staging/toupload를 미리
> 클린업해 이 간섭 가능성을 최소화한다(완전히 배제하지는 못함, informational 성격의
> 잔여 리스크로 문서화).

### 사전 조건

- 공통 전제 조건 충족
- `pgrep`, `kill -9` 사용 가능, edge_runtime이 system_log 재시작시키는 상태
- `systemd-cat`, `journalctl --rotate`/`--vacuum-files` 권한(root)
- `df -P`, `dd`(또는 `fallocate`), `stat -c %d` 사용 가능
- TC15와 동일한 예외 케이스 전용 파괴적 시험 전제(대상 파티션 여유공간을 일시적으로
  0%에 가깝게까지 소진) — 안전 상한 `TC16_MAX_FILL_MB`(기본 6144MB), 미충족 시 SKIP
- filler는 TC15와 동일 이유로 `SYSTEM_LOG_STAGING_DIR`/`SYSTEM_LOG_PATH` 트리 바깥
  (`/edge/log/.tc16_disk_filler/`)에 배치 — 디스크 예산 circuit breaker 오트립 방지
- 측정용 임시 덤프(`/tmp/tc16_measure_dump.log`)가 `/edge/log`와 다른 파티션인지
  `stat -c %d`로 사전 확인
- 다른 TC와 동시 실행 금지(TC04/TC12/TC15/TC18/TC20 등)
- 의존 TC 없음 (독립 실행 가능, TC15 실행 여부와 무관)

### 절차

**Phase 0 — 측정 및 사전 조건 계산**

0. `wait_system_log_idle 300` — system_log의 `journalctl -o cat`/`xz -f` 호스트 명령이 5초 연속
   안 보일 때까지 최대 300초 대기. 직전 TC 재시작으로 시작된 boot capture가 fill 도중 ENOSPC로
   실패하며 partial .xz를 지우면 공간이 돌아와 ENOSPC가 재현되지 않음(2026-10-06 run 실측)

1. staging/toupload 클린업 (`systemlog_*.log.xz`, `*.log`, `.merging_*.tmp` 제거 —
   위 Flag 참고, cleanup_if_low_disk_space 간섭 최소화 목적 겸 BEFORE 목록 정리)
2. `journalctl --rotate && journalctl --vacuum-files=1`로 journal 초기화
3. `/edge/log/.tc_dummy_journal_blob`(TC04/15와 공유하는 premade 랜덤 blob)에서
   `head -c 48M`으로 48MB 슬라이스해 (2026-09-23 실측 조정: 8MB는 dump/compress 안전 마진이 너무 좁아 fill 오차로 dump 단계에서부터 ENOSPC 발생 — 48MB로 상향해 안전 구간 확보) `systemd-cat -t TC16_ENOSPC_DUMMY`로 주입 →
   `sync; sleep 3; journalctl --rotate; sleep 2`
4. **측정 덤프**: `journalctl -o cat > /tmp/tc16_measure_dump.log` 실행 후
   `DUMP_SIZE_BYTES` 확인, 파일 삭제 (TC15-절차3과 동일 원리)
5. `df -P /edge/log`로 `AVAIL0_BYTES` 확인, `RESERVE_BYTES` = `DUMP_SIZE_BYTES` +
   `max(256KiB, DUMP_SIZE_BYTES*5%)`
6. 사전 조건 확인: `AVAIL0_BYTES > RESERVE_BYTES + 20MiB` AND
   `(AVAIL0_BYTES - RESERVE_BYTES) <= TC16_MAX_FILL_MB*1MiB`(6144MB) — 미충족 시
   TC16-0 FAIL 기록 후 더미 생성 없이 즉시 종료(SKIP)
7. `FILLER_BYTES` = `AVAIL0_BYTES - RESERVE_BYTES`

**Phase 1 — disk 채우기 및 재시작 트리거**

8. `mkdir -p /edge/log/.tc16_disk_filler` 후 `dd`/`fallocate`로 `FILLER_BYTES`만큼
   여러 파일로 분할 채움(TC15-절차8과 동일)
9. `df -P /edge/log`로 채운 후 여유공간이 `RESERVE_BYTES` 근방인지 `dump_cmd`로 확인
10. 트리거 직전 archived journal 목록(`/var/log/journal/*/system@*.journal`) 기록 + `start_keep_full`
    시작(TC15 keep-full 재충전 Flag와 동일 — vacuum 후 여유공간 재충전으로 xz ENOSPC 결정화.
    R09 빌드는 재시작 직후 `cleanup_if_low_disk_space`가 실제 로그를 지워 공간을 비우는 것도
    재충전이 다시 메운다, 2026-10-06 실측)
11. `kill -9 $(pgrep -f /edge/app/bin/system_log)` → edge_runtime 재시작 →
    `task_capture_boot_log()` 무조건 실행
12. 최대 180초까지 journald를 2초 간격으로 폴링해 `[task_capture_boot_log] Done:`
    또는 `Failed to compress log` 완료 신호를 기다림 (ENOSPC 자체는 수 초지만 kill 후
    docker-loader 종료→재기동에 ~70초 걸린 사례가 있어 60→180초로 확대, 2026-10-06)

**Phase 2 — 검증**

13. staging에서 신규 raw `.log`(`NEW_LOG`) 확인
14. `${NEW_LOG}.xz` 부재 확인
15. `NEW_LOG`와 동일 베이스네임이 toupload로 잘못 넘어가지 않았는지 확인(merge 오염
    방지 검증, 기존 TC16-3과 동일 목적)
16. journald(`docker-loader`)에서 `"[task_capture_boot_log] Failed to compress log,
    keeping raw .log for diagnostics: ${NEW_LOG}"` ERROR 로그를 `dump_cmd`로 캡처
    (코드 원문 `system_log.cpp:735`와 정확히 일치 — dump 실패 메시지(`"Failed to dump
    log"`, `:724`)가 대신 나타나면 의도한 코드 경로가 아니므로 별도 FAIL로 구분 기록)
17. **결정적 재확인 (명령 실행 결과 근거):** `xz --keep -0 -v "$NEW_LOG"; echo
    "manual_xz_exit=$?"` 직접 실행해 stderr `"No space left on device"` + exit≠0을
    `dump_cmd`로 캡처 (TC15-절차16과 동일 원리)
18. `AFTER_HEAD` 비교

**Phase 3 — 복원 (반드시 실행)**

19. 17번이 만든 `${NEW_LOG}.xz` 삭제
20. `rm -rf /edge/log/.tc16_disk_filler`
21. `NEW_LOG` 삭제 — **기존 버전과 달리 로그 확인 여부와 무관하게 항상 삭제**(증거는
    16/17번에서 이미 `dump_cmd`로 원문 캡처했으므로, "진단용 보존"을 이유로 디바이스에
    파일을 남기지 않는다 — 파괴적 시험은 영구 잔재를 남겨서는 안 된다는 원칙 우선)
22. `journalctl --rotate && journalctl --vacuum-files=1`로 journal 재초기화
23. `df -P /edge/log`로 여유공간이 `AVAIL0_BYTES` 근방(±5%)으로 복원됐는지 확인

> **주의(스크립트 구현 필수 요건):** TC15와 동일 — 19~23번(복원)은 13~18번의
> PASS/FAIL 결과와 무관하게 **항상** 실행돼야 한다(`trap ... EXIT`).

### 기대 결과

| 항목 | 기준 |
|------|------|
| raw `.log` | staging에 신규 생성되어 보존됨 |
| partial `.xz` | 존재하지 않음 |
| toupload 오이관 | 없음 |
| ERROR 로그 | compress 실패 경로 로그 등장, dump 실패 경로 아님 |
| 수동 재현 | `xz --keep` 재시도가 `No space left on device`로 실패(exit≠0) |
| list-boots head | BEFORE와 다름 |
| 복원 | filler 전량 삭제, 여유공간 `AVAIL0_BYTES` 근방 회복 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC16-0 | 사전 조건 충족(여유공간>RESERVE+20MiB AND FILLER_BYTES≤6144MB) — 미충족 시 이후 절차 생략(SKIP) | boolean | true | df/측정값 기반 계산 |
| TC16-1 | 압축 실패 후 raw `.log`가 staging에 보존됨 | boolean | true | `[ -f "$NEW_LOG" ]` |
| TC16-2 | 깨진 partial `.xz`는 남지 않음 | boolean | true | `[ ! -f "${NEW_LOG}.xz" ]` |
| TC16-3 | raw `.log`가 toupload로 잘못 이관되지 않음 | boolean | true | `find "${TOUPLOAD_DIR}" -name "$(basename "$NEW_LOG")*"` 결과 없음 |
| TC16-4 | compress 실패 경로(ENOSPC) ERROR 로그 등장, dump 실패 메시지 아님 | boolean | true | `journalctl -u docker-loader \| grep -F "[task_capture_boot_log] Failed to compress log, keeping raw .log for diagnostics:"` 매치 AND `Failed to dump log` 없음 |
| TC16-5 | 수동 재현: `xz --keep -0` 이 ENOSPC로 실패 | boolean | true | `manual_xz_exit -ne 0` AND stderr에 `No space left on device` 포함 |
| TC16-6 | compress 실패와 무관하게 vacuum 실행됨 | boolean | true | TC15-6과 동일 — 트리거(kill) 직전 archived journal 목록이 boot capture 후 전부 삭제됨 |
| TC16-7 | 정리 후 filler 잔재 없음 + 여유공간 AVAIL0의 95% 이상 복원 | boolean | true | `[ ! -d /edge/log/.tc16_disk_filler ]` AND `df -P /edge/log` 재확인값 ≥ AVAIL0×95% (상한 없음 — 업로드/vacuum으로 늘어나는 건 정상) |

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

## TC18 — 저장공간 부족(<10%) 시 SYSTEM_LOG_DIRS cleanup (R09 전용)

> **[2026-10-02] R09 전용으로 복구.** main에서는 `delete_if_low_disk_space()`/`delete_oldest_files_until_safe()`가 제거돼 2026-09-23에 삭제됐던 TC이나, R090125 백포트 커밋(`309e4e2`, EWP-2698)에는 `cleanup_log_dir()`/`cleanup_nmon_dir()` → `cleanup_if_low_disk_space(path, 10)` → `delete_oldest_files_until_safe(path, 20)` 경로가 그대로 남아있어 tcs_tools `720df12` 버전을 되살렸다. **TC18-0에 빌드 가드 추가**: 실행 중 system_log 바이너리(`/proc/<pid>/exe`)에 `[cleanup_if_low_disk_space]` 문자열이 없으면(main 계열 빌드) 파티션을 채우기 전에 SKIP 한다.

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
| TC18-0 | 사전 조건 충족(실행 중 바이너리에 `[cleanup_if_low_disk_space]` 존재 AND 여유율≥25% AND 필요 소진량≤안전상한 6144MB) — 미충족 시 이후 절차 생략(SKIP) | boolean | true | `grep -caF "[cleanup_if_low_disk_space]" /proc/<pid>/exe` ≥1 + df 파싱값 기반 계산 |
| TC18-1 | 더미 배치로 파티션 여유율이 10% 미만으로 낮춰짐 | boolean | true | `[ "$after_permille" -lt 100 ]` |
| TC18-2 | SYSTEM_LOG_DIRS 중 최소 1곳에서 더미 파일 개수가 실제로 감소함 (filesystem 관점 증거, TC18-4의 journal 증거와는 독립 채널) | boolean | true | `staging_removed>=1 \|\| toupload_removed>=1 \|\| archive_removed>=1` (각 `생성개수 - 잔존개수`) |
| TC18-4 | journald에 SYSTEM_LOG_DIRS 중 1곳 이상의 `[cleanup] Removing:` 로그 존재 (실제 cleanup 코드 경로로 삭제됐다는 직접 증거) | boolean | true | 3개 디렉토리 접두어(`tc18_dummy_staging_`/`toupload_`/`archive_`) 중 1개 이상 `journalctl -u docker-loader \| grep -F '[cleanup] Removing:'` 결과에 매치 |
| TC18-3 | 여유율이 20% 이상으로 회복됨 | boolean | true | 1순위: journal `[cleanup] Enough space recovered: X%`의 X ≥ 20 (코드가 `fs::space` available/capacity로 직접 측정한 값). 로그 없을 때만 `[ "$cur_permille" -ge 200 ]`. 회복 직후 `task_capture_boot_log`가 staging에 dump+xz를 써서 df 재측정값이 20% 바로 아래로 떨어질 수 있어 df는 참고 근거(2026-10-06 실측: 로그 20.2767% / df 197‰) |

---

## TC19 — 로그 디스크 예산 watermark 타당성 근거 수집 (informational)

### 목적

`LOG_DISK_BUDGET_HARD_LIMIT_BYTES`(2560MiB, 2.5GiB) / `LOG_DISK_BUDGET_LOW_WATERMARK_BYTES`
(2304MiB, 2.25GiB, `system_log.hpp:37-38`)는 dev가 TC04 실측(dump 크기 70~210MB)만으로
잠정 추정한 값이다. 이 TC는 그 값 자체를 변경하거나 PASS/FAIL로 재단하지 않고, 실기기의
실제 dump 산출물(`SYSTEM_LOG_STAGING_DIR`=`/edge/log/system`, `SYSTEM_LOG_PATH`=
`/edge/log/toupload/system/`) 크기 분포·현재 총 사용량·여유율을 근거로 수집해, QA 결과
보고서에서 "타당해 보임" 또는 "재검토 필요"를 판단할 수 있는 자료를 남기는 용도다.

> **판정 성격:** review 권고 원문이 "PASS/FAIL 게이트가 아닌 정보성"으로 명시했다. 근거
> 수집 자체가 실패(예: 두 디렉토리 모두 파일이 하나도 없어 분포를 볼 수 없음)한 경우에만
> FAIL 처리하고, 그 외에는 수집된 수치를 그대로 evidence로 남긴다.

### 사전 조건

- 공통 전제 조건 충족
- `du`, `find -printf`, `awk` 사용 가능
- 다른 TC와 동시 실행 무관(읽기 전용, 비파괴적) — 단, TC20/TC21 실행 도중(더미 배치 중)에는
  분포가 인위적으로 왜곡되므로 그 사이에는 실행하지 않는다

### 절차

1. `du -sh /edge/log/system /edge/log/toupload/system/ 2>&1` 로 두 디렉토리 총 사용량을
   그대로 dump_cmd 캡처
2. `find /edge/log/system /edge/log/toupload/system/ -type f -printf '%s %TY-%Tm-%Td %p\n' 2>&1 | sort -n`
   로 개별 파일(크기 + mtime + 경로) 전체 목록을 dump_cmd 캡처 — `.log.xz`/`.meta`/`nmon`
   하위 포함 여부가 그대로 드러난다
3. `task_check_disk_budget()`과 동일한 측정 대상(두 디렉토리 재귀, 일반 파일만)으로
   합산 바이트 수 계산:
   ```bash
   usage_bytes=$(find /edge/log/system /edge/log/toupload/system/ -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
   ```
4. `usage_bytes`를 MiB로 환산하고, `LOG_DISK_BUDGET_HARD_LIMIT_BYTES`(2560MiB) 대비
   여유율(%)을 계산: `awk -v u="$usage_bytes" 'BEGIN{printf "%.2f", u/1024/1024/2560*100}'`
5. `.log.xz` 확장자 파일만 추려 개수·평균·최대·최소 크기를 계산(rotation 1회당 크기 추정치,
   TC04가 실측한 70~210MB 범위와 비교할 근거)
6. 위 1~5번 dump_cmd 결과를 evidence로 통합 저장 — 이 TC는 "타당하다/아니다"를 스스로
   판정하지 않고, 결과 보고서 작성자가 이 수치를 근거로 판단하도록 남긴다

### 기대 결과

| 항목 | 기준 |
|------|------|
| 근거 수집 | 두 디렉토리 각각 최소 1개 이상의 파일 존재, 크기/mtime 목록 획득 |
| 사용량/한도 비교 | 현재 사용량(MiB) 및 하드리밋(2560MiB) 대비 여유율(%) 산출 |
| `.log.xz` 크기 분포 | 개수/평균/최대/최소 크기 산출 (근거 없으면 "0건"으로 명시) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC19-1 | 근거 수집 성공 (두 디렉토리 조회 가능, 파일 목록 1건 이상 획득) — 분포의 타당성 자체는 판정하지 않음 | informational | — | `find ... \| wc -l` 결과가 0이면 FAIL, 그 외에는 목록을 evidence로 기록 |
| TC19-2 | 현재 총 사용량 대비 2560MiB 하드리밋 여유율(%) 산출 | informational | — | 계산된 `usage_bytes`/여유율(%)을 evidence로 기록 (수동 판단 자료, PASS/FAIL 미해당) |

---

## TC20 — 로그 디스크 예산 circuit breaker: 트립/재개 경계 + 트립 중 정상 정리 로직 유지

### 목적

`SYSTEM_LOG_STAGING_DIR`+`SYSTEM_LOG_PATH` 합산 사용량이 하드리밋(2560MiB) 이상이 되면
`task_check_disk_budget()`(`system_log.cpp:524-561`)이 `log_disk_guard_tripped_`를 true로
바꿔 이후 `request_dump_journal()`(`system_log.cpp:639-645`)을 경유하는 모든 신규 journal
dump를 차단하는지, 트립 중에도 day-retention(`delete_log`)이 정상 동작하는지, 그리고
사용량이 로우워터마크(2304MiB) 이하로 내려가면 자동 재개(신규 dump 정상 생성)되는지를
`kill -9` 재시작 패턴(TC12/TC14/TC16/TC18 재사용)으로 결정적으로 검증한다.

> **주의 (파괴적 시험, 예외 케이스 전용):** `/edge/log` 파티션에 최대 약 2.6GiB 상당의
> 더미를 실제로 채운다. TC18과 마찬가지로 사전 여유공간을 확인해 부족하면 더미 생성 없이
> SKIP한다. **TC04/TC15/TC16/TC18처럼 디스크 용량을 전제·변경하는 다른 TC와 동시 실행
> 금지.** `--full`/`--only`에만 포함하고 기본(빠른) 실행에는 포함하지 않는다.

### 사전 조건

- 공통 전제 조건 충족
- `pgrep`, `kill -9` 사용 가능, edge_runtime이 system_log 재시작시키는 상태(TC12/14/16/18과 동일)
- `df -P`, `dd`, `touch -d`, `xz` 사용 가능
- 빌드 상수: `LOG_DISK_BUDGET_HARD_LIMIT_BYTES=2560MiB`, `LOG_DISK_BUDGET_LOW_WATERMARK_BYTES=2304MiB`,
  `LOG_DISK_BUDGET_CHECK_INTERVAL_SEC=300`(`system_log.hpp:37-39`) — 5분 주기를 기다리지
  않고 `kill -9` 재시작으로 `task_check_disk_budget()`을 결정적으로 즉시 발화시킨다
  (`system_log_timer_loop()`의 시작 시퀀스 `delete_old_journals()`→`task_cleanup_logs()`→
  **`task_check_disk_budget()`**→`task_capture_boot_log()`→...,`system_log.cpp:900-936`)
- **디스크 여유공간 실측 필요**: 시험 시작 시점 `SYSTEM_LOG_STAGING_DIR`가 속한 파티션
  여유공간이, 하드리밋까지 채우는 데 필요한 양(`NEED_MB` = 2560MiB − 현재 사용량 + 여유
  마진) + 안전마진(15%p) 이상이어야 진행. 안전 상한 `TC20_MAX_FILL_MB`(기본 3072MB)를
  넘기면 df 파싱 이상 등 극단적 상황으로 보고 SKIP(TC18의 `TC18_MAX_FILL_MB` 패턴과 동일).
- 다른 TC(TC04/TC15/TC16/TC18)와 동시 실행 금지

### 절차

**Phase 0 — 사전 조건 계산**

1. `usage0` = `task_check_disk_budget()`과 동일 방식으로 현재 사용량 측정:
   `find /edge/log/system /edge/log/toupload/system/ -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'`
2. `df -P`로 해당 파티션 total/avail 확인, `NEED_MB` = `ceil((2560MiB*1024*1024 - usage0)/1MiB) + 64`
   (usage0이 이미 하드리밋을 넘는 예외적 상황이면 `NEED_MB=0`으로 두고 더미 배치 생략, 이미
   트립 조건이 성립한 것으로 간주하고 Phase 1의 4번부터 진행)
3. 여유공간이 `NEED_MB` + 안전마진(15%p) 이상이고 `NEED_MB` ≤ `TC20_MAX_FILL_MB`(3072MB)인지
   확인 — 미충족 시 TC20-0 FAIL 기록 후 더미 생성 없이 즉시 종료(SKIP)
4. (정보성 로그) 더미 배치 후 예상 실제 파티션 여유율이 20%/10% 밑으로 떨어질 가능성을
   미리 계산해 evidence에 남김 — 떨어질 경우 `cleanup_if_low_disk_space()`(`system_log.cpp:965-985`)가
   부수적으로 같이 발화할 수 있음을 인지하고 진행(TC20-3 판정 시 이를 반영해 두 로그
   채널 모두 허용, 아래 참고)

**Phase 1 — 더미 배치 및 트립 유발**

5. `BUDGET_FILL` 더미: `/edge/log/system/.tc20_budget_fill/`(재귀 합산 대상이므로 서브
   디렉토리도 카운트됨) 아래 `dd`로 64MB 청크 여러 개(`tc20_fill_NN.tc20fill`, 총량
   `NEED_MB`)를 생성한다. **확장자를 `.tc20fill`(비표준)로 둔다** —
   `delete_oldest_files_until_safe()`(`system_log.cpp:987-1017`)는 `.xz`/`.log`/`.meta`/
   `.nmon` 확장자만 삭제 후보로 삼으므로, 파티션 실여유율이 낮아져 저용량 긴급삭제가 함께
   발화하더라도 이 더미는 삭제 대상에서 제외되어 트립 상태가 흔들리지 않는다(코드
   근거로 확인, `system_log.cpp:991-998`). mtime은 현재 시각 그대로 둔다.
6. `RETENTION_DUMMY`(day-retention 검증용): `/edge/log/toupload/system/systemlog_20250101000000_20250101010000.log.xz`
   생성 후 `touch -d "31 days ago"`
7. `FRESH_RETENTION_DUMMY`(대조군, 유지되어야 함): 동일 위치에
   `systemlog_20250601000000_20250601010000.log.xz` 생성 후 `touch -d "1 day ago"`
8. `df -P`로 더미 배치 후 실제 파티션 여유율 재확인(기록용, dump_cmd)
9. `BEFORE_HEAD` = `journalctl --list-boots | head -n1` 기록 (TC06/TC15/TC16/TC18 패턴)
10. staging/toupload의 `systemlog_*.log`/`systemlog_*.log.xz` BEFORE 목록 기록(RETENTION
    더미 제외 필터링) — 신규 dump 미생성 확인용
11. `kill -9 $(pgrep -f /edge/app/bin/system_log)` → edge_runtime 재시작
12. 재시작 직후 최대 90초 1초 간격 폴링: journald(`docker-loader`)에서
    `"reached the 2560 MiB budget"`(트립 로그) 등장 대기
13. 트립 로그 확인 후 이어서 최대 60초 폴링: `"[task_capture_boot_log] Failed to dump log"`
    (또는 `"Log disk budget guard is tripped, skipping journal dump"`) 로그 확인 —
    `task_capture_boot_log()`는 매 재시작마다 무조건 실행되므로(`system_log.cpp:703-742`)
    이 로그가 반드시 나타나야 한다
14. `RETENTION_DUMMY` 삭제 여부 최대 90초 폴링(TC12와 동일 예산)
15. `FRESH_RETENTION_DUMMY` 존재 확인
16. `AFTER_HEAD` = `journalctl --list-boots | head -n1` 확인
17. staging/toupload에 신규 `systemlog_*.log`/`.log.xz`(boot capture 산출물)가 **생성되지
    않았는지** BEFORE 목록과 diff로 확인 — dump 자체가 스킵되므로 파일이 아예 안 생겨야 함
18. (추가 확인, on-demand) `send_and_wait "get_log_data" "{}" 30`(TC03 패턴 재사용) 발행 →
    응답 후 신규 `.xz` 미생성 확인 + journald에서
    `"[task_rotate_sync] Failed to make log!! Rotate logic is stopped."` ERROR 로그 확인

**Phase 2 — 재개 유발 및 정리**

19. `rm -rf /edge/log/system/.tc20_budget_fill/` 로 BUDGET_FILL 더미 전량 삭제 → 사용량이
    `usage0` 수준(로우워터마크 2304MiB 미만, 사전 조건에서 이미 보장됨)으로 복귀
20. `kill -9 $(pgrep -f system_log)` → 재시작(5분 타이머 대기 대신 결정적 재현, 요구사항 명시)
21. 재시작 후 최대 90초 폴링: journald에서
    `"under the 2304 MiB watermark; journal dumps resume"`(재개 로그) 확인
22. `send_and_wait "get_log_data" "{}" 30` 발행 → 응답 후 10초 대기, 신규 `.xz` 정상
    생성 확인(재개 후 dump 정상 동작)
23. cleanup: `FRESH_RETENTION_DUMMY` 삭제, `.tc20_budget_fill` 디렉토리 잔재 확인 및 제거,
    게이트가 미트립 상태로 남아 다른 TC에 영향을 주지 않는지 최종 확인(22번에서 이미 간접 확인됨)

> **주의 (Flag — 요구사항 문서와 코드 실동작 불일치 의심, review 전달 필요):** 요구사항
> 문서는 "게이트가 트립돼도 journal vacuum(`SYSTEM_LOG_CMD_ROTATE_VACUUM`)은 계속
> 동작해야 한다"고 전제했으나, 실제 코드(`task_capture_boot_log`, `system_log.cpp:722-731`
> / `task_capture_shutdown_log`, `:681-690` / `task_rotate_sync`, `:427-436`)를 보면
> `request_rotate_log()`(vacuum 호출)는 **세 함수 모두에서 `request_dump_journal`/
> `request_make_log`가 성공(`status==SUCCESS`)한 뒤에만 도달**하고, 실패/스킵 시 그 직전에
> `return`(또는 `return false`)한다. 즉 게이트가 트립되어 dump가 스킵되면, 이 세 경로를
> 통한 vacuum 호출 자체가 아예 실행되지 않는다 — day-retention(`delete_log`)/저용량
> 긴급삭제(`cleanup_if_low_disk_space`)는 `task_cleanup_logs()`에서 게이트와 무관하게
> 독립적으로(파일시스템 기반, IPC 미경유) 항상 실행되는 것과 대조적이다. TC20-4는 이
> 코드 근거에 기반한 "트립 중 vacuum 미실행(head 불변)"을 기대값으로 삼아 실측하고,
> 결과를 그대로 evidence에 남긴다 — PASS/FAIL 게이트가 아닌 **정보성/Flag** 항목이다.
> 만약 실측 결과가 예상과 달리 head가 변한다면(=vacuum이 실제로 실행됨) 그 자체가 코드
> 분석이 놓친 다른 경로가 있다는 뜻이므로 review에 재전달해야 한다. 이 발견은 "게이트가
> journal dump만 막고 정리 로직은 막지 않는다"는 설계 의도가 day-retention/저용량삭제에는
> 맞지만 vacuum에는 (현재 코드 기준) 적용되지 않을 수 있음을 시사하므로, journald 자체
> 저장소가 트립 기간 동안 트리밍되지 않아 별도의 디스크 압박 요인이 될 수 있다는 점을
> QA 결과 보고서에 반드시 명시할 것.

### 기대 결과

| 항목 | 기준 |
|------|------|
| 사전 조건 | 여유공간 ≥ `NEED_MB` + 15%p 마진 AND `NEED_MB` ≤ 3072MB |
| 트립 발동 | 재시작 후 하드리밋 초과 트립 로그 등장 |
| 신규 dump 차단 | WARN/ERROR 로그 등장, staging/toupload에 신규 `.log`/`.xz` 미생성 |
| day-retention 유지 | 31일 더미 삭제(1일 더미 생존 여부는 informational — 아래 Flag 참고) |
| vacuum (정보성) | 코드 근거상 트립 중 미실행 기대(head 불변) — 실측값을 그대로 기록 |
| 재개 | 더미 정리 후 재시작 시 재개 로그 등장, 신규 dump 정상 생성 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC20-0 | 사전 조건 충족(여유공간≥NEED_MB+15%p AND NEED_MB≤3072MB) — 미충족 시 이후 절차 생략(SKIP) | boolean | true | df 파싱값 기반 계산 |
| TC20-1 | 하드리밋 초과로 게이트 트립 로그 발생 | boolean | true | `journalctl -u docker-loader \| grep -F "reached the 2560 MiB budget"` |
| TC20-2 | 트립 중 신규 dump 차단(WARN+호출부 ERROR, 신규 파일 미생성) | boolean | true | `grep -F "Log disk budget guard is tripped"` 존재 AND `[ "$staging_new_count" -eq 0 ]` |
| TC20-3 | 트립 중에도 day-retention(31일 삭제) 정상 동작 | boolean | true | `[ ! -f "$RETENTION_DUMMY_31D" ]` |
| TC20-3b | (정보성) 1일 더미 생존 여부 — [2026-09-23, review PASS로 확정된 새 설계] `delete_if_low_disk_space`/`delete_oldest_files_until_safe` 제거 후 `cleanup_log_disk_budget()`이 나이(30일) 무관하게 mtime 오래된 순으로 watermark까지 지우므로, 트립 중 유일한 삭제 후보인 이 더미가 함께 소진될 수 있다(실측: 두 더미 모두 삭제됨 — 회귀 아님, 확정된 설계가 의도대로 동작한 것. 능동정리 메커니즘 자체의 정확성은 TC22가 직접 검증) | informational | — | `[ -f "$RETENTION_DUMMY_1D" ]` 결과를 그대로 기록 |
| TC20-4 | (정보성/Flag) 트립 중 journal vacuum 실행 여부 실측 — 코드 근거상 "미실행(head 불변)" 기대, review 전달용 | informational | — | `[ "$before_head" = "$after_head" ]` 결과를 그대로 기록(같으면 코드 분석과 일치, 다르면 Flag 갱신 필요) |
| TC20-5 | 사용량 로우워터마크 이하 복귀 후 게이트 재개 로그 발생 | boolean | true | `journalctl -u docker-loader \| grep -F "under the 2304 MiB watermark; journal dumps resume"` |
| TC20-6 | 재개 후 get_log_data 요청 시 신규 `.xz` 정상 생성 | boolean | true | `[ "$FILES_AFTER" -gt "$FILES_BEFORE" ]` |

---

## TC21 — 온디맨드 반복 요청 시 WARN 로그량 선형성 (레이트리밋 부재 감내 가능성)

### 목적

게이트가 트립된 상태에서 `get_log_data`(`SERVICE_GET_LOG_DATA`)를 짧은 간격으로 반복
호출했을 때, `request_dump_journal()`(`system_log.cpp:639-645`)의 매 스킵마다 찍히는
`LOG(WARN) "Log disk budget guard is tripped, skipping journal dump"`가 레이트리밋 없이
**요청 횟수만큼만** 찍히는지(요청 대비 폭증하지 않는지), 그리고 매 응답이 크래시/행 없이
즉시(수 초 이내) 반환되는지 확인한다.

> **판정 범위:** review의 "감내 가능한 수준"이라는 표현은 코드가 강제하는 정량적 상한이
> 아니므로, 이 TC는 "요청 수 ≈ WARN 로그 수"라는 **선형 관계**만 실측으로 보여주는 데까지만
> PASS/FAIL로 판정한다. 그 선형성 자체가 실제로 문제될 폭증인지에 대한 최종 판단은 QA
> 결과 보고서에서 review에 근거로 전달한다(요구사항 문서 (4) 원문 그대로).

### 사전 조건

- 공통 전제 조건 충족
- 게이트가 트립된 상태에서 시작해야 함 — **TC20 Phase 1(더미 배치 → 트립 유발, Phase 2
  정리 이전)** 직후 이어서 실행하면 트립 유발 단계를 반복하지 않아도 되어 효율적이다.
  독립 실행 시에는 TC20의 5~13번 절차(BUDGET_FILL 더미 배치 + `kill -9` 재시작 + 트립
  로그 확인)를 동일하게 수행해 자체적으로 트립 상태를 만든 뒤 진행한다(TC15/TC16처럼
  "의존 TC 없음, 독립 실행 가능"을 유지하기 위함).
- `mosquitto_pub`/`mosquitto_sub` 사용 가능(TC03 패턴 재사용)
- 다른 TC(TC04/15/16/18/20)와 동시 실행 금지(트립 상태를 전제로 하는 파괴적 시험)

### 절차

1. (트립 상태 확보) 위 사전 조건대로 TC20 Phase 1 재사용 또는 자체 트립 유발
2. `REQ_START_EPOCH` = 현재 epoch 초 기록 — 이후 journalctl 조회를 이 시각 이후로 한정
3. `REQ_COUNT=8`, 간격 4초로 `get_log_data` 요청을 순차 발행. 각 요청마다:
   - `mosquitto_pub`으로 발행, 해당 응답을 최대 10초까지 대기
   - 응답 수신까지 걸린 시간(초)과 수신 여부(성공/타임아웃)를 기록
   - 다음 요청까지 4초 대기
4. 8회 반복 종료 후 2초 대기(로그 flush)
5. `WARN_COUNT` = `journalctl -u docker-loader --since "@${REQ_START_EPOCH}" --no-pager | grep -cF "Log disk budget guard is tripped, skipping journal dump"`
6. 판정: `REQ_COUNT ≤ WARN_COUNT ≤ REQ_COUNT+2`(get_log_data 1회당 `request_make_log()`
   경유 1회 스킵이 정상 — 정확히 1:1이 이상적이나, 인접한 5분 주기 `task_check_disk_budget()`
   재확인 등 타이밍 변수를 위해 소폭 여유를 둠) 범위 안인지 확인 — 범위를 벗어나면(특히
   `REQ_COUNT`의 배수로 폭증) FAIL
7. `TIMEOUT_COUNT`(10초 내 무응답 건수) = 0 인지, 그리고 모든 응답 수신 소요 시간이 10초
   미만인지 확인 — 크래시/행 없이 즉시 응답하는지의 직접 증거
8. cleanup: TC20 Phase 2(더미 정리 + 재개 유도)로 이어서 마무리하거나, 독립 실행 시
   동일하게 BUDGET_FILL 삭제 → `kill -9` 재시작 → 재개 로그 확인까지 수행해 게이트를
   미트립 상태로 복원

### 기대 결과

| 항목 | 기준 |
|------|------|
| WARN 로그량 | `REQ_COUNT ≤ WARN_COUNT ≤ REQ_COUNT+2` (선형 관계, 레이트리밋 부재이나 폭증 아님) |
| 응답 지연/행 | 8회 모두 10초 이내 응답, 타임아웃 0건 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC21-1 | 반복 요청 횟수만큼(±소폭 여유) WARN 로그 발생 — 레이트리밋 부재이나 요청 대비 폭증 아님(선형성만 판정, "감내 가능성"의 최종 판단은 결과 보고서에서 review에 전달) | boolean | true | `[ "$WARN_COUNT" -ge "$REQ_COUNT" ] && [ "$WARN_COUNT" -le $((REQ_COUNT+2)) ]` |
| TC21-2 | 모든 응답이 타임아웃 없이(10초 이내) 수신됨(크래시/행 없음) | boolean | true | `[ "$TIMEOUT_COUNT" -eq 0 ]` |

---

## TC22 — 로그 디스크 예산 능동 정리(cleanup_log_disk_budget): 트립 tick 내 즉시 정리+재개

### 목적

[2026-09-23 신규, review PASS] `task_check_disk_budget()`이 하드리밋(2560MiB) 트립을
감지하면, 이제 스스로 `cleanup_log_disk_budget()`을 호출해 `SYSTEM_LOG_STAGING_DIR`+
`SYSTEM_LOG_PATH`(플랫, 서브디렉토리 제외)의 `.xz`/`.log`/`.meta`/`.nmon` 파일을 mtime
오름차순(오래된 것부터)으로 하나씩 지우며 매번 재측정하고, 로우워터마크(2304MiB) 이하가
되면 그 자리에서 멈추는지(`"Watermark reached, stopping cleanup"`), 그리고
`task_check_disk_budget()`이 그 결과를 받아 **재시작 없이, 같은 트립 사이클(tick) 안에서**
게이트를 즉시 재개하는지(`"under the 2304 MiB watermark; journal dumps resume"`)를
검증한다. TC20(기존)은 5분 자연 대기 또는 더미 수동 삭제 후 **별도 재시작**으로 재개를
확인하는 방식이었던 것과 대조적으로, 이 TC는 "정리→해제가 하나의 tick 안에서 자동으로
일어나는지" 자체가 핵심이다.

> **Flag — TC20/21의 `.tc20fill` 더미 재사용 불가:** `cleanup_log_disk_budget()`의 삭제
> 후보 스캔은 `fs::directory_iterator`(비재귀, flat)로 `.xz`/`.log`/`.meta`/`.nmon`
> 확장자만 본다(`system_log.cpp:1043-1060`). TC20/21의 `BUDGET_FILL_DIR`
> (`${STAGING_DIR}/.tc20_budget_fill/`, 확장자 `.tc20fill`)은 서브디렉토리+비표준
> 확장자로 **의도적으로 이중 면제**돼 있어 능동 정리 대상이 되지 않는다(TC20/21의
> 원래 설계 의도상 이건 정상 — 그 두 TC는 "트립이 유지되는지"를 보는 것). 이 TC는
> 반대로 "삭제되는" 경로를 봐야 하므로, `TOUPLOAD_DIR`에 직접(플랫) `.log.xz` 더미를
> 배치한다.

### 사전 조건

- 공통 전제 조건 충족
- `pgrep`, `kill -9`(또는 `systemctl restart docker-loader`) 사용 가능
- `df -P`, `dd`, `touch -d` 사용 가능
- 빌드 상수: `LOG_DISK_BUDGET_HARD_LIMIT_BYTES=2560MiB`, `LOG_DISK_BUDGET_LOW_WATERMARK_BYTES=2304MiB`
  (TC20과 동일)
- **디스크 여유공간 실측 필요**: TC20과 동일한 `calc_budget_need_mb()` 계산 재사용
  (`NEED_MB` = 하드리밋 − 현재 사용량 + 64MB 여유, 안전 상한 `TC20_MAX_FILL_MB`=3072MB
  넘기면 SKIP)
- 다른 TC(TC04/TC15/TC16/TC18/TC20/TC21)와 동시 실행 금지 — 같은 파티션을 전제로 함

### 절차

1. `calc_budget_need_mb()`로 `NEED_MB` 계산, 사전 조건 확인(미충족 시 SKIP)
2. `TOUPLOAD_DIR`에 32MB 청크의 `systemlog_tc22NNNN_tc22NNNN.log.xz` 더미를 `NEED_MB`
   만큼 배치 — mtime을 청크마다 오름차순 분산(1번째=29일 전 근방 → 마지막=1일 전,
   day-retention 30일 문턱 미만 유지)
3. `kill -9 $(pgrep -f /edge/app/bin/system_log)` → edge_runtime 재시작
4. 최대 90초 폴링: `"reached the 2560 MiB budget"`(트립) 로그 확인
5. 최대 30초 폴링: `"[cleanup_log_disk_budget] Starting cleanup"` 확인(같은 tick 안에서
   즉시 정리 시작)
6. 최대 30초 폴링: `"[cleanup_log_disk_budget] Removing:"` 확인
7. `"[cleanup_log_disk_budget] usage after removal:"` 로그 캡처(정보성)
8. 최대 60초 폴링: `"under the 2304 MiB watermark; journal dumps resume"`(재개, **재시작
   없이**) 확인
9. 실측 `find STAGING_DIR TOUPLOAD_DIR -type f | sum` 로 최종 사용량이 로우워터마크
   이하인지 직접 재확인(로그와 별개의 독립 증거)
10. 가장 오래된 청크(oldest mtime) 부재 확인 / 가장 최신 청크(newest mtime) 존재 확인
    (watermark에서 멈춰 전량 삭제가 아니라 "필요한 만큼만" 지웠는지 검증)
11. `send_and_wait "get_log_data" "{}" 30` 발행 → 신규 `.xz` 정상 생성 확인(게이트 실질
    재개 확인)
12. cleanup: 남은 더미 청크 전량 삭제, 잔재 없음 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 트립 발동 | 하드리밋 초과 트립 로그 등장 |
| 즉시 정리 | 같은 tick 안에서 `Starting cleanup`/`Removing:` 로그 등장 |
| 즉시 재개 | 재시작 없이 같은 사이클 안에서 재개 로그 등장 |
| 사용량 | 실측 사용량이 로우워터마크 이하 |
| 삭제 순서 | 가장 오래된 청크 삭제, 가장 최신 청크 보존(전량 삭제 아님) |
| 게이트 실질 재개 | `get_log_data` 신규 `.xz` 정상 생성 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC22-0 | 사전 조건 충족(여유공간≥NEED_MB+15% AND NEED_MB≤3072MB) — 미충족 시 SKIP | boolean | true | df 파싱값 기반 계산 |
| TC22-1 | 하드리밋 초과로 게이트 트립 로그 발생 | boolean | true | `grep -F "reached the 2560 MiB budget"` |
| TC22-2 | 트립 직후 같은 tick 안에서 능동 정리 시작됨 | boolean | true | `grep -F "[cleanup_log_disk_budget] Starting cleanup"` |
| TC22-3 | 삭제 로그(Removing:) 등장 | boolean | true | `grep -F "[cleanup_log_disk_budget] Removing:"` |
| TC22-4 | 재시작 없이 같은 트립 사이클 안에서 즉시 재개 로그 발생 | boolean | true | `grep -F "under the 2304 MiB watermark; journal dumps resume"` |
| TC22-5 | 실측 사용량이 로우워터마크 이하로 내려감 | boolean | true | `[ "$usage_after_bytes" -le "$watermark_bytes" ]` |
| TC22-6 | 가장 오래된 청크가 삭제됨 | boolean | true | `[ ! -f "$TC22_OLDEST_FILE" ]` |
| TC22-7 | 가장 최신 청크는 보존됨(전량 삭제 아님) | boolean | true | `[ -f "$TC22_NEWEST_FILE" ]` |
| TC22-8 | 게이트 재개 후 get_log_data 신규 .xz 정상 생성 | boolean | true | 신규 파일 diff 존재 확인 |
| TC22-9 | 정리 후 테스트 청크 잔재 없음 | boolean | true | `[ "$remain_count" -eq 0 ]` |

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
| TC04 | A (자동) | systemd-cat으로 100MB/200MB(신규, 2026-09-23) 실 journal 데이터 주입 + xz -0/300초 compress 예산 성공 검증 + `xz --test` 무결성 + vacuum cleanup |
| TC06 | B (반자동) | 저널 사용량 수동 확인 |
| TC10 | B (반자동) | 실제 리부트 포함 — pre/post 분리 실행, 재접속 후 post 수동 실행 |
| TC11 | B (반자동) | nmon 업로드 happy path — TC11-5 는 5분+ 대기 (BlobUploadDirector 스캔) |
| TC12 | A (자동) | nmon retention 30일 — `kill -9 system_log` 후 재시작 시 발화하는 cleanup 대기(최대 90초) |
| TC13 | A (자동) | nmon old 비어있는 환경 호환 — `get_log_data` 응답 수신만 확인 |
| TC14 | A (자동) | RTC 이상 동일 시작시간 다중 파일 병합 — `kill -9 system_log` 후 edge_runtime 재시작 흐름 재현 |
| TC15 | A (자동) | task_rotate_sync compress 실패 시 raw .log 보존 — **재설계(2026-09-23)**: xz -0+300초 분리 타임아웃으로 기존 180s 공유 타임아웃 유도 방식이 더 이상 유효하지 않아, 대상 파티션을 거의 채워 xz를 ENOSPC로 결정적 실패시키는 fault injection으로 전환(요구사항 문서 대안 (a) 채택). 예외 케이스 전용 파괴적 시험, 시험 종료 시 filler 전량 삭제+여유공간 복원 필수 |
| TC16 | A (자동) | task_capture_boot_log compress 실패 시 raw .log 보존 — TC15와 동일 ENOSPC 기법(2026-09-23 재설계) + `kill -9 system_log` 재시작 |
| TC17 | A (자동) | MessageContext tid 미검증 재현 — cmd_host 응답 위조(`mosquitto_pub`) 직접 발행, 회귀 세트 미포함(단독 실행 전용) |
| TC18 | A (자동) | [2026-10-02 R09 전용 복구] 저장공간 부족(<10%) 시 SYSTEM_LOG_DIRS cleanup — main에선 검증 대상 함수가 제거돼 2026-09-23 삭제됐으나 R090125 백포트에는 남아있어 복구. 빠른/전체 실행 미포함, `--tc18`/`--only`로만 실행. main 빌드(함수 부재)·여유율<25%면 TC18-0에서 자동 SKIP |
| TC19 | B (반자동) | 로그 디스크 예산 watermark 타당성 근거 수집 — 데이터 수집(du/find)은 자동, "타당함/재검토 필요" 최종 판단은 결과 보고서 작성자 수동 판정. PASS/FAIL 게이트 아닌 informational |
| TC20 | A (자동) | 로그 디스크 예산 circuit breaker 트립/재개 경계 + 트립 중 day-retention 유지 — 예외 케이스 전용 파괴적 시험(최대 ~2.6GiB 더미), `kill -9 system_log` 재시작으로 트립/재개 결정적 재현. `--full`/`--only`에 포함, 기본 실행에는 미포함. 사전 조건(여유공간) 미충족 시 자동 SKIP. TC20-4(트립 중 vacuum 실행 여부)는 informational/Flag — 코드 분석상 트립 중 미실행 기대(요구사항 가정과 배치, review 전달 필요) |
| TC21 | A (자동) | 온디맨드 반복 요청 시 WARN 로그량 선형성 — 게이트 트립 상태(TC20 Phase 1 재사용 또는 자체 유발) 전제, 8회 반복 요청 대비 WARN 로그 수 선형성만 판정(레이트리밋 부재 자체는 기존 사양). `--full`/`--only`에 포함, 기본 실행에는 미포함. 다른 디스크 전제 TC와 동시 실행 금지 |
| TC22 | A (자동) | [2026-09-23 신규] 로그 디스크 예산 능동 정리(`cleanup_log_disk_budget`) — 트립되면 오래된 `.xz`/`.log`/`.meta`/`.nmon`부터 지우며 재측정, 로우워터마크 이하가 되면 재시작 없이 같은 트립 tick 안에서 즉시 재개하는지 검증. TC20/21의 `.tc20fill` 더미(삭제 후보 이중 면제)는 재사용 불가해 `.log.xz` 플랫 더미로 별도 설계. 트립 로그 검출은 사후 journalctl 재조회 대신 restart 직전부터 시작하는 라이브 `journalctl -f` 캡처 방식 사용(1차 실행에서 사후 재조회로는 트립 메시지를 못 찾는 문제 실측 후 교체, TC18/21과 동일 패턴). `--full`/`--only`에 포함, 기본 실행에는 미포함. 사전 조건(여유공간) 미충족 시 자동 SKIP |

---

## 관련 문서

- `tc_system_log_result.md` — 본 TC 실행 결과 보고서
- `tc_system_log_evidence_full.log` — 결과의 근거가 되는 통합 로그

---

## 근거 매핑 (신규 TC19~21 — 로그 디스크 예산 circuit breaker)

review가 이번 QA 라운드에서 남긴 4가지 검증 권고사항과, 이를 커버하는 신규 TC/기준ID의
대응 관계다. 요구사항 문서(review 권고 재구성)와 실제 소스코드(`system_log.hpp`/`.cpp`)를
직접 대조(cross-check)했으며, 코드 라인은 모두 실측 확인했다.

| review 권고 | 커버 TC/기준ID | 근거 (요구사항 §X / 코드 파일:line) | 출처 신뢰도 |
|---|---|---|---|
| (1) watermark 타당성 근거수집 | TC19-1, TC19-2 | 요구사항 §(1) + `system_log.hpp:37-38`(HARD_LIMIT/LOW_WATERMARK 상수) | High (양쪽 일치, informational 성격도 요구사항 원문과 동일) |
| (2) 트립/재개 경계 실동작 | TC20-1(트립), TC20-5(재개), TC20-6(재개 후 dump 정상 생성) | 요구사항 §(2) + `task_check_disk_budget()`(`system_log.cpp:524-561`), `request_dump_journal()`(`:639-645`), `system_log_timer_loop()` 시작 시퀀스(`:900-936`) | High (양쪽 일치, 메시지 문자열까지 코드 원문과 대조 확인) |
| (3) 트립 중 정상 정리 로직(day-retention/vacuum) 유지 | TC20-2(dump 차단), TC20-3(day-retention 유지) | 요구사항 §(3) + `task_cleanup_logs()`(`:884-898`)→`delete_log()`(`:315-348`)가 게이트와 무관하게 항상 실행됨을 코드로 확인 | High (day-retention 부분은 양쪽 일치) |
| (3-부속) "vacuum도 게이트와 무관하게 계속 동작" | TC20-4 (informational/Flag) | 요구사항 §(3) 원문 주장 vs `task_capture_boot_log()`(`:703-742`)/`task_capture_shutdown_log()`(`:660-701`)/`task_rotate_sync()`(`:406-476`) 실제 코드 — `request_rotate_log()`(vacuum)이 `request_dump_journal`/`request_make_log` 성공 시에만 도달, 실패/스킵 시 그 직전 `return` | **Flag — 요구사항 가정과 코드 실동작 불일치 의심, review 재검토 필요.** 트립 중 이 세 경로로는 vacuum이 호출되지 않을 것으로 코드 분석됨(실측으로 재확인 필요) |
| (4) 온디맨드 반복 시 WARN 로그량 감내 가능성 | TC21-1(선형성), TC21-2(응답 지연/행 없음) | 요구사항 §(4) + `request_dump_journal()`의 매 스킵마다 무조건 1회 WARN, 레이트리밋 로직 코드상 부재 확인(`:639-645`) | High (양쪽 일치, "감내 가능성" 최종 판단 자체는 이 TC 범위 밖임을 요구사항 원문이 명시) |

### 주요 발견 요약

- (1)(2)(4)는 요구사항 문서와 코드가 라인 단위로 일치 — High 신뢰도로 TC 설계.
- (3) 중 day-retention/저용량 긴급삭제(`cleanup_if_low_disk_space`, 게이트와 무관한
  파일시스템 경로)는 요구사항 그대로 반영.
- 다만 (3)이 언급한 "journal vacuum도 게이트와 무관하게 계속 동작"이라는 부분은, 실제
  코드에서는 vacuum 호출(`request_rotate_log()`)이 dump 성공 이후에만 실행되는 체인 안에
  있어 **트립 중에는 이 경로들로 vacuum이 실행되지 않을 가능성이 높다** — day-retention과
  달리 vacuum은 게이트의 영향을 받는 것으로 코드가 읽힌다. TC20-4를 informational/Flag로
  설계해 실측값을 남기도록 했으며, QA 결과 보고서에서 review에 이 불일치를 반드시
  재전달해야 한다(트립 기간이 길어질 경우 journald 자체 저장소가 트리밍되지 않아 별도의
  디스크 압박 요인이 될 수 있다는 실무적 함의 포함).

---

## 근거 매핑 (xz -0 압축레벨 + compress 전용 타임아웃 분리 — TC04/15/16 갱신, 2026-09-23)

요구사항 문서(`qa_requirements_xz0_timeout.md`, review PASS 근거 + qa 사전조사)와 실제
소스 diff(`system_log/{include/system_log.hpp, source/system_log.cpp}`, HEAD 위
unstaged, review PASS)를 직접 대조(cross-check)했다. 코드 라인은 모두 실측 확인했다.
(참고: 요구사항 문서 본문은 diff의 기준 HEAD를 `65c47250`으로 표기했으나, 실제
저장소 HEAD는 이 세션 조사 시점 `e264339`(EWP-2721 로그 디스크 예산 circuit breaker,
TC19~21 대상)였다 — 커밋 해시 표기 차이일 뿐 diff 내용 자체는 요구사항 문서 서술과
그대로 일치함을 직접 확인했다.)

| diff 근거 (파일:line) | 변경 내용 | 커버 TC/기준ID | 출처 신뢰도 |
|---|---|---|---|
| `system_log.hpp:34` `SYSTEM_LOG_CMD_XZ`: `xz -f ` → `xz -f -0 ` | 압축레벨 6→0 | TC04-3/4(200MB 신규 티어, 대용량 성공+무결성), TC04-1/2(100MB 회귀, 영향 없음 재확인) | High (요구사항 §1 + 코드 일치) |
| `system_log.hpp:28-30` `SYSTEM_LOG_REQUEST_CMD_TIMEOUT=180`(불변)/`SYSTEM_LOG_XZ_CMD_TIMEOUT=300`(신규)/`SYSTEM_LOG_TIMEOUT_MARGIN_SEC=5`(신규), `SYSTEM_LOG_PUBLISH_TIMEOUT`(고정185) 제거 | compress만 별도 300초(+5) 예산, 나머지는 기존 180초(+5) 유지 | TC04-3/4(신규 300초 예산 실사용 검증), TC04 "알려진 제약"/사전조건 IPC 타임아웃 문구 전면 갱신(구버전 5초/7초 서술 삭제) | High (요구사항 §2 + 코드 일치) |
| `system_log.cpp:647-648` `request_compress_log()` → `request_command_sync(cmd, SYSTEM_LOG_XZ_CMD_TIMEOUT)` | compress 호출부가 신규 오버로드로 300초 명시 전달 | TC04-3/4, TC15(compress 실패 경로 재설계의 전제), TC16(동일) | High |
| `system_log.cpp:427-444` `task_rotate_sync()`: dump(180s, 불변)→rotate→compress(300s, 신규) 순차, compress 실패 시 `fs::remove(file_path+".xz")` (로직 자체는 불변, 예산만 분리) | dump/compress가 서로 다른 독립 타임아웃 예산을 가지게 됨 → 기존 TC15 재현 방식(raw 400MB로 공유 180초 유도) 무효화 | **TC15 전면 재설계** (ENOSPC fault injection, 요구사항 A절 대안 (a) 채택) | High (요구사항 §3 A절 분석 + 코드 순차 호출 구조 일치, tc-plan이 라인 재확인) |
| `system_log.cpp:692` / `:733` `task_capture_shutdown_log()`/`task_capture_boot_log()`: `request_command_sync(SYSTEM_LOG_CMD_XZ + log_path)` → `request_compress_log(log_path)` 래퍼 통일 | 두 경로도 자동으로 300초 xz 타임아웃 적용(이전엔 180초 그대로 상속) | **TC16 전면 재설계**(TC15와 동일 ENOSPC 기법), TC16 목적 섹션에 코드 라인 갱신 | High (요구사항 §4 + 코드 일치, `task_capture_shutdown_log`는 기존 TC16 범위 제외 방침 유지) |
| (변경 없음) `xz -f` 압축비/크기 관련 절대 수치 어설션 부재 확인 | 레벨0 반영이 기존 회귀 어설션에 영향 없음 | TC01~03, TC05, TC07, TC12 — **직접 재확인 결과 어설션 값 변경 불요**(코드/문서 모두 상대비교 또는 boolean 존재확인만 사용, grep으로 절대 크기·압축비 수치 어설션 없음을 확인) | High (요구사항 §3 서술 + tc-plan 직접 재확인 결과 일치) |

### 주요 발견 요약

- 항목 1/2(xz -0 속도/타임아웃 실반영)는 TC04에 200MB 신규 티어(TC04-3/4)로 반영 —
  기존 100MB 티어(TC04-1)는 그대로 두고 `xz --test` 무결성 체크(TC04-2/4)를 신규
  추가했다(기존엔 무결성 체크 자체가 없었음 — 이번에 처음 보강).
- 항목 3(TC01~03/05/07/12 회귀)은 요구사항 문서의 사전조사(grep 결과 절대 수치
  어설션 없음)를 tc-plan이 직접 재확인했고 동일한 결론에 도달했다 — 문서 변경 불요,
  회귀 재실행만 필요.
- 항목 4 + TC15/16 재설계는 요구사항 A절의 3가지 대안 중 **(a) ENOSPC 결정적 fault
  injection을 채택**했다. TC18이 같은 `/edge/log` 파티션에 대해 이미 "동적 계산(측정
  기반 사이징) + 안전 상한 + df 지연 고려 + 복원 검증" 패턴을 실전에서 검증해둔 전례가
  있어 그 골격을 그대로 재사용했고, 새로 반영된 로그 디스크 예산 circuit breaker
  (EWP-2721, TC19~21 대상)가 같은 파티션의 특정 하위 트리(`SYSTEM_LOG_STAGING_DIR`/
  `SYSTEM_LOG_PATH`)만 감시한다는 점(`system_log.cpp:530`)을 근거로, filler를 그
  트리 바깥에 배치해 두 신규 기능(디스크 예산 게이트 vs xz ENOSPC 재현)이 서로
  오염되지 않도록 설계했다. (b)(raw 물량으로 dump 실패 유도)는 검증 목적(compress
  실패)과 실제 재현 코드 경로(dump 실패)가 어긋나 채택하지 않았고, (c)(목적 재정의
  + 별도 TC 신설)는 (a)로 새 TC 없이도 결정성을 몇 초 안에 달성할 수 있어 불필요한
  분리로 보고 채택하지 않았다.
- ENOSPC 재현의 결정성은 "측정 덤프로 실제 dump 산출물 크기를 먼저 재보고, 그 크기 +
  작은 마진만 남기고 나머지를 채운다"는 사전 계산에 의존한다 — 정확한 바이트 단위
  타이밍 레이스가 아니라, incompressible(고엔트로피 base64) 더미 콘텐츠 특성상 xz
  압축 출력이 원본과 거의 같은 크기가 되는 점을 활용해 작은 마진으로도 압축 실패를
  안정적으로 유도하도록 설계했다. 다만 TC16(kill -9 재시작 트리거)은 재시작 시퀀스의
  `cleanup_if_low_disk_space()`가 사전에 일부 공간을 추가로 회수할 가능성이 남아있어
  informational 잔여 리스크로 문서화했다(Flag, TC16 목적 섹션 참고) — 실행 중 이
  간섭이 실제로 관측되면 마진 재조정이 필요할 수 있다.
- 이 재설계는 파괴적 시험(디스크를 거의 0%까지 소진)이므로 TC15/16 모두 "측정→계산→
  안전 상한 체크(미충족 시 SKIP)→채움→트리거→검증→**무조건 복원**" 구조를 명시했고,
  복원 단계는 PASS/FAIL 결과와 무관하게 항상 실행되도록(`trap` 기반) tc-dev에게
  요구사항으로 못박았다 — 파괴적 시험이 디바이스에 영구 잔재를 남기지 않아야 한다는
  원칙을 최우선했다.
