# Host Service — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/uniep/core/application/sys_manager`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][Host Service]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 109)

[AC GEN2][Unified Edge Platform][Host Service] 악성 코드 관리 

**Action:**

현재 시간 기록 및 NTP 비활성화

{code:bash}# 현재 시간 기록
date
timedatectl

# NTP 비활성화 (시간 수동 설정을 위해)
timedatectl set-ntp false{code}

**Expected Result:**

NTP가 비활성화 된다


### (연속 스텝)

**Action:**

시스템 시간을 01:58로 설정한다

{code:bash}# 시간을 새벽 1시 58분으로 설정 (2시 2분 전)
timedatectl set-time "01:58:00"

# 설정 확인
date{code}

**Expected Result:**

시간이 01:58로 설정된다


### (연속 스텝)

**Action:**

journald 실시간 모니터링 시작

{code:bash}# 터미널 1: sys_manager 로그 실시간 모니터링
journalctl -f -u sys_manager | grep -i chkrootkit &

# 터미널 1 (대안): 전체 시스템 로그에서 chkrootkit 모니터링
journalctl -f | grep -i chkrootkit &{code}

**Expected Result:**

실시간 모니터링이 시작된다


### (연속 스텝)

**Action:**

02:00까지 대기 (약 2~3분)

{code:bash}# 현재 시간 확인하며 대기
watch -n 10 date

# 또는 단순 대기
sleep 180{code}


### (연속 스텝)

**Action:**

*chkrootkit 실행 로그 확인*

{code:bash}# journalctl에서 chkrootkit 실행 로그 확인
journalctl --since "01:55" --until "02:10" | grep -i chkrootkit

# sys_manager 로그에서 확인
journalctl -u sys_manager --since "01:55" --until "02:10" | grep -i chkrootkit

# docker 컨테이너 로그에서 확인
docker logs sys_manager 2>&1 | grep -i chkrootkit | tail -30{code}

**Expected Result:**

악성코드가 감지 / 미감지 된다


## TC-2 (원본 Key 110)

[AC GEN2][Unified Edge Platform][Host Service] 방화벽 관리

**Action:**

iptables 규칙을 관리한다

{code:bash}# 타겟 디바이스에서 직접 실행
iptables -L -n -v{code}


### (연속 스텝)

**Action:**

