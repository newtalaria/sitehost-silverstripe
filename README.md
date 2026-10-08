# Silverstripe deploy on SiteHost

Deploys one Silverstripe site onto a SiteHost container. The site repository keeps a short workflow for the Actions form. This repository runs the deploy, the database and `public/assets` backups, and the restore.

Pin `@v1`.

## Set up a site

Do these in order. Secrets and variables for the whole organisation live under **Organisation → Settings → Secrets and variables → Actions**. A single site overrides them under **Repository → Settings → Secrets and variables → Actions**. Each container gets a GitHub environment under **Repository → Settings → Environments**.

Set each name once. Inside secrets, and inside variables, GitHub uses the environment value, then the repository value, then the organisation value. When the same name is both a secret and a variable, the secret is used. Override a secret with a secret, and a variable with a variable.

The container already has a git checkout and its own GitHub deploy key. Import the public half of `SITEHOST_SSH_PRIVATE_KEY` in SiteHost and attach it to each container SSH user. Database credentials stay on the container as `SS_DATABASE_SERVER`, `SS_DATABASE_PORT`, `SS_DATABASE_USERNAME`, `SS_DATABASE_PASSWORD`, and `SS_DATABASE_NAME`.

### 1. Organisation secrets

Shared by every site in the GitHub organisation. On each secret, set repository access to **All repositories**, or to **Selected repositories** and include this site. A secret that does not list the repository never reaches the deploy.

| Name | When | Value |
| --- | --- | --- |
| `SITEHOST_SSH_PRIVATE_KEY` | Every deploy | The Actions login private key, including the `BEGIN` and `END` lines. |
| `TALARIA_RELEASE_KEY` | Source maps | A Talaria key with `releases:write`. One key can serve every site. A site with its own key sets this secret on the repository or on the environment instead. |

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
```

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
| `remote_build_script` | `./.scripts/build.sh` | Relative path with no `..`. The container runs it with `bash` after checkout. |

## What the deploy does

Actions SSHes in with `SITEHOST_SSH_PRIVATE_KEY` and checks the host key with `SITEHOST_SSH_HOST_FINGERPRINT`.

1. Dump the database and copy `public/assets` on the container before changing files. Turn either input off to skip that copy.
2. Fetch the exact commit and check it out detached.
3. Run the site build script.
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
```
