# LLM Inference Platform on AWS EKS

vLLM on GPU nodes, LiteLLM as the gateway, Prometheus/Grafana for observability, all on EKS
and provisioned with Terraform. Full requirements: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).

## Build status

| Layer | Status | Where |
|---|---|---|
| 1. GPU cluster foundation (VPC, EKS, GPU node group, NVIDIA device plugin, Cluster Autoscaler, ECR) | **Done** | `terraform/`, `helm/`, `k8s/namespaces.yaml` |
| 2. vLLM serving + KEDA autoscaling | **Done** | `helm/vllm/`, `helm/keda.yaml`, `terraform/addons.tf` |
| 3. LiteLLM gateway (keys, routing, rate limits, NetworkPolicies) | **Done** | `helm/litellm/`, `k8s/network/`, `k8s/litellm/` |
| 4. Observability (Prometheus, Grafana, DCGM exporter, alerts) | **Done** (OTel tracing not included) | `terraform/observability.tf`, `helm/kube-prometheus-stack.yaml`, `helm/dcgm-exporter.yaml`, `helm/prometheus-rules/`, `grafana-dashboards/` |

## What layer 1 creates

```
VPC 10.0.0.0/16 (3 AZs, private /19s for nodes + pods, public /24s, 1 NAT)
└── EKS 1.33 (API auth mode, Pod Identity, control-plane logs)
    ├── add-ons: vpc-cni, kube-proxy, coredns, eks-pod-identity-agent, aws-ebs-csi-driver, metrics-server
    ├── node group "system"  m6i/m7i.xlarge  2..4   label role=system
    │     runs CoreDNS, Cluster Autoscaler, (later) LiteLLM, Prometheus, Grafana
    ├── node group "gpu"     g5.xlarge/g6.xlarge  1..6  AL2023 NVIDIA AMI, 200 GiB gp3 root
    │     label workload=gpu-inference, taint nvidia.com/gpu=true:NoSchedule
    │     runs NVIDIA device plugin (advertises nvidia.com/gpu), (later) vLLM, DCGM exporter
    ├── Cluster Autoscaler (Helm, Pod Identity role, least-waste expander)
    ├── default StorageClass gp3 (encrypted)
    └── namespaces llm, observability (Pod Security baseline enforced)
ECR: llm-inference/llm-app (immutable tags, scan on push)
```

## How GPU scaling works

1. A GPU workload (vLLM replica, or the test Deployment below) requests `nvidia.com/gpu: 1`.
2. No GPU node has a free GPU, so the pod goes **Pending**.
3. Cluster Autoscaler sees the pending pod, finds the `gpu` node group (auto-discovered through the
   `k8s.io/cluster-autoscaler/*` tags EKS puts on the ASG), and raises its desired size.
4. The node boots with the NVIDIA AMI, the device plugin advertises its GPU, and the pod schedules.
   The `k8s.amazonaws.com/accelerator` label stops the autoscaler from adding a second node while the
   first is still bringing its GPU online.
5. When load drops and a GPU node has been under 50% requested for 10 minutes, the autoscaler drains
   and removes it, down to `gpu_min_size`.

