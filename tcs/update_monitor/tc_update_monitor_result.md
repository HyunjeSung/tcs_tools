# TC 실행 결과 보고서 — update_monitor

**최초 실행:** 2026-08-10 16:22 ~ 17:10 KST (여러 회차, 최종 검증 run은 17:0x경)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `99494d9cfc6bfefba90246f2eeca11a8`
**실행 환경:** SSH (일부 구간 SSH 무응답 시 시리얼 COM6 병행)
**총 결과:** **PASS=10 / FAIL=0** (TC04/05/06/07/10 SKIP)
**Evidence:** `tcs/update_monitor/tc_update_monitor_evidence_full.log`

| TC | 결과 |
|---|---|
| TC01-1/2 | PASS/PASS |
| TC02 (4단계) | PASS×4 |
| TC03-1 | PASS |
| TC04 | SKIP (OTA_MOCK 미확보) |
| TC05 | SKIP (개발자 검토 대기) |
| TC06 | SKIP (host 미확보) |
| TC07 | SKIP (mock lookup 미확보) |
| TC09-1 | SKIP (검토 필요, `/etc/hwrevision` 미확인) |
| TC10 | SKIP (진행률 발생 소스 없음) |
| TC11-1/2/3 | PASS/PASS/PASS |

---

## 시험 과정에서 발견된 핵심 이슈 (개발자 확인 권장)

### 1. TC01 원본 설계가 실제로는 파괴적 시험이었음 — 발견 후 재설계

최초 tc-plan 초안은 TC01에서 `batch_update_request`로 더미 `.swu` 파일 2개(우선순위 정렬용)를
실제로 접수시키는 시나리오였다. 1차 실행(evidence 미보존, PASS=11/FAIL=7)에서 JSON 필드명이
`file_path`가 아니라 `path`(`update_monitor.cpp:6688`)여야 함을 발견해 수정 → 재실행했더니
실제로 접수(accepted)되면서 `swupdate -i` 커맨드가 cmd_host로 진짜 발사됐고, **배치 종료(성공/실패
무관) 시 앱 컨테이너 전체 재시작(`update_monitor.cpp:7300-7328`, `SERVICE_REBOOT_APPLICAITON`)이
실제로 발생**함을 확인했다(`docker ps` → `Up 15 minutes` 등 타이밍 일치, 핵심 프로세스는 재기동 후
정상 확인). 더미 파일로도 재현되므로 회귀 세트에 안전하게 포함할 수 없다고 판단, **TC01을 "큐에
아예 안 들어가는 거부 경로"만 검증하도록 축소**했다(`tc_update_monitor.sh` TC01 함수 주석 참고).
큐 정렬/중복거부(진행 중 상태) 검증은 TC12(자동화 불가 목록)로 이동.

**근거 — `evidence_full.log`**:
```
[TC01-1] device_type 누락 entry 만 있는 요청 발행 (큐에 안 들어가고 거부되어야 함)
  resp: {"error_code":"NONE","payload":{"reason":"No valid SWU files in request","result":"rejected"}}
[PASS] TC01-1: device_type 누락 entry 거부 (큐 미적재)
[TC01-2] 빈 files 배열 요청 발행
  resp: {"error_code":"NONE","payload":{"reason":"Missing or empty 'files' array in request","result":"rejected"}}
[PASS] TC01-2: 빈 files 배열 거부
```

### 2. (정정, 2026-08-11) TC02-5 "detect_count=0" 은 result.md 작성 시 옮겨적기 오류 — 드리프트 아님

최초 result.md에는 TC02-5 `detect_count=0`으로 기록돼 DUT 배포 바이너리가 로컬 git
checkout과 다를 가능성(드리프트)을 의심했으나, `evidence_full.log` 원본을 다시 확인한 결과
**실제 값은 `detect_count=4`** (evidence_full.log:517) — TC02-1~4 각 단계마다 `[UPDATE] .done
file detected for step: ...`(`adu_agent_monitor.cpp:143`) 로그가 정확히 1건씩, 총 4건 모두
정상 기록돼 있었다(예: `17:07:06 ... [UPDATE] .done file detected for step: is-installed,
mtime: -4651314773`). DUT BUILD_DATE(`2026/08/07 05:25:58`)와 해당 소스 라인의 마지막 커밋
(`a5abe4506`, 2025-06-19)을 대조해도 드리프트를 의심할 이유가 없다 — 애초에 로그 자체가
정상 검출됐으므로 드리프트 가설은 성립하지 않는다. **결론: 드리프트 없음, 이전 문서화가
잘못됐던 것.** 아래는 정정된 근거.

