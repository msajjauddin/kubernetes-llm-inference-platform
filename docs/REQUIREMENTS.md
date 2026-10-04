# Requirements — Kubernetes LLM Inference Platform

**Version:** 1.0 · **Status:** Approved baseline · **Owner:** Platform Engineering
**Scope:** AWS EKS-based inference platform serving open-weight LLMs with OpenAI-compatible APIs.

---

## 1. Goals & Context

Provide a production-style, cloud-native platform that serves LLMs with high throughput and low latency,
using vLLM as the inference engine and LiteLLM Proxy as the API gateway. All infrastructure must be
reproducible from code (Terraform), deployments automated (CI/CD + ArgoCD), and operations observable
(metrics, dashboards, traces).

**Business drivers:** reduce GPU cost per request, enforce per-team API governance (keys, quotas, routing),
and provide SLO-grade visibility into inference performance.

## 2. Users & Stakeholders

| Stakeholder | Interest |
|---|---|
| Application teams | Reliable OpenAI-compatible endpoint, API keys, rate limits |
| ML platform team | Model onboarding, GPU utilization, autoscaling |
| Security team | AuthN/AuthZ, network isolation, secrets management, auditability |
| SRE | SLOs, alerting, dashboards, incident response |

## 3. Functional Requirements

| ID | Requirement | Implementation | Priority |
|---|---|---|---|
| FR-1 | Serve LLMs via an OpenAI-compatible API (chat completions, completions, embeddings optional) | vLLM OpenAI server (`/v1/*`), model `Qwen/Qwen2.5-7B-Instruct` (swappable) | Must |
| FR-2 | Gateway providing **authentication** (API keys / virtual keys) | LiteLLM Proxy `general_settings.master_key` + virtual keys via `/key/generate` | Must |
| FR-3 | **Model routing** with load distribution and failover across model deployments | LiteLLM `model_list` + `router_settings` (`num_retries`, `cooldown_time`, fallbacks) | Must |
| FR-4 | **Request validation** at the edge (schema, max tokens, allowed models, budgets) | LiteLLM proxy input validation; FastAPI pydantic schemas on sample client | Must |
| FR-5 | **Rate limiting** per key/model (RPM/TPM + max parallel requests) | LiteLLM virtual-key budgets + `litellm_settings.max_parallel_requests` | Must |
| FR-6 | **Inference telemetry**: latency, token throughput, cost/spend per request | LiteLLM Prometheus callback; OTel traces from FastAPI + LiteLLM | Must |
| FR-7 | Provision EKS, VPC, IAM, networking and **GPU-backed node groups** declaratively | Terraform (`terraform/`) | Must |
| FR-8 | Container images built, scanned and stored in **Amazon ECR** | `terraform/ecr.tf` + CI workflow | Must |
| FR-9 | **CI/CD**: image builds on merge; **GitOps** automated sync to cluster | GitHub Actions + ArgoCD | Must |
| FR-10 | **Observability**: inference latency (TTFT, TPOT), token throughput, GPU utilization, request errors, resource consumption | Prometheus + Grafana (`helm/`, `grafana-dashboards/`) + DCGM exporter | Must |
| FR-11 | **Autoscaling** of inference workloads under increasing traffic | KEDA (prometheus trigger on request rate) + HPA (CPU) + Cluster Autoscaler (GPU nodes) | Must |
| FR-12 | **Load testing** to evaluate latency, throughput, concurrency and GPU utilization | Locust (`scripts/locustfile.py`) + acceptance thresholds (§7) | Must |
| FR-13 | **Security controls**: RBAC, NetworkPolicies, IAM least-privilege, secrets management | `k8s/rbac`, `k8s/network`, Pod Identity, PSS labels | Must |
| FR-14 | Prefix caching and continuous batching enabled to maximize GPU efficiency | vLLM args `--enable-prefix-caching`, continuous batching (default) | Should |
| FR-15 | Multi-tenant model variants on shared GPU (Multi-LoRA) | vLLM `--enable-lora` (documented; optional add-on) | Could |
| FR-16 | Budget alerts / spend tracking per team key | LiteLLM spend logs + `litellm_spend_metric` (needs Postgres for persistence) | Could |

## 4. Non-Functional Requirements

| ID | Category | Requirement / Target |
|---|---|---|
| NFR-1 | Latency (single request, warm) | TTFT p50 ≤ 300 ms, p99 ≤ 800 ms; TPOT p50 ≤ 60 ms @ 7B bf16 on g5.xlarge |
| NFR-2 | Throughput | ≥ 600 output tok/s aggregate per GPU at concurrency 32 (7B, 512-token outputs, prefix caching on) |
| NFR-3 | Concurrency | Sustain ≥ 64 concurrent chat sessions per replica with graceful degradation |
| NFR-4 | Availability | 99.9% monthly for the gateway endpoint; rolling-safe deployments (`Recreate` strategy for single-GPU vLLM) |
| NFR-5 | Scalability | Scale vLLM replicas 1→N (KEDA, ≤ GPU node max) and nodes 1→6 (Cluster Autoscaler) |
| NFR-6 | Durability of telemetry | Prometheus 7-day retention (configurable PVC-backed storage) |
| NFR-7 | Security | No public vLLM exposure; gateway auth required; secrets never in Git; PSS `baseline` minimum |
| NFR-8 | Reproducibility | Full environment rebuild from Terraform + manifests ≤ 45 min (excluding model download) |
| NFR-9 | Cost efficiency | GPU nodes scale to `min_size` when idle; quantization (FP8/AWQ) supported as cost lever |
| NFR-10 | Maintainability | All manifests reviewed via PR; ArgoCD self-heal + drift detection enabled |

