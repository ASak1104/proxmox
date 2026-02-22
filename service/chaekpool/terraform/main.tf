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

# Alpine nocloud 이미지 (Jenkins VM용)
resource "proxmox_virtual_environment_download_file" "alpine_cloud" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.node_name
  url          = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.0-x86_64-bios-cloudinit-r0.qcow2"
  file_name    = "alpine-3.23-cloud-amd64.img"
}

# Jenkins VM (Docker/Testcontainers 지원을 위해 LXC 대신 VM 사용)
resource "proxmox_virtual_environment_vm" "jenkins" {
  node_name   = var.node_name
  vm_id       = var.jenkins_vm.id
  name        = "cp-jenkins"
  description = "chaekpool/cp-jenkins VM - managed by OpenTofu"

  cpu {
    cores = var.jenkins_vm.cores
    type  = "host"
  }

  memory {
    dedicated = var.jenkins_vm.memory
  }

  disk {
    datastore_id = "local"
    file_id      = proxmox_virtual_environment_download_file.alpine_cloud.id
    interface    = "virtio0"
    size         = var.jenkins_vm.disk
  }

  network_device {
    bridge = "vmbr2"
  }

  initialization {
    datastore_id = "local"

    ip_config {
      ipv4 {
        address = var.jenkins_vm.ip
        gateway = var.svc_gateway
      }
    }
    dns {
      servers = [var.svc_gateway]
    }
    user_account {
      keys     = var.ssh_public_key != "" ? [var.ssh_public_key] : []
      username = "root"
    }
  }

  started  = true
  on_boot  = true
}

# Jenkins VM 부트스트랩: SSH + Python + Docker 설치
resource "null_resource" "jenkins_bootstrap" {
  provisioner "remote-exec" {
    inline = [
      "echo 'nameserver ${var.svc_gateway}' > /etc/resolv.conf",
      "while fuser /lib/apk/db/lock >/dev/null 2>&1; do sleep 1; done",
      "apk add --no-cache openssh python3 ca-certificates docker docker-cli-compose",
      "ssh-keygen -A",
      "rc-service sshd start",
      "rc-update add sshd",
      "rc-service docker start",
      "rc-update add docker"
    ]
    connection {
      type = "ssh"
      host = split("/", var.jenkins_vm.ip)[0]
      user = "root"
    }
  }

  triggers = {
    vm_id = proxmox_virtual_environment_vm.jenkins.vm_id
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
