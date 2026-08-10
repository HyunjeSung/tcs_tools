# Remote Update — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/products/ac_system_gen2/application/update_monitor`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][Remote Update]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 101)

[AC GEN2][Unified Edge Platform][Remote Update] 업데이트 스크립트 재사용성 확보

**Action:**

.swu  형식의 파일로 로컬 업데이트 시도

**Expected Result:**

.swu 형식의 파일로 로컬 업데이트가 정상적으로 가능 해야 함


### (연속 스텝)

**Action:**

ADU에서 .swu 형식의 파일로 Push 업데이트 시도

**Data:**

.swu 형식의 파일로 로컬, Push 업데이트 모두 가능 해야 함.

**Expected Result:**

Push 업데이트가 정상적으로 가능 해야 함.


## TC-2 (원본 Key 102)

[AC GEN2][Unified Edge Platform][Remote Update] Script Manifest 단계별 상태 검증

**Action:**

첨부 스크립트 아래와 같이 편집 후 실행 

*  ["is-installed"]=true  (나머지 단계=false)
* sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json

**Expected Result:**

is-install 단계가 수행 되어야 함 

* is-installed.done  및 result.json 파일 생성 
* result.json 파일에 step과 result code가 정상적으로 기록 되어야 함 (901)

{noformat}{
  "step": "is-installed",
  "resultCode": 901,
  "timestamp": "2026-06-08T08:04:11Z"
}{noformat}


### (연속 스텝)

**Action:**

첨부 스크립트 아래와 같이 편집 후 실행 

*  ["download"]=true (나머지 단계=false)
* sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json

**Expected Result:**

download 단계가 수행 되어야 함 

* download.done  및 result.json 파일 생성 
* result.json 파일에 step과 result code가 정상적으로 기록 되어야 함 (500)

{noformat}{
  "step": "download",
  "resultCode": 500,
  "timestamp": "2026-06-08T08:09:44Z"
}{noformat}


### (연속 스텝)

**Action:**

첨부 스크립트 아래와 같이 편집 후 실행 

*  ["install"]=true (나머지 단계=false)

* sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json

**Expected Result:**

install 단계가 수행 되어야 함 

* install.done  및 result.json 파일 생성 
* result.json 파일에 step과 result code가 정상적으로 기록 되어야 함 (600)

{noformat}{
  "step": "install",
  "resultCode": 600,
  "timestamp": "2026-06-08T08:11:39Z"
}{noformat}


### (연속 스텝)

**Action:**

첨부 스크립트 아래와 같이 편집 후 실행 

* ["apply"]=true (나머지 단계=false)

* sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json

**Expected Result:**

apply 단계가 수행 되어야 함 

* apply.done 및 result.json 파일 생성 
* result.json 파일에 step과 result code가 정상적으로 기록 되어야 함 (700)

{noformat}{
  "step": "apply",
  "resultCode": 700,
  "timestamp": "2026-06-08T08:13:40Z"
}{noformat}


## TC-3 (원본 Key 103)

[AC GEN2][Unified Edge Platform][Remote Update] OTA 업데이트 지원


### (연속 스텝)

**Action:**

h3. ADU 기반 OTA 업데이트 정상 수행

Azure Device Update(ADU)를 통해 클라우드에서 OTA 업데이트 배포 수행

**Expected Result:**

* IoT Hub를 통해 업데이트 배포 명령이 디바이스로 전달됨
* ADU Agent가 Desired Property를 정상 수신함
* 업데이트 Workflow가 정상 시작됨
* UpdateState가 Download → Install → Apply 단계로 전이됨
* 업데이트가 성공적으로 완료됨


### (연속 스텝)

**Action:**

h3. ADU Import Manifest 정상 등록 검증

OTA 업데이트를 위한 Import Manifest를 ADU 포털에 등록

**Expected Result:**

* Import Manifest가 JSON 형식 오류 없이 등록됨
* Provider / Name / Version 정보가 정상 인식됨
* 업데이트가 배포 가능한 상태로 전환됨


