module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.26"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Whoever runs `terraform apply` gets cluster-admin via an EKS access entry.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  enabled_log_types = ["api", "audit", "authenticator"]

  # Workloads get AWS credentials through EKS Pod Identity (SEC-4), not IRSA.
  enable_irsa = false

  addons = {
    vpc-cni = {
      before_compute = true
      # Enforce Kubernetes NetworkPolicies (k8s/network, helm/litellm) with the CNI's eBPF agent.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns = {
      configuration_values = jsonencode({
        nodeSelector = { role = "system" }
      })
    }
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    # Feeds `kubectl top` and CPU-based HPAs.
    metrics-server = {
      configuration_values = jsonencode({
        nodeSelector = { role = "system" }
      })
    }
  }

  eks_managed_node_groups = {
    # CPU nodes for everything that is not model serving.
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.system_min_size
      max_size     = var.system_max_size
      desired_size = var.system_desired_size

      labels = {
        role = "system"
      }
    }

    # GPU nodes for vLLM. The EKS-optimized AL2023 NVIDIA AMI ships the driver and
    # container toolkit; the device plugin (addons.tf) advertises nvidia.com/gpu.
    # Cluster Autoscaler grows this group when GPU pods are Pending and shrinks it when idle.
    gpu = {
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = var.gpu_instance_types
      capacity_type  = var.gpu_capacity_type

      min_size     = var.gpu_min_size
      max_size     = var.gpu_max_size
      desired_size = var.gpu_desired_size

      labels = local.gpu_node_labels

      # Keeps non-GPU pods off expensive nodes; vLLM and GPU DaemonSets tolerate it.
      taints = {
        gpu = {
          key    = local.gpu_node_taint.key
          value  = local.gpu_node_taint.value
          effect = "NO_SCHEDULE"
        }
      }

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.gpu_root_volume_size
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 250
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      update_config = {
        max_unavailable = 1
      }
    }
  }
}

# Managed node groups already carry the Cluster Autoscaler auto-discovery tags.
# These extra "node-template" tags describe what a GPU node will look like, so the
# autoscaler can add the first node even when the group is at zero (gpu_min_size = 0).
locals {
  gpu_asg_node_template_tags = merge(
    { for k, v in local.gpu_node_labels : "k8s.io/cluster-autoscaler/node-template/label/${k}" => v },
    {
      "k8s.io/cluster-autoscaler/node-template/taint/${local.gpu_node_taint.key}" = "${local.gpu_node_taint.value}:${local.gpu_node_taint.effect}"
      "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"          = tostring(var.gpu_count_per_node)
    },
  )
}

resource "aws_autoscaling_group_tag" "gpu_node_template" {
  for_each = local.gpu_asg_node_template_tags

  autoscaling_group_name = one(module.eks.eks_managed_node_groups["gpu"].node_group_autoscaling_group_names)

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = false
  }
}
