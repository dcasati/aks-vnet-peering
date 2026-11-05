variable "name" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "virtual_hub_id" {
  description = "vWAN virtual hub the transit VNet connects to"
  type        = string
}

variable "transit_cidr" {
  description = "Small routable prefix (/28 recommended) for the transit VNet; the ONLY prefix advertised to the hub"
  type        = string
}

variable "internal_cidr" {
  description = "Non-routable AKS VNet space (never connected to the hub; may overlap across environments)"
  type        = string

  validation {
    condition     = tonumber(split("/", var.internal_cidr)[1]) <= 23
    error_message = "internal_cidr must be /23 or larger to hold the /28 API, /26 system and /24 user subnets."
  }
}

variable "destination_cidrs" {
  description = "Private prefixes (Nexus, on-prem) that AKS reaches through the transit NVA -> hub. Everything else uses the NAT gateway."
  type        = list(string)

  validation {
    condition     = length(var.destination_cidrs) > 0 && length(var.destination_cidrs) <= 50
    error_message = "destination_cidrs must contain between 1 and 50 prefixes; summarise on-prem ranges."
  }
}

variable "ssh_public_key" {
  type = string
}

variable "nva_vmss_sku" {
  type = string
}

variable "nva_vmss_instances" {
  type = number
}

variable "nva_zones" {
  type = list(string)
}

variable "admin_principal_id" {
  description = "Principal granted AKS RBAC Cluster Admin"
  type        = string
}

variable "custom_ca_trust_certificates" {
  description = "PEM CA certificates added to the node trust store (AKS custom CA trust; max 10). Empty disables it."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.custom_ca_trust_certificates) <= 10
    error_message = "AKS custom CA trust accepts at most 10 certificates."
  }
}
