#!/usr/bin/env bash
# Checks vLLM end to end, then (optionally) loads it hard enough to make it scale:
#   1. port-forward the vLLM Service and wait for /health
#   2. list models, run one chat completion
#   3. with --load N: keep N concurrent requests in flight for --duration seconds, printing
#      vLLM replicas, Pending pods and GPU nodes as KEDA and Cluster Autoscaler react
#
# Usage: scripts/verify-vllm.sh [--load 96] [--duration 600]
# 96 in flight against the default target of 24 per replica asks KEDA for 4 replicas, so
# Cluster Autoscaler has to add 3 GPU nodes. Needs Prometheus scraping vLLM (observability layer).
set -euo pipefail

NS="${NS:-llm}"
SVC="${SVC:-vllm}"
PORT="${PORT:-8000}"
LOAD=0
DURATION=600
while [ $# -gt 0 ]; do
  case "$1" in
    --load) LOAD="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

URL="http://127.0.0.1:${PORT}"
kubectl -n "$NS" port-forward "svc/$SVC" "${PORT}:8000" >/dev/null 2>&1 &
PF=$!
WORKERS=()
cleanup() { kill "$PF" "${WORKERS[@]}" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Waiting for $SVC to be healthy (the first start downloads the model)"
for _ in $(seq 1 120); do
  curl -sf "$URL/health" >/dev/null 2>&1 && break
  sleep 5
done
curl -sf "$URL/health" >/dev/null || { echo "!! $SVC not healthy"; kubectl -n "$NS" get pods -o wide; exit 1; }

MODEL="$(curl -sf "$URL/v1/models" | jq -r '.data[0].id')"
echo "==> Model: $MODEL"

echo "==> Chat completion"
curl -sf "$URL/v1/chat/completions" -H 'Content-Type: application/json' -d @- <<EOF | jq -r '.choices[0].message.content, "tokens: \(.usage.completion_tokens)"'
{"model": "$MODEL", "max_tokens": 32,
 "messages": [{"role": "user", "content": "Say hello from a Kubernetes GPU node in one sentence."}]}
EOF

[ "$LOAD" -gt 0 ] || exit 0

# Long outputs keep each request in flight for a while, so the in-flight count tracks LOAD.
# The port-forward pins traffic to one pod; that's fine, the scaling signal is the queue it builds.
BODY=$(jq -nc --arg m "$MODEL" '{model: $m, max_tokens: 512, temperature: 0.8,
  messages: [{role: "user", content: "Write a detailed, step-by-step guide to running LLM inference on Kubernetes."}]}')
end=$(( $(date +%s) + DURATION ))
echo "==> Holding $LOAD requests in flight for ${DURATION}s"
for _ in $(seq 1 "$LOAD"); do
  ( while [ "$(date +%s)" -lt "$end" ]; do
      curl -s -o /dev/null -m 300 "$URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$BODY" || sleep 1
    done ) &
  WORKERS+=($!)
done

while [ "$(date +%s)" -lt "$end" ]; do
  replicas=$(kubectl -n "$NS" get deploy "$SVC" -o jsonpath='{.status.replicas}/{.status.readyReplicas}')
  desired=$(kubectl -n "$NS" get hpa "$SVC" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo "?")
  pending=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=vllm --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
  nodes=$(kubectl get nodes -l workload=gpu-inference --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf '%s  hpa-desired=%s  replicas(total/ready)=%s  pending=%s  gpu-nodes=%s\n' \
    "$(date +%H:%M:%S)" "$desired" "$replicas" "$pending" "$nodes"
  sleep 15
done

echo "==> Load stopped. KEDA scales in after a 10 min stabilization window, then Cluster Autoscaler"
echo "    removes idle GPU nodes ~10 min later. Watch: kubectl get hpa,pods -n $NS -w"
