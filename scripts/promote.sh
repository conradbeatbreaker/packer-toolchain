#!/usr/bin/env bash
# Promote the pinned toolchain into Nexus packer-hosted.
#
#   promote.sh PROMOTION_JSON
#
# For each component in versions.yaml:
#   - already in packer-hosted: download it from there and re-verify. No
#     upload. This is the normal case for components that didn't change.
#   - otherwise: fetch via the proxy (packer-proxy or github-proxy, per
#     policy/trust.yaml), verify signature and checksum, then upload the
#     zip, SHA256SUMS, .sig and the promotion record to packer-hosted.
#
# The bytes uploaded are the bytes verified, in this job. Redeploy is
# disabled on packer-hosted, so if a file already exists with different
# content this fails loudly instead of overwriting.
#
# Env: NEXUS_URL, NEXUS_USER, NEXUS_PASS (the promote account).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

record="${1:?usage: promote.sh PROMOTION_JSON}"
: "${NEXUS_URL:?}" "${NEXUS_USER:?}" "${NEXUS_PASS:?}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
summary=()

nexus_status() {   # URL -> HTTP status of a HEAD request
  curl -s -o /dev/null -w '%{http_code}' -I -K - "$1" <<<"user = \"$NEXUS_USER:$NEXUS_PASS\""
}
upload() {         # FILE URL
  curl -fsS --retry 3 -o /dev/null -K - --upload-file "$1" "$2" <<<"user = \"$NEXUS_USER:$NEXUS_PASS\""
}
verify_or_die() {  # PRODUCT VERSION DIR ZIP WHERE
  local sums; sums="$3/$(sums_name "$1" "$2")"
  verify_signature "$1" "$sums" "$sums.sig" ||
    die "$1 $2 ($5): SHA256SUMS signature is not valid for $(key_fingerprint "$1")"
  verify_checksum "$sums" "$3/$4" ||
    die "$1 $2 ($5): $4 does not match the signed SHA256SUMS"
}

while IFS=$'\t' read -r product version _; do
  hosted="$(hosted_base "$product" "$version")"
  sums="$(sums_name "$product" "$version")"

  if [[ "$(nexus_status "$hosted/$sums")" == 200 && "$(nexus_status "$hosted/promotion.json")" == 200 ]]; then
    dir="$work/hosted/$product"
    zip="$(fetch_release "$hosted" "$dir" "$product" "$version" "$NEXUS_USER" "$NEXUS_PASS")" ||
      die "$product $version: in packer-hosted but incomplete"
    verify_or_die "$product" "$version" "$dir" "$zip" "packer-hosted"
    summary+=("| \`$product\` | $version | already in packer-hosted, re-verified |")
    continue
  fi

  dir="$work/proxy/$product"
  zip="$(fetch_release "$(proxy_base "$product" "$version")" "$dir" "$product" "$version" "$NEXUS_USER" "$NEXUS_PASS")" ||
    die "$product $version: could not fetch via $(proxy_base "$product" "$version")"
  verify_or_die "$product" "$version" "$dir" "$zip" "via proxy"

  jq --arg p "$product" --arg v "$version" --arg z "$zip" \
     --arg h "$(sha256 "$dir/$zip")" --arg k "$(key_fingerprint "$product")" \
     '{component: $p, version: $v, artifact: $z, sha256: $h, signing_key: $k} + .' \
     "$record" > "$dir/promotion.json"

  # promotion.json last: its presence marks a complete promotion.
  for f in "$zip" "$sums" "$sums.sig" promotion.json; do
    case "$(nexus_status "$hosted/$f")" in
      200)
        # Left over from an interrupted run. Accept only identical bytes.
        fetch "$hosted/$f" "$work/existing" "$NEXUS_USER" "$NEXUS_PASS"
        [[ "$(sha256 "$work/existing")" == "$(sha256 "$dir/$f")" || "$f" == promotion.json ]] ||
          die "$product $version: packer-hosted already has a different $f. Investigate before touching it."
        ;;
      404) upload "$dir/$f" "$hosted/$f" || die "$product $version: upload of $f failed" ;;
      *)   die "$product $version: unexpected status checking $hosted/$f" ;;
    esac
  done
  summary+=("| \`$product\` | $version | **promoted** (\`$zip\`, sha256 \`$(sha256 "$dir/$zip" | cut -c1-12)…\`) |")
done < <(components)

report="$(printf '%s\n' "### Promotion" "" "Approved by **$(jq -r .approved_by "$record")** · [PR]($(jq -r .pull_request "$record")) · [run]($(jq -r .run "$record"))" "" \
  "| Component | Version | Result |" "| --- | --- | --- |" "${summary[@]}")"
echo "$report"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$report" >> "$GITHUB_STEP_SUMMARY"
exit 0
