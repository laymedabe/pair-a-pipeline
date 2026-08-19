variable "libvirt_uri" {
  description = "libvirt connection URI"
  default     = "qemu:///system"
}

variable "vm_count" {
  description = "Number of VMs to provision"
  default     = 1
}

variable "hostname_prefix" {
  description = "Prefix for the VM hostnames"
  default     = "pa-node"
}

variable "os_image_path" {
  description = "Path to the golden image built by Packer"
  default     = "/var/tmp/packer_output/almalinux9-golden.qcow2"
}

variable "ssh_public_key" {
  description = "Public SSH key for the sysadmin user"
  default     = "id_rsa.pub"
}

