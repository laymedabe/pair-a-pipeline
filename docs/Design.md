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


---

# Dave's Track: Jenkins Automation & Ansible CIS Hardening

## Project Objective
The overall objective of this project is to build an automated CI/CD pipeline that provisions, configures, and hardens a secure AlmaLinux 9 virtual machine from scratch. The final deliverable must successfully pass a strict CIS (Center for Internet Security) Level 1 audit, demonstrating the integration of infrastructure-as-code and configuration management best practices.

## Overview
This document details my specific contributions to the Pair A Trainee Pipeline project. While my partner handled the infrastructure provisioning (Packer and Terraform), my responsibility was to build the CI/CD orchestration using Jenkins and implement the configuration management and security hardening using Ansible.

## 1. Jenkins CI/CD Pipeline (`Jenkinsfile`)

### Objective
To create a fully automated, declarative pipeline that orchestrates the entire infrastructure lifecycle without human intervention. The pipeline governs Terraform state, manages ephemeral Packer builds, and secures secrets for Ansible.

### Detailed Stage Breakdown & Implementations

#### 1. Parameterized Build Logic
```groovy
parameters {
    booleanParam(name: 'DESTROY_AND_REBUILD', defaultValue: false, description: 'Destroy Terraform resources first, then run a full fresh rebuild')
    booleanParam(name: 'REBUILD_IMAGE', defaultValue: false, description: 'Rebuild the Packer image first, else reuse the existing one')
    booleanParam(name: 'CLEAN_WORKSPACE', defaultValue: true, description: 'Wipe the workspace clean after pipeline finishes')
}
```
**Why I did this:** 
Hardcoding pipeline behavior is inefficient. By adding boolean parameters, we created a modular pipeline where we can selectively trigger heavy operations. The `when { expression { ... } }` blocks in the stages dynamically evaluate these parameters to either skip or execute stages (e.g., bypassing Packer builds to save time during iterative Terraform testing). The `CLEAN_WORKSPACE` parameter was specifically added as a refinement to allow the Jenkins workspace to persist when we need to manually SSH into the VM for live demonstrations.

#### 2. Vault and Credential Security
```groovy
environment {
    VAULT_PASS = credentials('ansible-vault-password')
}
// ... later in the playbook execution ...
withCredentials([sshUserPrivateKey(credentialsId: 'vm-ssh-private-key', keyFileVariable: 'SSH_KEY')]) {
    sh 'echo $VAULT_PASS > vault_password.txt'
    sh "ansible-playbook ... --private-key $SSH_KEY --vault-password-file vault_password.txt"
}
```
**Why I did this:**
Initially, the pipeline dynamically generated a new, ephemeral SSH key pair during the run, or relied on plaintext passwords. To align with standard CI/CD and CIS best practices, we moved all sensitive material out of Git. The Ansible Vault password and the SSH private key are stored securely in Jenkins Credentials. The pipeline pulls them into ephemeral environment variables during the run, injecting them directly into the `ansible-playbook` command, preventing credential leakage.

#### 3. Bypassing Strict Role Dependencies
```groovy
sh 'sed -i "s/2.16.1/2.14.0/g" roles/rhel9-cis/vars/main.yml'
```
**Why I did this:**
The official MindPoint Group CIS role enforces a strict check for Ansible `>= 2.16.1`. Because AlmaLinux 9 natively ships with `ansible-core 2.14.x`, the pipeline would crash before running. Instead of forcing a pip upgrade of Ansible which pollutes the Jenkins agent, I used `sed` to dynamically patch the downloaded role on the fly, allowing it to run smoothly on our native OS environment.

#### 4. Handling Workspace State Leakage & Artifact Archival
```groovy
post {
    always {
        archiveArtifacts artifacts: 'ansible/audit_reports/*.json, ansible/audit_reports/*.html', allowEmptyArchive: true
        script { if (params.CLEAN_WORKSPACE) { cleanWs() } }
    }
}
```
**Why I did this:**
After Ansible hardens the VM, Goss generates compliance reports. The `archiveArtifacts` step securely pulls these HTML/JSON reports out of the workspace and attaches them to the Jenkins build history for permanent auditing. Immediately after, `cleanWs()` wipes the entire workspace (including the `vault_password.txt` file we temporarily created) to prevent secrets from lingering on the disk and to avoid "state leakage" where a future build succeeds only because of leftover files.

---

## 2. Ansible Configuration & CIS Hardening

### Objective
To securely configure the raw AlmaLinux 9 VM provisioned by Terraform and enforce the strict CIS (Center for Internet Security) Level 1 baseline, while formatting the attached raw data disks.

### Detailed Implementations & Precedence Hierarchy

#### 1. Disk Formatting & Persistent Mounting (`pre_tasks`)
```yaml
  pre_tasks:
    - name: Format first data disk as XFS
      filesystem:
        fstype: xfs
        dev: /dev/vdb
    - name: Mount first data disk
      mount:
        path: /mnt/data1
        src: /dev/vdb
        fstype: xfs
        state: mounted
```
**Why I did this:**
Terraform provided two raw data disks on the `virtio` bus (`/dev/vdb`, `/dev/vdc`). Because the CIS hardening role assumes a functional filesystem, I used Ansible `pre_tasks` (which execute before assigned roles) to format the disks with the `xfs` filesystem (as required by Pair A) and added them to `/etc/fstab` via the `mount` module so they persist across reboots.

#### 2. Proof of CIS Level 1 Enforcement
```yaml
rhel9cis_level_2: false
```
**Why I did this:** 
The Trainee Pipeline Task Brief specifically mandates **'Level 1 - Server only'** for the lockdown role. The MindPoint Group `rhel9-cis` role includes both Level 1 and Level 2 security profiles. Level 2 rules are much more restrictive and often break application functionality. By explicitly defining `rhel9cis_level_2: false` in my `group_vars`, I provided programmatic proof that I deliberately disabled the Level 2 rules to strictly adhere to the project brief.

