#!/bin/bash
# TC: web_interface
# 다른 AC Gen2 app(C++ BaseApp, MQTT IPC)과 달리 web_interface는 Node.js/Express
# HTTPS 웹 서버(기본 9112 포트)다. 검증은 MQTT req/res가 아니라 curl/openssl로
# DUT의 HTTPS 엔드포인트에 직접 요청을 보내 상태코드/헤더/TLS 핸드셰이크 결과로
# 판정한다 (tc_web_interface.md 참고).

HOST="${HOST:-192.168.10.25}"
PORT="${PORT:-9112}"
PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "PASS" ]; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc"
        FAIL=$((FAIL + 1))
        [ -n "$3" ] && echo "  [REASON] $3"
    fi
}

# 판정에 사용한 명령어를 그대로 실행하고 raw 출력을 evidence로 남긴다.
# (서술문("~확인됨")만으로는 근거로 인정하지 않는다 — 반드시 명령어 실행 결과를 남길 것)
# 실행 결과는 $OUTPUT 전역 변수에도 담아 assert 판정 로직에서 재사용한다.
dump_cmd() {
    echo "  \$ $*"
    OUTPUT="$("$@" 2>&1)"
    local rc=$?
    printf '%s\n' "$OUTPUT" | sed 's/^/    /'
    echo "    exit_code:${rc}"
    return "$rc"
}

# ============================================================
# TC01: API 문서 제공 (Swagger/OpenAPI 문서 서버)
# ============================================================
tc01_api_docs() {
    echo "=== TC01: API 문서 제공 (Swagger/OpenAPI 문서 서버) ==="

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/platform/docs.json"
    local code="$OUTPUT"
    if [ "$code" = "200" ]; then
        assert "TC01-1: docs.json 200 응답" "PASS"
    else
        assert "TC01-1: docs.json 200 응답" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk "https://$HOST:$PORT/platform/docs.json"
    local docs_json="$OUTPUT"
    # DUT에 python3가 없음(실측 확인, db_manager TC 조사 참고) — jq로 대체.
    if printf '%s' "$docs_json" | jq -e '(.openapi | startswith("3.")) and (.paths | length > 0)' >/dev/null 2>&1; then
        assert "TC01-2: docs.json이 유효한 OpenAPI 문서" "PASS"
    else
        assert "TC01-2: docs.json이 유효한 OpenAPI 문서" "FAIL"
    fi

    # -L 없이는 Swagger UI의 흔한 trailing-slash 리다이렉트(301)를 그대로 오판할 수 있어
    # 리다이렉트를 따라간 최종 코드로 판정한다.
    dump_cmd curl -skL -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/platform/docs"
    code="$OUTPUT"
    if [ "$code" = "200" ]; then
        assert "TC01-3: Swagger UI HTML 200 응답" "PASS"
    else
        assert "TC01-3: Swagger UI HTML 200 응답" "FAIL" "http_code=$code"
    fi

    local match_count
    match_count=$(printf '%s' "$docs_json" | grep -oE '"/(auth/token|health|health/system|publish/\{target\}/\{service\}|export/system/log)"' | sort -u | wc -l)
    echo "  matched_paths_count=${match_count}"
    if [ "$match_count" -eq 5 ]; then
        assert "TC01-4: 5개 핵심 엔드포인트가 paths에 존재" "PASS"
    else
        assert "TC01-4: 5개 핵심 엔드포인트가 paths에 존재" "FAIL" "matched=$match_count (expected 5)"
    fi
}

# ============================================================
# TC02: MQTT Disconnect 시 Error Response 처리 (원본 Action 미기재 — 개발자 검토 대기)
# ============================================================
tc02_mqtt_disconnect() {
    echo "=== TC02: SKIP (개발자 검토 대기 — tc_web_interface.md 참고) ==="
}

