# Capacity plan: 5,000 concurrent requests

Target: **5,000 requests in flight at the same time** (each one a streaming chat completion that is
being prefilled or generating tokens), from downstream apps such as an internal developer platform.

The numbers below are **estimates** from hardware specs and the model's shape. Nothing here has run
on real GPUs yet. Run the load test at the end and replace the per-GPU figure with what you measure;
everything else scales from it.

## Workload assumptions

| | Value | Why it matters |
|---|---|---|
| Prompt length | ~1,000 tokens (REQUIREMENTS §7 tests 100–1,500) | prefill compute, KV cache |
| Output length | ~300 tokens | decode time per request |
| Streaming | yes | gateway relays every token chunk |
| Model | Qwen2.5-7B-Instruct | 28 layers, 4 KV heads x 128 dims (GQA) |
| Latency targets | TTFT p99 ≤ 800 ms, TPOT p50 ≤ 60 ms (NFR-1) | caps batch size per GPU |

If your traffic has much longer prompts or outputs, redo the math: capacity falls roughly in
proportion to tokens per request.

## Why the default profile can't do it

The default profile is 6 x g5.xlarge (A10G 24 GB, bf16). After the 15 GB of weights, an A10G has
~5 GB left for KV cache. At 56 KiB per token (2 x 28 layers x 4 heads x 128 dims x 2 bytes) that is
~90k tokens, or about **65 concurrent requests per GPU** of 1,300 tokens. 6 GPUs hold ~400, and
5,000 would need ~80 A10Gs.

## Production profile: L40S + FP8

`terraform/5k.tfvars.example`, `helm/vllm/values-5k.yaml`, `helm/litellm/values-5k.yaml`.

**Per GPU (g6e.xlarge, 1 x L40S 48 GB, FP8 weights):**

- Memory: FP8 weights ~9 GB, leaving ~30 GB of KV cache, ~550k tokens, room for ~400 requests
  of 1,300 tokens. Memory is no longer the limit.
- Compute is. Each request costs ~1,300 tokens of work (prefill + decode) at ~15 GFLOP per token
  for a 7.6B model. At a realistic ~10k tokens/s of mixed prefill + decode per L40S in FP8, a GPU
  completes ~7–8 requests/s.
- Little's law: in flight = arrival rate x time in system. At ~50 ms per output token a request
  lasts ~15 s, so one GPU holds **~110–120 requests in flight** while meeting the latency targets,
  and produces ~2,300 output tokens/s.

**Fleet:**

| Component | Sizing | Setting |
|---|---|---|
| vLLM replicas | 5,000 / 100 in flight per GPU = **50 GPUs** at peak | `autoscaling.maxReplicas: 50`, `targetInFlightPerReplica: 100` |
| Per-replica ceiling | 192 sequences decoded together, then vLLM queues | `--max-num-seqs 192` |
| GPU nodes | 2 → 50 x g6e.xlarge (fallback g6e.2xlarge) | `gpu_min_size 2`, `gpu_max_size 50` |
| Output throughput | ~50 x 2,300 ≈ **115k tokens/s** at peak (estimate) | |
| Gateway | streaming 115k tokens/s of chunks, ~330 requests/s | LiteLLM 10 → 30 pods x 1 vCPU, `global_max_parallel_requests: 600` per pod |
| Gateway DB | 30 pods x 5 connections = 150 | `database_connection_pool_limit: 5`, Postgres `max_connections: 200` |
| System nodes | gateway + monitoring + controllers | 3 → 8 x m6i.2xlarge |
| Entry point | internal ALB, pod IP targets, 600 s idle timeout | `ingress.enabled: true` |
| Per-key limits | a platform key may be granted up to 5,000 parallel requests | `upperbound_key_generate_params` |
| EC2 quota | G and VT on-demand vCPUs ≥ 50 x 4 = **200** | request before applying |

**Cost at peak** (us-east-1 on-demand list prices, check current pricing): 50 x g6e.xlarge ≈
$93/hour for GPUs. The fleet only runs that size while traffic needs it; idle it shrinks to 2.

**Why FP8:** decode at large batch sizes is limited by memory bandwidth, and FP8 halves the bytes
read per step. It also leaves room for a big KV cache. Expect a small quality drop; check it on your
own evals. Without FP8, plan for roughly 1.6x the GPUs.

## Scaling speed

A new GPU replica needs a node boot, a ~10 GB image pull and a ~15 GB model download, so it takes
minutes, not seconds. The profile handles this three ways:

1. **Pre-warm:** a KEDA cron trigger holds 20 replicas (~2,000 in flight) on weekdays 07:00–19:00
   UTC. Adjust to your traffic.
2. **Big steps:** scale-up doubles the fleet (or adds 8 replicas) per minute instead of 2.
3. **Queue, don't fail:** while capacity arrives, requests wait in vLLM's queue (router timeout
   600 s) instead of erroring. Past 600 in flight per gateway pod, the gateway returns 429.

## Before running at 5,000

- **Image and model downloads:** 50 nodes pulling `vllm/vllm-openai` from Docker Hub through the
  NAT gateways will hit Docker Hub's pull rate limits, and 50 parallel 15 GB downloads from Hugging
  Face are slow. Mirror the image into ECR (pull-through cache) and stage the weights in S3 before
  scaling past a handful of nodes.
- **Alert routing:** Alertmanager has no receiver yet, so alerts only show in Grafana and Prometheus.
  Add Slack or PagerDuty before production traffic.
- **Measure:** run the load test below and update `targetInFlightPerReplica` to ~80% of the
  in-flight count where one replica still meets TTFT p99 ≤ 800 ms.

## Load test

`scripts/locustfile.py` keeps one streaming request open per Locust user, so users = concurrent
requests. It reports TTFT, TPOT and end-to-end time per request.

1. One replica first: `-u 50,100,150,200` against a single vLLM replica (autoscaling off). Find the
   in-flight count where TTFT p99 crosses 800 ms or TPOT p50 crosses 60 ms. That is your per-GPU
   capacity.
2. Then the fleet: `k8s/tests/load-test/locust.yaml` (12 workers), ramp to 5,000 users at 25/s and
   hold 15 minutes. Watch the Inference autoscaling dashboard: replicas, Pending pods, GPU nodes.

Pass criteria (REQUIREMENTS §7, scaled): 5,000 concurrent with under 1% 5xx, TTFT p99 ≤ 800 ms once
the fleet has scaled, no pod restarts, GPU utilization ≥ 85% at peak.