[https://growingenergylabs.atlassian.net/wiki/spaces/EnergySW/pages/10755506313/Edge+Open+Ports+List+V0.1|https://growingenergylabs.atlassian.net/wiki/spaces/EnergySW/pages/10755506313/Edge+Open+Ports+List+V0.1]
에 나온 목록과 매치하여 일치하는지 확인한다.

**Expected Result:**

OPen Ports List와 일치하여야함


## TC-3 (원본 Key 111)

[AC GEN2][Unified Edge Platform][Host Service] System Time 관리

**Action:**

터미널 > NTP Disable 설정 

{noformat}mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/set_ntp" \
  -m '{"tid":182,"source":"sqe_test","enabled":false}'{noformat}


### (연속 스텝)

**Action:**

터미널 > Get Status 실행 

{noformat}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_ntp_status" \
  -m '{"tid":180,"source":"sqe_test"}'{noformat}

**Expected Result:**

NTP Service가 False로 표시 되어야 함

* # {"error_code":"NONE","payload":{"data":{"*ntp_service":false*,"ntp_synchronized":true},"status":"success"}}


### (연속 스텝)

**Action:**

터미널 > NTP Enable 설정 

{noformat}mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/set_ntp" \
  -m '{"tid":181,"source":"sqe_test","enabled":true}'{noformat}


### (연속 스텝)

**Action:**

터미널 > Get Status 실행 

{noformat}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_ntp_status" \
  -m '{"tid":180,"source":"sqe_test"}'{noformat}

**Expected Result:**

NTP Service가 True로 표시 되어야 함

* # {"error_code":"NONE","payload":{"data":{"*ntp_service":true*,"ntp_synchronized":true},"status":"success"}}


## TC-4 (원본 Key 112)

[AC GEN2][Unified Edge Platform][Host Service] System Info 모니터링

**Action:**

SSH > 아래 Command 입력

{noformat}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_system_info" \
  -m '{"tid":150,"source":"sqe_test"}'{noformat}

**Expected Result:**

온도 및 Memory Usage 정보가 출력 되어야 함

* # root@qcells-emsplus:~# {"data":{"cpu_usage_1min":0.25,"has_storage":true,"has_temperature":true,"is_valid":true,"memory_usage":34.58,"storage_usage":[{"instance_id":0,"usage":1.0},{"instance_id":1,"usage":1.0}],"temperature":[{"instance_id":0,"value":45000.0}],"timestamp":1766550030},"status":"success"}


### (연속 스텝)

**Action:**

SSH > 아래 Command 입력 

* # top -bn1 | head -5

**Expected Result:**

Memory  및 CPU Usage 정보가 출력 되어야 함 

{noformat}top - 04:20:43 up  2:23,  3 users,  load average: 0.26, 0.24, 0.36
Tasks: 178 total,   1 running, 177 sleeping,   0 stopped,   0 zombie
%Cpu(s):  2.6 us,  5.2 sy,  0.0 ni, 92.2 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
MiB Mem :   1955.9 total,    297.4 free,    676.4 used,    982.1 buff/cache
MiB Swap:      0.0 total,      0.0 free,      0.0 used.    891.7 avail Mem{noformat}


## TC-5 (원본 Key 113)

[AC GEN2][Unified Edge Platform][Host Service] EEPROM Nameplate 관리


### (연속 스텝)

**Action:**

SSH > 첨부 스크립트 실행 > EEPROM Nameplate 값 확인 

{noformat}sh eeprom_test.sh dump{noformat}

**Expected Result:**

EEPROM 저장된 장치 Nameplate 정보가 정상적으로 출력 되어야 함 

{noformat}{"major_revision":"1.30","product_name":"EMS_Plus","product_option1":"FA-Linux","product_option2":"KR","production_date":"27/Jul/2026","serial_number":"E13123BU0051"}{noformat}


### (연속 스텝)

**Action:**

SSH > 첨부 스크립트 실행 > EEPROM Nameplate 값 변경

{noformat}sh eeprom_test.sh write-json '"production_date":"31/Jul/2026","product_name":"EMS_Plus"'{noformat}

**Expected Result:**

EEPROM Nameplate 값이 정상적으로 변경 되어야 함 

{noformat}--------------------------------------------------
REQ  : {"tid":1,"source":"sqe_test","production_date":"31/Jul/2026","product_name":"EMS_Plus"}
RES  : {"error_code":"NONE","payload":{"exit_code":0,"message":"","status":"success"}}
TIME : 2940 ms
error_code = NONE / payload.status = success
판정 : 응답 OK{noformat}


### (연속 스텝)

**Action:**

SSH > 첨부 스크립트 실행 > EEPROM Nameplate 값 확인 

{noformat}sh eeprom_test.sh dump{noformat}

**Expected Result:**

변경한 EEPROM Nameplate 값이 정상적으로 출력 되어야 함

{noformat}{"major_revision":"1.30","product_name":"EMS_Plus","product_option1":"FA-Linux","product_option2":"KR","production_date":"31/Jul/2026","serial_number":"E13123BU0051"}{noformat}


## TC-6 (원본 Key 114)

[AC GEN2][Unified Edge Platform][Host Service] Internet 연결 관리

**Action:**

SSH > 아래 Command 입력 

{noformat}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_internet_status" \
  -m '{"tid":95,"source":"sqe_test"}'{noformat}

**Expected Result:**

인터넷 연결 상태가 출력 되어야 함 

* # root@qcells-emsplus:~# {"error_code":"NONE","payload":{"data":{"failure_count":0,*"is_internet_connected":true,*"is_valid":true,"last_check_time":1766550467,"response_time_ms":55.0,"success_count":3,"timestamp":1766550467},"status":"success"}}


## TC-7 (원본 Key 115)

[AC GEN2][Unified Edge Platform][Host Service] Host Network Interface 관리

**Action:**

터미널 > 아래 Command 입력 

{code:java}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_network_info" \
  -m '{"tid":90,"source":"sqe_test"}'{code}

**Expected Result:**

Get network info 정보가 정상적으로 출력 되어야 함 

{noformat}{"error_code":"NONE","payload":{"data":[{"interface":"lo","ip_address":"127.0.0.1","is_up":false,"mac_address":"00:00:00:00:00:00","netmask":"8"},{"interface":"eth0","ip_address":"192.168.20.3","is_up":true,"mac_address":"44:b7:d0:c9:65:fe","netmask":"24"},{"interface":"can0","ip_address":"","is_up":true,"mac_address":"","netmask":""},{"interface":"mlan0","ip_address":"","is_up":false,"mac_address":"b8:f4:4f:e0:77:01","netmask":""},{"interface":"uap0","ip_address":"192.168.100.1","is_up":true,"mac_address":"ba:f4:4f:e0:78:01","netmask":"24"},{"interface":"wfd0","ip_address":"","is_up":false,"mac_address":"ba:f4:4f:e0:77:01","netmask":""},{"interface":"docker0","ip_address":"172.17.0.1","is_up":false,"mac_address":"02:42:9e:ed:89:8a","netmask":"16"}],"status":"success"}}
{noformat}


### (연속 스텝)

**Action:**

*2단계: 직접 확인*

{code:bash}# 타겟 디바이스에서 직접 실행
ip -j addr show
# 타겟 디바이스에서 직접 실행
ip route show{code}

**Expected Result:**

네트워크가 바로 확인 된다.


### (연속 스텝)

**Action:**

*네트워크 설정 테스트 절차:*

{code:bash}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/set_ethernet_config" \
  -m '{"tid":91,"source":"sqe_test","interface":"eth0","type":"dhcp"}'{code}

**Expected Result:**

DHCP 설정이 정상적으로 완료 되어야 함 

{noformat}{"error_code":"NONE","payload":{"message":"Ethernet configuration applied successfully","status":"success"}}{noformat}


### (연속 스텝)

**Action:**

*확인 -:*

{code:bash}# 타겟 디바이스에서 직접 실행
cat /etc/systemd/network/*.network | grep -i dhcp{code}

**Expected Result:**

DHCP 정보가 정상적으로 표시 되어야 함 

{noformat}DHCP=ipv4
[DHCP]
DHCP=no
DHCP=ipv4
[DHCP]
DHCP=ipv4
[DHCP]
DHCPServer=yes
[DHCPServer]
DHCP=ipv4
[DHCP]{noformat}


### (연속 스텝)

**Action:**

SSH > 아래와 같이 입력 

세션 1 : 아래  Command 입력 

{code:java}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/restart_network_service" \
  -m '{"tid":94,"source":"sqe_test"}'{code}



세션 2 :  # journalctl -f

**Expected Result:**

네트워크 서비스가 재시작 되어야 함 

{noformat}May 11 14:02:25 qcells-emsplus systemd[1]: Stopped Wait for Network to be Configured.
May 11 14:02:25 qcells-emsplus systemd[1]: Stopping Wait for Network to be Configured...
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: Restart operation initiated.
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: Bus bus-api-network: changing state RUNNING → CLOSED
May 11 14:02:25 qcells-emsplus systemd[1]: Stopping Network Configuration...
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: uap0: DHCPv4 server: STOPPED
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: uap0: LLDP Rx: Stopping LLDP client
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: eth0: LLDP Rx: Stopping LLDP client
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: uap0: DHCPv4 server: UNREF
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: uap0: DHCPv4 server: STOPPED
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: mlan0: DHCPv4 client: FREE
May 11 14:02:25 qcells-emsplus systemd-networkd[19675]: eth0: DHCPv4 client: FREE
May 11 14:02:25 qcells-emsplus systemd[1]: systemd-networkd.service: Deactivated successfully.
May 11 14:02:25 qcells-emsplus systemd[1]: Stopped Network Configuration.
May 11 14:02:25 qcells-emsplus systemd[1]: Starting Network Configuration...{noformat}


## TC-8 (원본 Key 116)

[AC GEN2][Unified Edge Platform][Host Service] Host Agent와의 연동


### (연속 스텝)

**Action:**

SSH >  아래 Command 입력 

{noformat}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 & 
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_system_info" \
  -m '{"tid":80,"source":"sqe_test"}'{noformat}

**Expected Result:**

Host Agent 와 정상적으로 통신이 가능 해야 함 

{noformat}{"error_code":"NONE","payload":{"data":{"cpu_usage_1min":0.72,"has_storage":true,"has_temperature":true,"is_valid":true,"memory_usage":55.34,"storage_usage":[{"instance_id":0,"usage":3.0},{"instance_id":1,"usage":1.0}],"temperature":[{"instance_id":0,"value":44000.0}],"timestamp":1775463317},"status":"success"}}{noformat}


### (연속 스텝)

**Action:**

SSH > Host Agent 재시작 > 15초 대기

{noformat}systemctl restart host-agent{noformat}


### (연속 스텝)

**Action:**

SSH >  아래 Command 입력

{code:java}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_system_info" \
  -m '{"tid":81,"source":"sqe_test"}'{code}

**Expected Result:**

Host Agent 와 정상적으로 통신이 가능 해야 함 

{noformat}{"error_code":"NONE","payload":{"data":{"cpu_usage_1min":0.72,"has_storage":true,"has_temperature":true,"is_valid":true,"memory_usage{noformat}


### (연속 스텝)

**Action:**

SSH >  아래 Command 입력

{code:java}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -C 1 &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_led_status" \
  -m '{"tid":83,"source":"sqe_test"}'{code}

**Expected Result:**

LED 정보가 정상적으로 출력 되어야 함 

{noformat}root@qcells-emsplus:~# {"error_code":"NONE","payload":{"leds":[{"brightness":128,"color":"0 255 0\n","delay_off_ms":0,"delay_on_ms":0,"instance_id":0,"is_available":true,"trigger":"none"},{"brightness":0,"color":"0 0 0\n","delay_off_ms":0,"delay_on_ms":0,"instance_id":1,"is_available":true,"trigger":"none"}],"status":"success"}}{noformat}


### (연속 스텝)

**Action:**

SSH >  아래 Command 입력

{code:java}cat /sys/class/leds/*/brightness{code}

**Expected Result:**

LED Brightness 정보가 정상적으로 출력 되어야 함 

{noformat}1
1
128
0
0
0
1
{noformat}


## TC-9 (원본 Key 117)

[AC GEN2][Unified Edge Platform][Host Service]  Host Agent Event Logging

**Action:**

SSH > 화이트 리스트 명령 실행 

{noformat}mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/cmd_host" \
  -m '{"tid":61,"source":"sqe_test","cmd":"hwclock --show","timeout":5}'{noformat}


### (연속 스텝)

**Action:**

SSH > Host-Agnet 로그 확인 

* # journalctl -u host-agent -n 20 --no-pager

**Expected Result:**

Host-Agent Event가 정상적으로 기록 되어야 함

* [I][HA] COMPONENT_REPORT requested


### (연속 스텝)

**Action:**

SSH > 차단된 명령어 입력 

{noformat}mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/cmd_host" \
  -m '{"tid":62,"source":"sqe_test","cmd":"rm -rf /tmp/x","timeout":5}'{noformat}


### (연속 스텝)

**Action:**

SSH > Host-Agnet 로그 확인

* # journalctl -u host-agent -n 20 --no-pager

**Expected Result:**

Host-Agent Event가 정상적으로 기록 되어야 함

* [W][HA] Command NOT in whitelist, blocking: rm -rf /tmp/x
* [E][HA] Shell command blocked by whitelist: rm -rf /tmp/x


## TC-10 (원본 Key 118)

[AC GEN2][Unified Edge Platform][Host Service] Host Command 지원

**Action:**

SSH > 아래 Command 입력 

* CMD 명령어 테스트 : timedatectl

{code:java}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -v &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/cmd_host" \
  -m '{"tid":10,"source":"sqe_test","cmd":"timedatectl","timeout":5}'{code}

**Expected Result:**

timedatectl 정보가 정상적으로 출력 되어야 함


### (연속 스텝)

**Action:**

SSH > 아래 Command 입력

* CMD 명령어 테스트 : cat /etc/os-release

{code:java}mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/cmd_host" \
  -m '{"tid":11,"source":"sqe_test","cmd":"cat /etc/os-release","timeout":5}'{code}

**Expected Result:**

OS-Release 정보가 정상적으로 출력 되어야 함


### (연속 스텝)

**Action:**

SSH > 아래 Command 입력

* CMD 명령어 테스트 : hwclock --show
{code:java}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -v &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/cmd_host" \
  -m '{"tid":12,"source":"sqe_test","cmd":"hwclock --show","timeout":5}'{code}

**Expected Result:**

HW-Clock 정보가 정상적으로 출력 되어야 함


### (연속 스텝)

**Action:**

SSH > 아래 Command 입력

* HAL 명령어 테스트 : 시스템 정보 요청

{code:java}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -v &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_system_info" \
  -m '{"tid":20,"source":"sqe_test"}'{code}

**Expected Result:**

시스템 정보가 정상적으로 출력 되어야 함 (온도, Memory Usage)


### (연속 스텝)

**Action:**

SSH > 아래 커맨드 입력 (시스템 정보 직접 확인)

* cat /sys/class/thermal/thermal_zone0/temp
* df -h /edge/log

**Expected Result:**

온도, Memory Usage 정보가 정상적으로 출력 되어야 함


## TC-11 (원본 Key 119)

[AC GEN2][Unified Edge Platform][Host Service] HW 별 Configuration 지원


### (연속 스텝)

**Action:**

SSH > 아래 Command 입력 

* # cat /etc/os-release

**Expected Result:**

OS-Release 정보가 정상적으로 출력 되어야 함 

{noformat}ID=qcells-edge
NAME="QCells Edge"
VERSION="5.15-kirkstone (kirkstone)"
VERSION_ID=5.15-kirkstone
PRETTY_NAME="QCells Edge 5.15-kirkstone (kirkstone)"
DISTRO_CODENAME="kirkstone"
BUILD_TYPE="DEBUG"
BUILD_MODEL="AC_SYSTEM_GEN2"
BUILD_DATE="2025/12/23 09:51:53"
BUILD_VERSION="X021223"
BUILD_MAIN_TAG="DD2512231"{noformat}


### (연속 스텝)

**Action:**

SSH > 아래 command 입력

{noformat}mosquitto_sub -t "emsp/sqe_test/sys_manager/res/+" -v &
mosquitto_pub \
  -t "emsp/sys_manager/sqe_test/req/get_platform_info" \
  -m '{"tid":1,"source":"sqe_test"}'{noformat}

**Expected Result:**

OS-Release 정보가 정상적으로 출력 되어야 함

{noformat}{
  "tid": 1,
  "status": "success",
  "data": {
    "ID": "qcells-edge",
    "NAME": "QCells Edge",
    "VERSION": "5.15-kirkstone (kirkstone)",
    "BUILD_MODEL": "AC_SYSTEM_GEN2",
    "BUILD_TYPE": "Debug",
    "BUILD_DATE": "2025/11/05 06:51:48",
    "BUILD_VERSION": "X011105",
    "is_valid": true
  }
}{noformat}


## TC-12 (원본 Key 120)

[AC GEN2][Unified Edge Platform][Host Service] Safe Reboot


### (연속 스텝)

**Action:**

현재 uptime을 기록한다

{noformat}# 타겟 디바이스에서 직접 실행
uptime; date{noformat}


### (연속 스텝)

**Action:**

Initiate safe reboot 동작 

{noformat}mosquitto_pub \
  -t "emsp/edge_runtime/sqe_test/req/request_system_reboot" \
  -m '{"tid":70,"source":"sqe_test"}'{noformat}


### (연속 스텝)

**Action:**

*Monitor device*

{noformat}ping 192.168.22.19{noformat}


### (연속 스텝)

**Action:**

*디바이스 복구 대기*

{code:java}while ! ping -c 1 192.168.10.44 &>/dev/null; do sleep 5; echo "Waiting..."; done
echo "Device online at $(date){code}


### (연속 스텝)

**Action:**

*reboot completed를* 확인한다

{noformat}# 타겟 디바이스에서 직접 실행
uptime; date{noformat}


### (연속 스텝)

**Action:**

*Check for filesystem errors*

{noformat}# 타겟 디바이스에서 직접 실행
dmesg | grep -i 'error\|corrupt\|fsck'{noformat}

**Expected Result:**

error 로그가 뜨지 않으면 정상 동작으로 확인한다


## TC-13 (원본 Key 187)

[AC GEN2][Unified Edge Platform][Host Service] LED 밝기 경계값 제어

**Action:**

LED1 / LED2 터미널 접속 후 

{noformat}$ echo [음수, 혹은 255를 넘어가는 숫자] > /sys/class/leds/led1/brightness{noformat}

입력하여

-밝기를 제어한다

**Expected Result:**

* 음수 입력 시 

{noformat}echo: write error: Invalid argument{noformat}

표시 되며, 제어 불가

* 255를 넘어가는 수치 입력시
** 밝기는 255로 고정


## TC-14 (원본 Key 188)

[AC GEN2][Unified Edge Platform][Host Service] LED 상태 시나리오 확인

**Action:**

*순서대로 LED1 (시스템) / LED2 (네트워크/서비스)*

*부팅 중 -* 

* *White*, 고정 / *Off*

*부팅 성공 -*

* {color:#006644}*Green*{color} 고정 / (네트워크 상태에 따름)

*부팅 실패  -* 

* {color:#ff5630}*Red*{color} 빠른 점멸 / (네트워크 상태에 따름)

**Data:**

부팅 중 - 시스템 기동 중 

부팅 성공 -정상 기동 완료

부팅 실패 - 커널 /서비스 치명 오류

**Expected Result:**

LED 시나리오가 정상적으로 작동된다


### (연속 스텝)

**Action:**

*업데이트* 

*순서대로 LED1 (시스템) / LED2 (네트워크/서비스)*

*업데이트 중 -*

* *White*, 보통 점멸 (1Hz, 40%) →빠른 점멸(10Hz, 40%) / Off

*업데이트 성공 -*

* {color:#006644}*Green*{color} LED2 교차 깜빡임 (5Hz, 40%) / {color:#006644}*Green*{color} LED1 교차 깜빡임 (5Hz, 40%)

*업데이트 실패  -*

* {color:#ff5630}*Red*{color} 빠른 점멸 / {color:#ff5630}*Red*{color} 빠른 점멸

*USB* 

기존 > Green에서 *White 점멸*

**Data:**

업데이트 중 - OTA/펌웨어 진행

업데이트 성공 - 업데이트 완료

업데이트 실패 - OTA 실패/롤백 필요

**Expected Result:**

설명


### (연속 스텝)

**Action:**

*네트워크*

*순서대로 LED1 (시스템) / LED2 (네트워크/서비스)*

*네트워크 연결 성공*  

* (시스템 상태에 따름) / {color:#006644}*Green*{color} 느린점멸

*네트워크 연결 실패* 

* (시스템 상태에 따름) / {color:#ff5630}*Red*{color} 고정

*네트워크 연결 안함* 

* (시스템 상태에 따름) / Off

**Data:**

네트워크 연결 성공 - IP 획득/연결 성공

네트워크 연결 실패 - DHCP/인증 실패

네트워크 연결 안함 - 인터페이스 없거나, 설정 없음

**Expected Result:**

LED 시나리오가 정상적으로 작동된다


### (연속 스텝)

**Action:**

*클라우드 서비스*

*순서대로 LED1 (시스템) / LED2 (네트워크/서비스)*

*클라우드 연결 성공*

* (시스템 상태에 따름) / {color:#006644}*Green*{color} 고정

**Data:**

클라우드 연결 성공 - MQTT/IoTHub 세션 활성

**Expected Result:**

LED 시나리오가 정상적으로 작동된다


### (연속 스텝)

**Action:**

*운영/관리*

*순서대로 LED1 (시스템) / LED2 (네트워크/서비스)*

*개발/디버그 모드*

* {color:#ffc400}*Yellow*{color}, 빠른 점멸 / (네트워크 상태에 따름)

*리커버리 모드*

* (필요시 추가 예정) / (필요시 추가 예정)

*테스트/유지보수 모드*

* (필요시 추가 예정) / (필요시 추가 예정)

**Data:**

개발/디버그 모드 - 개발자용 모드

**Expected Result:**

LED 시나리오가 정상적으로 작동된다


## TC-15 (원본 Key 190)

[AC GEN2][Unified Edge Platform][Host Service] LED 제어

**Action:**

LED1 / LED2 터미널 접속 후 

{noformat}$ echo [지정된 범위] > /sys/class/leds/led1/brightness{noformat}

입력하여

-밝기를 제어한다 (기본값 128)

**Data:**

0~255범위 지정 가능

**Expected Result:**

수치별 LED 밝기가 조절 된다


### (연속 스텝)

**Action:**

LED1 / LED2 터미널 접속 후 아래 커맨드 입력 

{noformat}$ echo 255 0 0 > /sys/class/leds/led1/multi_intensity{noformat}

-RGB 색상을 제어한다

**Data:**

순서대로 R, G, B 값 설정 가능


### (연속 스텝)

**Action:**

RGB값 TEST 

Red 255 0 0 (오류, 치명적 상태)

Green 0 255 0 (정상 동작, 성공 상태)

Yellow 255 200 0 (경고, 주의 필요 상태)

White 255 255 255 (완료 또는 중립 상태)

Off 0 0 0 (LED Off 상태)

**Expected Result:**

각 RGB 값 대로 색상이 LED에 표시 되어야 한다


### (연속 스텝)


