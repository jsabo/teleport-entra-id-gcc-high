# Teleport with Microsoft Entra ID in GCC High

Sign in to Teleport with Microsoft Entra ID from a tenant in Microsoft's US
Government cloud (GCC High), map Entra groups to Teleport roles, and manage who
holds which access as code: roles, Access Lists and their members in Terraform,
applied through Teleport by a bot.

GCC High runs on its own endpoints: sign-in at `login.microsoftonline.us` and
the portal at `portal.azure.us`, not the `.com` hosts of the global cloud.
Teleport's guided Entra ID integration and its directory sync call the global
hosts. The SAML connector in this repository calls neither. Teleport reads
Entra's signing certificate from the `.us` metadata document you give it, and
the user's groups and attributes arrive inside the signed sign-in message, so
nothing is fetched from Microsoft during sign-in.

Written for Teleport 18.11.3 Enterprise, self-hosted.

## What you need

- `tctl` logged in to your cluster with the preset `editor` role.
- An account in the GCC High tenant that can create enterprise applications
  (Cloud Application Administrator or higher).
- The Entra groups you want to map and the Teleport roles each should receive.
- For Part 2: Terraform 1.5 or later, `tbot` (the same major version as your
  cluster) and `jq`.

Run every command from the root of this repository.

## How it works

```
 browser ──► Teleport proxy ──► login.microsoftonline.us ──► Teleport proxy ──► signed in
             redirects to       user signs in, Entra          verifies the assertion
             the connector's    signs an assertion with       against the metadata
             sign-in URL        groups and claims and         document, maps groups
                                posts it to the Reply URL     to roles, stores claims
                                                              as traits
```

Entra and Teleport talk SAML (Security Assertion Markup Language). After the
user signs in, Entra sends Teleport a signed document called the assertion.
Each fact in it is a claim. Entra posts the assertion to the Reply URL, also
called the Assertion Consumer Service (ACS), and names Teleport by an Entity ID;
in Teleport both are the same URL. Teleport checks the signature against Entra's
federation metadata, an XML document Entra publishes with its certificate and
sign-in address.

The assertion carries the user's group memberships as object IDs. The connector
maps each object ID to Teleport roles; a user in several mapped groups receives
all of them. Every other claim, such as the user principal name (UPN, the Entra
sign-in name like `alice@agency.us`), is stored on the Teleport user as a trait,
a named list of values that roles can read.

Part 2 adds a second source of roles. An Access List is a named group of
Teleport users that grants roles to its members. Terraform creates the lists and
adds members by username, which for Entra users is the UPN. At every sign-in
Teleport looks up the user's memberships and adds the lists' roles to the
session. Terraform signs in to Teleport as a bot, a Teleport identity for a
machine; `tbot` is the agent that joins as the bot and keeps its short-lived
certificate renewed.

## Part 1: Sign in with Entra ID

### 1. Create the enterprise application

1. Sign in to <https://portal.azure.us> and open **Microsoft Entra ID**.
2. **Enterprise applications** → **New application** → **Create your own
   application**. Name it `Teleport`, choose **Integrate any other application
   you don't find in the gallery (Non-gallery)**, and create it.
3. From the application's **Overview** page copy the **Application ID**.
4. From **Microsoft Entra ID → Overview** copy the **Tenant ID**.

### 2. Configure SAML in Entra

`PROXY_ADDR` below is the address users type to reach Teleport, for example
`teleport.agency.us`.

1. In the application open **Single sign-on** → **SAML**. Edit **Basic SAML
   Configuration** and set both **Identifier (Entity ID)** and **Reply URL** to:

   ```
   https://PROXY_ADDR/v1/webapi/saml/acs/entra-id
   ```

2. Edit **Attributes & Claims**. Open **Unique User Identifier (Name ID)**, set
   **Name identifier format** to **Default** and the source attribute to
   `user.userprincipalname`. The Teleport username is the UPN.
3. **Add a group claim**. Choose **Groups assigned to the application** and
   leave the source attribute as **Group ID**. Entra limits a SAML assertion to
   150 groups; past that it leaves the groups out and sends a link to the
   Microsoft Graph API instead, which Teleport can only follow on the global
   cloud endpoint. Sending only the groups assigned to this application keeps
   every user under the limit. Choosing **Security groups** instead sends every
   group the user belongs to, and a user in more than 150 groups then signs in
   with no roles.
