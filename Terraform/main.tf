data "vsphere_datacenter" "datacenter" {
  name = "Datacenter"
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
        computer_name  = "SRV01"
        # On utilise le mot de passe généré par Terraform
        admin_password = random_password.win_admin_password.result
        
        # On force l'auto-logon une fois pour que les commandes RunOnce s'exécutent bien
        auto_logon       = true
        auto_logon_count = 1


        run_once_command_list = [
          # 1. On passe le réseau en "Private" pour ouvrir le pare-feu
          "powershell.exe -ExecutionPolicy Bypass -Command \"Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private\"",
          
          # 2. Installation et démarrage SSH + Règles de pare-feu
          "powershell.exe -ExecutionPolicy Bypass -Command \"Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0\"",
          "powershell.exe -ExecutionPolicy Bypass -Command \"Start-Service sshd; Set-Service -Name sshd -StartupType 'Automatic'\"",
          "powershell.exe -ExecutionPolicy Bypass -Command \"New-NetFirewallRule -Name 'AllowSSH_Any' -DisplayName 'Allow SSH Any Profile' -Enabled True -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22\"", # <--- LA VIRGULE ÉTAIT MANQUANTE ICI
          
          # 3. Injection de la clé et droits
          "powershell.exe -ExecutionPolicy Bypass -Command \"$path = 'C:\\ProgramData\\ssh'; if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force }; '${local.ansible_public_key}' | Out-File -FilePath \"$path\\administrators_authorized_keys\" -Encoding ascii; icacls \"$path\\administrators_authorized_keys\" /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'\""
        ]
      }

      network_interface {
        ipv4_address = "10.0.0.150"
        ipv4_netmask = 24
        
      }
      ipv4_gateway = "10.0.0.254"
    }
  }
provisioner "local-exec" {
    command = <<EOT
      # Attente SSH
      until nc -z -v -w5 10.0.0.150 22; do sleep 10; done
      
      # Lancement Ansible avec passage du mot de passe DSRM en extra-var
      ansible-playbook -i 10.0.0.150, \
        --user Administrateur \
        -e "ansible_connection=ssh" \
        -e "ansible_shell_type=powershell" \
        -e "ad_safe_mode_password=${nonsensitive(random_password.ad_dsrm_password.result)}" \
        ../Ansible/SetupAd.yml
    EOT
    
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }
}
