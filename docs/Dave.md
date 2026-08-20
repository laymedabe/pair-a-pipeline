# Dave's Track: Jenkins Automation & Ansible CIS Hardening

## Overview
This document details my specific contributions to the Pair A Trainee Pipeline project. While my partner handled the infrastructure provisioning (Packer and Terraform), my responsibility was to build the CI/CD orchestration using Jenkins and implement the configuration management and security hardening using Ansible.

## 1. Jenkins CI/CD Pipeline (`Jenkinsfile`)

### Objective
To create a fully automated, declarative pipeline that orchestrates the entire infrastructure lifecycle without human intervention.

### Key Implementations

#### Parameterized Builds
```groovy
parameters {
    booleanParam(name: 'DESTROY_AND_REBUILD', defaultValue: false, description: 'Destroy Terraform resources first, then run a full fresh rebuild')
    booleanParam(name: 'REBUILD_IMAGE', defaultValue: false, description: 'Rebuild the Packer image first, else reuse the existing one')
    booleanParam(name: 'CLEAN_WORKSPACE', defaultValue: true, description: 'Wipe the workspace clean after pipeline finishes')
}
```
**Why I did this:** 
Hardcoding pipeline behavior is inefficient. By adding parameters, we can selectively trigger different stages. The `CLEAN_WORKSPACE` parameter was specifically added as a refinement to allow the Jenkins workspace (and the ephemeral SSH keys) to persist when we need to SSH into the VM for live demonstrations.

#### Persistent SSH Key via Jenkins Credentials
```groovy
stage('Harden with Ansible') {
    steps {
        dir('ansible') {
            withCredentials([sshUserPrivateKey(credentialsId: 'vm-ssh-private-key', keyFileVariable: 'SSH_KEY')]) {
                // ... ansible-playbook ...
            }
        }
    }
}
```
**Why I did this:**
Initially, the pipeline dynamically generated a new, ephemeral SSH key pair during the run. While secure, this prevented us from cleaning the Jenkins workspace if we wanted to retain SSH access to the VM. To align with CIS and standard CI/CD best practices, we switched to a persistent key model: the public key (`id_rsa.pub`) is stored in Git, and the private key is stored securely in Jenkins Credentials. The pipeline now cleanly injects the private key into Ansible using `withCredentials`, allowing us to always clean the workspace (`cleanWs()`) while still maintaining our ability to SSH into the VM locally.

#### Handling Workspace State Leakage
```groovy
post {
    always {
        script {
            if (params.CLEAN_WORKSPACE) {
                cleanWs()
            }
        }
    }
}
```
**Why I did this:**
Leaving build artifacts (like downloaded ISOs and Terraform plugins) clutters the Jenkins server and can cause "state leakage" where a build succeeds only because of leftover files. `cleanWs()` ensures every build starts fresh unless explicitly bypassed for demonstrations.

---

## 2. Ansible Configuration & CIS Hardening

### Objective
To securely configure the raw AlmaLinux 9 VM provisioned by Terraform and enforce the strict CIS (Center for Internet Security) Level 1 baseline.

### Key Implementations

#### Variable Precedence Demonstration (`group_vars/all/vars.yml` & `playbook.yml`)
I demonstrated an understanding of Ansible variable precedence by utilizing Level 1 (`group_vars`) and Level 2 (`playbook.yml`) variables to tailor the CIS role.

**Level 1 (`vars.yml`):**
```yaml
rhel9cis_level_2: false
rhel9cis_syslog: rsyslog
rhel9cis_sshd_clientaliveinterval: 300
rhel9cis_pam_faillock_deny: 0
```
**Why I did this:** 
This configuration explicitly disables Level 2 rules, forces `rsyslog` over `journald` (as required by the Pair A brief), and disables the PAM account lockout module (`pam_faillock`) so we don't accidentally lock ourselves out of the test machine during demonstrations.

**Level 2 (`playbook.yml`):**
```yaml
  vars:
    rhel9cis_warning_banner: "PLAYBOOK LEVEL ACCESS BANNER"
```
**Why I did this:** 
By placing this variable at the playbook level, it overrides any banner defined in `group_vars`, successfully demonstrating Level 2 precedence.


### Proof of CIS Level 1 Enforcement
**Code Snippet:**
```yaml
rhel9cis_level_2: false
```
**Why I did this:** 
The Trainee Pipeline Task Brief specifically mandates **'Level 1 - Server only'** for the lockdown role. The MindPoint Group `rhel9-cis` role includes both Level 1 and Level 2 security profiles. Level 2 rules are much more restrictive and are intended for environments where security is paramount at the cost of functionality. By explicitly defining `rhel9cis_level_2: false` in my `group_vars`, I am providing hard, programmatic proof that I deliberately disabled the Level 2 rules to strictly adhere to the Level 1 Server baseline requirement requested in the project brief.

#### Disk Formatting & Mounting (`playbook.yml`)
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
Terraform provided raw data disks on the `virtio` bus (`/dev/vdb`, `/dev/vdc`). I used Ansible `pre_tasks` to format them with the `xfs` filesystem (as required by Pair A) and persistently mount them before the CIS role runs.

#### Bypassing Strict Role Dependencies (`Jenkinsfile`)
```groovy
sh 'sed -i "s/2.16.1/2.14.0/g" roles/rhel9-cis/vars/main.yml'
```
**Why I did this:**
The official MindPoint Group CIS role enforces a strict check for Ansible `>= 2.16.1`. Because AlmaLinux 9 natively ships with `ansible-core 2.14.x`, the pipeline would fail. I used `sed` to dynamically patch the downloaded role on the fly, allowing it to run smoothly on our native OS.

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
