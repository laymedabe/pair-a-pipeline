terraform {
  backend "local" {
    path = "/var/lib/jenkins/terraform.tfstate"
  }
}