# ============================================================
# TC03: MQTT-HTTP Bridge 지원
# ============================================================
tc03_bridge() {
    echo "=== TC03: MQTT-HTTP Bridge 지원 ==="
    local admin_key="${WI_ADMIN_AUTH_KEY:-$WI_AUTH_KEY}"
    local admin_secret="${WI_ADMIN_AUTH_SECRET:-$WI_AUTH_SECRET}"
    if [ -z "$admin_key" ]; then
        echo "  [SKIP] WI_ADMIN_AUTH_KEY/WI_AUTH_KEY 미설정 — TC03 전체 skip"
        return
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/auth/token" -H 'Content-Type: application/json' -d "{\"auth_key\":\"${admin_key}\",\"auth_secret\":\"${admin_secret}\",\"subject\":\"tc03\"}"
    local token_resp="$OUTPUT"
    printf '%s' "$token_resp" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d['httpStatus']==200 and d['data']['token']" >/tmp/tc_wi_py_$$ 2>&1
    local py_rc=$?
    sed 's/^/    /' /tmp/tc_wi_py_$$
    rm -f /tmp/tc_wi_py_$$
    if [ "$py_rc" -eq 0 ]; then
        assert "TC03-1: 토큰 발급 성공" "PASS"
    else
        assert "TC03-1: 토큰 발급 성공" "FAIL" "python3 검증 exit=$py_rc"
    fi

    local tok
    tok=$(printf '%s' "$token_resp" | python3 -c "import json,sys;print(json.load(sys.stdin).get('data',{}).get('token',''))" 2>/dev/null)
    if [ -z "$tok" ]; then
        echo "  [SKIP] 토큰 발급 실패로 TC03-2/3 skip"
        return
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/publish/db_manager/select_records" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","keys":["country_code"]}' -o /dev/null -w '%{http_code}'
    local code="$OUTPUT"
    if [ "$code" = "200" ]; then
        assert "TC03-2: Bridge select_records 정상 응답" "PASS"
    else
        assert "TC03-2: Bridge select_records 정상 응답" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/publish/nonexistent_app/select_records" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","keys":["country_code"]}'
    local nx_resp="$OUTPUT"
    if printf '%s' "$nx_resp" | grep -q '"errorCode"'; then
        assert "TC03-3: 존재하지 않는 target에 대해 에러코드 포함 응답" "PASS"
    else
        assert "TC03-3: 존재하지 않는 target에 대해 에러코드 포함 응답" "FAIL" "errorCode 키 없음"
    fi
}

# ============================================================
# TC04: 로깅 보안 (민감 정보 마스킹) (마스킹 로직 위치 미확인 — 개발자 검토 대기)
# ============================================================
tc04_log_masking() {
    echo "=== TC04: SKIP (개발자 검토 대기 — tc_web_interface.md 참고) ==="
}

