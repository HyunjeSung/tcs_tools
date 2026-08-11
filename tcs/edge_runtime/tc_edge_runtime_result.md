# TC 실행 결과 보고서 — edge_runtime

**최초 실행:** 2026-08-11 14:36 ~ 14:47 KST (1회차, `timeout 700`에 걸려 TC11 도중 강제 종료됨)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `873aeea160e2833449f8f47c7210d908`
**실행 환경:** SSH (COM7 시리얼 미인식으로 fallback)
**총 결과:** **PASS=23 / FAIL=16** (TC10/TC11-1 FAIL은 스크립트 결함, 실제 앱 동작과 무관 — 아래 참고)
**Evidence:** `tcs/edge_runtime/tc_edge_runtime_evidence_full.log`

> ⚠️ **이 실행 중 DUT 전체 앱 다운 사고 발생 → 조치 완료(2026-08-11 16:15 복구 확인)**.
> 아래 "핵심 이슈 1" 참고. `all_apps_ready_status: is_ready=true`, 17개 앱 전체 정상
> 기동 재확인함(사고 이후 시점 기준).

| TC | 결과 |
|---|---|
| TC01 (4개) | PASS×3, FAIL×1 |
| TC02 (3개) | PASS×3 |
| TC03 (3개) | PASS×2, FAIL×1 |
| TC04 (4개, 1개 선택) | PASS×3, FAIL×1(선택) |
| TC05 (5개) | PASS×2, FAIL×3 |
| TC06 (5개) | PASS×1, FAIL×4 |
| TC07 (3개) | PASS×1, FAIL×2 |
| TC08 (4개) | PASS×4 |
| TC09 (3개) | PASS×3 |
| TC10 (3개) | FAIL×3 (**스크립트 결함 — 아래 참고, 앱 자체는 정상**) |
| TC11 (2개, 실행분) | FAIL×1, PASS×1 (**TC11-1도 스크립트 결함**, TC11-3~ 이후 `timeout 700` 도달로 미완주) |

---

## 시험 과정에서 발견된 핵심 이슈

### 1. (중요, 사고 발생·조치 완료) `/edge/app/`는 호스트가 아니라 컨테이너 내부 전용 경로 — TC10/TC11이 이를 몰라서 실제 설정 파일을 깨뜨림

TC10/TC11은 `UNIEP_APPLIST="/edge/app/files/edge_runtime/uniep_applist.conf"`를 스크립트
실행 위치(SSH로 접속한 **호스트**)에서 직접 `jq`/`cp`로 다루도록 짜여 있는데,
`ac_system_gen2` 컨테이너의 `podman run` 커맨드(`docker-loader.sh`)를 보면
`/edge/app`은 **바인드 마운트 목록에 없다** — `/edge/sp`, `/edge/db`, `/edge/etc`,
`/edge/log`, `/edge/devapp`만 호스트와 공유되고, `/edge/app`(bin/files 전부)은
**이미지에 baked-in된 컨테이너 전용 파일시스템**이다. 그래서 호스트에서의
`jq -e . /edge/app/files/edge_runtime/uniep_applist.conf`는 항상
"No such file or directory"만 내고, TC11의 백업(`cp .../uniep_applist.conf /tmp/backup`)도
항상 조용히 실패한다.

문제는 여기서 그치지 않았다 — TC11은 `/edge/devapp/files/uniep_applist.conf`(이건
실제로 호스트-컨테이너 공유 경로, override 메커니즘 정상 대상)에 새 순서 설정을
쓰고 컨테이너를 재시작해 override가 실제 uniep_applist.conf 자리에 복사되는 것까지는
의도대로 동작했는데, 그 "새 순서 설정" 자체가 (백업 실패 등 연쇄로) 빈 값/개행 1바이트로
잘못 만들어졌고, 시험 종료 시 원복 시도(`cp $backup ...`)도 애초에 백업이 없어 실패했다.
그 결과 **`/edge/devapp/files/uniep_applist.conf`에 깨진 override가 영구히 남아, 이후
컨테이너가 재시작될 때마다(TC09도 `docker stop` 사용) 진짜 설정을 계속 덮어써
db_manager를 포함한 uniep 앱 전체가 기동 못 하는 상태**가 됐다(`[E][ER] [UniEP] Invalid
target ID: db_manager`, 이후 edge_runtime 프로세스만 남고 나머지 16개 앱 전부 다운,
`all_apps_ready_status: is_ready=false` 30회 재시도 소진 직전까지 확인).

