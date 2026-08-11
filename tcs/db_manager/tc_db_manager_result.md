# TC 실행 결과 보고서 — db_manager

**최초 실행:** 2026-08-11 11:26 ~ 12:27 KST (2회차)

**DUT:** 192.168.10.25 (qcells-emsplus, AC Gen2, aarch64)
**스크립트 md5:** `d37e2e862397f714b7228636910d3c2e`
**실행 환경:** SSH (COM7 시리얼 미인식으로 fallback)
**총 결과:** **PASS=22 / FAIL=4**
**Evidence:** `tcs/db_manager/tc_db_manager_evidence_full.log`

| TC | 결과 |
|---|---|
| TC01 (4단계) | PASS×4 |
| TC02-1 | PASS |
| TC02-2/3 | **FAIL** (sqlite3 CLI 부재로 사전조건 미충족, 개발자 확인 필요) |
| TC03 (3단계) | PASS×3 |
| TC04-1/2 | PASS/PASS |
| TC04-3 | **FAIL** (Debug 로그 관찰 타이밍, 개발자 확인 필요) |
| TC04-4 | PASS |
| TC06 | 미실행 (reboot 격리 phase — `--tc06-pre`/`--tc06-post`) |
| TC07-1/2 | PASS/PASS |
| TC07-3 | **FAIL** (시드 키가 db_manager 소관이 아닐 가능성, 개발자 확인 필요) |
| TC08 (3단계) | PASS×3 |
| TC09 (4단계) | PASS×4 |
| TC10-1/2 | PASS/PASS |

---

## 시험 과정에서 발견된 핵심 이슈 (개발자 확인 권장)

### 1. (스크립트 버그, 수정 완료) DUT에 `python3`가 없어 JSON 파싱 로직 전부 실패

1차 실행(PASS=14/FAIL=10)에서 `records` 배열 파싱, 원본 값 백업(`original_level`),
키 존재 확인(`timezone`) 등 `python3 -c "..."` 로 작성된 모든 판정 로직이 조용히
실패했다(`2>/dev/null`로 stderr가 가려져 있었음). 원인 확인을 위해 stderr를 노출해
재현한 결과:

```
$ sh /tmp/tc_db_manager_dbg.sh --tc03 (python 에러 노출)
/tmp/tc_db_manager_dbg.sh: line 207: python3: command not found
```

DUT는 busybox 기반 최소 이미지라 `python3` 바이너리 자체가 없다(`which python3` 0건).
`jq`(다른 앱 TC에서도 이미 사용 중, 존재 확인됨)로 전체 교체:
- `records` 배열/필드 존재 확인 → `jq -e '.payload.records | type=="array"'` 류로 단순화
- 실제 응답 구조를 실측한 결과 항상 `.payload.records` 고정 위치였음이 확인되어,
  원래 있던 "임의 depth 재귀 탐색" python 헬퍼(`PY_FIND_RECORDS`)도 불필요해져 제거
- 원본값 백업(`original_level`) → `jq -r '.payload.records[] | select(.key=="log_level_db") | .value'`

수정 후 재실행 PASS=14→22로 개선(TC03/TC04 원복 흐름 전체가 정상화됨).

### 2. (스크립트 버그, 수정 완료) DUT에 `file`/`sqlite3` CLI 없음

같은 이유로 TC09-3(`file` 커맨드로 SQLite 매직 확인)과 TC09-4(`sqlite3 .tables`)도
전부 "command not found"로 조용히 실패하고 있었다. `file` 대신 파일 헤더 첫 16바이트를
직접 읽어 `"SQLite format 3"` 매직 문자열을 확인하도록, `.tables` 대신 앱 자체
`select_all_records` IPC로 3개 필수 테이블 각각을 조회해 `result:true` 응답 여부로
대체 판정하도록 수정. 재실행 결과 TC09 전체 PASS.

### 3. TC02-2/3 FAIL — sqlite3 CLI 부재로 사전조건(unsynced 레코드 강제 생성) 미충족 (개발자 확인 필요)

