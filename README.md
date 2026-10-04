# LLM Inference Platform on AWS EKS

vLLM on GPU nodes, LiteLLM as the gateway, Prometheus/Grafana for observability, all on EKS
and provisioned with Terraform. Full requirements: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).

## Build status

| Layer | Status | Where |
|---|---|---|
| 1. GPU cluster foundation (VPC, EKS, GPU node group, NVIDIA device plugin, Cluster Autoscaler, ECR) | **Done** | `terraform/`, `helm/`, `k8s/namespaces.yaml` |
| 2. vLLM serving + KEDA autoscaling | **Done** (autoscaling goes live with layer 4's Prometheus) | `helm/vllm/`, `helm/keda.yaml`, `terraform/addons.tf` |
| 3. LiteLLM gateway (keys, routing, rate limits) | Next | `k8s/litellm/`, `litellm/` |
| 4. Observability (Prometheus, Grafana, DCGM exporter, OTel) | Planned | `helm/`, `grafana-dashboards/` |

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
requests are, while running + waiting is exactly how loaded each GPU is. Once LiteLLM is deployed, a
request-rate trigger can be added through `autoscaling.extraTriggers` and KEDA uses whichever asks for more.

**Until Prometheus exists (layer 4)** KEDA can't read the metrics, so it holds vLLM at its current
replica count (fallback `currentReplicasIfHigher`, never below 1). Nothing breaks; it just doesn't scale.
Layer 4 needs to: run a Prometheus Operator Prometheus in `observability` (KEDA queries
`http://prometheus-operated.observability.svc:9090`), and install the chart with
`--set metrics.serviceMonitor.enabled=true` so vLLM gets scraped with `namespace` and `pod` labels.

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
scripts/verify-vllm.sh --load 96 --duration 600   # after layer 4: watch replicas and GPU nodes grow
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
- **No NetworkPolicy yet**: the Service is ClusterIP only; the default-deny and LiteLLM -> vLLM allowlist
  (SEC-1/2) come with the gateway layer.

## Offline checks for the chart

```bash
helm lint helm/vllm
helm template vllm helm/vllm -n llm --kube-version 1.33.0 | kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

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

vLLM's in-cluster endpoint for LiteLLM is `http://vllm.llm.svc:8000/v1`, model `qwen2.5-7b-instruct`. `terraform output` exposes
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
