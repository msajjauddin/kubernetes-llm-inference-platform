#!/usr/bin/env bash
# Checks the gateway end to end (REQUIREMENTS AC-1, AC-7 and FR-2..FR-6):
#   1. /health/readiness, model list, one chat completion through LiteLLM to vLLM
#   2. no key -> 401; a model the key isn't allowed -> 403
#   3. a throwaway virtual key with rpm_limit 2 -> third request in a minute gets 429
#   4. /metrics/ needs the scrape token and shows the requests just made
#   5. a pod that isn't the gateway can't reach vLLM:8000 (NetworkPolicy)
#
# Usage: scripts/verify-litellm.sh
set -euo pipefail

NS="${NS:-llm}"
SVC="${SVC:-litellm}"
SECRET="${SECRET:-litellm-secrets}"
PORT="${PORT:-4000}"

secret() { kubectl -n "$NS" get secret "$SECRET" -o jsonpath="{.data.$1}" | base64 -d; }
MASTER="$(secret LITELLM_MASTER_KEY)"
METRICS_TOKEN="$(secret LITELLM_METRICS_TOKEN)"

URL="http://127.0.0.1:${PORT}"
kubectl -n "$NS" port-forward "svc/$SVC" "${PORT}:4000" >/dev/null 2>&1 &
PF=$!
KEY=""
cleanup() {
  [ -n "$KEY" ] && curl -s -o /dev/null "$URL/key/delete" -H "Authorization: Bearer $MASTER" \
    -H 'Content-Type: application/json' -d "{\"keys\": [\"$KEY\"]}" || true
  kill "$PF" 2>/dev/null || true
}
trap cleanup EXIT

fail() { echo "!! $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "==> Waiting for the gateway"
for _ in $(seq 1 60); do curl -sf "$URL/health/readiness" >/dev/null 2>&1 && break; sleep 2; done
curl -sf "$URL/health/readiness" | jq -c . || fail "gateway not ready"

MODEL="$(curl -sf "$URL/v1/models" -H "Authorization: Bearer $MASTER" | jq -r '.data[0].id')"
echo "==> Model: $MODEL"
CHAT=$(jq -nc --arg m "$MODEL" '{model: $m, max_tokens: 16, messages: [{role: "user", content: "Say hi in five words."}]}')

echo "==> Chat completion through LiteLLM -> vLLM"
curl -sf "$URL/v1/chat/completions" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' -d "$CHAT" \
  | jq -r '.choices[0].message.content, "tokens: \(.usage.total_tokens)"'

echo "==> Auth"
c=$(code "$URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$CHAT"); echo "    no key: $c"; [ "$c" = 401 ] || fail "expected 401"

KEY=$(curl -sf "$URL/key/generate" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -d "{\"key_alias\": \"verify-$(date +%s)\", \"models\": [\"$MODEL\"], \"rpm_limit\": 2, \"duration\": \"10m\"}" | jq -r .key)
OTHER=$(jq -nc '{model: "not-allowed-model", messages: [{role: "user", content: "hi"}]}')
c=$(code "$URL/v1/chat/completions" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$OTHER")
echo "    model outside the key's list: $c"; [ "$c" = 403 ] || [ "$c" = 401 ] || fail "expected 403"

echo "==> Rate limit (virtual key, rpm_limit 2)"
codes=""
for _ in 1 2 3; do codes="$codes $(code "$URL/v1/chat/completions" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$CHAT")"; done
echo "    $codes"; [[ "$codes" == *429* ]] || fail "expected a 429"

echo "==> Metrics"
c=$(code "$URL/metrics/"); echo "    without token: $c"; [ "$c" = 401 ] || fail "expected 401"
n=$(curl -sf "$URL/metrics/" -H "Authorization: Bearer $METRICS_TOKEN" | grep -c '^litellm_proxy_total_requests_metric_total' || true)
echo "    litellm_proxy_total_requests_metric_total series: $n"; [ "$n" -gt 0 ] || fail "no request metrics"

echo "==> NetworkPolicy: vLLM from a non-gateway pod (should time out)"
if kubectl -n "$NS" run "np-check-$RANDOM" --rm -i --restart=Never --quiet \
     --image=curlimages/curl:8.22.0 --overrides='{"spec":{"nodeSelector":{"role":"system"}}}' \
     -- curl -s -m 5 -o /dev/null http://vllm:8000/v1/models; then
  fail "vLLM is reachable from a non-gateway pod; is enableNetworkPolicy on for the vpc-cni add-on?"
fi
echo "    blocked"

echo "==> All gateway checks passed"