#### 3. Variable Precedence Demonstration (Level 1 vs Level 2)
I demonstrated a deep understanding of Ansible variable precedence by utilizing Level 1 (`group_vars`) and Level 2 (`playbook.yml`) variables to tailor the CIS role.

**Level 1 (`vars.yml` - Group/Global scope):**
```yaml
rhel9cis_syslog: rsyslog
rhel9cis_sshd_clientaliveinterval: 300
rhel9cis_pam_faillock_deny: 0
```
* **rsyslog over journald**: Explicitly forces the role to configure `rsyslog` instead of `journald`, fulfilling a specific Pair A design requirement.
* **pam_faillock_deny**: Disables the PAM account lockout module. If set to the CIS default, entering the wrong SSH key 4 times would permanently lock the `sysadmin` account, which is incredibly dangerous during testing and demonstrations.

**Level 2 (`playbook.yml` - Play scope):**
```yaml
  vars:
    rhel9cis_warning_banner: "PLAYBOOK LEVEL ACCESS BANNER"
```
* By placing this variable directly in the playbook, it overrides any banner defined in `group_vars`, successfully demonstrating Level 2 precedence (which has higher priority than Level 1 group variables).

#### 4. Understanding the RSyslog Duplication Quirk
During testing, we noticed that logs like `sudo` and `ssh` were appearing twice in `/var/log/secure`. This was deeply investigated.
* **The Cause:** The Ansible CIS role enforces a rule to route `authpriv.*` to `/var/log/secure`. Instead of placing this in a clean `/etc/rsyslog.d/` file, the role appends the rule directly into `/etc/rsyslog.conf`. Because AlmaLinux 9 already has a default `authpriv.*` rule further down in that exact same file, `rsyslog` parses the message twice, matching both rules and writing it to the disk twice.
* **The Verdict:** While technically inefficient, it is a known behavior of the automated lockdown script. We chose to leave it intact because it successfully satisfies the Goss compliance audit without breaking system functionality.

---

## 3. Auditing & Troubleshooting Fixes

### Goss Security Auditing
```groovy
archiveArtifacts artifacts: 'ansible/audit_reports/*.json, ansible/audit_reports/*.html', allowEmptyArchive: true
```
**Why I did this:**
After Ansible hardens the VM, Goss generates compliance reports. I used Jenkins to securely fetch and archive these artifacts. Our final run achieved an impressive **92.2%** passing rate against the strict CIS Level 1 baseline.

### Bypassing CIS SSH Lockouts (Rule 5.2.7)
**Command:**
```bash
sudo ssh -i /var/lib/jenkins/workspace/Pair-A-Pipeline/terraform/id_rsa -o IdentitiesOnly=yes sysadmin@<VM_IP>
```
**Why I did this:**
When trying to manually verify the VM, the connection was dropped (`kex_exchange_identification`). I identified that CIS Rule 5.2.7 (`MaxAuthTries 4`) was dropping the connection because my local SSH client was offering too many wrong keys from my laptop before offering the correct Jenkins key. Passing `-o IdentitiesOnly=yes` forced the client to only use the specified key, solving the lockout issue.

---

## 4. Useful Command Reference

### VM Connection Commands
* **SSH via Jenkins Workspace:** 
  ```bash
  sudo ssh -i /var/lib/jenkins/workspace/Pair-A-Pipeline/terraform/id_rsa -o IdentitiesOnly=yes sysadmin@<VM_IP>
  ```
* **SSH from Local User Directory:**
  ```bash
  ssh -i /home/aw7/pair-a-pipeline/terraform/id_rsa sysadmin@192.168.122.30
  ```

### Log & System Management Commands (Inside VM)
* **Check rsyslog Status:** `sudo systemctl status rsyslog`
* **Restart rsyslog:** `sudo systemctl restart rsyslog`
* **Test rsyslog Configuration Syntax:** `sudo rsyslogd -N1`
* **View Main System Logs:** `sudo tail -f /var/log/messages`
* **View Security/Authentication Logs:** `sudo tail -f /var/log/secure`
* **Check journald Configuration (CIS forwarding check):** `grep -r 'ForwardToSyslog' /etc/systemd/journald.conf`

### Libvirt & Hypervisor Commands (On Host Machine)
* **Find VM IP Address (DHCP Leases):** 
  ```bash
  sudo virsh -c qemu:///system net-dhcp-leases default
  ```
* **Prove UEFI Boot Configuration:** 
  ```bash
  sudo virsh -c qemu:///system dumpxml pa-node-1 | grep -iE 'loader|nvram'
  ```
* **List Disks (Verify Terraform Volumes):** 
  ```bash
  sudo virsh -c qemu:///system domblklist pa-node-1 --details
  ```
* **Live Attach Disk to VM:** 
  ```bash
  sudo virsh -c qemu:///system attach-disk pa-node-1 /var/tmp/demo-disk.qcow2 vdd --targetbus virtio --live --config
  ```
* **Live Detach Disk from VM:** 
  ```bash
  sudo virsh -c qemu:///system detach-disk pa-node-1 vdd --live --config
  ```
* **Verify Storage Pool (`pool_a`):** 
  ```bash
  sudo virsh -c qemu:///system pool-info pool_a && sudo virsh -c qemu:///system vol-list pool_a
  ```



---

# Pair A: Architecture & Design Decisions

This document outlines the architectural decisions, deviations, and configurations made for the Pair A deployment pipeline.

---

## 1. Deviations & Reasoning
We deviated from the original project brief to accommodate hardware constraints on the physical host.

* **Deviation:** Allocated 1GB of RAM per virtual machine instead of the requested 2GB.
* **Reasoning:** The host laptop only had 3GB of available RAM. Provisioning 4GB total would exceed host capacity, trigger the OOM (Out of Memory) killer, and cause system instability.

---

## 2. Partition Layout
The VMs are provisioned with three disks on the `virtio` bus to separate the OS from application data:

1. **OS Disk (`vda`):** Cloned from the Packer golden image. Contains the LVM Volume Group (`vg_sys_a`) with the required partitions (including the extra `lv_opt` logical volume mounted on `/opt`).
2. **Data Disk 1 (`vdb` - 2GB):** Formatted dynamically as `xfs` during the Ansible run and mounted to `/mnt/data1`.
3. **Data Disk 2 (`vdc` - 2GB):** Formatted dynamically as `xfs` during the Ansible run and mounted to `/mnt/data2`.

---

## 3. Inventory Generation
Ansible inventory generation is completely dynamic, driven by Terraform outputs to ensure we never have hardcoded or stale IP addresses.

```
┌─────────────────────────┐      1. DHCP Leases      ┌─────────────────────────┐
│     libvirt_domain      │ ───────────────────────► │  terraform/outputs.tf   │
│ (pa-node-1, pa-node-2)  │                          │  (extracts IPv4 leases) │
└─────────────────────────┘                          └────────────┬────────────┘
                                                                  │ 2. Injects variables
                                                                  ▼
┌─────────────────────────┐      3. Writes file      ┌─────────────────────────┐
│   ansible/inventory/    │ ◄─────────────────────── │  terraform/templates/   │
│        hosts.ini        │                          │      inventory.tpl      │
└─────────────────────────┘                          └─────────────────────────┘
```

### 3.1 Implementation Details

1. **Terraform Resource Management (`local_file`):**
   In `terraform/outputs.tf`, we utilize Terraform's native `local_file` resource combined with the `templatefile` function to render the inventory file directly into `ansible/inventory/hosts.ini`:
   ```hcl
   resource "local_file" "ansible_inventory" {
     content = templatefile("${path.module}/templates/inventory.tpl", {
       nodes = {
         for idx, domain in libvirt_domain.pa_node : domain.name => try([for addr in domain.network_interface[0].addresses : addr if length(regexall("^[0-9.]+$", addr)) > 0][0], "offline")
       }
     })
     filename = "${path.module}/../ansible/inventory/hosts.ini"
   }
   ```

2. **Automated IPv4 Filtering & Discovery:**
   The `libvirt` provider exposes all assigned network addresses on the guest interface. To avoid catching IPv6 link-local addresses (`fe80:...`), our extraction logic uses a Terraform comprehension loop with regular expression filtering (`regexall("^[0-9.]+$", addr)`). This guarantees that only valid, routable IPv4 addresses are passed downstream to Ansible.

3. **Dynamic Template Scaling:**
   In `terraform/templates/inventory.tpl`, we define the inventory structure using Terraform template directives (`%{ for name, ip in nodes ~}`):
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
   Whether `vm_count` is set to `1` or `2`, the template dynamically expands or shrinks without requiring any manual adjustments.

4. **Lifecycle & Clean Teardown (`terraform destroy`):**
   Because `ansible/inventory/hosts.ini` is managed as an active Terraform state resource (`local_file.ansible_inventory`), running `terraform destroy` automatically destroys and deletes the generated inventory file. This satisfies the requirement: *"terraform destroy leaves nothing behind: no domains, volumes, cloud-init ISOs, or generated inventory"*.

5. **Sample Generated Output:**
   ```ini
   [all]
   pa-node-1 ansible_host=192.168.122.169 ansible_user=sysadmin
   pa-node-2 ansible_host=192.168.122.174 ansible_user=sysadmin

   [pair_a]
   pa-node-1
   pa-node-2
   ```

---

## 4. Variable Precedence Table
To fulfill the requirement of demonstrating Ansible variable precedence, we track a single tailoring variable (`rhel9cis_warning_banner`) across three different precedence levels.

| Variable Name | Assigned Value | Where It Is Set | What It Overrides | Why It Wins |
| :--- | :--- | :--- | :--- | :--- |
| `rhel9cis_warning_banner` | `"AUTHORIZED ACCESS ONLY"` | **Level 1:** `group_vars/all/vars.yml` | Role Defaults (`defaults/main.yml`) | Inventory `group_vars` are loaded after the role's default variables, safely overriding them. |
| `rhel9cis_warning_banner` | `"PLAYBOOK LEVEL ACCESS BANNER"` | **Level 2:** `playbook.yml` (`vars:` block) | Group Vars (`group_vars/all/vars.yml`) | Play-level variables are more specific to the execution run and override inventory-level configurations. |
| `rhel9cis_warning_banner` | `"JENKINS EXTRA-VARS BANNER"` | **Level 3:** Jenkins Pipeline (`--extra-vars`) | Play Vars (`playbook.yml`) | Command-line extra variables (`-e` or `--extra-vars`) have the absolute highest precedence in Ansible and override all other variable definitions across the board. |

**Verification & Demonstration Notes (The Difference Between Levels):**
Ansible determines variable precedence by how "close" or "specific" the variable definition is to the actual execution. We demonstrated this by defining the exact same variable (`rhel9cis_warning_banner`) in three different places.:

1. **Level 1 (Broadest Scope):** Set in `group_vars/all/vars.yml`. This applies broadly to all servers in the inventory. If no other variable is set, Ansible uses this.
2. **Level 2 (Playbook Scope):** Set in the `vars:` block of `playbook.yml`. This is more specific because it applies directly to the current playbook run, overriding the broad inventory variables (Level 1).
3. **Level 3 (Execution Scope):** Passed via the `-e` flag in the `Jenkinsfile`. This is the most specific level possible (Command Line Extra Vars). It acts as an absolute override, squashing both Level 1 and Level 2.

**Proof of Execution:**
When the playbook was executed manually via the terminal (`ansible-playbook playbook.yml` *without* the `-e` flag), Ansible successfully loaded Level 1, but then immediately overrode it with **Level 2**. 

We verified this by SSHing into both nodes (`ssh sysadmin@<IP>`) and observing the following banner output, proving Level 2 won the precedence battle:
```text
PLAYBOOK LEVEL ACCESS BANNER
PLAYBOOK LEVEL ACCESS BANNER
Last login: Fri Aug  7 06:39:23 2026 from 192.168.122.1
```
*Note: Once the Jenkins pipeline is triggered, the `-e` flag will enforce Level 3 (`JENKINS EXTRA-VARS BANNER`).*

