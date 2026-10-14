resource "teleport_access_list" "this" {
  for_each = var.access_lists

  header = {
    version = "v1"
    metadata = {
      name = each.key
      labels = {
        # Marks the list as Terraform-managed in the Web UI.
        "teleport.dev/iac-tool" = "terraform"
      }
    }
  }

  spec = {
    # Members can be managed from Terraform only on a static list. Static
    # lists have no periodic review in the Web UI; this configuration is the
    # record of who holds access.
    type        = "static"
    title       = each.value.title
    description = each.value.description
    owners      = [for owner in each.value.owners : { name = owner }]
    grants = {
      roles = each.value.roles
    }
  }

  depends_on = [teleport_role.developer]
}

locals {
  # One entry per (list, member) pair, keyed "list/member".
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
