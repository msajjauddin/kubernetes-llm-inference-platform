output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "gpu_node_group_asg_name" {
  value = one(module.eks.eks_managed_node_groups["gpu"].node_group_autoscaling_group_names)
}

# Scheduling contract for GPU workloads (vLLM Deployment, DCGM exporter DaemonSet).
output "gpu_node_selector" {
  value = { workload = local.gpu_node_labels["workload"] }
}

output "gpu_toleration" {
  value = {
    key      = local.gpu_node_taint.key
    operator = "Exists"
    effect   = local.gpu_node_taint.effect
  }
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
