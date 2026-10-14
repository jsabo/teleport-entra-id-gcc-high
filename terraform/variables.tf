variable "proxy_addr" {
  description = "Teleport proxy address with port, for example teleport.agency.us:443."
  type        = string
}

variable "identity_file_path" {
  description = "Identity file written by tbot."
  type        = string
  default     = "../tbot/identity/identity"
}

variable "access_lists" {
  description = "Static Access Lists keyed by list name. Owners and members are Teleport usernames."
  type = map(object({
    title       = string
    description = optional(string, "")
    roles       = list(string)
    owners      = list(string)
    members     = list(string)
  }))
}
