output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "virtual_hub_id" {
  value = local.virtual_hub_id
}

output "environments" {
  description = "Per-environment cluster name, advertised transit prefix, and non-routable AKS space"
  value = { for k, m in module.env : k => {
    cluster_name      = m.cluster_name
    transit_cidr      = m.transit_cidr
    aks_internal_cidr = m.aks_internal_cidr
    nva_ilb_ip        = m.nva_ilb_ip
  } }
}

output "nexus_registry" {
  value = local.nexus_fqdn
}

output "ca_cert_file" {
  description = "Private root CA (PEM) to install with az aks update --custom-ca-trust-certificates"
  value       = local_file.ca_cert.filename
}

output "nexus_admin_password" {
  description = "Stand-in Nexus admin password (PoC only)"
  value       = var.create_nexus_standin ? random_password.nexus_admin[0].result : null
  sensitive   = true
}

output "nexus_cidr" {
  description = "Nexus spoke prefix that each environment routes to its transit NVA"
  value       = var.nexus_cidr
}
