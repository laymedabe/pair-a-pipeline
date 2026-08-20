# Comprehensive Pipeline Documentation & Codebase Guide

This documentation serves as a complete reference for the Pair A Trainee Pipeline repository. It provides a detailed breakdown of the end-to-end procedural workflow, explains the purpose and functionality of every major code component, and answers the "Why" and "How" for all technical decisions made during the project.

---

## Part 1: End-to-End Procedural Workflow

This section outlines the exact sequence of events that occurs from the moment the pipeline is triggered until the final compliance report is generated.

### Step 1: Initialization & Checkout
1. **Trigger:** The pipeline is triggered manually in the Jenkins Web UI or automatically via a webhook (e.g., from a Git push).
2. **Checkout:** Jenkins clones the `main` branch of the `pair-a-pipeline` repository into its local workspace (`/var/lib/jenkins/workspace/Pair-A-Pipeline`).
3. **Environment Setup:** Jenkins reads the `Jenkinsfile` and securely loads the Ansible Vault password from its credential store into an environment variable (`VAULT_PASS`).

### Step 2: Teardown Infrastructure (Optional)
1. **Condition:** This stage only runs if the `DESTROY_AND_REBUILD` parameter is checked.
2. **Action:** Jenkins navigates to the `terraform/` directory. It generates a fresh, ephemeral SSH key pair (`id_rsa` and `id_rsa.pub`). 
3. **Destruction:** It runs `terraform destroy`, which reads the `terraform.tfstate` file to locate the existing virtual machine and completely deletes it from the Libvirt/KVM hypervisor.

### Step 3: Build Golden Image (Optional)
1. **Condition:** Runs if either `REBUILD_IMAGE` or `DESTROY_AND_REBUILD` is checked.
2. **Action:** Jenkins navigates to the `packer/` directory. It executes `packer build`, which launches a temporary virtual machine and uses the `kickstart.cfg` file to automatically install AlmaLinux 9 from an ISO, partitioning the disk according to CIS standards.
3. **Output:** A finalized "Golden Image" (`.qcow2`) is generated and saved to the hypervisor's storage pool.

### Step 4: Provision Infrastructure
1. **Action:** Jenkins navigates to the `terraform/` directory. It runs `terraform init` and `terraform apply`.
2. **Provisioning:** Terraform instructs the Libvirt provider to clone the Golden Image, create two additional data disks, and launch a new Virtual Machine (`pa-node-1`).
3. **Cloud-Init:** During boot, `cloud_init.cfg` runs, setting the hostname and injecting the `id_rsa.pub` key (generated in Step 2) into the VM to allow SSH access.
4. **Dynamic Inventory:** Terraform outputs the VM's newly assigned IP address into the `ansible/inventory/hosts.ini` file.

### Step 5: Harden with Ansible
1. **Dependencies:** Jenkins navigates to `ansible/` and downloads the official MindPoint Group CIS Level 1 hardening role specified in `requirements.yml`.
2. **Execution:** Jenkins runs `ansible-playbook`, passing the dynamic inventory and the ephemeral `id_rsa` private key.
3. **Configuration:** Ansible connects to the VM, formats and mounts the extra data disks (XFS on VirtIO), and applies all security settings defined in `group_vars/all/vars.yml`.

### Step 6: Audit & Compliance (Goss)
1. **Action:** As the final step of the Ansible role, Goss (a server testing tool) scans the VM to verify compliance against the CIS Level 1 baseline.
2. **Output:** It generates JSON and HTML reports detailing passing and failing tests.

### Step 7: Post Actions (Cleanup & Archival)
1. **Archival:** Jenkins securely copies the Goss audit reports from the workspace and saves them permanently in the Jenkins Web UI.
2. **Cleanup:** If the `CLEAN_WORKSPACE` parameter is checked, Jenkins deletes the entire workspace, ensuring no sensitive files (like the SSH key or Vault password) are left behind on the disk.

---

## Part 2: Codebase Explanation (Why & How)

This section contains the full code for every critical file in the repository, explaining its purpose, how it works, and the reasoning behind its architecture.

### 1. The Jenkins Orchestrator (`Jenkinsfile`)

