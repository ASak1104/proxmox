# OPNsense VM - Firewall and router
resource "proxmox_virtual_environment_vm" "opnsense" {
  node_name   = var.node_name
  vm_id       = 102
  name        = "opnsense"
  description = "OPNsense firewall and router - managed by OpenTofu"

  agent {
    enabled = false # OPNsense doesn't support QEMU guest agent
  }

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 4096 # MB
  }

  # 네트워크 인터페이스 - 순서 중요!
  # net0: External (WAN) - vmbr0
  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # net1: Management - vmbr1
  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  # net2: Service - vmbr2
  network_device {
    bridge = "vmbr2"
    model  = "virtio"
  }

  # EFI Disk
  efi_disk {
    datastore_id = "local"
    file_format  = "qcow2"
    type         = "4m"
  }

  # Main disk
  disk {
    datastore_id = "local"
    interface    = "sata0"
    size         = 20 # GB
    file_format  = "qcow2"
  }

  boot_order    = ["sata0"]
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  started = true
  on_boot = true

  lifecycle {
    ignore_changes = [
      network_device, # OPNsense에서 직접 관리
      disk,
      memory, # 이미 4096으로 변경됨
    ]
  }
}
