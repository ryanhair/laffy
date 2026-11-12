#!/usr/bin/env bash
# Vendors taffy's generated XML layout fixtures into tests/fixtures/xml.
#
# Usage: scripts/sync-fixtures.sh [taffy-git-ref]
#
# With no argument, re-syncs the commit recorded in tests/fixtures/UPSTREAM.
# The fixtures are generated upstream from Chrome and are the conformance
# spec for laffy, so they are copied verbatim and never edited by hand.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_dir="$repo_root/tests/fixtures"
upstream_file="$fixtures_dir/UPSTREAM"
upstream_url="https://github.com/DioxusLabs/taffy.git"

ref="${1:-}"
if [[ -z "$ref" ]]; then
  if [[ ! -f "$upstream_file" ]]; then
    echo "error: no ref given and $upstream_file does not exist" >&2
    exit 1
  fi
  ref="$(awk -F': ' '$1 == "commit" { print $2 }' "$upstream_file")"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git init -q "$workdir"
git -C "$workdir" remote add origin "$upstream_url"
git -C "$workdir" fetch -q --depth 1 origin "$ref"
git -C "$workdir" checkout -q FETCH_HEAD

commit="$(git -C "$workdir" rev-parse HEAD)"
commit_date="$(git -C "$workdir" log -1 --format=%cs)"
version="$(awk -F'"' '$1 ~ /^version *= *$/ { print $2; exit }' "$workdir/Cargo.toml")"

rm -rf "$fixtures_dir/xml"
mkdir -p "$fixtures_dir/xml"
# Copy only the fixture groups; skip the generated Rust test module (mod.rs).
for group in "$workdir"/tests/xml/*/; do
  cp -R "$group" "$fixtures_dir/xml/$(basename "$group")"
done

count="$(find "$fixtures_dir/xml" -name '*.xml' | wc -l | tr -d ' ')"

cat > "$upstream_file" <<META
repository: $upstream_url
commit: $commit
date: $commit_date
version: $version
fixtures: $count
META

echo "Synced $count fixtures from taffy $version ($commit)"
