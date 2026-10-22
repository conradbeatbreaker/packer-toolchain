# shellcheck shell=bash
# Shared helpers for the toolchain scripts. Sourced, not executed.
#
# Two files drive everything:
#   versions.yaml       what is pinned        (toolchain approvers)
#   policy/trust.yaml   who signs it, where it comes from, soak period
#                       (security team)
#
# Requires: bash, curl, gpg, jq, yq (mikefarah v4), unzip.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="${VERSIONS:-$ROOT/versions.yaml}"
TRUST="$ROOT/policy/trust.yaml"
# Platform of the artifacts promoted and installed. Runners are linux_amd64;
# override only for local testing.
PLATFORM="${PLATFORM:-linux_amd64}"

die() { echo "::error::$*" >&2; exit 1; }

# Random heredoc delimiter for $GITHUB_OUTPUT. A fixed one could be closed
# early by text that came from a PR (e.g. a waiver file).
delim() { echo "EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; }

# --- versions.yaml ---------------------------------------------------------

# One line per component: product<TAB>version<TAB>plugin source ("-" for
# Packer itself). Packer always comes first.
components() {
  local f="${1:-$VERSIONS}"
  yq -r '["packer", .packer.version, "-"] | @tsv' "$f"
  yq -r '.plugins // {} | to_entries[] |
         ["packer-plugin-" + .key, .value.version, .value.source] | @tsv' "$f"
}

# Path of a component's version field in versions.yaml.
version_path() {
  case "$1" in
    packer) echo ".packer.version" ;;
    packer-plugin-*) echo ".plugins.\"${1#packer-plugin-}\".version" ;;
  esac
}

# version_in FILE PRODUCT -> version, or empty if absent.
version_in() { yq -r "$(version_path "$2") // \"\"" "$1" 2>/dev/null || true; }

# --- policy/trust.yaml -----------------------------------------------------

trust() { yq -r ".components.\"$1\".$2 // \"\"" "$TRUST"; }
key_fingerprint() { yq -r ".keys.\"$(trust "$1" key)\".fingerprint // \"\"" "$TRUST"; }
key_file() {
  local f; f="$(yq -r ".keys.\"$(trust "$1" key)\".file // \"\"" "$TRUST")"
  [[ -n "$f" ]] && echo "$ROOT/$f"
}
min_soak_days() { yq -r '.min_soak_days' "$TRUST"; }

# --- locations -------------------------------------------------------------
# Hosted layout keeps upstream filenames, so provenance stays obvious and an
# artifact can be re-verified later without going back to the internet:
#   packer-hosted/<product>/<version>/<upstream filename>

upstream_base() {
  local up; up="$(trust "$1" upstream)"
  case "$up" in
    hashicorp) echo "https://releases.hashicorp.com/$1/$2" ;;
    github:*)  echo "https://github.com/${up#github:}/releases/download/v$2" ;;
    *) die "$1: no usable upstream in policy/trust.yaml" ;;
  esac
}

proxy_base() {
  local up; up="$(trust "$1" upstream)"
  case "$up" in
    hashicorp) echo "$NEXUS_URL/repository/packer-proxy/$1/$2" ;;
    github:*)  echo "$NEXUS_URL/repository/github-proxy/${up#github:}/releases/download/v$2" ;;
    *) die "$1: no usable upstream in policy/trust.yaml" ;;
  esac
}

hosted_base() { echo "$NEXUS_URL/repository/packer-hosted/$1/$2"; }

# HashiCorp names files <product>_<ver>_*, GitHub releases <product>_v<ver>_*.
sums_name() {
  case "$(trust "$1" upstream)" in
    github:*) echo "${1}_v${2}_SHA256SUMS" ;;
    *)        echo "${1}_${2}_SHA256SUMS" ;;
  esac
}

# zip_name SUMS_FILE -> the one zip for $PLATFORM listed in the sums file.
zip_name() {
  local names
  names="$(awk -v p="_${PLATFORM}.zip" 'substr($2, length($2)-length(p)+1) == p {print $2}' "$1")"
  [[ -n "$names" && "$(wc -l <<<"$names")" -eq 1 ]] || return 1
  echo "$names"
}

# --- fetching --------------------------------------------------------------