**What it is:** The declarative Groovy script that dictates the entire CI/CD workflow.
**How it works:** It is divided into `parameters`, `environment`, and `stages` blocks. Each stage enters a specific directory (e.g., `dir('terraform')`) and executes shell commands (`sh`).
**Why we wrote it this way:**
- **Ephemeral Keys:** We run `ssh-keygen` inside the pipeline rather than storing keys in Git. This ensures that every deployment uses a unique, temporary key, maximizing security.
- **Role Patching:** We run `sed -i "s/2.16.1/2.14.0/g"` on the Ansible role because AlmaLinux 9 ships with an older version of Ansible. This dynamic patch prevents the pipeline from failing due to strict version dependencies.
- **Workspace Cleanup:** We added the `CLEAN_WORKSPACE` parameter. By default, it cleans the workspace to prevent state leakage and save disk space. However, we can uncheck it to intentionally leave the ephemeral SSH key behind, allowing us to log into the VM manually for demonstrations.

<details>
<summary><b>Click to view Jenkinsfile source code</b></summary>

```groovy
pipeline {
    agent any
    
    parameters {
        booleanParam(name: 'DESTROY_AND_REBUILD', defaultValue: false, description: 'Destroy Terraform resources first, then run a full fresh rebuild')
        booleanParam(name: 'REBUILD_IMAGE', defaultValue: false, description: 'Rebuild the Packer image first, else reuse the existing one')
        booleanParam(name: 'CLEAN_WORKSPACE', defaultValue: true, description: 'Wipe the workspace clean after pipeline finishes')
    }

    environment {
        // Vault password fetched from Jenkins credentials (never hardcoded in Git)
        VAULT_PASS = credentials('ansible-vault-password')
        TF_IN_AUTOMATION = 'true'
    }

    stages {
        stage('Teardown Infrastructure') {
            when {
                expression { params.DESTROY_AND_REBUILD }
            }
            steps {
                dir('terraform') {
                    // Wiped workspace means a destroy button with nothing to destroy!
                    // In a production environment, state lives in a persistent remote backend 
                    // (e.g., S3, pg, Consul) so we can run a destroy even on a fresh Jenkins workspace.
                    sh 'rm -f id_rsa id_rsa.pub'
                    sh 'ssh-keygen -t rsa -b 4096 -f id_rsa -N ""'
                    sh 'terraform init'
                    sh 'terraform destroy -auto-approve'
                }
            }
        }

        stage('Build Golden Image') {
            when {
                expression { params.REBUILD_IMAGE || params.DESTROY_AND_REBUILD }
            }
            steps {
                dir('packer') {
                    sh '/usr/bin/packer init build.pkr.hcl'
                    sh '/usr/bin/packer build -force build.pkr.hcl'
                }
            }
        }

        stage('Provision Infrastructure') {
            steps {
                dir('terraform') {
                    sh 'terraform init'
                    sh 'terraform apply -auto-approve'

                    // Wait for the VM to boot and get its IP
                    sh 'sleep 20'
                    sh 'terraform apply -auto-approve'
                }
            }
        }

        stage('Harden with Ansible') {
            steps {
                dir('ansible') {
                    // Install the pinned CIS role and required collections from requirements.yml
                    sh 'ansible-galaxy role install -r requirements.yml -p roles/ --force'
                    sh 'ansible-galaxy collection install -r requirements.yml --force'
                    
                    // Create a dummy vault password file from the Jenkins credential for this run
                    sh 'echo $VAULT_PASS > vault_password.txt'

                    // Patch the strict version check out of the freshly downloaded role
                    sh 'sed -i "s/2.16.1/2.14.0/g" roles/rhel9-cis/vars/main.yml'

                    // Run the playbook using only Level 1 (group_vars) and Level 2 (playbook vars)
                    sh "ansible-playbook -i inventory/hosts.ini playbook.yml --private-key ../terraform/id_rsa --vault-password-file vault_password.txt"
                }
            }
        }

        stage('Audit & Compliance (Goss)') {
            steps {
                dir('ansible') {
                    // Goss runs as part of the lockdown role if setup_audit / run_audit are triggered.
                    // The report is generated natively by the role.
                    sh 'echo "Goss audit report ready for archival"' 
                }
            }
        }
    }

    post {
        always {
            // Archive the Goss report artifact back to Jenkins
            archiveArtifacts artifacts: 'ansible/audit_reports/*.json, ansible/audit_reports/*.html', allowEmptyArchive: true
            
            // Replace the old cleanWs() line with this block:
            script {
                if (params.CLEAN_WORKSPACE) {
                    cleanWs()
                } else {
                    echo 'Skipping workspace cleanup so files can be presented!'
                }
            }
        }

        failure {
            echo 'Pipeline encountered an error. Failing loudly!'
        }
    }}
```
</details>

