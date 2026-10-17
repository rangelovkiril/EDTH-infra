output "kubeconfig" {
  value     = exoscale_sks_kubeconfig.admin.kubeconfig
  sensitive = true
}

output "endpoint" {
  value = exoscale_sks_cluster.this.endpoint
}
