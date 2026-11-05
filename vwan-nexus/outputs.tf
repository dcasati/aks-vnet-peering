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

output "private_destinations" {
  description = "Prefixes each environment routes through its transit NVA (Nexus + on-prem)"
  value       = local.private_destinations
}

output "onprem_sim" {
  description = "Simulated on-prem (create_onprem_sim): echo endpoint, gateway name, prefix"
  value = var.create_onprem_sim ? {
    cidr         = var.onprem_sim_cidr
    echo_url     = "http://${local.onprem_echo_ip}/"
    gateway_name = azurerm_virtual_network_gateway.onprem[0].name
  } : null
}

output "azfw_test" {
  description = "Azure Firewall under test (null unless create_azfw_test)"
  value = var.create_azfw_test ? {
    env        = var.azfw_test_env
    private_ip = local.azfw_private_ip
    subnet     = local.azfw_subnet
  } : null
}
