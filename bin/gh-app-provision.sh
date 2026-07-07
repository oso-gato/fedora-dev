#!/usr/bin/env bash
# gh-app-provision.sh — paste-based GitHub App credential provisioning for the
# fleet's setup wizards (spin-up.sh / day0.sh). Turns a TERMINAL PASTE of an App
# private-key PEM into a podman SECRET (never a loose file on disk) and collects the
# two PUBLIC ids, so a box can mint short-lived (<=1h) GitHub App installation tokens
# at runtime — see the container side bin/gh-app-auth.sh (secret at /run/secrets/gh_app_key).
#
# CANONICAL copy lives in oso-gato/fedora-dev (the merge box); mirrored VERBATIM into
# fedora-desktop + fedora-bootstrap, like sync-authorized-keys.sh. Keep in lockstep.
#
# SOURCEABLE function library (each container's wizard is the single source of truth
# for ITS questions; day0 invokes that wizard rather than duplicating prompts):
#   _gha_ask "<prompt>"                    -> read one PUBLIC line from the terminal
#   read_pem_to_secret   <secret-name>     -> paste a PEM STRAIGHT into `podman secret create`
#   read_pem_to_var      <varname>         -> paste a PEM into a shell var (root->core ferry only)
#   make_secret_from_var <secret> <var>    -> create a podman secret from a var (core side)
#   prompt_github_app    <secret> [idv instv] -> ask the 2 ids + paste PEM -> secret + export ids
#
# SECURITY: the PEM's ONLY at-rest home is podman's own secret store (rootless `file`
# driver, 0600), mounted read-only into tmpfs in the container. It is never written to a
# loose file, never placed in argv (only the PUBLIC ids are), and on the by-hand paths
# never held whole in a variable. App ID / Installation ID are PUBLIC integers.
#
# Prompts go to $GHA_TTY and pasted input is read from $GHA_IN (both default /dev/tty —
# reading the TERMINAL, not the script's stdin, so the prompt works as the last line of a
# multi-line paste and the streamed PEM never collides with the captured stdout). Both are
# overridable ONLY to make the read testable.

# Harden options ONLY when executed directly — when sourced by a wizard, do NOT clobber
# the parent's `set -e`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then set -uo pipefail; fi

GHA_TTY="${GHA_TTY:-/dev/tty}"   # where prompts are written
GHA_IN="${GHA_IN:-/dev/tty}"     # where pasted lines are read

_gha_ask() {  # _gha_ask "<prompt>"  -> echoes the entered value
  # v pre-initialized: under a caller's `set -u`, a failed read (no terminal — e.g. a
  # detached-tty su layer) left v UNSET and the printf died "v: unbound variable".
  local v=""
  { : <"$GHA_IN"; } 2>/dev/null || { echo "gha: input device $GHA_IN is not readable (no terminal?)" >&2; return 1; }
  printf '>> %s: ' "$1" >"$GHA_TTY"; IFS= read -r v <"$GHA_IN" || true; printf '%s' "${v:-}"
}

# Stream a pasted PEM line-by-line to stdout; stop at a sentinel ("END"/"__END__"),
# the PEM's own final line, or EOF. The PEM is never buffered whole — each line is
# emitted as it is read.
_gha_stream_pem() {
  printf '>> Paste the GitHub App private-key PEM, then a line "END" (or Ctrl-D):\n' >"$GHA_TTY"
  local line
  while IFS= read -r line; do
    case "$line" in
      END|__END__)                     break ;;
      '-----END '*'PRIVATE KEY-----')  printf '%s\n' "$line"; break ;;
      *)                               printf '%s\n' "$line" ;;
    esac
  done <"$GHA_IN"
}

