resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# =============================================================================
# 1. AKS Virtual Network (Dual Address Space: Small Routable + Non-Peered CGNAT)
# =============================================================================
resource "azurerm_virtual_network" "aks_vnet" {
  name                = "vnet-aks-automatic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space = [
    var.aks_vnet_peered_cidr,
    var.aks_vnet_internal_cidr,
  ]
}

# Subnet 1: API Server VNet Integration (Non-peered CGNAT space)
resource "azurerm_subnet" "aks_api" {
  name                 = "snet-aks-api"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = [var.aks_api_subnet_cidr]

  delegation {
    name = "aks-api-delegation"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnet 2: Managed System Nodes (Non-peered CGNAT space)
resource "azurerm_subnet" "aks_system_nodes" {
  name                 = "snet-aks-system"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = [var.aks_system_node_subnet_cidr]

  lifecycle {
    ignore_changes = [delegation]
  }
}

# Subnet 3: User Nodes (/24 required by AKS Automatic, Non-peered CGNAT space)
resource "azurerm_subnet" "aks_user_nodes" {
  name                 = "snet-aks-user-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = [var.aks_user_node_subnet_cidr]
}

# Subnet 4: IP Masquerade / NAT VMSS (Routable space, Peered with Remote VNet)
resource "azurerm_subnet" "nat_masquerade" {
  name                 = "snet-nat-masquerade"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = [var.nat_subnet_cidr]
}

# =============================================================================
# 2. NAT Gateway for Outbound Internet Access (Image Pulls & Package Installs)
# =============================================================================
resource "azurerm_public_ip" "nat_gw_pip" {
  name                = "pip-nat-gateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "aks_nat_gw" {
  name                = "ngw-aks-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "aks_nat_gw_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.aks_nat_gw.id
  public_ip_address_id = azurerm_public_ip.nat_gw_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "user_nodes_nat" {
  subnet_id      = azurerm_subnet.aks_user_nodes.id
  nat_gateway_id = azurerm_nat_gateway.aks_nat_gw.id
}

resource "azurerm_subnet_nat_gateway_association" "system_nodes_nat" {
  subnet_id      = azurerm_subnet.aks_system_nodes.id
  nat_gateway_id = azurerm_nat_gateway.aks_nat_gw.id
}

resource "azurerm_subnet_nat_gateway_association" "masquerade_nat" {
  subnet_id      = azurerm_subnet.nat_masquerade.id
  nat_gateway_id = azurerm_nat_gateway.aks_nat_gw.id
}

# =============================================================================
# 3. Remote Peered Virtual Network
# =============================================================================
resource "azurerm_virtual_network" "remote_vnet" {
  name                = "vnet-remote-services"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.remote_vnet_cidr]
}

resource "azurerm_subnet" "remote_api" {
  name                 = "snet-remote-api"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.remote_vnet.name
  address_prefixes     = [var.remote_api_subnet_cidr]
}

# =============================================================================
# 4. Subnet Peering (Only peer snet-nat-masquerade <-> snet-remote-api)
# =============================================================================
# NOTE: Requires feature `AllowSubnetPeering` registered under Microsoft.Network:
#   az feature register --namespace Microsoft.Network --name AllowSubnetPeering
#   az provider register --namespace Microsoft.Network
resource "azurerm_virtual_network_peering" "aks_to_remote" {
  name                                   = "peer-aks-nat-to-remote"
  resource_group_name                    = azurerm_resource_group.rg.name
  virtual_network_name                   = azurerm_virtual_network.aks_vnet.name
  remote_virtual_network_id              = azurerm_virtual_network.remote_vnet.id
  allow_virtual_network_access           = true
  allow_forwarded_traffic                = true
  peer_complete_virtual_networks_enabled = false

  local_subnet_names  = [azurerm_subnet.nat_masquerade.name]
  remote_subnet_names = [azurerm_subnet.remote_api.name]
}

resource "azurerm_virtual_network_peering" "remote_to_aks" {
  name                                   = "peer-remote-to-aks-nat"
  resource_group_name                    = azurerm_resource_group.rg.name
  virtual_network_name                   = azurerm_virtual_network.remote_vnet.name
  remote_virtual_network_id              = azurerm_virtual_network.aks_vnet.id
  allow_virtual_network_access           = true
  allow_forwarded_traffic                = true
  peer_complete_virtual_networks_enabled = false

  local_subnet_names  = [azurerm_subnet.remote_api.name]
  remote_subnet_names = [azurerm_subnet.nat_masquerade.name]
}

# =============================================================================
# 5. User-Defined Route (UDR) for AKS Subnets -> Internal Load Balancer
# =============================================================================
resource "azurerm_route_table" "aks_to_remote_rt" {
  name                = "rt-aks-to-remote-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  route {
    name                   = "route-to-peered-vnet-via-nat-vmss"
    address_prefix         = var.remote_vnet_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_lb.nat_ilb.frontend_ip_configuration[0].private_ip_address
  }

  route {
    name                   = "route-to-peered-api-subnet-via-nat-vmss"
    address_prefix         = var.remote_api_subnet_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_lb.nat_ilb.frontend_ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "user_nodes_rt_assoc" {
  subnet_id      = azurerm_subnet.aks_user_nodes.id
  route_table_id = azurerm_route_table.aks_to_remote_rt.id
}

resource "azurerm_subnet_route_table_association" "system_nodes_rt_assoc" {
  subnet_id      = azurerm_subnet.aks_system_nodes.id
  route_table_id = azurerm_route_table.aks_to_remote_rt.id
}