# ============================================================
# TC05: JWT 토큰 검증
# ============================================================
tc05_jwt() {
    echo "=== TC05: JWT 토큰 검증 ==="
    if [ -z "$WI_AUTH_KEY" ]; then
        echo "  [SKIP] WI_AUTH_KEY 미설정 — TC05 전체 skip"
        return
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/auth/token" -H 'Content-Type: application/json' -d "{\"auth_key\":\"${WI_AUTH_KEY}\",\"auth_secret\":\"${WI_AUTH_SECRET}\",\"subject\":\"tc05\"}"
    local token_resp="$OUTPUT"
    if printf '%s' "$token_resp" | grep -q '"roles":\["readonly"\]'; then
        assert "TC05-1: readonly 토큰 발급 성공" "PASS"
    else
        assert "TC05-1: readonly 토큰 발급 성공" "FAIL" "roles=[\"readonly\"] 확인 실패"
    fi

    local tok
    tok=$(printf '%s' "$token_resp" | python3 -c "import json,sys;print(json.load(sys.stdin).get('data',{}).get('token',''))" 2>/dev/null)
    if [ -z "$tok" ]; then
        echo "  [SKIP] 토큰 없음으로 TC05-2/3 skip"
    else
        dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/health/system" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{}'
        local code="$OUTPUT"
        if [ "$code" = "405" ]; then
            assert "TC05-2: POST /health/system -> 405" "PASS"
        else
            assert "TC05-2: POST /health/system -> 405" "FAIL" "http_code=$code"
        fi

        dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/publish/sys_manager/get_platform_info" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{}'
        code="$OUTPUT"
        if [ "$code" = "403" ]; then
            assert "TC05-3: POST /publish/sys_manager/get_platform_info -> 403(현재 코드 기준)" "PASS"
        else
            assert "TC05-3: POST /publish/sys_manager/get_platform_info -> 403(현재 코드 기준)" "FAIL" "http_code=$code"
        fi
    fi

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/auth/token" -H 'Content-Type: application/json' -d "{\"auth_key\":\"${WI_AUTH_KEY}\",\"auth_secret\":\"wrong\",\"subject\":\"tc05\"}"
    local code="$OUTPUT"
    if [ "$code" = "401" ]; then
        assert "TC05-4: 잘못된 secret으로 토큰 발급 시도 -> 401" "PASS"
    else
        assert "TC05-4: 잘못된 secret으로 토큰 발급 시도 -> 401" "FAIL" "http_code=$code"
    fi
}

# ============================================================
# TC06: 경로 순회 공격 방지
# ============================================================
tc06_path_traversal() {
    echo "=== TC06: 경로 순회 공격 방지 ==="

    local payloads='/../../../etc/passwd /..%2f..%2f..%2fetc/passwd /..\..\..\etc\passwd /.%00./.%00./.%00./etc/passwd'
    local p all_ok
    all_ok=1
    for p in $payloads; do
        dump_cmd curl -sk "https://$HOST:$PORT${p}"
        local body="$OUTPUT"
        dump_cmd curl -sk -o /dev/null -w '%{http_code}' "https://$HOST:$PORT${p}"
        local code="$OUTPUT"
        echo "  payload=${p} http_code=${code}"
        if printf '%s' "$body" | grep -q 'root:'; then
            all_ok=0
            echo "  [DETAIL] payload ${p}: 응답 바디에 root: 노출"
        fi
        case "$code" in
            4??) : ;;
            *) all_ok=0; echo "  [DETAIL] payload ${p}: http_code=${code} (4xx 아님)" ;;
        esac
    done
    if [ "$all_ok" -eq 1 ]; then
        assert "TC06-1: URL Path Traversal 전부 4xx (root: 미노출)" "PASS"
    else
        assert "TC06-1: URL Path Traversal 전부 4xx (root: 미노출)" "FAIL" "위 [DETAIL] 참고"
    fi

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/export/system/log?file=../../../etc/passwd"
    local code="$OUTPUT"
    if [ "$code" = "401" ]; then
        assert "TC06-2: Query Param Traversal(미인증) -> 401" "PASS"
    else
        assert "TC06-2: Query Param Traversal(미인증) -> 401" "FAIL" "http_code=$code"
    fi

    local admin_key="${WI_ADMIN_AUTH_KEY:-$WI_AUTH_KEY}"
    local admin_secret="${WI_ADMIN_AUTH_SECRET:-$WI_AUTH_SECRET}"
    if [ -z "$admin_key" ]; then
        echo "  [SKIP] TC06-3: admin 토큰 없음 (WI_ADMIN_AUTH_KEY 미설정) — skip"
    else
        dump_cmd curl -sk -X POST "https://$HOST:$PORT/auth/token" -H 'Content-Type: application/json' -d "{\"auth_key\":\"${admin_key}\",\"auth_secret\":\"${admin_secret}\",\"subject\":\"tc06\"}"
        local tok
        tok=$(printf '%s' "$OUTPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('data',{}).get('token',''))" 2>/dev/null)
        if [ -z "$tok" ]; then
            echo "  [SKIP] TC06-3: admin 토큰 발급 실패 — skip"
        else
            dump_cmd curl -sk "https://$HOST:$PORT/export/system/log" -H "Authorization: Bearer $tok"
            local resp_a="$OUTPUT"
            dump_cmd curl -sk "https://$HOST:$PORT/export/system/log?file=../../../etc/passwd" -H "Authorization: Bearer $tok"
            local resp_b="$OUTPUT"
            if [ "$resp_a" = "$resp_b" ]; then
                assert "TC06-3: Query Param Traversal(인증됨) 응답 불변" "PASS"
            else
                assert "TC06-3: Query Param Traversal(인증됨) 응답 불변" "FAIL" "file 파라미터에 따라 응답이 다름"
            fi
        fi
    fi

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/auth/token%00.jpg"
    code="$OUTPUT"
    case "$code" in
        4??) assert "TC06-4: Null Byte Injection 전부 4xx" "PASS" ;;
        *) assert "TC06-4: Null Byte Injection 전부 4xx" "FAIL" "http_code=$code" ;;
    esac
}

