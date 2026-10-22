#!/usr/bin/env bash
# Write the promotion record for this run: who approved it, when, and from
# which commit and PR. promote.sh stores it in Nexus next to the artifacts
# as promotion.json.
#
#   record-approval.sh OUT_FILE
#
# The approver is the person who approved the artifact-promotion
# environment for this run, read from the GitHub API. Not github.actor:
# on a push that is whoever merged the PR, which is a different person
# and a different decision.
#
# Refuses (exit 1) if the run has no recorded approval, so a promotion
# can't happen without one even if the environment protection is removed.
#
# Env: GH_TOKEN (needs actions:read), plus the standard GITHUB_* variables.
#
# This used to commit approved_by/approved_at back into versions.yaml. A
# push to main from a workflow needs the Actions bot on the ruleset bypass
# list, and that would let any workflow push to main around the PR gate.
# Nexus is also the better place: redeploy is disabled, so the record
# can't be rewritten after the fact.
set -euo pipefail

out="${1:?usage: record-approval.sh OUT_FILE}"
api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
gh_get() { curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$api/$1"; }

approval="$(gh_get "actions/runs/$GITHUB_RUN_ID/approvals" |
  jq -c '[.[] | select(.state == "approved")] | last // empty')"
[[ -n "$approval" ]] || { echo "::error::No environment approval recorded for run $GITHUB_RUN_ID. Refusing to promote."; exit 1; }

pr="$(gh_get "commits/$GITHUB_SHA/pulls" | jq -r '.[0].html_url // ""')"

jq -n \
  --argjson a "$approval" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg run "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  --arg commit "$GITHUB_SHA" \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg pr "$pr" \
  '{
     approved_by: $a.user.login,
     approval_comment: ($a.comment // ""),
     environment: ([$a.environments[]?.name] | join(",")),
     promoted_at: $at,
     repository: $repo,
     commit: $commit,
     pull_request: $pr,
     run: $run
   }' > "$out"

echo "Approved by $(jq -r .approved_by "$out")"
