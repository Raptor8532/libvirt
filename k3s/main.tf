terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

// instance the provider
provider "libvirt" {
  uri = "qemu:///system"
}

// variables that can be overriden
variable "hostname" { default = "test" }
variable "domain" { default = "example.com" }
variable "ip_type" { default = "dhcp" } # dhcp is other valid type
variable "memoryMB" { default = 1024 * 1 }
variable "cpu" { default = 1 }
variable "diskBytes" { default = 1024*1024*1024*5 }
variable "private_key_path" {
  description = "Path to the private SSH key, used to access the instance."
  default     = "~/.ssh/id_rsa"
}

// fetch the latest ubuntu release image from their mirrors
resource "libvirt_volume" "os_image" {
  name   = "${var.hostname}-os_image"
  pool   = "default"
  source = "jammy-server-cloudimg-amd64.img"
  format = "qcow2"
}

// Use CloudInit ISO to add ssh-key to the instance
resource "libvirt_cloudinit_disk" "commoninit" {
  name           = "${var.hostname}-commoninit.iso"
  pool           = "default"
  user_data      = data.template_cloudinit_config.config.rendered
  network_config = data.template_file.network_config.rendered
}

data "template_file" "user_data" {
  template = file("${path.module}/cloud_init.cfg")
  vars = {
    hostname             = var.hostname
    fqdn                 = "${var.hostname}.${var.domain}"
    public_key           = file("/home/deltaro/.ssh/id_rsa.pub")
    terraform_public_key = file("/home/deltaro/.ssh/terraform_rsa.pub")
  }
}

data "template_cloudinit_config" "config" {
  gzip          = false
  base64_encode = false
  part {
    filename     = "init.cfg"
    content_type = "text/cloud-config"
    content      = data.template_file.user_data.rendered
  }
}

data "template_file" "network_config" {
  template = file("${path.module}/network_config_${var.ip_type}.cfg")
}

############################################################
//-> Create storage
############################################################

resource "libvirt_pool" "k3s_pool" {
  name = "cluster"
  type = "dir"
  path = "/home/deltaro/vm-storage/k3s"
}

resource "libvirt_volume" "master" {
  name = "master-k3s.qcow2"
  pool   = "default"
  size = var.diskBytes
}


############################################################
//-> Create the machine
############################################################
resource "libvirt_domain" "domain-ubuntu" {
  # domain name in libvirt, not hostname
  name   = var.hostname
  memory = var.memoryMB
  vcpu   = var.cpu
  #qemu_agent = true

  disk {
    volume_id = libvirt_volume.os_image.id
  }
  disk {
    volume_id = libvirt_volume.master.id
  }

  network_interface {
    network_name   = "default"
    mac            = "52:54:00:82:7c:fe"
    wait_for_lease = true
  }

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  # IMPORTANT
  # Ubuntu can hang is a isa-serial is not present at boot time.
  # If you find your CPU 100% and never is available this is why
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = "true"
  }
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait"
    ]

    connection {
      host        = self.network_interface.0.addresses.0
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("${var.private_key_path}")
    }
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = "ANSIBLE_HOST_KEY_CHECKING=False /home/deltaro/.local/bin/ansible-playbook -u ubuntu -i ${self.network_interface.0.addresses.0}, --private-key ${var.private_key_path} provision.yml"
  }
}

output "ips" {
  value = libvirt_domain.domain-ubuntu.*.network_interface.0.addresses
}