---

## 5. Tailoring Decisions & Exceptions

### CIS Profile Levels Overview
Before applying tailoring, it's important to understand the purpose of the two primary CIS Benchmark profiles:

| CIS Profile | Purpose & Description | When to Use |
| :--- | :--- | :--- |
| **Level 1** | Practical, baseline security. Designed to be easy to implement and provide a clear security benefit **without** significantly inhibiting the utility or functionality of the system. | Used as the standard baseline for all general-purpose systems and corporate IT environments. |
| **Level 2** | Defense-in-depth security. Highly restrictive and designed for environments where security is paramount. Implementing this can negatively impact system performance or break application functionality if not carefully tailored. | Used for highly sensitive, air-gapped, or strictly regulated environments (e.g., military, PCI-DSS, HIPAA). |

The following specific tailoring decisions were made to align with the Pair A assignment:

* **Use of RSyslog:** Enforced `rhel9cis_syslog: rsyslog` to override the default `journald` implementation.
* **SSHD Timeout Adjustments:** Configured `rhel9cis_sshd_clientaliveinterval: 300` and `rhel9cis_sshd_clientalivecountmax: 0` per assignment requirements.
* **PAM Faillock Disablement:** Completely disabled account lockouts on failed password attempts for both standard users and root by setting `rhel9cis_pam_faillock_deny: 0` and toggling off CIS rules `5.3.3.1.1`, `5.3.3.1.2`, and `5.3.3.1.3`.
* **Cloud Instance CIS Exceptions:** Because this is an automated cloud deployment, we disabled local password checks (`rhel9cis_rule_5_2_4` and `rhel9cis_rule_5_4_2_4`) and provided a custom authselect profile name (`rhel9cis_authselect_custom_profile_name: "custom_cis_profile"`) to ensure the role passes successfully on SSH-key only servers.
* **Ansible Version Check Bypass:** Bypassed the strict Ansible version check (`> 2.16.1`) in the CIS role to natively support the AlmaLinux 9 repository's default `ansible-core` package (`2.14.18`).

---

## 6. Comprehensive Project Summary (Guide Adherence)

This section details exactly how the infrastructure was built to adhere to the project requirements.

### Phase 1: Golden Image Build (Packer)
* Created a clean `kickstart.cfg` mapped directly to an AlmaLinux 9 base ISO.
* Enforced the `@^minimal-environment` package set to keep the attack surface low.
* Implemented the required CIS Level 1 logical volumes (`/var`, `/var/log`, `/var/log/audit`, `/var/tmp`, `swap`) under a single Volume Group (`vg_sys_a`).
* Added the Pair A specific extra logical volume (`/opt` - 2GB).
* Pre-installed `cloud-init` and `qemu-guest-agent` for downstream Terraform automation.

### Phase 2: Infrastructure Provisioning (Terraform)
* Provisioned two identical virtual machines on KVM/libvirt: `pa-node-1` and `pa-node-2`.
* Solved kernel panics and AlmaLinux 9 compatibility issues by strictly defining the `q35` machine type with `host-passthrough` CPU mode.
* Handled `q35` IDE limitations by injecting an XSLT transformation to remap the cloud-init CD-ROM to the SATA bus.
* Attached the 20GB Golden Image base OS disk, plus **two additional 2GB data disks** per node.
* Secured the initial OS state via `cloud-init`, enforcing SSH-key authentication for the `sysadmin` user, configuring passwordless sudo, disabling root login, and strategically preventing background package upgrades that would clash with Ansible.
* Dynamically extracted the provisioned IPv4 addresses directly from the hypervisor DHCP leases to generate the Ansible inventory file.

### Phase 3: Hardening & Orchestration (Ansible & Jenkins)
* Implemented the industry-standard `rhel9-cis` (Ansible-Lockdown) collection to automatically harden the instances.
* Wrote `pre_tasks` in the playbook to dynamically format the two 2GB data disks as `xfs` and mount them permanently to `/mnt/data1` and `/mnt/data2` before hardening.
* Fixed concurrent SSH verification hangs by providing a pre-configured `ansible.cfg` with `host_key_checking = False`.
* Orchestrated the entire build, destroy, provision, and harden lifecycle using a declarative `Jenkinsfile` parameterized for flexibility and complete reproducibility.

---

## 7. Troubleshooting & Problem Solving
Throughout the development of this infrastructure, several major technical hurdles were encountered and systematically resolved:

1. **Terraform `q35` Machine Type vs. IDE Limitations:**
   * **Error:** Terraform failed to provision with `unsupported configuration: IDE controllers are unsupported for this QEMU binary or machine type`.
   * **Solution:** The `q35` hardware profile does not support legacy IDE buses, but the Terraform libvirt provider hardcodes the `cloud-init` CD-ROM to IDE. We implemented an `xslt` transformation block in `main.tf` to dynamically rewrite the libvirt XML on-the-fly, changing the CD-ROM bus from `ide` to `sata`.

2. **AlmaLinux 9 CPU Kernel Panics:**
   * **Error:** VMs failed to boot properly due to missing microarchitecture features.
   * **Solution:** AlmaLinux 9 strictly requires the `x86-64-v2` instruction set. We updated the Terraform domain definition to include `cpu { mode = "host-passthrough" }`, passing the host's CPU capabilities directly to the guest.

3. **Ansible IPv6 Link-Local Connectivity Issues:**
   * **Error:** The dynamic inventory generation in `outputs.tf` was grabbing `fe80::...` IPv6 addresses, causing Ansible SSH connections to hang or fail.
   * **Solution:** Rewrote the IP extraction logic in `outputs.tf` using a Terraform `for` loop and `regexall("^[0-9.]+$")` to filter out IPv6 and strictly bind the inventory to the IPv4 leases.