# Re-flow a paste-mangled PEM. Browser consoles (verified live: Hostinger, 2026-07-08)
# flatten a multi-line paste into ONE line, turning the newlines into spaces. That is
# DETERMINISTICALLY reversible: extract header/footer + base64 body, strip whitespace,
# re-fold the body to 64 columns. Idempotent on a well-formed PEM. Emits nothing (rc 1)
# when the markers can't be found.
_gha_reflow_pem() {  # stdin: pasted text -> stdout: normalized PEM
  local flat hdr ftr body
  flat="$(tr '\n' ' ')"
  hdr="$(printf '%s' "$flat" | grep -oE -- '-----BEGIN [A-Z ]+KEY-----' | head -1)"
  ftr="$(printf '%s' "$flat" | grep -oE -- '-----END [A-Z ]+KEY-----'   | head -1)"
  body="$(printf '%s' "$flat" | sed -n 's/.*KEY-----\(.*\)-----END.*/\1/p' | tr -d '[:space:]')"
  [ -n "$hdr" ] && [ -n "$ftr" ] && [ -n "$body" ] || return 1
  printf '%s\n' "$hdr"
  printf '%s\n' "$body" | fold -w 64
  printf '%s\n' "$ftr"
}

# Validate a PEM actually parses as a private key (openssl, stdin only — never a file).
_gha_pem_valid() { printf '%s\n' "$1" | openssl pkey -noout 2>/dev/null; }

# Read + reflow + VALIDATE a pasted PEM, re-prompting on a mangled paste (up to 3 tries).
# Validation runs BEFORE any secret is created — a truncated console paste (bytes silently
# dropped mid-paste) fails HERE with the cause named, not later at JWT signing.
_gha_read_valid_pem() {  # -> echoes the validated PEM; rc 1 after 3 failed attempts
  local attempt pem
  for attempt in 1 2 3; do
    pem="$(_gha_stream_pem | _gha_reflow_pem)" || pem=""
    if [ -n "$pem" ] && _gha_pem_valid "$pem"; then printf '%s' "$pem"; return 0; fi
    printf '>> That paste is NOT a valid private key (%s chars received) — likely truncated/garbled\n' "${#pem}" >"$GHA_TTY"
    printf '>> by the console (browser consoles mangle long pastes). Attempt %s of 3 — paste again\n' "$attempt" >"$GHA_TTY"
    printf '>> (or Ctrl-C and run Day-0 over plain ssh, the reliable channel for pastes):\n' >"$GHA_TTY"
  done
  echo "gha: no valid PEM after 3 attempts" >&2; return 1
}

read_pem_to_secret() {  # read_pem_to_secret <podman-secret-name>
  local name="${1:?secret name required}" _pem
  command -v podman >/dev/null 2>&1 || { echo "gha: podman not found" >&2; return 1; }
  _pem="$(_gha_read_valid_pem)" || return 1
  printf '%s\n' "$_pem" | podman secret create --replace "$name" - \
    || { echo "gha: 'podman secret create $name' failed" >&2; return 1; }
}

read_pem_to_var() {  # read_pem_to_var <varname>   (root->core ferry; PEM transiently in a var)
  local _v="${1:?varname required}" _pem; _pem="$(_gha_read_valid_pem)" || return 1
  printf -v "$_v" '%s' "$_pem"
}

make_secret_from_var() {  # make_secret_from_var <secret-name> <varname>   (core side)
  local name="${1:?secret name required}" var="${2:?varname required}"
  command -v podman >/dev/null 2>&1 || { echo "gha: podman not found" >&2; return 1; }
  printf '%s' "${!var}" | podman secret create --replace "$name" - \
    || { echo "gha: 'podman secret create $name' failed" >&2; return 1; }
}

prompt_github_app() {  # prompt_github_app <secret-name> [<id-var> <inst-var>]  -> secret + export ids
  local name="${1:-gh_app_key}" idv="${2:-GH_APP_ID}" instv="${3:-GH_APP_INSTALLATION_ID}" id inst
  id="$(_gha_ask 'GitHub App ID (public integer)')"
  inst="$(_gha_ask 'GitHub App Installation ID (public integer)')"
  [ -n "$id" ] || { echo "gha: App ID is required" >&2; return 1; }
  read_pem_to_secret "$name" || return 1
  printf -v "$idv" '%s' "$id"; printf -v "$instv" '%s' "$inst"
  export "${idv?}" "${instv?}"
  echo "gha: podman secret '$name' created; $idv=$id $instv=$inst" >&2
}
