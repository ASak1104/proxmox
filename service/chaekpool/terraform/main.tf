# Chaekpool 프로젝트 서비스 LXC 컨테이너
# 모두 서비스 네트워크(vmbr2, 10.0.1.0/24)에 위치
resource "proxmox_virtual_environment_container" "service" {
  for_each = var.containers

  node_name    = var.node_name
  vm_id        = each.value.id
  description  = "chaekpool/${each.key} - managed by OpenTofu"
  unprivileged = true

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.svc_gateway
      }
    }

    dns {
      servers = [var.svc_gateway]
    }

    user_account {
      keys = var.ssh_public_key != "" ? [var.ssh_public_key] : []
    }
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local"
    size         = each.value.disk
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr2"
  }

  operating_system {
    template_file_id = var.template_id
    type             = "alpine"
  }

  started       = true
  start_on_boot = true

  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
    ]
  }
}
