terraform {
  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "2.15.0"
    }
  }
}

provider "vsphere" {
  user                 = "administrator@vpshere.local"
  password             = "Sesroot0@" # Use this env var : VSPHERE_PASSWORD
  vsphere_server       = "10.0.0.101"
  allow_unverified_ssl = true
  api_timeout          = 45
}
