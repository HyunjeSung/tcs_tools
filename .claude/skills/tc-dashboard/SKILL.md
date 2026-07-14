---
name: tc-dashboard
description: tools/tc_dashboard/ (system_log TC 웹 대시보드, FastAPI + 순수 JS) 를 개발/수정할 때 참고하는 레퍼런스 스킬. 서버 재시작 전 실행 중 run 확인 규칙, 시리얼 채널 라이브 로그 tail 아키텍처, WSL/Windows interop 함정(Python 3.8 asyncio.to_thread 부재, SerialPort 기본 인코딩, DrvFs 공유 위반)을 정리해둠. "tc_dashboard", "대시보드 서버", "serial_run.ps1", "시리얼 라이브 로그" 같은 키워드에서 활성화.
version: 1.0.0
---

# tc_dashboard 개발 레퍼런스

`tools/tc_dashboard/` — system_log TC를 브라우저에서 실행/모니터링하는 FastAPI 백엔드(`server.py`) + 정적 JS 프론트(`static/index.html`). SSH 채널과 시리얼(COM) 채널 둘 다 지원.

## 실행 / 재시작

```bash
cd tools/tc_dashboard && ./run.sh   # .venv/bin/python3 (3.8.10) 우선 사용
```

**서버 재시작 전 반드시 실행 중인 run이 없는지 확인**:
```bash
curl -s http://localhost:8090/api/runs?page=1 | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['runs'][0]['status'])"
```
`running`이면 재시작하지 말 것 — `pkill`로 Python 서버를 죽여도 그게 띄운 `powershell.exe`/시리얼 세션이 곧바로 안 끝나거나 COM 포트가 잠깐 안 풀려서 다음 실행이 "Access denied"로 실패할 수 있다. 코드 수정 후 검증하려고 TC를 직접 돌릴 때도 마찬가지로 먼저 idle인지 확인.

## 시리얼 채널 아키텍처 (`_run_serial` / `serial_run.ps1`)

SSH 채널은 원격 stdout이 그대로 `output.log`로 흐르지만, 시리얼은 그렇지 않다 — 이 비대칭이 오늘 세션 대부분의 버그 근원이었다.

- **결과 판정의 진실 소스는 base64 dump**: TC 스크립트는 `$REMOTE_OUT` 파일로 리다이렉트되어 실행되고, 끝나면 `base64 -w 76 $REMOTE_OUT`을 시리얼로 전송 → PowerShell이 디코딩해 `Out-Utf8`로 실제 stdout에 씀. 노이즈 있는 raw 시리얼 캡처와 무관하게 항상 깨끗함 — **판정 로직은 이 경로만 신뢰해야 한다.**
- **라이브 미리보기는 tee + 별도 tail**: `serial_run.ps1`의 원격 명령이 `sh $REMOTE_SCRIPT $Flag 2>&1 | tee $REMOTE_OUT`라서 TC 출력이 시리얼 콘솔에도 동시에 흐른다. 이걸 `server.py`의 `_tail_serial_log()`가 Windows 쪽 `$LogFile`(`SERIAL_LIVE_LOG_WIN` = `WIN_TEMP_LOG_PATH` 디렉토리 + `tc_dashboard_serial.log`, `config.env` 기반)을 1초 간격 `/mnt/c` 브릿지로 tail해 `output.log`에 append. **쓰기는 항상 Windows 로컬 디스크로만 가게 유지할 것** — tail 경로를 WSL 쪽으로 바꾸면 `Pump()`의 80ms 주기마다 9P 왕복이 붙어 시리얼 타이밍이 깨진다.
- **같은 내용이 두 번 나오는 게 정상**: tee로 살린 라이브 스트림과 최종 base64 디코딩본이 겹쳐서 같은 `[PASS]/[FAIL] TCxx-x` 줄이 두 번 찍힐 수 있다. `_parse_results()`가 case_id로 dedup(나중 것 = 항상 깨끗한 최종본을 채택)하므로 카운트는 안전하지만, 새 파서 로직을 만질 땐 이 dedup을 깨지 말 것.
- **`$LogFile`은 run 간 공유·누적 파일**(append-only, 안 지워짐) — `_tail_serial_log`는 반드시 run 시작 시점의 파일 크기를 `start_offset`으로 기록하고 그 이후분만 읽어야 이전 run 내용이 안 섞인다.
- **`_filter_serial_noise()`가 걸러내는 것들**: `docker-loader[` 저널 스팸(다른 서브시스템이 콘솔에 계속 끼어듦), `P> ` 프롬프트/`^C` 에코, 대시보드 프로토콜 마커(`M_RM_DONE`/`M_DECODE_DONE`/`M_DASH_RUN_END`, `M_DUMPBEG`~`M_DUMPEND` 사이 base64 블록), 그리고 `_looks_corrupted()`로 걸러내는 진짜 시리얼 라인 노이즈(개행 없이 수천자, `errors="replace"`가 채운 U+FFFD 비율 높음 — TC04처럼 대량 데이터 주입 중 회선이 불안정해지면 생김). **마커/노이즈 판별은 프롬프트 접두(`P> `)를 벗긴 뒤에 해야 한다** — `P> M_DUMPBEG`처럼 마커 앞에 프롬프트가 그대로 붙어 나오는 게 흔해서 순서를 틀리면 필터가 못 잡는다.
- **청크 경계 처리**: 1초마다 읽다 보니 한 줄이 두 읽기에 걸쳐 잘릴 수 있다 — `_tail_serial_log`가 `pending` 버퍼로 마지막 미완성 줄을 다음 주기로 넘긴 뒤에 필터링한다.

