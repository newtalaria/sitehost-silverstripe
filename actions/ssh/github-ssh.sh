#!/usr/bin/env bash
# GitHub host keys and the container deploy key for git fetch.
# The published host keys are pinned so a missing known_hosts entry can be
# written without trusting a key fetched at deploy time. A container that
# already has a GitHub identity keeps it. A container with none gets one
# ed25519 key, and a rejected fetch prints that public key.

export SITEHOST_GITHUB_SSH_LOADED=1

# GitHub's published host keys, checked 2026-11-11 against api.github.com/meta.
# Fingerprints: ed25519 SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU,
# ecdsa SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM,
# rsa SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s.
GITHUB_HOST_KEYS=$'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='

# Drop leading and trailing whitespace. SSH config lines need this before the keyword is read.
github_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Expand a leading ~/ in an IdentityFile path. OpenSSH does this; the file test below needs the real path.
github_expand_path() {
  local path="$1"
  # A stored IdentityFile keeps a literal tilde. This comparison does not expand it.
  # shellcheck disable=SC2088
  local home_prefix='~/'
  if [[ "$path" == "${home_prefix}"* ]]; then
    path="${HOME}/${path#"$home_prefix"}"
  elif [[ "$path" == '~' ]]; then
    path="${HOME}"
  fi
  printf '%s' "$path"
}

# Print the first IdentityFile under a Host block that matches github.com, when that file exists.
github_configured_identity() {
  local config="${HOME}/.ssh/config"
  local line key rest token path in_match
  [[ -f "$config" ]] || return 1
  in_match=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(github_trim "$line")"
    [[ -z "$line" ]] && continue
    key="${line%%[[:space:]]*}"
    rest="$(github_trim "${line#"$key"}")"
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    if [[ "$key" == "host" ]]; then
      in_match=0
      # Host patterns are single tokens. A literal * matches every host, including github.com.
      # shellcheck disable=SC2086
      for token in $rest; do
        if [[ "$token" == "github.com" || "$token" == "*" ]]; then
          in_match=1
        fi
      done
      continue
    fi
    if [[ "$in_match" -eq 1 && "$key" == "identityfile" ]]; then
      path="$(github_expand_path "$rest")"
      if [[ -f "$path" ]]; then
        printf '%s' "$path"
        return 0
      fi
    fi
  done < "$config"
  return 1
}

# Use the container's existing GitHub key, or create one ed25519 key and pin it to github.com.
ensure_github_identity() {
  local ssh_dir candidate path config
  if [[ -z "${HOME:-}" ]]; then
    echo "HOME is not set, so the GitHub deploy key cannot be stored." >&2
    exit 1
  fi
  ssh_dir="${HOME}/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  if path="$(github_configured_identity)"; then
    GITHUB_IDENTITY="$path"
    return 0
  fi
  for candidate in id_ed25519 id_ecdsa id_rsa; do
    if [[ -f "${ssh_dir}/${candidate}" ]]; then
      GITHUB_IDENTITY="${ssh_dir}/${candidate}"
      return 0
    fi
  done
  path="${ssh_dir}/id_ed25519"
  ssh-keygen -q -t ed25519 -f "$path" -N "" -C "sitehost-deploy"
  chmod 600 "$path"
  config="${ssh_dir}/config"
  {
    printf '\nHost github.com\n'
    printf '  IdentityFile %s\n' "$path"
    printf '  IdentitiesOnly yes\n'
  } >> "$config"
  chmod 600 "$config"
  GITHUB_IDENTITY="$path"
}

# Write GitHub's published host keys when this user has no github.com entry yet.
ensure_github_known_hosts() {
  local known="${HOME}/.ssh/known_hosts"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "$known"
  chmod 600 "$known"
  if ssh-keygen -F github.com -f "$known" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' "$GITHUB_HOST_KEYS" >> "$known"
}

# Return 0 when every github.com key already stored matches a published fingerprint.
github_known_hosts_trusted() {
  local known="${HOME}/.ssh/known_hosts"
  local lines line fingerprint trusted
  [[ -f "$known" ]] || return 1
  lines="$(ssh-keygen -F github.com -f "$known" 2>/dev/null | grep -v '^#' || true)"
  [[ -n "$lines" ]] || return 1
  trusted=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    trusted=1
    fingerprint="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null || true)"
    case "$fingerprint" in
      *"SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"*|\
      *"SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"*|\
      *"SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"*) ;;
      *) return 1 ;;
    esac
  done <<< "$lines"
  [[ "$trusted" -eq 1 ]]
}

# Prepare known_hosts and the identity before git fetch. Sets GITHUB_IDENTITY.
prepare_github_ssh() {
  ensure_github_known_hosts
  ensure_github_identity
}

# Print the public half of GITHUB_IDENTITY. Derive it when the .pub file is absent.
github_public_key() {
  local pub="${GITHUB_IDENTITY}.pub"
  if [[ -f "$pub" ]]; then
    cat "$pub"
    return 0
  fi
  ssh-keygen -y -f "$GITHUB_IDENTITY"
}

# The fetch log is a host-key rejection.
github_fetch_failed_host_key() {
  grep -q 'Host key verification failed' "$1"
}

# The fetch log is an authentication rejection.
github_fetch_failed_publickey() {
  grep -q 'Permission denied (publickey)' "$1"
}

# Stop the deploy and say which known_hosts entry to remove, or that the published keys are already present.
explain_github_host_key() {
  if github_known_hosts_trusted; then
    echo "GitHub refused the host key check for ${GIT_REMOTE}. ${HOME}/.ssh/known_hosts already contains GitHub's published keys." >&2
  else
    echo "The github.com entry in ${HOME}/.ssh/known_hosts does not match the host key GitHub publishes." >&2
    echo "Remove the github.com lines from that file and run the deploy again." >&2
  fi
  exit 1
}

# Stop the deploy and print the public key the repository still needs to trust.
explain_github_deploy_key() {
  local slug pub
  slug="${GIT_REMOTE%.git}"
  slug="${slug#git@github.com:}"
  pub="$(github_public_key)"
  echo "This container cannot fetch ${GIT_REMOTE} until GitHub accepts its deploy key." >&2
  echo "Add this public key on ${slug} as a deploy key. Leave write access off, then run the deploy again." >&2
  echo "https://github.com/${slug}/settings/keys/new" >&2
  echo >&2
  printf '%s\n' "$pub" >&2
  echo >&2
  echo "The private key stays on this container. The same public key is printed until it is registered." >&2
  exit 1
}
