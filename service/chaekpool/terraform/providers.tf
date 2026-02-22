terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.50.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_username}=${var.proxmox_api_token}"
  insecure  = true

  ssh {
    agent    = true
    username = var.proxmox_ssh_user
    node {
      name    = var.node_name
      address = var.proxmox_ssh_host
    }
  }
}