## 5. Architecture Requirements (component mapping)

| Concern | Component | Notes |
|---|---|---|
| Ingress to gateway | LiteLLM Service (`ClusterIP`) | Expose via `kubectl port-forward` in dev; ALB/Ingress + WAF in prod |
| Inference | vLLM Deployment (1 replica = 1 GPU) | `--gpu-memory-utilization 0.90`, shm volume for NCCL |
| KV-cache efficiency | PagedAttention (built-in) + `--enable-prefix-caching` | AWS explainer: aws.amazon.com/what-is/vllm/ |
| Metrics source (inference) | vLLM `/metrics` (Prometheus) | TTFT, TPOT, throughput, running/waiting requests |
| Metrics source (GPU) | DCGM exporter DaemonSet on GPU nodes | `DCGM_FI_DEV_GPU_UTIL`, framebuffer used |
| Metrics source (gateway) | LiteLLM Prometheus callback | request counts, latency histogram, spend |
| Tracing | OTel Collector (OTLP in → Prometheus spanmetrics) | FastAPI + LiteLLM instrumented |
| Scale signal | KEDA prometheus trigger on `litellm_proxy_total_requests_metric` rate | threshold per §7 test plan |
| Node scale signal | Cluster Autoscaler via EKS Pod Identity | `min=1, max=6` GPU nodes |

## 6. Security Requirements

| ID | Requirement | Implementation |
|---|---|---|
| SEC-1 | Default-deny ingress in `llm` namespace | `network-policies.yaml` |
| SEC-2 | Explicit allowlist: client → LiteLLM (4000), LiteLLM → vLLM (8000), Prometheus → metrics ports, DNS egress | NetworkPolicies with pod/namespace selectors |
| SEC-3 | Least-privilege service accounts (no default SA usage, no cluster-admin bindings for workloads) | `k8s/rbac/serviceaccounts.yaml` |
| SEC-4 | IAM via EKS Pod Identity / IRSA; node roles carry no extra policies | `terraform/iam.tf`, `terraform/eks.tf` |
| SEC-5 | Secrets externalized; never committed | `k8s/litellm/secret.example.yaml` + External Secrets Operator (prod) backed by AWS Secrets Manager |
| SEC-6 | Pod Security Standards enforced (`baseline`; goal: `restricted` with non-root builds) | `k8s/namespaces.yaml` labels |
| SEC-7 | Gateway is the only auth boundary exposed to clients; vLLM unreachable externally | LiteLLM master key + NetworkPolicy |
| SEC-8 | ECR image scanning on push; CI blocks critical CVEs | `terraform/ecr.tf` + workflow scan step |

## 7. Acceptance Criteria & Load-Test Plan

**Tool:** Locust (`scripts/locustfile.py`) — ramp 1→50 users over 5 min, hold 10 min, prompts 100–1,500 tokens.

| # | Scenario | Pass criteria |
|---|---|---|
| AC-1 | Smoke test | `smoke_test.py` green: gateway /health, model list, 1-token chat completion |
| AC-2 | Latency at low load (u=5) | TTFT p50 ≤ 300 ms, p99 ≤ 800 ms |
| AC-3 | Throughput at concurrency 32 | ≥ 600 output tok/s aggregate |
| AC-4 | Saturation (u=50) | Error rate < 1%; 429s from rate limiter present but bounded; no pod restarts |
| AC-5 | Autoscaling | Request-rate > threshold triggers KEDA scale-up ≤ 120 s; nodes added by Cluster Autoscaler ≤ 300 s |
| AC-6 | GPU utilization | ≥ 85% average during AC-3/AC-4 (DCGM dashboard panel) |
| AC-7 | Security | From a non-allowlisted pod, `curl vllm:8000/v1/models` times out; gateway rejects requests without key (401) |
| AC-8 | Telemetry | Grafana dashboard shows TTFT/TPOT/throughput/GPU panels populated during the test |

## 8. Out of Scope (v1)

- Multi-region failover, model training/fine-tuning pipelines, user-facing web UI,
  GPU time-slicing/MIG multiplexing, private model registries (Hugging Face Enterprise).

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| GPU capacity unavailability in region | Multi-AZ node group + fallback instance families (`g6`, `p4d`) via `gpu_instance_types` |
| vLLM OOM on long contexts | `--max-model-len 8192` cap; KV cache bounded by `--gpu-memory-utilization` |
| LiteLLM DB (virtual keys/spend) ephemeral in demo | `DATABASE_URL` points to SQLite; production: RDS Postgres (module stub in `terraform/`) |
| TTFT regression under batching | Disaggregated prefill / `max-num-seqs` tuning documented in AWS vLLM guide |
