output "cluster_name" {
  value = azurerm_kubernetes_automatic_cluster.aks.name
}

output "transit_cidr" {
  description = "The only prefix of this environment advertised to vWAN"
  value       = var.transit_cidr
}

output "aks_internal_cidr" {
  value = var.internal_cidr
}

output "aks_vnet_id" {
  value = azurerm_virtual_network.aks.id
}

output "nva_ilb_ip" {
  value = local.nva_ilb_ip
}
