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
