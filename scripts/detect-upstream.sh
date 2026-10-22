#!/usr/bin/env bash
# Poll upstream and propose newer versions in versions.yaml.
#
# For each component, proposes the newest stable release that is newer than
# the pin AND already past the soak period, so routine bump PRs can pass the
# gate. Newer releases still soaking are listed in the summary but not
# proposed; pulling one in early is the waiver path, deliberately not this.
#
# For plugins, api_version is read from the release's zip (the binary name
# carries it, e.g. packer-plugin-vsphere_v2.5.0_x5.0_linux_amd64), without
# running anything. The gate re-checks it by executing the verified binary.
#
# Edits versions.yaml in place. Sets outputs `changed` (true|false) and
# `summary` (markdown).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

min_soak="$(min_soak_days)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
changed=false
summary=()

# api_version_of PRODUCT VERSION -> e.g. x5.0
api_version_of() {
  local base sums zip name
  base="$(upstream_base "$1" "$2")"
  sums="$work/$(sums_name "$1" "$2")"
  fetch "$base/$(basename "$sums")" "$sums" || return 1
  zip="$(zip_name "$sums")" || return 1
  name="$zip"
  if ! [[ "$name" =~ _x[0-9]+\.[0-9]+_ ]]; then
    fetch "$base/$zip" "$work/$zip" || return 1
    name="$(unzip -Z1 "$work/$zip" | grep -E "^${1}_v" | head -1)"
  fi
  [[ "$name" =~ _(x[0-9]+\.[0-9]+)_ ]] && echo "${BASH_REMATCH[1]}"
}

while IFS=$'\t' read -r product current _; do
  candidate="" soaking=()
  while IFS=$'\t' read -r version created; do
    version_gt "$version" "$current" || continue
    age="$(age_days "$created")"
    if (( age >= min_soak )); then
      if [[ -z "$candidate" ]] || version_gt "$version" "$candidate"; then candidate="$version"; fi
    else
      soaking+=("$version (${age}d old)")
    fi
  done < <(releases "$product")

  if [[ -n "$candidate" ]]; then
    V="$candidate" yq -i "$(version_path "$product") = strenv(V)" "$VERSIONS"
    line="- \`$product\`: $current → **$candidate**"
    if [[ "$product" != "packer" ]]; then
      key="${product#packer-plugin-}"
      api="$(api_version_of "$product" "$candidate" || true)"
      if [[ -n "$api" ]]; then
        A="$api" yq -i ".plugins.\"$key\".api_version = strenv(A)" "$VERSIONS"
      else
        line+=" (could not read API version; left unchanged, the gate will check it)"
      fi
    fi
    summary+=("$line")
    changed=true
  fi
  if (( ${#soaking[@]} )); then
    summary+=("- \`$product\`: newer but still inside the ${min_soak}-day soak, not proposed: $(printf '%s, ' "${soaking[@]}" | sed 's/, $//')")
  fi
done < <(components)

(( ${#summary[@]} )) || summary=("Everything is at the newest release past the ${min_soak}-day soak.")
printf '%s\n' "${summary[@]}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  d="$(delim)"
  {
    echo "changed=$changed"
    echo "summary<<$d"
    printf '%s\n' "${summary[@]}"
    echo "$d"
  } >> "$GITHUB_OUTPUT"
fi