### (연속 스텝)

**Action:**

h3. 클라우드 → 디바이스 OTA 전송 경로 검증

클라우드에서 OTA 업데이트 배포 후 디바이스 수신 확인

**Expected Result:**

* IoT Hub → ADU Service → Device 경로가 정상 동작함
* 네트워크 연결을 통해 업데이트 파일이 다운로드됨
* 다운로드 중 오류 없이 파일 수신이 완료됨


### (연속 스텝)

**Action:**

h3. OTA 업데이트 중 네트워크 단절 시 재시도 처리

**Data:**

* 다운로드 실패가 감지됨
* ADU Agent가 재시도 또는 실패 상태로 전환됨
* 네트워크 복구 후 업데이트를 재개 또는 재시도 가능함


### (연속 스텝)

**Action:**

h3. OTA 업데이트 결과 상태 보고 검증

OTA 업데이트 완료 후 ADU 상태 확인

**Expected Result:**

* ADU 포털에서 업데이트 결과(Succeeded / Failed)가 표시됨
* installedUpdateId가 디바이스에 정상 기록됨
* 디바이스가 Idle 상태로 복귀함


### (연속 스텝)

**Action:**

h3. OTA 업데이트 실패 시 복구(Restore) 동작

OTA 업데이트 Install 또는 Apply 단계에서 실패 발생

**Expected Result:**

* 실패가 즉시 감지됨
* Restore 단계가 자동 수행됨
* 기존 소프트웨어 상태로 복구됨
* 서비스 중단 없이 시스템이 안정 상태를 유지함


### (연속 스텝)

**Action:**

h3. OTA 업데이트 이력 관리 검증

동일 디바이스에 대해 OTA 업데이트를 반복 수행

**Expected Result:**

* ADU 포털에서 업데이트 이력이 누적 관리됨
* 버전별 성공/실패 기록이 조회 가능함
* 동일 버전 재배포 시 정책에 따라 처리됨


### (연속 스텝)

**Action:**

h3. OTA 업데이트 대상 장비 그룹 배포 검증

IoT Hub Tag 또는 Device Group을 이용한 OTA 업데이트 수행

**Expected Result:**

* 지정된 장비 그룹에만 업데이트가 배포됨
* 그룹 외 장비는 업데이트를 수신하지 않음
* 대량 장비 OTA 배포가 안정적으로 수행됨


## TC-4 (원본 Key 104)

[AC GEN2][Unified Edge Platform][Remote Update] Azure IoT Hub 연동 지원

**Action:**

h2. ADU Agent 모듈 자동 생성 검증 (Remote Update 기반)

Azure IoT Hub에 디바이스가 등록된 이후 Device Update Agent가 기동됨

**Expected Result:**

* IoT Hub 디바이스 하위에 *"adu" 모듈이 자동 생성됨*
* ADU Agent가 모듈 형태(Module Identity)로 동작함
* 별도의 수동 모듈 생성 없이 Remote Update 구조가 완성됨


### (연속 스텝)

**Action:**

h2. ADU 모듈 기반 IoT Hub 연결 성공 확인

ADU Agent 기동 후 IoT Hub 연결 상태 확인

**Expected Result:**

* ADU Agent가 Module Identity로 IoT Hub에 연결됨
* MQTT 연결이 정상적으로 수립됨
* 아래와 같은 로그가 확인된다
* {noformat}Attempting to create connection to IoTHub using type: ADUC_ConnType_Module
Successfully re-authenticated the IoT Hub connection
{noformat}


### (연속 스텝)

**Action:**

h2. ADU 모듈 Health Check 통과 검증

ADU Agent 기동 직후 상태 점검

**Expected Result:**

* ADU Agent Health Check가 통과됨
* ADU 모듈 상태가 정상(Running)으로 유지됨
* Remote Update를 수신할 준비 상태가 됨


### (연속 스텝)

**Action:**

h2. Import Manifest 기반 Remote Update 트리거 수신

Azure Device Update 포털에서 Import Manifest 기반 업데이트 배포

