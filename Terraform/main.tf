data "vsphere_datacenter" "datacenter" {
  name = "Datacenter"
}

data "phpipam_subnet" "subnet_search" {
  subnet_address = "10.0.0.0"
  subnet_mask    = 24
}

data "phpipam_first_free_address" "next_ip" {
  subnet_id = data.phpipam_subnet.target_subnet.id
}

data "phpipam_subnet" "target_subnet" {
  subnet_id = data.phpipam_subnet.subnet_search.subnet_id
}

locals {
  gw_ip = data.phpipam_subnet.target_subnet.gateway.ip_addr
}

data "vsphere_compute_cluster" "host" {
  name          = "Calico"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_datastore" "iso" {
  name          = "ISOs"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}
data "vsphere_datastore" "datastore" {
  name          = "datastore0"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

locals {
  root_module_name = "ClientA"
  prefix           = "ClientA"
  number_of_user   = 1
  vcenter_sso_domain = "vsphere.local"
}

data "vsphere_host" "esxi_host" {
  name          = "10.0.0.42" # Mets l'IP ou le FQDN de ton hôte ESXi
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

# Récupération de l'ISO Windows
data "vsphere_datastore" "iso_ds" {
  name          = "ISOs"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

# Variable locale pour la clé publique Ansible
locals {
  ansible_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOLUBmViUWVz9p5Atte8R8PHgkPtjNSMEKxdcmwRu5Sf root@debian"
}

# Génère un mot de passe aléatoire fort
resource "random_password" "win_admin_password" {
  length           = 16
  special          = true
  override_special = "!$#%" # Caractères spéciaux acceptés par Windows sans poser de soucis de shell
}

# 2. On centralise les secrets dans le fichier de logs local
resource "local_file" "vm_secrets" {
  content  = <<EOT
Machine: ${vsphere_virtual_machine.win_server.name}
Admin Password: ${random_password.win_admin_password.result}
AD DSRM Password: ${random_password.ad_dsrm_password.result}
EOT
  filename = "${path.module}/secrets_${vsphere_virtual_machine.win_server.name}.txt"
}

resource "vsphere_host_port_group" "PortGroup" {
  name                = "Serveurs"
  host_system_id      = data.vsphere_host.esxi_host.id
  virtual_switch_name = "vSwitch0"
  vlan_id             = 0 # 20 Normalement, 0 Pour les TEST (flemme de faire un OPNSense)
}

resource "random_password" "ad_dsrm_password" {
  length           = 16
  special          = true
  override_special = "!$#%"
}

data "vsphere_network" "network" {
  name          = vsphere_host_port_group.PortGroup.name
  datacenter_id = data.vsphere_datacenter.datacenter.id
  
  # On force la dépendance pour être sûr que le port group existe avant de le chercher
  depends_on = [vsphere_host_port_group.PortGroup]
}

# On récupère le template que tu as créé manuellement
data "vsphere_virtual_machine" "template" {
  name          = "WinServer2025-Template"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

resource "vsphere_virtual_machine" "win_server" {
  name             = "SRV001"
  resource_pool_id = data.vsphere_host.esxi_host.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  host_system_id   = data.vsphere_host.esxi_host.id

  guest_id = data.vsphere_virtual_machine.template.guest_id
  firmware = "efi"

  lifecycle {
    ignore_changes = [
      disk[0].io_reservation, # Ignore la dérive sur le premier disque
    ]
  }

  network_interface {
    network_id = data.vsphere_network.network.id
  }

  disk {
    label = "disk0"
    size  = 100
    io_reservation   = 0
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    customize {
      windows_options {
        computer_name  = "SRV001"
        # On utilise le mot de passe généré par Terraform
        admin_password = random_password.win_admin_password.result
        
        # On force l'auto-logon une fois pour que les commandes RunOnce s'exécutent bien
        auto_logon       = true
        auto_logon_count = 1


run_once_command_list = [
        # 1. Passage du réseau en "Private"
        "powershell.exe -ExecutionPolicy Bypass -Command \"Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private\"",
        
        # 2. Injection de la clé SSH et droits
        "powershell.exe -ExecutionPolicy Bypass -Command \"$path = 'C:\\ProgramData\\ssh'; if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force }; '${local.ansible_public_key}' | Out-File -FilePath \"$path\\administrators_authorized_keys\" -Encoding ascii; icacls \"$path\\administrators_authorized_keys\" /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'\"",
      
        # 3. Configuration OpenSSH (Server + Firewall + Service)
        "powershell.exe -ExecutionPolicy Bypass -Command \"Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0\"",
        "powershell.exe -ExecutionPolicy Bypass -Command \"Start-Service sshd; Set-Service -Name sshd -StartupType 'Automatic'\"",
        "powershell.exe -ExecutionPolicy Bypass -Command \"New-NetFirewallRule -Name 'AllowSSH_Any' -DisplayName 'Allow SSH Any Profile' -Enabled True -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22\"",
        
        # 4. ACTIVATION DU BUREAU À DISTANCE (RDP)
        # Activation dans le registre (fDenyTSConnections = 0)
        "powershell.exe -ExecutionPolicy Bypass -Command \"Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name 'fDenyTSConnections' -Value 0\"",
        # Activation du NLA (Network Level Authentication)
        "powershell.exe -ExecutionPolicy Bypass -Command \"Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp' -Name 'UserAuthentication' -Value 1\"",
        # Ouverture du pare-feu pour le RDP (Port 3389)
        "powershell.exe -ExecutionPolicy Bypass -Command \"Enable-NetFirewallRule -DisplayGroup '@FirewallAPI.dll,-28752'\"", # Groupe standard RDP
        "powershell.exe -ExecutionPolicy Bypass -Command \"New-NetFirewallRule -Name 'AllowRDP_Any' -DisplayName 'Allow RDP Any Profile' -Enabled True -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389\""

        ]
      }

      network_interface {
        ipv4_address = data.phpipam_first_free_address.next_ip.ip_address
        ipv4_netmask = data.phpipam_subnet.target_subnet.subnet_mask
        
      }
      # On accède à l'adresse IP à l'intérieur de l'objet gateway
      ipv4_gateway = local.gw_ip
    }
  }
provisioner "local-exec" {
    command = <<EOT
      # On utilise l'IP dynamique ici aussi
      until nc -z -v -w5 ${data.phpipam_first_free_address.next_ip.ip_address} 22; do sleep 10; done
      
      ansible-playbook -i ${data.phpipam_first_free_address.next_ip.ip_address}, \
        --user Administrateur \
        -e "ad_safe_mode_password=${nonsensitive(random_password.ad_dsrm_password.result)}" \
        ../Ansible/Deploy_AD.yml
    EOT
    
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }
}

resource "phpipam_address" "reserve_ip" {
  subnet_id   = data.phpipam_subnet.target_subnet.id
  ip_address  = data.phpipam_first_free_address.next_ip.ip_address
  hostname    = vsphere_virtual_machine.win_server.name
  description = "VM provisionnée par Terraform"
  state_tag_id = 2 # 2 = Active / Used
}
