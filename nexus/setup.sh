#!/usr/bin/env bash
# Create the Nexus repositories, roles and service accounts for the Packer
# toolchain. Idempotent: anything that already exists is left alone (and
# reported), so check the settings by hand if it was created earlier.
#
#   NEXUS_URL=http://10.10.1.117:8081 \
#   NEXUS_ADMIN_USER=admin NEXUS_ADMIN_PASS=... \
#   CI_PASS=... PROMOTE_PASS=... \
#   nexus/setup.sh
#
# Shape (no group repository; CI must not be able to reach a proxy):
#
#   packer-hosted  raw hosted  redeploy disabled, strict content type off
#                              CI: read+browse   promote: read+browse+add+edit
#   packer-proxy   raw proxy   https://releases.hashicorp.com/
#   github-proxy   raw proxy   https://github.com/   (vSphere plugin)
#                              promote: read+browse   CI: nothing
#
# Nexus checks `edit` for a PUT upload (`add` covers the components API),
# so promote needs both. That does not allow overwriting: redeploy-disabled
# is enforced by the repository whatever the privileges. It stops overwrite,
# not delete-then-reupload, so nobody gets delete; the privilege model is
# what makes hosted immutable. Keep delete for a named break-glass account.
#
# Strict content type validation is off on purpose: it is a format check,
# not an integrity control, and it rejects the extensionless SHA256SUMS
# files. Integrity comes from signature + checksum verification.
set -euo pipefail

: "${NEXUS_URL:?}" "${NEXUS_ADMIN_USER:?}" "${NEXUS_ADMIN_PASS:?}" "${CI_PASS:?}" "${PROMOTE_PASS:?}"
BLOB_STORE="${BLOB_STORE:-default}"
CI_USER="${CI_USER:-packer-ci}"
PROMOTE_USER="${PROMOTE_USER:-packer-promote}"

api() {  # METHOD PATH [JSON]
  curl -fsS -X "$1" -K - -H 'Content-Type: application/json' \
    ${3:+--data "$3"} "$NEXUS_URL/service/rest$2" <<<"user = \"$NEXUS_ADMIN_USER:$NEXUS_ADMIN_PASS\""
}
exists() { api GET "$1" >/dev/null 2>&1; }

create() {  # KIND NAME CHECK_PATH CREATE_PATH JSON (does not update an existing one)
  if exists "$3"; then echo "exists:  $1 $2"; else api POST "$4" "$5" >/dev/null; echo "created: $1 $2"; fi
}

proxy_json() {  # NAME REMOTE
  jq -n --arg n "$1" --arg r "$2" --arg b "$BLOB_STORE" '{
    name: $n, online: true,
    storage: {blobStoreName: $b, strictContentTypeValidation: false},
    proxy: {remoteUrl: $r, contentMaxAge: -1, metadataMaxAge: 1440},
    negativeCache: {enabled: true, timeToLive: 60},
    httpClient: {blocked: false, autoBlock: true},
    raw: {contentDisposition: "ATTACHMENT"}
  }'
}

create repository packer-hosted /v1/repositories/raw/hosted/packer-hosted /v1/repositories/raw/hosted \
  "$(jq -n --arg b "$BLOB_STORE" '{
    name: "packer-hosted", online: true,
    storage: {blobStoreName: $b, strictContentTypeValidation: false, writePolicy: "allow_once"},
    raw: {contentDisposition: "ATTACHMENT"}
  }')"
create repository packer-proxy /v1/repositories/raw/proxy/packer-proxy /v1/repositories/raw/proxy \
  "$(proxy_json packer-proxy https://releases.hashicorp.com/)"
create repository github-proxy /v1/repositories/raw/proxy/github-proxy /v1/repositories/raw/proxy \
  "$(proxy_json github-proxy https://github.com/)"

priv() { echo "nx-repository-view-raw-$1-$2"; }

create role packer-ci /v1/security/roles/packer-ci /v1/security/roles \
  "$(jq -n --arg r "$(priv packer-hosted read)" --arg b "$(priv packer-hosted browse)" '{
    id: "packer-ci", name: "packer-ci",
    description: "Packer build runners: read approved artifacts from packer-hosted only",
    privileges: [$r, $b], roles: []
  }')"
create role packer-promote /v1/security/roles/packer-promote /v1/security/roles \
  "$(jq -n --args '{
    id: "packer-promote", name: "packer-promote",
    description: "Promotion job: fetch via proxies, upload new artifacts to packer-hosted. No delete.",
    privileges: $ARGS.positional, roles: []
  }' "$(priv packer-hosted read)" "$(priv packer-hosted browse)" "$(priv packer-hosted add)" "$(priv packer-hosted edit)" \
     "$(priv packer-proxy read)" "$(priv packer-proxy browse)" \
     "$(priv github-proxy read)" "$(priv github-proxy browse)")"

user_json() {  # ID PASS ROLE
  jq -n --arg u "$1" --arg p "$2" --arg r "$3" '{
    userId: $u, firstName: $u, lastName: "service", emailAddress: ($u + "@invalid.local"),
    password: $p, status: "active", roles: [$r]
  }'
}
# Users have no single-user GET; search by id.
if api GET "/v1/security/users?userId=$CI_USER" | jq -e --arg u "$CI_USER" 'any(.[]; .userId == $u)' >/dev/null; then
  echo "exists:  user $CI_USER"
else
  api POST /v1/security/users "$(user_json "$CI_USER" "$CI_PASS" packer-ci)" >/dev/null; echo "created: user $CI_USER"
fi
if api GET "/v1/security/users?userId=$PROMOTE_USER" | jq -e --arg u "$PROMOTE_USER" 'any(.[]; .userId == $u)' >/dev/null; then
  echo "exists:  user $PROMOTE_USER"
else
  api POST /v1/security/users "$(user_json "$PROMOTE_USER" "$PROMOTE_PASS" packer-promote)" >/dev/null; echo "created: user $PROMOTE_USER"
fi

cat <<EOF

Done. Still to do by hand:
  - Delete packer-group if it exists. No group repository in this design.
  - Disable anonymous access (Security > Anonymous Access). With it on,
    the "CI gets 404 for an unapproved version" evidence proves nothing
    about what an unauthenticated client can read.
  - Evidence check, as $CI_USER (expect 404):
      curl -su "$CI_USER:\$CI_PASS" -o /dev/null -w '%{http_code}\n' \\
        "$NEXUS_URL/repository/packer-hosted/packer/1.99.0/packer_1.99.0_linux_amd64.zip"
  - And that CI can't reach the proxy at all (expect 403):
      curl -su "$CI_USER:\$CI_PASS" -o /dev/null -w '%{http_code}\n' \\
        "$NEXUS_URL/repository/packer-proxy/packer/1.16.0/packer_1.16.0_SHA256SUMS"
  - Check github-proxy follows GitHub's redirect to its asset storage
      (expect 200), as $PROMOTE_USER:
      curl -su "$PROMOTE_USER:\$PROMOTE_PASS" -o /dev/null -w '%{http_code}\n' \\
        "$NEXUS_URL/repository/github-proxy/vmware/packer-plugin-vsphere/releases/download/v2.5.0/packer-plugin-vsphere_v2.5.0_SHA256SUMS"
EOF
