# system_log TC ↔ EMS 빌드 호환표

TC마다 검증 대상 코드가 EMS 빌드 계열에 따라 있거나 없고, TC 판정 방식도 계속 바뀐다.
"이 TC를 이 EMS 빌드에서 돌리면 의미 있는 결과가 나오는가"를 TC별로 기록한다.
**새 EMS 빌드에서 돌리거나 TC를 고치면 이 표를 같이 갱신한다**(근거 run ID 필수).

- tcs_tools 버전: 레포 루트 `VERSION`의 `TCS_VERSION` — 대시보드 실행 이력 "버전" 컬럼에 run마다 기록됨
- EMS 빌드: DUT `/etc/os-release`의 `BUILD_VERSION` — 같은 컬럼에 run 시작 시 자동 기록됨
- 근거 run: `tools/tc_dashboard/runs/<run_id>/` (output.log / sl_journal.log)

## EMS 빌드 계열

| 계열 | 빌드 | 특징 (system_log) | 비고 |
|------|------|-------------------|------|
| R09 | R090127 (BUILD_DATE 2026/10/02) | `xz -f`(기본 레벨) + 압축 180초 공유 타임아웃, `cleanup_if_low_disk_space`/`delete_oldest_files_until_safe` 있음(R090125 백포트 `309e4e2`), 디스크 예산 circuit breaker 없음 | 2026-10-06 기준 기본 DUT(192.168.10.25) |
| main | R090128 이후(빌드 번호 미정, DUT 미탑재) | `xz -f -0` + 압축 전용 300초(`SYSTEM_LOG_XZ_CMD_TIMEOUT`), 디스크 예산 circuit breaker(`task_check_disk_budget`/`cleanup_log_disk_budget`), `cleanup_if_low_disk_space` 제거 | 로컬 소스(application repo `EWP-2721`) 기준. R09 다음 빌드에 포함되는지는 미확인 |

## 판정 기호

| 기호 | 의미 |
|------|------|
| ✅ | 해당 빌드에서 PASS 확인 (근거 run 있음) |
| ❌ | 해당 빌드에 검증 대상 기능이 없음 → FAIL이 정상(빌드 한계) |
| ⏭ | 해당 빌드에서 TC가 스스로 SKIP (빌드 가드) |
| ⚠️ | 돌릴 수는 있으나 결과가 비결정적이거나 TC 수정 후 미검증 |
| — | 아직 그 빌드에서 돌려보지 않음 |

## 호환표 (tcs_tools v1.1.1 기준)

| TC | 검증 대상 | R09 (R090127) | main (R090128+) | 근거 run (R090127) | 비고 |
|----|-----------|---------------|-----------------|--------------------|------|
| TC01 | 파일명 규칙 | ✅ | — | 20261006_143254 | 파일명은 journal `Created meta file`로 확정(업로드로 즉시 소멸 대응) |
| TC02 | 24시간 타이머 | ✅ | — | 20261006_143254 | rotate 뒤 로그로 판정, TC14 뒤 실행 + 미래 시각 journal 정리 |
| TC03 | On-demand export | ✅ | — | 20261006_143254 | |
| TC04 | 대용량(100/200MB) 압축 제한시간 내 성공 | ❌ | — (대상) | 20261006_143254 | R09는 기본 레벨 xz가 180초 초과 → `Failed to compress`. main의 xz -0+300초 검증용 |
| TC05 | xz 압축/무결성 | ✅ | — | 20261006_143254 | 생성 순간 스냅샷 + meta 로그로 판정 |
| TC06 | journal rotate/vacuum 사용량 | ✅ | — | 20261006_143254 | |
| TC07 | 30일 retention 삭제 | ✅ | — | 20261006_143254 | tcs 16a1b35(2026-08-03) 버전은 트리거 경로가 달라 FAIL(20261006_193117) |
| TC08 | 업로드 대상(.xz/.meta) 생성 | ✅ | — | 20261006_143254 | SETUP meta 로그도 근거로 인정 |
| TC09 | factory reset 시 로그 삭제 | ✅ | — | 20261006_143254 | |
| TC10 | 재부팅 shutdown+boot 로그 병합 | ✅ | — | 20261006_201409 | boot_id 재부팅 확인 + `Merge done`. 선택 실행에서 pre→재부팅→post 자동 체이닝 |
| TC11 | nmon 업로드 | ✅ | — | 20261006_143254 | |
| TC12 | nmon 30일 retention | ✅ | — | 20261006_143254 | `.nmon.meta` 잔존은 허용(TC12-3 비게이트) |
| TC13 | nmon 부재 no-op | ✅ | — | 20261006_143254 | |
| TC14 | 동일 시작시각 다중 파일 병합 + 재귀/자기복사 없음 | ✅ | — | 20261006_201409 | TC14-5(재귀 증가 검출) 2026-10-06 추가 |
| TC15 | rotate_sync 압축 실패 시 raw 보존 + vacuum | ✅ | — | 20261006_201409 | 8/8 PASS. keep-full 재충전(vacuum 감지 직후 67,608KB 재충전) → xz ENOSPC(`exit_code 1`, `Failed to compress log!! Keeping raw .log, removing partial .xz.`). keep-full 이전 방식은 R090127에서 비결정(4회 중 2회 xz 성공) |
| TC16 | boot_log 압축 실패 시 raw 보존 + vacuum | ✅ | — | 20261006_201409 | 8/8 PASS. vacuum 감지 직후 60,364KB 재충전 → `[task_capture_boot_log] Failed to compress log, keeping raw .log` |
| TC17 | MessageContext tid 미검증(결함 재현) | — | — | — | 결함 재현용(FAIL=결함 존재). 회귀 세트 미포함 |
| TC18 | 저장공간 부족(<10%) cleanup | ✅ | ⏭ | 20261006_201409 | R09 전용. main은 함수 제거로 TC18-0이 SKIP. TC18-3은 코드 회복 로그 기준 |
| TC19 | 디스크 예산 watermark 근거 수집 | ✅ | — | 20261006_143254 | informational |
| TC20 | 디스크 예산 트립/재개 | ❌ | — (대상) | 20261006_125124 | R09에 기능 없음(journal `budget` 로그 0건) |
| TC21 | 트립 중 반복 요청 WARN 선형성 | ❌ | — (대상) | 20261006_125124 | 동일 |
| TC22 | 디스크 예산 능동 정리 | ❌ | — (대상) | 20261006_125124 | 동일 |

## 변경 이력

| 날짜 | tcs_tools | EMS | 내용 |
|------|-----------|-----|------|
| 2026-10-06 | v1.1.1 | R090127 | 최초 작성. R090127 전 TC 실측 반영, main 계열은 DUT 미탑재로 전부 미검증 |
| 2026-10-06 | v1.1.1 | — | `VERSION`의 `EMS_TARGET_MIN`과 대시보드 ⚠ 불일치 표시 제거 — 호환 판단은 이 표로 일원화. TC15/16 keep-full 재충전 방식 적용(⚠️ 미검증) |
| 2026-10-06 | v1.1.1 | R090127 | 20261006_201409(TC10/14/15/16/18) 29/29 PASS — TC15/16 keep-full 방식 검증 완료(⚠️→✅), TC10/14/18 근거 run 갱신 |