4. **Ansible Concurrent SSH Key Hangs:**
   * **Error:** Running Ansible concurrently against two new nodes caused SSH key fingerprint prompts `(yes/no)` to overlap and hang the terminal, resulting in `UNREACHABLE` errors.
   * **Solution:** Created an `ansible.cfg` file configuring `host_key_checking = False` to ensure zero-touch execution for the Jenkins pipeline.

5. **Cloud-Init Background Upgrade Lock Contention:**
   * **Error:** The Ansible playbook was randomly failing mid-run with `Connection reset by peer` and then timing out completely.
   * **Solution:** Investigated the hypervisor logs and discovered `cloud-init` was running a full `dnf upgrade` in the background (which upgraded network components and dropped the connection). Resolved by setting `package_update: false` and `package_upgrade: false` in `cloud_init.cfg` to ensure a stable state for Ansible.

6. **Ansible CIS Role Strict Versioning:**
   * **Error:** The playbook failed asserting `You must use Ansible 2.16.1 or greater` (the system had `2.14.18` installed via standard AlmaLinux repos).
   * **Solution:** Rather than installing custom pip environments that could break Jenkins, we manually bypassed the `version_compare` assertion inside the role's `main.yml`, as the core logic remains fully backward compatible.

7. **Virtualization Modules & VM Power State on Host Reboot:**
   * **Error:** After rebooting the host machine, running `terraform apply` fails with "Domain requires KVM, but it is not available" or outputs IP addresses as "offline".
   * **Solution:**
     1. The KVM kernel modules may not load automatically. Manually load them using `sudo modprobe kvm_intel` (or `kvm_amd`).
     2. Run `sudo terraform apply` to instruct libvirt to power the existing VMs back on (this acts safely as a power button and does not destroy existing data).
     3. Wait a few moments for the VMs to boot, then run `sudo terraform refresh` to fetch their newly assigned DHCP IP addresses and update the Ansible `hosts.ini` dynamic inventory.

## 8. Final Implementation Details & Fixes (Jenkins & Packer)

During the final integration of the Jenkins CI/CD pipeline, the following critical architecture changes and fixes were applied:

1. **Storage Pool Decoupling:** 
   * **Issue:** `terraform destroy` could not cleanly delete the `pool_a` directory because Packer was saving the Golden Image inside it.
   * **Fix:** Updated `build.pkr.hcl` to output the Golden Image to `/var/tmp/packer_output/` to cleanly separate the immutable build artifact from the Terraform-managed live infrastructure pool.
2. **Minimal ISO SSL Verification Errors:**
   * **Issue:** The Kickstart automated installation paused on a fatal `Error setting up software source` error because the VM's out-of-sync clock failed to validate the `https://` SSL certificate for the AlmaLinux repository.
   * **Fix:** Downgraded the kickstart installation source URLs from `https://` to `http://` to bypass SSL date validation during the initial boot environment.
3. **QEMU SLIRP DNS Resolution Failures:**
   * **Issue:** The installer could not resolve `vault.almalinux.org` because QEMU's default user-mode (SLIRP) network occasionally failed to forward DNS requests correctly.
   * **Fix:** Injected `nameserver=8.8.8.8` into both the QEMU kernel boot parameters and the Kickstart network configuration to explicitly force Google's Public DNS.

---

## 9. Final Goss Audit Results
After successfully executing the full CI/CD pipeline and Ansible playbook, the built-in Goss scanner generated the final compliance scorecard against the CIS Level 1 Server profile.

**Final Score:**
* **Total Tests Run:** 616
* **Failed Tests:** 44 
* **Skipped Tests:** 10
* **Passed Tests:** 572
* **Overall Compliance:** **92.85%**

The infrastructure successfully exceeds the required 90% compliance threshold!

### 9.1 Three Failures Explained & Live Simulation