---

### 2. Infrastructure Provisioning (`terraform/`)

#### `main.tf`
**What it is:** The primary Terraform configuration file.
**How it works:** It uses the `dmacvicar/libvirt` provider to define resources like `libvirt_volume` (for disks) and `libvirt_domain` (for the VM itself). 
**Why we wrote it this way:** We use dynamic loops (`for_each` or `count`) to allow scaling. We also use a `lifecycle { ignore_changes = [cloudinit] }` block to prevent a known bug where Terraform tries to constantly replace the cloud-init ISO on every run.

<details>
<summary><b>Click to view main.tf source code</b></summary>

```hcl
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

  lifecycle {
    ignore_changes = [
      cloudinit,
    ]
  }

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
```
</details>

#### `variables.tf` & `outputs.tf`
**What it is:** The inputs and outputs of the Terraform module.
**How it works:** `variables.tf` defines the VM count, memory, and disk sizes. `outputs.tf` takes the final IP address of the VM and uses a `templatefile` function to dynamically generate the Ansible `hosts.ini` file.
**Why we wrote it this way:** Hardcoding IP addresses breaks automation. By dynamically generating the inventory, Ansible always knows exactly where to connect, regardless of what IP the DHCP server assigned.

<details>
<summary><b>Click to view variables.tf & outputs.tf source code</b></summary>

**variables.tf:**
```hcl
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
```

**outputs.tf:**
```hcl
# Output the IP addresses of the provisioned VMs
output "node_ips" {
  value = {
    for idx, domain in libvirt_domain.pa_node : domain.name => try([for addr in domain.network_interface[0].addresses : addr if length(regexall("^[0-9.]+$", addr)) > 0][0], "offline")
  }
  description = "The IP addresses of the deployed nodes"
}

# Generate Ansible dynamic inventory
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tpl", {
    nodes = {
      for idx, domain in libvirt_domain.pa_node : domain.name => try([for addr in domain.network_interface[0].addresses : addr if length(regexall("^[0-9.]+$", addr)) > 0][0], "offline")
    }
  })
  filename = "${path.module}/../ansible/inventory/hosts.ini"
}
```
</details>

#### `cloud_init.cfg`
**What it is:** The initial configuration script executed by the VM on its very first boot.
**How it works:** It sets the hostname (`pa-node-1`), disables root SSH login, and creates a `sysadmin` user. It then injects the public SSH key into the `sysadmin` user's `authorized_keys` file.
**Why we wrote it this way:** Cloud-init bridges the gap between Terraform and Ansible. It provides the initial "bootstrap" access required for Ansible to log in and take over configuration management.

<details>
<summary><b>Click to view cloud_init.cfg source code</b></summary>

```yaml
#cloud-config

# Update packages on first boot
package_update: false
package_upgrade: false

# Set the default user and add your SSH key so you can log in
users:
  - name: sysadmin
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key} # We will pass this in from Terraform

# Set the hostname (passed from Terraform)
hostname: ${hostname}
fqdn: ${hostname}.localdomain
manage_etc_hosts: true

# Keep ssh configuration clean
ssh_pwauth: false
disable_root: true
```
</details>

---

### 3. Golden Image Creation (`packer/`)

#### `build.pkr.hcl`
**What it is:** The Packer configuration file.
**How it works:** It defines a QEMU builder that downloads an AlmaLinux 9 ISO, boots it, types in a boot command via VNC, and points it to the `kickstart.cfg` file.
**Why we wrote it this way:** Building an image from an ISO takes time. By pre-building a "Golden Image" with Packer, Terraform can simply clone it in seconds, drastically speeding up the pipeline.

<details>
<summary><b>Click to view build.pkr.hcl source code</b></summary>

```hcl
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
```
</details>

#### `kickstart.cfg`
**What it is:** An automated answer file for the Red Hat installer (Anaconda).
**How it works:** It answers all the installation prompts (language, timezone, partitioning, root password) automatically.
**Why we wrote it this way:** It ensures the foundational filesystem (e.g., separating `/var`, `/tmp`, and `/var/log/audit`) perfectly aligns with CIS requirements before Ansible even touches the machine.

