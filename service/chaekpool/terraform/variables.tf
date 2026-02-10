variable "proxmox_endpoint" {
  description = "Proxmox API endpoint"
  type        = string
  default     = "https://10.0.0.254:8006"
}

variable "proxmox_username" {
  description = "Proxmox username"
  type        = string
  default     = ""
}

variable "proxmox_api_token" {
  description = "Proxmox API token"
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "template_id" {
  description = "Alpine 3.23 LXC template"
  type        = string
  default     = "local:vztmpl/alpine-3.23-default_20260116_amd64.tar.xz"
}

variable "ssh_public_key" {
  description = "SSH public key for LXC containers"
  type        = string
  default     = ""
}

variable "svc_gateway" {
  description = "Service network gateway (OPNsense OPT1)"
  type        = string
  default     = "10.1.0.1"
}

variable "containers" {
  description = "Chaekpool project LXC containers"
  type = map(object({
    id     = number
    ip     = string
    memory = number
    disk   = number
    cores  = number
  }))
  default = {
    # LB (200-209)
    cp-traefik = {
      id     = 200
      ip     = "10.1.0.100/24"
      memory = 512
      disk   = 5
      cores  = 1
    }
    # Data (210-219)
    cp-postgresql = {
      id     = 210
      ip     = "10.1.0.110/24"
      memory = 2048
      disk   = 20
      cores  = 2
    }
    cp-valkey = {
      id     = 211
      ip     = "10.1.0.111/24"
      memory = 1024
      disk   = 10
      cores  = 1
    }
    # Monitoring (220-229)
    cp-monitoring = {
      id     = 220
      ip     = "10.1.0.120/24"
      memory = 4096
      disk   = 30
      cores  = 4
    }
    # CI/CD (230-239)
    cp-jenkins = {
      id     = 230
      ip     = "10.1.0.130/24"
      memory = 2048
      disk   = 20
      cores  = 2
    }
    # App (240-249)
    cp-kopring = {
      id     = 240
      ip     = "10.1.0.140/24"
      memory = 2048
      disk   = 10
      cores  = 2
    }
  }
}