**Expected Result:**

* ADU 모듈이 *Desired Property 업데이트를 수신함*
* OrchestratorUpdateCallback이 호출됨
* Remote Update Workflow가 시작됨


### (연속 스텝)

**Action:**

h2. ADU 모듈을 통한 단계별 원격 업데이트 수행

Remote Update 트리거 수신 후 업데이트 진행

**Expected Result:**

* ADU 모듈이 update handler(microsoft/script:1 또는 swupdate:2)를 로딩함
* is-installed → download → install → apply 단계가 순차 실행됨
* result.json(aduc_result.json)이 단계별로 갱신됨


## TC-5 (원본 Key 105)

[AC GEN2][Unified Edge Platform][Remote Update] .swu 파일 서명 및 암호화 적용

**Action:**

Web HMI > Update 페이지 접속 

* http://192.168.10.20:9111

**Data:**

* 실제 할당 받은 IP 주소 입력


### (연속 스텝)

**Action:**

RSA 서명 훼손된 파일로 업데이트 시도 > EMS+ 로그 확인

**Data:**

훼손된 파일은 아래 링크 참고 (용량 문제로 첨부 불가) 

* [https://my.desk.qcells.com/browse/AGSRS-286|https://my.desk.qcells.com/browse/AGSRS-286]

**Expected Result:**

아래와 같은 로그가 출력되며 업데이트가 진행되지 않아야 함 

* [ERROR] : SWUPDATE failed [0] ERROR swupdate_rsa_verify.c : verify_final : 99 : EVP_DigestVerifyFinal failed, error 0x2000077 0


### (연속 스텝)

**Action:**

AES Key 훼손된 파일로 업데이트 시도 > EMS+ 로그 확인

**Data:**

훼손된 파일은 아래 링크 참고 (용량 문제로 첨부 불가) 

* [https://my.desk.qcells.com/browse/AGSRS-286|https://my.desk.qcells.com/browse/AGSRS-286]

**Expected Result:**

아래와 같은 로그가 출력되며 업데이트가 진행되지 않아야 함 

* [ERROR] : SWUPDATE failed [0] ERROR swupdate_decrypt_openssl.c : swupdate_DECRYPT_final : 103 : Final: Decryption error 0x1c800064, reason: bad decrypt


## TC-6 (원본 Key 106)

[AC GEN2][Unified Edge Platform][Remote Update] 중단, 이어받기, 재시작 지원

**Action:**

* {{.swu}} 이미지 기반 ADU 업데이트 배포 수행


### (연속 스텝)

**Action:**

* 디바이스에서 다운로드 중 강제 재부팅 수행

**Expected Result:**

다운로드 중단 후 재사용 가능한 파일이 보존된다


### (연속 스텝)

**Action:**

* 재부팅 후 동일 WorkflowId 재인식 여부 확인

**Expected Result:**

동일 WorkflowId가 재인식된다


### (연속 스텝)

**Action:**

* 기존 다운로드 파일 재활용 여부 확인

**Expected Result:**

재 다운로드 없이 설치가 진행된다


### (연속 스텝)

**Action:**

* 설치(install) 단계 정상 진행 여부 확인

**Expected Result:**

설치 성공 및 단계별 로그 출력 확인


## TC-7 (원본 Key 107)

[AC GEN2][Unified Edge Platform][Remote Update] 리소스 제한

**Action:**

현재 장비 리소스를 확인한다

{noformat}youngwoong@ywrasidebian11:~$ df --output=avail /tmp | tail -n1
96467164
youngwoong@ywrasidebian11:~$ grep MemAvailable /proc/meminfo
MemAvailable:    3506236 kB{noformat}


### (연속 스텝)

**Action:**

{noformat}youngwoong@ywrasidebian11:~$ cat /etc/adu-resource-limit.conf
# intentionally fail resource check
MIN_DISK_KB=98000000     # 98GB (현재보다 높게 설정)
MIN_MEM_KB=4000000       # 4GB (현재보다 높게 설정){noformat}


### (연속 스텝)

**Action:**

h3. result.json 출력 예시 – 디스크 공간 부족일시

{noformat}{   
  "step": "install",   
  "resultCode": 905001,   
  "extendedResultCode": 90500101,   
  "resultDetails": "디스크 공간 부족 (96467164 KB < 98000000 KB)",   
  "timestamp": "2025-07-28T03:22:10Z" 
}{noformat}

**Expected Result:**

Action란에 있는 로그와 같이 나타난다.


### (연속 스텝)

**Action:**

h3. result.json 출력 예시 – 메모리 부족

{noformat}{   
  "step": "install",   
  "resultCode": 905002,   
  "extendedResultCode": 90500201,   
  "resultDetails": "메모리 부족 (3506236 KB < 4000000 KB)",   
  "timestamp": "2025-07-28T03:23:12Z" 
}{noformat}

**Expected Result:**

Action란에 있는 로그와 같이 나타난다.


### (연속 스텝)

**Action:**

h3. 업데이트 수행 전 디스크 및 메모리 리소스 정상 확인

디바이스의 디스크 공간 및 메모리 사용 가능량이 사전 정의된 기준 이상인 상태에서 업데이트 수행

**Expected Result:**

* install 단계 진입 전 디스크 및 메모리 리소스 검사 수행됨
* 현재 리소스 값이 기준(MIN_DISK_KB, MIN_MEM_KB) 이상으로 확인됨
* 리소스 검사 통과 로그가 기록됨
* 업데이트가 정상적으로 install 단계로 진행됨


### (연속 스텝)

**Action:**

h3. 디스크 공간 부족 시 업데이트 중단

디스크 사용 가능량이 MIN_DISK_KB 기준보다 낮은 상태에서 업데이트 수행

**Expected Result:**

* install 단계 진입 전 디스크 공간 검사 수행됨
* 디스크 공간 부족 상태가 감지됨
* 업데이트가 즉시 중단됨
* result.json에 실패 상태가 기록됨
* download / install / apply 단계가 실행되지 않음


### (연속 스텝)

**Action:**

h3. 메모리 부족 시 업데이트 중단

메모리 사용 가능량이 MIN_MEM_KB 기준보다 낮은 상태에서 업데이트 수행

**Expected Result:**

기대 결과:

* install 단계 진입 전 메모리 사용 가능량 검사 수행됨
* 메모리 부족 상태가 감지됨
* 업데이트가 즉시 중단됨
* result.json에 실패 상태가 기록됨
* install 및 이후 단계가 실행되지 않음


### (연속 스텝)

**Action:**

h3. 디스크 및 메모리 동시 부족 시 업데이트 차단

디스크 공간과 메모리 사용 가능량이 모두 기준 미달인 상태에서 업데이트 수행

**Expected Result:**

* 리소스 검사 단계에서 첫 번째 실패 조건이 감지됨
* 업데이트가 install 단계 진입 전에 중단됨
* result.json에 실패 사유가 명확히 기록됨
* 시스템에 불필요한 리소스 사용이 발생하지 않음


### (연속 스텝)

**Action:**

h3. 리소스 부족 실패 시 result.json 기록 검증

리소스 부족으로 업데이트가 중단된 경우

**Expected Result:**

* result.json에 step=install 로 기록됨
* resultCode 및 extendedResultCode가 설정됨
* resultDetails에 실제 측정값과 기준값이 포함됨
* timestamp가 기록됨


### (연속 스텝)

**Action:**

h3. 리소스 제한 설정 파일 기반 동작 검증

{{/etc/adu-resource-limit.conf}} 파일의 임계값을 변경하여 업데이트 수행

**Expected Result:**

* 설정 파일의 MIN_DISK_KB, MIN_MEM_KB 값이 즉시 반영됨
* 스크립트 수정 없이 리소스 기준 변경 가능함
* 운영 환경별로 유연한 기준 설정이 가능함


## TC-8 (원본 Key 108)

[AC GEN2][Unified Edge Platform][Remote Update] 네트워크 장애 복구 지원

**Action:**

Cloud > FW 업데이트 중 네트워크 단절


### (연속 스텝)

**Action:**

네트워크 연결 > FW 업데이트 동작 확인

**Expected Result:**

FW 업데이트 재시도 하여 중단 없이 정상적으로 FW 업데이트 완료 되어야 함


## TC-9 (원본 Key 128)

[AC GEN2][Unified Edge Platform][Remote Update] 컨테이너 기반 배포

**Action:**

h3. Docker 이미지 기반 컨테이너 업데이트 정상 수행

업데이트 대상 애플리케이션이 Docker 컨테이너 형태로 배포된 상태에서 업데이트 수행

**Expected Result:**

* 업데이트 패키지가 Docker 이미지 형태로 배포됨

* docker pull 또는 docker load를 통해 이미지가 업데이트됨
* 신규 컨테이너가 Docker 이미지 기반으로 실행됨
* 업데이트 이후 애플리케이션이 정상 동작함


### (연속 스텝)

**Action:**

h3. 기존 컨테이너 유지 상태에서 컨테이너 전환

업데이트 수행 전 기존 컨테이너가 실행 중인 상태

**Data:**

while true; do docker ps; sleep 10; done

**Expected Result:**

* 기존 컨테이너가 즉시 삭제되지 않음

* 신규 컨테이너 준비 완료 후 컨테이너 전환이 수행됨
* 전환 과정에서 서비스 중단이 최소화됨


### (연속 스텝)

**Action:**

h3. Docker Volume 마운트 데이터 보존

컨테이너에 Docker Volume이 마운트된 상태에서 업데이트 수행

**Expected Result:**

* 업데이트 전·후 Docker Volume이 동일하게 마운트됨
* Volume에 저장된 데이터가 손실되지 않음
* 신규 컨테이너에서 기존 데이터를 정상 참조함


## TC-10 (원본 Key 129)

[AC GEN2][Unified Edge Platform][Remote Update] 무결성 검증 지원

**Action:**

h3. 정상 서명 및 SHA256 해시 검증 시 업데이트 성공

* 서명 및 SHA256 해시가 정상인 .swu 파일을 사용하여 업데이트 수행

**Expected Result:**

* ADU Agent가 Manifest를 정상 파싱함
* SWUpdate가 .swu 파일의 SHA256 해시를 검증함
* sw-description.sig 서명 검증이 성공함
* install 및 apply 단계가 정상 수행됨
* aduc_result.json 파일이 생성됨
* UpdateState가 Succeeded 또는 Idle로 정상 전환됨


### (연속 스텝)

**Action:**

h3. sw-description 서명 검증 실패 시 업데이트 차단

* sw-description.sig 파일이 변조된 .swu 파일로 업데이트 수행

**Expected Result:**

* SWUpdate에서 서명 검증 실패 로그 출력
* install 단계 이전에 업데이트가 중단됨
* aduc_result.json 파일이 생성되지 않거나 실패 상태로 기록됨
* ADU 상태가 Install Failed로 전환됨


### (연속 스텝)

**Action:**

h3. .swu 파일 SHA256 해시 불일치 시 업데이트 실패

* swu 파일의 내부 파일(myimage.tar.gz.enc 등)을 변조하여 해시 불일치 상태에서 업데이트 수행

**Expected Result:**

* SWUpdate에서 SHA256 해시 불일치 오류 로그 출력
* install 단계 진입 없이 업데이트가 중단됨
* Docker Pull/Load 또는 설치 로직이 실행되지 않음
* UpdateState가 Failed로 처리됨


### (연속 스텝)

**Action:**

h3. 스크립트 파일 해시 검증 실패 시 업데이트 중단

* example-a-b-update_swu.sh 파일이 변조된 상태에서 업데이트 수행

**Expected Result:**

* ADU 또는 SWUpdate에서 파일 무결성 오류 로그 출력

* 스크립트 실행 단계가 중단됨
* aduc_result.json 파일에 실패 상태 코드가 기록됨


## TC-11 (원본 Key 130)

[AC GEN2][Unified Edge Platform][Remote Update]  업데이트 진행률 실시간 확인

**Action:**

FW 업데이트 중 장비 로그 확인

**Expected Result:**

업데이트 진행률이 정상적으로 출력 되어야 함 

* progress socket을 통해 업데이트 진행률(예: 0% → 100%)이 실시간으로 수신됨
* 각 단계(RUN / SUCCESS / DONE)에 대한 상태 메시지가 순차적으로 전달됨
* Update Monitor가 진행률을 로그로 출력함


## TC-12 (원본 Key 131)

[AC GEN2][Unified Edge Platform][Remote Update] 기존 컨테이너 및 볼륨 데이터 보존

**Action:**

h3. 정상 업데이트 시 기존 컨테이너 유지 및 데이터 보존

업데이트 대상 컨테이너가 실행 중이며, Docker Volume이 마운트된 상태에서 업데이트 수행

**Expected Result:**

* 업데이트 수행 전 실행 중이던 컨테이너가 중단되지 않음
* 컨테이너 재생성 없이 업데이트가 수행됨
* Docker Volume에 저장된 데이터가 그대로 유지됨
* 업데이트 완료 후 애플리케이션이 정상 동작함


### (연속 스텝)

**Action:**

h3. 업데이트 전·후 Docker Volume 데이터 무결성 검증

Docker Volume에 테스트 데이터 파일이 사전에 존재한 상태에서 업데이트 수행

**Expected Result:**

* 업데이트 이전과 이후에 동일한 데이터 파일이 존재함
* 파일 내용이 변경되지 않음
* 데이터 손실 또는 초기화가 발생하지 않음


## TC-13 (원본 Key 132)

[AC GEN2][Unified Edge Platform][Remote Update] 디바이스 HW 호환성 검사

**Action:**

h4. 정상 HW에서 업데이트 허용

* 디바이스 모델 = sw-description 모델

**Data:**

* Req Type : Non-Functional(Portability(이식성))

* Requirement
** 업데이트 수행 전, sw-description 파일 내 정의된 내용을 바탕으로 디바이스의 하드웨어 호환성을 검사해야 한다.

**Expected Result:**

* HW Compatibility 검사 통과

* 업데이트 정상 진행


### (연속 스텝)

**Action:**

h4. 모델 불일치로 업데이트 차단

* 디바이스 모델 ≠ sw-description 모델

**Expected Result:**

* HW Compatibility 검사 실패
* result.json에 오류 코드 기록
* install/apply 미실행


## TC-14 (원본 Key 133)

[AC GEN2][Unified Edge Platform][Remote Update] 진행 단계별 result.json 생성 및 결과 저장

**Action:**

Test Script를 아래와 같이 편집 > Script 실행 

* declare -A ACTIONS=(
  *["is-installed"]=true*
  ["download"]=false
  ["install"]=false
  ["apply"]=false
  ["cancel"]=false
)
* 실행 예시) sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json
** 실행 및 결과 파일 생성 경로 지정

**Data:**

is-installed 단계까지 진행된 상태로 시뮬레이션

**Expected Result:**

is-installed 단계까지 진행 된 업데이트 결과 파일이 생성 되어야 함 

* is-installed.done 파일 생성 
** {
  *"step": "is-installed",*
  *"resultCode": 901,*
  "timestamp": "2026-01-14T07:18:34Z"
}


### (연속 스텝)

**Action:**

Test Script를 아래와 같이 편집 > Script 실행

* declare -A ACTIONS=(
  ["is-installed"]=false
  *["download"]=true*
  ["install"]=false
  ["apply"]=false
  ["cancel"]=false
)
* 실행 예시) sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json
** 실행 및 결과 파일 생성 경로 지정

