#!/bin/bash

# Is the SELinux rebuild set still level with Arch?
#
#   ./scripts/check-selinux-lockstep.sh              # human-readable table
#   ./scripts/check-selinux-lockstep.sh --markdown   # the same as GitHub markdown
#
# Exit status: 0 when every rebuild is at or ahead of the Arch package it
# replaces, 1 when at least one is behind, 2 when the check itself could not
# run. `--markdown` writes the table to stdout in a form the workflow pastes
# into an issue body and a job summary.
#
# WHY THIS EXISTS
#
# Ten of the packages in pkgbuilds/selinux.manifest `provides=` and
# `conflicts=` a package the Arch base already has -- systemd, coreutils,
# util-linux, shadow, sudo, openssh, pam, pambase. Installing the `selinux`
# addon REPLACES them. Arch keeps moving; archlinuxhardened/selinux moves when
# somebody there gets to it. The gap between the two is a silent downgrade of a
# core package on every machine that turned the addon on, and it has already
# happened once: at the pin this repository first used, `openssh-selinux` was
# 10.4p1-3 while Arch shipped 10.5p1-1, so the addon moved the one
# network-facing daemon back a release without a word. That is what
# pkgbuilds/selinux-overrides/openssh/ exists to fix, and this script is what
# notices the next one.
#
# Measured, and the reason it is automated:
# omarchy-server/reports/2026-08-29-mandatory-access-control.md §8.3.
#
# WHERE THE TWO VERSIONS COME FROM
#
#   ours    the PKGBUILDs this repository would build: the upstream tree at the
#           commit pinned in the manifest, with pkgbuilds/selinux-overrides/
#           copied over it, exactly as scripts/build-selinux.sh assembles them.
#           Not out/selinux/, which is gitignored and absent in CI -- and which
#           would in any case answer "what did somebody build once", where the
#           question here is "what would a build produce today".
#
#   Arch's  `pacman -Si` in the container this runs in, against core and extra.
#
#   The mapping between them is the package NAME: every rebuild is the stock
#   name with `-selinux` appended, including in the split builds (systemd-selinux
#   also produces systemd-libs-selinux and systemd-sysvcompat-selinux). A
#   manifest entry whose names have no Arch counterpart is additive -- libsepol,
#   policycoreutils, the policy -- and is listed as such rather than skipped
#   silently, because "not compared" and "in sync" must not look the same.
#
# It does NOT rebuild anything. Deciding to move the pin means reading the
# upstream diff, and no scheduled job should do that on its own.