**근거 — `evidence_full.log`**:
```
[Step: apply, resultCode=700]
  수신 payload: {...,"result_code":700,...,"workflow_step":"apply"}
[PASS] TC02-apply: apply 단계 알림 수신 (resultCode=700)
[TC02-5] .done file detected 로그 카운트 확인 (참고용 — PASS/FAIL 미포함)
  $ journalctl -u docker-loader --since 5 minutes ago
    Aug 10 17:07:06 qcells-emsplus docker-loader[33385]: [17:07:06:714][I][UM] [UPDATE] .done file detected for step: is-installed, mtime: -4651314773
    Aug 10 17:07:08 qcells-emsplus docker-loader[33385]: [17:07:08:084][I][UM] [UPDATE] .done file detected for step: download, mtime: -4651314772
    Aug 10 17:07:10 qcells-emsplus docker-loader[33385]: [17:07:10:094][I][UM] [UPDATE] .done file detected for step: install, mtime: -4651314769
    Aug 10 17:07:11 qcells-emsplus docker-loader[33385]: [17:07:11:407][I][UM] [UPDATE] .done file detected for step: apply, mtime: -4651314768
  detect_count=4 (참고용, TC02-1~4 결과가 실질 판정)
```

### 3. TC11에서 "Another update is already in progress" 관측 (판정에는 무관)

TC11-1 응답에 `energy_dispatcher` 앱이 `"reason":"Another update is already in progress"`로
`NOT_READY` 상태를 보고했다. TC11-1은 "응답 수신 여부"만 판정하므로 PASS에는 영향 없지만, 이전
회차의 실제 배치 처리(위 1번 이슈) 여파로 다른 앱의 FSM 상태가 일시적으로 영향받았을 가능성이
있어 참고로 남긴다 — 이후 재실행에서는 재현되지 않으면 무시해도 됨.

**근거 — `evidence_full.log`**:
```
[Step3] update_precheck 요청 발행 (trigger_type=local_script, source=swupdate_docker_pull_pre_script)
  resp: {..."app_status":[{"app_id":"energy_dispatcher","is_ready":false,"reason":"Another update is already in progress"}],..."result":"rejected",...}
[PASS] TC11-1: update_precheck 응답 수신
```

### 4. TC09-1 `/etc/hwrevision` 미확인

소스 코드(update_monitor 전체) 및 DUT 파일시스템 어디에도 `/etc/hwrevision` 근거가 없음 — HW
호환성 검사의 실제 메커니즘/경로를 개발자가 확인해줄 것. SKIP 처리.

---

## 요약

| TC | 기준 수 | PASS | FAIL | SKIP |
|---|---|---|---|---|
| TC01 | 2 | 2 | 0 | 0 |
| TC02 | 4 | 4 | 0 | 0 (TC02-5 참고용 제외) |
| TC03 | 1 | 1 | 0 | 0 |
| TC04 | 0 | 0 | 0 | 1 |
| TC05 | 0 | 0 | 0 | 1 |
| TC06 | 0 | 0 | 0 | 1 |
| TC07 | 0 | 0 | 0 | 1 |
| TC08 | 0 | 0 | 0 | 1 (준비물 없음) |
| TC09 | 0 | 0 | 0 | 1 |
| TC10 | 0 | 0 | 0 | 1 |
| TC11 | 3 | 3 | 0 | 0 |
| **합계** | **10** | **10** | **0** | **7 (SKIP)** |

TC12는 자동화 불가 항목 목록(문서 전용, PASS/FAIL 대상 아님).

## 다음 단계 (개발자 검토 필요)

- **TC05 (정정, 2026-08-11):** `/etc/adu-resource-limit.conf`, `MIN_DISK_KB`/`MIN_MEM_KB`,
  resultCode 905001/905002 근거를 `application/update_monitor` 뿐 아니라
  `ac_system_gen2` 전체 + `uniep/host_agent`까지 확장해 재검색했으나 **어디에도
  구현이 없다** (`grep -rln`, 0건). DUT에도 `/etc/adu-resource-limit.conf` 파일 자체가
  없음(`ls`: No such file or directory). **결론: 현재 코드베이스에는 미구현으로 보임** —
  Key107 요구사항이 아직 개발되지 않았거나, 로컬에 체크아웃되지 않은 별도 저장소(클라우드
  측 등)에 있을 가능성. 개발자 확인 필요.
- **TC09-1 (정정, 2026-08-11):** hwrevision 검사는 update_monitor 코드가 아니라
  swupdate 바이너리 네이티브 기능이 맞음 — DUT `/usr/bin/swupdate`에 `strings`로
  `check_hw_compatibility`, `/etc/hwrevision` 문자열이 실제로 존재함을 확인(컴파일에
  포함됨). 다만 **DUT 파일시스템에 `/etc/hwrevision` 파일 자체가 없음**(`ls`: No such
  file or directory) — SWUpdate 표준 동작상 `SWUPDATE_HW_COMPATIBILITY_FILE`이 없으면
  hw 호환성 체크를 건너뛴다. 즉 **현재 이 DUT 빌드에서는 hw 호환성 체크가 사실상
  비활성 상태**로 보인다. TC09를 의미 있게 검증하려면 `/etc/hwrevision` 파일이 이 빌드에
  provisioning 되어야 하는지(빠졌다면 왜) 개발자 확인 필요.
- TC02-5: ~~드리프트 의심~~ → 위 2번 항목에서 정정 완료, 드리프트 아님(result.md 옮겨적기
  오류였음). 추가 조치 불필요.
- TC01 큐 정렬/중복거부, TC10 실제 진행률 검증: 컨테이너 재시작을 감수한 별도 격리 phase(`--tc01-pre/-post` 류)로 재설계할지 여부 결정 (사용자 판단 필요)