**Data:**

download 단계까지 진행된 상태로 시뮬레이션

**Expected Result:**

download 단계까지 진행 된 업데이트 결과 파일이 생성 되어야 함

* download.done 파일 생성

{
  *"step": "download",*
  *"resultCode": 500,*
  "timestamp": "2026-01-14T07:47:02Z"
}
~


### (연속 스텝)

**Action:**

Test Script를 아래와 같이 편집 > Script 실행

* declare -A ACTIONS=(
  ["is-installed"]=false
  ["download"]=false
  *["install"]=true*
  ["apply"]=false
  ["cancel"]=false
)
* 실행 예시) sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json
** 실행 및 결과 파일 생성 경로 지정

**Data:**

install 단계까지 진행된 상태로 시뮬레이션

**Expected Result:**

install 단계까지 진행 된 업데이트 결과 파일이 생성 되어야 함

* install.done 파일 생성

{

*"step": "install",*
*"resultCode": 600,*
"timestamp": "2026-01-14T07:49:45Z"
}


### (연속 스텝)

**Action:**

Test Script를 아래와 같이 편집 > Script 실행

* declare -A ACTIONS=(
  ["is-installed"]=false
  ["download"]=false
  ["install"]=false
  *["apply"]=true*
  ["cancel"]=false
)
* 실행 예시) sh simulation-script2.sh --work-folder /edge/log --result-file /edge/log/result.json
** 실행 및 결과 파일 생성 경로 지정