<details>
<summary><b>Click to view kickstart.cfg source code</b></summary>

```ini
# ==============================================================================
# AlmaLinux 9 Unattended Kickstart Configuration (Pair A)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Base Installation Settings
# ------------------------------------------------------------------------------
# Force the installer to run in text mode rather than graphical UI to save memory.
text

# Automatically agree to the End User License Agreement.
eula --agreed

# Automatically reboot the virtual machine once the installation completes.
reboot

# Define the installation sources using the AlmaLinux 9.4 minimal vault.
url --url="http://vault.almalinux.org/9.4/BaseOS/x86_64/os/"
repo --name="AppStream" --baseurl="http://vault.almalinux.org/9.4/AppStream/x86_64/os/"

# ------------------------------------------------------------------------------
# 2. Localization & Network
# ------------------------------------------------------------------------------
# Set system language and keyboard layout to US English.
lang en_US.UTF-8
keyboard us

# Set system timezone to UTC.
timezone UTC

# Enable the first network interface (vda) and configure it via DHCP so it can 
# download packages during the build process. Force Google DNS to bypass QEMU SLIRP DNS issues.
network --bootproto=dhcp --device=link --nameserver=8.8.8.8 --activate

# ------------------------------------------------------------------------------
# 3. User Provisioning & Services
# ------------------------------------------------------------------------------
# Set a plaintext root password (can be hardened later via Ansible).
rootpw --plaintext toor

# Create the primary 'ansible' user and add it to the wheel group for sudo access.
# Packer uses this account to log in and issue the final shutdown command.
user --name=ansible --groups=wheel --plaintext --password=ansible

# CRITICAL: Enable the SSH daemon and the QEMU guest agent. 
# sshd is required by Packer to finalize the build.
# qemu-guest-agent is required by libvirt/Terraform to fetch the dynamic IP address.
services --enabled=sshd,qemu-guest-agent

# ------------------------------------------------------------------------------
# 4. Partitioning & LVM (Pair A Layout)
# ------------------------------------------------------------------------------
# Wipe all existing partitions and initialize the disk label on the primary virtual disk (vda).
clearpart --all --initlabel --drives=vda

# Create the EFI System Partition (ESP) required for UEFI boot.
part /boot/efi --fstype="efi" --size=600 --fsoptions="umask=0077,shortname=winnt"

# Create the standard boot partition (outside of LVM).
part /boot --fstype="xfs" --size=1024

# Create a Physical Volume taking up the remaining disk space.
part pv.01 --fstype="lvmpv" --size=1 --grow

# Create the Volume Group and assign it the specific Pair A name.
volgroup vg_sys_a pv.01

# --- CIS Level 1 Required Logical Volumes ---
# Separate partitions ensure one filled directory doesn't crash the entire OS.
logvol /var            --fstype="xfs"  --size=2048 --name=var           --vgname=vg_sys_a
logvol /var/log        --fstype="xfs"  --size=1024 --name=var_log       --vgname=vg_sys_a
logvol /var/log/audit  --fstype="xfs"  --size=1024 --name=var_log_audit --vgname=vg_sys_a
logvol /var/tmp        --fstype="xfs"  --size=1024 --name=var_tmp       --vgname=vg_sys_a
logvol swap            --fstype="swap" --size=1024 --name=swap          --vgname=vg_sys_a

# --- Pair A Assigned Extra Logical Volume ---
logvol /opt            --fstype="xfs"  --size=2048 --name=lv_opt        --vgname=vg_sys_a

# --- Root Logical Volume ---
# Root gets a floor size of 4GB but uses --grow to expand and fill whatever 
# space is left in the 20GB disk image.
logvol /               --fstype="xfs"  --size=4096 --name=root          --vgname=vg_sys_a --grow

# ------------------------------------------------------------------------------
# 5. Software Packages
# ------------------------------------------------------------------------------
%packages
# Install the minimal AlmaLinux environment to keep the attack surface low.
@^minimal-environment

# cloud-init makes the golden image reusable by regenerating host keys and 
# network data on first boot.
cloud-init

# Explicitly install the agent so Terraform can communicate with the VM.
qemu-guest-agent
%end
```
</details>

---

### 4. Configuration Management (`ansible/`)

