# Silverstripe deploy on SiteHost

Deploys one Silverstripe site onto a SiteHost container. The site repository keeps a short workflow for the Actions form. This repository runs the deploy, the database and `public/assets` backups, and the restore.

Pin `@v1`.

## Usage

Create GitHub environments for each container before the first deploy, and add reviewers on the ones that need them. The first run that names an environment GitHub has not seen creates that environment with no protection.

`secrets: inherit` passes the organisation and repository secrets. The caller permissions need `contents: read`.

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
        default: false
      backup_assets:
        description: Backup assets
        type: boolean
        default: false
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
    secrets: inherit
```

A site with another container adds that name to its own choice list and creates a GitHub environment with the same name. The shared workflow takes the string it is given. It does not treat `production` as special. Put rules that depend on a name in the caller, as `require_main_or_tag` does above.

The shared workflow queues deploys with group `sitehost-silverstripe-${{ github.repository }}-${{ inputs.environment }}`. Two sites can deploy at the same time. Two deploys of one site to the same environment wait. Do not set that same group on the caller. GitHub cancels the run as a deadlock when the caller and the called workflow lock one group.

## What each run can turn on

| Input | Default | Effect |
| --- | --- | --- |
| `environment` | required | GitHub environment for this container. Reviewers, secrets, variables, and deployment branches are the ones on that environment. |
| `backup_database` | `false` | `mysqldump` of the Silverstripe database before any file changes. Restore runs if deploy, the smoke check, or the rollback test fails. |
| `backup_assets` | `false` | Copy `public/assets` before any file changes. Restored on the same failures. |
| `cleanup_stale_branches` | `false` | Delete local branches on the container after the detached checkout. |
| `test_rollback` | `false` | Finish the deploy, then fail so the backups from this run are restored. |
| `require_main_or_tag` | `false` | Fail unless the ref is `main` or a tag. `emergency_override` deploys another ref. |
| `container_snapshot` | `false` | SiteHost API container backup, snapshot pin, and snapshot rollback. |
| `upload_source_maps` | `false` | Build source maps, upload them, and copy the rewritten script onto the theme path after checkout. |

## What the deploy does

The container already has a git checkout and its own GitHub deploy key. Actions SSHes in with `SITEHOST_SSH_PRIVATE_KEY` and checks the host key with `SITEHOST_SSH_HOST_FINGERPRINT`.

1. When a backup is on, dump the database and copy `public/assets` before changing files. The dump reads `SS_DATABASE_SERVER`, `SS_DATABASE_PORT`, `SS_DATABASE_USERNAME`, `SS_DATABASE_PASSWORD`, and `SS_DATABASE_NAME` from the container SSH session. Those values stay on the container.
2. Fetch the exact commit and check it out detached.
3. Run the site build script. The default is `./.scripts/build.sh`.
4. Write `TALARIA_RELEASE` and `TALARIA_COMMIT_SHA` to `.env`.
5. `supervisorctl restart php`.
6. Request the site URL. The job allows 30 minutes for the remote deploy and 90 minutes overall.

A failed deploy restores the database dump and assets copy that this run wrote. The checked-out code stays in place. A successful deploy deletes those copies.

`REMOTE_BUILD_SCRIPT` is a relative path with no `..`. The container runs it with `bash`.

## Source maps

Turn on `upload_source_maps` for a theme script that Silverstripe combines. The job runs `npm ci` and `npm run build:sourcemap` on Node 22, uploads with [`newtalaria/source-maps@v1`](https://github.com/newtalaria/source-maps), and copies the rewritten file to `themes/default/javascript` after checkout. `Requirements::combine_files` still builds `assets/_combinedfiles` from that file. The rewritten script is the first file in the combine, and `silverstripe_combine_files` defaults to true.

`TALARIA_RELEASE_KEY` is a Talaria key with `releases:write`. The deploy job selects the GitHub environment before it builds or uploads maps, so the key can live on that environment, the repository, or the organisation.

| Input | Default |
| --- | --- |
| `node_version` | `22` |
| `source_map_command` | `npm run build:sourcemap` |
| `source_map_directory` | `source-maps` |
| `rewritten_script` | `source-maps/scripts.js` |
| `remote_script_dir` | `themes/default/javascript` |
| `silverstripe_combine_files` | `true` |

The site needs a `package-lock.json` because the job runs `npm ci`.

## Secrets and variables

Organisation secrets:

- `SITEHOST_SSH_PRIVATE_KEY` — one Actions login key. Import the public half in SiteHost and attach it to each container SSH user.
- `SITEHOST_API_KEY` — used only when `container_snapshot` is true. Give it the cloud container and job modules. Leave Allowed IP Addresses empty. A GitHub-hosted runner changes address every job, and SiteHost rejects a key that does not list that address. Leave `container_snapshot` false until that works.
- `TALARIA_RELEASE_KEY` — when the site uploads source maps. An environment secret with this name is used for that container. A repository or organisation secret is used when the environment does not set one.

Organisation variables: `SITEHOST_CLIENT_ID`, `SITEHOST_SERVER`, `SITEHOST_SSH_HOST`, `SITEHOST_SSH_PORT`, `SITEHOST_SSH_HOST_FINGERPRINT`.

The SSH host, port, and fingerprint are the same for every container on one server. An environment value with the same name overrides the organisation value.

Environment variables, one GitHub environment per container: `SITEHOST_SSH_USER`, `SITEHOST_STACK`, `SITEHOST_SITE_URL`.

`SITEHOST_APP_PATH` defaults to `/container/application`. `SITEHOST_BACKUP_ROOT` defaults to `/container/backups/containers`. `SITEHOST_SERVICE` defaults to `SITEHOST_STACK`. Set `SITEHOST_CONTAINER` only when the stack has more than one container.

`SITEHOST_SITE_URL` must start with `http://` or `https://`.

## Container snapshots

`container_snapshot` runs the SiteHost API backup, pins the new snapshot directory, and can roll the application files back from that pin. It also sets `TALARIA_RELEASE` through the API, which restarts the container. The `.env` write and `supervisorctl restart php` still run. Leave the input false while the API key rejects GitHub-hosted runner addresses.

The snapshot scripts record directory names and pin the one new directory. They do not follow a `latest` link.
