# TC 실행 결과 보고서 — sys_manager

**최초 실행:** 2026-08-11 10:19 ~ 11:25 KST (3회차, 최종 검증 run은 11:1x~11:25)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `82f4dd5b5930a428c47bef7a01c866e7`
**실행 환경:** SSH (COM7 시리얼 미인식으로 fallback)
**총 결과:** **PASS=45 / FAIL=2** (TC12 reboot phase·TC14는 default 실행에서 제외/SKIP)
**Evidence:** `tcs/sys_manager/tc_sys_manager_evidence_full.log`

| TC | 결과 |
|---|---|
| TC01-1/2 | PASS/PASS |
| TC02-1/2/3 | PASS/PASS/PASS |
| TC03 (5단계) | PASS×5 |
| TC04-1/2/3 | PASS/PASS/PASS |
| TC05-1 | PASS |
| TC05-2/3 | **FAIL** (production_date 포맷 미확인, 개발자 확인 필요) |
| TC05-4 | PASS (cleanup 원복 확인) |
| TC06-1/2/3 | PASS/PASS/PASS |
| TC07 (5단계) | PASS×5 |
| TC08-1/2/3/4 | PASS×4 |
| TC09-1/2/3 | PASS×3 |
| TC10-1/2/3/4/5 | PASS×5 |
| TC11-1/2/3 | PASS×3 |
| TC12 | 미실행 (reboot 격리 phase — `--tc12-pre`/`--tc12-post`, 이번 회차 범위 밖) |
| TC13-1/2 | PASS/PASS |
| TC14 | SKIP (스텁 — tc_sys_manager.md 참고, 개발자 검토 대기) |
| TC15 (5단계) | PASS×5 |

---

## 시험 과정에서 발견된 핵심 이슈 (개발자 확인 권장)

### 1. (스크립트 버그, 수정 완료) `send_and_wait`의 payload envelope이 uniep 프레임워크와 불일치 — 파라미터 있는 요청 전부 실패

최초 1차 실행(PASS=21/FAIL=14)에서 파라미터를 포함하는 요청(TC03 set_ntp, TC05
set_eeprom_info, TC07 set_ethernet_config, TC09/10 cmd_host 등)이 전부
`"Missing required parameter: ..."` 로 실패했다. 원인 확인을 위해 `sys_manager.cpp`의
`handle_req_cmd_host`/`handle_req_set_ntp`를 읽어보니 `message.contains("cmd")`처럼
수신 JSON(`message`)에서 필드를 **바로** 읽고 있었다 — `update_monitor`의
`handle_request_batch_update`(`update_monitor.cpp:6668-6671`)에 있는
`if (payload.contains("payload")) payload = payload["payload"];` 같은 언래핑 코드가
sys_manager 쪽엔 없다.

`tc_sys_manager.sh`의 `send_and_wait()`가 `{"tid":"...","payload":{...}}` 형태로
한 겹 더 감싸 보내고 있었던 게 원인 — DUT에서 직접 `mosquitto_pub`으로 flat 포맷
(`{"tid":"...","cmd":"..."}`)을 보내보니 정상 응답이 왔다(아래 근거). `send_and_wait()`를
`jq -c --arg tid "$tid" '. + {tid: $tid}'` 로 payload 필드를 최상위로 flatten하도록
수정 → 재실행 결과 PASS=21→44로 즉시 개선. **이 패턴은 신규 8개 앱(sys_manager 포함
uniep 기반 6개: db_manager/device_manager/azure_connector/edge_runtime/energy_monitor)
스크립트에 동일하게 있어서 실행 전 미리 전체 수정함** — `system_log`/`device_log`/
`update_monitor`(ac_system_gen2 자체 프레임워크 또는 호환 언래핑 보유)는 영향 없음.

**근거 (수정 전, flat 포맷 직접 검증)**:
```
$ mosquitto_pub -h localhost -t emsp/sys_manager/tc_runner/req/cmd_host -m '{"tid":"probe1","cmd":"hwclock --show"}'
응답: {"error_code":"NONE","payload":{"cmd":"hwclock --show","exit_code":0,"message":"2026-08-11 10:29:38...","status":"success"}}
```
**근거 — `evidence_full.log`** (수정 후 재실행, TC09/TC10 전부 PASS):
```
whitelist 명령(hwclock --show) 응답: {"error_code":"NONE","payload":{"cmd":"hwclock --show",...,"status":"success"}}
[PASS] TC09-1: whitelist 명령(hwclock --show) 성공 응답
```

