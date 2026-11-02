# =============================================================================
# Managed Identity & Network Contributor Role for AKS Automatic BYO VNet
# =============================================================================
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-automatic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "aks_vnet_contributor" {
  scope                = azurerm_virtual_network.aks_vnet.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_role_assignment" "aks_rt_contributor" {
  scope                = azurerm_route_table.aks_to_remote_rt.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# =============================================================================
# AKS Automatic Cluster in Custom VNet
# =============================================================================
resource "azurerm_kubernetes_automatic_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  api_server_access {
    subnet_id = azurerm_subnet.aks_api.id
  }

  hosted_system {
    system_node_subnet_id = azurerm_subnet.aks_system_nodes.id
    node_subnet_id        = azurerm_subnet.aks_user_nodes.id
  }

  depends_on = [
    azurerm_role_assignment.aks_vnet_contributor,
    azurerm_role_assignment.aks_rt_contributor,
    azurerm_subnet_nat_gateway_association.user_nodes_nat,
    azurerm_subnet_nat_gateway_association.system_nodes_nat,
    azurerm_subnet_route_table_association.user_nodes_rt_assoc,
  ]
}

# Grant the current Terraform caller RBAC Cluster Admin on the AKS Automatic cluster
resource "azurerm_role_assignment" "current_user_aks_admin" {
  scope                = azurerm_kubernetes_automatic_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

