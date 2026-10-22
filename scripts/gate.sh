#!/usr/bin/env bash
# Gate: the six criteria for the toolchain pinned in versions.yaml.
#
#   gate.sh [BASE_REF]
#
# BASE_REF is the commit to compare against (what changed, and criterion 4).
# Defaults to HEAD^1.
#
# Criteria 1, 2 and 6 run for every component every time: they are cheap,
# and criterion 6 depends on the Packer/plugin combination, not one version.
# Criteria 3, 4 and 5 only make sense for a version that changed.
#
#   1. SHA256SUMS signature valid against the key pinned in policy/trust.yaml
#   2. artifact checksum matches the signed sums file
#   3. stable release, not a prerelease
#   4. version moves forward only
#   5. release is at least min_soak_days old (the only waivable criterion)
#   6. plugin API version matches versions.yaml and the pinned Packer
#      accepts the plugin (`packer plugins install --path`)
#
# Criteria 1 and 2 are never waivable. Criterion 5 can be waived only by a
# file in waivers/ that names this exact component and version and has not
# expired.
#
# Writes a markdown report to $GITHUB_OUTPUT as `report` (and to the job
# summary), exits non-zero if anything failed.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

base="${1:-HEAD^1}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git -C "$ROOT" show "$base:versions.yaml" > "$work/base.yaml" 2>/dev/null || : > "$work/base.yaml"
min_soak="$(min_soak_days)"
today="$(date -u +%Y-%m-%d)"

PASS="✅" FAIL="❌" NA="➖" WAIVED="⚠️"
failed=0
rows=()
notes=()
packer_bin=""

note() { notes+=("- **$1 $2**: $3"); }

