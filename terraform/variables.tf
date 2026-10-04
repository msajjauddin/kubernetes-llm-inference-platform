variable "region" {
  description = "AWS region. Pick one with g5 capacity (us-east-1, us-west-2, eu-west-1 are safe bets)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the prefix for most other resources."
  type        = string
  default     = "llm-inference"
}

variable "kubernetes_version" {
  description = "EKS control plane version. Keep the Cluster Autoscaler image tag on the same minor."
  type        = string
  default     = "1.33"
}

variable "environment" {
  description = "Environment tag (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Extra tags applied to every AWS resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets (and GPU nodes) across."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheap) instead of one per AZ (HA). Set false for production."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Narrow this to your office/VPN range."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# System node group (CoreDNS, Cluster Autoscaler, LiteLLM, Prometheus, ...)
# ---------------------------------------------------------------------------

variable "system_instance_types" {
  description = "Instance types for the CPU node group that runs platform add-ons and the gateway."
  type        = list(string)
  default     = ["m6i.xlarge", "m7i.xlarge"]
}

variable "system_min_size" {
  type    = number
  default = 2
}

variable "system_max_size" {
  type    = number
  default = 4
}

variable "system_desired_size" {
  type    = number
  default = 2
}

# ---------------------------------------------------------------------------
# GPU node group (vLLM)
# ---------------------------------------------------------------------------

variable "gpu_instance_types" {
  description = <<-EOT
    GPU instance types, in order of preference. All types in one node group must expose the
    same number of GPUs (gpu_count_per_node) so Cluster Autoscaler can plan capacity correctly.
    g5.xlarge = 1x A10G 24 GB, g6.xlarge = 1x L4 24 GB.
  EOT
  type        = list(string)
  default     = ["g5.xlarge", "g6.xlarge"]
}

variable "gpu_count_per_node" {
  description = "GPUs per node for the instance types above. Used for Cluster Autoscaler scale-from-zero hints."
  type        = number
  default     = 1
}

variable "gpu_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot GPUs are much cheaper but can be reclaimed mid-request."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.gpu_capacity_type)
    error_message = "gpu_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "gpu_min_size" {
  description = "Minimum GPU nodes. 1 keeps one model replica warm; 0 lets the platform scale GPU spend to zero when idle."
  type        = number
  default     = 1
}

variable "gpu_max_size" {
  description = "Maximum GPU nodes Cluster Autoscaler may add."
  type        = number
  default     = 6
}

variable "gpu_desired_size" {
  description = "Initial GPU node count. Only used at creation; Cluster Autoscaler owns it afterwards."
  type        = number
  default     = 1
}

variable "gpu_root_volume_size" {
  description = "Root volume (GiB) for GPU nodes. vLLM images are ~10 GB and 7B weights ~15 GB, so keep headroom."
  type        = number
  default     = 200
}

# ---------------------------------------------------------------------------
# Add-ons
# ---------------------------------------------------------------------------

variable "cluster_autoscaler_chart_version" {
  type    = string
  default = "9.59.0"
}

variable "cluster_autoscaler_image_tag" {
  description = "Must match the Kubernetes minor version (kubernetes_version)."
  type        = string
  default     = "v1.33.6"
}

variable "nvidia_device_plugin_chart_version" {
  type    = string
  default = "0.20.1"
}

variable "ecr_repositories" {
  description = "ECR repositories to create for images built by CI."
  type        = list(string)
  default     = ["llm-app"]
}
