#!/usr/bin/env bash
# List github-pages (or --environment) deployments and prune per --mode.
# Also sweeps stale records: refs that no longer exist as a branch or tag
# (e.g. a PR closed while its closed-event run never reached this job).
# Soft-fail: API/per-id errors are logged; exit 0 unless bad args.
# Usage:
#   upsert.sh --owner O --repo R --ref REF --mode replace|purge
#             [--environment github-pages] [--protect-ref REF ...]
# Requires: gh, jq, GH_TOKEN (or gh auth)
set -euo pipefail

owner=""
repo=""
ref=""
mode=""
environment="github-pages"
protect_refs=()

usage() {
  echo "Usage: $0 --owner O --repo R --ref REF --mode replace|purge [--environment ENV] [--protect-ref REF ...]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) owner="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --ref) ref="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --environment) environment="${2:-}"; shift 2 ;;
    --protect-ref) protect_refs+=("${2:-}"); shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$owner" && -n "$repo" && -n "$ref" && -n "$mode" ]] || usage
[[ "$mode" == "replace" || "$mode" == "purge" ]] || usage

script_dir="$(cd "$(dirname "$0")" && pwd -P)"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/upsert-deployments.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
list_file="$tmpdir/list.json"

set +e
gh api --paginate \
  "repos/${owner}/${repo}/deployments?environment=${environment}&per_page=100" \
  >"$list_file" 2>"$tmpdir/list.err"
list_rc=$?
set -e

if [[ "$list_rc" -ne 0 ]]; then
  echo "warning: failed to list deployments (exit $list_rc); skipping upsert" >&2
  cat "$tmpdir/list.err" >&2 || true
  exit 0
fi

# --paginate may concatenate JSON arrays; normalize to one array
if ! jq -s 'add // []' "$list_file" >"$tmpdir/all.json" 2>/dev/null; then
  # single array page
  cp "$list_file" "$tmpdir/all.json"
fi

select_args=(--ref "$ref" --mode "$mode")
for p in "${protect_refs[@]+"${protect_refs[@]}"}"; do
  [[ -n "$p" ]] || continue
  select_args+=(--protect-ref "$p")
done

# delete_ids <ids-text> <ref> <mode>: mark each deployment inactive, then delete it.
delete_ids() {
  local ids="$1" target_ref="$2" target_mode="$3" id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    echo "upsert-deployments: deleting deployment $id (ref=$target_ref mode=$target_mode)"
    set +e
    gh api -X POST "repos/${owner}/${repo}/deployments/${id}/statuses" \
      -f state=inactive \
      -f description="upsert-deployments ${target_mode}" >/dev/null 2>"$tmpdir/status.err"
    gh api -X DELETE "repos/${owner}/${repo}/deployments/${id}" \
      >/dev/null 2>"$tmpdir/del.err"
    local del_rc=$?
    set -e
    if [[ "$del_rc" -ne 0 ]]; then
      echo "warning: failed to delete deployment $id" >&2
      cat "$tmpdir/del.err" >&2 || true
    fi
  done <<<"$ids"
}

if ! ids="$("$script_dir/select_ids.sh" "${select_args[@]}" <"$tmpdir/all.json")"; then
  echo "warning: select_ids failed; skipping upsert" >&2
  exit 0
fi
if [[ -z "${ids}" ]]; then
  echo "upsert-deployments: nothing to delete for ref=$ref mode=$mode"
else
  delete_ids "$ids" "$ref" "$mode"
fi

# --- sweep stale refs -------------------------------------------------------
# Any deployment ref with no matching branch or tag is orphaned: purge it.
# Protected refs are never swept. Soft-fail if the branch/tag listing fails.
set +e
gh api --paginate "repos/${owner}/${repo}/branches?per_page=100" --jq '.[].name' \
  >"$tmpdir/branches.txt" 2>"$tmpdir/branches.err"
branches_rc=$?
gh api --paginate "repos/${owner}/${repo}/tags?per_page=100" --jq '.[].name' \
  >>"$tmpdir/branches.txt" 2>>"$tmpdir/branches.err"
tags_rc=$?
set -e

if [[ "$branches_rc" -ne 0 || "$tags_rc" -ne 0 ]]; then
  echo "warning: failed to list branches/tags (exit $branches_rc/$tags_rc); skipping sweep" >&2
  cat "$tmpdir/branches.err" >&2 || true
  exit 0
fi

# Distinct deployment refs (heads/ prefix stripped), minus existing names and protected refs.
protect_lines=""
for p in "${protect_refs[@]+"${protect_refs[@]}"}"; do
  [[ -n "$p" ]] && protect_lines+="${p#refs/heads/}"$'\n'
done

stale_refs="$(jq -r '.[] | (.ref // "") | sub("^refs/heads/"; "")' "$tmpdir/all.json" \
  | sort -u \
  | grep -v '^$' \
  | grep -vxF -f "$tmpdir/branches.txt" || true)"

while IFS= read -r stale; do
  [[ -n "$stale" ]] || continue
  if [[ -n "$protect_lines" ]] && grep -qxF "$stale" <<<"$protect_lines"; then
    continue
  fi
  if [[ "$stale" == "$ref" ]]; then
    continue # already handled above
  fi
  stale_args=(--ref "$stale" --mode purge)
  for p in "${protect_refs[@]+"${protect_refs[@]}"}"; do
    [[ -n "$p" ]] || continue
    stale_args+=(--protect-ref "$p")
  done
  if ! stale_ids="$("$script_dir/select_ids.sh" "${stale_args[@]}" <"$tmpdir/all.json")"; then
    echo "warning: select_ids failed for stale ref $stale; skipping" >&2
    continue
  fi
  echo "upsert-deployments: sweeping stale ref $stale (no branch or tag)"
  delete_ids "$stale_ids" "$stale" purge
done <<<"$stale_refs"

exit 0
