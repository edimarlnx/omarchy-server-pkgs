#!/bin/bash

# Vendor the server profile from the omarchy-server lab repository into
# server-profile/, so a CI runner that only checks out THIS repository has
# everything the PKGBUILDs need.
#
#   ./scripts/sync-overlay.sh            # copy from ../omarchy-server
#   OMARCHY_SERVER_DIR=/path ./scripts/sync-overlay.sh
#
# The four directories copied are exactly the ones the overlay tarball carries
# (see scripts/build.sh):
#
#   overlay/        settings replacements, runtime commands, install/server, patches
#   addons/         the server addon package lists (also read by the ISO builder)
#   branding/       the Limine wallpaper
#   router-addons/  the ROUTER addon package lists, from profile/router/addons
#   migrations-allow  the upstream-migration allowlist (a single file, not a
#                   directory: it is profile POLICY the maintainer edits, and
#                   the runtime package installs it as
#                   install/server/migrations-allow)
#
# router-addons/ is vendored under a name of its own because both profiles call
# the directory `addons` in the lab repository. The runtime package unpacks it
# to install/router/addons/, which is where omarchy-server-addon looks first on
# a machine whose /etc/omarchy-profile says `router`.
#
# The lab repository stays the source of truth for the profile's content; this
# repository is the source of truth for how it is packaged. Run this before
# committing whenever the profile changed, and commit the result.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
server_dir=${OMARCHY_SERVER_DIR:-$repo_root/../omarchy-server}
source_dir="$server_dir/profile/server"
router_dir="$server_dir/profile/router"
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

[[ -d $router_dir/addons ]] || { echo "Error: missing $router_dir/addons" >&2; exit 1; }
rsync -a --delete "$router_dir/addons/" "$target_dir/router-addons/"

[[ -f $source_dir/migrations-allow ]] ||
  { echo "Error: missing $source_dir/migrations-allow" >&2; exit 1; }
rsync -a "$source_dir/migrations-allow" "$target_dir/migrations-allow"

echo "Synced $source_dir -> $target_dir"
echo "Synced $router_dir/addons -> $target_dir/router-addons"
git -C "$repo_root" status --short -- server-profile || true
