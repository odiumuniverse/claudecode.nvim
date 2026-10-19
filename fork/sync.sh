#!/usr/bin/env bash
# Rebase fork commits onto upstream/main and recreate the cleanup commit on top.
#
#   fork/sync.sh             fetch upstream, drop the cleanup commit, rebase, redo cleanup
#   fork/sync.sh --continue  redo cleanup after a stopped rebase was finished by hand
#   fork/sync.sh --cleanup   only (re)create the cleanup commit
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

subject="fork: remove upstream release and agent tooling"
list="fork/cleanup.txt"

die() {
  echo "sync: $*" >&2
  exit 1
}

rebase_in_progress() {
  [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]
}

cleanup() {
  local paths=() line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    paths+=("$line")
  done <"$list"

  git rm -r -q --ignore-unmatch -- "${paths[@]}"
  if git diff --cached --quiet; then
    echo "sync: nothing to clean"
    return
  fi
  git commit -q -m "$subject"
  echo "sync: cleanup commit $(git rev-parse --short HEAD)"
}

# The cleanup commit may sit anywhere in our series once new commits land on top of it.
drop_cleanup() {
  local sha
  sha=$(git log --format=%H --fixed-strings --grep="$subject" upstream/main..HEAD)
  [[ -z "$sha" ]] && return
  [[ $(wc -l <<<"$sha") -gt 1 ]] && die "several cleanup commits: $sha"
  git rebase -q --onto "$sha^" "$sha"
}

case "${1:-}" in
--continue)
  rebase_in_progress && die "finish the rebase first: git rebase --continue"
  cleanup
  ;;
--cleanup)
  cleanup
  ;;
"")
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "commit or stash your changes first"
  fi
  git fetch -q upstream
  drop_cleanup
  if ! git rebase -q upstream/main; then
    die "rebase stopped on a conflict: resolve it, run 'git rebase --continue', then 'fork/sync.sh --continue'"
  fi
  cleanup
  echo "sync: done, publish with: git push --force-with-lease origin HEAD"
  ;;
*)
  die "unknown argument: $1"
  ;;
esac
