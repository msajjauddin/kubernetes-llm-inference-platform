data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = merge(
    {
      Project     = "llm-inference-platform"
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )

  # Labels and taint carried by every GPU node. Later layers (vLLM, DCGM exporter)
  # select on these, so they are exported as outputs too.
  gpu_node_labels = {
    "workload"                      = "gpu-inference"
    "nvidia.com/gpu.present"        = "true"   # NVIDIA device plugin's chart schedules on this label
    "k8s.amazonaws.com/accelerator" = "nvidia" # Cluster Autoscaler treats a node as not-ready until its GPUs are advertised
  }

  gpu_node_taint = {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NoSchedule"
  }
}
