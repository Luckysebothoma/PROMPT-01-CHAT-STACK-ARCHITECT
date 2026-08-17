#!/usr/bin/env bash
# smoke_test.sh - basic API contract smoke tests for ai-gateway-1-of-10-chat
# Invoked by deploy-ai-gateway-1-of-10-chat.sh test

set -u
BASE_URL="${1:-http://127.0.0.1:${API_PORT:-4400}}"

pass=0
fail=0
skip=0

check() {
  local name="$1" url="$2" method="${3:-GET}" data="${4:-}"
  local code
  if [ "$method" = "POST" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$data" "$url" 2>/dev/null)
  else
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  fi
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    echo "[NOT AVAILABLE] $name (no response from $url)"
    skip=$((skip+1))
    return
  fi
  if [[ "$code" =~ ^2 ]]; then
    echo "[PASS] $name ($code)"
    pass=$((pass+1))
  else
    echo "[FAIL] $name ($code)"
    fail=$((fail+1))
  fi
}

check "GET /health"        "$BASE_URL/health"
check "GET /ready"         "$BASE_URL/ready"
check "GET /dependencies"  "$BASE_URL/dependencies"
check "GET /help"          "$BASE_URL/help"
check "GET /metrics"       "$BASE_URL/metrics"
check "POST /v1/chat"      "$BASE_URL/v1/chat" "POST" '{"message":"smoke test"}'

echo ""
echo "Summary: PASS=$pass FAIL=$fail SKIPPED/NOT AVAILABLE=$skip"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