#### `playbook.yml`
**What it is:** The master Ansible playbook.
**How it works:** It contains `pre_tasks` that format the raw VirtIO data disks using the `xfs` filesystem and mount them persistently. It then calls the `rhel9-cis` role to harden the OS.
**Why we wrote it this way:** Formatting disks must happen before hardening. By placing the `rhel9cis_warning_banner` variable here, we demonstrate Ansible's "Level 2" variable precedence, proving that play-level variables override group-level variables.

<details>
<summary><b>Click to view playbook.yml source code</b></summary>

```yaml
---
- name: Pair A Node Setup and Hardening
  hosts: all
  become: yes

  vars:
    # ---------------------------------------------------------
    # Variable Precedence Demonstration (Play Vars)
    # This overrides group_vars/all/vars.yml (Level 2 of 3)
    # ---------------------------------------------------------
    rhel9cis_warning_banner: "PLAYBOOK LEVEL ACCESS BANNER"

  pre_tasks:
    - name: Ensure xfsprogs is installed
      package:
        name: xfsprogs
        state: present

    - name: Format first data disk as XFS (virtio bus = /dev/vdb)
      filesystem:
        fstype: xfs
        dev: /dev/vdb

    - name: Format second data disk as XFS (virtio bus = /dev/vdc)
      filesystem:
        fstype: xfs
        dev: /dev/vdc

    - name: Mount first data disk
      mount:
        path: /mnt/data1
        src: /dev/vdb
        fstype: xfs
        state: mounted

    - name: Mount second data disk
      mount:
        path: /mnt/data2
        src: /dev/vdc
        fstype: xfs
        state: mounted

  roles:
    - role: rhel9-cis
      tags:
        - hardening
```
</details>

#### `group_vars/all/vars.yml`
**What it is:** The global variable file (Level 1 precedence) that configures the CIS role.
**How it works:** It overrides the default behavior of the MindPoint Group CIS role.
**Why we wrote it this way:**
- **`rhel9cis_level_2: false`:** This is the programmatic proof that we adhered to the project brief's "Level 1 Server" requirement, preventing the highly restrictive Level 2 rules from applying.
- **`rhel9cis_syslog: rsyslog`:** Forces the use of rsyslog instead of journald, as required by Pair A.
- **`rhel9cis_pam_faillock_deny: 0`:** Disables permanent user account lockouts to ensure we don't accidentally lock ourselves out during testing and live demonstrations.

<details>
<summary><b>Click to view vars.yml source code</b></summary>

```yaml
---
# Pair A Tailoring Variables
# Sourced from RHEL9-CIS 2.3.0 defaults/main.yml

# 1. Login Banner
# (Control 1.7.2 / 1.7.3)
rhel9cis_level_2: false
rhel9cis_warning_banner: "AUTHORIZED ACCESS ONLY"

# 2. SSHD Timeout
# (Control 5.1.9)
rhel9cis_sshd_clientaliveinterval: 300
rhel9cis_sshd_clientalivecountmax: 0

# 3. Use rsyslog for logging
# (Control 6.2.1.x and 6.2.3.x) 
# Options are 'journald' or 'rsyslog'. 
rhel9cis_syslog: rsyslog

# 4. No account lockouts on failed password attempts (Safety / Security)
# (Controls 5.3.3.1.1 through 5.3.3.1.3)
# Setting deny to 0 disables the faillock lockout feature.
rhel9cis_pam_faillock_deny: 0
# To explicitly tell the role not to enforce the lockout rules, we can also toggle them off:
rhel9cis_rule_5_3_3_1_1: false
rhel9cis_rule_5_3_3_1_2: false
rhel9cis_rule_5_3_3_1_3: false
# 5. Cloud Environment & Automation Exceptions
# Since this is an automated cloud deployment, we use SSH keys and disable passwords.
# Therefore, we must disable CIS rules that check for local passwords, or the playbook will fail.
rhel9cis_rule_5_2_4: false # Disables the check requiring the 'sysadmin' user to have a password
rhel9cis_rule_5_4_2_4: false # Disables the check requiring the 'root' user to have a password

# 6. Authselect Profile
# The CIS role requires us to explicitly provide a custom authselect profile name 
# to prove we aren't just using the default unmodified configuration.
rhel9cis_authselect_custom_profile_name: "custom_cis_profile"

# 7. Ansible Version Compatibility
# The CIS role aggressively asserts that Ansible >= 2.16.1 must be used.
# AlmaLinux 9 ships with Ansible 2.14.18 natively. By overriding this variable,
# we bypass the role's strict version check so it runs smoothly on our native OS.
min_ansible_version: "2.14.0"

# 8. Goss Audit Configuration
# Required by Jenkins to execute the final audit phase and archive the report.
setup_audit: true
run_audit: true
fetch_audit_output: true
audit_output_destination: "{{ playbook_dir }}/audit_reports/"
audit_format: json
```
</details>

