# Observability (layer 4): Prometheus, Alertmanager and Grafana (kube-prometheus-stack), GPU metrics
# (DCGM exporter), the LLM platform alerts and the Grafana dashboards. Prometheus is also the
# signal source for vLLM autoscaling: KEDA queries it, so it is installed with the cluster
# add-ons rather than with the workloads.

# Same labels as k8s/namespaces.yaml, created here because the Helm releases below need it before
# `kubectl apply -k k8s/` runs. Applying k8s/ afterwards changes nothing.
resource "kubernetes_namespace_v1" "observability" {
  metadata {
    name = "observability"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }

  lifecycle {
    # kubectl apply -k adds its last-applied annotation.
    ignore_changes = [metadata[0].annotations]
  }

  depends_on = [module.eks]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name

  values = [
    file("${path.module}/../helm/kube-prometheus-stack.yaml"),
    # Alert rules live in their own file so `promtool test rules` can check them offline.
    yamlencode({
      additionalPrometheusRulesMap = {
        "llm-platform" = yamldecode(file("${path.module}/../helm/prometheus-rules/llm-platform.yaml"))
      }
    }),
  ]

  # The CRDs and webhook take a while on a fresh cluster; Prometheus' PVC binds on first schedule.
  timeout = 900

  depends_on = [
    module.eks,
    kubernetes_storage_class_v1.gp3,
  ]
}

# GPU metrics on every GPU node. Its ServiceMonitor needs the CRDs from the release above.
resource "helm_release" "dcgm_exporter" {
  name       = "dcgm-exporter"
  repository = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart      = "dcgm-exporter"
  version    = var.dcgm_exporter_chart_version
  namespace  = "kube-system"

  values = [file("${path.module}/../helm/dcgm-exporter.yaml")]

  # A DaemonSet on GPU nodes only: with gpu_min_size = 0 there may be none, which is fine.
  wait = false

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.nvidia_device_plugin,
  ]
}

# One ConfigMap per dashboard in grafana-dashboards/. Grafana's sidecar loads every ConfigMap
# labelled grafana_dashboard=1 into the folder named by the grafana_folder annotation.
resource "kubernetes_config_map_v1" "grafana_dashboard" {
  for_each = fileset("${path.module}/../grafana-dashboards", "*.json")

  metadata {
    name      = "grafana-dashboard-${trimsuffix(each.value, ".json")}"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "LLM Platform"
    }
  }

  data = {
    (each.value) = file("${path.module}/../grafana-dashboards/${each.value}")
  }
}
