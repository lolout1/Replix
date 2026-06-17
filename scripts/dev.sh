#!/usr/bin/env bash
# Unified dev launcher.
#
# Creates logs/<YYYYMMDD-HHMMSS>/ for the launch, tees uvicorn into backend.log
# and Next.js dev into frontend.log, and points the pipeline at the same
# folder via REPROLAB_RUNS_ROOT — so every pipeline run kicked off during this
# launch lands alongside the server logs at logs/<ts>/prj_*/.
#
# Stop with Ctrl-C (or TaskStop from the agent harness). meta.json is updated
# with ended_at on the way out.
set -euo pipefail

cd "$(dirname "$0")/.."

TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="logs/$TS"
mkdir -p "$LOG_DIR"

export REPROLAB_RUNS_ROOT="$PWD/$LOG_DIR"

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
SANDBOX="${REPROLAB_DEFAULT_SANDBOX:-docker}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_meta () {
    local ended_at="${1:-}"
    local ended_field='"ended_at": null'
    if [ -n "$ended_at" ]; then
        ended_field="\"ended_at\": \"$ended_at\""
    fi
    cat > "$LOG_DIR/meta.json" <<EOF
{
  "started_at": "$STARTED_AT",
  $ended_field,
  "git_sha": "$GIT_SHA",
  "sandbox_mode": "$SANDBOX",
  "runs_root": "$REPROLAB_RUNS_ROOT",
  "backend_pid": ${BACKEND_PID:-null},
  "frontend_pid": ${FRONTEND_PID:-null}
}
EOF
}

PY_BIN=".venv/Scripts/python.exe"
if [ ! -f "$PY_BIN" ]; then PY_BIN=".venv/bin/python"; fi
if [ ! -f "$PY_BIN" ]; then
    echo "[dev.sh] no venv at .venv — create one with: python -m venv .venv && pip install -r backend/requirements.txt" >&2
    exit 1
fi

# Free :8000 / :3000 from any stale dev server so re-running this script is
# safe. Windows path uses PowerShell (lsof is unreliable on Windows + git-bash);
# macOS / Linux use lsof + kill.
free_port () {
    local port="$1"
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command \
            "Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id \$_.OwningProcess -Force -ErrorAction SilentlyContinue }" \
            >/dev/null 2>&1 || true
    elif command -v lsof >/dev/null 2>&1; then
        # -t prints PIDs only; -i :PORT scopes to that port; -sTCP:LISTEN filters
        # to the listener (avoids killing transient client sockets).
        local pids
        pids="$(lsof -t -i ":$port" -sTCP:LISTEN 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            # shellcheck disable=SC2086
            kill -9 $pids 2>/dev/null || true
        fi
    fi
}
free_port 8000
free_port 3000

echo "[dev.sh] logs    -> $LOG_DIR"
echo "[dev.sh] sandbox -> $SANDBOX"
echo "[dev.sh] runs    -> $REPROLAB_RUNS_ROOT"

"$PY_BIN" -m uvicorn backend.app:create_app --factory --host 127.0.0.1 --port 8000 --reload \
    > "$LOG_DIR/backend.log" 2>&1 &
BACKEND_PID=$!

(
    cd frontend && REPROLAB_BACKEND_URL=http://127.0.0.1:8000 npm run dev
) > "$LOG_DIR/frontend.log" 2>&1 &
FRONTEND_PID=$!

write_meta

cleanup () {
    local ended_at
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_meta "$ended_at"
    kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true
    free_port 8000
    free_port 3000
}
trap cleanup EXIT INT TERM

echo "[dev.sh] backend pid=$BACKEND_PID  log=$LOG_DIR/backend.log"
echo "[dev.sh] frontend pid=$FRONTEND_PID log=$LOG_DIR/frontend.log"
echo "[dev.sh] open http://localhost:3000/lab"

# Block until either child exits. `wait -n` would be nicer but it's bash 4.3+
# and the default /bin/bash on macOS is still 3.2, so we poll with kill -0
# (which only checks process existence, doesn't actually signal).
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$FRONTEND_PID" 2>/dev/null; do
    sleep 1
done
