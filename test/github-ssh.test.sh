#!/usr/bin/env bash
# A container with no GitHub key gets one key and GitHub's published host keys.
# A rejected fetch prints that public key and stops before composer.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ssh="${root}/actions/ssh/github-ssh.sh"
deploy="${root}/actions/ssh/remote-deploy.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "github-ssh: $1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

export HOME="${tmp}/home"
export GIT_REMOTE="git@github.com:example/site.git"
mkdir -p "$HOME"

# shellcheck disable=SC1090
source "$ssh"

prepare_github_ssh
[[ -f "${HOME}/.ssh/id_ed25519" ]] || fail "did not create a deploy key"
[[ -f "${HOME}/.ssh/id_ed25519.pub" ]] || fail "did not write the public key"
pub="$(cat "${HOME}/.ssh/id_ed25519.pub")"
[[ "$pub" == "ssh-ed25519 "* ]] || fail "public key is not ed25519" "$pub"
grep -q 'IdentitiesOnly yes' "${HOME}/.ssh/config" || fail "did not pin the new key to github.com"
github_known_hosts_trusted || fail "published host keys were not accepted"
ed25519_lines="$(grep -c 'github.com ssh-ed25519 ' "${HOME}/.ssh/known_hosts")"
[[ "$ed25519_lines" -eq 1 ]] || fail "expected one ed25519 host key, found ${ed25519_lines}"

prepare_github_ssh
[[ "$(cat "${HOME}/.ssh/id_ed25519.pub")" == "$pub" ]] || fail "a second prepare replaced the deploy key"
ed25519_lines="$(grep -c 'github.com ssh-ed25519 ' "${HOME}/.ssh/known_hosts")"
[[ "$ed25519_lines" -eq 1 ]] || fail "a second prepare duplicated the host key"

set +e
instructions="$(explain_github_deploy_key 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "the deploy-key instructions should fail the deploy" "$instructions"
[[ "$instructions" == *"$pub"* ]] || fail "instructions omitted the public key" "$instructions"
[[ "$instructions" == *"https://github.com/example/site/settings/keys/new"* ]] || fail "instructions omitted the settings link" "$instructions"
[[ "$instructions" != *"PRIVATE KEY"* ]] || fail "instructions included a private key header" "$instructions"
private_line="$(sed -n '2p' "${HOME}/.ssh/id_ed25519")"
[[ "$instructions" != *"$private_line"* ]] || fail "instructions included the private key"

# An existing key is left in place, and no github.com config block is added for it.
rm -rf "$HOME"
mkdir -p "${HOME}/.ssh"
ssh-keygen -q -t ed25519 -f "${HOME}/.ssh/id_ed25519" -N "" -C "kept"
kept="$(cat "${HOME}/.ssh/id_ed25519.pub")"
prepare_github_ssh
[[ "$(cat "${HOME}/.ssh/id_ed25519.pub")" == "$kept" ]] || fail "replaced an existing deploy key"
[[ ! -e "${HOME}/.ssh/config" ]] || fail "wrote an ssh config for a key that was already there"

# A github.com entry that is not GitHub's key is reported, not trusted.
bogus="$(mktemp -d)"
ssh-keygen -q -t ed25519 -f "${bogus}/key" -N "" -C "bogus"
printf 'github.com %s\n' "$(cat "${bogus}/key.pub")" > "${HOME}/.ssh/known_hosts"
github_known_hosts_trusted && fail "a stand-in host key was trusted"
set +e
host_msg="$(explain_github_host_key 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 && "$host_msg" == *"Remove the github.com lines"* ]] || fail "a bad host key should say to remove it" "$host_msg"

# The deploy stops on a public-key rejection and does not build the site.
unset SITEHOST_GITHUB_SSH_LOADED
bin="${tmp}/bin"
mkdir -p "$bin"
export CALLS="${tmp}/calls.log"
cat > "${bin}/git" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' git "$*" >> "$CALLS"
if [[ "$*" == *fetch* ]]; then
  echo "git@github.com: Permission denied (publickey)." >&2
  exit 128
fi
STUB
chmod +x "${bin}/git"
app="${tmp}/app"
mkdir -p "${app}/.git"
rm -rf "$HOME"
mkdir -p "$HOME"
set +e
out="$(
  env -u SITEHOST_GITHUB_SSH_LOADED -u SITEHOST_LIB_LOADED -u SITEHOST_RUNTIME_LOADED \
    HOME="$HOME" \
    PATH="${bin}:${PATH}" \
    CALLS="$CALLS" \
    SITEHOST_APP_PATH="$app" \
    DEPLOY_LOG_DIR="${tmp}/logs" \
    GIT_REMOTE="git@github.com:example/site.git" \
    DEPLOY_SHA="0123456789abcdef0123456789abcdef01234567" \
    bash "$deploy" 2>&1
)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "a missing deploy key should fail the deploy" "$out"
[[ "$out" == *"https://github.com/example/site/settings/keys/new"* ]] || fail "the deploy did not print the settings link" "$out"
created="$(cat "${HOME}/.ssh/id_ed25519.pub")"
[[ "$out" == *"$created"* ]] || fail "the deploy did not print the new public key" "$out"
[[ "$out" != *"PRIVATE KEY"* ]] || fail "the deploy log included a private key header" "$out"
grep -q 'composer' "$CALLS" && fail "composer ran after GitHub rejected the key"
grep -q 'fetch origin 0123456789abcdef0123456789abcdef01234567' "$CALLS" || fail "did not try to fetch"

echo "github ssh test passed"
