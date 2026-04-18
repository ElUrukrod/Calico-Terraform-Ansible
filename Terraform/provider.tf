terraform {
  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "2.15.0"
    }
        phpipam = {
      source  = "lord-kyron/phpipam"
      version = "~> 1.6.2"
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

provider "phpipam" {
  # L'argument attendu est souvent "endpoint" et non "app_url"
  endpoint = "http://10.0.0.46/api"
  app_id   = "terraform"
  
  # Si tu utilises un Token d'application (App Token)
  # Le paramètre est souvent "password" dans la configuration du provider
  # même si c'est un token technique.
  password = "Sesroot0"
  username = "admin" # Parfois requis même avec un token, selon le provider

  # Si ton phpIPAM n'est pas en HTTPS, assure-toi que l'insecure est autorisé
  insecure = true
}
