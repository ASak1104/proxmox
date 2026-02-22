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

# Ansible 부트스트랩: 컨테이너 생성 후 openssh + python3 설치
resource "null_resource" "ansible_bootstrap" {
  for_each = var.containers

  provisioner "local-exec" {
    command = <<-EOT
      sleep 5 && ssh ${var.proxmox_ssh_user}@${var.proxmox_ssh_host} "sudo pct exec ${each.value.id} -- sh -c '
        apk add --no-cache openssh python3 ca-certificates &&
        ssh-keygen -A &&
        rc-service sshd start &&
        rc-update add sshd
      '"
    EOT
  }

  triggers = {
    container_id = proxmox_virtual_environment_container.service[each.key].vm_id
  }
}