**조치**: `/edge/devapp/files/uniep_applist.conf`(테스트가 남긴 깨진 override, 실사용자
설정 아님) 삭제 → `docker stop ac_system_gen2`로 컨테이너 재기동 → 이미지 baked-in
원본(507바이트, 2022-11-15)으로 정상 복원 확인 → `docker exec ac_system_gen2 ps -ef`로
17개 앱 전체 재기동 확인, `all_apps_ready_status: is_ready=true` 확인.

**중요**: 사고 원인 조사 과정에서 `docker exec ac_system_gen2 ls -la
/edge/app/files/edge_runtime/`로 실제 컨테이너 내부를 보니 원본 파일은 507바이트로
정상 존재했다 — 즉 **TC10-1/2/3과 TC11-1의 FAIL은 실제 uniep_applist.conf 내용이나
파싱 로직 문제가 아니라, TC 스크립트가 호스트에서 컨테이너 전용 경로를 잘못 읽으려
한 것 자체가 원인**이다. 이 두 TC는 사용자와 합의된 범위 밖 후속 작업(TC 스크립트를
`docker exec ac_system_gen2 <cmd>`로 감싸는 재작성)에서 다시 검증해야 한다 — 이번
회차 결과는 앱 동작에 대한 유효한 판정이 아니다.

같은 문제가 `device_manager`(TC01~04, `configuration.json`/`register_map.json`)에도
있음을 확인, 별도 result.md에 기록.

### 2. TC05/TC06 (bin 변조 계열) 일부 후속 판정 FAIL — 메커니즘 자체는 동작 확인, 세부 원인 미조사

TC05/TC06은 `/edge/devapp/bin/`(정상적으로 호스트-컨테이너 공유되는 override 디렉터리)을
사용해 바이너리를 변조하는 올바른 방식이라 위 1번 문제와는 무관하다. TC05-1(fork 실패
로그)과 TC08(watchdog 계열, kill -9 기반) 전부 PASS해 **watchdog 메커니즘 자체는
정상 동작함**을 확인했다. 다만 TC05-2/3/4(앱 수 불일치 판정, 적색 LED, 컨테이너
재시작 트리거)와 TC06 전체(10초 타이머 계열)는 FAIL — 로그 관찰 시간창(`$since`)
타이밍 또는 다른 원인일 수 있으나 이번 회차에서는 원인을 특정하지 못했다. TC05-5/
TC06-5(cleanup 검증 — 원복 후 정상 재부팅)는 PASS해 최소한 **정리 절차 자체는
안전하게 동작함**은 확인됨.

### 3. TC01-2/TC03-1/TC04-4/TC07-1/TC07-3 FAIL — 개별 원인 미조사

시간 관계상 이번 회차에서는 로그 문구 불일치/타이밍 여부를 세부 조사하지 않음.
`evidence_full.log`의 해당 절 참고해 개발자 확인 필요.

---

## 요약

| TC | 기준 수 | PASS | FAIL |
|---|---|---|---|
| TC01 | 4 | 3 | 1 |
| TC02 | 3 | 3 | 0 |
| TC03 | 3 | 2 | 1 |
| TC04 | 4 | 3 | 1 |
| TC05 | 5 | 2 | 3 |
| TC06 | 5 | 1 | 4 |
| TC07 | 3 | 1 | 2 |
| TC08 | 4 | 4 | 0 |
| TC09 | 3 | 3 | 0 |
| TC10 | 3 | 0 | 3 (스크립트 결함, 앱 무관) |
| TC11 | 2(실행분) | 1 | 1 (TC11-1 스크립트 결함) |
| **합계** | **39** | **23** | **16** |

TC11은 `timeout 700` 도달로 TC11-2 이후(원복 검증 등) 완주 못 함 — 위 표는 실행된
부분만 반영.

## 다음 단계 (개발자/사용자 확인 필요, 별도 세션 권장)

- **[중요] TC10/TC11 스크립트를 `docker exec ac_system_gen2 <cmd>` 방식으로 재작성** —
  device_manager와 함께 별도 세션에서 진행하기로 함(2026-08-11 사용자 결정)
- TC05-2/3/4, TC06 전체: watchdog 앱-수-불일치/LED/컨테이너-재시작 판정 FAIL 원인 조사
- TC01-2/TC03-1/TC04-4/TC07-1/TC07-3: 개별 원인 조사