# fetch URL OUT [USER PASS]. Credentials go to curl on stdin, not argv, so
# they don't show up in the process list.
fetch() {
  local url="$1" out="$2" user="${3:-}" pass="${4:-}"
  if [[ -n "$user" ]]; then
    curl -fsSL --retry 3 -o "$out" -K - "$url" <<<"user = \"$user:$pass\""
  else
    curl -fsSL --retry 3 -o "$out" "$url"
  fi
}

# fetch_release BASE_URL DIR PRODUCT VERSION [USER PASS]
# Downloads SHA256SUMS, its .sig and the $PLATFORM zip into DIR and prints
# the zip filename. Nothing is trusted yet; call the verify_* functions.
fetch_release() {
  local base="$1" dir="$2" product="$3" version="$4" sums zip
  sums="$(sums_name "$product" "$version")"
  mkdir -p "$dir"
  fetch "$base/$sums" "$dir/$sums" "${@:5}" || return 1
  fetch "$base/$sums.sig" "$dir/$sums.sig" "${@:5}" || return 1
  zip="$(zip_name "$dir/$sums")" || return 1
  fetch "$base/$zip" "$dir/$zip" "${@:5}" || return 1
  echo "$zip"
}

# --- verification ----------------------------------------------------------

# verify_signature PRODUCT SUMS SIG
# Good signature from the key pinned for PRODUCT, by full primary-key
# fingerprint. A subkey signature counts if its primary is the pinned key.
# Uses a throwaway keyring so nothing else on the host is trusted.
verify_signature() {
  local product="$1" sums="$2" sig="$3" fp keyfile home status rc=0
  fp="$(key_fingerprint "$product")"
  keyfile="$(key_file "$product")"
  [[ -n "$fp" && -f "$keyfile" ]] || { echo "no pinned key for $product" >&2; return 1; }
  home="$(mktemp -d)"
  gpg --homedir "$home" --batch --quiet --import "$keyfile" 2>/dev/null
  status="$(gpg --homedir "$home" --batch --status-fd 1 --verify "$sig" "$sums" 2>/dev/null)" || rc=1
  rm -rf "$home"
  [[ $rc -eq 0 ]] || return 1
  # Expired or revoked key or signature: reject, even though gpg exits 0.
  grep -qE '^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG|EXPSIG|BADSIG|ERRSIG)' <<<"$status" && return 1
  [[ "$(awk '$2 == "VALIDSIG" {print $NF}' <<<"$status")" == "$fp" ]]
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# verify_checksum SUMS ZIP_PATH: the zip's hash matches its line in SUMS.
verify_checksum() {
  local want
  want="$(awk -v n="$(basename "$2")" '$2 == n {print $1}' "$1")"
  [[ -n "$want" && "$(sha256 "$2")" == "$want" ]]
}

# --- upstream metadata -----------------------------------------------------

api_get() {
  local auth=()
  [[ "$1" == https://api.github.com/* && -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
  curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} "$1"
}

# release_meta PRODUCT VERSION -> "<prerelease true|false><TAB><created ISO8601>"
release_meta() {
  local up; up="$(trust "$1" upstream)"
  case "$up" in
    hashicorp)
      api_get "https://api.releases.hashicorp.com/v1/releases/$1/$2" |
        jq -r '[.is_prerelease, .timestamp_created] | @tsv' ;;
    github:*)
      api_get "https://api.github.com/repos/${up#github:}/releases/tags/v$2" |
        jq -r '[(.prerelease or .draft), .published_at] | @tsv' ;;
  esac
}

# releases PRODUCT -> "<version><TAB><created>" for recent stable releases.
releases() {
  local up; up="$(trust "$1" upstream)"
  case "$up" in
    hashicorp)
      api_get "https://api.releases.hashicorp.com/v1/releases/$1?limit=20" |
        jq -r '.[] | select(.is_prerelease | not) | [.version, .timestamp_created] | @tsv' ;;
    github:*)
      api_get "https://api.github.com/repos/${up#github:}/releases?per_page=30" |
        jq -r '.[] | select((.prerelease or .draft) | not) |
               [(.tag_name | ltrimstr("v")), .published_at] | @tsv' ;;
  esac | grep -E '^[0-9]+\.[0-9]+\.[0-9]+	' || true
}

# age_days ISO8601 -> whole days since then.
age_days() {
  jq -nr --arg t "$1" '(now - ($t | sub("\\.[0-9]+"; "") | fromdateiso8601)) / 86400 | floor'
}

# version_gt A B: A is strictly newer than B.
version_gt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}
