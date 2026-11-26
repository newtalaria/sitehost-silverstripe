#!/usr/bin/env bash
# A failed smoke check prints the PHP fatal from the Apache log, and nothing else from that file.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="${root}/actions/ssh/remote-php-error.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log="${tmp}/error.log"
export APACHE_ERROR_LOG="$log"
cat > "$log" <<'EOF'
[Thu Nov 26 14:54:52] [proxy_fcgi:error] AH01071: Got error 'PHP message: [Talaria] Silverstripe client disabled'
[Thu Nov 26 14:56:14] [proxy_fcgi:error] AH01071: Got error 'PHP message: PHP Fatal error: Uncaught SilverStripe\Core\Injector\InjectorNotFoundException: Class Talaria\SilverStripe\LogHandlerFactory does not exist'
[Thu Nov 26 14:56:15] [core:notice] AH00094: Command line: '/usr/sbin/apache2 -D FOREGROUND'
EOF

out="$(bash "$script")"
[[ "$out" == *"LogHandlerFactory does not exist"* ]] || {
  echo "php-error: did not print the fatal" >&2
  printf '%s\n' "$out" >&2
  exit 1
}
[[ "$out" == *"client disabled"* ]] || {
  echo "php-error: did not print the earlier PHP message" >&2
  printf '%s\n' "$out" >&2
  exit 1
}
[[ "$out" != *"AH00094"* ]] || {
  echo "php-error: printed a line that is not a PHP error" >&2
  printf '%s\n' "$out" >&2
  exit 1
}

export APACHE_ERROR_LOG="${tmp}/missing.log"
missing="$(bash "$script")"
[[ "$missing" == *"not found"* ]] || {
  echo "php-error: a missing log should be reported" >&2
  printf '%s\n' "$missing" >&2
  exit 1
}

echo "php error test passed"
