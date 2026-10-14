# Teleport SSO with Microsoft Entra ID in GCC High

Sign Teleport users in with Microsoft Entra ID from a tenant in Microsoft's US
Government cloud (GCC High), map Entra groups to Teleport roles, and pass Entra
claims through to Teleport as traits. The sign-in setup is one enterprise
application in Entra and one SAML connector in Teleport. A second, independent
part manages who holds which access with Terraform: roles, Access Lists and their
members, applied through Teleport as a bot identity (steps 6 to 10).

GCC High runs on its own endpoints: sign-in at `login.microsoftonline.us` and the
portal at `portal.azure.us`, not the `.com` hosts of the global cloud. Teleport's
guided Entra ID integration and its directory sync are built for the global
endpoints. The SAML connector in this repository is not: Teleport reads Entra's
signing certificate from the `.us` metadata document you give it, and the user's
groups and attributes arrive inside the signed assertion, so nothing is fetched
from the Microsoft Graph API during sign-in.

Written against Teleport 18.11.3 (Enterprise, self-hosted). The Terraform part
(steps 6 to 10) was run end to end against a Teleport 18.11.3 cluster with an
Entra ID connector: apply, sign-in, member add and remove, destroy.

Terms, defined once. **SAML** (Security Assertion Markup Language) is the protocol
in which Entra sends Teleport a signed document, the **assertion**, describing the
user who just signed in. Each fact in it is a **claim**. The **Entity ID** is the
name Entra knows Teleport by, and the **Reply URL** (also called the Assertion
Consumer Service, **ACS**) is where Entra posts the assertion; in Teleport both are
the same URL. The **federation metadata** is an XML document Entra publishes with
its signing certificate and sign-in address. A Teleport **trait** is a key with a
list of values attached to a user; roles read traits with `{{external.<name>}}`.

## How a sign-in flows

```
 browser ──► Teleport proxy ──► login.microsoftonline.us ──► Teleport proxy ──► signed in
             redirects to       user signs in, Entra          verifies the assertion
             the connector's    signs an assertion with       against the metadata
             sign-in URL        groups and claims and         document, maps groups
                                posts it to the Reply URL     to roles, stores claims
                                                              as traits
```

Entra puts the user's group memberships in the assertion as a list of group object
IDs. The connector maps each object ID to one or more Teleport roles; a user in
several mapped groups receives the union. Every other claim (user principal name,
given name, surname, email, anything you add) is stored on the Teleport user as a
trait and can be used in role templates.

## Prerequisites

- A self-hosted Teleport Enterprise cluster and `tctl` logged in with a role that
  can manage `saml` resources (the preset `editor` role does).
- An account in the GCC High tenant that can create enterprise applications (Cloud
  Application Administrator or higher).
- The Entra groups you want to map, and the Teleport roles each should receive.

## 1. Create the enterprise application

1. Sign in to <https://portal.azure.us> and open **Microsoft Entra ID**.
2. **Enterprise applications** → **New application** → **Create your own
   application**. Name it `Teleport`, choose **Integrate any other application you
   don't find in the gallery (Non-gallery)**, and create it.
3. From the application's **Overview** page copy the **Application ID**.
4. From **Microsoft Entra ID → Overview** copy the **Tenant ID**.

## 2. Write the connector

Copy the example and fill in your values:

```bash
cp connector.example.yaml connector.yaml
```

| Placeholder | Value |
|---|---|
| `PROXY_ADDR` | The address users type to reach Teleport, for example `teleport.example.gov`. |
| `TENANT_ID` | Tenant ID from step 1. |
| `APP_ID` | Application ID from step 1. |
| `GROUP_ADMINS_ID`, `GROUP_DEVELOPERS_ID` | Object IDs of the Entra groups to map. Add or remove `attributes_to_roles` entries to match your groups. |

The connector's `entity_descriptor_url` is Entra's federation metadata document on
the GCC High sign-in host:

```
https://login.microsoftonline.us/TENANT_ID/federationmetadata/2007-06/federationmetadata.xml?appid=APP_ID
```

