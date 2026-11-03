# Silverstripe deploy on SiteHost

Deploys one Silverstripe site onto a SiteHost container. The same repository can back up that container, restore a snapshot, print container status, and tag a semver release. The site repository keeps a short workflow for each Actions form. This repository runs the work.

Pin `@v1`.

- **Backups use the SiteHost API only.** Each deploy asks SiteHost to back up the container first, and a failed deploy restores from that backup. The older local database dump and `public/assets` copy are still in the code, but they are disabled and no input turns them on. See [Backups](#backups).
- **Talaria is optional.** With no Talaria key, the deploy and backup still run, Talaria steps are skipped, and the run shows one warning. Set `TALARIA_API_KEY` to turn on releases, source maps, job check-ins, and the log collector. See [Talaria (optional)](#talaria-optional).

## Set up a site

Do these in order. Secrets and variables for the whole organisation live under **Organisation → Settings → Secrets and variables → Actions**. A single site overrides them under **Repository → Settings → Secrets and variables → Actions**. Each container gets a GitHub environment under **Repository → Settings → Environments**.

Set each name once. Inside secrets, and inside variables, GitHub uses the environment value, then the repository value, then the organisation value. When the same name is both a secret and a variable, the secret is used. Override a secret with a secret, and a variable with a variable.

The container already has a git checkout and its own GitHub deploy key. [Set up the SSH user](#set-up-the-ssh-user) covers creating the Actions login key, importing it in SiteHost, and storing the private half in GitHub. Database credentials stay on the container as `SS_DATABASE_SERVER`, `SS_DATABASE_PORT`, `SS_DATABASE_USERNAME`, `SS_DATABASE_PASSWORD`, and `SS_DATABASE_NAME`.

### 1. Organisation secrets

Shared by every site in the GitHub organisation. On each secret, set repository access to **All repositories**, or to **Selected repositories** and include this site. A secret that does not list the repository never reaches the deploy.

| Name | When | Value |
| --- | --- | --- |
| `SITEHOST_SSH_PRIVATE_KEY` | Every deploy | The Actions login private key, including the `BEGIN` and `END` lines. |
| `SITEHOST_API_KEY` | Every deploy, backup, and restore | The account API key from the SiteHost control panel. Leave the key's IP allowlist empty. A key with any address listed rejects a GitHub-hosted runner, because that address changes on every job. |
| `TALARIA_API_KEY` | Optional. Turns Talaria on | See [Talaria (optional)](#talaria-optional). |
| `TALARIA_RELEASE_KEY` | Optional. Source maps | See [Talaria (optional)](#talaria-optional). |
| `TALARIA_URL` | Optional | See [Talaria (optional)](#talaria-optional). |

### 2. Organisation variables

Shared by every container on one SiteHost server. Open the **Variables** tab on the same Actions settings page.

| Name | When | Example |
| --- | --- | --- |
| `SITEHOST_SSH_HOST` | Every deploy | `203.0.113.10` |
| `SITEHOST_SSH_HOST_FINGERPRINT` | Every deploy | `SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` |
| `SITEHOST_SSH_PORT` | The SSH port is not 22 | `22` |
| `SITEHOST_CLIENT_ID` | Every deploy, backup, and restore | `17` |
| `SITEHOST_SERVER` | Every deploy, backup, and restore | `ch-servername` |

`SITEHOST_SERVER` is the server name in the SiteHost API. It is not the SSH address.

### 3. Environment for each container

Create the environment before the first deploy and add reviewers on the ones that need them. The environment name is the string the workflow sends, such as `test` or `production`. The first run that names an environment GitHub has not seen creates that environment with no protection.

Open the environment and add these **variables**:

| Name | When | Example |
| --- | --- | --- |
| `SITEHOST_SSH_USER` | Every deploy | `exampletest` |
| `SITEHOST_CONTAINER` | Every deploy, backup, and restore | `test.example.com` |
| `SITEHOST_STACK` | Every deploy, backup, and restore | `cce6c3ce72078711` |
| `SITEHOST_SITE_URL` | Every deploy and restore | `https://test.example.com` |

`SITEHOST_CONTAINER` is the hostname shown in the SiteHost panel, such as `test.example.com`. `SITEHOST_STACK` is the id SiteHost uses for that stack and, on a one-container stack, for the container itself. [Find the stack id](#find-the-stack-id) below is the step for every container.

`SITEHOST_SITE_URL` must start with `http://` or `https://`.

These have defaults. Set them on the environment only when this container differs.

| Name | Default |
| --- | --- |
| `SITEHOST_APP_PATH` | `/container/application` |
| `SITEHOST_BACKUP_ROOT` | `/container/backups/containers` |

### 4. Repository overrides

Use the repository when one site differs from the organisation. Same names as above.

A repository secret overrides an organisation secret. A repository variable overrides an organisation variable. An environment value overrides both.

### Find the stack id

Do this once for each container, from a shell on that container. The id is the last part of the directory SiteHost mounts as `/container`.

1. SSH in as that container's SSH user.
2. Print the stack id:

```bash
awk '$5 == "/container" { n=$4; sub(".*/", "", n); print n }' /proc/self/mountinfo
```

The test container prints `cce6c3ce72078711`.

3. Open the GitHub environment for that container. The environment name is the string the workflow sends, such as `test` or `production`.
4. Add a variable named `SITEHOST_STACK` and paste the id from step 2.
5. Set `SITEHOST_CONTAINER` to the hostname for that same container, such as `test.example.com`. The API backup sends `SITEHOST_STACK` as both the stack and the container. The hostname is the panel label.

When `/container/backups/containers` already exists, its real path ends in the same id:

```bash
basename "$(readlink -f /container/backups/containers)"
```

Repeat from step 1 on the next container. The production container has a different id, so it gets its own `SITEHOST_STACK` on the production environment.

The account API can list the same ids. `GET /cloud/stack/list_all` with `client_id` and `filters[server_name]` set to `SITEHOST_SERVER` returns each stack. Match `containers[].name` to the hostname and use that stack's `name` as `SITEHOST_STACK`.

## Add the workflow

Save this as `.github/workflows/deploy.yml` in the site repository. Pass the keys by name. `secrets: inherit` only reaches a reusable workflow in the same organisation, and this workflow lives in `newtalaria`.

This is the smallest caller. It needs no Talaria. Each deploy takes a SiteHost API backup first and restores from it if the deploy fails.

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

permissions:
  contents: read

jobs:
  deploy:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/deploy.yml@v1
    with:
      environment: ${{ inputs.environment }}
      emergency_override: ${{ inputs.emergency_override }}
      require_main_or_tag: ${{ inputs.environment == 'production' }}
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
      SITEHOST_API_KEY: ${{ secrets.SITEHOST_API_KEY }}
```

The run shows one warning, `Talaria keys are not set, so the Talaria integration is skipped`, and the deploy carries on. To add Talaria, pass its keys as well. [Talaria (optional)](#talaria-optional) has the full caller.

More choices for the form:

```yaml
      cleanup_stale_branches:
        description: Cleanup stale branches
        type: boolean
        default: false
      container_snapshot:
        description: Back up this container through the SiteHost API first
        type: boolean
        default: true
      test_rollback:
        description: Test rollback
        type: boolean
        default: false
```

Pass each one under `with:` by the same name. Any other input is an error.

GitHub leaves a secret empty inside this workflow when the caller does not pass it in the `secrets:` map, and GitHub reports no error. A Talaria key that is set in GitHub but missing from that map reads as no key, so the run skips Talaria with the warning above.

Another container is another name in `options` and another GitHub environment with that same name. The shared workflow takes the string it is given. Put rules that depend on a name in the caller, as `require_main_or_tag` does above.

Deploy, backup, restore, and status share the group `sitehost-silverstripe-${{ github.repository }}-${{ inputs.environment }}`. Two sites can run at the same time. Two runs for one site and the same environment wait. Leave that group off the caller. GitHub cancels the run as a deadlock when the caller and the called workflow lock one group. The release workflow uses a separate group and does not SSH.

Run a deploy from the Actions tab with **Run workflow**. Pick the environment. The SiteHost API backup is on by default. Turning `container_snapshot` off skips the backup and the automatic rollback, and the run warns about it.

## Talaria (optional)

The deploy, backup, restore, and status workflows all run without Talaria. Talaria adds the release name in `.env`, source maps, job check-ins, and the container log collector.

### Keys

| Name | Kind | Value |
| --- | --- | --- |
| `TALARIA_API_KEY` | Secret | Turns Talaria on. A secret `tal_sk_<env>_<cell>_…` key with `monitors:write` and `logs:write`. The ingest host comes from the key's cell: `https://ingest-<cell>.newtalaria.com`, and the collector exports to that host plus `/otlp`. When the site contains `talaria/sitehost/monitors.json`, or `TALARIA_INSTALL_PROBE` is `true`, the deploy runs `vendor/bin/talaria-sitehost install` (talaria/silverstripe 3.0.1 or newer). That registers each job once, rewrites one crontab block, and starts the log collector. Cron lines check in with a `tal_mon_` monitor token, not this key. |
| `TALARIA_RELEASE_KEY` | Secret | Needed when `upload_source_maps` is on. A `tal_sk_` key with `releases:write`. One key can serve every site. |
| `TALARIA_URL` | Secret or variable | Ingest origin override for self-host or a custom domain. Leave it unset on Talaria Cloud. A `self` cell key needs it. It applies to the key check, the source map upload, and the collector. |
| `TALARIA_INSTALL_PROBE` | Variable | `true` runs the Talaria installer even without `monitors.json`. |

A secret is read first and a variable with the same name second. Variables are not masked by GitHub, so keep keys in secrets.

### What the run does with them

The first step of the deploy checks the Talaria settings, before any backup or file change.

| Settings | Result |
| --- | --- |
| None set | One warning: `Talaria keys are not set, so the Talaria integration is skipped. The backup and deploy continue.` The job summary says Talaria was skipped. The release in `.env`, source maps, check-ins, the collector, and the SiteHost environment update all skip. The backup and deploy run. |
| Some set, some missing | Fails and names the missing ones. `TALARIA_URL` or `TALARIA_RELEASE_KEY` without `TALARIA_API_KEY` is partial. So is `upload_source_maps` without `TALARIA_RELEASE_KEY`. |
| Malformed key | Fails. The key must be a `tal_sk_` key with a valid cell and checksum, the same check the SDK makes. |
| Key rejected | Fails. The check calls `GET /v1/sdk-config` on the ingest host with each key. HTTP 401 or 403 means the key is wrong, revoked, or for another cell. Any other 4xx points at `TALARIA_URL`. |
| Talaria unreachable | Warns and continues. A timeout, connection error, 408, 429, or 5xx is treated as an outage, not a wrong key. Talaria steps then run best effort: a failed source map upload or Talaria installer is a warning, not a failed deploy. |

Auth errors fail closed, because a wrong key is a configuration mistake that a rerun will not fix. Outages fail open, so Talaria downtime never blocks a deploy. `GET /v1/sdk-config` accepts any live key and writes nothing, so the check cannot confirm `releases:write` or `monitors:write`. A missing scope still fails at the step that needs it.

Keys are masked in the log with `::add-mask::` and sent to curl on stdin, never on its command line. Without Talaria, no Talaria key reaches the container.

### Caller with Talaria

```yaml
jobs:
  deploy:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/deploy.yml@v1
    with:
      environment: ${{ inputs.environment }}
      emergency_override: ${{ inputs.emergency_override }}
      require_main_or_tag: ${{ inputs.environment == 'production' }}
      upload_source_maps: true
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
      SITEHOST_API_KEY: ${{ secrets.SITEHOST_API_KEY }}
      TALARIA_API_KEY: ${{ secrets.TALARIA_API_KEY }}
      TALARIA_RELEASE_KEY: ${{ secrets.TALARIA_RELEASE_KEY }}
      TALARIA_URL: ${{ secrets.TALARIA_URL }}
```

Leave `upload_source_maps` off, and `TALARIA_RELEASE_KEY` out, for a site with no combined theme script.

## Back up a container

Save this as `.github/workflows/backup.yml` in the site repository. It takes a SiteHost API backup of one container and prints the snapshot id. It does not check out code or change the site. The id stays on the container.

```yaml
name: Back up SiteHost

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Container to back up
        type: choice
        required: true
        options:
          - test
          - production

permissions:
  contents: read

jobs:
  backup:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/backup.yml@v1
    with:
      environment: ${{ inputs.environment }}
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
      SITEHOST_API_KEY: ${{ secrets.SITEHOST_API_KEY }}
```

The run lists the snapshot directories, asks SiteHost to back up this container, and waits until the new directory is visible. The job summary and the output `snapshot_id` are that directory name, such as `2026-10-19_09:43:28`. Paste it into a restore. The scheduler job id is not a restore id.

## Restore a snapshot

This restores the container from a SiteHost API container backup: one the deploy took, one the backup workflow took, or SiteHost's nightly backup.

The SiteHost API can create a container backup ([`POST /cloud/stack/backup`](https://docs.sitehost.nz/api/v1.5/?action=POST&path=%2Fcloud%2Fstack%2Fbackup)), but API v1.5 has no endpoint that lists or restores one. SiteHost writes each backup to a dated directory under `/container/backups/containers`. So the restore copies from that directory over SSH. The control panel's Backups tab is the manual alternative.

Save this as `.github/workflows/restore.yml`. Leave `snapshot_id` empty to restore the newest dated snapshot, or paste a directory name from a backup run or from status. `confirm` must be the word `restore`. The database inside the snapshot stays unused unless `restore_database` is on.

```yaml
name: Restore SiteHost

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Container to restore
        type: choice
        required: true
        options:
          - test
          - production
      snapshot_id:
        description: Snapshot directory name. Leave empty for the newest.
        type: string
        required: false
      restore_database:
        description: Load the database stored in that snapshot
        type: boolean
        default: false
      confirm:
        description: Type restore to replace the application files
        type: string
        required: true

permissions:
  contents: read

jobs:
  restore:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/restore.yml@v1
    with:
      environment: ${{ inputs.environment }}
      snapshot_id: ${{ inputs.snapshot_id }}
      restore_database: ${{ inputs.restore_database }}
      confirm: ${{ inputs.confirm }}
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
      SITEHOST_API_KEY: ${{ secrets.SITEHOST_API_KEY }}
```

An empty id, or `newest`, picks the newest dated directory that has application files, before anything else runs. The run refuses `latest`, which is SiteHost's symlink, and any name with a slash. It checks that the directory is a real snapshot with application files, takes a new SiteHost API backup, and records that safety id in the summary. Then it copies `application/` from the chosen snapshot onto the site, which includes `public/assets`. Files that are not in the snapshot are removed. With `restore_database` on, it loads the database dump from that same snapshot. SiteHost names it `databases/mysql8-<SS_DATABASE_NAME>.sql.gz`, and a plain `<SS_DATABASE_NAME>.sql.gz` also works. It restarts php and requests `SITEHOST_SITE_URL`. The summary names the restored id and the safety id. Restore the safety id to undo the restore.

Restore needs no Talaria key.

A deploy that ran `dev/build` needs the database box ticked. Files alone leave the schema ahead of the code.

## Container status

Save this as `.github/workflows/status.yml`. The run SSHes in, prints the checked-out commit, whether that commit is `main` on the git remote, any semver tag that points at it, `TALARIA_RELEASE` from `.env` (`missing` on a site without Talaria), free space on `/container`, `supervisorctl status`, and the newest snapshot directory names. It skips `latest`. It does not change files. Copy a snapshot name from the log into the restore form.

```yaml
name: SiteHost status

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Container to read
        type: choice
        required: true
        options:
          - test
          - production

permissions:
  contents: read

jobs:
  status:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/status.yml@v1
    with:
      environment: ${{ inputs.environment }}
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
```

## Tag a release

Save this as `.github/workflows/release.yml`. Pick `patch`, `minor`, or `major`. The workflow reads the newest tag on the site repository.

| Latest tag | Choice | New tag |
| --- | --- | --- |
| `1.2.5` | `patch` | `1.2.6` |
| `1.2.5` | `minor` | `1.3.0` |
| `1.2.5` | `major` | `2.0.0` |
| `v1.2.5` | `patch` | `v1.2.6` |
| `v1`, `nightly`, or no tag | any | `1.0.0` |

A latest tag that is not `1.2.5` or `v1.2.5` starts at `1.0.0`. Older semver tags stay where they are and are not the base. The release notes are the commit subjects since the previous semver tag. A new `1.0.0` lists the last 30 subjects and names the tag that was ignored. The workflow creates the tag and a GitHub Release on `main`. It does not deploy, and it does not move this action's `v1` tag. Deploy the new tag by running the deploy workflow from that tag.

The caller needs `contents: write`. The reusable workflow refuses any branch other than `main`.

```yaml
name: Tag a release

on:
  workflow_dispatch:
    inputs:
      bump:
        description: Which part of the version to increase
        type: choice
        required: true
        default: patch
        options:
          - patch
          - minor
          - major

permissions:
  contents: write

jobs:
  release:
    uses: newtalaria/sitehost-silverstripe/.github/workflows/release.yml@v1
    with:
      bump: ${{ inputs.bump }}
```

## What each deploy can turn on

| Input | Default | Effect |
| --- | --- | --- |
| `environment` | required | GitHub environment for this container. Reviewers, secrets, variables, and deployment branches are the ones on that environment. |
| `container_snapshot` | `true` | SiteHost API backup of this container before any file changes. If the deploy, the smoke check, or the rollback test fails, the application files and the database come back from that backup. Off means no backup and no rollback. |
| `cleanup_stale_branches` | `false` | Delete local branches on the container after the detached checkout. |
| `test_rollback` | `false` | Finish the deploy, then fail so this run's SiteHost backup is restored. |
| `require_main_or_tag` | `false` | Fail unless the ref is `main` or a tag. |
| `emergency_override` | `false` | With `require_main_or_tag`, deploy a ref that is not `main` or a tag. |
| `upload_source_maps` | `false` | Talaria only. Build source maps, upload them, and copy the rewritten script onto the theme path after checkout. Skipped with the Talaria warning when no key is set. |

## What the deploy does

Actions SSHes in with `SITEHOST_SSH_PRIVATE_KEY` and checks the host key with `SITEHOST_SSH_HOST_FINGERPRINT`.

1. Check the Talaria settings. See [Talaria (optional)](#talaria-optional).
2. With Talaria on and `upload_source_maps` on, build and upload the source maps.
3. When `container_snapshot` is on, back up this container through the SiteHost API and record the new snapshot directory. The deploy does not continue until that backup finishes.
4. Fetch the exact commit and check it out detached.
5. Run `composer install` without dev dependencies, then `vendor/bin/sake dev/build flush=all`.
6. With Talaria on, write `TALARIA_RELEASE` and `TALARIA_COMMIT_SHA` to `.env`, then run the Talaria installer and collector when the site uses them.
7. `supervisorctl restart php`.
8. With Talaria on and `container_snapshot` on, write the two release values through the SiteHost environment API. SiteHost restarts the container to apply them.
9. With source maps, copy the rewritten script onto the theme path.
10. Request `SITEHOST_SITE_URL`. The job allows 30 minutes for the remote deploy and 90 minutes overall.
11. If step 4, 5, 6, 7, or 10 failed, or `test_rollback` is on, restore the application files and the database from the backup in step 3.

## Backups

The SiteHost API backup is the only backup this action takes. The deploy, backup, and restore workflows all use it.

### Local copies (disabled)

The local database dump (`mysqldump` into `/container/logs`) and the `public/assets` copy are disabled as of 3 November 2026. The code stays in `remote-deploy.sh` and `remote-restore.sh`, and the workflow steps stay in `deploy.yml`, behind a fixed `SITEHOST_LOCAL_BACKUPS=disabled`. No input or variable can turn them on. A container backup already holds the database dump and `public/assets`.

### Through the SiteHost API

The deploy (with `container_snapshot`, on by default), the backup workflow, and the restore workflow's safety copy all call [`POST /cloud/stack/backup`](https://docs.sitehost.nz/api/v1.5/?action=POST&path=%2Fcloud%2Fstack%2Fbackup) for this container. `SITEHOST_STACK` is sent as the stack `name` and as `containers[0]`, and as the `project` and `service` when the deploy writes the release values. The action stops when the stack id is missing, because an empty container list backs up every container on the stack. [Find the stack id](#find-the-stack-id) is how the id is collected. The hostname in `SITEHOST_CONTAINER` is the panel label and is not a container name in this API.

The API returns a scheduler job. That job id means the backup was accepted. It is not a restore id. The action polls [`/job/get`](https://docs.sitehost.nz/api/v1.5/?action=GET&path=%2Fjob%2Fget) until the job completes. SiteHost can report that job complete before the new directory shows up under `/container/backups/containers/`. The pin step checks again for up to three minutes. That path is often a symlink. The directory name is the id this action restores from, including the colons in names such as `2026-10-19_09:35:25`. The run lists the directories before the backup and keeps the single new one. A container with no backup yet has no directory there, so that list is empty and this backup is the first snapshot. It does not follow the `latest` symlink. The job summary records the id, and the workflow output `snapshot_id` is that same name. A second new directory in the same window, such as the nightly backup, stops the deploy before any file changes.

A container backup holds `application`, `config`, `crontabs`, and, on a web container, `databases/mysql8-<database>.sql.gz`. A failed deploy, smoke check, or rollback test restores `application` from the pinned directory, then loads that database dump from it. `config` stays as it is.

The SiteHost API v1.5 has no call that lists or restores a container backup. [`/cloud/stack`](https://docs.sitehost.nz/api/v1.5/?path=%2Fcloud%2Fstack) offers `backup`, plus `copy` and `overwrite`, which clone from another live stack, not from a backup. So restores read the backup directory on the container.

[`/server/snapshot`](https://docs.sitehost.nz/api/v1.5/?action=POST&path=%2Fserver%2Fsnapshot%2Frestore) is a disk snapshot of the whole server and has its own numeric id. Restoring it rolls the server back. This action does not call it.

On a managed server the control panel Backups tab can restore the same directory. That restore covers the website files. The database is the dump in `databases/`.

`talaria-sitehost install` can rewrite the container crontab during the deploy. The snapshot rollback returns the application files and the database. The crontab written during the deploy stays in place.

The API key is `SITEHOST_API_KEY`, with no IP address on the key. `SITEHOST_CLIENT_ID` and `SITEHOST_SERVER` are the account and the API server name. `SITEHOST_CONTAINER` and `SITEHOST_STACK` are set on the environment for that container.

## Source maps

Turn on `upload_source_maps` for a theme script that Silverstripe combines. The job runs `npm ci` and the source map command on Node 22, uploads with [`newtalaria/source-maps@v1`](https://github.com/newtalaria/source-maps), and copies the rewritten file to `themes/default/javascript` after checkout. `Requirements::combine_files` still builds `assets/_combinedfiles` from that file. The rewritten script is the first file in the combine, and `silverstripe_combine_files` defaults to true.

Source maps are a Talaria feature. They need `TALARIA_API_KEY` and `TALARIA_RELEASE_KEY` (see [Talaria (optional)](#talaria-optional)). With no Talaria key, `upload_source_maps` is skipped with the Talaria warning, and the theme keeps the script already on the container. The site needs a `package-lock.json` because the job runs `npm ci`.

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
      SITEHOST_API_KEY: ${{ secrets.SITEHOST_API_KEY }}
      TALARIA_API_KEY: ${{ secrets.TALARIA_API_KEY }}
      TALARIA_RELEASE_KEY: ${{ secrets.TALARIA_RELEASE_KEY }}
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

`git remote -v` should show this site's GitHub repository, and `git fetch origin` should finish without a password. That uses the deploy key already on the container. Each `command -v` line should print a path. A restore and a failed-deploy rollback need `rsync`, `gzip`, and `mysql`. `mysqldump` is only used by the disabled local backup.

A restore and a rollback load the database, so confirm the database settings Silverstripe already uses. The first command prints the server, user, and database name. The second checks the password without printing it.

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
