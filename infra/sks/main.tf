locals {
  zone = "bg-sof-1"
  name = "edth-sks"
}

resource "exoscale_security_group" "nodes" {
  name        = "${local.name}-nodes"
  description = "SKS worker nodes"
}

resource "exoscale_security_group_rule" "kubelet" {
  security_group_id      = exoscale_security_group.nodes.id
  type                   = "INGRESS"
  protocol               = "TCP"
  user_security_group_id = exoscale_security_group.nodes.id
  start_port             = 10250
  end_port               = 10250
  description            = "kubelet"
}

resource "exoscale_security_group_rule" "mqtt_nodeport" {
  security_group_id = exoscale_security_group.nodes.id
  type              = "INGRESS"
  protocol          = "TCP"
  cidr              = "0.0.0.0/0"
  start_port        = 31883
  end_port          = 31883
  description       = "mqtt nlb nodeport"
}

resource "exoscale_security_group_rule" "calico_vxlan" {
  security_group_id      = exoscale_security_group.nodes.id
  type                   = "INGRESS"
  protocol               = "UDP"
  user_security_group_id = exoscale_security_group.nodes.id
  start_port             = 4789
  end_port               = 4789
  description            = "calico vxlan"
}

resource "exoscale_sks_cluster" "this" {
  zone          = local.zone
  name          = local.name
  service_level = "starter"
  cni           = "calico"
  version       = "1.37.0"

  exoscale_ccm   = true
  metrics_server = true
  auto_upgrade   = false
}

resource "exoscale_sks_nodepool" "workers" {
  zone          = local.zone
  cluster_id    = exoscale_sks_cluster.this.id
  name          = "workers"
  instance_type = "standard.medium"
  size          = 2

  security_group_ids = [exoscale_security_group.nodes.id]
}

resource "exoscale_sks_kubeconfig" "admin" {
  zone       = local.zone
  cluster_id = exoscale_sks_cluster.this.id

  user                  = "kubernetes-admin"
  groups                = ["system:masters"]
  ttl_seconds           = 7 * 24 * 3600
  early_renewal_seconds = 24 * 3600
}
