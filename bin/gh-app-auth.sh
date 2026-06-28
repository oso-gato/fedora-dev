#!/usr/bin/env bash
# gh-app-auth.sh — STANDING, AUTO-ROTATING GitHub credential for fedora-dev, so the
# autonomous dev loop (git push / gh pr create / label) never stops for auth.
#
# It mints a short-lived GitHub App INSTALLATION token (fresh from the App private
# key, <=1h lifetime, only the installation's repo scopes) — there is no human
# expiry to babysit. The private key enters ONLY at runtime (Build Principle 5: no
# secret in any image layer); it is read from a mounted secret file (preferred,
# tmpfs) or an inline env var, and is NEVER printed.
#
# Runs at the BASE image level (entrypoint, PID 1) where the `gh` binary is NOT
# installed (gh lives in the claudebox). So the git path is gh-free: a git
# credential helper that mints a token ON DEMAND (no token ever persisted to disk).
# The box's `gh` CLI is served separately by a written ~/.config/gh/hosts.yml.
#
# Inputs (env; the App private key may instead be a mounted file):
#   GH_APP_ID                 (required) the App's App-ID (integer)
#   GH_APP_PRIVATE_KEY_FILE   path to the PEM (default /run/secrets/gh_app_key)
#   GH_APP_PRIVATE_KEY        PEM text inline (alternative to the file)
#   GH_APP_INSTALLATION_ID    (optional) installation id; auto-discovered if unset
#   GH_API                    (default https://api.github.com)
#
# Modes:
#   gh-app-auth.sh token        # print a fresh installation token to stdout
#   gh-app-auth.sh credential   # git credential-helper protocol (mint on demand)
#   gh-app-auth.sh install      # wire git (on-demand helper) + gh (hosts.yml) for `core`
#
# FAIL CLOSED: any missing input / signing / API failure / empty token → non-zero exit,
# nothing sensitive on stdout. `credential` stays silent on anything but github.com.
set -uo pipefail
umask 077

MODE="${1:-token}"
API="${GH_API:-https://api.github.com}"
CFG_DIR="${HOME:-/home/core}/.config/fedora-dev"
ENV_FILE="$CFG_DIR/gh-app.env"          # NON-secret App identity (id, install, key path)
GH_HOSTS="${HOME:-/home/core}/.config/gh/hosts.yml"
SELF="/usr/local/bin/gh-app-auth.sh"    # the on-disk path git invokes as the helper

die(){ echo "gh-app-auth: $*" >&2; exit 1; }
b64url(){ openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }   # base64url, no padding

# --- credential mode sources the persisted (non-secret) App identity first --------
# git invokes the helper with NO inherited env, so identity must be on disk. The
# private KEY is referenced by path (kept in tmpfs /run/secrets), never persisted.
if [ "$MODE" = credential ] && [ -r "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

mint_token() {
    [ -n "${GH_APP_ID:-}" ] || die "GH_APP_ID is required"
    local key_file="${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}" keytmp
    keytmp="$(mktemp)" || die "mktemp failed"
    trap 'rm -f "$keytmp"' RETURN
    if [ -n "${GH_APP_PRIVATE_KEY:-}" ]; then printf '%s\n' "$GH_APP_PRIVATE_KEY" > "$keytmp"
    elif [ -r "$key_file" ];               then cat "$key_file" > "$keytmp"
    else die "no private key (set GH_APP_PRIVATE_KEY or provide $key_file)"; fi
    [ -s "$keytmp" ] || die "private key is empty"

    # RS256 JWT: iat backdated 60s for clock skew; exp +9m (< GitHub's 10m cap).
    local now iat exp header payload h p si sig jwt
    now="$(date +%s)" || die "date failed"; iat=$((now-60)); exp=$((now+540))
    header='{"alg":"RS256","typ":"JWT"}'
    payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GH_APP_ID")"
    h="$(printf '%s' "$header"  | b64url)"; p="$(printf '%s' "$payload" | b64url)"
    si="${h}.${p}"
    sig="$(printf '%s' "$si" | openssl dgst -sha256 -sign "$keytmp" -binary 2>/dev/null | b64url)" \
        || die "JWT signing failed (bad private key?)"
    [ -n "$sig" ] || die "empty signature"
    jwt="${si}.${sig}"

    api(){ local m="$1" path="$2" out code body
        out="$(curl -sS -X "$m" -w $'\n%{http_code}' \
            -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" "${API}${path}" 2>/dev/null)" || return 1
        code="${out##*$'\n'}"; body="${out%$'\n'*}"
        case "$code" in 2*) printf '%s' "$body";; *) return 1;; esac; }

    local inst="${GH_APP_INSTALLATION_ID:-}" tokresp token
    if [ -z "$inst" ]; then
        inst="$(api GET /app/installations | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')" \
            || die "could not list installations (check the App key / App-ID)"
        [ -n "$inst" ] || die "no installations found for this App"
    fi
    tokresp="$(api POST "/app/installations/${inst}/access_tokens")" \
        || die "installation-token exchange failed (installation $inst)"
    token="$(printf '%s' "$tokresp" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$token" ] || die "no token in installation-token response"
    printf '%s' "$token"
}

