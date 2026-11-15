#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="$HOME/vprofile-ansible/zabbix"
VM_IPS=("10.10.10.50" "10.10.10.51" "10.10.10.52")
ZABBIX_VERSION="7.0"
TIMEZONE="Africa/Cairo"

read -rp "SSH user for the VMs: " SSH_USER

DEFAULT_IP=$(hostname -I | awk '{print $1}')
echo "NOTE: use the IP that the VMs can reach through the VPN (not necessarily this one)."
read -rp "IP of this WSL machine as seen by the VMs [${DEFAULT_IP}]: " WSL_IP
WSL_IP=${WSL_IP:-$DEFAULT_IP}

read -rsp "Choose a Zabbix DB password: " DB_PASS; echo
read -rsp "Choose an Ansible Vault password: " VAULT_PASS; echo

if [[ "$DB_PASS" =~ [\"\'\\] ]]; then
  echo "ERROR: the DB password must not contain quotes (' \") or backslashes." >&2
  exit 1
fi

echo ">>> Installing Ansible..."
sudo apt-get update
sudo apt-get install -y ansible python3-pymysql sshpass
ansible-galaxy collection install community.mysql

echo ">>> Creating project in ${TARGET_DIR}"
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"
mkdir -p group_vars/all
mkdir -p roles/zabbix_server/{tasks,handlers}
mkdir -p roles/zabbix_agent/{tasks,handlers}

cat > ansible.cfg <<'EOF'
[defaults]
inventory = inventory.ini
host_key_checking = False
vault_password_file = .vault_pass
EOF

{
  echo "[zabbix_server]"
  echo "localhost ansible_connection=local"
  echo
  echo "[vms]"
  i=1
  for ip in "${VM_IPS[@]}"; do
    echo "vm${i} ansible_host=${ip}"
    i=$((i + 1))
  done
  echo
  echo "[vms:vars]"
  echo "ansible_user=${SSH_USER}"
} > inventory.ini

cat > group_vars/all/vars.yml <<EOF
zabbix_version: "${ZABBIX_VERSION}"
zabbix_timezone: "${TIMEZONE}"
zabbix_server_ip: "${WSL_IP}"
zabbix_db_password: "{{ vault_zabbix_db_password }}"
EOF

printf '%s' "$VAULT_PASS" > .vault_pass
chmod 600 .vault_pass
printf 'vault_zabbix_db_password: "%s"\n' "$DB_PASS" > group_vars/all/vault.yml
#ansible-vault encrypt group_vars/all/vault.yml --vault-password-file .vault_pass

cat > roles/zabbix_server/tasks/main.yml <<'EOF'
---
- name: Add Zabbix repository
  ansible.builtin.apt:
    deb: "https://repo.zabbix.com/zabbix/{{ zabbix_version }}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_{{ zabbix_version }}+ubuntu{{ ansible_distribution_version }}_all.deb"

- name: Install Zabbix packages
  ansible.builtin.apt:
    update_cache: true
    name:
      - zabbix-server-mysql
      - zabbix-frontend-php
      - zabbix-apache-conf
      - zabbix-sql-scripts
      - zabbix-agent2
      - mariadb-server
      - python3-pymysql

- name: Start MariaDB
  ansible.builtin.service:
    name: mariadb
    state: started
    enabled: true

- name: Create Zabbix database
  community.mysql.mysql_db:
    name: zabbix
    encoding: utf8mb4
    collation: utf8mb4_bin
    login_unix_socket: /run/mysqld/mysqld.sock

- name: Create Zabbix DB user
  community.mysql.mysql_user:
    name: zabbix
    password: "{{ zabbix_db_password }}"
    priv: "zabbix.*:ALL"
    login_unix_socket: /run/mysqld/mysqld.sock
  no_log: true

- name: Check if schema already imported
  community.mysql.mysql_query:
    login_db: zabbix
    query: "SHOW TABLES LIKE 'users'"
    login_unix_socket: /run/mysqld/mysqld.sock
  register: schema_check
  changed_when: false

- name: Import schema (first run only)
  when: schema_check.rowcount[0] == 0
  block:
    - name: Allow trigger creation during import
      community.mysql.mysql_variables:
        variable: log_bin_trust_function_creators
        value: 1
        mode: global
        login_unix_socket: /run/mysqld/mysqld.sock

    - name: Import server.sql.gz
      ansible.builtin.shell: >
        zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz |
        mysql --default-character-set=utf8mb4 zabbix

    - name: Restore trigger setting
      community.mysql.mysql_variables:
        variable: log_bin_trust_function_creators
        value: 0
        mode: global
        login_unix_socket: /run/mysqld/mysqld.sock

- name: Set DB password in zabbix_server.conf
  ansible.builtin.lineinfile:
    path: /etc/zabbix/zabbix_server.conf
    regexp: '^#?\s*DBPassword='
    line: "DBPassword={{ zabbix_db_password }}"
  no_log: true
  notify: Restart zabbix server

- name: Set PHP timezone for the frontend
  ansible.builtin.replace:
    path: /etc/zabbix/apache.conf
    regexp: '^\s*#?\s*php_value date.timezone.*$'
    replace: "        php_value date.timezone {{ zabbix_timezone }}"
  notify: Restart apache

- name: Enable and start services
  ansible.builtin.service:
    name: "{{ item }}"
    state: started
    enabled: true
  loop:
    - zabbix-server
    - zabbix-agent2
    - apache2
EOF

cat > roles/zabbix_server/handlers/main.yml <<'EOF'
---
- name: Restart zabbix server
  ansible.builtin.service:
    name: zabbix-server
    state: restarted

- name: Restart apache
  ansible.builtin.service:
    name: apache2
    state: restarted
EOF

cat > roles/zabbix_agent/tasks/main.yml <<'EOF'
---
- name: Add Zabbix repository
  ansible.builtin.apt:
    deb: "https://repo.zabbix.com/zabbix/{{ zabbix_version }}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_{{ zabbix_version }}+ubuntu{{ ansible_distribution_version }}_all.deb"

- name: Install zabbix-agent2
  ansible.builtin.apt:
    update_cache: true
    name: zabbix-agent2

- name: Set Server
  ansible.builtin.lineinfile:
    path: /etc/zabbix/zabbix_agent2.conf
    regexp: '^Server='
    line: "Server={{ zabbix_server_ip }}"
  notify: Restart zabbix agent

- name: Set Hostname
  ansible.builtin.lineinfile:
    path: /etc/zabbix/zabbix_agent2.conf
    regexp: '^#?\s*Hostname='
    line: "Hostname={{ inventory_hostname }}"
  notify: Restart zabbix agent

- name: Enable and start agent
  ansible.builtin.service:
    name: zabbix-agent2
    state: started
    enabled: true
EOF

cat > roles/zabbix_agent/handlers/main.yml <<'EOF'
---
- name: Restart zabbix agent
  ansible.builtin.service:
    name: zabbix-agent2
    state: restarted
EOF

cat > site.yml <<'EOF'
---
- name: Zabbix server
  hosts: zabbix_server
  become: true
  roles:
    - zabbix_server

- name: Zabbix agents on the VMs
  hosts: vms
  become: true
  roles:
    - zabbix_agent
EOF

GITIGNORE="$HOME/vprofile-ansible/.gitignore"
touch "$GITIGNORE"
for line in "zabbix/.vault_pass" "*.vault_pass" "Nagios/*.tar.gz" "Nagios/nagios-4.*/" "Nagios/nagios-plugins-*/"; do
  grep -qxF "$line" "$GITIGNORE" || echo "$line" >> "$GITIGNORE"
done

echo ">>> Checking playbook syntax..."
ansible-playbook site.yml --syntax-check

echo
echo "Project created in: ${TARGET_DIR}"
echo

read -rp "Install the Zabbix SERVER on this machine now? [y/N] " ANS
if [[ "${ANS,,}" == "y" ]]; then
  ansible-playbook site.yml --limit zabbix_server --ask-become-pass
  echo
  echo "Open http://localhost/zabbix and finish the setup wizard:"
  echo "  DB type MySQL, database zabbix, user zabbix, password = the one you chose."
  echo "  Default login: Admin / zabbix  (change it right away)."
fi

read -rp "Install the Zabbix AGENT on the 3 VMs now? [y/N] " ANS
if [[ "${ANS,,}" == "y" ]]; then
  echo ">>> Testing SSH access to the VMs..."
  if ansible vms -m ping; then
    ansible-playbook site.yml --limit vms --ask-become-pass
  else
    echo "Cannot reach the VMs. Check the VPN/network and the SSH user, then run:"
    echo "  ssh-copy-id ${SSH_USER}@<VM_IP>"
    echo "  cd ${TARGET_DIR} && ansible vms -m ping"
    echo "  ansible-playbook site.yml --limit vms --ask-become-pass"
  fi
fi

echo
echo "Done. Add the hosts in the Zabbix UI: Data collection > Hosts > Create host"
echo "  Host names: vm1, vm2, vm3 | Template: Linux by Zabbix agent | Agent port 10050"
