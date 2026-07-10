---
name: tc-dev
description: AC Gen2 EMS 어플리케이션(system_log, device_log, blob_upload_director, cloud_upload_manager 등)의 TC 명세/스크립트/결과/evidence를 4파일 패턴으로 작성하는 스킬. 새 TC 개발 시작 또는 기존 TC 명세 정비 시 사용. "TC 만들어", "TC 작성", "TC 명세", "사전 조건 작성", "PASS/FAIL Criteria" 같은 키워드에서 활성화.
version: 1.0.0
---

# TC 개발 4파일 패턴

`tcs/` 디렉토리 아래 다음 4개 파일을 한 세트로 작성/유지한다.

| 파일 | 역할 |
|---|---|
| `tcs/<name>/tc_<name>.md` | TC 명세 (목적 + 사전 조건 + 절차 + 기대 결과 + PASS/FAIL Criteria) |
| `tcs/<name>/tc_<name>.sh` | TC 실행 스크립트 (bash + busybox 호환) |
| `tcs/<name>/tc_<name>_result.md` | TC 실행 결과 보고서 |
| `tcs/<name>/tc_<name>_evidence_full.log` | 결과의 근거가 되는 모든 로그를 통합한 단일 파일 |

---

## 1. `tcs/<name>/tc_<name>.md` (TC 명세)

### Frontmatter
```yaml
---
spec_id: <name>
suite: application
grade: A | B | C
phase: Phase 1
test_file: tcs/<name>/tc_<name>.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---
```

### 구조 (모든 TC가 따라야 할 4단 구조)

```markdown
## TCxx — <한 줄 요약>

### 목적
<무엇을 검증하는지 한 문단>

### 사전 조건
- 공통 전제 조건 충족 (DUT 전원 ON, 네트워크/시리얼 접속 가능, 대상 프로세스 실행 중)
- 이 TC 만의 추가 조건 (권한, 환경변수, 디스크 여유, 의존 TC 등)
- 환경변수: (필요 시) NAME=값
- 의존: <사전에 실행되어야 할 TC, 또는 디바이스 상태>

### 절차
1. 단계 1
2. 단계 2
...

### 기대 결과
| 항목 | 기준 |
|---|---|
| ... | ... |

### PASS/FAIL Criteria
| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---|---|---|---|---|
| TCxx-1 | ... | boolean / manual / exit code | ... | `[ ... ]` |
```

### 명세 작성 규칙

- **"근거 코드" 섹션은 두지 않는다.** (코드는 evidence 로그로 검증, 명세에서 cpp 코드 인용 X)
- **사전 조건을 잘 작성한다** — TC 의 전제와 실행 환경을 분명히. 사전 조건이 부실하면 실패 원인을 환경 문제로 잘못 돌리게 된다.
- **TC 순서 의존성에 주의** — 예: `system_log` TC02 (24h timer) 는 SETUP `get_log_data` 이전에 실행해야 발화. 의존성이 있는 TC 는 사전 조건에 명시.
- **manual 타입의 기준은 출력에 충분한 정보를 남긴다** (수동 판정용).

---

## 2. `tcs/<name>/tc_<name>.sh` (TC 실행 스크립트)

### 헤드 (공통 변수 + 헬퍼)

```bash
#!/bin/bash
MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="<application_id>"
STAGING_DIR="/edge/log/<name>"
TOUPLOAD_DIR="/edge/log/toupload/<name>"
PASS=0
FAIL=0

send_and_wait() {
    local service="$1"
    local payload="$2"
    [ -z "$payload" ] && payload="{}"
    local timeout="${3:-30}"
    local tid="tc-$(date +%s)"
    local full_payload
    full_payload=$(printf '{"tid":"%s","payload":%s}' "$tid" "$payload")
    local resp_topic="emsp/${SOURCE}/${TARGET}/res/${service}"
    local req_topic="emsp/${TARGET}/${SOURCE}/req/${service}"
    local resp_file="/tmp/mqtt_resp_$$_${service}"
    mosquitto_sub -h "$MQTT_HOST" -t "$resp_topic" -W "$timeout" -C 1 > "$resp_file" 2>/dev/null &
    local sub_pid=$!
    sleep 0.5     # mosquitto_sub 연결 대기 — 0.2 는 부족, 0.5 권장
    mosquitto_pub -h "$MQTT_HOST" -t "$req_topic" -m "$full_payload"
    wait "$sub_pid"
    cat "$resp_file" 2>/dev/null
    rm -f "$resp_file"
}

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "PASS" ]; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
}
```

### 스크립트 작성 규칙

- **busybox 호환** — bash array 사용 자제, `for i in $list` + `awk '{print $n}'` 패턴 사용
- **출력 marker 는 라인 시작에 위치** — `echo M_DONE` 형태. 시리얼 helper 의 `(?m)^M_` 매칭과 호환.
- **`${2:-{}}` 같은 brace 안에 `{` 두지 말 것** — bash parameter expansion 이 `}` 를 종료 brace 로 인식해 깨진다. `local v="$2"; [ -z "$v" ] && v="{}"` 패턴 사용.
- **각 TC 함수는 자기 사전 조건을 가능한 함수 안에서 명시적으로 출력** — 결과 보고서에서 그대로 인용 가능.
- **TC 순서가 결과에 영향 있으면 main case 에 명시적 순서로 배치** (예: TC02 가장 먼저).
- **SETUP / cleanup 패턴** — SETUP 은 별도 함수 + 의존 TC 만 호출 후 진행. cleanup 은 각 TC 함수 끝에서 자기가 만든 임시 파일 제거.

