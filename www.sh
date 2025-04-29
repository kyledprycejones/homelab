sudo apt update
sudo apt install ansible
sudo pip3 install proxmoxer


echo "[pvenodes]
192.168.102.10
192.168.102.11
192.168.102.12" >> /etc/ansible/hosts

echo "ansible_key_file: /opt/ansible/files/public-keys/ansible-key.pub
project_path: /opt/ansible/vms/
image_path: /var/lib/vz/images/0/
domain_name: .homelab.lan
timezone: Europe/London
locale: en_GB.UTF-8
group_name: pvenodes
vms:
  - name: ubuntu-vm1
    vmid: 100
    ip: dhcp
  - name: ubuntu-vm2
    vmid: 101
    ip: dhcp
  - name: ubuntu-vm3
    vmid: 102
    ip: dhcp" >> group_vars/pvenodes.yml"


ansible-vault create vault.yml

echo "---
- name: Assemble variable files on localhost
  hosts: localhost
  tasks:
    - name: Assemble variable files
      ansible.builtin.include_role:
        name: assemble_files
      loop: "{{ variable_files }}"

- name: Download cloud-init images and create snippets
  hosts: pvenodes
  tasks:
    - name: Download cloud-init images
      ansible.builtin.get_url:
        url: "{{ item.url }}"
        dest: "{{ image_path }}{{ item.filename }}"
        mode: "0644"
      loop: "{{ images }}"
      when: item.state == "present"

    - name: Create snippets folder
      ansible.builtin.file:
        path: /var/lib/vz/snippets/
        state: directory
        mode: "0755"

    - name: Create cloud-init user files
      ansible.builtin.template:
        src: user-data.yml.j2
        dest: "/var/lib/vz/snippets/{{ item.name }}-user-data.yml"
        mode: "0644"
      loop: "{{ vms }}"

- name: Create VMs on first Proxmox node
  hosts: pvenodes[0]
  tasks:
    - name: Create virtual machines
      community.general.proxmox_kvm:
        api_user: "{{ api_user }}"
        api_token_id: "{{ api_token_id }}"
        api_token_secret: "{{ api_token_secret }}"
        api_host: "{{ inventory_hostname }}"
        node: pvedemo1
        name: "{{ item.name }}"
        vmid: "{{ item.vmid }}"
        ide: "ide2: local:cloudinit,format=qcow2"
        net: "net0: virtio,bridge=vmbr0"
        ipconfig: "ipconfig0: ip={{ item.ip }}"
        memory: 2048
        cores: 2
        disk: "virtio0: local-lvm:10,format=qcow2"
        ostype: l26
        onboot: false
        state: present
      loop: "{{ vms }}"" >> deploy_vms.yml


