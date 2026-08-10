---
spec_id: sys_manager
suite: application
grade: B
phase: Phase 1
test_file: tcs/sys_manager/tc_sys_manager.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-SYS_MANAGER: sys_manager — Host 시스템 서비스(시스템 시간/네트워크/EEPROM/Safe Reboot 등)

## 목적 (Objective)

`sys_manager` 애플리케이션의 System Time 관리(NTP), Internet 연결 관리, Host Network
Interface 관리, EEPROM Nameplate 관리, Host Agent 연동(UDS), Host Command 지원
(`SERVICE_CMD_HOST`), HW별 Configuration, Safe Reboot, 악성코드 점검(chkrootkit),
방화벽(iptables) 조회, System Info 모니터링, LED 제어까지 sys_manager가 책임지는
Host 서비스 전 기능을 검증한다.

이 문서는 사내 `AC Gen2 TestCase.xlsx`의 "Host Service" 카테고리 원본 15개
TC(원본 Key 109-120, 187, 188, 190, `docs/tc_requirements/sys_manager.md`)를 기준으로
작성했다. 원본 다수가 Web HMI 수동 조작, 실제 LED 육안 확인, 사내 Confluence
Open-Ports 문서 대조처럼 사람이 개입해야 검증 가능한 항목을 포함하므로, 본
문서는 그중 **DUT에 SSH/시리얼로 접속해 셸 스크립트/MQTT로 자동 검증 가능한
부분만 TC로 재구성**했다. 완전히 자동화 불가능한 항목은 TC16에 목록으로
모았다.

