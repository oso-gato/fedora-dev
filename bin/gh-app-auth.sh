#!/usr/bin/env bash
# gh-app-auth.sh — STANDING, AUTO-ROTATING GitHub credential for fedora-dev, so the
# autonomous dev loop (git push / gh pr create / label) never stops for auth.
#
# Mints a short-lived GitHub App INSTALLATION token (fresh from the App private key,
# <=1h lifetime, only the installation's repo scopes) — no human expiry to babysit.
# The private key enters ONLY at runtime (Build Principle 5: no secret in any image
# layer); it is read from a mounted secret file (preferred, tmpfs) or an inline env
# var, and is NEVER printed.
#
# WHERE THE AGENT RUNS GIT: in the claudebox (Distrobox), NOT the base image. So the
# token is wired to BOTH consumers via paths that EXIST in-box (the home volume):
#   * git  -> git's BUILT-IN `store` helper + ~/.git-credentials (store ships with git,
#            so it works in-box; a script/key under the base /usr/local/bin or
#            /run/secrets would be invisible there).
#   * gh   -> ~/.config/gh/hosts.yml (+ config.yml version marker).
# Both files live on the shared home volume and are refreshed by the entrypoint tick.
#
# Inputs (env; the App private key may instead be a mounted file):
#   GH_APP_ID                 (required) the App's App-ID (integer)
#   GH_APP_PRIVATE_KEY_FILE   path to the PEM (default /run/secrets/gh_app_key)
#   GH_APP_PRIVATE_KEY        PEM text inline (alternative to the file)
#   GH_APP_INSTALLATION_ID    (optional) installation id; auto-discovered if unset
#   GH_API                    (default https://api.github.com)
#
# Modes:
#   gh-app-auth.sh token      # print a fresh installation token to stdout
#   gh-app-auth.sh install    # mint + wire core's git (store) and gh (hosts.yml)
#
# FAIL CLOSED: any missing input / signing / API failure / empty token → non-zero exit,
# nothing sensitive on stdout.
set -uo pipefail
umask 077

MODE="${1:-token}"
API="${GH_API:-https://api.github.com}"
HOME="${HOME:-/home/core}"
GH_HOSTS="$HOME/.config/gh/hosts.yml"

die(){ echo "gh-app-auth: $*" >&2; exit 1; }
b64url(){ openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }   # base64url, no padding

mint_token() {
    [ -n "${GH_APP_ID:-}" ] || die "GH_APP_ID is required"
    local key_file="${GH_APP_PRIVATE_KEY_FILE:-/run/secrets/gh_app_key}" keytmp
    keytmp="$(mktemp)" || die "mktemp failed"
    # RETURN cleans on normal return; EXIT cleans when die() exits this $()-subshell —
    # a RETURN trap alone does NOT fire on exit, which would leak the key copy to /tmp.
    trap 'rm -f "$keytmp"' RETURN EXIT
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

    # minimal, fail-closed GitHub API helper (no jq). Bounded timeouts so a network
    # blackhole can't hang init (this runs synchronously during entrypoint bring-up).
    api(){ local m="$1" path="$2" out code body
        out="$(curl -sS --connect-timeout 10 --max-time 20 -X "$m" -w $'\n%{http_code}' \
            -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" "${API}${path}" 2>/dev/null)" || return 1
        code="${out##*$'\n'}"; body="${out%$'\n'*}"
        case "$code" in 2*) printf '%s' "$body";; *) return 1;; esac; }

    local inst="${GH_APP_INSTALLATION_ID:-}" insts ids n tokresp token
    if [ -z "$inst" ]; then
        insts="$(api GET /app/installations)" || die "could not list installations (check the App key / App-ID)"
        # The list repeats "id" (installation + account objects); the FIRST is the
        # installation id. Count installation OBJECTS by "account" — if >1, the choice is
        # ambiguous, so require an explicit GH_APP_INSTALLATION_ID (Quadlet/run.sh set it).
        n="$(printf '%s' "$insts" | grep -c '"account"')"
        [ "${n:-0}" -ge 1 ] || die "no installations found for this App"
        [ "${n:-0}" -eq 1 ] || die "$n installations — set GH_APP_INSTALLATION_ID explicitly"
        ids="$(printf '%s' "$insts" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')"
        inst="$(printf '%s\n' "$ids" | head -1)"
        [ -n "$inst" ] || die "could not resolve an installation id"
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

    install)
        mkdir -p "$(dirname "$GH_HOSTS")"
        # config.yml version marker — without it gh treats a fresh dir as legacy and
        # attempts a multi-account migration that 401s on first use.
        gh_cfg="$(dirname "$GH_HOSTS")/config.yml"
        [ -f "$gh_cfg" ] || printf 'version: 1\ngit_protocol: https\n' > "$gh_cfg"

        # Mint ONCE, wire BOTH consumers from the same token.
        tok="$(mint_token)" || die "initial token mint failed"

        # git (the agent's `git push` runs IN-BOX): built-in `store` helper +
        # ~/.git-credentials on the shared home volume. `store` ships with git, so it
        # resolves in the claudebox too. Token is <=1h, rewritten by the refresh tick.
        printf 'https://x-access-token:%s@github.com\n' "$tok" > "$HOME/.git-credentials"
        chmod 600 "$HOME/.git-credentials"
        if ! grep -qE '^[[:space:]]*helper[[:space:]]*=[[:space:]]*store' "$HOME/.gitconfig" 2>/dev/null; then
            printf '[credential]\n\thelper = store\n' >> "$HOME/.gitconfig"
        fi

        # gh CLI (in-box: gh pr create / comment / label): native nested hosts.yml.
        printf 'github.com:\n    users:\n        x-access-token:\n            oauth_token: %s\n    git_protocol: https\n    oauth_token: %s\n    user: x-access-token\n' \
            "$tok" "$tok" > "$GH_HOSTS"
        chmod 600 "$GH_HOSTS"
        echo "gh-app-auth: installed (git store helper + gh hosts.yml; token <=1h, auto-refreshed)"
        ;;

    *)
        die "usage: gh-app-auth.sh token|install"
        ;;
esac
