---
name: tc-bootstrap
description: 새 AC Gen2 EMS 애플리케이션의 TC 4파일 골격을 `tcs/` 아래에 즉시 생성하는 스킬. 인자로 app 이름 (예: device_log) 받음. 빈 명세/실행 스크립트 보일러플레이트/result/evidence 4파일을 한 번에 작성하여 tc-dev 가 spec 채우기에 들어갈 수 있는 상태로 만든다. "tc 골격", "tc 부트스트랩", "새 TC 만들어", "tc-bootstrap" 같은 키워드에서 활성화.
version: 1.0.0
---

# TC 4파일 골격 부트스트랩

`/tc-bootstrap <app_name>` 호출 시 `tcs/` 디렉토리 아래 다음 4파일을 한 번에 생성한다.

```
tcs/<app>/tc_<app>.md                 # 명세 골격 (frontmatter + TC01 placeholder)
tcs/<app>/tc_<app>.sh                 # 실행 스크립트 보일러플레이트 (send_and_wait + assert + main switch)
tcs/<app>/tc_<app>_result.md          # 결과 보고서 헤더만
tcs/<app>/tc_<app>_evidence_full.log  # 빈 파일
```

이미 4파일 중 하나라도 존재하면 **덮어쓰지 말고** 사용자에게 확인을 받는다.

---

## 사용

```
/tc-bootstrap <app_name>
```

예: `/tc-bootstrap device_log` → `tcs/device_log/tc_device_log.{md,sh,_result.md,_evidence_full.log}` 4 파일 생성.

생성 후:
1. 개발자: `tcs/<app>/tc_<app>.md` 의 spec 본문 채우기 (TC 별 4단 구조)
2. `/tc-dev <app>` 호출하여 AI 가 명세 기반으로 `.sh` 채우기
3. `/tc-run <app>` 으로 실행

---

## 골격 템플릿

### 1. `tcs/<app>/tc_<app>.md`

```markdown
---
spec_id: <app>
suite: application
grade: A
phase: Phase 1
test_file: tcs/<app>/tc_<app>.sh
requires_labgrid: false
requires_hardware: []
validation_level: full
---

# TC-APP-<APP_UPPER>: <app> — <한 줄 설명>

## 목적 (Objective)

<app> 애플리케이션의 ... (개발자가 작성)

## 공통 전제 조건 (Common Preconditions)

- DUT 전원 ON, 네트워크 연결, SSH 또는 시리얼 콘솔(config.env의 SERIAL_COM_PORT, 115200 8N1) 접속 가능
- DUT에서 `<app>` 프로세스 실행 중 (`pgrep -f <app>`)
- MQTT 브로커 동작 중 (`localhost:1883`)
- `mosquitto_pub` / `mosquitto_sub` 설치됨

---

## TC01 — <한 줄 요약>

### 목적
<TODO>

### 사전 조건
- 공통 전제 조건 충족
- <TODO>

### 절차
1. <TODO>

### 기대 결과
| 항목 | 기준 |
|------|------|
| <TODO> | <TODO> |

### PASS/FAIL Criteria

| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
| TC01-1 | <TODO> | boolean | true | `<TODO>` |

---

## 환경 변수 (Environment Variables)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MQTT_HOST` | `localhost` | MQTT 브로커 주소 |
| `SOURCE` | `tc_runner` | MQTT 발신 source ID |
| `TARGET` | `<app>` | MQTT 수신 대상 앱 ID |

---

## 관련 문서

- `tc_<app>_result.md` — 본 TC 실행 결과 보고서
- `tc_<app>_evidence_full.log` — 결과의 근거가 되는 통합 로그
```

### 2. `tcs/<app>/tc_<app>.sh`

```bash
#!/bin/bash
# TC: <app>
# MQTT topic: emsp/{target}/{source}/req/{service}
#             emsp/{source}/{target}/res/{service}

MQTT_HOST="localhost"
SOURCE="tc_runner"
TARGET="<app>"
PASS=0
FAIL=0

# subscribe 먼저 시작 후 publish → 응답 누락 방지
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
    sleep 0.5
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

# ============================================================
# TC01: <한 줄 요약>
# ============================================================
tc01_placeholder() {
    echo "=== TC01: <TODO> ==="
    # TODO: 검증 로직
    assert "TC01-1: <TODO>" "PASS"
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " <app> TC"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01)
        tc01_placeholder
        ;;
    *)
        tc01_placeholder
        # TODO: 추가 TC 호출
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
```

### 3. `tcs/<app>/tc_<app>_result.md`

```markdown
# TC 실행 결과 보고서 — <app>

**최초 실행:** YYYY-MM-DD HH:MM KST (예정)

**DUT:** config.env의 DUT_HOST (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** (실행 후 채움)
**실행 환경:** SSH / 시리얼(config.env의 SERIAL_COM_PORT)
**총 결과:** 미실행
**Evidence:** `tcs/<app>/tc_<app>_evidence_full.log`

| TC | 결과 (PASS/총) |
|---|---|
| TC01-1 | 미실행 |

---

## TC01 — <한 줄 요약>

| 기준 ID | 결과 |
|---|---|
| TC01-1: <TODO> | 미실행 |

**TC01-1 근거 — `evidence_full.log` SECTION X (...)**:
(실행 후 raw 명령 결과 인용)

---

## 요약

| TC | 기준 수 | PASS | FAIL |
|---|---|---|---|
| TC01 | 1 | 0 | 0 |
| **합계** | **1** | **0** | **0** |
```

### 4. `tcs/<app>/tc_<app>_evidence_full.log`

```
############################################################
# tc_<app> 통합 Evidence
# 생성: (실행 후 채움)
# DUT: config.env의 DUT_HOST (qcells-emsplus)
# 스크립트 md5: (실행 후 채움)
# 결과: 미실행
############################################################
```

---

## 실행 단계 (bash 의사 코드)

```bash
APP="$1"
[ -z "$APP" ] && { echo "Usage: /tc-bootstrap <app_name>"; exit 1; }

TCDIR=tcs/${APP}   # 레포 루트 기준 상대경로 (레포 루트에서 실행)
mkdir -p "$TCDIR"

for ext in ".md" ".sh" "_result.md" "_evidence_full.log"; do
    target="${TCDIR}/tc_${APP}${ext}"
    if [ -e "$target" ]; then
        echo "[WARN] $target 이미 존재 — 사용자 확인 필요 (덮어쓰지 않음)"
    fi
done

# 위의 4 템플릿을 각각 Write 도구로 작성
# .sh 는 chmod +x
```

---

## 사후 작업

골격 생성 후:

1. 개발자가 `tc_<app>.md` 의 spec 채우기 (TC01~ 본문)
2. `/tc-dev <app>` 호출 — AI 가 명세 기반으로 `.sh` 의 `tc01_placeholder` 같은 함수 실제 구현
3. `/tc-run <app>` 호출 — DUT 에서 실행 + evidence 수집

전체 절차는 [tc-harness SKILL](../tc-harness/SKILL.md) 참조.
