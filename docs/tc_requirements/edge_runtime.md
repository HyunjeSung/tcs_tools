# Edge Runtime — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/uniep/core/application/edge_runtime`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][Edge Runtime]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 177)

[AC GEN2][Unified Edge Platform][Edge Runtime] 재부팅 요청 수행

**Action:**

SSH 세션 2개 연결 > 재부팅 요청 > EMS 로그 확인 

* 세션1 : # mosquitto_pub -h localhost -t 'emsp/edge_runtime/udev/req/request_reboot' -m '{"reason":"test_restart"}'
* 세션2 : # journalctl -f

**Expected Result:**

모든 Application이 정상 종료 되어야 함

* 예) EnergyDispatcher cleanup


### (연속 스텝)

**Action:**

SSH > 재부팅 정보 확인

**Expected Result:**

아래 파일에 재부팅 정보가 정상적으로 기록 되어야 함

* /edge/log/reboot_info.txt


## TC-2 (원본 Key 178)

[AC GEN2][Unified Edge Platform][Edge Runtime] 모든 앱 Ready 알림 전송

**Action:**

EMS+ 보드 부팅


### (연속 스텝)

**Action:**

터미널 > All App Ready Message 확인

**Data:**

로그 형식 확인 필요

**Expected Result:**

모든 앱 준비 완료 후 All App Ready 알림을 전송 해야 함


### (연속 스텝)

**Action:**

모든 App이 Ready 상태 > LED 상태 확인

**Expected Result:**

모든 App이 Ready 상태인 경우 LED가 녹색으로 출력 되어야 함


### (연속 스텝)

**Action:**

모든 App Ready가 실패한 상태 > LED 상태 확인

* /edge/devapp/bin 경로에 Application bin 파일명과 동일한 이름의 빈 파일 저장 > 컨테이너 재실행

**Expected Result:**

모든 App Ready에 실패한 경우 LED가 빨간색을 출력 되어야 함


## TC-3 (원본 Key 180)

[AC GEN2][Unified Edge Platform][Edge Runtime] Ready 알림 대기 타임아웃 처리

**Action:**

* Ready 알림 대기 (앱 시작 시 Ready 메시지 수신 테스트)
** 보드 ssh 두 세션 준비 후 
1 session : journalctl -f
2 session : docker stop ac_system_gen2
컨테이너 재실행한다

**Expected Result:**

*  로그에서 각 어플리케이션들이 Ready를 보낸다


### (연속 스텝)

**Action:**

초기 서비스 체크 타이머 (DB Manager Ready 10초 대기 테스트)

* ssh 1 session, 2 session 으로 테스트 한 세션에 journalctl -f 로 로그를 켜두고 다른 세션에서 /edge/devapp/bin 경로에 텅빈 파일을 db_manager bin 파일명과 동일하게 바꿔 위치 시킨뒤 컨테이너 재실행 하여 테스트


### (연속 스텝)

**Action:**

타임아웃 처리

* Ready 타임아웃 시 Core Container 재부팅 테스트 (+*_초기 서비스 체크 타이머 방법과 동일_*+)

**Expected Result:**

Application start시 일정기간 ready가 안 오면 Reboot 되어야 함 

* 앱 총 ready 대기 : 60초
* db mgr ready 대기 : 10초


## TC-4 (원본 Key 182)

[AC GEN2][Unified Edge Platform][Edge Runtime] Heartbeat 메시지 수신


### (연속 스텝)

**Action:**

Web HMI > Service > Log Level > Edge Runtime : Debug로 변경 후 Heartbeat 메시지 수신 확인 

* # handler_noti_watchdog From: app_name 
* 각 앱들이 Heartbeat를 보내는 지 확인


### (연속 스텝)

**Action:**

애플리케이션 별 타임아웃 설정

* 9초 내 Heartbeat 미수신 시 타임아웃 테스트

**Data:**

ps -ef 로 컨테이너 내부에 Edge runtime이 fork한 자식 프로세스 pid 확인 후 kill 명령어로 pid 종료 시킨뒤 로그 확인(와치독에 의한 종료가 발생할 것임)

**Expected Result:**

타임아웃 로그가 확인된다


### (연속 스텝)

**Action:**

주기적 Heartbeat 수신 체크

* 3초마다 Watchdog 체크 동작 테스트

**Expected Result:**

* 3초마다 Watchdog동작이 체크 된다


### (연속 스텝)

**Action:**

Watchdog 타이머 동작

* Watchdog 타이머 시작 및 정지 테스트
** ssh 1 session, 2 session 으로 테스트 한 세션에 journalctl -f 로 로그를 켜두고 
** 다른 세션에서 docker stop ac_system_gen2로 컨테이너를 재실행 시키면서 watchdog이 제대로 켜져서 작동하는지 로그 확인

**Data:**