# ============================================================
# TC07: Injection 공격 방지
# ============================================================
tc07_injection() {
    echo "=== TC07: Injection 공격 방지 ==="

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/auth/token" -H 'Content-Type: application/json' -d '{"auth_key":"admin OR 1=1--","auth_secret":"x","subject":"x"}'
    local code="$OUTPUT"
    if [ "$code" = "401" ]; then
        assert "TC07-1: SQL Injection 페이로드 -> 401" "PASS"
    else
        assert "TC07-1: SQL Injection 페이로드 -> 401" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/auth/token" -H 'Content-Type: application/json' -d '{"auth_key":"admin OR 1=1--","auth_secret":"x","subject":"x"}'
    local body="$OUTPUT"
    if printf '%s' "$body" | grep -q '"token"'; then
        assert "TC07-2: 응답에 토큰 미포함" "FAIL" "응답에 token 키 존재"
    else
        assert "TC07-2: 응답에 토큰 미포함" "PASS"
    fi
}

# ============================================================
# TC08: CORS
# ============================================================
tc08_cors() {
    echo "=== TC08: CORS ==="

    dump_cmd curl -sk -i -X OPTIONS "https://$HOST:$PORT/health" -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: GET'
    local base_hdr
    base_hdr=$(printf '%s' "$OUTPUT" | grep -i 'Access-Control-Allow-Methods' | tr -d '\r')
    echo "  parsed_header=[${base_hdr}]"
    if [ "$base_hdr" = "Access-Control-Allow-Methods: GET,POST,PUT,DELETE,OPTIONS" ]; then
        assert "TC08-1: Allow-Methods 헤더 값 정확히 일치" "PASS"
    else
        assert "TC08-1: Allow-Methods 헤더 값 정확히 일치" "FAIL" "header=${base_hdr}"
    fi

    local m
    for m in PATCH HEAD CONNECT TRACE; do
        dump_cmd curl -sk -i -X OPTIONS "https://$HOST:$PORT/health" -H 'Origin: https://example.com' -H "Access-Control-Request-Method: ${m}"
        local h2
        h2=$(printf '%s' "$OUTPUT" | grep -i 'Access-Control-Allow-Methods' | tr -d '\r')
        echo "  cross-check method=${m} header=[${h2}] (base와 동일 여부: $([ "$h2" = "$base_hdr" ] && echo yes || echo no))"
    done

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X PATCH "https://$HOST:$PORT/health"
    local code="$OUTPUT"
    if [ "$code" = "404" ]; then
        assert "TC08-2: PATCH 실제 요청 시 404(라우트 없음)" "PASS"
    else
        assert "TC08-2: PATCH 실제 요청 시 404(라우트 없음)" "FAIL" "http_code=$code"
    fi
}

