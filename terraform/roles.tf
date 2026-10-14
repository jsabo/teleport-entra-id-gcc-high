# Roles granted by the Access Lists. Managed here so Terraform creates them
# before any list that grants them: Teleport skips a whole list at sign-in if
# it grants a role that does not exist.
resource "teleport_role" "developer" {
  version = "v8"
  metadata = {
    name        = "developer"
    description = "SSH to env: dev servers as the local part of the user principal name"
  }
  spec = {
    allow = {
      # The Teleport username is the user principal name; email.local() keeps
      # the part before the @, so alice@agency.us logs in as alice.
      logins = ["{{email.local(user.metadata.name)}}"]
      node_labels = {
        env = ["dev"]
      }
    }
  }
}
