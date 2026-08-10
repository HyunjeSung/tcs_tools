# Telemetry foundation — 요구사항 원본 (AC Gen2 TestCase.xlsx > Gen2 TestCae)

소스 매핑: `qcells/uniep/core/application/energy_monitor`

엑셀 브라켓 규칙: `[AC GEN2][Unified Edge Platform][Telemetry foundation]` → 마지막 브라켓이 앱 이름

---

## TC-1 (원본 Key 138)

[AC GEN2][Unified Edge Platform][Telemetry foundation] Report 항목 필터링

**Action:**

* Telemetry 항목으로 선정된 항목만 report 한다.
** (LOG확인법) 
{noformat}[   58.943452] docker-loader[631]: [07:15:26:600][I][AZ] Success to send message with headers. Message: {"devices":[{"assetId":"60733-sn234234234","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},{"assetId":"60734-sn123123123","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"}],"oem":"Solax","sendTimestamp":"2025-12-16T23:25:09Z","site":{"assetId":"123456789","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},"siteId":"123456789","type":"CommonTelemetryDto","version":"1.0"}{noformat}

**Expected Result:**

Action란에 있는 로그가 확인된다.


### (연속 스텝)

**Action:**

* Azure Iot Hub Explorer로 확인하는 방법
** configuration.json에서 정의한 deviceMetricList 항목이 포함되어 있는지 확인

!36d71c5c-b2e2-4112-9ce7-133984d14b04|width=926,height=692,alt="image-20251217-075042.png"!


## TC-2 (원본 Key 139)

[AC GEN2][Unified Edge Platform][Telemetry foundation] Azure IoT Hub 전송

**Action:**

* 생성된 telemetry data를 설정된 주기마다 MQTT를 이용해 Azure IoT Hub로 전송한다.

* Azure Iot Hub의 Explorer를 이용하여 Common-Telemetry 값을 확인한다

**Expected Result:**

* 유효한 값이 확인된다.

!04568702-2005-4c9e-ab4a-3502fe6f5726|width=926,height=692,alt="image-20251217-072140.png"!


## TC-3 (원본 Key 140)

[AC GEN2][Unified Edge Platform][Telemetry foundation] 평균 값 계산

**Action:**

* 본 requirement는 report 되는 항목이 순시값이 아닌 common telemetry report 주기동안의 평균 값으로 report 되어야 한다는 requirement다.
* configuration.json의 "qualifier" 값이 "Avg"로 되어 있는 항목은 순시 값이 아닌 평균 값이 report 되어야 한다.
** configuration.json 파일(26.01.15 기준) :   
{noformat}                {
                    "rid": "sn234234234-000002",
                    "name": "Tot_ESS_Apparent_Power",
                    "description": "MCU_Monitoring_Data_01/Tot_ESS_Apparent_Power",
                    "profileID": "Qcells_Common",
                    "readingType": {
                        "uom": "ASCII",
                        "qualifier": "Avg",
                        "accumulationType": "Instantaneous",
                        "tenMultiplier": 1
                    },
                    "metricPath": "sn234234234/tpo_opt_spi_reg_map/1s_read_group/MCU_Monitoring_Data_01/Tot_ESS_Apparent_Power"
                },{noformat}
*


### (연속 스텝)

**Action:**

* 평균값을 확인하는 방법은 아래의 두가지 방법이 있다.
** 로그로 확인하는 경우
*** 첫째로 Energy Link에서 보내주는 telemetry 값을 확인한다.
로그의 예시는 아래와 같다.([EM] → Energy Monitor log header)

{noformat}[   58.583575] docker-loader[631]: [07:15:26:546][D][EM] [EM] IPC notification energy_link telemetry : [
[   58.583897] docker-loader[631]:     {
[   58.584365] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD1",
[   58.584796] docker-loader[631]:         "value": 0.33
[   58.585100] docker-loader[631]:     },
[   58.585410] docker-loader[631]:     {
[   58.585680] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD2",
[   58.585941] docker-loader[631]:         "value": 0.33
[   58.586180] docker-loader[631]:     },
[   58.586422] docker-loader[631]:     {
[   58.586707] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD3",
[   58.586981] docker-loader[631]:         "value": 0.33
[   58.587238] docker-loader[631]:     },
[   58.587541] docker-loader[631]:     {
[   58.587809] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD4",
[   58.588375] docker-loader[631]:         "value": 0.33
[   58.588656] docker-loader[631]:     },
[   58.588907] docker-loader[631]:     {
[   58.589162] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Power_Control_Point",
[   58.589472] docker-loader[631]:         "value": 3304.21
[   58.589726] docker-loader[631]:     },
[   58.589964] docker-loader[631]:     {
[   58.590218] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/INV_Target_Power",
[   58.590512] docker-loader[631]:         "value": 3304.21
[   58.590753] docker-loader[631]:     },
[   58.590996] docker-loader[631]:     {
[   58.591247] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Battery_Target_Power",
[   58.591526] docker-loader[631]:         "value": 3304.21
[   58.591773] docker-loader[631]:     },
[   58.592054] docker-loader[631]:     {
[   58.592398] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Debug",
[   58.592743] docker-loader[631]:         "value": 33.04
[   58.593065] docker-loader[631]:     },
[   58.593327] docker-loader[631]:     {
[   58.593601] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Minor",
[   58.593895] docker-loader[631]:         "value": 33.04
[   58.594150] docker-loader[631]:     },
[   58.594395] docker-loader[631]:     {
[   58.594662] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Major",
[   58.594925] docker-loader[631]:         "value": 33.04
[   58.595173] docker-loader[631]:     },
[   58.595473] docker-loader[631]:     {
[   58.595750] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Division",
[   58.596054] docker-loader[631]:         "value": 33.04
[   58.596367] docker-loader[631]:     },
[   58.596635] docker-loader[631]:     {
[   58.596901] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/jf2_normal_and_additional_read/Temperature_Data/Temperature_4_in_the_rack",
[   58.597217] docker-loader[631]:         "value": 26.61
[   58.597496] docker-loader[631]:     }
[   58.597780] docker-loader[631]: ]
[   58.598084] docker-loader[631]: [07:15:26:546][D][EM] Processing telemetry payload with 12 metrics
[   58.938942] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD1] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.939443] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD2] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.939774] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD3] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.940110] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD4] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.940446] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Power_Control_Point] value=3304.21, scaleFactor=1, periodMs=0, precision=0
[   58.940771] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/INV_Target_Power] value=3304.21, scaleFactor=1, periodMs=0, precision=0
[   58.941115] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Battery_Target_Power] value=3304.21, scaleFactor=1, periodMs=0, precision=0
[   58.941442] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Debug] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.941731] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Minor] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.941990] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Major] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.942251] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Division] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.942567] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/jf2_normal_and_additional_read/Temperature_Data/Temperature_4_in_the_rack] value=26.61, scaleFactor=1, periodMs=0, precision=0
[   58.942882] docker-loader[631]: [07:15:26:547][D][EM] Successfully processed 12 metrics from payload
{noformat}