set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/pkgbuilds/selinux.manifest"
overrides="$repo_root/pkgbuilds/selinux-overrides"
upstream_url=${SELINUX_GIT_URL:-https://github.com/archlinuxhardened/selinux.git}

markdown=0
[[ ${1:-} == --markdown ]] && markdown=1

command -v pacman >/dev/null || {
  echo "check-selinux-lockstep: this has to run on Arch (or in archlinux:latest)." >&2
  exit 2
}

commit=$(sed -n 's/^commit=//p' "$manifest")
[[ -n $commit ]] || { echo "check-selinux-lockstep: no commit= pin in $manifest" >&2; exit 2; }
mapfile -t manifest_packages < <(grep -Ev '^[[:space:]]*(#|$)|^commit=' "$manifest")
((${#manifest_packages[@]})) || { echo "check-selinux-lockstep: the manifest lists no packages" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ── the tree this repository would build ────────────────────────────────────
# A full clone and a checkout of the pin. SELINUX_SRC points at a local clone
# when there is one, which is what makes the check runnable offline.
tree="$work/selinux"
if [[ -n ${SELINUX_SRC:-} && -d ${SELINUX_SRC:-}/.git ]]; then
  git clone --quiet --no-hardlinks "$SELINUX_SRC" "$tree" || exit 2
else
  git clone --quiet "$upstream_url" "$tree" || {
    echo "check-selinux-lockstep: could not clone $upstream_url" >&2
    exit 2
  }
fi
git -C "$tree" checkout --quiet "$commit" || {
  echo "check-selinux-lockstep: $commit is not in that tree" >&2
  exit 2
}
# Same overrides scripts/build-selinux.sh applies, and for the same reason: an
# override is precisely where this repository has already corrected a version.
for override in "$overrides"/*/; do
  [[ -d $override ]] || continue
  cp -a "$override." "$tree/$(basename "$override")/" 2>/dev/null || true
done

# Read pkgver/pkgrel/pkgname out of a PKGBUILD without building it. Sourced in
# a subshell with the few variables makepkg would have set, because these
# PKGBUILDs branch on CARCH. Anything a PKGBUILD prints is discarded; only the
# variables matter.
read_pkgbuild() { # read_pkgbuild <dir> -> "pkgver-pkgrel<TAB>name name ..."
  (
    set +u
    CARCH=x86_64 CHOST=x86_64-pc-linux-gnu
    # shellcheck disable=SC1090,SC1091
    source "$1/PKGBUILD" >/dev/null 2>&1 || exit 1
    [[ -n ${pkgver:-} && -n ${pkgrel:-} ]] || exit 1
    printf '%s-%s\t%s\n' "$pkgver" "$pkgrel" "${pkgname[*]}"
  )
}

pacman -Sy --noconfirm >/dev/null 2>&1 || {
  echo "check-selinux-lockstep: could not refresh the Arch databases" >&2
  exit 2
}

arch_version() { # arch_version <pkg> -> version, or empty when Arch has no such package
  pacman -Si "$1" 2>/dev/null | sed -n 's/^Version *: *//p' | head -1
}

behind_rows=()
level_rows=()
additive=()
unreadable=()

for package in "${manifest_packages[@]}"; do
  dir="$tree/$package"
  if [[ ! -d $dir ]]; then
    unreadable+=("$package (no such directory at the pin)")
    continue
  fi
  if ! info=$(read_pkgbuild "$dir"); then
    unreadable+=("$package (its PKGBUILD could not be read)")
    continue
  fi
  ours=${info%%$'\t'*}
  names=${info#*$'\t'}

  compared=0
  for name in $names; do
    [[ $name == *-selinux ]] || continue
    stock=${name%-selinux}
    theirs=$(arch_version "$stock")
    [[ -n $theirs ]] || continue
    compared=1
    case "$(vercmp "$theirs" "$ours")" in
      1) behind_rows+=("$name|$stock|$ours|$theirs") ;;
      *) level_rows+=("$name|$stock|$ours|$theirs") ;;
    esac
  done
  ((compared)) || additive+=("$package $ours")
done

# Informational only: whether upstream itself has moved past the pin. A pin that
# is behind is not by itself a problem -- it is deliberate -- but it is the
# first thing anyone reading a "rebuild needed" issue wants to know.
upstream_head=$(git -C "$tree" ls-remote origin HEAD 2>/dev/null | awk '{print $1}')
pin_note="the pin ${commit:0:12} is upstream HEAD"
if [[ -n $upstream_head && $upstream_head != "$commit" ]]; then
  ahead=$(git -C "$tree" rev-list --count "$commit..origin/HEAD" 2>/dev/null || echo "?")
  pin_note="upstream is $ahead commits ahead of the pin ${commit:0:12} (${upstream_head:0:12})"
fi

emit_table() { # emit_table <rows...>
  local row name stock ours theirs
  for row in "$@"; do
    IFS='|' read -r name stock ours theirs <<<"$row"
    if ((markdown)); then
      printf '| `%s` | `%s` | `%s` | `%s` |\n' "$name" "$ours" "$stock" "$theirs"
    else
      printf '  %-32s %-24s  Arch %-16s %s\n' "$name" "$ours" "$stock" "$theirs"
    fi
  done
}

if ((markdown)); then
  echo "### SELinux rebuilds vs Arch"
  echo
  echo "Pin: \`$commit\` — $pin_note"
  echo
  if ((${#behind_rows[@]})); then
    echo "**${#behind_rows[@]} rebuild(s) are BEHIND Arch. A rebuild is needed.**"
    echo
    echo "| rebuild | this repo would build | replaces | Arch has |"
    echo "|---|---|---|---|"
    emit_table "${behind_rows[@]}"
    echo
    echo "Each row is a package the \`selinux\` addon installs over the Arch one,"
    echo "so every machine with the addon is running the older build."
    echo
    echo "To fix: move \`commit=\` in \`pkgbuilds/selinux.manifest\` to an upstream"
    echo "commit that carries the newer version, or add/refresh the package's"
    echo "directory under \`pkgbuilds/selinux-overrides/\` with Arch's current"
    echo "PKGBUILD plus the SELinux changes — then re-run"
    echo "\`./scripts/build-selinux.sh\` and the SELinux acceptance."
    echo
  else
    echo "**Every rebuild is level with or ahead of Arch.**"
    echo
  fi
  if ((${#level_rows[@]})); then
    echo "<details><summary>In sync (${#level_rows[@]})</summary>"
    echo
    echo "| rebuild | this repo would build | replaces | Arch has |"
    echo "|---|---|---|---|"
    emit_table "${level_rows[@]}"
    echo
    echo "</details>"
    echo
  fi
  if ((${#additive[@]})); then
    echo "<details><summary>Additive, no Arch counterpart to compare (${#additive[@]})</summary>"
    echo
    printf '-   `%s`\n' "${additive[@]}"
    echo
    echo "</details>"
    echo
  fi
  if ((${#unreadable[@]})); then
    echo "**Not checked (${#unreadable[@]}) — treat this as a failure of the check, not a pass:**"
    echo
    printf '-   %s\n' "${unreadable[@]}"
    echo
  fi
else
  echo "=== SELinux rebuilds vs Arch ==="
  echo "pin: $commit"
  echo "     $pin_note"
  echo
  if ((${#behind_rows[@]})); then
    echo "BEHIND (${#behind_rows[@]}) — a rebuild is needed:"
    emit_table "${behind_rows[@]}"
    echo
  fi
  if ((${#level_rows[@]})); then
    echo "in sync (${#level_rows[@]}):"
    emit_table "${level_rows[@]}"
    echo
  fi
  ((${#additive[@]})) && { echo "additive, nothing in Arch to compare (${#additive[@]}):"; printf '  %s\n' "${additive[@]}"; echo; }
  ((${#unreadable[@]})) && { echo "NOT CHECKED (${#unreadable[@]}):"; printf '  %s\n' "${unreadable[@]}"; echo; }
fi

# An unreadable PKGBUILD is not a pass. It means the comparison did not happen
# for that package, which is the same risk the check exists to remove.
if ((${#behind_rows[@]} || ${#unreadable[@]})); then
  exit 1
fi
exit 0
