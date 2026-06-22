#!/usr/bin/env bash
# Mint a short-lived GitHub App installation token and print it to
# stdout. Copied from sealedsecurity/seal's .buildkite/scripts (kept
# in sync by hand — this repo publishes rarely). Parameterized by
# GH_APP_REPO so it targets sealedsecurity/seal-bundled-deps.
#
# Env (from secret-env in the consuming pipeline):
#   GH_APP_ID               the App's numeric App ID
#   GH_APP_PRIVATE_KEY_B64  base64 -w0 of the App's .pem
#   GH_APP_REPO             owner/repo (default sealedsecurity/seal-bundled-deps)
#
# The App must be installed on the repo with Contents:write.
# Deps: curl + openssl only.
set -euo pipefail

: "${GH_APP_ID:?GH_APP_ID must be set}"
: "${GH_APP_PRIVATE_KEY_B64:?GH_APP_PRIVATE_KEY_B64 must be set}"
repo="${GH_APP_REPO:-sealedsecurity/seal-bundled-deps}"

key_file="$(mktemp)"
trap 'rm -f "${key_file}"' EXIT
printf '%s' "${GH_APP_PRIVATE_KEY_B64}" | base64 -d >"${key_file}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now="$(date +%s)"
header='{"alg":"RS256","typ":"JWT"}'
payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "${GH_APP_ID}")"
unsigned="$(printf '%s' "${header}" | b64url).$(printf '%s' "${payload}" | b64url)"
sig="$(printf '%s' "${unsigned}" | openssl dgst -sha256 -sign "${key_file}" | b64url)"
jwt="${unsigned}.${sig}"

jwt_auth=(
    -H "Authorization: Bearer ${jwt}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)

gh_call() {
    local label="$1"
    shift
    local body status
    body="$(curl -sS --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 1 -w $'\n%{http_code}' "$@")" || {
        echo "gh-app-token: ${label}: curl transport error" >&2
        return 1
    }
    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [[ "${status}" != 2* ]]; then
        echo "gh-app-token: ${label} failed (HTTP ${status})" >&2
        echo "${body}" | sed -n 's/.*"message":[[:space:]]*"\([^"]*\)".*/  message: \1/p' >&2
        return 1
    fi
    printf '%s' "${body}"
}

install_id="$(
    gh_call "installation lookup for ${repo}" "${jwt_auth[@]}" \
        "https://api.github.com/repos/${repo}/installation" |
        grep -m1 -o '"id":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+'
)" || exit 1
[[ -n "${install_id}" ]] || {
    echo "gh-app-token: no installation id in lookup response for ${repo}" >&2
    exit 1
}

token="$(
    gh_call "token mint (installation ${install_id})" -X POST "${jwt_auth[@]}" \
        "https://api.github.com/app/installations/${install_id}/access_tokens" |
        sed -n 's/.*"token":[[:space:]]*"\([^"]*\)".*/\1/p'
)" || exit 1
[[ -n "${token}" ]] || {
    echo "gh-app-token: no token in mint response" >&2
    exit 1
}

printf '%s' "${token}"
