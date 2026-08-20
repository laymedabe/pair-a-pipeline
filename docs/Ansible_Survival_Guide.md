# The Ultimate Ansible Survival Guide

This guide is designed to be your primary reference for Ansible activities. It contains the most critical commands, directory structures, variable precedence rules, and copy-pasteable examples of the most commonly used modules.

---

## 1. Core CLI Commands

### Ad-Hoc Commands
Run a single module against hosts without writing a full playbook. Great for quick checks.
```bash
# Ping all hosts in the inventory to check connectivity
ansible all -i inventory/hosts.ini -m ping

# Run a raw shell command on a specific group of hosts (e.g., 'webservers')
ansible webservers -i inventory/hosts.ini -m command -a "uptime"

# Check disk space on all hosts using elevated privileges (sudo)
ansible all -i inventory/hosts.ini -m command -a "df -h" --become
```

### Playbook Commands
```bash
# Run a playbook
ansible-playbook -i inventory/hosts.ini playbook.yml

# Run a playbook and ask for the SSH password (if not using keys)
ansible-playbook -i inventory/hosts.ini playbook.yml -k

# Run a playbook and ask for the sudo (become) password
ansible-playbook -i inventory/hosts.ini playbook.yml -K

# Perform a DRY RUN (shows what WOULD change without actually changing anything)
ansible-playbook -i inventory/hosts.ini playbook.yml --check

# Pass an extra variable at runtime (Highest Precedence)
ansible-playbook -i inventory/hosts.ini playbook.yml -e "my_var=override_value"
```

---

## 2. Standard Directory Structure

If you need to build a project from scratch, use this standard layout:
```text
project_root/
├── ansible.cfg              # Master configuration (e.g., disable host_key_checking)
├── inventory/
│   └── hosts.ini            # List of servers and their IPs
├── group_vars/
│   └── all/
│       └── vars.yml         # Variables applied to ALL hosts
├── roles/                   # Downloaded or custom roles live here
├── requirements.yml         # Defines which roles to download from Ansible Galaxy
└── playbook.yml             # The master playbook that maps roles/tasks to hosts
```

---

## 3. Variable Precedence Cheat Sheet

Ansible applies variables based on where they are defined. If the same variable is defined in multiple places, the one with the **highest precedence wins**.

**Lowest to Highest (The Last One Wins):**
1. `roles/defaults/main.yml` *(Lowest - role defaults)*
2. `inventory/hosts.ini` (Host/Group variables defined in inventory)
3. `group_vars/all/vars.yml` *(Level 1 - standard project variables)*
4. `roles/vars/main.yml` *(Variables hardcoded inside a role)*
5. `playbook.yml` `vars:` block *(Level 2 - playbook overrides)*
6. `--extra-vars` or `-e` at the command line *(Highest - immediate override)*

---

## 4. Most Critical Modules (Copy & Paste Examples)

These are the core modules you will need for 90% of Ansible tasks.

### 1. `package` / `dnf` / `apt` (Install Software)
Ensures a specific piece of software is installed or removed.
```yaml
- name: Ensure Apache is installed
  package:
    name: httpd
    state: present # use 'absent' to uninstall, 'latest' for the newest version
```

### 2. `service` / `systemd` (Manage Services)
Ensures a service is running and set to start on boot.
```yaml
- name: Ensure Apache is running and enabled on boot
  service:
    name: httpd
    state: started # use 'stopped', 'restarted', or 'reloaded'
    enabled: yes
```

### 3. `file` (Manage Files & Directories)
Creates directories, symlinks, or ensures specific permissions.
```yaml
- name: Create a secure directory
  file:
    path: /opt/secure_data
    state: directory
    owner: root
    group: root
    mode: '0700'
```

### 4. `copy` (Upload a File)
Copies a file from your Ansible control node to the remote server.
```yaml
- name: Copy custom configuration file
  copy:
    src: ./files/custom_httpd.conf
    dest: /etc/httpd/conf.d/custom_httpd.conf
    owner: root
    mode: '0644'
    backup: yes # Creates a backup of the original file before overwriting!
```

### 5. `template` (Upload a Dynamic File)
Like `copy`, but processes Jinja2 variables (e.g., `{{ variable_name }}`) inside the file before uploading.
```yaml
- name: Deploy dynamic configuration from template
  template:
    src: ./templates/config.j2
    dest: /etc/myapp/config.conf
```

### 6. `user` (Manage User Accounts)
Creates or modifies a user on the Linux system.
```yaml
- name: Create a new sysadmin user
  user:
    name: jdoe
    comment: "John Doe"
    groups: wheel
    append: yes
    shell: /bin/bash
    generate_ssh_key: yes
```

### 7. `lineinfile` (Edit a Specific Line in a File)
Ensures a specific line exists in a file, or modifies an existing line using regex. Extremely useful for quick config edits.
```yaml
- name: Ensure SELinux is set to enforcing
  lineinfile:
    path: /etc/selinux/config
    regexp: '^SELINUX='
    line: SELINUX=enforcing
```

### 8. `command` / `shell` (Run Raw Commands)
When a module doesn't exist for what you want to do. (Note: Only use `shell` if you need pipes `|` or redirects `>`).
```yaml
- name: Run a simple command
  command: /usr/bin/uptime

- name: Run a shell command with a pipe
  shell: cat /var/log/messages | grep error > /tmp/errors.txt
```

---

## 5. Playbook Structure Template

If you are asked to write a playbook from scratch, use this skeleton:

```yaml
---
- name: My Complete Server Setup Playbook
  hosts: all            # Which hosts to target (from inventory)
  become: yes           # Run all tasks as sudo (root)
  
  vars:                 # Playbook level variables
    http_port: 80
    max_clients: 200
  
  pre_tasks:            # Tasks to run BEFORE roles
    - name: Run a quick update
      command: dnf update -y
      
  roles:                # Roles to execute
    - common_setup
    - rhel9-cis

  tasks:                # Tasks to run AFTER roles
    - name: Install Nginx
      package:
        name: nginx
        state: present

  handlers:             # Tasks that only run if notified (e.g., restarting a service after config change)
    - name: restart nginx
      service:
        name: nginx
        state: restarted
```
