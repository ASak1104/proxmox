output "opnsense_id" {
  description = "OPNsense VM ID"
  value       = proxmox_virtual_environment_vm.opnsense.vm_id
}

output "opnsense_external_ip" {
  description = "OPNsense external (WAN) IP"
  value       = var.opnsense_wan_ip
}
