output "container_ids" {
  description = "Chaekpool service LXC container IDs"
  value = {
    for name, ct in proxmox_virtual_environment_container.service :
    name => ct.vm_id
  }
}

output "container_ips" {
  description = "Chaekpool service LXC container IPs"
  value = {
    for name, config in var.containers :
    name => config.ip
  }
}
