#!/bin/bash

# Build the [omarchy-server] packages and sign them.
#
#   ./scripts/build.sh                     # every package
#   ./scripts/build.sh omarchy-server      # one package
#
# Output: out/*.pkg.tar.zst and, unless OMARCHY_NO_SIGN=1, one .sig each.
#
# The script runs on Arch as root. When it is started somewhere else it
# re-executes itself inside an archlinux container with this checkout bind
# mounted, so a laptop and a GitHub Actions runner take the same path through
# the same code. In CI the workflow already runs in `container: archlinux`, so
# the native branch is the one that matters there.
#
# Signing key: the private key must be in the GnuPG home named by GNUPGHOME
# (the workflow imports it from the PACMAN_GPG_KEY secret). OMARCHY_SIGN_KEY
# pins which key when the home holds more than one; otherwise the first secret
# key is used. Nothing about the key material is read from this repository —
# only its PUBLIC half is here, inside pkgbuilds/omarchy-server-keyring/.
#
# Sources: the PKGBUILDs pull the pinned commits over https by default. A local
# checkout can be substituted by exporting OMARCHY_SRC and/or FWALL_SRC, which
# is what the omarchy-server lab repository's pkgs/build.sh does.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${OMARCHY_BUILD_IMAGE:-archlinux:latest}
out_dir="$repo_root/out"
packages=("$@")

if ((${#packages[@]} == 0)); then
  packages=(omarchy-server-keyring omarchy-server-settings omarchy-server fwall)
fi

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
  [[ -n ${OMARCHY_SIGN_KEY:-} ]] && env_args+=(-e "OMARCHY_SIGN_KEY=$OMARCHY_SIGN_KEY")
  [[ -n ${OMARCHY_NO_SIGN:-} ]] && env_args+=(-e "OMARCHY_NO_SIGN=$OMARCHY_NO_SIGN")
  if [[ -n ${OMARCHY_SRC:-} ]]; then
    mounts+=(-v "$OMARCHY_SRC:/src/omarchy:ro")
    env_args+=(-e "OMARCHY_SRC=/src/omarchy")
  fi
  if [[ -n ${FWALL_SRC:-} ]]; then
    mounts+=(-v "$FWALL_SRC:/src/tui-tools:ro")
    env_args+=(-e "FWALL_SRC=/src/tui-tools")
  fi
  exec docker run --rm "${mounts[@]}" "${env_args[@]}" \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    "$image" bash /work/scripts/build.sh "${packages[@]}"
fi

((EUID == 0)) || { echo "Error: run as root (makepkg drops to a builder user)." >&2; exit 1; }

# ── dependencies ────────────────────────────────────────────────────────────
pacman -Syu --noconfirm --needed base-devel git

# Go is only pulled in when something in this run compiles. The three Omarchy
# packages are arch=any file bundles and would pay 250 MiB for a toolchain they
# never call.
case " ${packages[*]} " in
  *" fwall "*) pacman -S --noconfirm --needed go ;;
esac

id builder >/dev/null 2>&1 || useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: /usr/bin/pacman" >/etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

# git refuses to read a repository owned by another user.
for src in /src/omarchy /src/tui-tools; do
  [[ -d $src ]] && git config --system --add safe.directory "$src"
done

# ── the signing key ─────────────────────────────────────────────────────────
# Every unprivileged step runs through this, so the two build scripts can share
# the GnuPG setup while dropping privileges the way each of them needs to.
as_builder() { su builder -c "$1"; }

# shellcheck source=scripts/gnupg-builder.sh
source "$repo_root/scripts/gnupg-builder.sh"
prepare_signing_key

# ── the overlay tarball ─────────────────────────────────────────────────────
# Every input to makepkg is a declared source instead of an ambient path, so
# the server profile vendored under server-profile/ is packed into each
# PKGBUILD directory that consumes it. addons/ rides along because the runtime
# package ships those lists and the ISO builder reads the same files to fill
# its offline mirror; branding/ carries the Limine wallpaper.
# scripts/sync-overlay.sh is what refreshes server-profile/ from the lab repo.
for package in omarchy-server-settings omarchy-server; do
  tar -czf "$repo_root/pkgbuilds/$package/omarchy-server-overlay.tar.gz" \
    -C "$repo_root/server-profile" overlay addons branding
done

install -d "$out_dir"
work=/home/builder/work
install -d -o builder -g builder "$work"

for package in "${packages[@]}"; do
  echo "=== building $package ==="
  rm -rf "${work:?}/$package"
  cp -a "$repo_root/pkgbuilds/$package" "$work/$package"
  chown -R builder:builder "$work/$package"

  # makepkg --nodeps installs nothing at all, so the makedepends a package
  # genuinely needs to compile are read out of the PKGBUILD and installed here.
  makedeps=$(su builder -c "cd '$work/$package' && makepkg --printsrcinfo" |
    sed -n 's/^[[:space:]]*makedepends = //p')
  if [[ -n $makedeps ]]; then
    # shellcheck disable=SC2086
    pacman -S --needed --noconfirm $makedeps
  fi

  # --nodeps, not -s: the Omarchy packages are arch=any file bundles with no
  # compile step, and their depends() name each other plus packages that only
  # exist in the [omarchy] repository. Installing ~200 MiB of runtime
  # dependencies would buy the build nothing.
  su builder -c "
    set -euo pipefail
    export GNUPGHOME=${gnupg_dir:-/home/builder/gnupg}
    ${sign_key:+export GPGKEY=$sign_key}
    ${OMARCHY_SRC:+export OMARCHY_SRC=$OMARCHY_SRC}
    ${FWALL_SRC:+export FWALL_SRC=$FWALL_SRC}
    cd '$work/$package'
    makepkg --noconfirm --nodeps -f ${sign_args[*]}
  "
  cp -f "$work/$package"/*.pkg.tar.zst* "$out_dir/"
done

# Hand the output back to the invoking user when this ran in a container.
if [[ -n ${HOST_UID:-} && -n ${HOST_GID:-} ]]; then
  chown -R "$HOST_UID:$HOST_GID" "$out_dir" "$repo_root/pkgbuilds"
fi

echo
echo "Packages in $out_dir:"
ls -la "$out_dir"
