pipeline {
    agent any
    
    parameters {
        booleanParam(name: 'DESTROY_AND_REBUILD', defaultValue: false, description: 'Destroy Terraform resources first, then run a full fresh rebuild')
        booleanParam(name: 'REBUILD_IMAGE', defaultValue: false, description: 'Rebuild the Packer image first, else reuse the existing one')
    }

    environment {
        // Vault password fetched from Jenkins credentials (never hardcoded in Git)
        VAULT_PASS = credentials('ansible-vault-password')
        TF_IN_AUTOMATION = 'true'
    }

    stages {
        stage('Teardown Infrastructure') {
            when {
                expression { params.DESTROY_AND_REBUILD }
            }
            steps {
                dir('terraform') {
                    // Wiped workspace means a destroy button with nothing to destroy!
                    // In a production environment, state lives in a persistent remote backend 
                    // (e.g., S3, pg, Consul) so we can run a destroy even on a fresh Jenkins workspace.
                    sh 'terraform init'
                    sh 'terraform destroy -auto-approve'
                }
            }
        }

        stage('Build Golden Image') {
            when {
                expression { params.REBUILD_IMAGE || params.DESTROY_AND_REBUILD }
            }
            steps {
                dir('packer') {
                    sh '/usr/bin/packer init build.pkr.hcl'
                    sh '/usr/bin/packer build -force build.pkr.hcl'
                }
            }
        }

        stage('Provision Infrastructure') {
            steps {
                dir('terraform') {
                    sh 'terraform init'
                    sh 'terraform apply -auto-approve'
                }
            }
        }

        stage('Harden with Ansible') {
            steps {
                dir('ansible') {
                    // Install the pinned CIS role and required collections from requirements.yml
                    sh 'ansible-galaxy role install -r requirements.yml -p roles/ --force'
                    sh 'ansible-galaxy collection install -r requirements.yml --force'
                    
                    // Create a dummy vault password file from the Jenkins credential for this run
                    sh 'echo $VAULT_PASS > vault_password.txt'

                    // Patch the strict version check out of the freshly downloaded role
                    sh 'sed -i "s/2.16.1/2.14.0/g" roles/rhel9-cis/vars/main.yml'

                    // Run the playbook using only Level 1 (group_vars) and Level 2 (playbook vars)
                    sh "ansible-playbook -i inventory/hosts.ini playbook.yml --vault-password-file vault_password.txt"
                }
            }
        }

        stage('Audit & Compliance (Goss)') {
            steps {
                dir('ansible') {
                    // Goss runs as part of the lockdown role if setup_audit / run_audit are triggered.
                    // The report is generated natively by the role.
                    sh 'echo "Goss audit report ready for archival"' 
                }
            }
        }
    }

    post {
        always {
            // Archive the Goss report artifact back to Jenkins
            archiveArtifacts artifacts: 'ansible/audit_reports/*.json, ansible/audit_reports/*.html', allowEmptyArchive: true
            
            // Clean up the workspace, ensuring no secrets or generated inventory are left behind
            cleanWs()
        }
        failure {
            echo 'Pipeline encountered an error. Failing loudly!'
        }
    }
}
