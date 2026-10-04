#!/usr/bin/env bash
# Proves GPU node autoscaling end to end:
#   1. scale a GPU-holding Deployment to N replicas -> pods go Pending
#   2. Cluster Autoscaler adds GPU nodes until every pod is Running
#   3. scale to 0 -> idle GPU nodes are removed back down to gpu_min_size
#
# Usage: scripts/verify-gpu-scaling.sh [replicas]   (default 3, must be <= gpu_max_size)
set -euo pipefail

REPLICAS="${1:-3}"
NS=gpu-test
DEPLOY=gpu-scale-test
SCALE_UP_TIMEOUT=900     # seconds; AC-5 target for node add is 300 s, image pull adds more
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

gpu_nodes() { kubectl get nodes -l workload=gpu-inference --no-headers 2>/dev/null | wc -l | tr -d ' '; }
ready_pods() { kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true; }

echo "==> GPU nodes before: $(gpu_nodes)"
kubectl get nodes -l workload=gpu-inference -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,GPUS:.status.allocatable.nvidia\\.com/gpu

kubectl apply -f "$ROOT/k8s/tests/gpu-scale-test.yaml" >/dev/null
echo "==> Scaling $DEPLOY to $REPLICAS replicas (1 GPU each)"
start=$(date +%s)
kubectl -n "$NS" scale deploy "$DEPLOY" --replicas="$REPLICAS"

while true; do
  ready="$(ready_pods)"; ready="${ready:-0}"
  elapsed=$(( $(date +%s) - start ))
  printf '\r    t=%4ss  gpu-nodes=%s  ready-pods=%s/%s' "$elapsed" "$(gpu_nodes)" "$ready" "$REPLICAS"
  [ "$ready" -ge "$REPLICAS" ] && break
  if [ "$elapsed" -ge "$SCALE_UP_TIMEOUT" ]; then
    echo; echo "!! Timed out. Recent autoscaler decisions:"
    kubectl -n kube-system logs deploy/cluster-autoscaler --tail=40 || true
    kubectl -n "$NS" get pods -o wide
    exit 1
  fi
  sleep 10
done
echo; echo "==> Scale-out OK in ${elapsed}s: $(gpu_nodes) GPU nodes"
kubectl get events -n "$NS" --field-selector reason=TriggeredScaleUp --no-headers | tail -3 || true

echo "==> Scaling back to 0; Cluster Autoscaler removes idle GPU nodes after ~10 min (scale-down-unneeded-time)"
kubectl -n "$NS" scale deploy "$DEPLOY" --replicas=0
echo "    Watch with: kubectl get nodes -l workload=gpu-inference -w"
echo "    Clean up:   kubectl delete namespace $NS"