case "$MODE" in
    token)
        tok="$(mint_token)" || exit 1     # propagate fail-closed; a bare printf would mask it
        printf '%s\n' "$tok"
        ;;

    credential)
        # git credential helper. Only `get` for github.com gets an answer; mint fresh.
        [ "${2:-}" = get ] || exit 0
        host=""; while IFS='=' read -r k v; do [ "$k" = host ] && host="$v"; [ -z "$k" ] && break; done
        [ "$host" = github.com ] || exit 0
        tok="$(mint_token)" || exit 0          # fail SILENT → git falls back to its other helpers
        printf 'username=x-access-token\npassword=%s\n' "$tok"
        ;;

    install)
        # Wire `core`'s git + gh to the App credential. Idempotent.
        mkdir -p "$CFG_DIR" "$(dirname "$GH_HOSTS")"
        # 0) ensure gh's config carries a schema VERSION marker — without it a fresh config
        #    dir is treated as legacy and gh attempts a multi-account migration that 401s on
        #    first use. Don't clobber an existing config.yml.
        gh_cfg="$(dirname "$GH_HOSTS")/config.yml"
        [ -f "$gh_cfg" ] || printf 'version: 1\ngit_protocol: https\n' > "$gh_cfg"
        # 1) persist NON-secret App identity for the on-demand git helper (no key here).
        {   printf 'GH_APP_ID=%q\n'              "${GH_APP_ID:?GH_APP_ID required}"
            printf 'GH_APP_INSTALLATION_ID=%q\n' "${GH_APP_INSTALLATION_ID:-}"
            printf 'GH_APP_PRIVATE_KEY_FILE=%q\n' "${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}"
        } > "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        # If the key was supplied INLINE (no mounted file), persist it 0600 on the home
        # volume so the helper can read it later (runtime artifact, never a layer).
        if [ -n "${GH_APP_PRIVATE_KEY:-}" ] && [ ! -r "${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}" ]; then
            printf '%s\n' "$GH_APP_PRIVATE_KEY" > "$CFG_DIR/app_key.pem"; chmod 600 "$CFG_DIR/app_key.pem"
            printf 'GH_APP_PRIVATE_KEY_FILE=%q\n' "$CFG_DIR/app_key.pem" >> "$ENV_FILE"
        fi
        # 2) git: on-demand credential helper for github.com (mints fresh per op).
        git config --global --replace-all "credential.https://github.com.helper" "!$SELF credential"
        git config --global --replace-all "credential.https://github.com.useHttpPath" "false"
        # 3) gh CLI: write a fresh token into hosts.yml in gh's NATIVE nested format
        #    (the flat legacy form makes gh attempt a multi-account migration that 401s).
        #    Refreshed on the entrypoint 40-min tick.
        tok="$(mint_token)" || die "initial token mint failed"
        printf 'github.com:\n    users:\n        x-access-token:\n            oauth_token: %s\n    git_protocol: https\n    oauth_token: %s\n    user: x-access-token\n' \
            "$tok" "$tok" > "$GH_HOSTS"
        chmod 600 "$GH_HOSTS"
        echo "gh-app-auth: installed (git on-demand helper + gh hosts.yml; token <=1h, auto-refreshed)"
        ;;

    *)
        die "usage: gh-app-auth.sh token|credential|install"
        ;;
esac
