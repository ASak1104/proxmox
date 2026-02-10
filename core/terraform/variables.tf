variable "proxmox_endpoint" {
  description = "Proxmox API endpoint"
  type        = string
  default     = "https://10.0.0.254:8006"
}

variable "proxmox_username" {
  description = "Proxmox username or API token user (format: user@realm!tokenid)"
  type        = string
  default     = ""
}

variable "proxmox_api_token" {
  description = "Proxmox API token in format 'user@realm!tokenid:tokenvalue'"
  type        = string
  sensitive   = true
  default     = ""
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "ssh_public_key" {
  description = "SSH public key for VM/container access (not used in infra layer)"
  type        = string
  default     = ""
}

variable "opnsense_wan_ip" {
  description = "OPNsense WAN (external) IP address"
  type        = string
  default     = ""
}
