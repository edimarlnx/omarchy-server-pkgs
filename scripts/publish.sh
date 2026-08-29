#!/bin/bash

# Assemble the signed [omarchy-server] pacman database from out/ and publish
# everything as assets of a single, fixed GitHub release tagged `repo`.
#
#   ./scripts/publish.sh              # publish to $GITHUB_REPOSITORY or origin
#   ./scripts/publish.sh --local      # build repo/ and stop, upload nothing
#   ./scripts/publish.sh --dry-run    # build repo/, then say what publishing
#                                     # would upload and delete. Read-only.
#
# Why one fixed tag: pacman needs a stable base URL, and a GitHub release's
# asset URLs are stable per tag
# (https://github.com/<owner>/<repo>/releases/download/repo/<asset>). That is
# exactly the shape of the `Server` line the profile ships, and the same trick
# arch-mact2-mirror uses to serve a pacman repository off GitHub.
#
# Two constraints of release assets shape what is uploaded:
#
#   * assets are flat files, so the `omarchy-server.db` and
#     `omarchy-server.files` that repo-add leaves as SYMLINKS to the .tar.gz
#     are published as real copies. `$repo.db` is the name pacman fetches, so
#     this is not optional.
#   * an asset name is unique per release, so a rebuilt package REPLACES its
#     asset (--clobber).
#
# The database is built FRESH from out/, never by adding this run's packages on
# top of the previously published one. A cumulative database keeps an entry for
# a package that no longer exists: `fwall` was renamed to `tui-firewall`, its
# asset was deleted, and its record survived in the database — every client
# `pacman -Sy` then offered a package whose file was a 404. out/ is therefore
# the whole truth about the repository, which means the publishing path must
# always be fed a COMPLETE build (see the README, "Publishing"), and any asset
# the fresh database does not reference is deleted from the release.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out_dir="$repo_root/out"
repo_dir="$repo_root/repo"
db_name=omarchy-server
tag=${OMARCHY_RELEASE_TAG:-repo}
local_only=0
dry_run=0
db_ready=0

for arg in "$@"; do
  case $arg in
    --local) local_only=1 ;;
    --dry-run) dry_run=1 ;;
    *) echo "Usage: ${0##*/} [--local | --dry-run]" >&2; exit 2 ;;
  esac
done

