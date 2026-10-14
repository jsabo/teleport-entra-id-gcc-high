# Terraform talks to the Teleport proxy as the "terraform" bot, using the
# identity file that tbot keeps renewed. Bots are exempt from per-action MFA,
# so no human has to approve each apply.
provider "teleport" {
  addr               = var.proxy_addr
  identity_file_path = var.identity_file_path
}
