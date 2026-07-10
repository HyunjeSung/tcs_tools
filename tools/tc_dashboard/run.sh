#!/bin/bash
# system_log TC 웹 대시보드 실행
cd "$(dirname "$0")"
exec python3 -m uvicorn server:app --host 0.0.0.0 --port 8090