# waiver_for PRODUCT VERSION: sets $waiver to a valid waiver file, or "".
# Rejected waivers are explained in the notes so nobody wonders why theirs
# was ignored. (Sets a variable rather than printing, so the notes aren't
# lost in a subshell.)
waiver_for() {
  local product="$1" version="$2" f comp ver exp
  waiver=""
  for f in "$ROOT"/waivers/*.yaml; do
    [[ -e "$f" ]] || continue
    comp="$(yq -r '.component // ""' "$f")"
    ver="$(yq -r '.version // ""' "$f")"
    [[ "$comp" == "$product" ]] || continue
    if [[ "$ver" != "$version" ]]; then
      note "$product" "$version" "waiver \`${f#"$ROOT"/}\` ignored: it is for version $ver"
      continue
    fi
    exp="$(yq -r '.expires // ""' "$f")"
    if [[ -z "$(yq -r '.cve // ""' "$f")" || -z "$(yq -r '.applicability // ""' "$f")" ]]; then
      note "$product" "$version" "waiver \`${f#"$ROOT"/}\` ignored: \`cve\` and \`applicability\` are required"
    elif ! [[ "$exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      note "$product" "$version" "waiver \`${f#"$ROOT"/}\` ignored: \`expires\` must be YYYY-MM-DD"
    elif [[ "$exp" < "$today" ]]; then
      note "$product" "$version" "waiver \`${f#"$ROOT"/}\` ignored: expired $exp"
    else
      waiver="$f"
      return
    fi
  done
}

while IFS=$'\t' read -r product version source; do
  c1="$FAIL" c2="$FAIL" c3="$NA" c4="$NA" c5="$NA" c6="$NA"
  dir="$work/$product"
  old="$(version_in "$work/base.yaml" "$product")"

  # Policy: the component must be known, and a plugin's source address must
  # be the one security approved. Otherwise a bump could point at another
  # namespace or an unvetted plugin.
  if [[ -z "$(trust "$product" upstream)" || -z "$(key_fingerprint "$product")" ]]; then
    note "$product" "$version" "not in policy/trust.yaml (no upstream or key) — needs a security-owned policy change first"
    rows+=("| \`$product\` | $version | $FAIL | $FAIL | $NA | $NA | $NA | $NA |")
    failed=1; continue
  fi
  if [[ "$source" != "-" && "$source" != "$(trust "$product" source)" ]]; then
    note "$product" "$version" "source \`$source\` does not match policy/trust.yaml (\`$(trust "$product" source)\`)"
    rows+=("| \`$product\` | $version | $FAIL | $FAIL | $NA | $NA | $NA | $NA |")
    failed=1; continue
  fi

  # Criteria 1 and 2
  if ! zip="$(fetch_release "$(upstream_base "$product" "$version")" "$dir" "$product" "$version")"; then
    note "$product" "$version" "could not download SHA256SUMS, signature or ${PLATFORM} zip from upstream"
  else
    sums="$dir/$(sums_name "$product" "$version")"
    if verify_signature "$product" "$sums" "$sums.sig"; then
      c1="$PASS"
      if verify_checksum "$sums" "$dir/$zip"; then
        c2="$PASS"
      else
        note "$product" "$version" "\`$zip\` does not match the signed SHA256SUMS"
      fi
    else
      note "$product" "$version" "SHA256SUMS signature is not a valid signature from $(key_fingerprint "$product")"
      note "$product" "$version" "checksum not evaluated: the sums file itself is untrusted"
    fi
  fi

  # Criteria 3, 4, 5: only for a version that moved.
  if [[ "$version" != "$old" ]]; then
    if meta="$(release_meta "$product" "$version")" && [[ -n "$meta" ]]; then
      IFS=$'\t' read -r prerelease created <<<"$meta"
      if [[ "$prerelease" == "false" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        c3="$PASS"
      else
        c3="$FAIL"; note "$product" "$version" "upstream marks this as a prerelease"
      fi
      age="$(age_days "$created")"
      if (( age >= min_soak )); then
        c5="$PASS"
      elif waiver_for "$product" "$version"; [[ -n "$waiver" ]]; then
        c5="$WAIVED"
        note "$product" "$version" "released $age days ago (< $min_soak); soak waived by \`${waiver#"$ROOT"/}\` for \`$(yq -r .cve "$waiver")\`, expires $(yq -r .expires "$waiver")"
      else
        c5="$FAIL"; note "$product" "$version" "released $age days ago; soak period is $min_soak days"
      fi
    else
      c3="$FAIL" c5="$FAIL"
      note "$product" "$version" "no release metadata upstream — does this version exist?"
    fi

    if [[ -z "$old" ]] || version_gt "$version" "$old"; then
      c4="$PASS"
    else
      c4="$FAIL"; note "$product" "$version" "moves backwards from $old"
    fi
  fi

  # Criterion 6. Binaries are only executed after criteria 1 and 2 passed.
  if [[ "$c1$c2" == "$PASS$PASS" ]]; then
    unzip -q -o "$dir/$zip" -d "$dir/bin"
    if [[ "$product" == "packer" ]]; then
      packer_bin="$dir/bin/packer"
    else
      c6="$FAIL"
      declared="$(yq -r ".plugins.\"${product#packer-plugin-}\".api_version" "$VERSIONS")"
      bin="$(find "$dir/bin" -maxdepth 1 -type f -name "${product}_v*" | head -1)"
      actual="$( [[ -n "$bin" ]] && "$bin" describe 2>/dev/null | jq -r '.api_version // empty' || true)"
      if [[ -z "$actual" ]]; then
        note "$product" "$version" "plugin binary did not answer \`describe\`"
      elif [[ "$actual" != "$declared" ]]; then
        note "$product" "$version" "plugin speaks API $actual, versions.yaml declares $declared"
      elif [[ -z "$packer_bin" ]]; then
        note "$product" "$version" "cannot test compatibility: pinned Packer failed verification"
      elif ! out="$(PACKER_PLUGIN_PATH="$work/plugins" PACKER_CHECKPOINT_DISABLE=1 \
                    "$packer_bin" plugins install --path "$bin" "$source" 2>&1)"; then
        note "$product" "$version" "Packer $(version_in "$VERSIONS" packer) refused the plugin: $(tail -1 <<<"$out")"
      else
        c6="$PASS"
      fi
    fi
  elif [[ "$product" != "packer" ]]; then
    c6="$FAIL"
  fi

  [[ "$c1$c2$c3$c4$c5$c6" == *"$FAIL"* ]] && failed=1
  label="$version"
  [[ "$version" != "$old" ]] && label="**$version** (was ${old:-new})"
  rows+=("| \`$product\` | $label | $c1 | $c2 | $c3 | $c4 | $c5 | $c6 |")
done < <(components)

{
  echo "### Gate criteria"
  echo
  if (( failed )); then echo "**Result: FAIL**"; else echo "**Result: PASS**"; fi
  echo
  echo "| Component | Version | 1 Signature | 2 Checksum | 3 Stable | 4 Forward | 5 Soak ≥ ${min_soak}d | 6 API compat |"
  echo "| --- | --- | :-: | :-: | :-: | :-: | :-: | :-: |"
  printf '%s\n' "${rows[@]}"
  echo
  echo "$PASS pass · $FAIL fail · $WAIVED waived (criterion 5 only) · $NA not applicable (version unchanged)"
  if (( ${#notes[@]} )); then
    echo
    echo "#### Details"
    printf '%s\n' "${notes[@]}"
  fi
  echo
  echo "<sub>Compared against \`$(git -C "$ROOT" rev-parse --short "$base" 2>/dev/null || echo "$base")\`. Keys and soak period from \`policy/trust.yaml\`. Platform: \`$PLATFORM\`.</sub>"
} > "$work/report.md"

cat "$work/report.md"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$work/report.md" >> "$GITHUB_STEP_SUMMARY"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  d="$(delim)"
  { echo "report<<$d"; cat "$work/report.md"; echo "$d"; } >> "$GITHUB_OUTPUT"
fi

exit "$failed"
