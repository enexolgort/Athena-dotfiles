#!/usr/bin/env bash
# check-remote.sh
# Run from any client device on your tailnet (laptop, phone via Termux)
# to verify Athena's services are actually reachable. Not run on the
# server itself.
#
# Usage: ./check-remote.sh [--host <tailscale-ip-or-name>]
# Exit code: 0 if everything passed, 1 if anything failed.

set -uo pipefail

HOST="athena"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; BOLD=""; RESET=""
fi

PASS=0
FAIL=0
pass() { echo "  ${GREEN}✓${RESET} $1"; PASS=$((PASS + 1)); }
fail() { echo "  ${RED}✗${RESET} $1"; FAIL=$((FAIL + 1)); }

check_port() {
  local port="$1" label="$2"
  if timeout 5 bash -c "exec 3<>/dev/tcp/$HOST/$port" 2>/dev/null; then
    exec 3<&- 3>&- 2>/dev/null
    pass "$label (port $port open)"
  else
    fail "$label (port $port unreachable)"
  fi
}

echo "${BOLD}Checking Athena ($HOST)${RESET}"
check_port 22 "SSH"
check_port 3000 "Forgejo / git server"
check_port 5678 "n8n"
check_port 11434 "Ollama"
check_port 8080 "Open WebUI"
check_port 3001 "Uptime Kuma"

echo
echo "${BOLD}Summary: $PASS passed, $FAIL failed${RESET}"
[ "$FAIL" -eq 0 ]
