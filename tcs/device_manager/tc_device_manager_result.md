# TC 실행 결과 보고서 — device_manager

**최초 실행:** 2026-08-11 13:13 KST (기본 실행 1회차)
**재작업 실행:** 2026-08-12 09:40~09:58 KST (스크립트 수정 후 2회차, TC03 reboot 1사이클 포함)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5 (2회차):** `0775209a78c3fff80124698c3632843d`
**실행 환경:** SSH
**총 결과 (2회차):** **PASS=5 / FAIL=1** (TC03 PASS=3/FAIL=0, TC04 PASS=2/FAIL=1; TC01/TC02는 환경 제약으로 SKIP, TC05는 설계상 SKIP)
**Evidence:** `tcs/device_manager/tc_device_manager_evidence_full.log` (`device_manager_run2` 섹션)

| TC | 결과 |
|---|---|
| TC01 | **SKIP — 이 DUT에서 자동화 불가 (환경 제약, 2026-08-12 확정)** |
| TC02 | **SKIP — 이 DUT에서 자동화 불가 (환경 제약, 2026-08-12 확정)** |
| TC03 | **실제 판정 완료**: PASS=3(TC03-1/2/3) / FAIL=0 (reboot 1사이클 실행) |
| TC04 | **실제 판정 완료**: PASS=2(TC04-1, TC04-3) / FAIL=1(TC04-2) |
| TC05 | SKIP — 자동화 불가(Web HMI 수동 조작), 스텁 |

---

## 확인 사항 (2026-08-12 재작업)

### 배경 — 2026-08-11 1회차의 두 가지 미해결 이슈

1회차 실행 시 TC01~03은 reboot 전제라 미실행, TC04는 `/edge/app/files/commonfile/register_map.json`을
호스트에서 직접 `jq`로 읽으려다 `No such file or directory`로 SKIP됐다. 이후 "TC04 SKIP은
스크립트가 host/container 경로를 혼동한 오판"임을 확인했으나(`docker exec ac_system_gen2 ls -la ...`로
파일 실존 확인), 그 자리에서 재작업하지 않고 별도 세션으로 미뤘다(이전 result.md "다음 단계" 참고).

### 오늘(2026-08-12) 재작업 — 두 단계로 진행

**1단계 — 경로 fix:** `configuration.json`/`register_map.json`을 다루는 모든 host-side
`cp`/`mv`/`jq`/`cat` 호출을 `docker exec ac_system_gen2 <cmd>`로 재작성. 단, **컨테이너 안에는
`jq`가 설치되어 있지 않음**을 실측 확인(`docker exec ac_system_gen2 sh -c 'jq --version'` →
`command not found`) — 그래서 `jq`가 필요한 조회는 전부 `docker exec ac_system_gen2 cat <path> | jq ...`
형태로 컨테이너에서 원본만 꺼내 호스트 `jq`로 파싱하는 구조로 작성했다.

**2단계 — 더 근본적인 발견:** 경로 fix를 TC01-pre(설정 파일 수정 → reboot → 반영 확인)에
적용하기 전, "수정한 파일이 reboot를 버티는지"부터 실측 검증했다. `docker cp`로
`configuration.json`에 `__tc_marker` 필드를 심고, `systemctl restart docker-loader`로
`docker-loader.sh`의 컨테이너 재기동 로직만 별도로 재현(`docker run --rm` 확인됨,
전체 OS reboot 없이도 동일 현상 재현 가능해 검증 사이클을 단축함) → 컨테이너
`Created` 타임스탬프가 바뀌며(재생성 확인) 마커 값이 `null`로 초기화됨을 확인했다.

**결론**: `/edge/app`(configuration.json/register_map.json이 있는 경로)은 `/edge/devapp`,
`/edge/db`, `/edge/log`와 달리 호스트에 bind mount 되어 있지 않다. `db_manager` 소스
(`edge_site_json_data.hpp` `kConfigurationFilePath`, `db_manager.cpp`
`init_configuration()`/`init_register_map()`)를 보면 이 파일이 boot/factory_reset마다
`std::ifstream`으로 다시 읽히는 **진짜 source of truth**가 맞으므로, TC01/TC02가 "파일 수정 →
reboot → 반영 확인"으로 설계된 접근 자체는 타당하다 — 문제는 이 DUT의 컨테이너 기동 방식이
파일 수정의 영속성을 깨뜨린다는 점이다. **TC01/TC02는 이 DUT에서 자동화 불가로 SKIP 처리했다**
(스크립트도 `tc01_pre`/`tc02_pre`가 reboot를 실행하지 않고 SKIP 안내만 출력하도록 수정).
이게 이 테스트보드만의 프로비저닝 누락인지 실제 제품 배포 방식과 다른 것인지(=제품 버그
가능성)는 개발자 확인이 필요한 별도 항목으로 남긴다 — `tc_device_manager.md` "환경 제약"
절 참고.

**근거 — `evidence_full.log` (`device_manager_run2`)**:
```
$ docker exec ac_system_gen2 sh -c 'jq --version' ; which jq
sh: 1: jq: not found
/usr/bin/jq
jq-1.6-145-ga9f97e9e

$ docker cp ac_system_gen2:/edge/app/files/commonfile/configuration.json /tmp/cfg_test.json && \
  jq '.__tc_marker = "before_reboot_test"' /tmp/cfg_test.json > /tmp/cfg_test_marked.json && \
  docker cp /tmp/cfg_test_marked.json ac_system_gen2:/edge/app/files/commonfile/configuration.json && \
  docker exec ac_system_gen2 sh -c 'cat /edge/app/files/commonfile/configuration.json' | jq '.__tc_marker'
"before_reboot_test"

$ docker inspect ac_system_gen2 --format 'Created={{.Created}}'
Created=2026-08-12 09:01:34.97307175 +0900 KST

$ systemctl restart docker-loader; systemctl is-active docker-loader
active

$ docker inspect ac_system_gen2 --format 'Created={{.Created}}'
Created=2026-08-12 09:32:36.19450957 +0900 KST

$ docker exec ac_system_gen2 sh -c 'cat /edge/app/files/commonfile/configuration.json' | jq '.__tc_marker'
null
```

