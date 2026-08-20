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

This section explains the critical files in the repository.

### 1. The Jenkins Orchestrator (`Jenkinsfile`)

**What it is:** The declarative Groovy script that dictates the entire CI/CD workflow.

**How it works:** It is divided into `parameters`, `environment`, and `stages` blocks. Each stage enters a specific directory (e.g., `dir('terraform')`) and executes shell commands (`sh`).

**Why we wrote it this way:**
- **Ephemeral Keys:** We run `ssh-keygen` inside the pipeline rather than storing keys in Git. This ensures that every deployment uses a unique, temporary key, maximizing security.
- **Role Patching:** We run `sed -i "s/2.16.1/2.14.0/g"` on the Ansible role because AlmaLinux 9 ships with an older version of Ansible. This dynamic patch prevents the pipeline from failing due to strict version dependencies.
- **Workspace Cleanup:** We added the `CLEAN_WORKSPACE` parameter. By default, it cleans the workspace to prevent state leakage and save disk space. However, we can uncheck it to intentionally leave the ephemeral SSH key behind, allowing us to log into the VM manually for demonstrations.

### 2. Infrastructure Provisioning (`terraform/`)

#### `main.tf`
**What it is:** The primary Terraform configuration file.
**How it works:** It uses the `dmacvicar/libvirt` provider to define resources like `libvirt_volume` (for disks) and `libvirt_domain` (for the VM itself). 
**Why we wrote it this way:** We use dynamic loops (`for_each` or `count`) to allow scaling. We also use a `lifecycle { ignore_changes = [cloudinit] }` block to prevent a known bug where Terraform tries to constantly replace the cloud-init ISO on every run.

#### `variables.tf` & `outputs.tf`
**What it is:** The inputs and outputs of the Terraform module.
**How it works:** `variables.tf` defines the VM count, memory, and disk sizes. `outputs.tf` takes the final IP address of the VM and uses a `templatefile` function to dynamically generate the Ansible `hosts.ini` file.
**Why we wrote it this way:** Hardcoding IP addresses breaks automation. By dynamically generating the inventory, Ansible always knows exactly where to connect, regardless of what IP the DHCP server assigned.

#### `cloud_init.cfg`
**What it is:** The initial configuration script executed by the VM on its very first boot.
**How it works:** It sets the hostname (`pa-node-1`), disables root SSH login, and creates a `sysadmin` user. It then injects the public SSH key into the `sysadmin` user's `authorized_keys` file.
**Why we wrote it this way:** Cloud-init bridges the gap between Terraform and Ansible. It provides the initial "bootstrap" access required for Ansible to log in and take over configuration management.

### 3. Golden Image Creation (`packer/`)

#### `build.pkr.hcl`
**What it is:** The Packer configuration file.
**How it works:** It defines a QEMU builder that downloads an AlmaLinux 9 ISO, boots it, types in a boot command via VNC, and points it to the `kickstart.cfg` file.
**Why we wrote it this way:** Building an image from an ISO takes time. By pre-building a "Golden Image" with Packer, Terraform can simply clone it in seconds, drastically speeding up the pipeline.

#### `kickstart.cfg`
**What it is:** An automated answer file for the Red Hat installer (Anaconda).
**How it works:** It answers all the installation prompts (language, timezone, partitioning, root password) automatically.
**Why we wrote it this way:** It ensures the foundational filesystem (e.g., separating `/var`, `/tmp`, and `/var/log/audit`) perfectly aligns with CIS requirements before Ansible even touches the machine.

### 4. Configuration Management (`ansible/`)

#### `playbook.yml`
**What it is:** The master Ansible playbook.
**How it works:** It contains `pre_tasks` that format the raw VirtIO data disks using the `xfs` filesystem and mount them persistently. It then calls the `rhel9-cis` role to harden the OS.
**Why we wrote it this way:** Formatting disks must happen before hardening. By placing the `rhel9cis_warning_banner` variable here, we demonstrate Ansible's "Level 2" variable precedence, proving that play-level variables override group-level variables.

#### `group_vars/all/vars.yml`
**What it is:** The global variable file (Level 1 precedence) that configures the CIS role.
**How it works:** It overrides the default behavior of the MindPoint Group CIS role.
**Why we wrote it this way:**
- **`rhel9cis_level_2: false`:** This is the programmatic proof that we adhered to the project brief's "Level 1 Server" requirement, preventing the highly restrictive Level 2 rules from applying.
- **`rhel9cis_syslog: rsyslog`:** Forces the use of rsyslog instead of journald, as required by Pair A.
- **`rhel9cis_pam_faillock_deny: 0`:** Disables permanent user account lockouts to ensure we don't accidentally lock ourselves out during testing and live demonstrations.
