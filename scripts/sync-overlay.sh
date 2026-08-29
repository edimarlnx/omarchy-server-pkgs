#!/bin/bash

# Vendor the server profile from the omarchy-server lab repository into
# server-profile/, so a CI runner that only checks out THIS repository has
# everything the PKGBUILDs need.
#
#   ./scripts/sync-overlay.sh            # copy from ../omarchy-server
#   OMARCHY_SERVER_DIR=/path ./scripts/sync-overlay.sh
#
# The three directories copied are exactly the ones the overlay tarball carries
# (see scripts/build.sh):
#
#   overlay/   settings replacements, runtime commands, install/server, patches
#   addons/    the addon package lists (also read by the ISO builder)
#   branding/  the Limine wallpaper
#
# The lab repository stays the source of truth for the profile's content; this
# repository is the source of truth for how it is packaged. Run this before
# committing whenever the profile changed, and commit the result.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
server_dir=${OMARCHY_SERVER_DIR:-$repo_root/../omarchy-server}
source_dir="$server_dir/profile/server"
target_dir="$repo_root/server-profile"

if [[ ! -d $source_dir ]]; then
  echo "Error: $source_dir does not exist (set OMARCHY_SERVER_DIR)." >&2
  exit 1
fi

command -v rsync >/dev/null || { echo "Error: rsync is required." >&2; exit 1; }

install -d "$target_dir"
for dir in overlay addons branding; do
  [[ -d $source_dir/$dir ]] || { echo "Error: missing $source_dir/$dir" >&2; exit 1; }
  rsync -a --delete "$source_dir/$dir/" "$target_dir/$dir/"
done

echo "Synced $source_dir -> $target_dir"
git -C "$repo_root" status --short -- server-profile || true