### 2. (스크립트 버그, 수정 완료) TC10-4 온도 비교에서 float 산술 문법 오류로 스크립트 조기 종료

`get_system_info`가 반환하는 `temperature[0].value`가 `44000.0`(float)인데
`diff=$(( sysfs_temp - temp_reported ))` 처럼 busybox ash 정수 산술(`$(( ))`)에 그대로
넣어 `syntax error: invalid arithmetic operator (error token is ".0")`로 스크립트가
TC10에서 죽어 TC11 이후를 전혀 실행하지 못했다(1차 실행 로그 마지막 줄). `awk` 기반
절대값 비교로 교체해 해결.

**근거 (1차 실행, 수정 전)**:
```
temp_reported=44000.0 sysfs_temp=44000
/tmp/tc_sys_manager.sh: line 458: 44000.0: syntax error: invalid arithmetic operator (error token is ".0")
exit=1
```

### 3. (스크립트 버그, 수정 완료) TC02-2가 존재하지 않는 응답 필드를 검사

`get_iptables_status` 응답 payload는 `rules_text`/`service_active`만 있고 `status`
필드가 아예 없는데, TC02-2가 `grep -q '"status":"success"'`로 판정해 항상 FAIL이었다.
이 서비스의 성공 여부는 envelope의 `error_code`로 판정하도록 수정.

**근거 — `evidence_full.log`**:
```
get_iptables_status 응답: {"error_code":"NONE","payload":{"rules_text":"...","service_active":true}}
[PASS] TC02-2: 응답 error_code가 NONE(성공)
```

### 4. TC05-2/3 FAIL — EEPROM `production_date` 쓰기 포맷 확인 안 됨 (개발자 확인 필요)

`get_eeprom_info`가 반환하는 현재 `production_date` 값이 `255/BAD/65535`로, EEPROM
자체가 정상 프로비저닝되지 않은 것으로 보인다(0xFF/0xFFFF류 sentinel 패턴). 쓰기 시도
포맷을 `YYYYMMDD`/`YYYY-MM-DD`/`YYYY/MM/DD`/`DD/MM/YYYY`/`MM/DD/YYYY`/`DD-MM-YYYY`
6종 모두 시도했으나 전부 `CMD_HAL failed: Input error: ... Syntax error - Operation
Aborted!`로 거부됨. 검증 로직은 `sys_manager` C++ 코드가 아니라 `send_hal_command
("eeprom","0","set","info", "\"Production Date=<value>\"")`(`sys_info.cpp:463`)로
넘어가는 외부 HAL 바이너리 쪽에 있어 로컬 checkout만으로는 정확한 포맷을 확인할 수
없다. **개발자가 실제 허용 포맷(또는 HAL 문서)을 확인해줘야 TC05-2/3을 완성할 수 있음.**

**근거 — `evidence_full.log`**:
```
before_date=255/BAD/65535
set_eeprom_info 응답: {"error_code":"UNKNOWN","payload":{"exit_code":1,"message":"CMD_HAL failed: Input error: Invalid value \"19991231\" for field \"Production Date\" - Syntax error - Operation Aborted!\n","status":"error"}}
[FAIL] TC05-2: set_eeprom_info 성공 응답
```

---

## 요약

| TC | 기준 수 | PASS | FAIL |
|---|---|---|---|
| TC01 | 2 | 2 | 0 |
| TC02 | 3 | 3 | 0 |
| TC03 | 5 | 5 | 0 |
| TC04 | 3 | 3 | 0 |
| TC05 | 4 | 2 | 2 |
| TC06 | 3 | 3 | 0 |
| TC07 | 5 | 5 | 0 |
| TC08 | 4 | 4 | 0 |
| TC09 | 3 | 3 | 0 |
| TC10 | 5 | 5 | 0 |
| TC11 | 3 | 3 | 0 |
| TC13 | 2 | 2 | 0 |
| TC15 | 5 | 5 | 0 |
| **합계** | **47** | **45** | **2** |

TC12(reboot)는 이번 회차 범위 밖(`--tc12-pre/-post` 별도 실행 필요), TC14는 스텁 SKIP.

## 다음 단계 (개발자 검토 필요)

- TC05-2/3: EEPROM `production_date` 실제 허용 입력 포맷 확인 (HAL 바이너리/문서 확인 필요)
- TC12: reboot를 감수하는 별도 phase로 실제 실행할지 여부 (Safe Reboot 시나리오)