**Data:**

apply 단계까지 진행된 상태로 시뮬레이션

**Expected Result:**

apply 단계까지 진행 된 업데이트 결과 파일이 생성 되어야 함

* apply.done 파일 생성

{
*"step": "apply",*
*"resultCode": 700,*
"timestamp": "2026-01-14T07:51:38Z"
}


## TC-15 (원본 Key 134)

[AC GEN2][Unified Edge Platform][Remote Update] 외부 컨테이너 진행 상태 모니터링

**Action:**

h3. 정상 업데이트 중 외부 컨테이너에서 WebSocket 연결 성공

**Data:**

업데이트가 진행 중이며 Update Monitor 컨테이너(애플리케이션)가 실행 중인 상태

**Expected Result:**

* 외부 컨테이너(WebSocket 클라이언트)가 Update Monitor에 정상 연결된다
* WebSocket 연결이 업데이트 시작부터 종료까지 유지된다


### (연속 스텝)

**Action:**

h3. 업데이트 진행률 WebSocket 실시간 수신

**Data:**

SWUpdate가 .swu 파일을 정상 설치하며 진행 중

**Expected Result:**

* WebSocket을 통해 진행률 이벤트가 실시간으로 수신됨
* 진행률 값이 0% → 100% 방향으로 점진적으로 증가함


