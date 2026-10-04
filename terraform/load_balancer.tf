# AWS Load Balancer Controller: turns the LiteLLM chart's Ingress into an Application Load Balancer
# (REQUIREMENTS §5 "ALB/Ingress in prod"). The ALB sends traffic straight to gateway pod IPs
# (target-type ip), so it scales with the HPA without a NodePort hop.

module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name = "${var.cluster_name}-aws-lb-controller"

  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/../helm/aws-load-balancer-controller.yaml.tftpl", {
      cluster_name = module.eks.cluster_name
      region       = var.region
      vpc_id       = module.vpc.vpc_id
    })
  ]

  depends_on = [
    module.eks,
    module.aws_lb_controller_pod_identity,
    helm_release.kube_prometheus_stack, # ServiceMonitor CRD
  ]
}
