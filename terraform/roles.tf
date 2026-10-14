resource "teleport_role" "developer" {
  version = "v8"
  metadata = {
    name        = "developer"
    description = "SSH to env: dev servers as the part of the user principal name before the @"
  }
  spec = {
    allow = {
      # alice@agency.us logs in as alice.
      logins = ["{{email.local(user.metadata.name)}}"]
      node_labels = {
        env = ["dev"]
      }
    }
  }
}
