terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.1"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# Storage Pool for Pair A
resource "libvirt_pool" "pool_a" {
  name = "pool_a"
  type = "dir"
  path = "/home/pool_a"
}

# Base OS image volume
resource "libvirt_volume" "os_base" {
  name   = "almalinux9-base.qcow2"
  pool   = libvirt_pool.pool_a.name
  source = var.os_image_path
  format = "qcow2"
}

# OS Volumes for each VM (cloned from base)
resource "libvirt_volume" "os_disk" {
  count          = var.vm_count
  name           = "${var.hostname_prefix}-${count.index + 1}-os.qcow2"
  pool           = libvirt_pool.pool_a.name
  base_volume_id = libvirt_volume.os_base.id
  format         = "qcow2"
}

# Data Disks for each VM (2 disks per VM, 2G each)
resource "libvirt_volume" "data_disk_1" {
  count  = var.vm_count
  name   = "${var.hostname_prefix}-${count.index + 1}-data1.qcow2"
  pool   = libvirt_pool.pool_a.name
  format = "qcow2"
  size   = 2147483648 # 2G
}

resource "libvirt_volume" "data_disk_2" {
  count  = var.vm_count
  name   = "${var.hostname_prefix}-${count.index + 1}-data2.qcow2"
  pool   = libvirt_pool.pool_a.name
  format = "qcow2"
  size   = 2147483648 # 2G
}

# Cloud-Init for each VM
resource "libvirt_cloudinit_disk" "commoninit" {
  count     = var.vm_count
  name      = "${var.hostname_prefix}-${count.index + 1}-commoninit.iso"
  pool      = libvirt_pool.pool_a.name
  user_data = templatefile("${path.module}/cloud_init.cfg", {
    hostname       = "${var.hostname_prefix}-${count.index + 1}"
    ssh_public_key = file(var.ssh_public_key)
  })
  network_config = <<-EOF
    version: 2
    ethernets:
      main_iface:
        match:
          name: en*
        dhcp4: true
  EOF
}

# VMs
resource "libvirt_domain" "pa_node" {
  count  = var.vm_count
  name   = "${var.hostname_prefix}-${count.index + 1}"
  memory = "1024" # Deviation: 1GB instead of 2GB
  vcpu   = 2

  qemu_agent = true

  # AlmaLinux 9 requires x86-64-v2 CPU features.
  # We must pass the host CPU through instead of the default qemu64.
  cpu {
    mode = "host-passthrough"
  }

  # UEFI boot settings
  machine  = "q35"
  firmware = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
  nvram {
    file     = "/var/lib/libvirt/qemu/nvram/${var.hostname_prefix}-${count.index + 1}_VARS.fd"
    template = "/usr/share/edk2/ovmf/OVMF_VARS.fd"
  }

  network_interface {
    network_name   = "default"
    wait_for_lease = true
  }

  # OS Disk
  disk {
    volume_id = libvirt_volume.os_disk[count.index].id
  }

  # Data Disk 1
  disk {
    volume_id = libvirt_volume.data_disk_1[count.index].id
  }

  # Data Disk 2
  disk {
    volume_id = libvirt_volume.data_disk_2[count.index].id
  }

  # Cloud-Init
  cloudinit = libvirt_cloudinit_disk.commoninit[count.index].id

  # Use VNC instead of SPICE (qemu-kvm minimal doesn't include SPICE)
  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  # WORKAROUND: The libvirt provider's 'cloudinit' parameter hardcodes an IDE CD-ROM.
  # The 'q35' machine type does not support IDE. This XSLT transform intercepts the XML
  # before it is sent to KVM and changes the cloud-init CD-ROM bus from IDE to SATA.
  xml {
    xslt = <<EOF
<?xml version="1.0" ?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>
  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>
  <xsl:template match="target[@bus='ide']">
    <target dev="sda" bus="sata"/>
  </xsl:template>
</xsl:stylesheet>
EOF
  }
}
