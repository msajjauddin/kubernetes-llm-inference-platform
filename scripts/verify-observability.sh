#!/usr/bin/env bash
# Checks the observability layer and the autoscaling wiring that depends on it (AC-5, AC-6, AC-8):
#   1. Prometheus is scraping vLLM, LiteLLM, the DCGM exporter, KEDA and Cluster Autoscaler
#   2. the queries behind vLLM's KEDA triggers return data
#   3. KEDA's ScaledObject is Ready and its HPA reads real metric values (not <unknown>)
#   4. Grafana is up and has the LLM Platform dashboards
#   5. the LLM platform alert rules are loaded, and which alerts are firing
#
# Usage: scripts/verify-observability.sh
set -euo pipefail

OBS="${OBS:-observability}"
LLM_NS="${LLM_NS:-llm}"
PROM_PORT="${PROM_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"

kubectl -n "$OBS" port-forward svc/prometheus-operated "${PROM_PORT}:9090" >/dev/null 2>&1 &
PF1=$!
kubectl -n "$OBS" port-forward svc/monitoring-grafana "${GRAFANA_PORT}:80" >/dev/null 2>&1 &
PF2=$!
trap 'kill $PF1 $PF2 2>/dev/null || true' EXIT

fail() { echo "!! $*"; exit 1; }
PROM="http://127.0.0.1:${PROM_PORT}"
GRAFANA="http://127.0.0.1:${GRAFANA_PORT}"
q() { curl -sf "$PROM/api/v1/query" --data-urlencode "query=$1"; }

echo "==> Waiting for Prometheus and Grafana"
for _ in $(seq 1 30); do curl -sf "$PROM/-/ready" >/dev/null 2>&1 && curl -sf "$GRAFANA/api/health" >/dev/null 2>&1 && break; sleep 2; done
curl -sf "$PROM/-/ready" >/dev/null || fail "Prometheus not ready"

echo "==> Scrape targets (healthy / total)"
for job in vllm litellm dcgm-exporter keda-operator cluster-autoscaler kube-state-metrics; do
  r=$(q "sum(up{job=\"$job\"}) or vector(0)" | jq -r '.data.result[0].value[1]')
  t=$(q "count(up{job=\"$job\"}) or vector(0)" | jq -r '.data.result[0].value[1]')
  printf '    %-20s %s / %s\n' "$job" "$r" "$t"
  case "$job" in
    vllm|litellm|kube-state-metrics) [ "$r" != 0 ] || fail "no healthy $job target" ;;
  esac
done
[ "$(q 'count(up{job="dcgm-exporter"}) or vector(0)' | jq -r '.data.result[0].value[1]')" != 0 ] \
  || echo "    (no DCGM targets: normal only while there are no GPU nodes)"

echo "==> KEDA trigger inputs"
MODEL=$(q "group by (model_name) (vllm:num_requests_running{namespace=\"$LLM_NS\"})" | jq -r '.data.result[0].metric.model_name // empty')
[ -n "$MODEL" ] || fail "no vllm:num_requests_running series: vLLM isn't being scraped with namespace/model_name labels"
SEL="namespace=\"$LLM_NS\",model_name=\"$MODEL\""
echo "    in-flight: $(q "sum({__name__=~\"vllm:num_requests_(running|waiting)\",$SEL})" | jq -r '.data.result[0].value[1]')"
echo "    waiting:   $(q "sum(vllm:num_requests_waiting{$SEL})" | jq -r '.data.result[0].value[1]')"

echo "==> KEDA ScaledObject and HPA"
kubectl -n "$LLM_NS" get scaledobject vllm
ready=$(kubectl -n "$LLM_NS" get scaledobject vllm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[ "$ready" = True ] || fail "ScaledObject not Ready: kubectl -n $LLM_NS describe scaledobject vllm"
kubectl -n "$LLM_NS" get hpa vllm
kubectl -n "$LLM_NS" get hpa vllm -o jsonpath='{.status.currentMetrics}' | grep -q averageValue \
  || fail "HPA has no metric values yet (wait a minute; if it persists check the keda-operator logs)"

echo "==> GPU metrics"
echo "    GPUs reporting: $(q 'count(DCGM_FI_DEV_GPU_UTIL) or vector(0)' | jq -r '.data.result[0].value[1]')"
q 'DCGM_FI_DEV_GPU_UTIL' | jq -r '.data.result[] | "    \(.metric.node) gpu\(.metric.gpu) \(.metric.modelName): \(.value[1])% used by \(.metric.exported_pod // "-")"'

echo "==> Grafana dashboards"
PASS=$(kubectl -n "$OBS" get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -sf -u "admin:$PASS" "$GRAFANA/api/search?tag=llm-platform" | jq -r '.[] | "    \(.folderTitle) / \(.title)"'
n=$(curl -sf -u "admin:$PASS" "$GRAFANA/api/search?tag=llm-platform" | jq length)
[ "$n" -ge 4 ] || fail "expected 4 LLM Platform dashboards, found $n"

echo "==> Alerts"
rules=$(curl -sf "$PROM/api/v1/rules" | jq '[.data.groups[] | select(.name | startswith("llm-platform")) | .rules[]] | length')
echo "    LLM platform rules loaded: $rules"
[ "$rules" -gt 0 ] || fail "llm-platform rules not loaded"
curl -sf "$PROM/api/v1/alerts" | jq -r '.data.alerts[] | select(.state == "firing") | "    firing: \(.labels.alertname) \(.labels.severity)"'

echo "OK. Grafana: kubectl -n $OBS port-forward svc/monitoring-grafana 3000:80, user admin, password from secret monitoring-grafana"