## WSL/Windows interop 함정

1. **`asyncio.to_thread`는 Python 3.9+ 전용** — 이 venv는 3.8.10(`hasattr(asyncio, 'to_thread')` → `False`). 3.8에서 이걸 부르면 `AttributeError`가 나는데, `except Exception:`으로 감싸놓으면 매 루프 조용히 삼켜져서 **기능이 통째로 죽어도 에러 로그가 하나도 안 남는다.** 반드시 `loop.run_in_executor(None, fn)`을 쓰고, 새 async 헬퍼를 추가하면 실제로 파일에 바이트가 써지는지 직접 확인할 것 (조용히 실패하는 게 이 클래스 버그의 특징).
2. **`SerialPort` 기본 Encoding은 ASCII** — `$port.Encoding = [System.Text.Encoding]::UTF8`을 명시 안 하면 `ReadExisting()`이 한글 멀티바이트를 `?`로 뭉갠다.
3. **WSL(`/mnt/c`)에서 파일을 읽는 동안 Windows 프로세스가 같은 파일에 쓰면 간헐적 공유 위반**("다른 프로세스에서 사용 중") 이 난다. `serial_run.ps1`의 `Write-LogSafe` 헬퍼가 `Add-Content` 실패 시 짧게(15ms) 최대 3회 재시도 후 조용히 포기하도록 되어 있다 — 완전히 없애진 못하고 완화만 함. `$ErrorActionPreference = 'Continue'`라서 이게 실패해도 스크립트 자체나 판정 로직(`$global:fullCapture` 기반)엔 영향 없다.
4. **Windows 경로 변환**: `_win_path()`(WSL→Windows, `wslpath -w`)와 `_wsl_path()`(Windows→WSL, `wslpath -u`) 둘 다 존재. 새로 Windows 쪽 파일 경로가 필요하면 `config.env`의 `WIN_TEMP_LOG_PATH`/`WIN_KEY_PATH` 패턴처럼 하드코딩 대신 config에서 파생시킬 것.

## 기타 알아둘 것

- `MAX_RUNS = 50` — `_prune_old_runs()`가 오래된 `runs/<id>/` 디렉토리를 지우고, `_rebuild_latest_status()`가 **남은 run들만 재생**해 `latest_status.json`을 재구성한다(누적만 하는 구식 `_update_latest_status`와 달리 삭제된 run을 가리키는 stale 항목이 안 남음). 서버 시작 시 + 매 run 종료 시(`finally`) 둘 다 호출됨.
- `run_tc()`의 상태 판정: `exit_code == 0`이어도 파싱된 케이스가 0개면 `"pass"`가 아니라 `"error"`로 처리해야 한다(시리얼 base64 dump가 노이즈로 깨졌는데 프로세스 자체는 정상 종료한 경우를 위함).
- `/api/runs`는 `page`/`page_size` 페이지네이션 지원. `dutDot`(LED)은 TC PASS/FAIL이 아니라 **연결 성공 여부**(`exit_code !== null`)만 나타내며, 라이브 폴링 완료 시점과 `showRunLog()`로 과거 run을 볼 때(`applyConnectionState`) 갱신된다. ping은 ICMP라 lockout 위험 없어 20초 간격 반복 폴링 중(SSH는 3회 실패 시 lockout 위험 있어 헬스체크에 절대 안 씀).
- 채널 선택(`selectedChannel`)은 세션 내에서만 유지되고 페이지 새로고침하면 항상 `ssh`로 초기화됨(localStorage 미사용) — 시리얼로 돌리려면 매번 배지 클릭 필요.
