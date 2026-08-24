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