### Main case 패턴

```bash
case "${1}" in
    --pre)   tc_pre  ;;     # reboot 발생하는 TC pre 단계
    --post)  tc_post ;;     # reboot 후 검증 단계
    *)
        # 의존성/시간 민감 TC 를 먼저
        verify_prereq        # 예: timer_loop 시작 로그 확인
        tc02_timer_running   # 시간 민감 TC

        # SETUP + 나머지 TC
        setup_rotate
        tc01_filename_format
        tc03_on_demand_export
        ...
        tc09_factory_reset

        echo "============================================"
        echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
        echo "============================================"
        ;;
esac
```

---

## 3. `tcs/<name>/tc_<name>_result.md` (결과 보고서)

### 헤더

```markdown
# TC 실행 결과 보고서 — <name>

**실행일시:** YYYY-MM-DD HH:MM ~ HH:MM KST
**DUT:** config.env의 DUT_HOST
**접속:** 시리얼 config.env의 SERIAL_COM_PORT (115200 8N1)
**스크립트:** `tcs/<name>/tc_<name>.sh` (md5: `<hash>`)
**총 결과:** **<P> PASS / <F> FAIL**
**Evidence:** `tcs/<name>/tc_<name>_evidence_full.log` (단일 통합)
```

### 각 TC 섹션

```markdown
## TCxx — <한 줄>

| 기준 ID | 결과 |
|---|---|
| TCxx-1: <설명> | **PASS** / **FAIL** |

**근거 — `evidence_full.log` (FILE: run<n>/<file>.log)**
\```
<evidence 안에 실제로 존재하는 로그 라인만 인용>
\```
```

### 인용 규칙

- **evidence_full.log 에 실제로 있는 라인만 인용한다.** 추측이나 일반화 X.
- 명령어 결과(`ls -la`, `xz --test`, `md5sum` 등)는 그대로 캡처해서 코드 블록으로.
- FAIL 케이스는 **결정적 증거**를 비교 가능한 형태로 (예: "같은 시간대 device_log 는 발화, system_log 는 0 라인").

---

## 4. `tcs/<name>/tc_<name>_evidence_full.log` (통합 evidence)

단일 텍스트 파일에 모든 근거 로그를 모은다. 디렉토리 분산 금지.

### 구조

```
############################################################
# <name> TC 통합 Evidence
# 생성: YYYY-MM-DD HH:MM:SS
# DUT: config.env의 DUT_HOST
# 스크립트 md5: <hash>
# 결과: PASS=<P> / FAIL=<F>
############################################################


############################################################
# FILE: run<n>/tc_run_out.log  (<lines> lines, <bytes> bytes)
############################################################
<TC 스크립트 표준출력>


############################################################
# FILE: run<n>/tc_sl_filt.log  (<lines> lines, <bytes> bytes)
############################################################
<application 의 [APP_TAG] 필터링된 docker-loader journal>


############################################################
# FILE: run<n>/tc_mqtt_filt.log
############################################################
<application 관련 MQTT req/res 필터링>


############################################################
# FILE: run<n>/cmd_outputs.log
############################################################
<ls -la / xz --test / md5sum / journalctl --disk-usage / df -h 등 명령어 결과>


############################################################
# FILE: <reboot 시나리오 시리얼 콘솔 raw, 있는 경우>
############################################################
```

### evidence 작성 규칙

- **검색은 `grep -aA20 'FILE: <section>'` 패턴**으로 한 섹션만 펼치도록 헤더 표준화
- **base64 dump 시 시리얼 buffer overrun 으로 corrupt 가능** — 가능하면 디바이스에서 `fgrep` 으로 [APP_TAG]/관련 토픽만 추출한 작은 파일을 dump (큰 파일 chunked dump 는 위험)
- **bytes/lines 헤더에 적어두면** 추후 검증/회수 비교 시 유용

---

## 작업 순서 (체크리스트)

새 TC 작성 시:

1. [ ] `tcs/<name>/tc_<name>.md` 4단 구조로 명세 작성 (사전 조건 꼼꼼히)
2. [ ] `tcs/<name>/tc_<name>.sh` 작성 (busybox 호환, marker 규칙, send_and_wait 헬퍼)
3. [ ] 시리얼로 실행: `/tc-run <name>` (별도 스킬)
4. [ ] `tcs/<name>/tc_<name>_evidence_full.log` 자동 생성/갱신
5. [ ] `tcs/<name>/tc_<name>_result.md` 작성 — evidence 에 실제 있는 로그만 인용
6. [ ] FAIL 케이스는 결정적 증거 + 후속 조치 제안 섹션 추가

명세 정비 시:

1. [ ] 각 TC 의 사전 조건이 충분한지 점검 (의존성, 환경변수, 디스크 등)
2. [ ] 절차/기대 결과/PASS-FAIL Criteria 가 정렬되어 있는지
3. [ ] TC 간 순서 의존성이 있으면 사전 조건에 명시
4. [ ] result.md 의 인용이 evidence_full.log 와 일치하는지 검증
