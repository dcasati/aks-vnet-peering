locals {
  internal_len = tonumber(split("/", var.internal_cidr)[1])

  aks_api_subnet_cidr    = cidrsubnet(var.internal_cidr, 28 - local.internal_len, 0) # x.x.0.0/28
  aks_system_subnet_cidr = cidrsubnet(var.internal_cidr, 26 - local.internal_len, 1) # x.x.0.64/26
  aks_user_subnet_cidr   = cidrsubnet(var.internal_cidr, 24 - local.internal_len, 1) # x.x.1.0/24

  nva_ilb_ip = cidrhost(var.transit_cidr, 4)
}

# =============================================================================
# 1. Transit VNet (routable /28) - the ONLY VNet of this environment connected to vWAN
# =============================================================================
resource "azurerm_virtual_network" "transit" {
  name                = "vnet-${var.name}-transit"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.transit_cidr]
}

resource "azurerm_subnet" "nva" {
  name                 = "snet-nva"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [var.transit_cidr]
}

resource "azurerm_virtual_hub_connection" "transit" {
  name                      = "conn-${var.name}-transit"
  virtual_hub_id            = var.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.transit.id
  internet_security_enabled = false
}

# =============================================================================
# 2. AKS VNet (non-routable) - never connected to the hub, only peered to its transit VNet
# =============================================================================
resource "azurerm_virtual_network" "aks" {
  name                = "vnet-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.internal_cidr]
}

resource "azurerm_subnet" "aks_api" {
  name                 = "snet-aks-api"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.aks_api_subnet_cidr]

  delegation {
    name = "aks-api-delegation"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "aks_system" {
  name                 = "snet-aks-system"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.aks_system_subnet_cidr]

  lifecycle {
    ignore_changes = [delegation]
  }
}

resource "azurerm_subnet" "aks_user" {
  name                 = "snet-aks-user-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.aks_user_subnet_cidr]
}

