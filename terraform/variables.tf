variable "proxy_addr" {
  description = "Teleport proxy address with port, for example teleport.agency.us:443."
  type        = string
}

variable "identity_file_path" {
  description = "Identity file written by tbot's identity service."
  type        = string
  default     = "../tbot/identity/identity"
}

# One variable describes every Access List and its members. Keys are the list
# names in Teleport. Member and owner names are Teleport usernames: for Entra
# users, the user principal name exactly as Entra sends it. Teleport requires
# at least one owner on every list.
variable "access_lists" {
  description = "Static Access Lists to manage, keyed by list name."
  type = map(object({
    title       = string
    description = optional(string, "")
    roles       = list(string)
    owners      = list(string)
    members     = list(string)
  }))
}
