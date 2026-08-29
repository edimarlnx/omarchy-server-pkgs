#!/bin/bash

# Build and sign the SELinux package set of the server profile.
#
#   ./scripts/build-selinux.sh                 # every package in the manifest
#   ./scripts/build-selinux.sh libselinux      # one, plus nothing else
#
# Output: out/selinux/*.pkg.tar.zst and, unless OMARCHY_NO_SIGN=1, one .sig each.
#
# The package list, the build order, the reason each package is in it and the
# upstream commit are all in pkgbuilds/selinux.manifest. Nothing is vendored:
# this script clones https://github.com/archlinuxhardened/selinux at that commit
# and builds the directories the manifest names, with the small number of
# overrides in pkgbuilds/selinux-overrides/ applied on top.
#
# This is a heavy build — systemd alone is most of it. Packages already present
# in out/selinux/ at the version the PKGBUILD would produce are skipped, so an
# interrupted run resumes where it stopped. OMARCHY_SELINUX_FORCE=1 rebuilds
# everything.
#
# Like scripts/build.sh, it runs on Arch as root and otherwise re-executes
# itself inside an archlinux container with this checkout bind mounted.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${OMARCHY_BUILD_IMAGE:-archlinux:latest}
out_dir="$repo_root/out/selinux"
manifest="$repo_root/pkgbuilds/selinux.manifest"
overrides="$repo_root/pkgbuilds/selinux-overrides"
upstream_url=${SELINUX_GIT_URL:-https://github.com/archlinuxhardened/selinux.git}

# The manifest is the single place the pin and the list live.
commit=$(sed -n 's/^commit=//p' "$manifest")
[[ -n $commit ]] || { echo "Error: no commit= pin in $manifest" >&2; exit 1; }
mapfile -t manifest_packages < <(grep -Ev '^[[:space:]]*(#|$)|^commit=' "$manifest")

packages=("$@")
((${#packages[@]})) || packages=("${manifest_packages[@]}")

# ── not on Arch: hand the job to a container ────────────────────────────────
if ! command -v makepkg >/dev/null; then
  command -v docker >/dev/null || {
    echo "Error: neither makepkg nor docker is available." >&2
    exit 1
  }
  mounts=(-v "$repo_root:/work")
  env_args=()
  if [[ -n ${GNUPGHOME:-} ]]; then
    mounts+=(-v "$GNUPGHOME:/gnupg-host:ro")
    env_args+=(-e "GNUPGHOME_HOST=/gnupg-host")
  fi
  for var in OMARCHY_SIGN_KEY OMARCHY_NO_SIGN OMARCHY_SELINUX_FORCE SELINUX_GIT_URL; do
    [[ -n ${!var:-} ]] && env_args+=(-e "$var=${!var}")
  done
  # A local clone of the upstream PKGBUILD tree, when there is one, saves the
  # container a network fetch and lets a build run offline.
  if [[ -n ${SELINUX_SRC:-} ]]; then
    mounts+=(-v "$SELINUX_SRC:/src/selinux:ro")
    env_args+=(-e "SELINUX_SRC=/src/selinux")
  fi
  exec docker run --rm "${mounts[@]}" "${env_args[@]}" \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    "$image" bash /work/scripts/build-selinux.sh "${packages[@]}"
fi

((EUID == 0)) || { echo "Error: run as root (makepkg drops to a builder user)." >&2; exit 1; }

# ── build environment ───────────────────────────────────────────────────────
pacman -Syu --noconfirm --needed base-devel git

id builder >/dev/null 2>&1 || useradd -m builder

# setpriv, not su or sudo: this build installs pam-selinux over the container's
# pam (systemd-selinux is built against it), and a PAM stack in the middle of
# being replaced is not something to drop privileges through. setpriv is a
# direct setuid/setgid and never opens a PAM session.
builder_uid=$(id -u builder)
builder_gid=$(id -g builder)
# PATH is spelled out rather than inherited, and it includes the three perl
# directories Arch adds through /etc/profile.d/perlbin.sh. That is not a
# detail: po4a -- a makedepend of util-linux-selinux -- installs to
# /usr/bin/vendor_perl, and a PATH without it makes meson report
# `Program po4a found: NO` and fail the build with the package installed.
builder_path=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/vendor_perl:/usr/bin/site_perl:/usr/bin/core_perl
as_builder() {
  setpriv --reuid "$builder_uid" --regid "$builder_gid" --init-groups \
    env HOME=/home/builder PATH="$builder_path" bash -c "$1"
}

# ── the signing key ─────────────────────────────────────────────────────────
# shellcheck source=scripts/gnupg-builder.sh
source "$repo_root/scripts/gnupg-builder.sh"
prepare_signing_key

# ── the source cache ────────────────────────────────────────────────────────
# makepkg downloads every tarball and clones systemd's whole repository into
# the package directory, which lives inside the container and dies with it. A
# rerun then pays for all of it again -- and one of those downloads,
# openssh from ftp.openbsd.org, took half an hour on a link that was doing
# 20 MB/s to GitHub. SRCDEST points makepkg at a directory on the host instead,
# so a rebuild reuses what the last one fetched.
srcdest=/work/out/selinux-src
install -d -o builder -g builder "$srcdest"
export SRCDEST="$srcdest"

# ── the upstream tree ───────────────────────────────────────────────────────
work=/home/builder/work
tree="$work/selinux"
install -d -o builder -g builder "$work"

# git refuses to read a repository whose files another user owns, and this one
# changes hands twice: copied in as root, built as builder.
git config --system --add safe.directory "$tree"

if [[ -d ${SELINUX_SRC:-} ]]; then
  echo "Using the mounted PKGBUILD tree at $SELINUX_SRC"
  rm -rf "$tree"
  cp -a "$SELINUX_SRC" "$tree"
  if [[ $(git -C "$tree" rev-parse HEAD) != "$commit" ]]; then
    git -C "$tree" -c advice.detachedHead=false checkout -q "$commit" ||
      { echo "Error: the mounted tree cannot be moved to $commit" >&2; exit 1; }
  fi
else
  echo "Cloning $upstream_url at $commit"
  rm -rf "$tree"
  git clone -q "$upstream_url" "$tree"
  git -C "$tree" -c advice.detachedHead=false checkout -q "$commit"
fi

# Overrides: one directory per package, copied over the upstream one. This is
# where this profile carries the changes it needs (a version bump ahead of the
# upstream tree, an extra patch) without vendoring the whole PKGBUILD.
if [[ -d $overrides ]]; then
  for dir in "$overrides"/*/; do
    [[ -d $dir ]] || continue
    name=$(basename "$dir")
    [[ -d $tree/$name ]] || { echo "Error: override for unknown package $name" >&2; exit 1; }
    echo "Applying override: $name"
    cp -a "$dir." "$tree/$name/"
  done
fi

chown -R builder:builder "$tree"

# The upstream PKGBUILDs verify release tarballs against the SELinux project's
# and each Arch maintainer's keys, which are not in a fresh container's keyring.
# The tree carries every one of them under _pgp_cache/ (its own
# export_pgp_keys_in_cache.sh keeps that directory current), so the build needs
# no keyserver and works offline.
#
# They go into the SAME GnuPG home makepkg signs from, because that is the one
# makepkg also verifies sources against.
import_pgp_keys() {
  echo "Importing the PGP keys the PKGBUILDs require"
  install -d -m 700 -o builder -g builder "$gnupg_dir"
  as_builder "gpgconf --kill gpg-agent >/dev/null 2>&1 || true"
  as_builder "GNUPGHOME='$gnupg_dir' gpg --batch --quiet --import $tree/_pgp_cache/*.asc" || true
  as_builder "GNUPGHOME='$gnupg_dir' gpg --batch --quiet --import $tree/*/keys/pgp/*.asc" || true
}
import_pgp_keys

# ── build ───────────────────────────────────────────────────────────────────
install -d "$out_dir"

# Packages that are additive (they replace nothing in stock Arch) are safe to
# install into the build container as they are produced, and later packages in
# the list need them at build time. The rebuilds are not installed here, with
# two exceptions that systemd-selinux genuinely builds against.
# pacman refuses a local file whose signature it cannot verify, and the key
# these are signed with is this repository's, not one in the container's
# keyring. The file was produced in this same container seconds ago, so it is
# installed from a copy with the detached signature left behind.
install_built_package() {
  local file=$1 staged
  staged=$(mktemp -d)
  cp "$file" "$staged/"
  # --ask=4 is ALPM's QUESTION_CONFLICT_PKG, pre-answered yes: pam-selinux and
  # shadow-selinux conflict with the container's own pam and shadow, and under
  # plain --noconfirm pacman takes the default answer (no) and fails the
  # transaction. The addon needs the same flag on the target, which is what
  # profile/server/addons/selinux.pacman-args carries.
  pacman -U --noconfirm --ask=4 "$staged/$(basename "$file")"
  rm -rf "$staged"
}

install_after_build() {
  case "$1" in
    libsepol | libselinux | libsemanage | checkpolicy | secilc | setools | \
      sepolgen | semodule-utils | policycoreutils | selinux-python | \
      pambase-selinux | pam-selinux | shadow-selinux) return 0 ;;
    *) return 1 ;;
  esac
}

built=()
for package in "${packages[@]}"; do
  dir="$tree/$package"
  [[ -d $dir ]] || { echo "Error: no such package directory upstream: $package" >&2; exit 1; }

  # `makepkg --packagelist` prints the exact file names this PKGBUILD would
  # produce, which is what makes a resume cheap: if they are all in out/, the
  # build has nothing to do.
  # Debug packages are build artifacts, not something a server installs, so
  # they are neither kept nor counted when deciding whether a build can be
  # skipped.
  mapfile -t expected < <(as_builder "cd '$dir' && makepkg --packagelist" |
    xargs -r -n1 basename | grep -v -- '-debug-' || true)
  missing=0
  for file in "${expected[@]}"; do
    [[ -f $out_dir/$file ]] || missing=1
  done
  if ((missing == 0)) && [[ ${OMARCHY_SELINUX_FORCE:-0} != 1 ]]; then
    echo "=== $package: already built, skipping ==="
    if install_after_build "$package"; then
      for file in "${expected[@]}"; do
        install_built_package "$out_dir/$file"
      done
    fi
    continue
  fi

  echo "=== building $package ==="
  started=$SECONDS

  # The dependencies are installed here, as root, instead of by `makepkg -s`.
  # Two reasons: `makepkg -s` shells out to sudo, and sudo goes through the PAM
  # stack this very build replaces; and half of what these PKGBUILDs depend on
  # exists in no Arch repository, because an earlier package in this list built
  # it. `pacman -T` reports what is still unsatisfied, and anything the sync
  # databases do not know is one of those and is already installed.
  mapfile -t deps < <(as_builder "cd '$dir' && makepkg --printsrcinfo" |
    sed -n 's/^[[:space:]]*\(make\)\?depends = //p' | sort -u)
  if ((${#deps[@]})); then
    mapfile -t unsatisfied < <(pacman -T "${deps[@]}" || true)
    to_install=()
    for dep in "${unsatisfied[@]}"; do
      pacman -Si "${dep%%[<>=]*}" >/dev/null 2>&1 && to_install+=("$dep")
    done
    ((${#to_install[@]})) && pacman -S --needed --noconfirm "${to_install[@]}"
  fi

  # --nodeps because of the above. --nocheck: the upstream test suites want a
  # running kernel with SELinux enabled, which a container does not have.
  as_builder "
    set -euo pipefail
    export GNUPGHOME='$gnupg_dir'
    ${sign_key:+export GPGKEY=$sign_key}
    export MAKEFLAGS='-j$(nproc)'
    export SRCDEST='$srcdest'
    cd '$dir'
    makepkg --noconfirm --nodeps --nocheck --cleanbuild -f ${sign_args[*]}
  "
  echo "=== $package built in $((SECONDS - started))s ==="

  for file in "$dir"/*.pkg.tar.zst; do
    [[ -f $file ]] || continue
    # The debug packages the split builds produce are build artifacts, not
    # something a server installs.
    [[ $(basename "$file") == *-debug-* ]] && continue
    cp -f "$file" "$out_dir/"
    [[ -f $file.sig ]] && cp -f "$file.sig" "$out_dir/"
    built+=("$(basename "$file")")
    if install_after_build "$package"; then
      install_built_package "$out_dir/$(basename "$file")"
    fi
  done
done

if [[ -n ${HOST_UID:-} && -n ${HOST_GID:-} ]]; then
  chown -R "$HOST_UID:$HOST_GID" "$repo_root/out"
fi

echo
echo "Packages in $out_dir:"
ls -la "$out_dir"
