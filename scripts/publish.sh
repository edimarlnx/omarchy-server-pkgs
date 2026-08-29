#!/bin/bash

# Assemble the signed [omarchy-server] pacman database from out/ and publish
# everything as assets of a single, fixed GitHub release tagged `repo`.
#
#   ./scripts/publish.sh              # publish to $GITHUB_REPOSITORY or origin
#   ./scripts/publish.sh --local      # build repo/ and stop, upload nothing
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
#     asset (--clobber) and an old package version is deleted only once the
#     database no longer references it.
#
# The database published is the previous one with this run's packages added,
# not a fresh one built from out/: a run that rebuilds a single package must
# not drop the other three out of the repository.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out_dir="$repo_root/out"
repo_dir="$repo_root/repo"
db_name=omarchy-server
tag=${OMARCHY_RELEASE_TAG:-repo}
local_only=0

[[ ${1:-} == --local ]] && local_only=1

shopt -s nullglob
packages=("$out_dir"/*.pkg.tar.zst)
shopt -u nullglob
((${#packages[@]})) || { echo "Error: no packages in $out_dir. Run scripts/build.sh first." >&2; exit 1; }

# repo-add comes with pacman. On a machine that has none, the --local dry run
# borrows one from a container; the publishing path is expected to run on Arch
# (the workflow's `container: archlinux`), where the token handling stays put.
if ! command -v repo-add >/dev/null; then
  if ((local_only)) && command -v docker >/dev/null; then
    exec docker run --rm -v "$repo_root:/work" \
      ${GNUPGHOME:+-v "$GNUPGHOME:/gnupg-host:ro"} \
      -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
      "${OMARCHY_BUILD_IMAGE:-archlinux:latest}" bash -euo pipefail -c '
        install -d -m 700 /root/.gnupg-work
        [[ -d /gnupg-host ]] && cp -a /gnupg-host/. /root/.gnupg-work/
        rm -f /root/.gnupg-work/S.*
        export GNUPGHOME=/root/.gnupg-work
        bash /work/scripts/publish.sh --local
        chown -R "$HOST_UID:$HOST_GID" /work/repo
      '
  fi
  echo "Error: repo-add (pacman) is required." >&2
  exit 1
fi

gh_repo=${GITHUB_REPOSITORY:-}
if ((!local_only)) && [[ -z $gh_repo ]]; then
  command -v gh >/dev/null || { echo "Error: gh is required (or use --local)." >&2; exit 1; }
  gh_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

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

install -d "$repo_dir"

# ── the previous database ───────────────────────────────────────────────────
# Fetched so packages that this run did not rebuild keep their entries. A
# release that does not exist yet simply yields nothing.
if ((!local_only)) && [[ ! -f $repo_dir/$db_name.db.tar.gz ]]; then
  if gh release view "$tag" --repo "$gh_repo" >/dev/null 2>&1; then
    echo "› fetching the published database from release '$tag'"
    for asset in "$db_name.db.tar.gz" "$db_name.db.tar.gz.sig" \
      "$db_name.files.tar.gz" "$db_name.files.tar.gz.sig"; do
      gh release download "$tag" --repo "$gh_repo" --pattern "$asset" \
        --dir "$repo_dir" --clobber 2>/dev/null || true
    done
  fi
fi

cp -f "$out_dir"/*.pkg.tar.zst "$repo_dir/"
shopt -s nullglob
sigs=("$out_dir"/*.pkg.tar.zst.sig)
shopt -u nullglob
((${#sigs[@]})) && cp -f "${sigs[@]}" "$repo_dir/"

# --verify checks the signature of the database being updated before touching
# it, so a tampered or foreign db is refused instead of extended.
verify_args=()
[[ -f $repo_dir/$db_name.db.tar.gz.sig ]] && verify_args=(--verify)

echo "› repo-add --sign${verify_args:+ --verify} ($sign_key)"
repo-add --sign --key "$sign_key" "${verify_args[@]}" \
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

# ── what the database references ────────────────────────────────────────────
mapfile -t referenced < <(
  bsdtar -xOf "$repo_dir/$db_name.db.tar.gz" '*/desc' |
    awk '/^%FILENAME%$/ { getline; print }' | sort -u
)
echo "› database references ${#referenced[@]} package(s)"

if ((local_only)); then
  echo
  echo "Local repository: $repo_dir"
  ls -la "$repo_dir"
  exit 0
fi

# ── the release ─────────────────────────────────────────────────────────────
if ! gh release view "$tag" --repo "$gh_repo" >/dev/null 2>&1; then
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

echo "› uploading ${#upload[@]} asset(s) to $gh_repo release '$tag'"
gh release upload "$tag" --repo "$gh_repo" --clobber "${upload[@]}"

# ── retire packages the database no longer references ───────────────────────
# Only package assets are considered: the database, its signature and their
# symlink copies are always current by construction.
mapfile -t published < <(
  gh release view "$tag" --repo "$gh_repo" --json assets \
    --jq '.assets[].name | select(endswith(".pkg.tar.zst"))'
)
for asset in "${published[@]}"; do
  keep=0
  for name in "${referenced[@]}"; do
    [[ $asset == "$name" ]] && { keep=1; break; }
  done
  ((keep)) && continue
  echo "› deleting superseded asset $asset"
  gh release delete-asset "$tag" "$asset" --repo "$gh_repo" --yes
  gh release delete-asset "$tag" "$asset.sig" --repo "$gh_repo" --yes 2>/dev/null || true
done

echo
echo "Published: https://github.com/$gh_repo/releases/tag/$tag"
