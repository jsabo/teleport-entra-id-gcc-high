# Terraform authenticates as the bot with the identity file tbot keeps renewed.
provider "teleport" {
  addr               = var.proxy_addr
  identity_file_path = var.identity_file_path
}