# ============================================================
# TC09: SSL 암호화 스위트
# ============================================================
tc09_tls_cipher() {
    echo "=== TC09: SSL 암호화 스위트 ==="

    dump_cmd curl -vk "https://$HOST:$PORT/health"
    local cnt1
    cnt1=$(printf '%s' "$OUTPUT" | grep -c "SSL connection using TLSv1.3")
    echo "  SSL_connection_TLSv1.3_match_count=${cnt1}"
    if [ "$cnt1" -ge 1 ]; then
        assert "TC09-1: 기본 접속이 TLSv1.3으로 협상됨" "PASS"
    else
        assert "TC09-1: 기본 접속이 TLSv1.3으로 협상됨" "FAIL" "count=$cnt1"
    fi

    dump_cmd openssl s_client -connect "$HOST:$PORT" -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384 </dev/null
    local cnt2
    cnt2=$(printf '%s' "$OUTPUT" | grep -c "Cipher.*TLS_AES_256_GCM_SHA384")
    echo "  cipher_match_count=${cnt2}"
    if [ "$cnt2" -ge 1 ]; then
        assert "TC09-2: TLS_AES_256_GCM_SHA384 강제 시 핸드셰이크 성공" "PASS"
    else
        assert "TC09-2: TLS_AES_256_GCM_SHA384 강제 시 핸드셰이크 성공" "FAIL" "count=$cnt2"
    fi
}

# ============================================================
# TC10: TLS 1.3 강제 (구버전 TLS 거부)
# ============================================================
tc10_tls_min_version() {
    echo "=== TC10: TLS 1.3 강제 (구버전 TLS 거부) ==="

    dump_cmd curl -sk --tls-max 1.0 -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/health"
    local code="$OUTPUT"
    if [ "$code" = "000" ]; then
        assert "TC10-1: TLS 1.0 접속 시 000" "PASS"
    else
        assert "TC10-1: TLS 1.0 접속 시 000" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk --tls-max 1.1 -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/health"
    code="$OUTPUT"
    if [ "$code" = "000" ]; then
        assert "TC10-2: TLS 1.1 접속 시 000" "PASS"
    else
        assert "TC10-2: TLS 1.1 접속 시 000" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk --tls-max 1.2 -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/health"
    code="$OUTPUT"
    if [ "$code" = "000" ]; then
        assert "TC10-3: TLS 1.2 접속 시 000" "PASS"
    else
        assert "TC10-3: TLS 1.2 접속 시 000" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk --tlsv1.3 -o /dev/null -w '%{http_code}' "https://$HOST:$PORT/health"
    code="$OUTPUT"
    if [ "$code" = "200" ]; then
        assert "TC10-4: TLS 1.3 접속 시 200" "PASS"
    else
        assert "TC10-4: TLS 1.3 접속 시 200" "FAIL" "http_code=$code"
    fi
}

# ============================================================
# TC11: Content-Type 검증
# ============================================================
tc11_content_type() {
    echo "=== TC11: Content-Type 검증 ==="

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/health" -H "Content-Type: text/plain" -d "test data"
    local code="$OUTPUT"
    if [ "$code" = "415" ]; then
        assert "TC11-1: text/plain -> 415" "PASS"
    else
        assert "TC11-1: text/plain -> 415" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/health" -H "Content-Type: application/xml" -d "<test/>"
    code="$OUTPUT"
    if [ "$code" = "415" ]; then
        assert "TC11-2: application/xml -> 415" "PASS"
    else
        assert "TC11-2: application/xml -> 415" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/health" -H "Content-Type: text/html" -d "<html></html>"
    code="$OUTPUT"
    if [ "$code" = "415" ]; then
        assert "TC11-3: text/html -> 415" "PASS"
    else
        assert "TC11-3: text/html -> 415" "FAIL" "http_code=$code"
    fi
}

