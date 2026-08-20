# Exam Guide: Configuring a Standalone VM with Ansible

If the instructor hands you a pre-existing VM (with an IP address and SSH credentials) and asks you to use the "same method" you used in your pipeline to configure it, you won't have Jenkins or Terraform to help you. You will need to build the Ansible structure manually from your terminal.

Here is exactly how to do it step-by-step.

---

## Step 1: Create the Directory Structure

Create a clean workspace on your computer:
```bash
mkdir exam_project
cd exam_project
mkdir -p inventory group_vars/all
```

## Step 2: Create the Static Inventory

Since Terraform isn't here to dynamically generate your inventory, you must write it manually.

Create a file named `inventory/hosts.ini`:
```ini
[all]
# Replace '192.168.x.x' with the IP the instructor gave you.
# Replace 'sysadmin' with the username the instructor gave you.
exam-vm ansible_host=192.168.x.x ansible_user=sysadmin
```

## Step 3: Define the Requirements (If using a Role)

If the instructor asks you to apply a specific role (like the CIS role, or an Nginx role from Ansible Galaxy), create `requirements.yml`:

```yaml
---
roles:
  # Example: Pulling a random role from Ansible Galaxy
  - name: geerlingguy.nginx
```

Then, download the role immediately so it's ready to use:
```bash
ansible-galaxy role install -r requirements.yml -p roles/ --force
```

## Step 4: Configure Variables (Tailoring)

If the instructor tells you to configure specific settings (like disabling rules, changing ports, etc.), put those inside your `group_vars`.

Create `group_vars/all/vars.yml`:
```yaml
---
# Example variables that the role might expect
nginx_port: 8080
enable_ssl: false

# Or if it's the CIS role again:
rhel9cis_level_2: false
rhel9cis_syslog: rsyslog
```

## Step 5: Write the Playbook

Create your `playbook.yml` file to tie the inventory, the variables, and the downloaded role together:

```yaml
---
- name: Exam Configuration Playbook
  hosts: all
  become: yes  # Run as root/sudo

  roles:
    # Use the name of the role you downloaded in Step 3
    - geerlingguy.nginx
```

## Step 6: Run the Playbook

Finally, you run the playbook manually from your terminal. 

**Scenario A: The instructor gave you an SSH Private Key**
If they gave you a key file (e.g., `instructor_key.pem`), pass it using `-i` (identity) or `--private-key`:
```bash
ansible-playbook -i inventory/hosts.ini playbook.yml --private-key /path/to/instructor_key.pem
```

**Scenario B: The instructor gave you a Password**
If they just gave you a password for the VM, use the `-k` (ask SSH password) and `-K` (ask sudo password) flags. Ansible will prompt you to type the password on your screen:
```bash
ansible-playbook -i inventory/hosts.ini playbook.yml -k -K
```
