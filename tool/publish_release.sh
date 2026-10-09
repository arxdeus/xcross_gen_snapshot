#!/usr/bin/env bash
# Publishes $DIST (the 8 compiler zips + manifest.json) as the GitHub release
# $TAG. Run by the publish job of .github/workflows/gen_snapshot.yml only.
#
#   no release      -> create a draft, upload everything (manifest last),
#                      check the uploaded digests, publish.
#   draft           -> a previous run stopped half way: upload what is
#                      missing or different (manifest last), check, publish.
#   published, same manifest      -> nothing to do (assets are checked).
#   published, different manifest -> fail, unless REPLACE=true (only set by
#                      the workflow_dispatch replace path): then the zips and
#                      then manifest.json are overwritten in place. Between
#                      the first zip and the manifest upload (seconds) the
#                      published zips do not match the published manifest;
#                      xcross checks every download against the manifest and
#                      fails closed in that window.
#
# Env: TAG, TITLE, NOTES, GITHUB_REPOSITORY, GH_TOKEN; optional DIST (default
# dist) and REPLACE (default false).
set -euo pipefail

: "${TAG:?}" "${TITLE:?}" "${NOTES:?}" "${GITHUB_REPOSITORY:?}"
dist=${DIST:-dist}
replace=${REPLACE:-false}

retry() {
  local i
  for i in 1 2 3 4 5; do
    "$@" && return 0
    echo "attempt $i of: $* failed" >&2
    sleep $((i * 10))
  done
  return 1
}

fail() {
  echo "::error::$*"
  exit 1
}

shopt -s nullglob
zips=("$dist"/gen_snapshot-*.zip)
[ "${#zips[@]}" -eq 8 ] || fail "expected 8 zips in $dist, found ${#zips[@]}"
[ -f "$dist/manifest.json" ] || fail "$dist/manifest.json is missing"
# manifest.json goes last: it is what xcross reads first.
files=("${zips[@]}" "$dist/manifest.json")

# The release of $TAG as REST JSON (drafts included), empty if there is none.
release_json() {
  local all
  all=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$TAG\")") || return 1
  local count
  count=$(jq -s length <<<"$all")
  if [ "$count" -gt 1 ]; then
    echo "::error::$count releases use tag $TAG" >&2
    return 2
  fi
  printf '%s' "$all"
}

fetch_release() {
  local out
  for i in 1 2 3 4 5; do
    if out=$(release_json); then
      printf '%s' "$out"
      return 0
    elif [ $? -eq 2 ]; then
      return 1
    fi
    sleep $((i * 10))
  done
  return 1
}

remote_digest() { # <release json> <asset name>
  jq -r --arg n "$2" '.assets[]? | select(.name == $n) | .digest // empty' <<<"$1"
}

local_digest() { echo "sha256:$(sha256sum "$1" | cut -d' ' -f1)"; }

# Uploads every file whose release asset is missing or has other bytes.
upload_changed() {
  local json f name
  json=$(fetch_release) || fail "cannot read release $TAG"
  for f in "${files[@]}"; do
    name=$(basename "$f")
    if [ "$(remote_digest "$json" "$name")" = "$(local_digest "$f")" ]; then
      echo "$name: already uploaded"
    else
      echo "$name: uploading"
      retry gh release upload "$TAG" "$f" --clobber
    fi
  done
}

# Fails unless every release asset has exactly the bytes in $dist.
check_uploaded() {
  local json f name want have
  json=$(fetch_release) || fail "cannot read release $TAG"
  for f in "${files[@]}"; do
    name=$(basename "$f")
    want=$(local_digest "$f")
    have=$(remote_digest "$json" "$name")
    [ "$have" = "$want" ] || fail "$name on release $TAG is ${have:-missing}, expected $want"
  done
  echo "all ${#files[@]} assets of $TAG match $dist"
}

create_draft() {
  # Never create a second draft if a failed attempt actually got through.
  [ -n "$(fetch_release)" ] && return 0
  gh release create "$TAG" --verify-tag --draft --title "$TITLE" --notes "$NOTES"
}

json=$(fetch_release) || fail "cannot read release $TAG"
if [ -z "$json" ]; then
  state=none
elif [ "$(jq -r .draft <<<"$json")" = true ]; then
  state=draft
else
  state=published
fi
echo "release $TAG: $state (replace=$replace)"

case $state in
  none | draft)
    if [ "$state" = none ]; then
      retry create_draft
    else
      echo "finishing the draft release of a previous run"
      retry gh release edit "$TAG" --title "$TITLE" --notes "$NOTES"
    fi
    upload_changed
    check_uploaded
    retry gh release edit "$TAG" --draft=false
    ;;
  published)
    rm -f published-manifest.json
    if [ -n "$(remote_digest "$json" manifest.json)" ]; then
      retry gh release download "$TAG" -p manifest.json -O published-manifest.json --clobber
    fi
    if [ -f published-manifest.json ] && cmp -s published-manifest.json "$dist/manifest.json"; then
      echo "release $TAG is published with this exact manifest"
      check_uploaded
      exit 0
    fi
    echo "published manifest.json differs from the new one:"
    diff -u published-manifest.json "$dist/manifest.json" || true
    if [ "$replace" != true ]; then
      fail "release $TAG is already published with a different manifest; refusing to replace it. To overwrite it on purpose, run the workflow manually with flutter=$TAG and replace_release=true."
    fi
    echo "replacing the assets of the published release $TAG (replace_release=true)"
    retry gh release edit "$TAG" --title "$TITLE" --notes "$NOTES"
    upload_changed
    check_uploaded
    ;;
esac

json=$(fetch_release) || fail "cannot read release $TAG"
[ "$(jq -r .draft <<<"$json")" = false ] || fail "release $TAG is still a draft"
gh release view "$TAG"
