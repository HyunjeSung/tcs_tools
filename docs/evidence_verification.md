# TC 판정 근거 대조 방법론 — journald / 리눅스 명령 / spec

TC 하나의 PASS/FAIL 판정이 신뢰할 수 있으려면, 서로 독립적인 세 가지 근거가 일치해야 한다.

1. **spec** (`tcs/<app>/tc_<app>.md`) — 무엇을 확인해야 PASS인지 정의
2. **리눅스 명령 실행 결과** (`tc_<app>.sh`가 `dump_cmd`로 남긴 raw output) — 스크립트가 실제로 무엇을 봤는지
3. **journald 로그** (`[SL]`/`[SM]` 태그) — 애플리케이션 내부에서 실제로 무슨 일이 있었는지

서술문("~확인됨", "~되었음")은 근거로 인정하지 않는다 — 세 가지 모두 명령어를 실행한 raw 출력이어야 검증력이 있다.

---

## 1. spec: PASS/FAIL Criteria 표

`tc_<app>.md`의 각 TC 섹션은 "PASS/FAIL Criteria" 표로 판정 기준을 정의한다. 표는 기준 ID, 설명,
타입, 기준값, 셸 검증(실제 실행할 명령/조건식)을 컬럼으로 갖는다. 이 표가 스크립트(`.sh`)의
`assert` 호출과 1:1로 대응해야 한다 — spec에 없는 판정을 스크립트가 임의로 추가하거나,
spec에 있는 기준을 스크립트가 빠뜨리면 안 된다.

예 (`tcs/system_log/tc_system_log.md` TC01):

```
| 기준 ID | 설명 | 타입 | 기준값 | 셸 검증 |
|---------|------|------|--------|---------|
```

## 2. 스크립트: `dump_cmd`로 raw output 캡처

`tc_<app>.sh`는 판정 직전에 실제 판정에 쓴 명령을 `dump_cmd`로 실행해 stdout/stderr +
`exit_code:N`을 그대로 남긴다 (`tcs/system_log/tc_system_log.sh:59-66`):

```bash
dump_cmd() {
    echo "  \$ $*"
    "$@" > /tmp/tc_dump_out_$$ 2>&1
    local rc=$?
    sed 's/^/    /' /tmp/tc_dump_out_$$
    rm -f /tmp/tc_dump_out_$$
    echo "    exit_code:${rc}"
    return "$rc"
}
```

사용 예 (`ls -la`로 파일 존재를 판정한 경우):

```bash
dump_cmd ls -la "$LATEST_XZ"
```

`assert` 함수는 판정 결과만 `[PASS]`/`[FAIL]` 라인으로 요약하고, 바로 위에 남은 `dump_cmd`
출력이 그 판정의 근거가 된다. **판정 로직만 돌리고 결과만 요약하는 것(assert만 호출하고
근거 없이 PASS 처리)은 금지** — 과거 TC02-2/TC06이 "수동확인" 문구로 조건 없이 PASS 처리하던
것을 실제 비교 로직 + `dump_cmd`로 교체하며 회귀(TC02의 `latest_xz` 오선정)를 실제로 잡아낸
사례가 있다.

## 3. journald: `[SL]`/`[SM]` 태그 인용

`system_log`/`system_manager` 애플리케이션은 자체 로그에 `[SL]`/`[SM]` 태그를 붙여 journald
(`docker-loader` 서비스 유닛)에 남긴다. 스크립트 자체 출력(`dump_cmd` 등)만으로는 "애플리케이션
내부에서 실제로 그렇게 동작했는지"까지는 보증하지 못하므로, journald 로그를 별도로 인용해
대조한다. 예:

```
[16:13:38][SL] [get_log_name] log_file_name: systemlog_20260709161334_20260709161338.log
[16:13:38][SM] Executing host command: xz -f /edge/log/toupload/system/systemlog_20260709161334_20260709161338.log
→ exit_code:0
```

## 4. 결과 문서에서의 3자 대조