As required by **Section 6 (Presentation)** of the project brief, here is the detailed breakdown and live simulation procedure for three key test failures identified in the Goss audit report:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   THREE GOSS FAILURES BREAKDOWN                                  │
├────┬─────────────────────────────┬─────────────────────────────────┬─────────────────────────────┤
│ #  │ CIS Benchmark Rule          │ Reason for Failure              │ Justification / Category    │
├────┼─────────────────────────────┼─────────────────────────────────┼─────────────────────────────┤
│ 1  │ 5.3.2.2 (pam_faillock)      │ Faillock PAM module disabled    │ Intentional Pair A Tailoring│
│ 2  │ 6.2.3.6 (Remote Syslog Host)│ No upstream syslog target       │ Environment/Lab Limitation  │
│ 3  │ 5.3.3.2.7 (Root PW Quality) │ enforce_for_root not enabled    │ SSH-Key / Cloud Auth Model  │
└────┴─────────────────────────────┴─────────────────────────────────┴─────────────────────────────┘
```

---

#### Failure 1: CIS 5.3.2.2 – Ensure pam_faillock module is enabled
* **Rule Title:** `5.3.2.2 | Ensure pam_faillock module is enabled`
* **Goss Resource Tested:** `File: /etc/pam.d/system-auth` and `/etc/pam.d/password-auth`
* **Failure Symptom:** Goss expects regex patterns `/auth\s+required\s+pam_faillock.so preauth/` and `/account\s+required\s+pam_faillock.so/`.
* **Root Cause & Rationale:** 
  * In the **Pair A Assignment Brief (Section 3)**, we are explicitly instructed:  
    `"No account lockouts on failed password attempts on both user and root accounts (Safety / Security)"`.
  * Enabling `pam_faillock` would automatically lock accounts after repeated invalid password attempts, risking lockout Denial-of-Service (DoS) and interrupting automated operational tasks.
  * We intentionally customized the `authselect` profile (`rhel9cis_authselect_custom_profile_name`) and disabled the faillock rules (`rhel9cis_pam_faillock_deny: 0` / rules `5.3.3.1.1`–`5.3.3.1.3`).
* **Live Simulation / Verification Commands:**
  ```bash
  # Check active authselect profile (shows faillock is not enforced)
  authselect current

  # Confirm pam_faillock is absent from active PAM stack
  grep -i "pam_faillock" /etc/pam.d/system-auth /etc/pam.d/password-auth || echo "Verified: Faillock disabled per Pair A requirements."
  ```

---

#### Failure 2: CIS 6.2.3.6 – Ensure rsyslog is configured to send logs to a remote log host
* **Rule Title:** `6.2.3.6 | Ensure rsyslog is configured to send logs to a remote log host`
* **Goss Resource Tested:** `Command: remote_syslog` (exit status expected 0 or 2)
* **Failure Symptom:** Goss returns exit code `1` and notes missing remote target pattern: `*.* action(type="omfwd" target="logagg.example.com" port="514" protocol="tcp")`.
* **Root Cause & Rationale:**
  * Pair A is assigned `Use rsyslog for logging`. Rsyslog is installed, enabled, and actively writing system logs locally to `/var/log/messages`.
  * However, CIS Rule 6.2.3.6 expects logs to be forwarded to a centralized external log aggregator (SIEM / central syslog server).
  * In our isolated local KVM hypervisor lab, no external log aggregator server exists. Configuring a dummy remote IP would cause rsyslog connection retry spam and potential network buffer bloat.
* **Live Simulation / Verification Commands:**
  ```bash
  # 1. Prove rsyslog is actively running locally
  systemctl status rsyslog --no-pager

  # 2. Write a test message and prove local ingestion works
  logger -t PRESENTATION_TEST "Local Rsyslog verification on pa-node-1"
  sudo tail -n 5 /var/log/messages | grep "PRESENTATION_TEST"

  # 3. Check for remote forwarding rule (shows why Goss flagged it)
  grep -E '^\*\.\*.*omfwd|action\(type="omfwd"' /etc/rsyslog.conf /etc/rsyslog.d/*.conf || echo "Verified: No remote host configured (Isolated Lab Host)."
  ```

---

#### Failure 3: CIS 5.3.3.2.7 – Ensure password quality is enforced for the root user
* **Rule Title:** `5.3.3.2.7 | Ensure password quality is enforced for the root user`
* **Goss Resource Tested:** `Command: password_quality_enforce_root`
* **Failure Symptom:** Goss expects pattern `/:enforce_for_root/` in `/etc/security/pwquality.conf`.
* **Root Cause & Rationale:**
  * Our VM deployment uses standard modern cloud infrastructure security practices: **SSH public key authentication only**.
  * The `root` account has no password assigned (it is locked with `!` in `/etc/shadow`), and SSH direct root login is strictly disabled (`PermitRootLogin no`).
  * Administrative access is granted only to the `sysadmin` user via public key authentication with sudo privileges. Enforcing interactive password complexity (`enforce_for_root`) on an account that does not accept password logins is functionally redundant.
* **Live Simulation / Verification Commands:**
  ```bash
  # 1. Verify root account password is locked (shows 'LK' or 'NP')
  sudo passwd -S root

  # 2. Verify direct root login via SSH is disabled
  sudo sshd -T | grep -i permitrootlogin

  # 3. Inspect pwquality.conf for enforce_for_root (shows why Goss flagged it)
  grep -E '^enforce_for_root' /etc/security/pwquality.conf || echo "Verified: enforce_for_root not active because root password authentication is disabled."
  ```

---


## 10. Manual Execution Quick Reference

If you need to reproduce this exact 92.85% environment manually (bypassing Jenkins), run the following commands in order from the repository root:

### 1. Build the Golden Image (Packer)
```bash
cd packer
sudo /usr/bin/packer build -force build.pkr.hcl
```
*(Builds the KVM Golden Image and outputs it to `/var/tmp/packer_output/`)*

### 2. Provision the Infrastructure (Terraform)
```bash
cd ../terraform
terraform init -reconfigure
sudo terraform apply -auto-approve
```
*(Provisions the VMs in libvirt and attaches the data disks)*

### 3. Refresh the Dynamic Inventory
```bash
# Wait ~30 seconds for VMs to boot before running this
sudo terraform apply -refresh-only -auto-approve
```
*(Fetches the new DHCP IP addresses from the hypervisor and writes them to Ansible's `hosts.ini`)*

### 4. CIS Hardening & Validation (Ansible)
```bash
cd ../ansible
ansible-playbook -i inventory/hosts.ini playbook.yml --ask-vault-pass
```
*(Executes the CIS hardening role and runs the final Goss audit)*

### 5. Check the Final Audit Score
```bash
jq '.summary | . + { "passing_percentage": (((."test-count" - ."failed-count") / ."test-count") * 100 | tostring + "%") }' audit_reports/pa-node-1*post_scan*.json
```
*(Calculates and displays your final compliance percentage)*

---

## 11. Final Jenkins CI/CD Integration & Adjustments

During the final phase of automating this pipeline natively inside Jenkins, several key adjustments were made to ensure stability, proper variable precedence, and host compatibility:

1. **Host Memory Constraints (Scaling Down):**
   * **Issue:** Running two virtual machines (`pa-node-1` and `pa-node-2`) alongside the heavy Jenkins Java process caused the host machine to run completely out of memory, crashing the hypervisor.
   * **Fix:** Reduced `vm_count` in Terraform to `1`. Because the entire Terraform architecture (including Ansible dynamic inventory generation) was written dynamically with `for` loops, Terraform cleanly scaled down to a single VM (`pa-node-1`) without breaking any downstream dependencies.

2. **Persistent Jenkins State Management:**
   * **Issue:** Jenkins uses the `cleanWs()` command to securely wipe the workspace after every run. This meant Terraform would "forget" the VMs existed and orphan them on the hypervisor.
   * **Fix:** Restored `terraform/backend.tf` to point to a persistent local path (`/var/lib/jenkins/terraform.tfstate`) outside the workspace, guaranteeing Terraform tracks state safely across Jenkins builds.

3. **Ansible Galaxy Collections in Jenkins:**
   * **Issue:** The Jenkinsfile command `ansible-galaxy install -r requirements.yml -p roles/` successfully installed the `rhel9-cis` role, but explicitly ignored the `collections` section of the requirements file, causing the playbook to crash on the `community.general.modprobe` module.
   * **Fix:** Added an explicit `ansible-galaxy collection install -r requirements.yml --force` command to the Jenkinsfile to guarantee all collection dependencies are met.

4. **Preserving Level 1 & Level 2 Variable Precedence:**
   * **Issue:** We wanted to bypass the CIS role's strict `2.16.1` Ansible version check using our `group_vars` (Level 1 precedence). However, Jenkins downloads a fresh copy of the role every time, and the role's native `vars/` take precedence over `group_vars`, causing the build to fail.
   * **Fix:** Instead of injecting command-line Extra Vars (Level 3 precedence) which would artificially squash the entire precedence hierarchy, we added a lightweight `sed` command to the `Jenkinsfile`. This dynamically patches the downloaded role on-the-fly (`sed -i "s/2.16.1/2.14.0/g" roles/rhel9-cis/vars/main.yml`), proving that our pure Level 1 and Level 2 variable architecture works perfectly.

5. **Jenkins SSH Authentication:**
   * **Issue:** Terraform dynamically injects `aw7`'s public SSH key into the VM via Cloud-Init. However, the Jenkins pipeline runs as the `jenkins` user and was getting `Permission denied (publickey)` when trying to execute Ansible.
   * **Fix:** Securely copied the `aw7` private key to `/var/lib/jenkins/.ssh/id_rsa`, unifying the authentication identity so Jenkins can seamlessly assume control of the infrastructure it builds.

---

## 12. Validation & Verification Commands

To manually verify the success of the automated pipeline on the target VM without relying on Jenkins artifacts, you can run the following commands from your host terminal (replace `<VM_IP>` with the dynamically assigned IP from Terraform):

### Check the Goss Audit Score
This command connects to the VM, reads the native JSON output generated by the CIS role in `/opt/`, and calculates your final passing percentage:
```bash
ssh sysadmin@<VM_IP> "sudo jq '.summary | . + { \"passing-percentage\": ( ( (.\"test-count\" - .\"failed-count\") / .\"test-count\" ) * 100 | tostring + \"%\" ) }' /opt/*post_scan*.json"
```

### Verify Rsyslog Enforcement
To confirm that `rsyslog` was successfully installed and enabled (overriding the default `journald` implementation as defined in our CIS tailoring variables):
```bash
ssh sysadmin@<VM_IP> "systemctl status rsyslog"
```

---

## 13. File System Structure (PAIR A)

This section provides an overview of the directory structure for the `trainee-pipeline` repository, detailing the purpose of each directory and subdirectory:

* **`.git/` & `.gitignore`**: Contains the source control tracking for the repository and files to ignore.
* **`Jenkinsfile`**: The declarative pipeline script used by Jenkins to orchestrate the entire end-to-end CI/CD process.
* **`ansible/`**: Contains all configuration management code to harden the infrastructure.
  * **`ansible.cfg`**: Configures Ansible defaults, particularly overriding SSH host key checking for automated pipelines.
  * **`playbook.yml`**: The main execution entry point for configuring and hardening the VMs.
  * **`requirements.yml`**: Defines the required external Ansible dependencies (roles and collections), specifically the CIS hardening role.
  * **`inventory/`**: Holds the `hosts.ini` dynamic inventory file, which is populated with IP addresses on-the-fly by Terraform.
  * **`group_vars/`**: Contains group-level variables (e.g., `all/`) used to demonstrate Level 1 variable precedence.
  * **`roles/`**: Download location for third-party roles like `rhel9-cis` during the Ansible-Galaxy dependency resolution step.
  * **`audit_reports/`**: Directory where final Goss security compliance audit JSON reports are output and stored.
* **`docs/`**: Holds project documentation, architectural decisions, and guides (like this `design.md` file).
* **`packer/`**: Contains the configuration to build the Golden Image.
  * **`build.pkr.hcl`**: The Packer HashiCorp Configuration Language file defining the AlmaLinux 9 build process.
  * **`kickstart.cfg`**: The automated installer configuration used to define the initial base operating system and partitioning.
* **`terraform/`**: Contains the infrastructure-as-code definitions to provision the virtual machines.
  * **`main.tf`**: The primary declarative file defining the libvirt provider, network, volumes, and QEMU instances.
  * **`variables.tf`**: Defines input variables (like memory, disk sizes, and network names) for the Terraform module.
  * **`outputs.tf`**: Extracts necessary data from the provisioned infrastructure, such as dynamically building the Ansible inventory file.
  * **`backend.tf`**: Configures the state file location, allowing state persistence across Jenkins workspace cleanups.
  * **`cloud_init.cfg`**: Provides the early-boot initialization instructions for the VMs (e.g., creating users, injecting SSH keys).
  * **`id_rsa.pub`**: The public SSH key used to grant access to the newly provisioned servers.
  * **`templates/`**: Directory containing Terraform templates, such as the `inventory.tpl` file used to generate the Ansible inventory.

---

## 14. Areas for Future Improvement & Evaluation Readiness

This section outlines potential areas of improvement, technical optimizations, and key readiness points for evaluation based on the Pair A project brief.

---

### 14.1 Technical & Configuration Optimizations

1. **Ansible Vault for Sensitive Variables:**
   * **Current Implementation:** The pipeline passes the vault password from Jenkins credentials via the `VAULT_PASS` environment variable into a temporary password file.
   * **Improvement:** Migrate any sensitive values (e.g., custom user credentials, internal tokens, sensitive override variables) into an encrypted `ansible/vars/vault.yml` using `ansible-vault encrypt`. This ensures all secrets remain encrypted at rest within the Git repository while maintaining zero-touch automated decryption in Jenkins.

2. **Persistent Mount Robustness (`fstab`):**
   * **Current Implementation:** Extra data disks (`/mnt/data1` and `/mnt/data2` on the `virtio` bus) are formatted as `xfs` and mounted via Ansible `pre_tasks`.
   * **Improvement:** Ensure mount definitions in `ansible/playbook.yml` use permanent block device UUIDs (`blkid`) rather than transient device node names (`/dev/vdb`, `/dev/vdc`) to prevent accidental disk misassignment if the hypervisor reorders virtual storage devices.

3. **Ansible Version Alignment:**
   * **Current Implementation:** The downloaded `rhel9-cis` role is dynamically patched via `sed` in the `Jenkinsfile` to support the default `ansible-core 2.14.x` package available in AlmaLinux 9 repositories.
   * **Improvement:** Provision an isolated Python virtual environment (`python3 -m venv`) inside the Jenkins execution agent to install `ansible-core >= 2.16.1` via `pip`. This eliminates the need for inline role patching while ensuring complete forward compatibility.

4. **Mount Flags for CIS Compliance on `/tmp`:**
   * **Current Implementation:** `/tmp` is partitioned as a dedicated logical volume within `vg_sys_a`.
   * **Improvement:** Enforce strict mount flags (`nodev,nosuid,noexec`) in `/etc/fstab` during the Kickstart installation phase or early Ansible plays to turn the 4 failed Goss tests for `/tmp` into passing tests.

---

### 14.2 Presentation & Evaluation Defense Points

1. **Defending Hardware Constraints (RAM & VM Count):**
   * The project brief specifies 2 VMs with 2GB RAM each. 
   * **Defense:** Due to physical host laptop constraints (3GB host RAM), the infrastructure was scaled to 1 VM with 1GB RAM to prevent host OOM kernel panics. The Terraform code and dynamic inventory templates are written generically using dynamic `for` loops, meaning the pipeline seamlessly scales to 2 or more nodes simply by updating `vm_count = 2` without any code modifications.

2. **Live `virsh` Demonstration Tasks (Section 6):**
   * **CRITICAL NOTE:** Because Terraform provisions these VMs on the system-level daemon, you must run all demonstration commands using `sudo` and explicitly point to the system URI (`-c qemu:///system`). If you just type `virsh`, it will look in your empty user session and fail!
   * Be prepared to demonstrate the live hypervisor tasks while Jenkins runs with `DESTROY_AND_REBUILD` checked:
     * **Find VM IP Address:** `sudo virsh -c qemu:///system net-dhcp-leases default`
     * **Prove UEFI:** `sudo virsh -c qemu:///system dumpxml pa-node-1 | grep -iE 'loader|nvram'`
     * **List Disks & Match to Terraform:** `sudo virsh -c qemu:///system domblklist pa-node-1 --details`
     * **Live Attach & Detach Disk:** `sudo virsh -c qemu:///system attach-disk pa-node-1 /var/tmp/demo-disk.qcow2 vdd --targetbus virtio --live --config` and `sudo virsh -c qemu:///system detach-disk pa-node-1 vdd --live --config`
     * **Walk Storage Pool:** `sudo virsh -c qemu:///system pool-info pool_a && sudo virsh -c qemu:///system vol-list pool_a`

3. **Cross-Presentation Strategy (Partner's Track):**
   * Per Section 4 & 6 of the brief, prepare to present the track completed by your partner (e.g., if you focused on Packer/Terraform, practice walking through the Ansible lockdown role, variable precedence hierarchy, and Goss auditing).



## 15. Pipeline Bug Fixes & Refinements

This section documents the final polishing and troubleshooting steps taken to perfect the CI/CD pipeline prior to evaluation.

### 15.1 Jenkins Workspace Persistence & SSH Key Management
* **Problem**: When Jenkins finished building, it ran `cleanWs()` and deleted the `id_rsa` SSH key it used to provision the VM. Because CIS hardens the VM and disables password logins, the VM was completely inaccessible after the pipeline ran. Also, a wiped workspace caused `terraform destroy` to fail on subsequent runs because the `terraform.tfstate` file was deleted.
* **Fix**: Added a `CLEAN_WORKSPACE` boolean parameter to the Jenkinsfile. If unchecked, the workspace and SSH keys persist. This allows presenters to SSH into the VM after a successful build using `sudo ssh -i /var/lib/jenkins/workspace/Pair-A-Pipeline/terraform/id_rsa -o IdentitiesOnly=yes sysadmin@<VM_IP>` and allows Terraform to successfully find and destroy the previous state.

### 15.2 Redundant SSH Key Generation
* **Problem**: The `ssh-keygen` command was running twice—first in the `Teardown Infrastructure` stage and again in the `Provision Infrastructure` stage. If `Teardown` was skipped, the key was never generated.
* **Fix**: Consolidated the key generation exclusively to the `Teardown` stage. If a user needs a fresh VM, they must check `DESTROY_AND_REBUILD`, ensuring the key is generated once and efficiently reused across the pipeline.

### 15.3 MaxAuthTries CIS Rule Lockout (Rule 5.2.7)
* **Problem**: When attempting to SSH into the VM for verification, the connection was immediately dropped with `kex_exchange_identification: Connection closed by remote host`. The CIS Level 1 playbook enforces `MaxAuthTries 4`, meaning if the user's laptop SSH client automatically tried 4 different keys from `~/.ssh/` before offering the correct one, the server dropped the connection.
* **Fix**: Used the `-o IdentitiesOnly=yes` flag in the manual SSH command to force the client to stop guessing and only offer the specific Jenkins `id_rsa` key, bypassing the CIS rate-limit.

### 15.4 Securing the Repository (.gitignore)
* **Problem**: `id_rsa.pub` was initially committed to the repository during earlier testing, posing a secret leakage risk.
* **Fix**: The key was deleted via `git rm`, and `id_rsa` alongside `id_rsa.pub` were explicitly added to the `.gitignore` file. This guarantees that ephemeral keys generated during local or Jenkins testing are never accidentally tracked by source control.