# ============================================================
# TC12: Rate Limit (부하 시험 성격 — 단독 실행 또는 마지막 순서 권장)
# ============================================================
tc12_rate_limit() {
    echo "=== TC12: Rate Limit ==="
    echo "  [주의] 60초 이내 650회 요청 부하 시험 — 다른 TC와 rate limit 버킷을 공유하므로 단독 실행 권장"

    local outfile="/tmp/tc_wi_tc12_codes_$$"
    : > "$outfile"
    local i
    for i in $(seq 1 650); do
        curl -sk -o /dev/null -w '%{http_code}\n' "https://$HOST:$PORT/health" >> "$outfile"
    done
    echo "  \$ for i in \$(seq 1 650); do curl -sk -o /dev/null -w '%{http_code}\\n' https://\$HOST:\$PORT/health; done | sort | uniq -c"
    sort "$outfile" | uniq -c | sed 's/^/    /'
    local cnt429
    cnt429=$(sort "$outfile" | uniq -c | awk '$2==429{print $1}')
    [ -z "$cnt429" ] && cnt429=0
    rm -f "$outfile"
    echo "  429_count=${cnt429}"
    if [ "$cnt429" -ge 40 ] && [ "$cnt429" -le 60 ]; then
        assert "TC12-1: 650회 중 429 응답이 40~60회 범위로 발생" "PASS"
    else
        assert "TC12-1: 650회 중 429 응답이 40~60회 범위로 발생" "FAIL" "429_count=$cnt429"
    fi

    dump_cmd curl -sk -i "https://$HOST:$PORT/health"
    local hdr
    hdr=$(printf '%s' "$OUTPUT" | grep -i '^RateLimit-Limit' | tr -d '\r')
    echo "  parsed_header=[${hdr}]"
    if [ "$hdr" = "RateLimit-Limit: 600" ]; then
        assert "TC12-2: RateLimit-Limit 헤더 값 == 600" "PASS"
    else
        assert "TC12-2: RateLimit-Limit 헤더 값 == 600" "FAIL" "header=${hdr}"
    fi
}

# ============================================================
# TC13: XSS
# ============================================================
tc13_xss() {
    echo "=== TC13: XSS ==="

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/auth/token" -H "Content-Type: application/json" -d '{"auth_key":"<script>alert(1)</script>","auth_secret":"test","subject":"test"}'
    local code="$OUTPUT"
    if [ "$code" = "401" ]; then
        assert "TC13-1: 응답 상태 401" "PASS"
    else
        assert "TC13-1: 응답 상태 401" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk -i -X POST "https://$HOST:$PORT/auth/token" -H "Content-Type: application/json" -d '{"auth_key":"<script>alert(1)</script>","auth_secret":"test","subject":"test"}'
    local resp="$OUTPUT"
    local ct
    ct=$(printf '%s' "$resp" | grep -i '^content-type' | tr -d '\r')
    echo "  parsed_content_type=[${ct}]"
    if [ "$ct" = "Content-Type: application/json; charset=utf-8" ]; then
        assert "TC13-2: Content-Type이 application/json" "PASS"
    else
        assert "TC13-2: Content-Type이 application/json" "FAIL" "content-type=${ct}"
    fi

    local xcto
    xcto=$(printf '%s' "$resp" | grep -ic 'X-Content-Type-Options: nosniff')
    echo "  X-Content-Type-Options_match_count=${xcto}"
    if [ "$xcto" -ge 1 ]; then
        assert "TC13-3: X-Content-Type-Options: nosniff 존재" "PASS"
    else
        assert "TC13-3: X-Content-Type-Options: nosniff 존재" "FAIL" "count=$xcto"
    fi
}

# ============================================================
# TC14: HSTS
# ============================================================
tc14_hsts() {
    echo "=== TC14: HSTS ==="

    dump_cmd curl -sk -i "https://$HOST:$PORT/health"
    local hdr
    hdr=$(printf '%s' "$OUTPUT" | grep -i '^strict-transport-security' | tr -d '\r')
    echo "  parsed_header=[${hdr}]"
    if [ "$hdr" = "Strict-Transport-Security: max-age=31536000; includeSubDomains; preload" ]; then
        assert "TC14-1: HSTS 헤더 값 정확히 일치" "PASS"
    else
        assert "TC14-1: HSTS 헤더 값 정확히 일치" "FAIL" "header=${hdr}"
    fi
}

