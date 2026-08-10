# Flexible connectivity — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/products/ac_system_gen2/application/device_manager`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][Flexible connectivity]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 136)

[AC GEN2][Unified Edge Platform][Flexible connectivity] 코드 수정 없이 구성 변경 지원 검증

**Action:**

configuration.json 파일에 새로운 Device 또는 Protocol에 대한 connection 정보를 추가한다.


### (연속 스텝)

**Action:**

기존 설정이 초기화되도록 EMS DB를 삭제한다.


### (연속 스텝)

**Action:**

EMS 시스템을 재부팅한다.


### (연속 스텝)

**Action:**

시스템 부팅 후 로그를 확인하여 configuration.json에 추가된 Protocol에 대한 연결 시도가 수행되는지 확인한다.


### (연속 스텝)

**Action:**

Source code 수정 없이 configuration.json 변경만으로 새로운 Device 또는 Protocol 연결 동작이 수행되는지 검증한다.


## TC-2 (원본 Key 137)

[AC GEN2][Unified Edge Platform][Flexible connectivity] JSON 기반 정보 Load

**Action:**

시스템이 booting하고나서 Config / RegMap json data 중 하나라도 없을 경우 검증

* configuration.json 또는 RegisterMaps.json data 저장하지 않은 상태에서 시스템을 시작


### (연속 스텝)

**Action:**

* system log를 통해 필요한 file이 없어서 동작하지 않았다는 [EL] messag를 통해서 확인

Web HMI 페이지 System > Log Level > Energy Link 설정

**Data:**

[직접 test 후 로그 확인 후 수정 예정]

**Expected Result:**

로그가 표시 된다


### (연속 스텝)

**Action:**

시스템이 booting하고나서 Config / RegMap json file을 문제없이 Load하는지 확인

**Data:**

* [https://github.com/qcells-hqct/qcells-cloud-server-nextgen-schemas/tree/main/examples|https://github.com/qcells-hqct/qcells-cloud-server-nextgen-schemas/tree/main/examples]{color:#ffffff}Github 계정 연결{color}  정의된 최신 configuration json, RegisterMaps.json file을 이용하여 Test진행


### (연속 스텝)

**Action:**

* Test를 위해 해당 file들을 특정 위치에 넣고 또는 Web HMI를 통해 data를 추가하고 reboot

**Expected Result:**

data 추가 후 정상 reboot 된다


### (연속 스텝)

**Action:**

* system log를 통해 정상적으로 data을 load했는지 확인

**Expected Result:**

정상적으로 data가 load되는 것이 표시된다


## TC-3 (원본 Key 189)

[AC GEN2][Unified Edge Platform][Flexible connectivity] 주기적인 Read Data 처리

**Action:**

Energy Link Log Level : Debug로 변경


### (연속 스텝)

**Action:**

EMS 로그에서 아래 정보 확인 

* 통신 방법 (CAN, Modbus, SPI)
* Read 주기 (Modbus, SPI 한정)
** operation
** periodMs

**Expected Result:**

아래와 같이 주기적으로 Data를 Read 해야 함 

* operation  : "read" 인 그룹만 주기적으로 Read 해야 함 
* periodMs 주기로 Read 해야 함 (예: 1000 > 1초 주기)