4. **Users and groups** → **Add user/group**: assign every group you will map
   to roles. Under **Properties** set **Assignment required?** to **Yes** so
   only members of assigned groups can sign in through Teleport.

### 3. Write the connector

```bash
cp connector.example.yaml connector.yaml
```

Fill in the five placeholders:

| Placeholder | Value |
|---|---|
| `PROXY_ADDR` | The address from step 2, for example `teleport.agency.us`. |
| `TENANT_ID` | Tenant ID from step 1. |
| `APP_ID` | Application ID from step 1. |
| `GROUP_ADMINS_ID`, `GROUP_DEVELOPERS_ID` | Object IDs of the Entra groups to map. Add or remove `attributes_to_roles` entries to match your groups. |

The connector's `entity_descriptor_url` points at Entra's federation metadata
on the GCC High sign-in host, `login.microsoftonline.us`. Leave
`entra_id_groups_provider.disabled: true`; it tells Teleport not to follow the
Graph link described in step 2.3.

### 4. Test, then create the connector

```bash
tctl sso test connector.yaml
```

A browser opens on the Entra sign-in page. Sign in as a member of a mapped
group. `tctl` then prints the claims Teleport received and the roles they mapped
to, without saving anything. When that looks right, create the connector:

```bash
tctl create -f connector.yaml
```

### 5. Sign in and check

```bash
tsh login --proxy=PROXY_ADDR --auth=entra-id
tsh status
```

`tsh status` lists the roles the user received. To see the traits stored from
the assertion, where `USER_PRINCIPAL_NAME` is the user's UPN:

```bash
tctl get users/USER_PRINCIPAL_NAME
```

The `traits` block holds the group object IDs under
`http://schemas.microsoft.com/ws/2008/06/identity/claims/groups` and the other
Entra claims under their full names.

To make Entra the default sign-in method in the Web UI and `tsh`, open the
cluster's authentication settings in an editor and set `type: saml` and
`connector_name: entra-id` under `spec`:

```bash
tctl edit cluster_auth_preference
```

## Part 2: Manage access with Terraform

The connector decides who may sign in and which roles their Entra groups give
them. Terraform manages the rest: the roles, the Access Lists that grant them,
and who is a member. Terraform does not manage users. Entra creates the Teleport
user at the first sign-in and refreshes it at every sign-in, so Terraform only
needs the username: the UPN exactly as Entra sends it, such as `alice@agency.us`.
You can add a member before that person has ever signed in.

An Access List managed this way has type `static`. Terraform owns its members,
the Web UI shows them read-only, and there is no periodic review because this
configuration is the record of who holds access. Every list needs at least one
owner. Terraform connects to the Teleport proxy as the bot, so the audit log
records every change under the bot's name.

| File | What you edit |
|---|---|
| `terraform/terraform.tfvars.example` | Your lists: title, roles granted, owners, members. Copy to `terraform.tfvars`. |
| `terraform/roles.tf` | Roles the lists grant. Ships with `developer`, which logs in to servers labeled `env: dev` as the part of the UPN before the `@`. |
| `terraform/main.tf` | Creates one Access List and its members per entry in `terraform.tfvars`. No edits needed. |
| `tbot/token.yaml` | The bot's join token. No edits needed. |
| `tbot/tbot.example.yaml` | `tbot` configuration. Copy to `tbot.yaml`. |

### 6. Create the bot

```bash
tctl create -f tbot/token.yaml
tctl bots add terraform --roles=terraform-provider --token=terraform
```

`terraform-provider` is a role Teleport ships for this purpose. The token uses
the bound keypair join method: `tbot` generates a key pair, keeps it on disk,
and proves its identity with it from then on. For the first join Teleport
generated a one-time registration secret; read it:

```bash
tctl get token/terraform --format=json | jq -r '.[0].status.bound_keypair.registration_secret'
```

### 7. Start tbot

```bash
cp tbot/tbot.example.yaml tbot/tbot.yaml
```

Set `proxy_server` to `PROXY_ADDR:443` and paste the registration secret. Then,
in a second terminal, start `tbot` and leave it running:

```bash
tbot start -c tbot/tbot.yaml
```

Within a few seconds it writes the identity file `tbot/identity/identity`, the
bot's certificate and key in the form the Terraform provider reads, and renews
it while running. Delete the `registration_secret` line from `tbot/tbot.yaml`
now; the next start uses the key pair saved in `tbot/storage` instead.

