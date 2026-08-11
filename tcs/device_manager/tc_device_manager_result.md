# TC 실행 결과 보고서 — device_manager

**최초 실행:** 2026-08-11 13:13 KST (기본 실행 1회차)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `e720d664a22caed6cc550ccc63dd69cd`
**실행 환경:** SSH (COM7 시리얼 미인식으로 fallback)
**총 결과:** **PASS=0 / FAIL=0** — 기본 실행 범위 내 자동 판정 대상 없음(아래 사유 참고)
**Evidence:** `tcs/device_manager/tc_device_manager_evidence_full.log`

| TC | 결과 |
|---|---|
| TC01 | 미실행 — reboot 격리 phase(`--tc01-pre`/`--tc01-post`), 별도 실행 필요 |
| TC02 | 미실행 — reboot 격리 phase(`--tc02-pre`/`--tc02-post`), 별도 실행 필요 |
| TC03 | 미실행 — reboot 격리 phase(`--tc03-pre`/`--tc03-post`), 별도 실행 필요 |
| TC04 | SKIP — **정정(2026-08-11): 오판이었음**, 아래 근거 참고 |
| TC05 | SKIP — 자동화 불가(Web HMI 수동 조작), 스텁 |

---

## 확인 사항

### TC01~TC03: reboot 전제 — 이번 회차(기본 실행)에서는 미실행

세 TC 모두 `configuration.json`/`factory_reset` 변경 후 reboot을 요구하는 pre/post
분리 구조라 기본 실행에 포함되지 않는다(스크립트 자체 안내 메시지, 아래 근거). 다른
6개 앱과 달리 device_manager는 기본 실행만으로는 실질적 회귀 검증이 거의 안 되는
구조라, **reboot 3사이클을 감수하는 별도 세션에서 `--tc01-pre/post` ~
`--tc03-pre/post`를 순서대로 실행해야** 실제 PASS/FAIL을 얻을 수 있다.

**근거 — `evidence_full.log`**:
```
[안내설명] TC01~TC03은 reboot을 수반하므로 이 스크립트 단독 실행에서는 실행하지 않음(SSH 세션 끊김).
  ./tc_device_manager.sh --tc01-pre   (configuration.json 세팅 + factory_reset + reboot)
  ./tc_device_manager.sh --tc01-post  (재연결 후 검증 + teardown reboot)
  ./tc_device_manager.sh --tc02-pre   (configuration.json 세팅 + factory_reset + reboot)
  ./tc_device_manager.sh --tc02-post  (재연결 후 검증 + teardown reboot)
  ./tc_device_manager.sh --tc03-pre   (레지스터 값 조작 시나리오 세팅 + reboot, TC02 teardown 이후 실행)
  ./tc_device_manager.sh --tc03-post  (재연결 후 검증 + teardown reboot)
```

### TC04: (정정, 2026-08-11) SKIP은 오판 — `register_map.json`은 실제로 존재함, 스크립트가 host/container 경로를 혼동

최초 판단(`/edge/app/files/`가 없어 사이트 미프로비저닝)은 **틀렸다**. `ac_system_gen2`
컨테이너의 `podman run` 커맨드를 확인하니 `/edge/app`은 바인드 마운트 목록에 없다 —
`/edge/sp`,`/edge/db`,`/edge/etc`,`/edge/log`,`/edge/devapp`만 호스트-컨테이너 공유고,
`/edge/app`(bin/files 전부)은 **이미지에 baked-in된 컨테이너 전용 파일시스템**이라
SSH로 접속한 호스트에서는 애초에 안 보이는 게 정상이다. 실제로
`docker exec ac_system_gen2 ls -la /edge/app/files/commonfile/register_map.json`으로
확인하니 1,271,179바이트 파일이 2022-11-15부터 정상 존재한다(사이트 프로비저닝 문제
아님). **TC04는 register_map.json을 직접 읽는 모든 `jq`/`cat` 호출을
`docker exec ac_system_gen2 <cmd>`로 감싸야 정상 동작한다** — 이번 회차의 SKIP은
스크립트 결함으로 인한 오판이었고, 재작업은 TC01~03과 함께 별도 세션에서 진행하기로
함(2026-08-11 사용자 결정, [[project_tc_dashboard]] 계열 결정 이력 참고).

**근거**:
```
(수정 전, 오판 당시) $ jq .. /edge/app/files/commonfile/register_map.json
    jq: error: Could not open file ...: No such file or directory
(재확인, 2026-08-11) $ docker exec ac_system_gen2 ls -la /edge/app/files/commonfile/register_map.json
    -rw-r--r-- 1 root root 1271179 Nov 15  2022 /edge/app/files/commonfile/register_map.json
```

### TC05: 스텁 SKIP (자동화 불가, 설계대로)

Web HMI 수동 조작이 필요해 처음부터 자동화 대상이 아님 — `tc_device_manager.md` 참고.

---

## 요약

| TC | 상태 |
|---|---|
| TC01~TC03 | 미실행 (reboot 별도 세션 필요) |
| TC04 | SKIP (스크립트가 host/container 경로 혼동 — 오판, 재작업 필요) |
| TC05 | SKIP (설계상 자동화 불가) |
| **자동 판정 기준 수** | **0** |

## 다음 단계 (별도 세션 진행 예정, 2026-08-11 사용자 결정)

- TC01~TC04: `configuration.json`/`register_map.json`을 다루는 모든 host-side
  `cp`/`mv`/`jq`/`cat` 호출을 `docker exec ac_system_gen2 <cmd>`로 재작성 필요
  (edge_runtime TC10/TC11과 동일 근본 원인, `tc_edge_runtime_result.md` 핵심 이슈 1 참고)
- 위 재작성 후 TC01~03은 reboot 3사이클을 감수하는 별도 세션에서 pre/post 순서대로 실행