> **중요 발견 — 요구사항과 소스 코드 불일치 다수 확인됨:**
> - TC-5(EEPROM)의 원본 `eeprom_test.sh dump|write-json` 인터페이스는 저장소의
>   실제 스크립트(`sources/meta-qcells-bsp-emsplus/recipes-utils/hw-iface-tests/files/eeprom_test.sh`)
>   와 다르다 — 그 스크립트는 인자를 받지 않으며(`$# -ne 0`이면 즉시 실패)
>   `Major Revision` 필드만 왕복 검사한다. 대신 sys_manager 자체 IPC
>   (`get_eeprom_info`/`set_eeprom_info`)로 동일 기능을 더 정확하게 검증한다 (TC05).
> - TC-9(Host Agent Event Logging)의 "성공 명령 → `[I][HA] COMPONENT_REPORT
>   requested`" 기대 로그는 근거가 없다 — `COMPONENT_REPORT`는 LED 검색 등
>   별도 이벤트에서만 발생하며 `hwclock --show` 실행과 무관하다. 또한
>   host_agent 기본 로그 레벨은 `info`이고(`host_agent/config/AC_SYSTEM_GEN2.yaml`
>   `logging.level: info`), whitelist 통과/CMD_EXEC 감사 로그는 전부 `DEBUG`
>   레벨이라 기본 설정에서는 journalctl에 나타나지 않는다. 반대로 **차단된
>   명령**은 `WARNING` 레벨(`log_message(LogLevel::WARNING, "Shell command
>   blocked by whitelist: " + command)`)이라 기본 설정에서도 확인 가능하다 —
>   TC09는 이 차단 경로만 확정 근거로 작성했다.
> - TC-11(HW별 Configuration)의 원본 `get_platform_info` 예시 응답은 키를
>   대문자(`"ID"`, `"BUILD_MODEL"`, `"BUILD_DATE"` 등)로 표기하지만, 실제
>   `PlatformInfo` 구조체(`sys_info_parse.hpp`)의 JSON 필드명은 소문자
>   (`id`, `name`, `build_type`, `build_version`, `build_host_model`,
>   `build_host_date`, `is_valid` 등)다. TC11에 이 케이스 불일치를 명시했다.

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(COM7, 115200 8N1) 접속 가능
- DUT에서 `sys_manager` 프로세스 실행 중 (`pgrep -f sys_manager`)
- DUT에서 `host-agent` 프로세스 실행 중이며 sys_manager와 UDS 연결됨
  (`sys_host_->is_connected() == true` — `get_system_info` 응답이 정상 수신되면 간접 확인)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨
- root 권한 (NTP/시간 변경, iptables 조회, journalctl 조회, host-agent 재시작)

> **주의(파괴적 시험 가능성):** TC01은 시스템 시간을 변경한다(NTP off 후 복원 필요).
> TC08은 `systemctl restart host-agent`로 실제 서비스를 재시작한다. TC12는 실제
> DUT reboot(safe reboot)를 유발한다 — 시리얼 helper(`serial_helper.ps1`) 사용을
> 권장한다(project memory `feedback_serial_vs_ssh_polling` 참고).

---

## TC01 — 악성코드 점검(chkrootkit) 매일 02:00 자동 실행

### 목적

`sys_manager`의 보안 모니터링 스레드가 매일 02:00에 `chkrootkit -q -n`을
host_agent 경유로 실행하고, 결과를 파싱하여 findings 개수를 로그로 남기는지
확인한다.

### 사전 조건

- 공통 전제 조건 충족
- 시스템 시간 변경 권한 (root), NTP 비활성화 가능 (`timedatectl set-ntp false`)
- `chkrootkit -q -n`이 host_agent whitelist에 등록되어 있음(exact match) —
  별도 조치 불필요

### 절차

1. `date; timedatectl` 로 현재 시간 기록 후 `timedatectl set-ntp false` 로 NTP 비활성화
2. `journalctl -u docker-loader -f | grep -i "security"` 를 백그라운드로 구독 시작
   (sys_manager 로그가 `docker-loader` 서비스 유닛에 기록되는 구조 — 다른 TC 문서와 동일)
3. 시스템 시간을 `date -s "HH:01:58:00"` 형태로 02:00 2분 전으로 설정
4. 02:00을 지나도록 3~4분 대기
5. `journalctl -u docker-loader --since "<설정한 01:58>" | grep -E "Executing scheduled security check|Security monitoring|Daily security check|Security check completed"` 로 실행 로그 확인
6. `journalctl -u docker-loader --since "<설정 시각>" | grep -E "finding\(s\)|No suspicious activity detected"` 로 결과 로그 확인
7. cleanup: 시스템 시간을 NTP로 복원(`timedatectl set-ntp true`)

### 기대 결과

| 항목 | 기준 |
|------|------|
| 스케줄 실행 로그 | `"Executing scheduled security check (2 AM)"` 출현 |
| 실행 완료 로그 | `"Security check completed with N finding(s)"` 또는 `"No suspicious activity detected"` 출현 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | 02시 스케줄 트리거 로그 출현 | boolean | true | `journalctl -u docker-loader --since "$SET_TIME" \| grep -q "Executing scheduled security check"` |
| TC01-2 | 보안 점검 완료 로그 출현 | boolean | true | `journalctl -u docker-loader --since "$SET_TIME" \| grep -qE "Security check completed with|No suspicious activity detected"` |

---

## TC02 — 방화벽(iptables) 규칙 조회 (Open Ports 문서 대조는 범위 밖)

### 목적

`get_iptables_status` IPC 요청 및 직접 `iptables -L -n` 실행 결과가 정상적으로
조회되는지 확인한다. (원본 TC-2의 "사내 Confluence Open Ports List와 수동
대조" 서브스텝은 자동화 범위 밖 — TC16에 명시)

### 사전 조건

- 공통 전제 조건 충족
- `iptables` 서비스 상태 조회 가능

### 절차

1. `mosquitto_sub -t "emsp/tc_runner/sys_manager/res/+" -C 1 &` 구독 시작
2. `mosquitto_pub -t "emsp/sys_manager/tc_runner/req/get_iptables_status" -m '{"tid":1,"source":"tc_runner"}'` 발행
3. 응답 payload에서 `is_active`, `rules_text`(또는 유사 필드) 확인
4. 직접 `iptables -L -n -v` 실행 결과와 비교 (규칙 개수/체인이 유사한지)

### 기대 결과

| 항목 | 기준 |
|------|------|
| get_iptables_status 응답 | `error_code: NONE`, `status: success`, 규칙 텍스트 비어있지 않음 |
| 직접 조회 결과 | `iptables -L -n -v` 정상 출력 (체인 INPUT/FORWARD/OUTPUT 존재) |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC02-1 | get_iptables_status 응답 수신 | boolean | true | `[ -n "$resp" ]` |
| TC02-2 | 응답 status가 success | boolean | true | `echo "$resp" \| grep -q '"status":"success"'` |
| TC02-3 | 직접 iptables 조회 시 INPUT 체인 존재 | boolean | true | `iptables -L -n -v \| grep -q "^Chain INPUT"` |

> Open Ports List(Confluence) 문서와의 수동 대조는 TC16(자동화 불가 목록) 참고.

---

## TC03 — System Time 관리 (NTP on/off 및 상태 조회)

### 목적

`set_ntp` IPC 요청으로 NTP를 비활성화/활성화할 수 있고, `get_ntp_status`
응답의 `ntp_service` 필드가 그 상태를 정확히 반영하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- `systemctl --runtime mask/unmask systemd-timesyncd`, `systemctl start/kill
  systemd-timesyncd` 가 host_agent whitelist에 exact match로 등록됨

### 절차

1. `mosquitto_pub -t "emsp/sys_manager/tc_runner/req/set_ntp" -m '{"tid":1,"source":"tc_runner","enabled":false}'` 발행 → 응답 확인
2. `mosquitto_sub -C 1` 로 `get_ntp_status` 요청 후 응답의 `ntp_service` 필드가 `false`인지 확인
3. 직접 `systemctl is-active systemd-timesyncd` 로 서비스가 `masked`/비활성 상태인지 교차 확인
4. `set_ntp` `enabled:true` 발행 → 응답 확인
5. `get_ntp_status` 재조회 → `ntp_service`가 `true`인지 확인
6. 직접 `systemctl is-active systemd-timesyncd` 로 서비스가 활성 상태인지 교차 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| set_ntp(false) 응답 | `{"status":"success","message":"NTP disabled"}` |
| get_ntp_status(after false) | `data.ntp_service == false` |
| set_ntp(true) 응답 | `{"status":"success","message":"NTP enabled"}` |
| get_ntp_status(after true) | `data.ntp_service == true` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC03-1 | set_ntp(false) 성공 응답 | boolean | true | `echo "$resp" \| grep -q '"status":"success"'` |
| TC03-2 | get_ntp_status에서 ntp_service=false | boolean | true | `echo "$resp" \| grep -q '"ntp_service":false'` |
| TC03-3 | set_ntp(true) 성공 응답 | boolean | true | `echo "$resp" \| grep -q '"status":"success"'` |
| TC03-4 | get_ntp_status에서 ntp_service=true | boolean | true | `echo "$resp" \| grep -q '"ntp_service":true'` |
| TC03-5 | systemd-timesyncd 활성 상태 최종 복원 | boolean | true | `systemctl is-active systemd-timesyncd` 출력이 `active` |

---

## TC04 — System Info 모니터링 (get_system_info)

### 목적

`get_system_info` IPC 응답이 CPU 사용률, 메모리 사용률, 온도, 스토리지
사용률을 정상적으로 반환하고, `top`/`/proc` 직접 조회 값과 동일한 범위에
있는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- `temperature`/`storage` HAL 컴포넌트가 구성됨 (`sys_host_->has_component()`)

### 절차

1. `mosquitto_sub -C 1` 로 `get_system_info` 요청/응답 수신
2. 응답 payload에서 `data.cpu_usage_1min`, `data.memory_usage`, `data.temperature[]`,
   `data.storage_usage[]`, `data.is_valid` 확인
3. `top -bn1 | head -5` 직접 실행하여 CPU/메모리 값이 응답값과 상식적 범위에서
   일치하는지 비교 (완전 동일치는 아닐 수 있음 — 순간값 차이 허용)

### 기대 결과

| 항목 | 기준 |
|------|------|
| get_system_info 응답 | `data.is_valid == true`, `cpu_usage_1min >= 0`, `memory_usage` 0~100 범위 |
| top 직접 조회 | Tasks/%Cpu(s)/MiB Mem 라인 정상 출력 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC04-1 | get_system_info 응답 is_valid=true | boolean | true | `echo "$resp" \| grep -q '"is_valid":true'` |
| TC04-2 | memory_usage 0~100 범위 | boolean | true | `mem=$(echo "$resp" \| jq '.payload.data.memory_usage'); awk -v m="$mem" 'BEGIN{exit !(m>=0 && m<=100)}'` |
| TC04-3 | top 직접 조회 정상 출력 | boolean | true | `top -bn1 \| head -5 \| grep -q "MiB Mem"` |

---

## TC05 — EEPROM Nameplate 관리 (get/set_eeprom_info)

### 목적

`get_eeprom_info`가 EEPROM에 저장된 Nameplate 정보(모델명/시리얼/생산일 등)를
정상 반환하고, `set_eeprom_info`로 일부 필드(`production_date`)를 변경한 뒤
재조회 시 변경 값이 반영되는지 확인한다.

> 원본 요구사항의 `eeprom_test.sh dump`/`write-json` 인터페이스는 저장소의
> 실제 스크립트와 인자 체계가 다르다(위 "중요 발견" 참고). 동일 검증 목적을
> sys_manager 자체 IPC로 대체한다.

### 사전 조건

- 공통 전제 조건 충족
- EEPROM 하드웨어(`eeprom` HAL 컴포넌트) 정상 연결

### 절차

1. `get_eeprom_info` 요청 → 응답에서 `production_date` 원본값(`BEFORE`) 기록
2. `set_eeprom_info` 요청으로 `production_date`만 임시값(예: 현재값과 다른 날짜)으로 변경
3. 재조회(`get_eeprom_info`) → `production_date`가 변경값과 일치하는지 확인
4. cleanup: `set_eeprom_info` 로 `production_date`를 `BEFORE` 값으로 복원 후 재조회로 복원 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| get_eeprom_info 응답 | `data.major_revision`/`product_name`/`product_option1`/`product_option2`/`production_date`/`serial_number` 모두 존재 |
| set_eeprom_info 응답 | `error_code: NONE`, `payload.status: success` |
| 변경 반영 확인 | 재조회 시 `production_date`가 새 값과 일치 |
| 복원 확인 | cleanup 후 재조회 시 `production_date`가 `BEFORE`와 일치 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC05-1 | get_eeprom_info 응답에 6개 필드 모두 존재 | boolean | true | `echo "$resp" \| jq -e '.payload.data \| has("major_revision") and has("production_date") and has("serial_number") and has("product_name") and has("product_option1") and has("product_option2")'` |
| TC05-2 | set_eeprom_info 성공 응답 | boolean | true | `echo "$resp" \| grep -q '"error_code":"NONE"'` |
| TC05-3 | 변경값이 재조회에 반영됨 | boolean | true | `[ "$after_date" = "$new_date" ]` |
| TC05-4 | cleanup 후 원복 확인 | boolean | true | `[ "$restored_date" = "$before_date" ]` |

---

## TC06 — Internet 연결 관리 (get_internet_status)

### 목적

`get_internet_status` IPC 응답이 인터넷 연결 상태(`is_internet_connected`),
응답 시간, 성공/실패 카운트를 정상적으로 반환하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- DUT가 인터넷에 연결된 상태 (내부 모니터링 스레드가 최근 판정 완료)

### 절차

1. `get_internet_status` 요청/응답 수신
2. 응답 payload에서 `data.is_internet_connected`, `data.response_time_ms`,
   `data.success_count`, `data.failure_count`, `data.is_valid` 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| get_internet_status 응답 | `error_code: NONE`, `data.is_valid == true` |
| 연결 상태 | DUT가 실제 인터넷 연결 중이면 `is_internet_connected == true` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC06-1 | get_internet_status 응답 수신 | boolean | true | `[ -n "$resp" ]` |
| TC06-2 | is_valid=true | boolean | true | `echo "$resp" \| grep -q '"is_valid":true'` |
| TC06-3 | is_internet_connected 필드 존재 | boolean | true | `echo "$resp" \| jq -e '.payload.data \| has("is_internet_connected")'` |

---

## TC07 — Host Network Interface 관리 (조회 + DHCP 설정 + 서비스 재시작)

### 목적

`get_network_info`가 인터페이스 목록(IP/MAC/up상태)을 정상 반환하고,
`set_ethernet_config`로 DHCP 설정을 적용하면 `/etc/systemd/network/<iface>.network`
파일에 `DHCP=ipv4`가 기록되며, `restart_network_service`가
`systemd-networkd`를 재시작하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- 대상 인터페이스(`eth0`)가 DUT에 존재
- `/etc/systemd/network/` 쓰기 가능 (host_agent 구조화 writer 경유)

### 절차

1. `get_network_info` 요청/응답 수신 → `data[]`에서 `eth0` 항목 확인
2. 직접 `ip -j addr show`, `ip route show` 실행하여 교차 확인
3. `set_ethernet_config` 요청 (`interface: eth0, type: dhcp`) 발행 → 응답 확인
4. 직접 `cat /etc/systemd/network/eth0.network | grep -i dhcp` 로 `DHCP=ipv4` 포함 확인
5. `restart_network_service` 요청 발행 → 응답 확인
6. `systemctl is-active systemd-networkd` 로 재시작 후 서비스가 `active`인지 확인
   (원본 요구사항의 journalctl 로그 예시는 systemd-networkd 버전에 따라 문구가
   달라질 수 있어 `is-active` 상태 기반으로 판정 — 상세 로그는 참고용)

### 기대 결과

| 항목 | 기준 |
|------|------|
| get_network_info 응답 | `data[]`에 `eth0` 포함, `is_up`/`ip_address`/`mac_address` 필드 존재 |
| set_ethernet_config 응답 | `error_code: NONE`, `payload.status: success` |
| 설정 파일 | `/etc/systemd/network/eth0.network`에 `DHCP=ipv4` 포함 |
| restart_network_service 응답 | `error_code: NONE` |
| 서비스 상태 | `systemctl is-active systemd-networkd` == `active` |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC07-1 | get_network_info에 eth0 존재 | boolean | true | `echo "$resp" \| jq -e '.payload.data[] \| select(.interface=="eth0")'` |
| TC07-2 | set_ethernet_config 성공 응답 | boolean | true | `echo "$resp" \| grep -q '"status":"success"'` |
| TC07-3 | eth0.network에 DHCP=ipv4 포함 | boolean | true | `cat /etc/systemd/network/eth0.network \| grep -q "DHCP=ipv4"` |
| TC07-4 | restart_network_service 성공 응답 | boolean | true | `echo "$resp" \| grep -q '"error_code":"NONE"'` |
| TC07-5 | systemd-networkd 재시작 후 active | boolean | true | `systemctl is-active systemd-networkd \| grep -q "^active$"` |

---

## TC08 — Host Agent와의 연동 (UDS 재연결 + LED 상태 조회)

### 목적

`host-agent` 프로세스를 재시작해도 sys_manager가 UDS 연결을 자동 복구
(`ensure_connected()`)하여 `get_system_info` 응답을 계속 정상 제공하는지,
그리고 `get_led_status` 응답이 `/sys/class/leds/*/brightness` 직접 조회
값과 일치하는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- `systemctl restart host-agent` 실행 권한
- LED 하드웨어(`led` HAL 컴포넌트) 2개 인스턴스(led1/led2) 구성됨

### 절차

1. `get_system_info` 요청 → 정상 응답 확인 (host-agent 재시작 전 baseline)
2. `systemctl restart host-agent` 실행 후 15초 대기
3. `get_system_info` 재요청 → 여전히 정상 응답 수신되는지 확인 (UDS 자동 재연결)
4. `get_led_status` 요청 → 응답의 `leds[].brightness`/`color` 확인
5. 직접 `cat /sys/class/leds/led1/brightness /sys/class/leds/led2/brightness` 실행
   → `get_led_status` 응답의 `brightness` 값과 일치하는지 비교

### 기대 결과

| 항목 | 기준 |
|------|------|
| host-agent 재시작 전 get_system_info | `error_code: NONE` |
| host-agent 재시작 후 get_system_info | `error_code: NONE` (재연결 성공) |
| get_led_status 응답 | `leds[]` 배열에 최소 1개 이상 항목, `is_available: true` |
| sysfs 직접 조회와 일치 | `brightness` 값 동일 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC08-1 | host-agent 재시작 전 응답 성공 | boolean | true | `echo "$resp_before" \| grep -q '"error_code":"NONE"'` |
| TC08-2 | host-agent 재시작 후 응답 성공(재연결) | boolean | true | `echo "$resp_after" \| grep -q '"error_code":"NONE"'` |
| TC08-3 | get_led_status 응답에 leds 배열 존재 | boolean | true | `echo "$resp" \| jq -e '.payload.leds \| length > 0'` |
| TC08-4 | led1 brightness가 sysfs 값과 일치 | boolean | true | `[ "$(echo "$resp" \| jq '.payload.leds[0].brightness')" = "$(cat /sys/class/leds/led1/brightness)" ]` |

---

## TC09 — Host Agent Event Logging (whitelist 차단 로그)

### 목적

`cmd_host`로 whitelist에 없는 명령을 전송하면 host_agent가 이를 차단하고
`journalctl -u host-agent`에 `WARNING` 레벨 차단 로그(`Shell command blocked
by whitelist: <cmd>`)를 남기는지 확인한다.

> 원본 요구사항의 "화이트리스트 명령(`hwclock --show`) 실행 시 `[I][HA]
> COMPONENT_REPORT requested` 로그가 남는다"는 기대는 코드 근거가 없다 —
> `COMPONENT_REPORT`는 별도 이벤트(LED 컴포넌트 검색 등)에서만 발생하고,
> 성공한 whitelist 명령의 감사 로그(`CMD_EXEC: ...`)는 `DEBUG` 레벨이라
> host_agent 기본 설정(`logging.level: info`)에서는 journalctl에 나타나지
> 않는다. 이 TC는 **차단 경로**(WARNING 레벨, 기본 설정에서도 확인 가능)만
> 확정 근거로 작성했다.

### 사전 조건

- 공통 전제 조건 충족
- host_agent `logging.level`이 기본값(`info`)인 상태 (변경하지 않았다면 자동 충족)

### 절차

1. `journalctl -u host-agent --no-pager | tail -0 -f &` 로 실시간 tail 시작 (또는 시작 시각 기록)
2. `cmd_host` 요청으로 whitelist에 있는 명령(`hwclock --show`) 전송 → 응답
   `status: success` 확인 (whitelist 통과 자체는 응답으로 검증, 감사 로그는 DEBUG라 미검증)
3. `cmd_host` 요청으로 whitelist에 없는 명령(`rm -rf /tmp/x`) 전송 → 응답
   `status: error`, `message`에 `"whitelist"` 포함 확인
4. `journalctl -u host-agent --since "<시작 시각>" | grep "Shell command blocked by whitelist: rm -rf /tmp/x"` 로 WARNING 로그 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| whitelist 명령 응답 | `status: success` |
| 비whitelist 명령 응답 | `status: error`, `message`에 whitelist 관련 문구 포함 |
| journalctl 차단 로그 | `[W][HA] Shell command blocked by whitelist: rm -rf /tmp/x` 출현 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC09-1 | whitelist 명령(hwclock --show) 성공 응답 | boolean | true | `echo "$resp1" \| grep -q '"status":"success"'` |
| TC09-2 | 비whitelist 명령 차단 응답 | boolean | true | `echo "$resp2" \| grep -qi "whitelist"` |
| TC09-3 | journalctl WARNING 차단 로그 출현 | boolean | true | `journalctl -u host-agent --since "$START" \| grep -q "Shell command blocked by whitelist: rm -rf /tmp/x"` |

---

## TC10 — Host Command 지원 (cmd_host 화이트리스트 명령군)

### 목적

`cmd_host`로 whitelist에 등록된 대표 명령(`timedatectl`, `cat /etc/os-release`,
`hwclock --show`)이 정상 실행/응답되고, `get_system_info`(HAL 경유 시스템
정보)가 직접 조회한 온도/디스크 사용량과 일치하는 범위에 있는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- `/sys/class/thermal/thermal_zone0/temp` 및 `/edge/log` 마운트 존재

### 절차

1. `cmd_host` 요청 (`cmd: "timedatectl"`) → 응답 `stdout`/`message`에 타임존/NTP 정보 포함 확인
2. `cmd_host` 요청 (`cmd: "cat /etc/os-release"`) → 응답에 `BUILD_MODEL=`, `VERSION_ID=` 포함 확인
3. `cmd_host` 요청 (`cmd: "hwclock --show"`) → 응답에 날짜/시간 형식 문자열 포함 확인
4. `get_system_info` 요청 → `data.temperature[0].value`(밀리도 단위) 확인
5. 직접 `cat /sys/class/thermal/thermal_zone0/temp` 실행 → 값이 `get_system_info` 온도와 근접한지 비교(±5000 milli-degree 이내)
6. 직접 `df -h /edge/log` 실행 → 정상 출력 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| timedatectl 응답 | `status: success`, 출력에 `Time zone` 포함 |
| os-release 응답 | `status: success`, 출력에 `BUILD_MODEL=` 포함 |
| hwclock 응답 | `status: success`, 출력이 날짜 형식(`YYYY-MM-DD`) 포함 |
| get_system_info 온도 | thermal_zone0 직접 조회값과 ±5°C(5000 milli) 이내 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC10-1 | timedatectl 명령 성공 | boolean | true | `echo "$resp1" \| grep -q '"status":"success"'` |
| TC10-2 | os-release 명령 성공 및 BUILD_MODEL 포함 | boolean | true | `echo "$resp2" \| grep -q "BUILD_MODEL="` |
| TC10-3 | hwclock 명령 성공 | boolean | true | `echo "$resp3" \| grep -q '"status":"success"'` |
| TC10-4 | 온도 값이 thermal_zone0과 근접 | boolean | true | `diff=$(( $(cat /sys/class/thermal/thermal_zone0/temp) - temp_reported )); [ ${diff#-} -lt 5000 ]` |
| TC10-5 | df -h /edge/log 정상 출력 | boolean | true | `df -h /edge/log \| grep -q "/edge/log"` |

---

## TC11 — HW별 Configuration 지원 (get_platform_info)

### 목적

`get_platform_info` 응답이 `/etc/os-release` 내용을 정상적으로 파싱해
반환하는지 확인한다.

> **주의 — 응답 키 대소문자 불일치:** 원본 요구사항의 예시 응답은 키를
> 대문자(`ID`, `NAME`, `VERSION`, `BUILD_MODEL`, `BUILD_TYPE`, `BUILD_DATE`,
> `BUILD_VERSION`)로 표기하지만, 실제 `PlatformInfo`(`sys_info_parse.hpp`)의
> `NLOHMANN_DEFINE_TYPE_INTRUSIVE` 필드명은 소문자(`id`, `name`, `version`,
> `build_type`, `build_version`, `build_host_model`, `build_host_date`,
> `is_valid` 등)다. 이 TC는 실제 소문자 키 기준으로 판정 기준을 작성했다 —
> 원본 문서의 대문자 키 기대와 다르므로 QA 검토 시 문서 수정 필요.

### 사전 조건

- 공통 전제 조건 충족

### 절차

1. 직접 `cat /etc/os-release` 실행 → `BUILD_MODEL`, `VERSION_ID`, `BUILD_VERSION` 등 원본 값 기록
2. `get_platform_info` 요청/응답 수신
3. 응답의 `data.build_host_model`이 `/etc/os-release`의 `BUILD_MODEL`과 일치하는지 확인
4. 응답의 `data.version_id`가 `/etc/os-release`의 `VERSION_ID`와 일치하는지 확인
5. 응답의 `data.is_valid`가 `true`인지 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| get_platform_info 응답 | `error_code: NONE`, `data.is_valid == true` |
| build_host_model 일치 | `/etc/os-release`의 `BUILD_MODEL`과 동일 |
| version_id 일치 | `/etc/os-release`의 `VERSION_ID`와 동일 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC11-1 | get_platform_info 응답 is_valid=true | boolean | true | `echo "$resp" \| jq -e '.payload.data.is_valid == true'` |
| TC11-2 | build_host_model이 os-release와 일치 | boolean | true | `[ "$(echo "$resp" \| jq -r '.payload.data.build_host_model')" = "$(grep '^BUILD_MODEL=' /etc/os-release \| cut -d= -f2 \| tr -d '\"')" ]` |
| TC11-3 | version_id가 os-release와 일치 | boolean | true | `[ "$(echo "$resp" \| jq -r '.payload.data.version_id')" = "$(grep '^VERSION_ID=' /etc/os-release \| cut -d= -f2 \| tr -d '\"')" ]` |

---

## TC12 — Safe Reboot (request_system_reboot → sys_manager → host_agent)

### 목적

`request_system_reboot`(edge_runtime 대상) 요청이 전체 앱 종료 후
`SERVICE_REBOOT_HOST`를 통해 sys_manager로 전달되고, sys_manager가
`SysControl::execute_safe_reboot()`로 host_agent에 `safe_reboot` HAL 커맨드를
실행시켜 실제 안전 재부팅(파일시스템 remount-ro 포함)이 수행되는지 확인한다.

### 사전 조건

- 공통 전제 조건 충족
- 시리얼(COM7) 또는 지속적인 ping 모니터링으로 재부팅 전/후 상태 확인 가능
- **권장**: 시리얼 helper(`serial_helper.ps1`) 사용 — SSH 폴링은 재부팅 중
  네트워크 재기동 타이밍에 false-negative 가능성 있음(project memory 참고)

### 절차

1. `uptime; date` 로 재부팅 전 baseline 기록
2. `mosquitto_pub -t "emsp/edge_runtime/tc_runner/req/request_system_reboot" -m '{"tid":1,"source":"tc_runner"}'` 발행
3. DUT가 오프라인(ping 실패)이 되었다가 다시 온라인(ping 성공)이 될 때까지 대기
4. 온라인 복귀 후 `uptime; date` 재확인 → uptime이 reboot 전보다 작아졌는지 확인
5. `dmesg | grep -iE "error|corrupt|fsck"` 로 파일시스템 오류 로그가 없는지 확인
6. `journalctl -u host-agent -b | grep -iE "safe reboot|Executing reboot syscall|remount"` 로 safe_reboot 실행 경로 로그 확인

### 기대 결과

| 항목 | 기준 |
|------|------|
| 재부팅 발생 | uptime이 리셋됨 (재부팅 전보다 작은 값) |
| 파일시스템 오류 | `dmesg`에 error/corrupt/fsck 관련 라인 없음 |
| safe_reboot 실행 로그 | 최신 boot의 host-agent 로그에 remount/reboot 관련 로그 존재 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC12-1 | DUT 재부팅 후 온라인 복귀 | boolean | true | `ping -c 1 192.168.10.25` 성공 |
| TC12-2 | uptime 리셋 확인 | boolean | true | `[ "$uptime_after_sec" -lt "$uptime_before_sec" ]` |
| TC12-3 | 파일시스템 오류 로그 없음 | boolean | true | `dmesg \| grep -iE "error\|corrupt\|fsck" \| wc -l` == 0 (또는 화이트리스트 예외 확인 후 수동 판정) |
| TC12-4 | safe_reboot 실행 경로 로그 존재 | boolean | true | `journalctl -u host-agent -b \| grep -qiE "remount|reboot syscall"` |

---

## TC13 — LED 밝기 경계값 제어 (sysfs 직접)

### 목적

`/sys/class/leds/led1(led2)/brightness`에 음수를 쓰면 커널이 `EINVAL`로
거부하고, 255를 초과하는 값을 쓰면 `max_brightness`(255)로 클램프되는지
확인한다. (표준 Linux LED class sysfs 동작 — sys_manager 코드가 아닌 커널
동작이지만, sys_manager의 `set_led_control`이 동일 경로를 거치므로 실제
동작 확인 목적으로 포함)

### 사전 조건

- 공통 전제 조건 충족
- `/sys/class/leds/led1/brightness`, `/sys/class/leds/led1/max_brightness` 접근 가능

### 절차

1. `cat /sys/class/leds/led1/max_brightness` 로 최대값(예상 255) 확인
2. `echo -1 > /sys/class/leds/led1/brightness` 시도 → 셸 에러 메시지 캡처(`2>&1`)
3. `echo 300 > /sys/class/leds/led1/brightness` 시도 → 이후 `cat /sys/class/leds/led1/brightness` 로 실제 적용값 확인
4. cleanup: `echo 128 > /sys/class/leds/led1/brightness` 로 기본값 복원

### 기대 결과

| 항목 | 기준 |
|------|------|
| 음수 입력 | 쓰기 실패 (`write error: Invalid argument`) |
| 255 초과 입력 | `max_brightness`(255)로 클램프되어 저장됨 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC13-1 | 음수 입력 시 쓰기 오류 | boolean | true | `echo -1 > /sys/class/leds/led1/brightness 2>&1 \| grep -qi "invalid argument"` |
| TC13-2 | 255 초과 입력 시 255로 클램프 | boolean | true | `echo 300 > /sys/class/leds/led1/brightness; [ "$(cat /sys/class/leds/led1/brightness)" = "255" ]` |

---

## TC14 — LED 상태 시나리오 (부팅/업데이트/네트워크/클라우드/운영 모드) — (검토 필요 — 소스 내 일부만 확인)

> `edge_runtime.cpp`에서 확정 근거를 찾은 것은 "부팅 성공"(`send_ready_led_control()`:
> LED1(instance 0) `color="0 255 0"`(Green), `brightness=128`, `trigger="none"` 고정)과
> "부팅 실패"(`send_failed_led_control()`: LED1 `color="255 0 0"`(Red),
> `trigger="timer"`, `delay_on_ms=100`, `delay_off_ms=100` 빠른 점멸)
> 뿐이다. 두 경우 모두 `APPID_SYS_MANAGER`로 `SERVICE_SET_LED_CONTROL`을
> 발행하는 것이 최종 경로이므로, 이 두 시나리오만 sys_manager 관점에서
> "그 payload를 받으면 실제로 그 색상/패턴이 적용되는가"로 재구성해 자동
> 검증할 수 있다(TC15에서 함께 커버). "부팅 중"(White 고정), "업데이트
> 중/성공/실패", "네트워크 연결 성공/실패/안함", "클라우드 연결 성공",
> "개발/디버그 모드", "리커버리/테스트 모드"에 대해 이를 자동으로 트리거하는
> 상태 머신(예: update_monitor나 네트워크 상태 변화 시 LED를 자동으로 바꾸는
> 코드)은 `sys_manager`/`edge_runtime`/`update_monitor` 어디에서도 발견하지
> 못했다 — 개발자 확인 필요(문서상 계획된 기능이나 미구현이거나, 이 저장소
> 밖의 다른 컴포넌트가 담당할 가능성).

### 목적
<TODO — 개발자 확인 후 작성: LED1/LED2가 부팅중/업데이트/네트워크/클라우드/운영
모드에 따라 자동으로 색상·점멸 패턴을 바꾸는 상태 머신이 실제로 존재하는지,
있다면 어느 컴포넌트(app)가 소유하는지 확인 필요>

### 사전 조건
<TODO>

### 절차
<TODO>

### 기대 결과
<TODO>

### PASS/FAIL Criteria
<TODO>

---

## TC15 — LED 제어 (밝기 0~255 + RGB 색상, IPC 경유)

### 목적

`set_led_control` IPC로 지정한 밝기(0~255)와 RGB 색상(`multi_intensity`)이
`/sys/class/leds/led1(led2)/brightness`, `.../multi_intensity` sysfs에
정확히 반영되는지 확인한다. (원본 TC-15는 sysfs 직접 echo 기준이지만, 여기서는
sys_manager의 `set_led_control`/`get_led_status` IPC 경로로 동일 효과를
검증한다 — 실제 LED 색상의 육안 확인은 범위 밖, sysfs 값 readback으로 대체)

### 사전 조건

- 공통 전제 조건 충족
- LED 인스턴스 0(led1), 1(led2) 구성됨

### 절차

1. `set_led_control` 요청 (`instance_id: 0, brightness: 0, color: "0 0 0", trigger: "none"`) 발행 → 응답 확인
2. `cat /sys/class/leds/led1/brightness` == `0` 확인
3. `set_led_control` 요청 (`instance_id: 0, brightness: 255, color: "255 0 0", trigger: "none"`) 발행 → Red(오류/치명 상태) 표현
4. `cat /sys/class/leds/led1/brightness /sys/class/leds/led1/multi_intensity` 로 `255`, `255 0 0` 확인
5. 순서대로 Green(`0 255 0`, 정상), Yellow(`255 200 0`, 경고), White(`255 255 255`, 완료/중립), Off(`0 0 0`) 에 대해 동일하게 반복
6. `get_led_status` 요청으로도 동일 값이 조회되는지 교차 확인
7. cleanup: `set_led_control` 요청으로 `brightness: 128, color: "0 255 0", trigger: "none"` (부팅 성공 기본값)로 복원

### 기대 결과

| 항목 | 기준 |
|------|------|
| brightness 0/255 설정 | sysfs `brightness` 값이 요청값과 일치 |
| RGB 색상 설정 (Red/Green/Yellow/White/Off) | sysfs `multi_intensity` 값이 요청값과 일치 |
| get_led_status 조회 | IPC 응답 값이 sysfs 값과 일치 |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC15-1 | brightness=0 설정 후 sysfs 반영 | boolean | true | `[ "$(cat /sys/class/leds/led1/brightness)" = "0" ]` |
| TC15-2 | brightness=255 설정 후 sysfs 반영 | boolean | true | `[ "$(cat /sys/class/leds/led1/brightness)" = "255" ]` |
| TC15-3 | Red(255 0 0) 색상 sysfs 반영 | boolean | true | `cat /sys/class/leds/led1/multi_intensity \| grep -q "255 0 0"` |
| TC15-4 | Green(0 255 0) 색상 sysfs 반영 | boolean | true | `cat /sys/class/leds/led1/multi_intensity \| grep -q "0 255 0"` |
| TC15-5 | get_led_status 응답이 sysfs와 일치 | boolean | true | `[ "$(echo "$resp" \| jq '.payload.leds[0].brightness')" = "$(cat /sys/class/leds/led1/brightness)" ]` |

---

## TC16 — 자동화 불가 항목 목록 (사내 위키 대조 / 육안 LED 확인)

이 항목들은 사내 Confluence 문서 열람, 실제 LED 육안 색상 확인처럼 단일 DUT
셸 스크립트로는 검증 불가능한 원본 요구사항이다. TC로 변환하지 않고 목록으로만
남긴다 — 실행이 필요하면 QA가 수동으로 확인한다.

| 원본 Key | 항목 | 자동화 불가 사유 |
|----------|------|-------------------|
| Key110 (TC-2 2단계) | iptables 규칙과 Confluence "Edge Open Ports List" 문서 대조 | 사내 Confluence 페이지 열람 및 사람의 판단 비교 필요 (규칙 덤프 자체는 TC02로 자동화됨) |
| Key188 (TC-14, 대부분) | LED1/LED2 실제 색상·점멸 패턴 육안 확인 (업데이트/네트워크/클라우드/개발모드 시나리오) | 물리 LED 육안 확인 필요, 자동 트리거 상태 머신 코드도 미확인 (TC14 참고) |
| Key190 (TC-15, 육안 확인 서브스텝) | RGB 값 설정 후 실제 LED 색상이 육안으로 올바르게 보이는지 확인 | 카메라/육안 확인 필요 — sysfs readback(TC15)으로 대체했으나 실제 발광 색상 자체는 미검증 |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `sys_manager` | MQTT 수신 대상 앱 ID (TC12만 `edge_runtime`) |

---

## 자동화 등급 (Automation Grade)

🟡 **B (일부 확인 필요)**

| TC | 등급 | 비고 |
|----|------|------|
| TC01 | A (자동) | 시스템 시간 조작 + 스케줄 로그 확인, 무인 실행 가능 |
| TC02 | B (반자동) | iptables 덤프는 자동, Open Ports 문서 대조는 TC16 |
| TC03 | A (자동) | set_ntp/get_ntp_status IPC 왕복 |
| TC04 | A (자동) | get_system_info + top 비교 |
| TC05 | A (자동) | get/set_eeprom_info IPC로 원본 스크립트 대체 |
| TC06 | A (자동) | get_internet_status 단순 조회 |
| TC07 | A (자동) | get/set_network_info + DHCP 파일 확인 + 서비스 재시작 |
| TC08 | A (자동) | host-agent 재시작 + 재연결 확인, LED sysfs 교차 확인 |
| TC09 | B (반자동) | 차단 경로만 확정 근거, 성공 경로 감사 로그는 DEBUG라 기본 설정에서 미검증 |
| TC10 | A (자동) | cmd_host 화이트리스트 명령 3종 + 온도값 교차 확인 |
| TC11 | A (자동, 문서 수정 필요) | 응답 키 대소문자가 원본 문서와 다름 — 코드 기준으로 재작성됨 |
| TC12 | C (파괴적) | 실제 DUT 재부팅 유발, 시리얼 helper 권장 |
| TC13 | A (자동) | 커널 LED class sysfs 표준 동작 확인 |
| TC14 | Flag | 부팅 성공/실패 외 나머지 시나리오는 소스 내 자동 트리거 로직 미발견 — 개발자 확인 대기 |
| TC15 | B (반자동) | sysfs readback으로 대체, 실제 육안 색상 확인은 범위 밖 |
| TC16 | 자동화 불가 | 목록만 제공, 실행은 QA 수동 |

---

## 관련 문서

- `tc_sys_manager_result.md` — 본 TC 실행 결과 보고서
- `tc_sys_manager_evidence_full.log` — 결과의 근거가 되는 통합 로그
- `docs/tc_requirements/sys_manager.md` — 요구사항 원본 (AC Gen2 TestCase.xlsx "Host Service" 카테고리, 원본 Key 109-120/187/188/190, 15개 TC)
