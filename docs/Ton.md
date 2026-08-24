# Pair A — Packer + Terraform Infrastructure

## 1. Objective

Build a **repeatable VM provisioning pipeline** where:

```text
AlmaLinux ISO
     ↓
   Packer
     ↓
Golden QCOW2 Image
     ↓
  Terraform
     ↓
Libvirt VM
     ↓
VM Validation
```

**Goal:** Avoid manually installing and configuring every VM. Build the OS image once, then  use Terraform to consistently recreate the infrastructure.

---

## 2. Packer — Build the Golden Image

**Purpose:** Create a standardized, reusable AlmaLinux image that Terraform can use as the base for VMs.

Packer uses **QEMU/KVM** to automatically install AlmaLinux 9.4 using Kickstart.

### Key configuration

| Configuration | Purpose |
|---|---|
| AlmaLinux 9.4 Minimal | Provides a lightweight base OS |
| QEMU/KVM | Runs the automated VM build |
| 20 GB QCOW2 | Provides the reusable VM disk image |
| 2 GB RAM / 2 vCPU | Resources used only during image creation |
| UEFI/OVMF | Ensures the image uses modern UEFI boot |
| SHA-256 checksum | Verifies ISO integrity |
| Kickstart | Automates the OS installation |
| `cloud-init` | Allows VM-specific configuration later |
| `qemu-guest-agent` | Allows libvirt/Terraform to obtain guest information |
| SSH enabled | Allows Packer to verify and finalize the installation |

Output:

```text
/var/tmp/packer_output/almalinux9-golden.qcow2
```

### Why a golden image?

Instead of:

```text
VM → Install OS → Configure → Repeat
```

we use:

```text
Install once → Golden Image → Clone for every VM
```

This makes VM provisioning **faster and consistent**.

---

## 3. Kickstart — Automated OS Installation

**Purpose:** Make the AlmaLinux installation completely unattended and ensure every golden image starts with the same layout.

Kickstart configures:

- Minimal AlmaLinux environment
- Language and keyboard
- UTC timezone
- DHCP networking
- SSH
- QEMU guest agent
- `cloud-init`
- Initial `ansible` user
- UEFI partitioning
- LVM filesystem layout

### Filesystem layout

```text
/boot/efi
/boot
/
/var
/var/log
/var/log/audit
/var/tmp
/opt
swap
```

**Why separate filesystems?**

The layout provides better isolation between important directories and prepares the image for later infrastructure/security requirements.

---

## 4. Terraform — Provision the VM

**Purpose:** Convert the Packer image into an actual VM infrastructure environment managed as code.

Terraform uses:

```text
dmacvicar/libvirt
qemu:///system
```

### Resource flow

```text
Golden Image
     │
     ▼
  Base Volume
     │
     ├── OS Disk
     ├── Data Disk 1
     └── Data Disk 2
             │
             ▼
          VM
```

Terraform manages:

- Libvirt storage pool
- Base OS image
- VM OS disks
- Additional data disks
- Cloud-init
- VM CPU/RAM
- Network
- UEFI configuration
- VNC/serial console

**Why Terraform?**

The VM becomes **Infrastructure as Code**. Instead of manually creating the VM, its configuration is declared in `.tf` files and can be recreated with:

```bash
terraform apply
```

---

## 5. Storage Pool and Volumes

**Purpose:** Organize and manage all VM storage through libvirt.

Terraform creates:

```text
pool_a
```

Inside the pool:

```text
almalinux9-base.qcow2
pa-node-1-os.qcow2
pa-node-1-data1.qcow2
pa-node-1-data2.qcow2
cloud-init ISO
```

The VM OS disk is cloned from the Packer golden image.

**Why clone the image?**

The golden image remains the reusable source while each VM receives its own disk.

---

## 6. VM Hardware and UEFI

**Purpose:** Ensure the provisioned VM has the required virtual hardware and can boot the same way as the golden image.

Configuration:

```text
RAM:          1 GB
vCPU:         2
CPU:          host-passthrough
Machine:      q35
Firmware:     UEFI/OVMF
```

### Why `host-passthrough`?

AlmaLinux 9 requires CPU features associated with newer x86-64 CPU levels. Passing through the host CPU features avoids compatibility problems with the default virtual CPU.

### Why UEFI?

The Packer image is built for UEFI, so Terraform must provision the VM with matching UEFI firmware.

---

## 7. Cloud-Init

**Purpose:** Apply VM-specific settings after the generic golden image is cloned.

Terraform generates a cloud-init ISO that configures:

- `sysadmin` user
- SSH public key
- Hostname
- FQDN
- Sudo access
- Password authentication disabled
- Root SSH login disabled

This keeps the golden image **generic**, while each VM receives its own identity and access configuration.

```text
Golden Image
    │
    ├── Common OS
    │
    ▼
Terraform + Cloud-Init
    │
    ├── Hostname
    ├── SSH key
    └── sysadmin
    │
    ▼
Unique VM
```

---

## 8. Terraform → Ansible Inventory

**Purpose:** Automatically pass the newly provisioned VM information to the next automation stage without manually entering IP addresses.

Terraform obtains the VM's DHCP address and generates:

```text
ansible/inventory/hosts.ini
```

Template:

```ini
[all]
%{ for name, ip in nodes ~}
${name} ansible_host=${ip} ansible_user=sysadmin
%{ endfor ~}

[pair_a]
%{ for name, ip in nodes ~}
${name}
%{ endfor ~}
```

Example result:

```ini
[all]
pa-node-1 ansible_host=192.168.122.88 ansible_user=sysadmin

[pair_a]
pa-node-1
```

**Why automate this?**

If Terraform recreates the VM and its IP changes, the inventory can be regenerated instead of being manually updated.

---

## 9. Live `virsh` Validation

**Purpose:** Prove that Terraform's declared infrastructure actually exists and is configured correctly in libvirt.

### Show VM

```bash
virsh list
```

**Goal:** Confirm the VM is running.

### Prove UEFI

```bash
virsh dumpxml pa-node-1 | grep -A5 -B2 firmware
```

**Goal:** Demonstrate that the VM uses OVMF/UEFI.

### List disks

```bash
virsh domblklist pa-node-1
```

**Goal:** Match the actual VM disks to Terraform's declared volumes.

Expected:

```text
pa-node-1-os.qcow2
pa-node-1-data1.qcow2
pa-node-1-data2.qcow2
```

### Walk the storage pool

```bash
virsh pool-info pool_a
virsh vol-list pool_a
```

**Goal:** Demonstrate how Terraform resources map to libvirt storage.

### Attach/detach disk

```bash
virsh attach-disk pa-node-1 <disk> vdb --live --config
```

Then:

```bash
virsh domblklist pa-node-1
```

Detach:

```bash
virsh detach-disk pa-node-1 vdb --live --config
```

**Goal:** Demonstrate live VM storage management through libvirt.

---

## 10. DESTROY_AND_REBUILD

**Purpose:** Demonstrate that the environment is reproducible and does not depend on manually created infrastructure.

With `DESTROY_AND_REBUILD` enabled:

```text
Existing VM
    ↓
Terraform Destroy
    ↓
Terraform Rebuild
    ↓
Golden Image
    ↓
New VM
    ↓
New IP
    ↓
Updated Inventory
```

The important concept is:

> **The VM is disposable; the code and golden image are the source of truth.**

### Core Takeaway

**Packer standardizes the OS. Terraform provisions the infrastructure. Libvirt/virsh provides visibility and validation.**

The result is a reproducible workflow:

**Build once → Provision automatically → Validate → Destroy → Rebuild.**
