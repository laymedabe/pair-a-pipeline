	packer {
  required_plugins {
    qemu = {
      version = "~> 1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# This block defines a "source" using the QEMU builder plugin.
# We are naming this specific configuration "almalinux9".
source "qemu" "almalinux9" {
  
  # ---------------------------------------------------------
  # 1. Hypervisor and OS Image Setup
  # ---------------------------------------------------------
  # Specifies the exact path to the QEMU/KVM executable on the host machine.
  qemu_binary       = "/usr/libexec/qemu-kvm"
  
  # The URL to download the minimal AlmaLinux 9.4 ISO.
  iso_url           = "https://vault.almalinux.org/9.4/isos/x86_64/AlmaLinux-9.4-x86_64-minimal.iso"
  
  # The cryptographic hash used to verify the ISO downloaded correctly and hasn't been tampered with.
  iso_checksum      = "sha256:20123bb9f8319143e792b906137236bdcb0d10b023c36626ca2d8e9f62144eb9"

  # Pass the host CPU features directly to the VM to satisfy x86-64-v2 requirements
  accelerator       = "kvm"
  cpu_model         = "host"
  # ---------------------------------------------------------
  # 2. Build Environment and Output
  # ---------------------------------------------------------
  # Tell Packer not to open a UI/VNC window (runs the build silently in the background).
  headless          = true

  # Output to a persistent tmp directory to prevent conflicts with Terraform's managed libvirt pool
  output_directory  = "/var/tmp/packer_output"
  
  # The filename of the final Golden Image.
  vm_name           = "almalinux9-golden.qcow2"

  # ---------------------------------------------------------
  # 3. Virtual Hardware Configuration
  # ---------------------------------------------------------
  # Sets the virtual hard drive maximum capacity to 20 Gigabytes.
  disk_size         = "20G"
  
  # Uses the qcow2 format (thin-provisioned, so it only takes up used space, not the full 20G).
  format            = "qcow2"

  # Memory (RAM) in Megabytes allocated to the VM just for the build process (2GB).
  memory            = 2048
  
  # Number of CPU cores allocated to the VM during the build.
  cpus              = 2

  # ---------------------------------------------------------
  # 4. UEFI Boot Configuration
  # ---------------------------------------------------------
  machine_type      = "q35"
  
  # Tell Packer to use modern UEFI pflash drives instead of legacy -bios
  efi_boot          = true
  efi_firmware_code = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
  efi_firmware_vars = "/usr/share/edk2/ovmf/OVMF_VARS.fd"

  # ---------------------------------------------------------
  # 5. Kickstart & Automation Injection
  # ---------------------------------------------------------
  # Packer creates a temporary HTTP server pointing to the current directory (".") 
  # so the VM can download the kickstart.cfg file over the virtual network.
  http_directory    = "."
  # Gives the VM 10 seconds to boot up and reach the installation menu before typing.
  boot_wait         = "10s"
  
  # Simulates a human typing on a keyboard to intercept the boot menu and pass the kickstart URL.
  # {{ .HTTPIP }} and {{ .HTTPPort }} are dynamically replaced by Packer's temporary server details.
  # Interrupt the boot process, edit the boot parameters, and inject the kickstart URL
  boot_command = [
    "<up><wait>",
    "e",
    "<down><down><end>",
    " inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/kickstart.cfg nameserver=8.8.8.8",
    "<f10>"
  ]

  # ---------------------------------------------------------
  # 6. Completion and Cleanup
  # ---------------------------------------------------------
  # The user account Packer will use to SSH into the machine to verify the install is done.
  # (This matches the user you created in your kickstart.cfg).
  ssh_username      = "ansible"
  ssh_password      = "ansible"
  
  # How long Packer will wait for the OS to install and SSH to become available before giving up.
  ssh_timeout       = "60m"
  
  # The command Packer runs over SSH to safely power off the VM so it can finalize the image.
  shutdown_command  = "echo 'ansible' | sudo -S bash -c 'cloud-init clean; truncate -s 0 /etc/machine-id; rm -f /var/lib/dbus/machine-id; shutdown -P now'"
}

# ---------------------------------------------------------
# 7. Build Execution
# ---------------------------------------------------------
# This block tells Packer which sources to actually build when you run `packer build`
build {
  sources = ["source.qemu.almalinux9"]
}
