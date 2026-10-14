resource "teleport_access_list" "this" {
  for_each = var.access_lists

  header = {
    version = "v1"
    metadata = {
      name = each.key
      labels = {
        # Shows the list as Terraform-managed in the Web UI.
        "teleport.dev/iac-tool" = "terraform"
      }
    }
  }

  spec = {
    type        = "static"
    title       = each.value.title
    description = each.value.description
    owners      = [for owner in each.value.owners : { name = owner }]
    grants = {
      roles = each.value.roles
    }
  }

  # Roles must exist before a list grants them. Add every role from roles.tf.
  depends_on = [teleport_role.developer]
}

locals {
  members = merge([
    for list_name, list in var.access_lists : {
      for member in list.members : "${list_name}/${member}" => {
        list   = list_name
        member = member
      }
    }
  ]...)
}

resource "teleport_access_list_member" "this" {
  for_each = local.members

  header = {
    version = "v1"
    metadata = {
      name = each.value.member
    }
  }

  spec = {
    access_list     = teleport_access_list.this[each.value.list].id
    membership_kind = 1 # 1 = user, 2 = nested Access List
  }
}
