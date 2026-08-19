[all]
%{ for name, ip in nodes ~}
${name} ansible_host=${ip} ansible_user=sysadmin
%{ endfor ~}

[pair_a]
%{ for name, ip in nodes ~}
${name}
%{ endfor ~}
