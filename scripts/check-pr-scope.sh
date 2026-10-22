#!/usr/bin/env bash
# Fail if a bump PR touches anything other than versions.yaml and waivers/.
#
#   check-pr-scope.sh BASE_SHA
#
# A routine bump touches versions.yaml. A soak waiver PR touches
# versions.yaml plus one file in waivers/, and CODEOWNERS then requires
# both the toolchain approvers and the waiver approvers. Anything else in
# the diff (the gate, the keys, the trust policy, workflows) means this is
# not a bump and must not be reviewable as one.
#
# This does not stop a PR that only edits gate.sh or a key; CODEOWNERS
# routes those to the security team.
set -euo pipefail

base="${1:?usage: check-pr-scope.sh BASE_SHA}"

# --no-renames so a rename shows both the old and the new path.
changed="$(git diff --no-renames --name-only "$base" HEAD)"
[[ -n "$changed" ]] || { echo "No changes against $base."; exit 0; }

bad=()
while IFS= read -r path; do
  [[ "$path" == "versions.yaml" || "$path" =~ ^waivers/[^/]+\.yaml$ ]] || bad+=("$path")
done <<<"$changed"

echo "Changed paths:"
while IFS= read -r path; do echo "  $path"; done <<<"$changed"

if (( ${#bad[@]} )); then
  echo "::error::A bump PR may only touch versions.yaml and waivers/*.yaml. Out of scope:"
  printf '  %s\n' "${bad[@]}"
  echo "Split gate, key, policy or workflow changes into their own PR."
  exit 1
fi
echo "Scope OK."