TC02는 원래 `sqlite3 "$DB_PATH" "INSERT INTO configuration ..."` 로 앱을 거치지 않고
DB에 직접 unsynced 레코드 2건을 심어 "동기화 안 된 상태"를 재현하려 했으나, DUT에
`sqlite3` CLI가 없어 이 INSERT 자체가 매 실행 조용히 실패한다(1차/2차 실행 모두
`sqlite3: command not found`). 그 결과 원래부터 있던 1건만 감지되어 `>=2` 기준을
못 채운다. db_manager는 `insert_records`라는 IPC 서비스도 지원하므로
(`db_manager.cpp:270, SERVICE_INSERT_RECORDS`) 원칙적으로는 sqlite3 없이도 레코드
삽입이 가능하지만, `configuration` 테이블의 정확한 `DbRecord` 스키마(키 필요 여부 등)를
확인하지 못해 이번 회차에서는 대체 구현을 적용하지 않았다. **개발자가 (a) sqlite3를
테스트 이미지에 포함할지, (b) `insert_records` IPC로 사전조건을 재작성할지 결정 필요.**

**근거 — `evidence_full.log`**:
```
$ sqlite3 /edge/db/edge_storage.db INSERT INTO configuration (value) VALUES (...);
    /tmp/tc_db_manager.sh: line 58: sqlite3: command not found
[FAIL] TC02-2: unsynced 레코드 수 >= 2
    unsynced_count=1
```

### 4. TC04-3 FAIL — Debug 레벨 로그 관찰 타이밍 (개발자 확인 필요)

log_level_db를 Debug(0)로 바꾼 뒤 5초간 `journalctl -f`로 `[D][DB]` 태그 로그를
기다리는데, 이 5초 구간에 db_manager가 자발적으로 Debug 로그를 내는 활동이 없으면
당연히 못 잡는다(수동 트리거 없이 유휴 대기만 함). TC 설계상 Debug 로그를 유발하는
후속 요청(예: 아무 select_records 호출)을 대기 중에 같이 보내야 결정적으로 재현될
것으로 보임 — 개발자 검토 필요.

### 5. TC07-3 FAIL — "persistence_list_sync_flag" 시드 키가 db_manager 소관 아닐 가능성 (개발자 확인 필요)

TC07이 기대하는 시드 키 `persistence_list_sync_flag`를 소스에서 검색하니
`db_manager.cpp`에는 없고 `template_app.cpp`/`edge_runtime.cpp`에만 존재한다
(`edge_runtime.cpp:294`, `template_app.cpp:324,395,786,858`). 즉 이 키는 db_manager가
아니라 edge_runtime(또는 템플릿을 복제한 다른 앱)이 자기 초기화 시점에 심는 값으로
보인다 — TC07 스펙이 시드 키의 소유 앱을 잘못 가정했을 가능성이 높다. **개발자가
실제 시딩 주체를 확인해 TC07을 올바른 앱으로 옮기거나 키 이름을 수정해야 함.**

**근거 — `evidence_full.log`**:
```
select_all_records(persistent_state) 응답: {...,"records":[...19개 키...],"result":true,...}
```
(19개 키 목록에 `persistence_list_sync_flag` 없음, 위 목록 grep 결과)

---

## 요약

| TC | 기준 수 | PASS | FAIL |
|---|---|---|---|
| TC01 | 4 | 4 | 0 |
| TC02 | 3 | 1 | 2 |
| TC03 | 3 | 3 | 0 |
| TC04 | 4 | 3 | 1 |
| TC07 | 3 | 2 | 1 |
| TC08 | 3 | 3 | 0 |
| TC09 | 4 | 4 | 0 |
| TC10 | 2 | 2 | 0 |
| **합계** | **26** | **22** | **4** |

TC06(reboot)은 이번 회차 범위 밖(`--tc06-pre/-post` 별도 실행 필요).

## 다음 단계 (개발자 검토 필요)

- TC02-2/3: sqlite3 CLI 부재 — 테스트 이미지에 포함 또는 `insert_records` IPC 기반으로 사전조건 재작성
- TC04-3: Debug 로그 관찰 중 능동 트리거(예: select 요청) 추가 필요 여부
- TC07-3: `persistence_list_sync_flag` 시드 키의 실제 소유 앱 확인 (edge_runtime 소관으로 추정)
