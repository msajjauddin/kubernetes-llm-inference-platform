# In-cluster add-ons that the GPU layer depends on. Later layers (vLLM, LiteLLM,
# observability) are deployed from k8s/ and helm/, not from Terraform.

# Default StorageClass for PVCs (Prometheus, LiteLLM DB, model cache).
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

# Advertises nvidia.com/gpu on GPU nodes so pods can request GPUs.
resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = var.nvidia_device_plugin_chart_version
  namespace  = "kube-system"

  values = [file("${path.module}/../helm/nvidia-device-plugin.yaml")]

  depends_on = [module.eks]
}

# Adds GPU nodes when vLLM pods are Pending for lack of nvidia.com/gpu, and removes
# them once they sit idle. Credentials come from cluster_autoscaler_pod_identity.
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/../helm/cluster-autoscaler.yaml.tftpl", {
      cluster_name = module.eks.cluster_name
      region       = var.region
      image_tag    = var.cluster_autoscaler_image_tag
    })
  ]

  depends_on = [
    module.eks,
    module.cluster_autoscaler_pod_identity,
    aws_autoscaling_group_tag.gpu_node_template,
  ]
}

# Event-driven pod autoscaling (FR-11). The vLLM chart's ScaledObject (helm/vllm) scales
# replicas on vLLM queue depth from Prometheus; replicas that don't fit become Pending
# pods, which Cluster Autoscaler answers with GPU nodes.
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_chart_version
  namespace        = "keda"
  create_namespace = true

  values = [file("${path.module}/../helm/keda.yaml")]

  depends_on = [module.eks]
}
