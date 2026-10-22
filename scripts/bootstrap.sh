#!/usr/bin/env bash
# Install the pinned Packer and plugins from Nexus packer-hosted, on a build
# runner. Called from image repos, with this repo checked out at the commit
# in their .toolchain-sha, so versions, keys and this script all come from
# one approved commit.
#
# For each component: download the zip, SHA256SUMS and .sig from
# packer-hosted, verify the signature against the key pinned in
# policy/trust.yaml and the zip against the sums file, then install.
# Any mismatch fails the job. Nothing is fetched from the internet and
# `packer init` is never run.
#
# This is the provenance check. Packer's own SHA256SUM sidecar check at
# plugin load time is separate: the sidecar is written at install time
# from whatever binary was installed, so it proves the file hasn't changed
# on disk since, not where it came from.
#
# Env: NEXUS_URL, NEXUS_USER, NEXUS_PASS (the CI account, read-only).
# Exports to later steps: PATH (packer), PACKER_PLUGIN_PATH,
# PACKER_CHECKPOINT_DISABLE.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

: "${NEXUS_URL:?}" "${NEXUS_USER:?}" "${NEXUS_PASS:?}"
dest="${RUNNER_TEMP:-$(mktemp -d)}/packer-toolchain"
rm -rf "$dest"
mkdir -p "$dest/bin" "$dest/plugins" "$dest/dl"
export PACKER_PLUGIN_PATH="$dest/plugins" PACKER_CHECKPOINT_DISABLE=1

while IFS=$'\t' read -r product version source; do
  dir="$dest/dl/$product"
  zip="$(fetch_release "$(hosted_base "$product" "$version")" "$dir" "$product" "$version" "$NEXUS_USER" "$NEXUS_PASS")" ||
    die "$product $version is not in packer-hosted. Has it been promoted?"
  sums="$dir/$(sums_name "$product" "$version")"
  verify_signature "$product" "$sums" "$sums.sig" ||
    die "$product $version: SHA256SUMS signature is not valid for $(key_fingerprint "$product")"
  verify_checksum "$sums" "$dir/$zip" ||
    die "$product $version: $zip does not match the signed SHA256SUMS"
  echo "Verified $zip"

  if [[ "$product" == "packer" ]]; then
    unzip -q -o "$dir/$zip" packer -d "$dest/bin"
    got="$("$dest/bin/packer" version | head -1)"
    [[ "$got" == "Packer v$version" ]] || die "expected Packer v$version, binary reports '$got'"
  else
    unzip -q -o "$dir/$zip" -d "$dir/bin"
    bin="$(find "$dir/bin" -maxdepth 1 -type f -name "${product}_v*" | head -1)"
    [[ -n "$bin" ]] || die "$zip contains no plugin binary"
    "$dest/bin/packer" plugins install --path "$bin" "$source"
  fi
done < <(components)

"$dest/bin/packer" plugins installed

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "$dest/bin" >> "$GITHUB_PATH"
  { echo "PACKER_PLUGIN_PATH=$dest/plugins"; echo "PACKER_CHECKPOINT_DISABLE=1"; } >> "$GITHUB_ENV"
fi