# Plain VNet peering AKS <-> transit. vWAN does not propagate the AKS prefix (peering is non-transitive),
# so the hub only ever learns the transit /28.
resource "azurerm_virtual_network_peering" "aks_to_transit" {
  name                         = "peer-${var.name}-aks-to-transit"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.aks.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "transit_to_aks" {
  name                         = "peer-${var.name}-transit-to-aks"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.aks.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# =============================================================================
# 3. Internet egress for AKS (control plane deps, MCR, etc.) - not via the hub
# =============================================================================
resource "azurerm_public_ip" "natgw" {
  name                = "pip-${var.name}-natgw"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "aks" {
  name                = "ngw-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "aks" {
  nat_gateway_id       = azurerm_nat_gateway.aks.id
  public_ip_address_id = azurerm_public_ip.natgw.id
}

resource "azurerm_subnet_nat_gateway_association" "aks_system" {
  subnet_id      = azurerm_subnet.aks_system.id
  nat_gateway_id = azurerm_nat_gateway.aks.id
}

resource "azurerm_subnet_nat_gateway_association" "aks_user" {
  subnet_id      = azurerm_subnet.aks_user.id
  nat_gateway_id = azurerm_nat_gateway.aks.id
}

# =============================================================================
# 4. UDR: private destinations (Nexus, on-prem) -> NVA internal LB in the peered transit VNet
# =============================================================================
resource "azurerm_route_table" "aks" {
  name                = "rt-${var.name}-aks-to-nexus"
  location            = var.location
  resource_group_name = var.resource_group_name

  dynamic "route" {
    for_each = var.destination_cidrs
    content {
      name                   = "via-transit-nva-${replace(route.value, "/[./]/", "-")}"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = coalesce(var.next_hop_override, local.nva_ilb_ip)
    }
  }
}

resource "azurerm_subnet_route_table_association" "aks_system" {
  subnet_id      = azurerm_subnet.aks_system.id
  route_table_id = azurerm_route_table.aks.id
}

resource "azurerm_subnet_route_table_association" "aks_user" {
  subnet_id      = azurerm_subnet.aks_user.id
  route_table_id = azurerm_route_table.aks.id
}

# =============================================================================
# 5. SNAT NVA (ILB HA ports + Linux VMSS) in the transit VNet
# =============================================================================
resource "azurerm_lb" "nva" {
  name                = "ilb-${var.name}-nva"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "fe-nva"
    subnet_id                     = azurerm_subnet.nva.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_ilb_ip
    zones                         = length(var.nva_zones) > 0 ? var.nva_zones : null
  }
}

resource "azurerm_lb_backend_address_pool" "nva" {
  loadbalancer_id = azurerm_lb.nva.id
  name            = "bepool-nva"
}

# HTTP probe served by the NVA itself; returns 200 only when forwarding + SNAT are configured.
resource "azurerm_lb_probe" "nva" {
  loadbalancer_id     = azurerm_lb.nva.id
  name                = "probe-nva-health"
  protocol            = "Http"
  port                = 8080
  request_path        = "/healthz"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "ha_ports" {
  loadbalancer_id                = azurerm_lb.nva.id
  name                           = "rule-ha-ports"
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "fe-nva"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nva.id]
  probe_id                       = azurerm_lb_probe.nva.id
  floating_ip_enabled            = true
  disable_outbound_snat          = true
}

resource "azurerm_network_security_group" "nva" {
  name                = "nsg-${var.name}-nva"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "Allow-AKS-To-NVA"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.internal_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer-Probe"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-Other-VNet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nva" {
  subnet_id                 = azurerm_subnet.nva.id
  network_security_group_id = azurerm_network_security_group.nva.id
}

resource "azurerm_linux_virtual_machine_scale_set" "nva" {
  name                        = "vmss-${var.name}-nva"
  resource_group_name         = var.resource_group_name
  location                    = var.location
  sku                         = var.nva_vmss_sku
  instances                   = var.nva_vmss_instances
  admin_username              = "azureuser"
  upgrade_mode                = "Manual"
  zones                       = length(var.nva_zones) > 0 ? var.nva_zones : null
  zone_balance                = length(var.nva_zones) > 1
  platform_fault_domain_count = 1
  single_placement_group      = false

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  custom_data = base64encode(templatefile("${path.module}/nva-cloud-init.yaml.tftpl", {
    internal_cidr     = var.internal_cidr
    destination_cidrs = var.destination_cidrs
  }))

  network_interface {
    name                           = "nic-nva"
    primary                        = true
    ip_forwarding_enabled          = true
    accelerated_networking_enabled = true

    ip_configuration {
      name                                   = "ipconfig-nva"
      primary                                = true
      subnet_id                              = azurerm_subnet.nva.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.nva.id]
    }
  }

  depends_on = [
    azurerm_lb_rule.ha_ports,
    azurerm_subnet_network_security_group_association.nva,
  ]
}

# =============================================================================
# 6. AKS Automatic cluster (BYO VNet, CNI Overlay)
# =============================================================================
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "aks_vnet" {
  scope                = azurerm_virtual_network.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_role_assignment" "aks_rt" {
  scope                = azurerm_route_table.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_automatic_cluster" "aks" {
  name                = "aks-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  api_server_access {
    subnet_id = azurerm_subnet.aks_api.id
  }

  hosted_system {
    system_node_subnet_id = azurerm_subnet.aks_system.id
    node_subnet_id        = azurerm_subnet.aks_user.id
  }

  depends_on = [
    azurerm_role_assignment.aks_vnet,
    azurerm_role_assignment.aks_rt,
    azurerm_subnet_nat_gateway_association.aks_system,
    azurerm_subnet_nat_gateway_association.aks_user,
    azurerm_subnet_route_table_association.aks_system,
    azurerm_subnet_route_table_association.aks_user,
  ]
}

resource "azurerm_role_assignment" "aks_admin" {
  scope                = azurerm_kubernetes_automatic_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.admin_principal_id
}

# =============================================================================
# Custom CA trust: lets containerd/kubelet verify a Nexus cert issued by a
# private CA. azurerm_kubernetes_automatic_cluster doesn't expose
# securityProfile.customCATrustCertificates, so it is merged in with azapi.
# AKS reimages the hosted system nodes; NAP NodeClaims that already exist are
# NOT marked drifted and must be recycled (see scripts/e2e-test.sh).
# =============================================================================
resource "azapi_update_resource" "custom_ca_trust" {
  count = length(var.custom_ca_trust_certificates) > 0 ? 1 : 0

  type        = "Microsoft.ContainerService/managedClusters@2026-07-01"
  resource_id = azurerm_kubernetes_automatic_cluster.aks.id

  body = {
    properties = {
      securityProfile = {
        # The API stores base64(PEM); LF line endings only.
        customCATrustCertificates = [for pem in var.custom_ca_trust_certificates : base64encode(replace(pem, "\r\n", "\n"))]
      }
    }
  }

  timeouts {
    create = "60m"
    update = "60m"
  }
}