`tc_<app>_result.md`는 TC별 섹션에서 위 세 근거를 나란히 인용한다 (spec의 기준 ID ↔ 스크립트의
`dump_cmd`/`assert` 출력 ↔ journald 발췌). 예시는 `tcs/system_log/tc_system_log_result.md`의
TC01 섹션 참고:

```markdown
| 기준 ID | 결과 |
|---------|------|
| TC01-1: 파일명 형식 ... | **PASS** |

**근거 (tc_run.out):**
```
[PASS] TC01-1: ...
```

**근거 (journald — ...):**
```
[16:13:38][SL] ...
```
```

evidence는 CLAUDE.md 규칙대로 단일 파일 `tc_<app>_evidence_full.log`의 `# FILE: <name>` 섹션을
그대로 인용하며, 디렉토리 분산은 하지 않는다.

## 5. tc-dashboard의 자동 대조 (`tools/tc_dashboard/server.py`)

대시보드에서 TC를 실행하면 위 대조를 사람이 손으로 만들지 않아도 되도록 자동화되어 있다.

- **journald 캡처**: run 실행 중 별도 SSH 세션으로 `journalctl -u docker-loader -f -o short-iso
  --no-pager`를 백그라운드로 띄워 전체 로그를 수집(`_start_journal_capture`/
  `_stop_journal_capture`, best-effort — 실패해도 TC 실행 자체는 막지 않음), `[SL]`/`[SM]`
  태그가 있는 라인만 걸러 run 디렉토리에 `sl_journal.log`로 저장한다(`SL_TAG_RE`).
- **TC별 블록 분리**: `tc_<app>.sh`가 각 TC 실행 전 찍는 `=== TCxx: ... ===` / `--- TCxx-n: ... ---`
  구분선을 기준으로 `output.log`를 TC별 원본 블록으로 나눈다(`TC_SECTION_RE`, `_split_log_by_tc`).
- **journald ↔ output.log 토큰 매칭**: 각 TC 블록 안에 등장하는 실제 파일명(타임스탬프 등 숫자를
  포함하는 토큰, 예: `systemlog_20260709161334_....log.xz`)을 `JOURNAL_TOKEN_RE`로 추출하고,
  그 토큰이 포함된 journald 라인만 최대 `JOURNAL_EXCERPT_MAX_LINES`(8)줄 추려 그 TC의 근거로
  붙인다(`_filter_journal_for_tc`). 여러 TC가 캡처 하나를 공유하는 `default` 일괄 실행에서도
  TC 무관 로그가 섞여 들어가지 않도록 하기 위함이다.
  - 토큰이 없는 TC(예: TC04처럼 output.log에 확장자만 언급하고 실제 파일명을 안 남기는 경우)는
    journald 근거가 빈 문자열로 처리된다 — 원본 `tc_system_log_result.md`에서도 TC04는 journald
    근거 섹션이 없는 것과 일치하는 동작이다. "근거 없음"을 임의로 지어내지 않는다.
- **PDF 리포트 생성**: `_generate_result_md`가 위 세 가지(assert 결과 표, `dump_cmd` 출력 블록,
  필터링된 journald 발췌)를 `tc_<app>_result.md`와 동일한 양식으로 합쳐 markdown을 만들고,
  `xhtml2pdf`로 PDF 변환해 대시보드 실행 이력에서 다운로드할 수 있게 한다
  (`/api/runs/{run_id}/result.pdf`).

## 원칙 요약

- 서술문(`echo "...확인됨"`)만으로 `assert ... "PASS"` 하지 않는다 — 반드시 `dump_cmd`로 raw
  명령 출력을 남긴 뒤 그 출력을 근거로 판정한다.
- spec의 PASS/FAIL Criteria ↔ 스크립트의 `assert` 호출 ↔ 결과 문서/evidence의 인용이 항상
  1:1로 대응해야 한다. 세 곳 중 하나만 바뀌고 나머지가 안 바뀌면 drift다.
- journald 근거는 실제로 토큰이 매칭될 때만 남긴다 — 매칭이 안 되면 "근거 없음"으로 두고
  일반화된 설명으로 대체하지 않는다.