### 8. Describe your lists

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Set `proxy_addr` to `PROXY_ADDR:443` and describe each list:

| Field | Meaning |
|---|---|
| key | The list's name in Teleport, for example `dev-servers`. |
| `title`, `description` | Shown in the Web UI. |
| `roles` | Roles every member receives. Each must exist: a role Teleport ships, such as `auditor`, or one in `terraform/roles.tf`. |
| `owners` | Usernames that own the list. At least one. |
| `members` | Usernames of the members. |

### 9. Apply

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

To change who holds access, edit `members` in `terraform.tfvars` and apply
again. Removing a list from the file removes the list and its members.

### 10. Check

```bash
tctl acl users ls dev-servers --format=json | jq -c '.[] | {name: .spec.name, status: .spec.ineligible_status, added_by: .spec.added_by}'
```

Every member shows `added_by: bot-terraform`. A member who has signed in through
Entra shows `INELIGIBLE_STATUS_ELIGIBLE`. Then sign in as a member:

```bash
tsh login --proxy=PROXY_ADDR --auth=entra-id
tsh status
```

`tsh status` lists the roles from the connector's group mapping plus the roles
of every list the user is a member of.

## Troubleshooting

Part 1 messages appear on the sign-in page and in the Auth Service log. Part 2
messages come from `terraform apply`, `tctl` or the audit log.

| Message | Cause | Fix |
|---|---|---|
| `No roles mapped from claims. The mappings may contain typos.` | No group in the assertion matched an `attributes_to_roles` value. | Check the group object IDs in `connector.yaml`, and that the group is assigned to the application (step 2.4). `tctl sso test` prints the groups received. |
| `SAML: not in expected audience.` | The Entity ID in Entra differs from the connector's `audience`. | Make Entity ID, Reply URL, `acs`, `audience` and `service_provider_issuer` the identical string. |
| `received response with incorrect or missing attribute statements` | The assertion carries no claims. | Add the group claim (step 2.3) and confirm the user is assigned to the application. |
| `Your account is a member of more than 150 Entra ID groups.` | The group claim sends all groups and the user exceeds Entra's limit. | Switch the group claim to **Groups assigned to the application** (step 2.3). |
| The Teleport username is an opaque string instead of the UPN. | The Name ID format is not **Default**. | Set it to **Default** with source `user.userprincipalname` (step 2.2). |
| `owners are missing` | A list in `terraform.tfvars` has no `owners`. Teleport requires at least one owner on every list. | Name an owner. |
| `Access list member's (...) access list (...) is not static` | A list with that name already exists and was created in the Web UI or with `tctl`. Terraform cannot convert it. | Delete the existing list or pick another name. |
| A member's status is empty or `INELIGIBLE_STATUS_USER_NOT_EXIST`. | The user has not signed in yet. Teleport re-checks member status when a user is created or changed and every 30 minutes. | Expected until the first sign-in. If it persists afterwards, the member name differs from the username: compare with `tctl users ls`, including case. |
| A member signs in without the list's roles and the audit log holds `access list skipped because it references non-existent role(s)`. | One of the list's `roles` does not exist. Teleport skips the whole list. | Create the role in `terraform/roles.tf` or fix the name. |
| `tctl` or `tsh` fail with `Cannot connect to the auth server` right after an apply or destroy removed a role. | Your current certificate still names the deleted role. | Run `tsh login` again. |

## References

- Teleport: [Authentication with Microsoft Entra ID (SAML)](https://goteleport.com/docs/zero-trust-access/sso/integrate-idp/entra-id/)
- Teleport: [Managing Access List members with Terraform](https://goteleport.com/docs/configuration/resource-guides/access-list/#managing-access-list-members-with-terraform)
- Teleport: [Terraform provider resources](https://goteleport.com/docs/reference/infrastructure-as-code/terraform-provider/)
- Teleport: [Bound keypair joining](https://goteleport.com/docs/reference/machine-workload-identity/bound-keypair/getting-started/)
- Teleport: [Role templates](https://goteleport.com/docs/reference/access-controls/roles/#role-templates)
- Microsoft: [National cloud deployments for Microsoft Graph and Entra sign-in endpoints](https://learn.microsoft.com/en-us/graph/deployments)
- Microsoft: [Connect to Azure Government using the portal](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-get-started-connect-with-portal)
- Microsoft: [Configure group claims for applications](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-group-claims)