### TC04: 경로 fix 적용 후 실제 판정 완료 — PASS=2 / FAIL=1

수정된 스크립트로 `--tc04` 실행 결과:

| 기준 | 판정 | 근거 |
|------|------|------|
| TC04-1: device_cycle_data 알림 2회 이상 수신 | **PASS** | `msg_count=22` (30초간) |
| TC04-2: 평균 수신 간격이 periodMs ±20% 이내 | **FAIL** | `periodMs=1000`, 실측 `avg_interval_ms=1333` (33% 벗어남, 허용 오차 ±20%=200ms 초과) |
| TC04-3: Read 에러 로그 없음 | **PASS** | `journalctl` `[EL]`+`Failed to read` 매치 없음 |

TC04-2 FAIL은 스크립트 버그가 아니라 **실측 데이터**다 — `register_map.json`의
`periodMs=1000` 설정과 달리 실제 `device_cycle_data` 알림 평균 간격이 1333ms로 측정됐다.
MQTT/캡처 오버헤드인지 실제 폴링 주기 지연인지는 추가 확인이 필요 — `tc_device_manager.md`
TC04절의 "판정 주체가 energy_link일 가능성" 메모와 함께 개발자 확인 권장 항목으로 남긴다.

**근거 (발췌, 전체는 evidence_full.log 참고)**:
```
$ docker exec ac_system_gen2 cat /edge/app/files/commonfile/register_map.json | jq '.. | objects | select(.operation? and (.operation | index("read"))) | {id, operation, periodMs}'
    { "id": "read", "operation": ["read"], "periodMs": 1000 }
    { "id": "read", "operation": ["read"], "periodMs": null }
  대상 periodMs=1000
  msg_count=22 avg_interval_ms=1333
[PASS] TC04-1: device_cycle_data 알림 2회 이상 수신
[FAIL] TC04-2: 평균 수신 간격이 periodMs ±20% 이내
[PASS] TC04-3: Read 에러 로그 없음
```

### TC03: reboot 1사이클 실행 완료 — PASS=3 / FAIL=0

TC03은 파일을 수정하지 않고 정상(pristine) 상태 그대로 reboot 후 로드를 확인하는
대조군이라 위 bind mount 문제와 무관 — 실제로 `--tc03-pre` → reboot → `--tc03-post`를
실행해 3개 기준 모두 PASS를 확인했다.

| 기준 | 판정 | 근거 |
|------|------|------|
| TC03-1: site data ready 로그 존재 | **PASS** | `[EL] Site data ready, creating devices` + `[DM] Site data ready, start connection threads` 둘 다 확인 |
| TC03-2: configuration 응답 비어있지 않음 | **PASS** | `get_configuration_json` 응답에 `deviceList` 등 포함(226KB) |
| TC03-3: register_map 응답 비어있지 않음 | **PASS** | `get_register_map_json` 응답에 `registerMaps` 등 포함(1.27MB) |

**부수적으로 발견한 버그 (스크립트, 수정 완료)**: `TC03_SAVE`(`--tc03-pre`가 저장한 T0
타임스탬프, `--tc03-post`가 읽어서 `journalctl --since`에 사용)가 원래
`/tmp/tc_device_manager_tc03_state`에 저장됐는데, `/tmp`는 ramdisk라 `--tc03-pre`가
실행하는 reboot로 **그 직후 유실**된다 — 이번 실행에서 실측 확인(reboot 후
`--tc03-post`를 그냥 실행하면 "TC03_SAVE 없음" 에러). `TC03_SAVE` 경로를
`/edge/log/.tc_device_manager_tc03_state`(bind mount되어 reboot 후에도 살아남는
경로)로 옮겨 수정했다 — 이번 실행은 T0를 수동으로 복원해 넘어갔지만, 다음 실행부터는
스크립트가 자동으로 정상 동작한다.

**근거**: `evidence_full.log` `device_manager_run2/tc03_post.log` 섹션.

### TC05: 스텁 SKIP (자동화 불가, 설계대로)

Web HMI 수동 조작이 필요해 처음부터 자동화 대상이 아님 — `tc_device_manager.md` 참고.

---

## 요약

| TC | 상태 |
|---|---|
| TC01 | **SKIP (환경 제약 — /edge/app bind mount 없음, 확정)** |
| TC02 | **SKIP (환경 제약 — /edge/app bind mount 없음, 확정)** |
| TC03 | **PASS=3 / FAIL=0 (reboot 1사이클 실측 완료)** |
| TC04 | **PASS=2 / FAIL=1 (실측 완료)** |
| TC05 | SKIP (설계상 자동화 불가) |
| **자동 판정 기준 수** | **6** (TC03-1/2/3, TC04-1/2/3) |

## 다음 단계

- TC04-2 FAIL: `periodMs=1000` 대비 실측 `avg_interval_ms=1333` 원인 확인 (MQTT 캡처
  오버헤드 vs 실제 폴링 지연) — energy_link 쪽 로그/TC와 교차 확인 권장
- TC01/TC02 SKIP의 근본 원인(`/edge/app` bind mount 누락)이 이 테스트보드만의 문제인지
  실제 제품 배포에도 있는 것인지 개발자 확인 필요
