# Teleport SSO with Microsoft Entra ID in GCC High

Sign Teleport users in with Microsoft Entra ID from a tenant in Microsoft's US
Government cloud (GCC High), map Entra groups to Teleport roles, and pass Entra
claims through to Teleport as traits. The whole setup is one enterprise application
in Entra and one SAML connector in Teleport.

GCC High runs on its own endpoints: sign-in at `login.microsoftonline.us` and the
portal at `portal.azure.us`, not the `.com` hosts of the global cloud. Teleport's
guided Entra ID integration and its directory sync are built for the global
endpoints. The SAML connector in this repository is not: Teleport reads Entra's
signing certificate from the `.us` metadata document you give it, and the user's
groups and attributes arrive inside the signed assertion, so nothing is fetched
from the Microsoft Graph API during sign-in.

Written against Teleport 18.11.3 (Enterprise, self-hosted).

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
4. (Optional) Add a claim named `username` with no namespace so roles can use the
   account name as a login. Set the source to **Transformation**, transformation
   `Extract()`, attribute `user.userprincipalname`, value `@`, then add a second
   transformation `ToLowercase()`. The connector exposes it as
   `{{external.username}}`; `role.example.yaml` shows it in use.
5. **Users and groups** → **Add user/group** and assign every group you mapped in
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
| `No roles mapped from claims. The mappings may contain typos.` | No group in the assertion matched an `attributes_to_roles` value. | Check the group object IDs in `connector.yaml`, and that the group is assigned to the application (step 3.5). `tctl sso test` prints the groups received. |
| `SAML: not in expected audience.` | The Entity ID in Entra differs from the connector's `audience`. | Make Entity ID, Reply URL, `acs`, `audience` and `service_provider_issuer` the identical string. |
| `received response with incorrect or missing attribute statements` | The assertion carries no claims. | Add the group claim (step 3.3) and confirm the user is assigned to the application. |
| `Your account is a member of more than 150 Entra ID groups.` | The group claim emits all groups and the user exceeds Entra's limit. | Switch the group claim to **Groups assigned to the application** and keep `entra_id_groups_provider.disabled: true`. |
| The Teleport username is an opaque string instead of the user principal name. | The Name ID format is not **Default**. | Set it to **Default** with source `user.userprincipalname` (step 3.2). |

## References

- Teleport: [Authentication with Microsoft Entra ID (SAML)](https://goteleport.com/docs/zero-trust-access/sso/integrate-idp/entra-id/)
- Microsoft: [National cloud deployments for Microsoft Graph and Entra sign-in endpoints](https://learn.microsoft.com/en-us/graph/deployments)
- Microsoft: [Connect to Azure Government using the portal](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-get-started-connect-with-portal)
- Microsoft: [Configure group claims for applications](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-group-claims)