---

## Part 3: Setup & Installation Guide (How to Recreate this Project from Scratch)

If you are starting from a completely blank slate and want to recreate this entire CI/CD pipeline from scratch, follow these step-by-step procedures.

### Step 1: Prepare the Local Environment
1. **Install Dependencies:** Ensure your host machine (AlmaLinux/RHEL) has `git`, `packer`, `terraform`, `ansible`, and `libvirt` (KVM/QEMU) installed.
2. **Start Libvirt:** Ensure the libvirt daemon is running: `sudo systemctl enable --now libvirtd`.

### Step 2: Initialize the Git Repository
1. Create a new directory and initialize Git:
   ```bash
   mkdir pair-a-pipeline && cd pair-a-pipeline
   git init
   ```
2. Create the necessary directory structure:
   ```bash
   mkdir packer terraform ansible docs
   mkdir -p ansible/group_vars/all ansible/inventory
   ```
3. Create the `.gitignore` file to ensure sensitive files like SSH keys and Terraform state backups are never committed.

### Step 3: Write the Infrastructure Code (Packer & Terraform)
1. **Packer:** Inside the `packer/` folder, create the `kickstart.cfg` answer file for AlmaLinux 9, and write the `build.pkr.hcl` file to build the golden image `.qcow2`.
2. **Terraform:** Inside the `terraform/` folder, create `main.tf` to define the libvirt provider and resources, `variables.tf` for scaling inputs, and `cloud_init.cfg` to set up the default `sysadmin` user. 
3. **Outputs:** Write the `outputs.tf` file to automatically generate the Ansible inventory file upon completion.

### Step 4: Write the Configuration Management Code (Ansible)
1. **Requirements:** Inside the `ansible/` folder, create `requirements.yml` and define the `ansible-lockdown/RHEL9-CIS` role.
2. **Playbook:** Create `playbook.yml` to format the raw data disks and execute the CIS role.
3. **Variables:** Inside `ansible/group_vars/all/`, create `vars.yml`. This is where you disable `rhel9cis_level_2` and configure tailoring variables like `rsyslog` and `pam_faillock`.

### Step 5: Configure Jenkins Server
1. **Install Plugins:** Ensure your Jenkins server has the **Git plugin** and **Pipeline plugin** installed.
2. **Create Ansible Vault Credential:** 
   - In Jenkins, navigate to **Manage Jenkins** -> **Credentials**.
   - Add a new "Secret text" credential.
   - Enter your secure vault password.
   - Set the ID exactly to: `ansible-vault-password`.
3. **Create the Jenkins Item:**
   - On the Jenkins dashboard, click **New Item**.
   - Name it `Pair-A-Pipeline` and select **Pipeline**.
   - Scroll down to the **Pipeline** section.
   - Set "Definition" to **Pipeline script from SCM**.
   - Set "SCM" to **Git**.
   - Enter your repository URL (e.g., `https://github.com/laymedabe/pair-a-pipeline.git`).
   - Set the branch to `*/main` and the script path to `Jenkinsfile`.

### Step 6: Orchestrate the Pipeline
1. Create the `Jenkinsfile` in the root of your repository.
2. Define your parameters (`DESTROY_AND_REBUILD`, `CLEAN_WORKSPACE`).
3. Define the stages mapping to the tools we set up: `Teardown`, `Packer`, `Terraform`, `Ansible`, and `Goss Audit`.
4. Commit all files and push to your remote Git repository:
   ```bash
   git add .
   git commit -m "Initial commit: End-to-end pipeline setup"
   git push origin main
   ```

### Step 7: Execution
1. Go to your Jenkins dashboard and click **Build with Parameters**.
2. For the very first run, check **DESTROY_AND_REBUILD** and **REBUILD_IMAGE** so the entire infrastructure builds from scratch.
3. Watch the pipeline logs as Packer builds the image, Terraform spins up the VM, Ansible hardens it, and Goss generates the final 90%+ compliance report!
