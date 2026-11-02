# =============================================================================
# Network Security Group for Remote API Subnet
# =============================================================================
resource "azurerm_network_security_group" "remote_api_nsg" {
  name                = "nsg-remote-api"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Strictly allow HTTP (8080) ONLY from the peered NAT Masquerade subnet (10.100.0.0/28)
  # This proves that AKS traffic from 100.64.1.0/24 is SNAT'd to 10.100.0.x!
  security_rule {
    name                       = "Allow-HTTP-From-Peered-NAT-Subnet-Only"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = var.nat_subnet_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Other-VNet-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "remote_api_nsg_assoc" {
  subnet_id                 = azurerm_subnet.remote_api.id
  network_security_group_id = azurerm_network_security_group.remote_api_nsg.id
}

# =============================================================================
# Target API VM in Peered VNet (No External Packages Needed - Uses Python3 Stdlib)
# =============================================================================
locals {
  api_cloud_init = <<-EOT
    #cloud-config
    write_files:
      - path: /opt/echo-api.py
        permissions: '0755'
        content: |
          #!/usr/bin/env python3
          import json
          import socket
          from datetime import datetime, timezone
          from http.server import BaseHTTPRequestHandler, HTTPServer

          class EchoHandler(BaseHTTPRequestHandler):
              def do_GET(self):
                  payload = {
                      "status": "ok",
                      "message": "Hello from the peered VNet API!",
                      "client_ip_seen_by_api": self.client_address[0],
                      "client_port_seen_by_api": self.client_address[1],
                      "api_server_hostname": socket.gethostname(),
                      "api_server_ip": "${var.remote_api_private_ip}",
                      "path": self.path,
                      "timestamp": datetime.now(timezone.utc).isoformat()
                  }
                  body = json.dumps(payload, indent=2).encode("utf-8")
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)

              def log_message(self, format, *args):
                  print(f"{self.client_address[0]} - - [{self.log_date_time_string()}] {format % args}", flush=True)

          if __name__ == "__main__":
              server = HTTPServer(("0.0.0.0", 8080), EchoHandler)
              print("Starting echo API server on 0.0.0.0:8080...", flush=True)
              server.serve_forever()

      - path: /etc/systemd/system/echo-api.service
        content: |
          [Unit]
          Description=Peered VNet Echo HTTP API
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=simple
          ExecStart=/usr/bin/python3 /opt/echo-api.py
          Restart=always
          RestartSec=2

          [Install]
          WantedBy=multi-user.target

    runcmd:
      - systemctl daemon-reload
      - systemctl enable --now echo-api.service
  EOT
}

resource "azurerm_network_interface" "remote_api_nic" {
  name                = "nic-remote-api"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig-api"
    subnet_id                     = azurerm_subnet.remote_api.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.remote_api_private_ip
  }
}

resource "azurerm_linux_virtual_machine" "remote_api_vm" {
  name                = "vm-remote-api"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.api_vm_sku
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.remote_api_nic.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh.public_key_openssh
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  custom_data = base64encode(local.api_cloud_init)
}

