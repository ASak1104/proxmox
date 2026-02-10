# Ubuntu Desktop VM - 관리용 (패널 접근)
# 일반적으로 shutdown 상태로 유지
resource "proxmox_virtual_environment_vm" "ubuntu" {
  node_name   = var.node_name
  vm_id       = 101
  name        = "ubuntu"
  description = "Ubuntu Desktop for management console access - managed by OpenTofu"

  agent {
    enabled = false
  }

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 2048 # MB
  }

  # Management network only
  network_device {
    bridge = "vmbr1"
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
    interface    = "virtio0"
    size         = 10 # GB
    file_format  = "qcow2"
    iothread     = true
  }

  # Ubuntu Desktop ISO (mounted)
  cdrom {
    file_id   = "local:iso/ubuntu-24.04.3-desktop-amd64.iso"
    interface = "ide2"
  }

  boot_order    = ["virtio0", "ide2", "net0"]
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  started = false # 기본적으로 shutdown 상태 유지
  on_boot = false

  lifecycle {
    ignore_changes = [
      network_device,
      disk,
      cdrom,
    ]
  }
}
