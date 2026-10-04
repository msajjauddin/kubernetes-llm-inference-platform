# LLM Inference Platform on AWS EKS

vLLM on GPU nodes, LiteLLM as the gateway, Prometheus/Grafana for observability, all on EKS
and provisioned with Terraform. Full requirements: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).

## Build status

| Layer | Status | Where |
|---|---|---|
| 1. GPU cluster foundation (VPC, EKS, GPU node group, NVIDIA device plugin, Cluster Autoscaler, ECR) | **Done** | `terraform/`, `helm/`, `k8s/namespaces.yaml` |
| 2. vLLM serving + KEDA autoscaling | Next | `k8s/vllm/`, `k8s/autoscaler/` |
| 3. LiteLLM gateway (keys, routing, rate limits) | Planned | `k8s/litellm/`, `litellm/` |
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

Layer 2 adds the trigger: KEDA scales vLLM replicas on request rate, and every replica that doesn't fit
becomes a Pending pod that drives step 3.

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

Everything else should use `nodeSelector: {role: system}`. `terraform output` exposes
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