({{"total_app_size = " << total_app_size <<", uniep_application_size = "<< uniep_application_size <<", other_application_size = "<< other_application_size }}

**Expected Result:**

Data란과 같이 총 watchdog에서 관리하는 어플리케이션 개수가 찍힌다 (DEBUG Log Level)


### (연속 스텝)

**Action:**

타임아웃 시 Core Container 재부팅

* Heartbeat 타임아웃 시 Core Container 재부팅 테스트

ssh 1 session, 2 session 으로 테스트 한 세션에 journalctl -f 로 로그를 켜두고 다른 세션에서 /edge/devapp/bin 경로에 텅빈 파일을 다른 어플리케이션 bin 파일명과 동일하게 바꿔 위치 시킨뒤 컨테이너 재실행 하여 테스트


### (연속 스텝)

**Action:**

크래시 감지 및 처리

* 앱 크래시 시 재부팅 요청 테스트

**Expected Result:**

+*_타임아웃 시 Core Container 재부팅 방법과 동일_*+


## TC-5 (원본 Key 183)

[AC GEN2][Unified Edge Platform][Edge Runtime] 순서별 Application 실행 및 의존성 보장

**Action:**

SSH > 아래 Command 입력 

* # docker exec -it ac_system_gen2 /bin/bash

**Expected Result:**

/edge/app 경로 접근이 가능해야 함


### (연속 스텝)

**Action:**

SSH > uniep_applist.conf 파일 확인 

* # cat /edge/app/files/edge_runtime/uniep_applist.conf

**Expected Result:**

아래와 같은 형식으로 uniep Application 리스트가 표시 되어야 함 

{noformat}{
  "order": 1,
  "name": "edge_runtime",
  "tags": "ER"
}{noformat}


### (연속 스텝)

**Action:**

SSH 세션 2개 연결 > 컨테이너 재 실행 후 EMS 로그 확인

* 세션 1 : # journalctl -f
* 세션 2 : # docker stop ac_system_gen2

**Expected Result:**

uniep_applist.conf 파일의 order 순서대로 uniep Application이 실행 되어야 함 

* 각 앱의 App is ready 로그가 출력되는 순서로 확인


### (연속 스텝)

**Action:**

SSH > /edge/devapp/files/ 경로에 uniep_applist.conf  파일 복사

* # cp /edge/app/files/edge_runtime/uniep_applist.conf /edge/devapp/files/

**Data:**

/edge/app 경로 접근 가능한 상태여야 함 ( # docker exec -it ac_system_gen2 /bin/bash )

**Expected Result:**

/edge/devapp/files/ 경로에 uniep_applist.conf  파일이 정상적으로 복사 되어야 함


### (연속 스텝)

**Action:**

SSH >  uniep_applist.conf 파일 수정 > 컨테이너 재부팅 > EMS 로그 확인 

* Application order 수정 

* docker stop ac_system_gen2  (컨테이너 재부팅)

**Data:**

*[order 수정 규칙]*

order 1 : Edge_Runtime , order 2 : DB_Manager 고정 (1, 2 중복 되지 않게 설정)

order 3부터 변경 가능 (1,2,3,5 등 중간 숫자가 비어있게 설정 불가) 

중복되는 order의 경우 무작위 실행

**Expected Result:**

컨테이너 재부팅 시 변경된 order 순서로 uniep Application이 실행 되어야 함 

* 컨테이너 재부팅 시 /edge/devapp/files/ 경로의  uniep_applist.conf  파일이 /edge/app/files/edge_runtime/ 경로로 복사 됨

{noformat}Jan 09 06:36:20 qcells-emsplus docker-loader[1619]: [06:36:20:476][I][ER] App is ready
Jan 09 06:36:21 qcells-emsplus docker-loader[1619]: [06:36:21:719][I][DB] App is ready
Jan 09 06:36:23 qcells-emsplus docker-loader[1619]: [06:36:23:674][I][SM] App is ready
Jan 09 06:36:24 qcells-emsplus docker-loader[1619]: [06:36:24:763][I][AZ] App is ready
Jan 09 06:36:25 qcells-emsplus docker-loader[1619]: [06:36:25:909][I][EL] App is ready
Jan 09 06:36:28 qcells-emsplus docker-loader[1619]: [06:36:27:548][I][TA] App is ready
Jan 09 06:36:28 qcells-emsplus docker-loader[1619]: [06:36:28:712][I][EM] App is ready
Jan 09 06:36:29 qcells-emsplus docker-loader[1619]: [06:36:29:889][I][UM] App is ready
Jan 09 06:36:31 qcells-emsplus docker-loader[1619]: [06:36:31:051][I][SL] App is ready{noformat}


## TC-6 (원본 Key 185)

[AC GEN2][Unified Edge Platform][Edge Runtime] Configuration 기반 Project Application 실행

**Action:**

SSH 세션 2개 연결 

* 세션 1 : journalctl -f
* 세션 2 : docker stop ac_system_gen2

**Data:**

12/19 Daily 버전부터 테스트 가능

**Expected Result:**

어플리케이션이 정상적으로 fork 되어야 함 

해당 Step은 아래 TC와 중복으로 보임. (검토 필요)

* [https://my.desk.qcells.com/browse/G2T-18|https://my.desk.qcells.com/browse/G2T-18]


### (연속 스텝)

**Action:**

SSH > 현재 실행 중인 Application 조회 

* # ps | grep edge

**Expected Result:**

현재 실행 중인 Application의 PID가 정상적으로 

296876 root      0:00 {startup.sh} /bin/bash /edge/startup.sh /edge/app/bin/edge_runtime /edge/api/uniep/dist/www.js /edge/api/product/dist/www.js /edge/hmi/product/server_hmi.js
296897 root      3:24 /edge/app/bin/edge_runtime
296898 root      0:21 node /edge/api/uniep/dist/www.js
296899 root      0:08 node /edge/api/product/dist/www.js
296900 root      0:02 node /edge/hmi/product/server_hmi.js
296940 root      0:54 /edge/app/bin/db_manager
296972 root      1:18 /edge/app/bin/azure_connector
296973 root      1h00 /edge/app/bin/energy_link
296974 root      1:02 /edge/app/bin/energy_monitor
296975 root      1:37 /edge/app/bin/sys_manager
296976 root      0:47 /edge/app/bin/system_log
296977 root      0:56 /edge/app/bin/template_app
296978 root      4:43 /edge/app/bin/update_monitor
297079 root      2:56 /edge/app/bin/device_manager
297080 root      1:00 /edge/app/bin/energy_dispatcher
587418 root      0:00 grep edge


### (연속 스텝)

**Action:**

일부 Application 종료 > EMS Log 확인 

* # kill -9 PID
** 예) kill -9 297080

**Expected Result:**

watchdog heartbeat 미수신으로 재부팅 되어야 함

* [I][ER] Reboot Now!!! Requested by edge_runtime, {"reason":"watchdog"}, 2025. 12. 22 02:25:26


### (연속 스텝)

**Action:**

SSH 세션 2개 연결 

* 세션 1 : journalctl -f

* 세션 2 : mosquitto_pub -h localhost -t 'emsp/edge_runtime/udev/req/request_reboot' -m '{"reason":"test_restart"}'
* 세션 2 실행 후 세션 1 Log 확인

**Expected Result:**

자식 프로세스가 안전하게 종료 되어야 함 (cleanup Log 확인)

* EnergyDispatcher cleanup


### (연속 스텝)

**Action:**

Test Restart 실행 

*  # mosquitto_pub -h localhost -t 'emsp/edge_runtime/udev/req/request_reboot' -m '{"reason":"test_restart"}'

**Data:**

Step 4,5 검토 필요 (아래 TC와 중복)

* [https://my.desk.qcells.com/browse/G2T-27|https://my.desk.qcells.com/browse/G2T-27]

**Expected Result:**

아래 경로에 재부팅 정보가 정상적으로 기록 되어야 함 

* /edge/log/reboot_info.txt


## TC-7 (원본 Key 186)

[AC GEN2][Unified Edge Platform][Edge Runtime] Application 실행

**Action:**

SSH > journalctl  로그 출력 

* # journalctl -f


### (연속 스텝)

**Action:**

SSH > 새로운 Window > dockser Container ID 확인 

* # docker ps

**Expected Result:**

docker container ID 가 정상적으로 표시 되어야 함 

* 예) 3ba0e49912af


### (연속 스텝)

**Action:**

docker container stop > journal 로그 확인 

* # docker stop [docker container ID] 
** 예) docker stop 3ba0e49912af

**Expected Result:**

docker container 가 재 시작되고 Core Container의 Application 들이 정상적으로 fork 되어야 함 

* 정상 fork 시 로그 
** [I][ER] Spawn App: energy_dispatcher
** [I][ER] app_fork - pid: 144
* 비정상 fork 시 로그 
** posix_spawn failed: STATUS


### (연속 스텝)

**Action:**

실행 중인 Application 확인 

* # ps | grep edge

**Data:**

2025-12-02 기준 필수 Application 리스트

* Edge Runtime
* DB Manager
* Azure Connector
* Energy Monitor
* Energy Link
* Sys Manager
* Update Monitor
* Energy Dispatcher
* Device Manager

**Expected Result:**

실행 중인 Application이 정상적으로 표시 되어야 함

{noformat}15807 root      0:00 {startup.sh} /bin/bash /edge/startup.sh /edge/app/bin/edge_runtime /edge/api/uniep/dist/www.js /edge/api/product/dist/www.js /edge/hmi/product/server_hmi.js
15829 root      0:00 /edge/app/bin/edge_runtime
15830 root      0:10 node /edge/api/uniep/dist/www.js
15831 root      0:05 node /edge/api/product/dist/www.js
15832 root      0:01 node /edge/hmi/product/server_hmi.js
15874 root      0:00 /edge/app/bin/db_manager
15889 root      0:00 /edge/app/bin/azure_connector
15890 root      0:13 /edge/app/bin/energy_link
15891 root      0:01 /edge/app/bin/energy_monitor
15893 root      0:00 /edge/app/bin/sys_manager
15894 root      0:00 /edge/app/bin/system_log
15895 root      0:00 /edge/app/bin/template_app
15902 root      0:00 /edge/app/bin/update_monitor
15986 root      0:07 /edge/app/bin/device_manager
15987 root      0:00 /edge/app/bin/energy_dispatcher
16512 root      0:00 grep edge{noformat}


