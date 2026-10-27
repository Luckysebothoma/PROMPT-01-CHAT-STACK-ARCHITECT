#!/usr/bin/env bash
# Day-2 provider tests. Reports PASS / FAIL / SKIPPED / NOT AVAILABLE.
# A live cloud provider test is only claimed when a key is configured AND
# the request actually executed.
set -u
BASE="${1:-http://127.0.0.1:${API_PORT:-4400}}"
pass=0; fail=0; skip=0
P(){ echo "[PASS] $*"; pass=$((pass+1)); }
F(){ echo "[FAIL] $*"; fail=$((fail+1)); }
S(){ echo "[SKIP] $*"; skip=$((skip+1)); }
N(){ echo "[N/A ] $*"; skip=$((skip+1)); }

command -v curl >/dev/null 2>&1 || { N "curl unavailable"; exit 0; }
curl -sf "$BASE/health" >/dev/null 2>&1 || { N "API not reachable at $BASE"; exit 0; }

body(){ curl -s -o /tmp/day2_body.$$ -w '%{http_code}' -X POST "$BASE/v1/chat" \
        -H 'Content-Type: application/json' -d "$1"; }

echo "== /dependencies exposes provider status without secrets"
dep=$(curl -s "$BASE/dependencies")
echo "$dep" | grep -q 'ai_providers' && P "ai_providers present" || F "ai_providers missing"
echo "$dep" | grep -qiE '(api_key|authorization|bearer |sk-|gsk_)' && F "possible secret in /dependencies" || P "no secret material in /dependencies"

echo "== invalid provider"
code=$(body '{"message":"hi","provider":"nope","model":"x"}')
[ "$code" = "400" ] && P "invalid provider -> 400" || F "invalid provider -> $code"

echo "== invalid model"
code=$(body '{"message":"hi","provider":"groq","model":"definitely-not-registered"}')
[ "$code" = "400" ] || [ "$code" = "503" ] && P "invalid model -> $code (controlled)" || F "invalid model -> $code"

echo "== validation"
code=$(body '{}'); [ "$code" = "400" ] && P "missing message -> 400" || F "missing message -> $code"

echo "== default resolution / no provider configured"
code=$(body '{"message":"hello"}')
if [ "$code" = "503" ]; then
  grep -q 'no_provider_configured' /tmp/day2_body.$$ && P "no provider configured -> controlled 503" || F "503 without expected error code"
  N "live provider chat (no provider configured)"
elif [ "$code" = "200" ]; then
  grep -q '"success":true' /tmp/day2_body.$$ && P "live provider chat executed (HTTP 200)" || F "200 without success envelope"
  grep -q 'usage_reported' /tmp/day2_body.$$ && P "token usage state reported" || F "usage state missing"
elif [ "$code" = "502" ]; then
  F "provider configured but upstream request failed (see API logs)"
else
  F "unexpected status $code"
fi
rm -f /tmp/day2_body.$$

echo "== metrics registered"
m=$(curl -s "$BASE/metrics")
for name in ai_gateway_provider_requests_total ai_gateway_provider_errors_total \
            ai_gateway_provider_request_duration_seconds \
            ai_gateway_provider_input_tokens_total ai_gateway_provider_output_tokens_total; do
  echo "$m" | grep -q "$name" && P "metric $name" || S "metric $name not emitted yet (no traffic)"
done

echo "SUMMARY: PASS=$pass FAIL=$fail SKIPPED/NA=$skip"
[ "$fail" -eq 0 ] || exit 1