shopt -s nullglob
packages=("$out_dir"/*.pkg.tar.zst)
shopt -u nullglob
((${#packages[@]})) || { echo "Error: no packages in $out_dir. Run scripts/build.sh first." >&2; exit 1; }

# repo-add comes with pacman. On a machine that has none, the local paths
# borrow one from a container; the publishing path is expected to run on Arch
# (the workflow's `container: archlinux`), where the token handling stays put.
# A --dry-run continues on the host afterwards, because the comparison against
# the release needs `gh` and the token, which the container has neither of.
if ! command -v repo-add >/dev/null; then
  if ((local_only || dry_run)) && command -v docker >/dev/null; then
    docker_args=(run --rm -v "$repo_root:/work")
    [[ -n ${GNUPGHOME:-} ]] && docker_args+=(-v "$GNUPGHOME:/gnupg-host:ro")
    docker_args+=(-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)"
      "${OMARCHY_BUILD_IMAGE:-archlinux:latest}" bash -euo pipefail -c '
        install -d -m 700 /root/.gnupg-work
        [[ -d /gnupg-host ]] && cp -a /gnupg-host/. /root/.gnupg-work/
        rm -f /root/.gnupg-work/S.*
        export GNUPGHOME=/root/.gnupg-work
        bash /work/scripts/publish.sh --local
        chown -R "$HOST_UID:$HOST_GID" /work/repo
      ')
    if ((local_only)); then
      docker "${docker_args[@]}"
      exit 0
    fi
    # A dry run only wants the database built; the container's own log would
    # otherwise be printed above the comparison that is the point of the run.
    echo "› building repo/ in a container (this host has no repo-add)"
    if ! container_log=$(docker "${docker_args[@]}" 2>&1); then
      printf '%s\n' "$container_log" >&2
      exit 1
    fi
    db_ready=1
  else
    echo "Error: repo-add (pacman) is required." >&2
    exit 1
  fi
fi

gh_repo=${GITHUB_REPOSITORY:-}
if ((!local_only)) && [[ -z $gh_repo ]]; then
  command -v gh >/dev/null || { echo "Error: gh is required (or use --local)." >&2; exit 1; }
  gh_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

if ((!db_ready)); then
  # The signing key. Same contract as scripts/build.sh: the private key lives in
  # GNUPGHOME, never in this repository.
  sign_key=${OMARCHY_SIGN_KEY:-}
  if [[ -z $sign_key ]]; then
    sign_key=$(gpg --with-colons --list-secret-keys 2>/dev/null |
      awk -F: '$1 == "fpr" { print $10; exit }')
  fi
  [[ -n $sign_key ]] || { echo "Error: no secret key to sign the database with." >&2; exit 1; }

  # Unattended signing, the same loopback arrangement scripts/build.sh sets up.
  if [[ -n ${GNUPGHOME:-} && -f $GNUPGHOME/passphrase ]] &&
    ! grep -q '^passphrase-file' "$GNUPGHOME/gpg.conf" 2>/dev/null; then
    printf 'pinentry-mode loopback\npassphrase-file %s\n' "$GNUPGHOME/passphrase" \
      >>"$GNUPGHOME/gpg.conf"
    echo "allow-loopback-pinentry" >>"$GNUPGHOME/gpg-agent.conf"
  fi

  # ── repo/ is rebuilt, not updated ─────────────────────────────────────────
  # Every file here is derived from out/, so the directory is emptied first:
  # a leftover package from an earlier build would otherwise be signed into
  # the database and served by scripts/verify.sh as if it were current.
  install -d "$repo_dir"
  rm -f "$repo_dir"/*.pkg.tar.zst "$repo_dir"/*.pkg.tar.zst.sig \
    "$repo_dir/$db_name".db* "$repo_dir/$db_name".files*

  cp -f "$out_dir"/*.pkg.tar.zst "$repo_dir/"
  shopt -s nullglob
  sigs=("$out_dir"/*.pkg.tar.zst.sig)
  shopt -u nullglob
  ((${#sigs[@]})) && cp -f "${sigs[@]}" "$repo_dir/"

  # No --verify: there is no previous database to verify, by construction. The
  # database this creates is signed, and that signature is what a client
  # checks.
  echo "› repo-add --sign ($sign_key) — a fresh database over ${#packages[@]} package(s)"
  repo-add --sign --key "$sign_key" \
    "$repo_dir/$db_name.db.tar.gz" "$repo_dir"/*.pkg.tar.zst

  # repo-add leaves $db_name.db and $db_name.files as symlinks. A release asset
  # cannot be a symlink, and `$repo.db` is the name pacman asks for.
  for suffix in db files; do
    cp -f "$repo_dir/$db_name.$suffix.tar.gz" "$repo_dir/$db_name.$suffix.new"
    mv -f "$repo_dir/$db_name.$suffix.new" "$repo_dir/$db_name.$suffix"
    if [[ -f $repo_dir/$db_name.$suffix.tar.gz.sig ]]; then
      cp -f "$repo_dir/$db_name.$suffix.tar.gz.sig" "$repo_dir/$db_name.$suffix.sig.new"
      mv -f "$repo_dir/$db_name.$suffix.sig.new" "$repo_dir/$db_name.$suffix.sig"
    fi
  done
  # repo-add keeps the previous generation as .old; those are not published.
  rm -f "$repo_dir"/*.old "$repo_dir"/*.old.sig
fi

# ── what the database references ────────────────────────────────────────────
# bsdtar comes with libarchive and is what Arch has; a --dry-run continues on
# whatever host the operator is on, where GNU tar may be the only one.
db_filenames() {
  if command -v bsdtar >/dev/null; then
    bsdtar -xOf "$1" '*/desc'
  else
    tar -xzOf "$1" --wildcards '*/desc'
  fi | awk '/^%FILENAME%$/ { getline; print }' | sort -u
}

