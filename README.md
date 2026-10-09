# Silverstripe deploy on SiteHost

Deploys one Silverstripe site onto a SiteHost container. The site repository keeps a short workflow for the Actions form. This repository runs the deploy, the database and `public/assets` backups, and the restore.

Pin `@v1`.

## Set up a site

Do these in order. Secrets and variables for the whole organisation live under **Organisation → Settings → Secrets and variables → Actions**. A single site overrides them under **Repository → Settings → Secrets and variables → Actions**. Each container gets a GitHub environment under **Repository → Settings → Environments**.

Set each name once. Inside secrets, and inside variables, GitHub uses the environment value, then the repository value, then the organisation value. When the same name is both a secret and a variable, the secret is used. Override a secret with a secret, and a variable with a variable.

The container already has a git checkout and its own GitHub deploy key. [Set up the SSH user](#set-up-the-ssh-user) covers creating the Actions login key, importing it in SiteHost, and storing the private half in GitHub. Database credentials stay on the container as `SS_DATABASE_SERVER`, `SS_DATABASE_PORT`, `SS_DATABASE_USERNAME`, `SS_DATABASE_PASSWORD`, and `SS_DATABASE_NAME`.

### 1. Organisation secrets

Shared by every site in the GitHub organisation. On each secret, set repository access to **All repositories**, or to **Selected repositories** and include this site. A secret that does not list the repository never reaches the deploy.

| Name | When | Value |
| --- | --- | --- |
| `SITEHOST_SSH_PRIVATE_KEY` | Every deploy | The Actions login private key, including the `BEGIN` and `END` lines. |
| `TALARIA_RELEASE_KEY` | Source maps | A Talaria key with `releases:write`. One key can serve every site. A site with its own key sets this secret on the repository or on the environment instead. |
| `TALARIA_DSN` | Job check-ins | API origin, for example `https://api.newtalaria.com`. Used only when the site contains `talaria/sitehost/monitors.json`. |
| `TALARIA_API_KEY` | Job check-ins | A project key with `monitors:write`. The deploy registers each job once and writes a ping token into the crontab. The token is not this key. |

### 2. Organisation variables

Shared by every container on one SiteHost server. Open the **Variables** tab on the same Actions settings page.

| Name | When | Example |
| --- | --- | --- |
| `SITEHOST_SSH_HOST` | Every deploy | `203.0.113.10` |
| `SITEHOST_SSH_HOST_FINGERPRINT` | Every deploy | `SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` |
| `SITEHOST_SSH_PORT` | The SSH port is not 22 | `22` |

### 3. Environment for each container

Create the environment before the first deploy and add reviewers on the ones that need them. The environment name is the string the workflow sends, such as `test` or `production`. The first run that names an environment GitHub has not seen creates that environment with no protection.

Open the environment and add these **variables**:

| Name | When | Example |
| --- | --- | --- |
| `SITEHOST_SSH_USER` | Every deploy | `exampletest` |
| `SITEHOST_STACK` | Every deploy | `test.example.com` |
| `SITEHOST_SITE_URL` | Every deploy | `https://test.example.com` |

`SITEHOST_SITE_URL` must start with `http://` or `https://`.

These have defaults. Set them on the environment only when this container differs.

| Name | Default |
| --- | --- |
| `SITEHOST_APP_PATH` | `/container/application` |

### 4. Repository overrides

Use the repository when one site differs from the organisation. Same names as above.

A repository secret overrides an organisation secret. A repository variable overrides an organisation variable. An environment value overrides both.

## Add the workflow

Save this as `.github/workflows/deploy.yml` in the site repository. Pass the keys by name. `secrets: inherit` only reaches a reusable workflow in the same organisation, and this workflow lives in `newtalaria`.

```yaml
name: Deploy to SiteHost

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Container to deploy
        type: choice
        required: true
        options:
          - test
          - production
      emergency_override:
        description: Production only. Deploy a ref that is not main or a tag.
        type: boolean
        default: false
      cleanup_stale_branches:
        description: Cleanup stale branches
        type: boolean
        default: false
      backup_database:
        description: Backup database
        type: boolean
        default: true
      backup_assets:
        description: Backup assets
        type: boolean
        default: true
      test_rollback:
        description: Test rollback
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  deploy:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/deploy.yml@v1
    with:
      environment: ${{ inputs.environment }}
      emergency_override: ${{ inputs.emergency_override }}
      cleanup_stale_branches: ${{ inputs.cleanup_stale_branches }}
      backup_database: ${{ inputs.backup_database }}
      backup_assets: ${{ inputs.backup_assets }}
      test_rollback: ${{ inputs.test_rollback }}
      require_main_or_tag: ${{ inputs.environment == 'production' }}
      upload_source_maps: true
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
      TALARIA_RELEASE_KEY: ${{ secrets.TALARIA_RELEASE_KEY }}
      TALARIA_DSN: ${{ secrets.TALARIA_DSN }}
      TALARIA_API_KEY: ${{ secrets.TALARIA_API_KEY }}
```

Pass `TALARIA_DSN` and `TALARIA_API_KEY` in that map. GitHub leaves an environment secret empty inside this workflow when the caller does not pass it, and the run does not report an error.

Another container is another name in `options` and another GitHub environment with that same name. The shared workflow takes the string it is given. Put rules that depend on a name in the caller, as `require_main_or_tag` does above.

The shared workflow queues deploys with group `sitehost-silverstripe-${{ github.repository }}-${{ inputs.environment }}`. Two sites can deploy at the same time. Two deploys of one site to the same environment wait. Leave that group off the caller. GitHub cancels the run as a deadlock when the caller and the called workflow lock one group.

Run it from the Actions tab with **Run workflow**. Pick the environment. Database and asset backups are already on.

## What each run can turn on

| Input | Default | Effect |
| --- | --- | --- |
| `environment` | required | GitHub environment for this container. Reviewers, secrets, variables, and deployment branches are the ones on that environment. |
| `backup_database` | `true` | `mysqldump` of the Silverstripe database on the container before any file changes. Restore runs if deploy, the smoke check, or the rollback test fails. |
| `backup_assets` | `true` | Copy `public/assets` on the container before any file changes. Restored on the same failures. |
| `cleanup_stale_branches` | `false` | Delete local branches on the container after the detached checkout. |
| `test_rollback` | `false` | Finish the deploy, then fail so the backups from this run are restored. |
| `require_main_or_tag` | `false` | Fail unless the ref is `main` or a tag. `emergency_override` deploys another ref. |
| `upload_source_maps` | `false` | Build source maps, upload them, and copy the rewritten script onto the theme path after checkout. |

## What the deploy does

Actions SSHes in with `SITEHOST_SSH_PRIVATE_KEY` and checks the host key with `SITEHOST_SSH_HOST_FINGERPRINT`.

1. Dump the database and copy `public/assets` on the container before changing files. Turn either input off to skip that copy.
2. Fetch the exact commit and check it out detached.
3. Run `composer install` without dev dependencies, then `vendor/bin/sake dev/build flush=all`.
4. Write `TALARIA_RELEASE` and `TALARIA_COMMIT_SHA` to `.env`.
5. `supervisorctl restart php`.
6. Request `SITEHOST_SITE_URL`. The job allows 30 minutes for the remote deploy and 90 minutes overall.

The dump is `mysqldump` of the Silverstripe database, gzipped, and the assets copy is `rsync` of `public/assets`. Both are written on the container, under `/container/logs`, before git fetch. A failed deploy, smoke check, or rollback test restores the copies this run wrote. The checked-out code stays in place. A successful deploy deletes those copies.

The SiteHost API can snapshot a container, and `container_snapshot` stays off. The API key only accepts listed hosts, and a GitHub-hosted runner uses a new address on every job.

## Source maps

Turn on `upload_source_maps` for a theme script that Silverstripe combines. The job runs `npm ci` and the source map command on Node 22, uploads with [`newtalaria/source-maps@v1`](https://github.com/newtalaria/source-maps), and copies the rewritten file to `themes/default/javascript` after checkout. `Requirements::combine_files` still builds `assets/_combinedfiles` from that file. The rewritten script is the first file in the combine, and `silverstripe_combine_files` defaults to true.

The site needs a `package-lock.json` because the job runs `npm ci`. Set `TALARIA_RELEASE_KEY` as in the organisation secrets table. A variable with that name is used only when no secret is set.

| Input | Default |
| --- | --- |
| `node_version` | `22` |
| `source_map_command` | `npm run build:sourcemap` |
| `source_map_directory` | `source-maps` |
| `rewritten_script` | `source-maps/scripts.js` |
| `remote_script_dir` | `themes/default/javascript` |
| `silverstripe_combine_files` | `true` |

Pass them on the same job:

```yaml
jobs:
  deploy:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/deploy.yml@v1
    with:
      environment: ${{ inputs.environment }}
      emergency_override: ${{ inputs.emergency_override }}
      cleanup_stale_branches: ${{ inputs.cleanup_stale_branches }}
      backup_database: ${{ inputs.backup_database }}
      backup_assets: ${{ inputs.backup_assets }}
      test_rollback: ${{ inputs.test_rollback }}
      require_main_or_tag: ${{ inputs.environment == 'production' }}
      upload_source_maps: true
      node_version: "22"
      source_map_command: npm run build:sourcemap
      source_map_directory: source-maps
      rewritten_script: source-maps/scripts.js
      remote_script_dir: themes/default/javascript
      silverstripe_combine_files: true
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
      TALARIA_RELEASE_KEY: ${{ secrets.TALARIA_RELEASE_KEY }}
      TALARIA_DSN: ${{ secrets.TALARIA_DSN }}
      TALARIA_API_KEY: ${{ secrets.TALARIA_API_KEY }}
```

## Set up the SSH user

Actions logs in as a container SSH user. Create one login key, put the public half on that user in SiteHost, and store the private half as the organisation secret `SITEHOST_SSH_PRIVATE_KEY`.

| Key | Public half | Private half | Used for |
| --- | --- | --- | --- |
| Actions login key | SiteHost, on every container SSH user | Organisation secret `SITEHOST_SSH_PRIVATE_KEY` | Actions logs into the container |
| Server host key | Already on the SiteHost server | Organisation variable `SITEHOST_SSH_HOST_FINGERPRINT` | Actions checks it reached your server |
| GitHub deploy key | Already on the site repository | Already on the container | The container runs `git fetch` |

Create the Actions login key once and attach it to every container. Leave the deploy key already on the container in place.

### Create the login key

```bash
ssh-keygen -t ed25519 -f "$HOME/.ssh/sitehost-actions" -C "github-actions-sitehost"
```

Press Enter at both passphrase prompts. GitHub Actions cannot type a passphrase.

```bash
ls -l "$HOME/.ssh/sitehost-actions" "$HOME/.ssh/sitehost-actions.pub"
```

You should see `sitehost-actions` (private) and `sitehost-actions.pub` (public).

### Add the public key in SiteHost

```bash
cat "$HOME/.ssh/sitehost-actions.pub"
```

Copy that line. It starts with `ssh-ed25519`.

In the [SiteHost control panel](https://cp.sitehost.nz):

1. Open **SSH Keys**.
2. Click **Add SSH Key**.
3. Paste the public key.
4. Save.

SiteHost copies that key onto any Cloud Container SSH user that selects it. See [SSH Key Syncing & Imported Keys](https://kb.sitehost.nz/cloud-containers/ssh-sftp-users/imported-keys).

### Add the private key in GitHub

```bash
cat "$HOME/.ssh/sitehost-actions"
```

Copy the whole block, from `-----BEGIN OPENSSH PRIVATE KEY-----` through `-----END OPENSSH PRIVATE KEY-----`.

1. Open the GitHub organisation, then **Settings**, then **Secrets and variables**, then **Actions**.
2. Open **Secrets** and click **New organization secret**.
3. Name: `SITEHOST_SSH_PRIVATE_KEY`.
4. Paste the private key into **Secret**.
5. Under **Repository access**, choose **Selected repositories** and add each site repository that will deploy.
6. Click **Add secret**.

GitHub lists the name and never shows the value again. You need permission to manage organisation secrets. Leave the local files until the login check below succeeds.

### Attach the key to each container

Do this for every container the workflow deploys, such as test and production. See [Managing SSH / SFTP Users](https://kb.sitehost.nz/cloud-containers/ssh-sftp-users/managing-users).

1. Open **Containers**, then **SSH & SFTP**.
2. Edit the existing SSH user and select the `github-actions-sitehost` key. If there is no user, click **Add User**, choose a username and password, tick the Actions key, select this server and this container, leave the config directory writable, and click **Add User**. Actions does not use the password.
3. Wait until the progress indicator beside the user disappears.
4. Open the user and note the username. That is `SITEHOST_SSH_USER` for this container's GitHub environment. The SSH host and port are the same for every container on this server. Note them once, as `SITEHOST_SSH_HOST` and `SITEHOST_SSH_PORT`.

### Read the server host fingerprint

A laptop that has already connected trusts the server through `~/.ssh/known_hosts`. A GitHub-hosted runner does not, so store the fingerprint once as `SITEHOST_SSH_HOST_FINGERPRINT`.

Replace the address with `SITEHOST_SSH_HOST`:

```bash
ssh-keygen -F 203.0.113.10 | grep -v '^#' | ssh-keygen -lf -
```

The server keeps a host key for each algorithm, so this prints about three lines:

```text
256 SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa= 203.0.113.10 (ECDSA)
256 SHA256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb= 203.0.113.10 (ED25519)
3072 SHA256:ccccccccccccccccccccccccccccccccccccccccccc= 203.0.113.10 (RSA)
```

From the line that ends in `(ECDSA)`, copy only the `SHA256:` field:

```text
SITEHOST_SSH_HOST_FINGERPRINT=SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
```

The deploy client asks for the ECDSA key first. An ED25519 or RSA fingerprint fails that check. If the command prints nothing, connect with `ssh` once, accept the host key, and run it again. If there is no `(ECDSA)` line, use the `(RSA)` line.

Store `SITEHOST_SSH_HOST`, `SITEHOST_SSH_PORT`, and `SITEHOST_SSH_HOST_FINGERPRINT` as organisation variables. Store `SITEHOST_SSH_USER` on the environment for that container.

### Check the login

Do this for each container before you delete the private key. Replace the username and host.

```bash
ssh -i "$HOME/.ssh/sitehost-actions" -p 22 exampletest@203.0.113.10
```

Type `yes` if it asks you to confirm the host key. A password prompt means the public key is not attached yet. A shell prompt means the login works.

From that shell:

```bash
ls -la /container/application
ls -la /container/backups/containers
cd /container/application
git remote -v
git fetch origin
command -v git composer php rsync gzip mysqldump mysql
```

`/container/application` should contain `public` and `.git`. `/container/backups/containers` should contain dated snapshot directories. Those paths are the defaults, so leave them out of GitHub unless this container uses different ones. If either listing fails, the SSH user is linked to more than this container. Use the directory under `$HOME/containers` that contains `.git`, and set `SITEHOST_APP_PATH` and `SITEHOST_BACKUP_ROOT` on that environment.

`git remote -v` should show this site's GitHub repository, and `git fetch origin` should finish without a password. That uses the deploy key already on the container. Each `command -v` line should print a path. A missing `mysqldump` or `mysql` blocks a run with **Backup database** on. A missing `rsync` blocks a run with **Backup assets** on.

When database backup will be on, confirm the database settings Silverstripe already uses. The first command prints the server, user, and database name. The second checks the password without printing it.

```bash
printenv SS_DATABASE_SERVER SS_DATABASE_USERNAME SS_DATABASE_NAME
if [ -n "$SS_DATABASE_PASSWORD" ]; then echo "SS_DATABASE_PASSWORD is set"; else echo "SS_DATABASE_PASSWORD is missing"; fi
```

`SS_DATABASE_SERVER`, `SS_DATABASE_USERNAME`, `SS_DATABASE_NAME`, and `SS_DATABASE_PASSWORD` must all be set. If one is missing, add it on the container's environment screen in SiteHost, open a new SSH session, and check again.

```bash
exit
```

Delete the local key files after every container login succeeds:

```bash
rm "$HOME/.ssh/sitehost-actions" "$HOME/.ssh/sitehost-actions.pub"
```