# ============================================================
# TC15: Log Level Control
# ============================================================
tc15_log_level() {
    echo "=== TC15: Log Level Control ==="

    local admin_key="${WI_ADMIN_AUTH_KEY:-$WI_AUTH_KEY}"
    local admin_secret="${WI_ADMIN_AUTH_SECRET:-$WI_AUTH_SECRET}"
    if [ -z "$admin_key" ]; then
        echo "  [SKIP] admin 토큰 없음 (WI_ADMIN_AUTH_KEY 미설정) — TC15 전체 skip"
        return
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/auth/token" -H 'Content-Type: application/json' -d "{\"auth_key\":\"${admin_key}\",\"auth_secret\":\"${admin_secret}\",\"subject\":\"tc15\"}"
    local tok
    tok=$(printf '%s' "$OUTPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('data',{}).get('token',''))" 2>/dev/null)
    if [ -z "$tok" ]; then
        echo "  [SKIP] admin 토큰 발급 실패 — TC15 skip"
        return
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/publish/db_manager/select_records" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_wi"]}'
    local before_val
    before_val=$(printf '%s' "$OUTPUT" | grep -o '"value":"[^"]*"' | head -1 | sed 's/"value":"//;s/"$//')
    echo "  backup_value=[${before_val}]"

    dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/publish/db_manager/upsert_records" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","records":[{"key":"log_level_wi","type":1,"value":"2"}]}'
    local code="$OUTPUT"
    if [ "$code" = "200" ]; then
        assert "TC15-1: log_level_wi 변경 요청 200" "PASS"
    else
        assert "TC15-1: log_level_wi 변경 요청 200" "FAIL" "http_code=$code"
    fi

    dump_cmd curl -sk -X POST "https://$HOST:$PORT/publish/db_manager/select_records" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"db":"edge_storage.db","table":"system_setting","keys":["log_level_wi"]}'
    if printf '%s' "$OUTPUT" | grep -q '"value":"2"'; then
        assert "TC15-2: 재조회 시 변경값 일치" "PASS"
    else
        assert "TC15-2: 재조회 시 변경값 일치" "FAIL" "재조회 응답에 value:2 없음"
    fi

    echo "  [MANUAL] TC15-3: journalctl -u docker-loader --since \"10 seconds ago\" | grep \"Log level set to\" — SSH 미사용 환경에서는 수동 확인 (PASS/FAIL 카운트 미포함)"

    if [ -n "$before_val" ]; then
        dump_cmd curl -sk -o /dev/null -w '%{http_code}' -X POST "https://$HOST:$PORT/publish/db_manager/upsert_records" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "{\"db\":\"edge_storage.db\",\"table\":\"system_setting\",\"records\":[{\"key\":\"log_level_wi\",\"type\":1,\"value\":\"${before_val}\"}]}"
        echo "  [CLEANUP] log_level_wi 복원 -> ${before_val}, http_code=${OUTPUT}"
    fi
}

# ============================================================
# main
# ============================================================
echo "============================================"
echo " web_interface TC"
echo " HOST=${HOST} PORT=${PORT}"
echo " $(date)"
echo "============================================"

case "${1}" in
    --tc01) tc01_api_docs ;;
    --tc02) tc02_mqtt_disconnect ;;
    --tc03) tc03_bridge ;;
    --tc04) tc04_log_masking ;;
    --tc05) tc05_jwt ;;
    --tc06) tc06_path_traversal ;;
    --tc07) tc07_injection ;;
    --tc08) tc08_cors ;;
    --tc09) tc09_tls_cipher ;;
    --tc10) tc10_tls_min_version ;;
    --tc11) tc11_content_type ;;
    --tc12) tc12_rate_limit ;;
    --tc13) tc13_xss ;;
    --tc14) tc14_hsts ;;
    --tc15) tc15_log_level ;;
    *)
        tc01_api_docs
        tc02_mqtt_disconnect
        tc03_bridge
        tc04_log_masking
        tc05_jwt
        tc06_path_traversal
        tc07_injection
        tc08_cors
        tc09_tls_cipher
        tc10_tls_min_version
        tc11_content_type
        tc13_xss
        tc14_hsts
        tc15_log_level
        # TC12(Rate Limit)는 부하 시험 성격상 다른 TC의 rate limit 버킷에 영향을
        # 줄 수 있어 기본 순차 실행에서는 마지막에 배치. 단독 실행 권장: --tc12
        tc12_rate_limit
        ;;
esac

echo ""
echo "============================================"
echo " 결과: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================"
