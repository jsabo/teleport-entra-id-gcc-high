output "access_lists" {
  description = "Managed Access Lists with the roles they grant and their members."
  value = {
    for name, list in var.access_lists : name => {
      roles   = list.roles
      members = list.members
    }
  }
}
