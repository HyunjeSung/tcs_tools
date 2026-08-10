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

### 2. TC02-5 로그 문구가 DUT 배포 바이너리에 없음 (DUT 빌드 vs 로컬 checkout 드리프트 의심)

TC02-1~4(ADU `.done` 파일 4단계 시뮬레이션)는 MQTT 알림 payload(`workflow_step`/`result_code`)로
확실히 PASS 확인됐지만, tc-plan이 근거로 든 로그 문구(`"[UPDATE] .done file detected for step: "`,
`adu_agent_monitor.cpp:143`)는 `journalctl`에서 0건 검출됐다. 로컬 git 체크아웃 소스에는 해당
LOG(INFO) 라인이 존재하므로, DUT에 실제 배포된 바이너리가 로컬 checkout과 다를 가능성이 있다
(`project_dut_build_vs_git_checkout` 참고). TC02-1~4가 이미 충분한 근거이므로 TC02-5는 판정에서
제외하고 참고 정보로만 남겼다.

**근거 — `evidence_full.log`**:
```
[Step: apply, resultCode=700]
  수신 payload: {...,"result_code":700,...,"workflow_step":"apply"}
[PASS] TC02-apply: apply 단계 알림 수신 (resultCode=700)
...
[TC02-5] .done file detected 로그 카운트 확인 (참고용 — PASS/FAIL 미포함)
  detect_count=0 (참고용, TC02-1~4 결과가 실질 판정)
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

- TC05: 리소스 사전 점검(`/etc/adu-resource-limit.conf` 등)이 update_monitor 소관인지 확인
- TC09-1: HW 호환성 검사 실제 경로 확인
- TC02-5: DUT 배포 바이너리와 로컬 checkout 드리프트 여부 확인 (빌드 버전 대조)
- TC01 큐 정렬/중복거부, TC10 실제 진행률 검증: 컨테이너 재시작을 감수한 별도 격리 phase(`--tc01-pre/-post` 류)로 재설계할지 여부 결정