Layer 2 adds the trigger: KEDA scales vLLM replicas on vLLM's queue depth, and every replica that doesn't
fit becomes a Pending pod that drives step 3 (see [vLLM serving](#vllm-serving-layer-2)).

**Scale to zero.** `gpu_min_size = 1` (the requirement) keeps one model replica warm. Set it to `0`
and the last GPU node goes away when idle; the ASG carries `node-template` tags (label, taint,
`nvidia.com/gpu` count) so the autoscaler can still add the first node from zero. The trade-off is a
cold start of a few minutes (node boot + image pull + model load) on the first request.

## Deploy

Prerequisites: AWS CLI (authenticated), Terraform >= 1.9, kubectl, and GPU quota in the region
(EC2 "Running On-Demand G and VT instances" must allow `gpu_max_size x 4` vCPUs, so 24 for the defaults).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set region, your IP in cluster_endpoint_public_access_cidrs
# optional: cp backend.tf.example backend.tf   # remote state in S3
terraform init
terraform apply                                  # ~20 min

$(terraform output -raw kubeconfig_command)
kubectl apply -k ../k8s                          # namespaces
```

## Verify

```bash
# GPU node is up and advertises its GPU
kubectl get nodes -l workload=gpu-inference \
  -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,GPUS:.status.allocatable.nvidia\\.com/gpu

# CUDA works on it
kubectl apply -f k8s/tests/gpu-smoke-test.yaml
kubectl -n gpu-test logs job/gpu-smoke-test

# Autoscaling: 3 GPU pods -> Cluster Autoscaler adds GPU nodes; then back to 0 and watch them drain
scripts/verify-gpu-scaling.sh 3
kubectl -n kube-system logs deploy/cluster-autoscaler --tail=50
kubectl delete namespace gpu-test
```

## Offline checks (no AWS account)

```bash
cd terraform
terraform init -backend=false
terraform validate
terraform test        # mocked plan: GPU node group, scale-from-zero tags, add-ons
```

## vLLM serving (layer 2)

```
namespace llm
├── Deployment vllm   vllm/vllm-openai:v0.31.0, Qwen/Qwen2.5-7B-Instruct served as "qwen2.5-7b-instruct"
│     1 replica = 1 GPU = 1 GPU node; bf16, max-model-len 8192, gpu-memory-utilization 0.90, prefix caching
│     runs as the image's non-root user (meets PSS restricted); /dev/shm 2Gi; weights cached in emptyDir
├── Service vllm      ClusterIP :8000 (OpenAI API at /v1, Prometheus metrics at /metrics)
├── ScaledObject vllm KEDA -> HPA, 1..6 replicas
└── PodDisruptionBudget vllm  maxUnavailable 1, so Cluster Autoscaler drains one GPU node at a time
namespace keda: KEDA operator + metrics server (Terraform helm_release, system nodes)
```

**Scaling chain.** vLLM exports `vllm:num_requests_running` and `vllm:num_requests_waiting`. KEDA queries
Prometheus every 15 s and targets 24 in-flight requests per replica (and at most 4 queued per replica).
Above that it raises the HPA's desired replicas, at most 2 pods a minute. A new replica can't fit on a
busy GPU node, goes Pending, and Cluster Autoscaler adds a GPU node for it (up to `gpu_max_size`). The
new pod pulls the image and downloads the model, then turns Ready and joins the Service. When load
drops, KEDA waits 10 minutes and removes one replica per 5 minutes; Cluster Autoscaler then removes the
emptied GPU nodes, down to `gpu_min_size`.

Why vLLM's queue rather than gateway request rate (REQUIREMENTS §5): request rate doesn't know how long
requests are, while running + waiting is exactly how loaded each GPU is. The gateway's request rate is
available as an extra trigger in `helm/vllm/values-litellm-trigger.yaml`; KEDA uses whichever asks for more.

KEDA reads these from the layer 4 Prometheus (`http://prometheus-operated.observability.svc:9090`), which
scrapes vLLM through the chart's ServiceMonitor. If Prometheus is unreachable, KEDA holds vLLM at its current
replica count (fallback `currentReplicasIfHigher`, never below 1) and the `KEDAScalerErrors` alert fires.

### Deploy

```bash
cd terraform && terraform apply      # adds KEDA (helm_release.keda) to an existing layer 1 cluster
cd ..
# Optional, only for gated models:  kubectl -n llm create secret generic hf-token --from-literal=token=hf_xxx
helm upgrade --install vllm helm/vllm -n llm
kubectl -n llm logs -f deploy/vllm     # first start: image pull + ~15 GB model download, a few minutes
```

Swap the model with `--set model.name=...,model.servedName=...`; extra vLLM flags go in `model.extraArgs`
(e.g. `["--quantization","fp8"]` as the NFR-9 cost lever). Larger models need a bigger GPU node group.

### Verify

```bash
scripts/verify-vllm.sh                        # health, model list, one chat completion
scripts/verify-vllm.sh --load 96 --duration 600   # watch replicas and GPU nodes grow (Grafana: Inference autoscaling)
kubectl -n llm get scaledobject,hpa vllm
```

### Choices

- **Rolling one replica at a time with `maxSurge: 0`** instead of NFR-4's `Recreate`: same goal (an update
  never needs a spare GPU) but the other replicas keep serving. `strategy.type: Recreate` restores the
  requirement's literal behavior.
- **Weights download per replica** into an emptyDir on the node's 200 GiB disk. Simple and stateless, but
  each scale-out pays the download. If cold start matters, stage the weights in S3 and load them with
  vLLM's `--load-format runai_streamer`, or pre-pull the image with a DaemonSet.
- **Resources** (`2500m` CPU, `10Gi`/`14Gi` memory) fit g5/g6.xlarge next to the node DaemonSets. A pod
  that requests more than the node type offers is never scheduled and Cluster Autoscaler won't add a
  node for it, so revisit these if `gpu_instance_types` changes.
- **NetworkPolicy**: only LiteLLM and the `observability` namespace can reach vLLM (`k8s/network/`, layer 3).

## LiteLLM gateway (layer 3)

```
namespace llm  (default-deny ingress, k8s/network/network-policies.yaml)
├── Deployment litellm         ghcr.io/berriai/litellm-non_root:v1.104.0, 2..6 replicas (HPA on CPU), system nodes
│     spread over AZs, PDB minAvailable 1, runs as UID 65534 (PSS restricted)
├── Service litellm            ClusterIP :4000   OpenAI API /v1, admin API /key/*, /metrics/, /health/*
├── StatefulSet litellm-postgres  Postgres 17, 20Gi gp3: virtual keys, teams, budgets, spend logs
├── Deployment litellm-redis   Redis 7.4, in-memory: cross-replica rate-limit counters, cooldowns, spend buffer
├── Job litellm-metrics-key-N  registers the Prometheus scrape key (one per helm revision)
└── vllm (layer 2)             reachable only from litellm pods and the observability namespace
```

Requests flow client -> `litellm:4000` -> `vllm:8000`. Clients never see vLLM.

| Requirement | How |
|---|---|
| FR-2 auth | Master key (admin only) plus virtual keys from `/key/generate`, stored in Postgres. No key: 401. |
| FR-3 routing | `model_list` entries with the same `model_name` are load-balanced (`simple-shuffle`); 2 retries, a deployment failing 3 times a minute is cooled down for 30 s; `fallbacks` / `context_window_fallbacks` for cross-model failover. Add a second vLLM release under the same name to spread load across both. |
| FR-4 validation | Per-key model allowlist (403), unknown model (400), key limits capped by `upperbound_key_generate_params`, vLLM rejects prompts over `max-model-len`. |
| FR-5 rate limits | Per key `rpm_limit` / `tpm_limit` / `max_parallel_requests` (429 when exceeded), defaults and ceilings in `values.yaml`; `global_max_parallel_requests` per replica. Counters live in Redis, so limits hold across replicas. |
| FR-6 telemetry | Prometheus callback on `/metrics/`: `litellm_proxy_total_requests_metric_total`, `litellm_proxy_failed_requests_metric_total`, `litellm_request_total_latency_metric`, `litellm_llm_api_time_to_first_token_metric`, token counters, `litellm_spend_metric_total`, per key/team/model. |
| FR-16 spend | `model_info` prices tokens from the GPU's hourly cost (~$1/h at ~600 tok/s), so budgets and spend per key mean something. Adjust if your instance type or throughput differs. |
| SEC-1/2/7 | Default-deny ingress in `llm`; allow any pod -> LiteLLM :4000, LiteLLM -> vLLM :8000 / Postgres / Redis, observability -> metrics. Enforced by the VPC CNI (`enableNetworkPolicy`, `terraform/eks.tf`). |
| SEC-5 | Keys live in the `litellm-secrets` Secret, created by a script, never in Git. |

### Deploy

```bash
cd terraform && terraform apply                 # turns on NetworkPolicy enforcement in the vpc-cni add-on
cd ..
kubectl apply -k k8s/                           # namespaces + default-deny + vLLM allowlist
scripts/create-litellm-secrets.sh               # random master/salt/scrape keys and DB/Redis passwords
helm upgrade --install litellm helm/litellm -n llm
kubectl -n llm rollout status deploy/litellm    # first start runs the DB migrations (~30 s)
```

Apply `k8s/` and install the gateway together: once default-deny is in, vLLM only takes traffic from
LiteLLM pods.

### Use it

```bash
kubectl -n llm port-forward svc/litellm 4000:4000 &
MASTER=$(kubectl -n llm get secret litellm-secrets -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)

# A key per team or app, with its own limits and budget
curl -s localhost:4000/key/generate -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -d '{"key_alias": "team-a", "models": ["qwen2.5-7b-instruct"], "rpm_limit": 120, "tpm_limit": 200000, "max_budget": 20}'

# Any OpenAI SDK works: base_url=http://localhost:4000/v1, api_key=<that key>
curl -s localhost:4000/v1/chat/completions -H "Authorization: Bearer sk-..." -H 'Content-Type: application/json' \
  -d '{"model": "qwen2.5-7b-instruct", "messages": [{"role": "user", "content": "Hello"}]}'
```

The admin UI is at `http://localhost:4000/ui` (log in with the master key). Production exposure is an
ALB Ingress with WAF in front of the `litellm` Service (REQUIREMENTS §5); cap request body size there.

### Verify

```bash
scripts/verify-litellm.sh    # health, chat via gateway, 401 without key, 403 wrong model, 429 over rpm,
                             # /metrics needs the scrape token, vLLM unreachable from other pods (AC-1, AC-7)
```

### Choices

- **Postgres in the chart** keeps the stack self-contained. It's one pod on one EBS volume: fine for dev
  and a single cluster, but losing it loses virtual keys. For production use RDS:
  `--set postgres.enabled=false --set externalDatabase.existingSecret=<secret with DATABASE_URL>`.
- **Redis in the chart, no persistence.** Without a shared Redis each replica counts rate limits on its
  own, so a 60 RPM key would really get 60 x replicas. Losing Redis only resets short-lived counters.
  ElastiCache works the same way through `extraEnv` / `config`.
- **`/metrics` needs a key.** LiteLLM's metrics carry key aliases, teams and spend, and port 4000 is open
  to the whole cluster. The chart registers `LITELLM_METRICS_TOKEN` as a virtual key allowed only
  `/metrics`, and the ServiceMonitor scrapes with it. `metrics.requireAuth=false` opens it instead.
- **One worker per pod**, scaled by replicas: multiple uvicorn workers would need Prometheus
  multiprocess mode to keep `/metrics` correct.
- **Gateway HPA on CPU** (FR-11): the gateway itself is light; GPU capacity follows vLLM's queue via KEDA.
- **Request size limits** (`max_request_size_mb`) are LiteLLM Enterprise only, so they belong on the ALB/WAF.
- **Models in the config file** (`store_model_in_db: false`): model routing changes go through Git and
  `helm upgrade`, not the admin UI.

## Observability (layer 4)

```
namespace observability  (Terraform: terraform/observability.tf)
├── kube-prometheus-stack "monitoring"   helm/kube-prometheus-stack.yaml, system nodes
│   ├── Prometheus Operator              selects ServiceMonitors / PrometheusRules in all namespaces
│   ├── Prometheus                       15 s scrapes, 7-day retention on a 50 GiB gp3 PVC (NFR-6)
│   │                                    svc prometheus-operated:9090  <- KEDA (vLLM autoscaling)
│   ├── Alertmanager                     2 GiB PVC, no receivers configured yet
│   ├── Grafana                          svc monitoring-grafana:80, dashboards from ConfigMaps
│   └── kube-state-metrics               replicas, HPA, Pending pods, node labels (workload, instance type)
├── PrometheusRule llm-platform          helm/prometheus-rules/llm-platform.yaml
└── ConfigMaps grafana-dashboard-*       one per grafana-dashboards/*.json, folder "LLM Platform"
namespace kube-system
├── node-exporter DaemonSet              all nodes, GPU nodes included
└── dcgm-exporter DaemonSet              GPU nodes only (helm/dcgm-exporter.yaml)
```

What gets scraped:

| Source | How | Used for |
|---|---|---|
| vLLM `/metrics` | ServiceMonitor in `helm/vllm` (on by default) | TTFT, TPOT, throughput, queue, KV cache; KEDA's triggers |
| LiteLLM `/metrics/` | ServiceMonitor in `helm/litellm`, bearer `LITELLM_METRICS_TOKEN` | requests, errors, latency, tokens, spend per key/team |
| DCGM exporter | its chart's ServiceMonitor | GPU utilization, tensor activity, memory, power, temperature, XID, which pod holds each GPU |
| KEDA | `helm/keda.yaml` ServiceMonitors | scaler values and errors |
| Cluster Autoscaler | `helm/cluster-autoscaler.yaml.tftpl` ServiceMonitor | unschedulable pods, nodes added/removed |
| Kubernetes | kube-state-metrics, kubelet/cAdvisor, node-exporter | replicas, Pending pods, CPU/memory (FR-10 resource use) |

Dashboards (Grafana folder **LLM Platform**, all tagged `llm-platform`):

| Dashboard | Shows | Requirement |
|---|---|---|
| vLLM inference | TTFT and TPOT p50/p90/p99 with NFR-1 targets, output tokens/s per GPU, finished requests, running/waiting, KV cache, prefix-cache hit rate, preemptions | NFR-1, NFR-2, FR-14, AC-2, AC-3, AC-8 |
| GPU (DCGM) | utilization against the 85% target, tensor/SM/memory-bandwidth activity, memory, power, temperature, clocks, XID, GPU-to-pod table | AC-6 |
| LiteLLM gateway | requests by status code, 5xx and 429 rates, failures by exception, latency, TTFT through the gateway, tokens, spend by team, usage per key | FR-6, FR-16, AC-4 |
| Inference autoscaling | the whole chain: in-flight per replica vs KEDA's targets, desired/ready/Pending replicas, GPU nodes by instance type, Cluster Autoscaler activity, KEDA errors | FR-11, NFR-5, AC-5 |

Alerts (`helm/prometheus-rules/llm-platform.yaml`, on top of the chart's Kubernetes and node rules):
`VLLMUnavailable`, `VLLMTimeToFirstTokenHigh` (p99 > 800 ms), `VLLMTimePerOutputTokenHigh` (p50 > 60 ms),
`VLLMKVCacheSaturated`, `VLLMCapacityExhausted` (at max replicas and still queueing),
`VLLMReplicaPendingTooLong` (no GPU node after 10 min), `LiteLLMUnavailable`, `LiteLLMServerErrorRateHigh`
(5xx > 1%; 401/429 don't count), `LiteLLMDeploymentDown`, `GPUMetricsMissing`, `GPUTemperatureHigh`, `GPUXidError`,
`GPUFleetIdle` (info, cost), `KEDAScalerErrors` (autoscaling blind), `ClusterAutoscalerUnschedulablePods`.

### Deploy

```bash
cd terraform && terraform apply      # kube-prometheus-stack, DCGM exporter, alerts, dashboards; KEDA and
cd ..                                # Cluster Autoscaler pick up their ServiceMonitors
helm upgrade --install vllm helm/vllm -n llm          # ServiceMonitors are now on by default
helm upgrade --install litellm helm/litellm -n llm
scripts/verify-observability.sh      # targets up, KEDA reading metrics, dashboards present, alerts loaded
```

On a cluster built before this layer, the same `terraform apply` adds it; the two `helm upgrade`s turn on the
ServiceMonitors (or add `--reuse-values --set metrics.serviceMonitor.enabled=true` if you keep old values).

### Open Grafana

```bash
kubectl -n observability port-forward svc/monitoring-grafana 3000:80
kubectl -n observability get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
# http://localhost:3000, user admin -> Dashboards -> LLM Platform
kubectl -n observability port-forward svc/prometheus-operated 9090   # Prometheus UI, alerts at /alerts
```

The chart generates the admin password on first install and keeps it across upgrades. For production put
Grafana behind an ALB Ingress with SSO (`grafana.ini` `auth.generic_oauth`) rather than port-forwarding.

### Watching a load test (AC-5, AC-6, AC-8)

Run `scripts/verify-vllm.sh --load 96 --duration 600` and open **Inference autoscaling**: in-flight per
replica crosses 24, desired replicas rise within a polling interval, the new replica shows as Pending until
Cluster Autoscaler's node joins, then ready. **GPU (DCGM)** shows utilization per GPU against the 85% line,
and **vLLM inference** shows TTFT/TPOT against the NFR-1 targets.

### Choices

- **Prometheus, Alertmanager and Grafana come from Terraform**, like KEDA, because KEDA's autoscaling and the
  ServiceMonitors in every other chart depend on them. Dashboards are ConfigMaps from `grafana-dashboards/*.json`;
  edit the JSON (or export from Grafana) and `terraform apply`. UI edits are not saved (`allowUiUpdates: false`).
- **Exporters with host access live in `kube-system`.** node-exporter needs hostNetwork/hostPID and the DCGM
  exporter needs a hostPath (kubelet pod-resources, to map GPUs to pods) and `SYS_ADMIN` (profiling counters).
  The `observability` namespace enforces Pod Security `baseline`, which forbids those, and stays that way.
- **No control-plane scraping.** EKS hides the scheduler, controller manager and etcd, and kube-proxy only
  serves metrics on localhost, so those jobs and their default alerts are off instead of permanently down.
- **One Prometheus replica.** Enough for one cluster and 7 days. If KEDA must keep scaling through a Prometheus
  restart, set `prometheus.prometheusSpec.replicas: 2`; the vLLM fallback already prevents scale-in while it's away.
- **Alertmanager has no receivers.** Alerts show in Prometheus, Alertmanager and Grafana. Add a Slack or
  PagerDuty receiver with its URL in a Secret, not in Git.
- **Not included: OpenTelemetry tracing** (REQUIREMENTS §5). Metrics cover FR-10 and the AC-8 panels; there is no
  FastAPI sample client to trace yet. An OTel Collector with the spanmetrics connector can be added later and
  pointed at this Prometheus.

## Offline checks for the charts

```bash
helm lint helm/vllm helm/litellm
for c in vllm litellm; do
  helm template $c helm/$c -n llm --kube-version 1.33.0 | kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
done
kubeconform -strict -summary k8s/namespaces.yaml k8s/network/

# Observability: alert rules and their unit tests, and the upstream charts with our values
promtool check rules helm/prometheus-rules/llm-platform.yaml
promtool test rules helm/prometheus-rules/tests.yaml
helm template monitoring prometheus-community/kube-prometheus-stack --version 91.9.0 -n observability \
  --kube-version 1.33.0 -f helm/kube-prometheus-stack.yaml | kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

The dashboards' queries and the KEDA queries were also run against a local Prometheus 3.6 scraping synthetic
vLLM 0.31, LiteLLM 1.104, DCGM, kube-state-metrics, KEDA and Cluster Autoscaler metrics (metric and label names
taken from those projects' source at the pinned versions); every panel returned data.

The LiteLLM config was also run for real (LiteLLM 1.104.0 with local Postgres and Redis and a stub
OpenAI server in place of vLLM) to check auth, routing, streaming, per-key 429s, the scrape key and
`/metrics`; `scripts/verify-litellm.sh` passed against it.

## Contract for later layers

GPU workloads must carry:

```yaml
nodeSelector:
  workload: gpu-inference
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
resources:
  limits:
    nvidia.com/gpu: 1
```

Everything else should use `nodeSelector: {role: system}`.

vLLM's in-cluster endpoint for LiteLLM is `http://vllm.llm.svc:8000/v1`, model `qwen2.5-7b-instruct`.
Clients use the gateway at `http://litellm.llm.svc:4000/v1`.

Prometheus (layer 4) selects every ServiceMonitor, PodMonitor and PrometheusRule in the cluster, whatever
its labels, so a new workload only needs a ServiceMonitor to be scraped, and a ConfigMap labelled
`grafana_dashboard: "1"` to add a dashboard. The vLLM and LiteLLM charts create their ServiceMonitors by
default. Optionally add `helm/vllm/values-litellm-trigger.yaml` for the request-rate KEDA trigger.
`terraform output` exposes
`gpu_node_selector`, `gpu_toleration`, `ecr_repository_urls`, `node_security_group_id` and the
cluster details for scripts and CI.

## Notes and choices

- **Cluster Autoscaler, not Karpenter**, because the requirements name it (FR-11, NFR-5, §5).
  Karpenter would provision faster and pick instance types per pod; swapping it in later only touches
  `terraform/addons.tf`, `terraform/iam.tf` and the node group definition.
- **EKS 1.33** is what the requirements specify. Check it is still in standard support in your region
  when you apply; extended support costs about 6x more per cluster-hour. Bumping it means changing
  `kubernetes_version` and `cluster_autoscaler_image_tag` together.
- **Mixed GPU types** (`g5.xlarge`, `g6.xlarge`) in one group improve capacity availability; both have one
  24 GB GPU, which keeps the autoscaler's capacity math correct. Don't mix in multi-GPU types.
- **Cost:** the GPU node (~$1/h for g5.xlarge on demand) dominates. `single_nat_gateway = true` saves
  ~$65/month per extra AZ; flip it off for production.
- **Security:** API endpoint is public by default but restricted by `cluster_endpoint_public_access_cidrs`;
  node roles carry only AWS-managed worker policies; add-ons get AWS access only via Pod Identity.