**Expected Result:**

Energy Link에서 보내주는 telemetry값이 확인된다


### (연속 스텝)

**Action:**

* 아래의 로그와 같이 Azure Iot Hub로 보내지는 payload 중 type":"CommonTelemetryDto" 인 payload에서 해당 항목이 순시값이 아닌 평균 값으로 report 되는지 확인한다.
** {noformat}[   58.943452] docker-loader[631]: [07:15:26:600][I][AZ] Success to send message with headers. Message: {"devices":[{"assetId":"60733-sn234234234","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},{"assetId":"60734-sn123123123","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"}],"oem":"Solax","sendTimestamp":"2025-12-16T23:25:09Z","site":{"assetId":"123456789","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},"siteId":"123456789","type":"CommonTelemetryDto","version":"1.0"}{noformat}

**Expected Result:**

평균값으로 report 된다


## TC-4 (원본 Key 141)

[AC GEN2][Unified Edge Platform][Telemetry foundation] 전송 주기 조절


### (연속 스텝)

**Action:**

* telemetry data 생성 주기를 가변적으로 변경할 수 있어야 한다.
* 아래의 예시처럼 "samplingRate"이 60이면 60초(1분)마다 common telemetry가 Azure Iot Hub로 전송되어야 한다.
{noformat}{
    "version": 0,
    "lastModifiedBy": "energy.link@qcells.com",
    "lastModifiedAt": 1715088000000,
    "commonTelemetryVer": "1.0",
    "samplingRate": 60,
    "deviceList": [
        {{noformat}

**Expected Result:**

Action의 로그가 확인된다


### (연속 스텝)

**Action:**

* 로그로 확인하는 경우
** 아래의 로그와 같이 Azure Iot Hub로 보내지는 payload 중 type":"CommonTelemetryDto" 인 payload 전송 주기가 "samplingRate" 주기와 일치하는지 확인한다.
** 
{noformat}[   58.943452] docker-loader[631]: [07:15:26:600][I][AZ] Success to send message with headers. Message: {"devices":[{"assetId":"60733-sn234234234","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},{"assetId":"60734-sn123123123","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"}],"oem":"Solax","sendTimestamp":"2025-12-16T23:25:09Z","site":{"assetId":"123456789","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},"siteId":"123456789","type":"CommonTelemetryDto","version":"1.0"}
[   118.943452] docker-loader[631]: [07:16:26:600][I][AZ] Success to send message with headers. Message: {"devices":[{"assetId":"60733-sn234234234","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},{"assetId":"60734-sn123123123","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"}],"oem":"Solax","sendTimestamp":"2025-12-16T23:25:09Z","site":{"assetId":"123456789","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},"siteId":"123456789","type":"CommonTelemetryDto","version":"1.0"}{noformat}

**Expected Result:**

samplingRate주기와 일치 하는 payload 전송주기가 표시된다


### (연속 스텝)

**Action:**

Azure Iot Hub Explorer로 확인하는 방법

* payload 전송 주기가 "samplingRate" 주기와 일치하는지 확인한다.

**Expected Result:**

* payload 전송 주기가 "samplingRate" 주기가 일치한다.


## TC-5 (원본 Key 142)

[AC GEN2][Unified Edge Platform][Telemetry foundation] 소수점 자릿수 조정 검증

**Action:**

* tenMultiplier 설정에 따라 소수점 이하 자릿수를 조정한다.


### (연속 스텝)

**Action:**

Test 로 확인되어야 하는 것 (Pass/Fail 판정)

* 본 requirement는 common telemetry의 각 항목 값의 소수점 이하 자릿수를 정의하는 requirement이다.

{noformat}tenMultiplier: -2 → 10^(-2) = 0.01 (소수점 이하 2자리)
tenMultiplier: -1 → 10^(-1) = 0.1
tenMultiplier: 0 → 10^0 = 1
tenMultiplier: 1 → 10^1 = 10{noformat}

* 예를들어 tenMuliplier 가 -2로 설정되어 있으면 해당 항목의 값은 소수점 이하 두자리로 report 되어야 한다.(inverter_701_Hz_Single : 59.75)


### (연속 스텝)

**Action:**

* tenMultiplier는 configuration.json에 정의되어 있다.

{noformat}                {
                    "rid": "sn123123123-000003",
                    "name": "Total_PCS_Grid_Current",
                    "description": "1s_Monitoring_Data_2/Total_PCS_Grid_Current",
                    "profileID": "Qcells_Common",
                    "readingType": {
                        "uom": "A",
                        "qualifier": "Avg",
                        "accumulationType": "Instantaneous",
                        "tenMultiplier": -2
                    },
                    "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/all_read/1s_Monitoring_Data_2/Total_PCS_Grid_Current"
                },{noformat}

**Data:**

[configuration_.json|https://us.xray.cloud.getxray.app/api/internal/attachments/c7ac4d8f-6955-424d-afc4-edebd37ac3a0?inXray=true]


### (연속 스텝)

**Action:**

* 로그로 확인하는 경우
** 아래의 로그와 같이 Azure Iot Hub로 보내지는 payload 중 type":"CommonTelemetryDto" 인 payload에서 각 항목 값의 자릿수가 configuration.json에서 정의한 tenMultiplier에 맞게 올라가는지 확인

{noformat}[   58.943452] docker-loader[631]: [07:15:26:600][I][AZ] Success to send message with headers. Message: {"devices":[{"assetId":"60733-sn234234234","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},{"assetId":"60734-sn123123123","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"}],"oem":"Solax","sendTimestamp":"2025-12-16T23:25:09Z","site":{"assetId":"123456789","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},"siteId":"123456789","type":"CommonTelemetryDto","version":"1.0"}{noformat}

**Expected Result:**

Action란과 같은 Log가 확인된다.


### (연속 스텝)

**Action:**

* Azure Iot Hub Explorer로 확인하는 방법
** 각 항목 값의 자릿수가 configuration.json에서 정의한 tenMultiplier에 맞게 올라가는지 확인


## TC-6 (원본 Key 143)

[AC GEN2][Unified Edge Platform][Telemetry foundation] 누적값 계산 

**Action:**

* 아래의 로그와 같이 Azure Iot Hub로 보내지는 payload 중 type":"CommonTelemetryDto" 인 payload에서 누적값 항목의 값이 정상적으로 증가하는지 확인
{noformat}[   58.943452] docker-loader[631]: [07:15:26:600][I][AZ] Success to send message with headers. Message: {"devices":[{"assetId":"60733-sn234234234","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},{"assetId":"60734-sn123123123","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"}],"oem":"Solax","sendTimestamp":"2025-12-16T23:25:09Z","site":{"assetId":"123456789","points":null,"sourceTimestamp":"2025-12-16T23:25:09Z"},"siteId":"123456789","type":"CommonTelemetryDto","version":"1.0"}{noformat}

**Expected Result:**

* 누적 data가 필요한 telemetry 항목에 대해 설정된 주기에 따라 시간당 누적 값(wh)을 계산한다


## TC-7 (원본 Key 144)

[AC GEN2][Unified Edge Platform][Telemetry foundation] Telemetry 수신


### (연속 스텝)

**Action:**

* Energy Link로 부터 MQTT를 통해 telemetry data를 수신한다.
* {noformat}[   58.583575] docker-loader[631]: [07:15:26:546][D][EM] [EM] IPC notification energy_link telemetry : [
[   58.583897] docker-loader[631]:     {
[   58.584365] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD1",
[   58.584796] docker-loader[631]:         "value": 0.33
[   58.585100] docker-loader[631]:     },
[   58.585410] docker-loader[631]:     {
[   58.585680] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD2",
[   58.585941] docker-loader[631]:         "value": 0.33
[   58.586180] docker-loader[631]:     },
[   58.586422] docker-loader[631]:     {
[   58.586707] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD3",
[   58.586981] docker-loader[631]:         "value": 0.33
[   58.587238] docker-loader[631]:     },
[   58.587541] docker-loader[631]:     {
[   58.587809] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD4",
[   58.588375] docker-loader[631]:         "value": 0.33
[   58.588656] docker-loader[631]:     },
[   58.588907] docker-loader[631]:     {
[   58.589162] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Power_Control_Point",
[   58.589472] docker-loader[631]:         "value": 3304.21
[   58.589726] docker-loader[631]:     },
[   58.589964] docker-loader[631]:     {
[   58.590218] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/INV_Target_Power",
[   58.590512] docker-loader[631]:         "value": 3304.21
[   58.590753] docker-loader[631]:     },
[   58.590996] docker-loader[631]:     {
[   58.591247] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Battery_Target_Power",
[   58.591526] docker-loader[631]:         "value": 3304.21
[   58.591773] docker-loader[631]:     },
[   58.592054] docker-loader[631]:     {
[   58.592398] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Debug",
[   58.592743] docker-loader[631]:         "value": 33.04
[   58.593065] docker-loader[631]:     },
[   58.593327] docker-loader[631]:     {
[   58.593601] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Minor",
[   58.593895] docker-loader[631]:         "value": 33.04
[   58.594150] docker-loader[631]:     },
[   58.594395] docker-loader[631]:     {
[   58.594662] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Major",
[   58.594925] docker-loader[631]:         "value": 33.04
[   58.595173] docker-loader[631]:     },
[   58.595473] docker-loader[631]:     {
[   58.595750] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Division",
[   58.596054] docker-loader[631]:         "value": 33.04
[   58.596367] docker-loader[631]:     },
[   58.596635] docker-loader[631]:     {
[   58.596901] docker-loader[631]:         "metricPath": "sn123123123/pcsx_can_reg_map_4pcs/jf2_normal_and_additional_read/Temperature_Data/Temperature_4_in_the_rack",
[   58.597217] docker-loader[631]:         "value": 26.61
[   58.597496] docker-loader[631]:     }
[   58.597780] docker-loader[631]: ]
[   58.598084] docker-loader[631]: [07:15:26:546][D][EM] Processing telemetry payload with 12 metrics
[   58.938942] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD1] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.939443] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD2] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.939774] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD3] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.940110] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/PCS_CMD4] value=0.33, scaleFactor=1, periodMs=0, precision=0
[   58.940446] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Power_Control_Point] value=3304.21, scaleFactor=1, periodMs=0, precision=0
[   58.940771] docker-loader[631]: [07:15:26:546][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/INV_Target_Power] value=3304.21, scaleFactor=1, periodMs=0, precision=0
[   58.941115] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/Battery_Target_Power] value=3304.21, scaleFactor=1, periodMs=0, precision=0
[   58.941442] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Debug] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.941731] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Minor] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.941990] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Major] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.942251] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/pcs_all_read/1s_Monitoring_Data_1_PCS/BPU_FWVer_Division] value=33.04, scaleFactor=1, periodMs=0, precision=0
[   58.942567] docker-loader[631]: [07:15:26:547][D][EM] Stored metric [sn123123123/pcsx_can_reg_map_4pcs/jf2_normal_and_additional_read/Temperature_Data/Temperature_4_in_the_rack] value=26.61, scaleFactor=1, periodMs=0, precision=0
[   58.942882] docker-loader[631]: [07:15:26:547][D][EM] Successfully processed 12 metrics from payload
{noformat}

**Expected Result:**

Action란의 Log가 표시된다


### (연속 스텝)

**Action:**

* Azure Iot Hub의 Explorer를 이용하여 Common-Telemetry 값을 확인하여 유효한 값인지 확인 한다

**Expected Result:**

아래와 같이 표시 된다

!blob:https://my.desk.qcells.com/7d2711cb-746c-4f30-92ed-71941ead89ce#media-blob-url=true&id=331e321b-20d9-438d-b4c3-827678bc0d80&collection=&contextId=171968&mimeType=image%2Fpng&name=image-20251217-072140.png&size=45728&width=926&height=692&alt=image-20251217-072140.png|alt="image-20251217-072140.png"!


### (연속 스텝)

**Action:**

APP을 통해 확인하면 됨