mapfile -t referenced < <(db_filenames "$repo_dir/$db_name.db.tar.gz")
# An empty list is never a legitimate answer, and it is the one answer that
# would delete every package on the release: a database that reads as empty
# means the reader failed, not that the repository is empty.
((${#referenced[@]})) || {
  echo "Error: could not read any package out of $repo_dir/$db_name.db.tar.gz." >&2
  exit 1
}
echo "› database references ${#referenced[@]} package(s)"

if ((local_only)); then
  echo
  echo "Local repository: $repo_dir"
  ls -la "$repo_dir"
  exit 0
fi

# references answers "does the fresh database still want this asset?". A
# package's detached signature rides with the package it signs.
references() {
  local candidate=${1%.sig} name
  for name in "${referenced[@]}"; do
    [[ $candidate == "$name" ]] && return 0
  done
  return 1
}

# ── the assets to upload ────────────────────────────────────────────────────
upload=("$repo_dir/$db_name.db" "$repo_dir/$db_name.db.tar.gz"
  "$repo_dir/$db_name.files" "$repo_dir/$db_name.files.tar.gz")
for extra in "$db_name.db.sig" "$db_name.db.tar.gz.sig" \
  "$db_name.files.sig" "$db_name.files.tar.gz.sig"; do
  [[ -f $repo_dir/$extra ]] && upload+=("$repo_dir/$extra")
done
for package in "$repo_dir"/*.pkg.tar.zst; do
  upload+=("$package")
  [[ -f $package.sig ]] && upload+=("$package.sig")
done

# ── the assets to retire ────────────────────────────────────────────────────
# Only package assets are considered: the database, its signature and their
# symlink copies are always current by construction.
release_exists=0
gh release view "$tag" --repo "$gh_repo" >/dev/null 2>&1 && release_exists=1

published=()
if ((release_exists)); then
  mapfile -t published < <(
    gh release view "$tag" --repo "$gh_repo" --json assets \
      --jq '.assets[].name | select(test("\\.pkg\\.tar\\.zst(\\.sig)?$"))'
  )
fi

stale=()
for asset in "${published[@]}"; do
  references "$asset" || stale+=("$asset")
done

if ((dry_run)); then
  echo
  echo "Dry run against $gh_repo release '$tag' — nothing was written."
  if ((!release_exists)); then
    echo "  the release does not exist yet; it would be created"
  fi
  echo "  would upload ${#upload[@]} asset(s):"
  printf '    + %s\n' "${upload[@]##*/}"
  if ((${#stale[@]})); then
    echo "  would delete ${#stale[@]} asset(s) the fresh database no longer references:"
    printf '    - %s\n' "${stale[@]}"
  else
    echo "  would delete nothing: every published asset is still referenced"
  fi
  exit 0
fi

# ── the release ─────────────────────────────────────────────────────────────
if ((!release_exists)); then
  echo "› creating release '$tag'"
  gh release create "$tag" --repo "$gh_repo" \
    --title "[omarchy-server] pacman repository" \
    --notes "$(
      cat <<'NOTES'
The assets of this release **are** the `[omarchy-server]` pacman repository.
The tag never moves; the assets are replaced on every build.

```
[omarchy-server]
SigLevel = Required DatabaseOptional
Server = https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo
```

See the repository README for the keyring bootstrap.
NOTES
    )"
fi

echo "› uploading ${#upload[@]} asset(s) to $gh_repo release '$tag'"
gh release upload "$tag" --repo "$gh_repo" --clobber "${upload[@]}"

# The database is uploaded before the retired assets are deleted, so a client
# fetching in the middle of a run sees either the old database with its old
# packages or the new one with the new ones, never a database pointing at a
# file that has already gone.
for asset in "${stale[@]}"; do
  echo "› deleting superseded asset $asset"
  gh release delete-asset "$tag" "$asset" --repo "$gh_repo" --yes
done

echo
echo "Published: https://github.com/$gh_repo/releases/tag/$tag"