Keep `entra_id_groups_provider.disabled: true`. It is explained under [Group
claim](#group-claim-what-entra-sends).

## 3. Configure SAML in Entra

In the enterprise application:

1. **Single sign-on** → **SAML**. Edit **Basic SAML Configuration** and set both
   **Identifier (Entity ID)** and **Reply URL** to the connector's `acs` value:

   ```
   https://PROXY_ADDR/v1/webapi/saml/acs/entra-id
   ```

   Save.
2. Edit **Attributes & Claims**. Open **Unique User Identifier (Name ID)**, set
   **Name identifier format** to **Default** and the source attribute to
   `user.userprincipalname`. Save. The Teleport username is the user principal name.
3. **Add a group claim**. Choose **Groups assigned to the application**, leave the
   source attribute as **Group ID**, and save. Entra now sends the object IDs of the
   assigned groups the user belongs to.
4. **Users and groups** → **Add user/group** and assign every group you mapped in
   `connector.yaml`. Under **Properties**, set **Assignment required?** to **Yes**
   so only members of assigned groups can sign in through Teleport.

## 4. Test, then create the connector

`tctl sso test` runs a full sign-in through the connector without saving it and
prints the attributes Teleport received and the roles they mapped to:

```bash
tctl sso test connector.yaml
```

When the browser lands back in Teleport signed in, create the connector:

```bash
tctl create -f connector.yaml
```

## 5. Verify

```bash
tsh login --proxy=PROXY_ADDR --auth=entra-id
tsh status
```

`tsh status` lists the roles the user received. To see the traits stored from the
assertion:

```bash
tctl get users/<user principal name>
```

The `traits` block holds the group object IDs under
`http://schemas.microsoft.com/ws/2008/06/identity/claims/groups`, the standard
Entra claims under their full URIs, and any custom claim under its short name.

To make Entra the default sign-in method in the Web UI and `tsh`:

```yaml
kind: cluster_auth_preference
version: v2
metadata:
  name: cluster-auth-preference
spec:
  type: saml
  connector_name: entra-id
```

```bash
tctl create -f cap.yaml
```

## 6. Manage access with Terraform

The connector decides who may sign in and which roles their Entra groups give
them. Day-to-day access changes, giving a named person a role or taking it away,
are easier to review and audit as code. The `terraform/` directory manages three
things through the Teleport Terraform provider: roles, **static Access Lists**,
and their members. Terraform connects to the Teleport proxy as a bot, so every
change is recorded in the audit log under the bot's name.

Terraform does not manage users. Entra creates the Teleport user at the first
sign-in and refreshes it at every sign-in; a user created any other way under the
same name blocks that sign-in. What Terraform manages is **membership by
username**: an Access List member is the Teleport username, which for Entra users
is the user principal name exactly as Entra sends it, such as `alice@agency.us`.
A member can be added before that person has ever signed in. At each sign-in
Teleport looks up the user's memberships and adds the lists' roles to the
session.

An Access List has a type. The default type is reviewed periodically in the Web
UI, which is where its members are managed. The `static` type is for lists
managed as code: Terraform owns the members, the Web UI shows them read-only, and
there is no review cycle because this configuration is the record of who holds
access. Every list needs at least one owner.

Terms, defined once. A **bot** is a Teleport identity for a machine; **tbot** is
the agent that joins as the bot and keeps a short-lived certificate renewed. The
**bound keypair** join method ties the bot to a key pair that tbot generates and
keeps on disk, so no long-lived secret is stored anywhere. An **identity file** is
that certificate and key in the one-file form the Terraform provider reads.

| File | Holds |
|---|---|
| `terraform/roles.tf` | The roles that lists grant. `developer` logs in to `env: dev` servers as the part of the user principal name before the `@`, so `alice@agency.us` becomes `alice`. |
| `terraform/main.tf` | One `teleport_access_list` and its `teleport_access_list_member` entries per key of the `access_lists` variable. |
| `terraform/terraform.tfvars.example` | The lists: title, roles granted, owners, members. Copy to `terraform.tfvars` and edit. |
| `tbot/token.yaml` | The bot's join token (bound keypair). |
| `tbot/tbot.example.yaml` | tbot configuration. Copy to `tbot/tbot.yaml` and fill in. |

## 7. Create the bot

```bash
tctl create -f tbot/token.yaml
tctl bots add terraform --roles=terraform-provider --token=terraform
```

`terraform-provider` is a role Teleport ships for this purpose. The second
command prints a `tbot start` example; the configuration file in the next step
replaces it. Read the one-time registration secret from the token:

```bash
tctl get token/terraform --format=json | jq -r '.[0].status.bound_keypair.registration_secret'
```

## 8. Run tbot

```bash
cp tbot/tbot.example.yaml tbot/tbot.yaml
```

Set `proxy_server` and paste the registration secret, then start tbot from the
repository root:

```bash
tbot start -c tbot/tbot.yaml
```

The identity file appears at `tbot/identity/identity` and is renewed while tbot
runs. Delete the `registration_secret` line from `tbot/tbot.yaml` after the first
start; the key pair in `tbot/storage` is the bot's identity from then on.

## 9. Apply

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Set `proxy_addr` and describe your lists, then:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

To change who holds access, edit `members` in `terraform.tfvars` and apply again.
Removing a list from the variable removes the list and its members.

## 10. Verify

```bash
tctl acl users ls dev-servers --format=json | jq -c '.[] | {name: .spec.name, status: .spec.ineligible_status, added_by: .spec.added_by}'
```

Every member shows `added_by: bot-terraform`. A member who has signed in through
Entra shows `INELIGIBLE_STATUS_ELIGIBLE`. One who has not signed in yet shows an
empty status or `INELIGIBLE_STATUS_USER_NOT_EXIST`; Teleport re-evaluates member
status when a user is created or changed and at least every 30 minutes, so the
status settles after their first sign-in. Then sign in as a member:

```bash
tsh login --proxy=PROXY_ADDR --auth=entra-id
tsh status
```

`tsh status` lists the roles from the connector's group mapping plus the roles
granted by every list the user is a member of.

## Group claim: what Entra sends

Entra limits a SAML assertion to 150 groups. Past that it leaves the groups claim
out and sends a link to the Microsoft Graph API instead. Teleport can follow that
link only with Graph API credentials on the global cloud endpoints, which a GCC
High tenant does not offer, so the connector sets
`entra_id_groups_provider.disabled: true` and the group claim is scoped to groups
assigned to the application. Only the groups you assign (the ones you map to roles)
are emitted, nested membership is not expanded, and the limit is never reached.

If you would rather emit every security group the user belongs to, choose
**Security groups** in the group claim instead. Users in more than 150 groups,
nested groups included, then sign in with no groups claim and receive no roles.

## Troubleshooting

Teleport reports these on the sign-in page and in the Auth Service log.

| Message | Cause | Fix |
|---|---|---|
| `No roles mapped from claims. The mappings may contain typos.` | No group in the assertion matched an `attributes_to_roles` value. | Check the group object IDs in `connector.yaml`, and that the group is assigned to the application (step 3.4). `tctl sso test` prints the groups received. |
| `SAML: not in expected audience.` | The Entity ID in Entra differs from the connector's `audience`. | Make Entity ID, Reply URL, `acs`, `audience` and `service_provider_issuer` the identical string. |
| `received response with incorrect or missing attribute statements` | The assertion carries no claims. | Add the group claim (step 3.3) and confirm the user is assigned to the application. |
| `Your account is a member of more than 150 Entra ID groups.` | The group claim emits all groups and the user exceeds Entra's limit. | Switch the group claim to **Groups assigned to the application** and keep `entra_id_groups_provider.disabled: true`. |
| The Teleport username is an opaque string instead of the user principal name. | The Name ID format is not **Default**. | Set it to **Default** with source `user.userprincipalname` (step 3.2). |

Terraform reports these during `apply`, or the sign-in shows them afterwards.

| Message | Cause | Fix |
|---|---|---|
| `owners are missing` | A list in `terraform.tfvars` has an empty `owners`. Teleport requires at least one owner on every list, static ones included. | Name an owner. |
| `Access list member's ("alice@agency.us") access list ("dev-servers") is not static ...` | A list with that name already exists and was created in the Web UI or with `tctl`, so its type is the default. Terraform cannot convert it. | Delete the existing list or pick another name. |
| A member stays at `INELIGIBLE_STATUS_USER_NOT_EXIST` after signing in. | The member name differs from the Teleport username. Names are compared exactly, including case. | Compare with `tctl users ls` and use the user principal name as Entra sends it. |
| A member signs in but does not receive the list's roles, and the audit log holds `access list skipped because it references non-existent role(s)`. | One of the list's `roles` does not exist. Teleport skips the whole list. | Create the role in `terraform/roles.tf` or fix the name. |
| `tctl` and `tsh` fail with `Cannot connect to the auth server` right after an apply or destroy removed a role. | Your current certificate still names the deleted role. | Run `tsh login` again to get a certificate without it. |
| tbot on macOS logs `Secure symlinks not supported on this platform`. | Informational. The storage and identity directories work without secure symlinks. | Add `symlinks: insecure` under `storage` and the identity `destination` to silence it. |

## References

- Teleport: [Authentication with Microsoft Entra ID (SAML)](https://goteleport.com/docs/zero-trust-access/sso/integrate-idp/entra-id/)
- Teleport: [Managing Access List members with Terraform](https://goteleport.com/docs/configuration/resource-guides/access-list/#managing-access-list-members-with-terraform)
- Teleport: [Terraform provider resources](https://goteleport.com/docs/reference/infrastructure-as-code/terraform-provider/)
- Teleport: [Bound keypair joining](https://goteleport.com/docs/reference/machine-workload-identity/bound-keypair/getting-started/)
- Teleport: [Role templates](https://goteleport.com/docs/reference/access-controls/roles/#role-templates)
- Microsoft: [National cloud deployments for Microsoft Graph and Entra sign-in endpoints](https://learn.microsoft.com/en-us/graph/deployments)
- Microsoft: [Connect to Azure Government using the portal](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-get-started-connect-with-portal)
- Microsoft: [Configure group claims for applications](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-group-claims)
