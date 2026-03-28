#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-19091}"
HOST="${HOST:-0.0.0.0}"
LOG_FILE="${LOG_FILE:-/tmp/zeroclaw_bailian_relay.log}"

if [ -z "${BAILIAN_API_KEY:-}" ] && [ -z "${DASHSCOPE_API_KEY:-}" ] && [ -z "${ZEROCLAW_API_KEY:-}" ]; then
    echo "需要先提供 BAILIAN_API_KEY / DASHSCOPE_API_KEY / ZEROCLAW_API_KEY" >&2
    exit 1
fi

PID="$(lsof -ti tcp:${PORT} || true)"
if [ -n "${PID}" ]; then
    kill ${PID} >/dev/null 2>&1 || true
    sleep 1
fi

: > "${LOG_FILE}"
node "${SCRIPT_DIR}/bailian-relay.js" >>"${LOG_FILE}" 2>&1 &
sleep 1

echo "Relay listening on http://${HOST}:${PORT}"
echo "Log: ${LOG_FILE}"
tail -n 20 "${LOG_FILE}" || true
