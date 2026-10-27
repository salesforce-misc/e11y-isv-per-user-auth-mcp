# GitHub MCP Server with Per-User OAuth

> [!IMPORTANT]
> This repo is a reference that demonstrates a working installation. It isn't a
> solution to promote into production. For that reason, the published package
> versions are left in a beta state.

Reference code for ISV partners who package MCP servers for Agentforce. It
connects Agentforce to
[GitHub's remote MCP server](https://github.com/github/github-mcp-server) as a
managed 2GP package, and it serves two purposes:

1. **An example of an MCP server with per-user authentication.** Each
   Salesforce user signs in to GitHub with their own account, so an Employee
   agent acts with that user's GitHub access, not a shared service account. The
   package shows which metadata that takes and how the pieces reference each
   other.
2. **An example of a post-install setup experience.** A post-install script and
   a guided setup page take the subscriber admin from install to a working
   connection. Without them, the admin assigns permission sets by hand, finds
   the identity provider to copy its callback URL, edits it to enter the OAuth
   App credentials, and finds where to authenticate. Those steps are spread
   across several Setup pages. The page shows what's done and what's next, so
   you can guide your own subscribers through far fewer clicks.

Take the parts that fit your package and expect to harden them for your own
security review, error handling, and support needs.

There are two ways to use it:

- **Try it as a package.** Install the beta version below in a scratch org and
  walk through the setup page as a subscriber would. As a beta package, it
  can't be installed in Developer Edition or production orgs.
- **Adapt it.** Clone the source, swap in your own namespace, and build it from
  your own Dev Hub as a starting point for your own package.

## What's in the package

The per-user MCP connection:

| Component                       | Name              | Purpose                                                                                                                                      |
| ------------------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| External Auth Identity Provider | `GitHubAuth`      | GitHub's OAuth endpoints. Sends `Accept: application/json` on token and refresh requests, because GitHub returns form-encoded data otherwise |
| External Credential             | `GitHub`          | OAuth with a **Per-User Principal** (`PerUserAccountAccess`) and the `repo, read:user` scopes                                                |
| Named Credential                | `GitHub`          | Points at `https://api.githubcopilot.com/mcp/readonly`                                                                                       |
| External Service Registration   | `GitHub`          | Registers the MCP server in Agentforce Registry, with 28 read-only tools                                                                     |
| Permission set                  | `GitHub_Perm_Set` | Access to the Per-User Principal, plus Read, Edit, and Delete on `UserExternalCredential`. Assign it to every user of the agent              |

The post-install setup experience:

| Component                    | Name                                                     | Purpose                                                                                               |
| ---------------------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Apex post-install script     | `GitHubMcpPostInstall`                                   | Assigns the permission sets at install time and repairs permissions that the install drops            |
| Permission set               | `GitHub_MCP_Setup`                                       | Access to the GitHub MCP Setup page. Assigned to the installing admin                                 |
| Lightning page, tab, and LWC | `GitHub_MCP_Setup`, `githubMcpSetup`                     | The guided setup page. Checks each step and links to the next                                         |
| Apex                         | `GitHubMcpSetupController`, `GitHubMcpCredentialService` | Back the setup page. Save the OAuth App credentials and start the admin's sign-in through Connect API |

The package never contains GitHub credentials. Each subscriber creates their own
GitHub OAuth App and enters its client ID and secret on the setup page after
install.

## Try it as a package

The current version is a **beta**: `GitHubReadOnlyMCP@0.1.0-12`
(`04tHs000000iTDnIAM`). Beta versions install only in scratch orgs and
sandboxes, and they can't be upgraded in place. Uninstall the previous version
before installing a newer one.

### 1. Create a scratch org with Agentforce

Create the org from your own project or from this repo's
[scratch org definition](config/project-scratch-def.json), which turns on the
features Agentforce needs.

Include `--no-namespace`. Without it, a scratch org created from a project
takes that project's namespace. From this repo, that's `mvpbo3`, so creation
fails unless your Dev Hub is linked to `mvpbo3`. From your own project, the org
gets your namespace, and a package can't install in an org with the same
namespace, which matters once you install your own build.

```sh
sf org create scratch --definition-file config/project-scratch-def.json \
  --no-namespace --alias ghmcp-try --duration-days 30 \
  --target-dev-hub <your-dev-hub>
```

### 2. Install the package

```sh
sf package install --package 04tHs000000iTDnIAM --target-org ghmcp-try \
  --wait 20 --no-prompt
```

You can also open
`/packaging/installPackage.apexp?p0=04tHs000000iTDnIAM` in the scratch org
and install for admins only.

The post-install script assigns both permission sets to you, the installer. It
also assigns `GitHub_Perm_Set` to the Platform Integration User.

### 3. Run the setup page

From the App Launcher, open **GitHub MCP Setup**. The page checks each step and
points at the next one:

1. **Permissions.** Confirms you have access to the Per-User Principal and to
   `UserExternalCredential`.
2. **Create a GitHub OAuth App.** Copy the callback URL from the page, then
   [register a new OAuth app](https://github.com/settings/applications/new) in
   GitHub with that URL.
3. **Client credentials.** Paste the OAuth App's client ID and secret. The page
   saves them to the packaged identity provider and never shows the secret
   again.
4. **Connect your GitHub account.** Signs you in to GitHub through the
   Per-User Principal. Agentforce Registry can list the server's tools only
   while an authenticated user makes the call, so do this before step 5.
5. **Next steps.** Open Agentforce Registry, select the **GitHub** MCP server,
   and refresh its tools. Then assign `GitHub_Perm_Set` to each agent user and
   add the tools to an **Employee** agent.

Use an Employee agent, not a Service agent. Per-user authentication needs a
known, signed-in Salesforce user.

To check that it works, ask the agent "Who am I on GitHub?" in Agent Studio
preview. The reply should include your GitHub login.

## Adapt it for your own package

The package uses the namespace `mvpbo3`, which belongs to the author's Dev Hub.
To build your own version, you need:

- A Dev Hub with your own namespace linked to it. See
  [Link a Namespace to a Dev Hub Org](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_reg_namespace.htm).
- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli).
- Node.js, if you want to run the LWC tests and the pre-commit hooks.

Scratch orgs created from a project with a `namespace` value get that
namespace, so you develop and test with the same API names your subscribers
will see.

### 1. Swap the namespace

The namespace is hard-coded in a few places, because metadata references
between packaged components and Connect API calls need the full API name:

| File                                                                                              | What to change                                                                                   |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `sfdx-project.json`                                                                               | `namespace`                                                                                      |
| `force-app/main/default/classes/GitHubMcpCredentialService.cls`                                   | `PACKAGE_NAMESPACE`. The setup page and the post-install script both read it                     |
| `force-app/main/default/externalServiceRegistrations/GitHub.externalServiceRegistration-meta.xml` | `<namedCredential>mvpbo3__GitHub</namedCredential>`                                              |
| `force-app/main/default/permissionsets/GitHub_Perm_Set.permissionset-meta.xml`                    | `<externalCredentialPrincipal>mvpbo3__GitHub-PerUserAccountAccess</externalCredentialPrincipal>` |
| `scripts/teardown-permission-sets.apex`                                                           | `PACKAGE_NAMESPACE`                                                                              |

To replace all of them at once (substitute your namespace for `yourns`):

```sh
git grep -l mvpbo3 | xargs perl -pi -e 's/mvpbo3/yourns/g'
git grep -n mvpbo3   # should print nothing
```

### 2. Remove the author's package IDs

In `sfdx-project.json`, delete every entry under `packageAliases`. Those IDs
belong to the author's Dev Hub. Keep the `force-app` entry under
`packageDirectories`; `sf package create` adds your own aliases in step 4.

### 3. Deploy and test in a namespaced scratch org

```sh
sf org create scratch --definition-file config/project-scratch-def.json \
  --alias ghmcp-dev --duration-days 7 --target-dev-hub <your-dev-hub>
sf project deploy start --target-org ghmcp-dev
sf apex run test --target-org ghmcp-dev --code-coverage \
  --result-format human --wait 10
npm install && npm run test:unit
```

In a source-deployed org the post-install script doesn't run, so assign the
permission sets yourself before you open the setup page:

```sh
sf org assign permset --name GitHub_Perm_Set --name GitHub_MCP_Setup \
  --target-org ghmcp-dev
```

### 4. Create the package and a beta version

```sh
sf package create --name GitHubReadOnlyMCP --package-type Managed \
  --path force-app --target-dev-hub <your-dev-hub>
sf package version create --package GitHubReadOnlyMCP \
  --installation-key-bypass --code-coverage --wait 60 \
  --target-dev-hub <your-dev-hub>
```

Install the new `04t` version in a **separate** scratch org, as in
[Try it as a package](#try-it-as-a-package). Only a real install runs the
post-install script and shows how the package behaves for a subscriber.

## Things to know

- **One GitHub OAuth App per org.** A GitHub OAuth App allows only one callback
  URL, and every org has its own. Each scratch org, sandbox, and subscriber org
  needs its own OAuth App.
- **Install can drop the `UserExternalCredential` grants.** Installing the
  package can remove the object permissions from `GitHub_Perm_Set`. The
  post-install script checks for that and, when they're missing, creates and
  assigns a fallback permission set, `GitHub_MCP_UEC_Access`, to the same
  users.
- **The post-install script runs in system mode on purpose.** From API version
  68.0, Apex database operations default to user mode. The post-install script
  runs as the package's own user, which has almost no permissions, so in user
  mode it can't even query `PermissionSet`. Every query and DML statement in
  `GitHubMcpPostInstall` uses `WITH SYSTEM_MODE` or `AccessLevel.SYSTEM_MODE`.
  If you add any, do the same. See the
  [release note](https://help.salesforce.com/s/articleView?id=release-notes.rn_apex_default_user_mode.htm&release=262&type=5).
- **The post-install script never fails the install.** Each step catches its
  own errors and emails them to the installer. A thrown exception would roll
  back the install, and the subscriber would see only "The post install script
  failed."
- **The setup page links to the Registry home page, not to the server.** The
  server's Registry page needs the External Service Registration's record ID,
  and only the Tooling API returns it.
- **GitHub OAuth App tokens don't expire.** A user loses access only when they
  revoke the app in their GitHub settings, or disconnect on the setup page.
- **Organization restrictions apply.** If a GitHub organization restricts OAuth
  App access, tool calls that touch that organization's data fail until an
  organization owner approves the app.

To reset an org between installs, run
[scripts/teardown-permission-sets.apex](scripts/teardown-permission-sets.apex)
with `sf apex run --file`. It removes the package's permission set assignments
and deletes the fallback permission set. It runs as a dry run, with every
change rolled back, until you set `DRY_RUN = false`.

## Project layout

| Path                              | Contents                                         |
| --------------------------------- | ------------------------------------------------ |
| `force-app/main/default/`         | Package source                                   |
| `config/project-scratch-def.json` | Scratch org definition with Agentforce turned on |
| `scripts/`                        | Anonymous Apex for test orgs                     |
