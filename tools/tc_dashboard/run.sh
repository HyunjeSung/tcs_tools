#!/bin/bash
# system_log TC 웹 대시보드 실행
cd "$(dirname "$0")"
PYTHON=python3
[ -x ".venv/bin/python3" ] && PYTHON=.venv/bin/python3
exec "$PYTHON" -m uvicorn server:app --host 0.0.0.0 --port 8090
