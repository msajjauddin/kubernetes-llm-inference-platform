# Offline plan test: no AWS account needed.  Run with `terraform test` after `terraform init -backend=false`.
# Checks the GPU scaling contract that later layers rely on.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:user/terraform"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}

run "gpu_node_group_scales_with_cluster_autoscaler" {
  command = plan

  assert {
    condition     = module.eks.eks_managed_node_groups["gpu"] != null
    error_message = "GPU node group missing"
  }

  assert {
    condition     = aws_autoscaling_group_tag.gpu_node_template["k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"].tag[0].value == "1"
    error_message = "Scale-from-zero GPU resource hint missing"
  }

  assert {
    condition     = aws_autoscaling_group_tag.gpu_node_template["k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"].tag[0].value == "true:NoSchedule"
    error_message = "Scale-from-zero GPU taint hint wrong"
  }

  assert {
    condition     = length(module.vpc.private_subnets) == 3
    error_message = "Expected one private subnet per AZ"
  }

  assert {
    condition     = helm_release.cluster_autoscaler.chart == "cluster-autoscaler" && helm_release.nvidia_device_plugin.chart == "nvidia-device-plugin"
    error_message = "GPU add-ons not planned"
  }

  assert {
    condition     = helm_release.keda.chart == "keda" && helm_release.keda.namespace == "keda"
    error_message = "KEDA (pod autoscaling for vLLM) not planned"
  }
}

run "gpu_can_scale_to_zero" {
  command = plan

  variables {
    gpu_min_size     = 0
    gpu_desired_size = 0
  }

  assert {
    condition     = var.gpu_min_size == 0
    error_message = "gpu_min_size = 0 should be accepted"
  }
}

run "observability_feeds_autoscaling_and_dashboards" {
  command = plan

  assert {
    condition     = helm_release.kube_prometheus_stack.namespace == "observability" && helm_release.kube_prometheus_stack.chart == "kube-prometheus-stack"
    error_message = "Prometheus must run in observability: KEDA queries prometheus-operated.observability.svc"
  }

  assert {
    condition     = strcontains(helm_release.kube_prometheus_stack.values[1], "VLLMReplicaPendingTooLong")
    error_message = "LLM platform alert rules not passed to Prometheus"
  }

  assert {
    condition     = helm_release.dcgm_exporter.namespace == "kube-system"
    error_message = "DCGM exporter needs hostPath + SYS_ADMIN, which the observability namespace's PSS baseline forbids"
  }

  assert {
    condition     = toset(keys(kubernetes_config_map_v1.grafana_dashboard)) == toset(["autoscaling.json", "gpu.json", "litellm.json", "vllm.json"])
    error_message = "Expected one Grafana dashboard ConfigMap per file in grafana-dashboards/"
  }
}