## TC-16 (원본 Key 135)

[AC GEN2][Unified Edge Platform][Remote Update] Docker Load 및 Pull 지원

**Action:**

h3. TC-DCK-01: Docker Pull 방식 업데이트 정상 수행

SWUpdate 기반 업데이트에서 {{--mode pull}} 옵션을 사용하여 Docker 이미지를 Pull 방식으로 설치

기대 결과:

* Handler 스크립트가 pull 모드로 실행됨
* docker login 후 docker pull 명령이 정상 수행됨
* install 단계에서 Docker 이미지가 정상 다운로드됨
* result.json에 install 성공 상태 코드가 기록됨
* apply 단계까지 정상 완료됨

**Data:**

예시파일 첨부

**Expected Result:**

해당 플로우가 정상 동작 된다


### (연속 스텝)

**Action:**

* *TC-DCK-02: Docker Load 방식 업데이트 정상 수행*

SWUpdate 기반 업데이트에서 {{--mode load}} 옵션을 사용하여 Docker 이미지를 Load 방식으로 설치

기대 결과:

* 암호화된 Docker 이미지 파일(myimage.tar.gz.enc)이 복호화됨
* docker load 명령이 정상 수행됨
* 로컬 이미지로 컨테이너 이미지가 등록됨
* result.json에 install 성공 상태 코드가 기록됨
* apply 단계까지 정상 완료됨

**Expected Result:**

해당 플로우가 정상 동작 된다


