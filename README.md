# omarchy-server-pkgs

> **Status: unofficial, under validation.** These packages and this repository
> are an independent experiment and are **not** an official Omarchy project or
> mirror. The signing key is a lab key for now. Do not add this repository to a
> machine you care about. Upstream: [omarchy.org](https://omarchy.org).

The signed pacman repository **`[omarchy-server]`**: the packages of the
headless [Omarchy](https://omarchy.org) server profile, built by GitHub Actions
and served from the assets of this repository's `repo` release.

```
[omarchy-server]
SigLevel = Required DatabaseOptional
Server = https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo
```

The release tag never moves; every build replaces its assets. That is what
makes a `Server` line pointing at a GitHub release usable as a pacman mirror,
and it is the same arrangement
[arch-mact2-mirror](https://github.com/NoaHimesaka1873/arch-mact2-mirror) uses.

| Package | What it is |
|---|---|
| `omarchy-server` | the Omarchy runtime for headless machines (`provides=omarchy`) |
| `omarchy-server-settings` | its defaults, `/etc/skel` content and system configuration |
| `omarchy-server-keyring` | the public key that signs everything here |
| `tui-firewall` | addon: a terminal UI over the system firewall (formerly `fwall`) |
| `tui-systemd` | addon: a terminal UI over systemd units and their journal |

The profile these packages install — the overlay, the addon lists, the install
scripts — is developed in
[**omarchy-server**](https://github.com/edimarlnx/omarchy-server), the lab
repository. This repository owns how those files become packages; that one owns
what is in them. `server-profile/` here is a vendored copy, refreshed by
`scripts/sync-overlay.sh`.

## Using the repository on any Arch machine

An installed Omarchy Server has this wired already: `omarchy-server-settings`
ships `/etc/pacman.d/omarchy-server.conf` and every channel template
(`pacman-{stable,rc,edge}.conf`) includes it. On any other Arch machine, two
steps.

**1. Trust the key.** The keyring package is signed by the very key it
delivers, so it cannot verify itself — the same chicken-and-egg
`archlinux-keyring` has. Break it once, by hand:

```bash
base=https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo
keyring=$(curl -fsSL $base/omarchy-server.db | bsdtar -xOf - '*/desc' |
  awk '/^%FILENAME%$/ { getline; print }' | grep '^omarchy-server-keyring-')

curl -fsSLO "$base/$keyring"
bsdtar -xOf "$keyring" usr/share/pacman/keyrings/omarchy-server.gpg >omarchy-server.gpg
bsdtar -xOf "$keyring" usr/share/pacman/keyrings/omarchy-server-trusted >omarchy-server-trusted

sudo pacman-key --add omarchy-server.gpg
sudo pacman-key --lsign-key "$(cut -d: -f1 omarchy-server-trusted)"
sudo pacman -U "$keyring"
sudo pacman-key --populate omarchy-server
```

Everything after this point is verified against that key.

**2. Add the repository.** Write the snippet at the top of this README to
`/etc/pacman.d/omarchy-server.conf` (the keyring package does not own that
path; `omarchy-server-settings` does, so skip this step if you are installing
the profile) and add one line to `/etc/pacman.conf`:

```
Include = /etc/pacman.d/omarchy-server.conf
```

Then `sudo pacman -Sy tui-firewall tui-systemd`.

## The SELinux set

The SELinux addons of the server profile need nineteen packages that exist in
no Arch repository: the SELinux userland, the Arch reference policy, and eight
rebuilds of core packages (systemd, coreutils, util-linux, shadow, sudo,
openssh, pam, pambase) that Arch does not build against `libselinux`.

Seventeen of them are the `selinux` addon, which is what a machine needs to RUN
confined. The other two — `setools` and `selinux-python`, i.e. `sesearch`,
`semanage` and `audit2allow` — are the separate `selinux-tools` addon, because
`setools` pulls `python-networkx` and Arch's `python-networkx` hard-depends on
scipy, pandas, matplotlib and numpy: 45 packages and 453 MiB of scientific
Python on a headless server. Both sets are built here; which one a machine
installs is the profile's decision.

They have their own build script, because the sources are somebody else's
PKGBUILDs and the builds are real compiles rather than `arch=any` bundles:

```bash
./scripts/build-selinux.sh                 # everything in the manifest, into out/selinux/
./scripts/build-selinux.sh libselinux      # one
```

Nothing is vendored. `pkgbuilds/selinux.manifest` carries the pinned commit of
[`archlinuxhardened/selinux`](https://github.com/archlinuxhardened/selinux), the
build order, and one paragraph per package saying why it is in the set — plus,
at the end, one per package saying why the ones that are not, are not. The
changes this profile needs on top of that tree live in
`pkgbuilds/selinux-overrides/<pkg>/`, copied over the upstream directory at
build time; there are two, and each says in its header what would have to be
true for it to be deleted.

> **Eight of these replace a package Arch ships.** A rebuild that is behind
> Arch is a **downgrade** delivered silently through `provides=` — which was
> already the case for `openssh-selinux` at the first pin used here, hence the
> override.

`scripts/publish.sh` does not publish this set. It is consumed by the ISO
builder out of `out/selinux/`, which is what makes the addon work on a machine
with no network.

### Staying level with Arch

Nobody is going to compare fourteen version numbers by hand every week, so a
job does it:

```bash
./scripts/check-selinux-lockstep.sh              # table
./scripts/check-selinux-lockstep.sh --markdown   # what the workflow posts
```

It clones `archlinuxhardened/selinux` at the manifest's pinned commit, copies
`pkgbuilds/selinux-overrides/` over it — exactly what `build-selinux.sh`
assembles — reads `pkgver-pkgrel` out of each PKGBUILD, and `vercmp`s it
against the Arch package of the same name with `-selinux` stripped off. It
compares **what a build today would produce**, not what is sitting in
`out/selinux/`: that directory is gitignored, absent in CI, and answers a
different question.

Exit 0 when every rebuild is level with or ahead of Arch, 1 when one is behind
or a PKGBUILD could not be read (an unread PKGBUILD is not a pass — it is a
comparison that did not happen), 2 when the check itself could not run.

`.github/workflows/selinux-lockstep.yml` runs it **weekly** (Mondays 06:17 UTC),
on `workflow_dispatch`, and on any push to `main` that touches the manifest,
an override or the script. When something is behind it opens — or updates in
place — a single issue titled *SELinux rebuilds are behind Arch* carrying the
diff, and fails the job. When everything is level again it comments and closes
that issue. **It never rebuilds anything**: moving the pin means reading an
upstream diff and re-running the SELinux acceptance in a VM, and no schedule
should decide that.

First run, 2026-08-29: 14 rebuilds compared, all in sync
(`systemd`/`systemd-libs`/`systemd-resolvconf`/`systemd-sysvcompat`/
`systemd-tests`/`systemd-ukify` 261.2-1, `openssh` 10.5p1-1, `sudo`
1.9.17.p2-6, `coreutils` 9.11-2, `util-linux`/`util-linux-libs` 2.42.2-1,
`shadow` 4.20.0.arch1-1, `pam` 1.7.2-2, `pambase` 20260616-1); 11 additive
packages have no Arch counterpart to compare.

## Layout

```
pkgbuilds/<pkg>/      the PKGBUILDs, one directory each
pkgbuilds/selinux.manifest       the SELinux set: pinned commit, order, rationale
pkgbuilds/selinux-overrides/     this profile's changes on top of that upstream
server-profile/       overlay/ addons/ branding/, vendored from the lab repo
scripts/sync-overlay.sh   refresh server-profile/ from ../omarchy-server
scripts/build.sh          build and sign the packages into out/
scripts/build-selinux.sh  build and sign the SELinux set into out/selinux/
scripts/check-selinux-lockstep.sh  are the rebuilds still level with Arch?
scripts/gnupg-builder.sh  the signing-key setup both build scripts share
scripts/publish.sh        repo-add --sign, then upload to the `repo` release
scripts/verify.sh         serve repo/ over HTTP and install it in a container
.github/workflows/        publish.yml (build+sign+publish), selinux-lockstep.yml
```

`out/` and `repo/` are build output and are gitignored.

## Where the sources come from

Nothing here vendors upstream code. The PKGBUILDs pull pinned commits:

| Package | Source |
|---|---|
| `omarchy-server`, `omarchy-server-settings` | `https://github.com/edimarlnx/omarchy.git`, branch `server`, commit `468b511` |
| `tui-firewall` | `https://github.com/tui-tools/tui-firewall.git`, tag `v0.1.0` |
| `tui-systemd` | `https://github.com/tui-tools/tui-systemd.git`, tag `v0.1.0` |

Exporting `OMARCHY_SRC`, `TUI_FIREWALL_SRC` or `TUI_SYSTEMD_SRC` substitutes a
local checkout for any of them, which is how the lab repository builds against
its working tree and how the ISO builder builds offline. `OMARCHY_GIT_URL` /
`TUI_FIREWALL_GIT_URL` / `TUI_SYSTEMD_GIT_URL` replace the URL outright.

`tui-firewall` was `fwall` while both tools lived in one monorepo. The package
carries `provides=(fwall)` and `replaces=(fwall)`, so a machine that installed
the old name takes the rename as an ordinary `pacman -Syu`.

## Building

```bash
./scripts/build.sh                 # all five packages into out/
./scripts/build.sh omarchy-server  # one
```

It runs on Arch as root; anywhere else it re-executes itself inside an
`archlinux` container with this checkout mounted, so a laptop and a CI runner
take the same path. `GNUPGHOME` must hold the private signing key, or
`OMARCHY_NO_SIGN=1` skips signing.

A full local rehearsal of what CI does, publishing nothing:

```bash
export GNUPGHOME=../omarchy-server/pkgs/keys/gnupg   # the lab key
./scripts/build.sh
./scripts/publish.sh --local     # assembles repo/ with repo-add --sign
./scripts/verify.sh              # serves it over HTTP, installs it, attacks it
```

`verify.sh` is the acceptance test for the whole chain. It boots a clean
`archlinux` container, serves `repo/` over HTTP on loopback, bootstraps the
trust anchor out of the keyring package, installs `tui-firewall` and
`omarchy-server` under `SigLevel = Required`, and then points the same container
at a hostile mirror: the same packages, a database rebuilt so every checksum
agrees, and a `tui-firewall` signed by a freshly generated stranger's key.
pacman must refuse it ("required key missing from keyring"), and must also
refuse the same package with no signature at all.

Last run, 2026-08-29, against the lab key: **13 assertions, all PASS** — HTTP
transport, keyring bootstrap, `pacman -Sy`, `fwall` (now `tui-firewall`) and
`omarchy-server` installed under `SigLevel = PackageRequired`, the shipped
`/etc/pacman.d/omarchy-server.conf`, and both hostile cases rejected with
nothing installed. The lab repository's own `pkgs/test.sh` (66 assertions) and
its ISO build are green against the same packages.

## Publishing

> **Bump `pkgrel` on every content change.** Release assets are addressed **by
> file name**, and the file name carries `pkgver-pkgrel`. Rebuilding without a
> bump republishes the same asset name, `repo-add` records the same version,
> and `pacman -Syu` on an installed machine finds nothing to do — the new
> content sits on the server and is never installed. That has already happened
> once, to `omarchy-server` and `omarchy-server-settings` at `4.0.1-1`, which
> is why both start at `4.0.1-2`. Editing anything under `server-profile/`
> means bumping **both**, since the same overlay tarball is a source of both.
> Move `pkgver` only when the pinned upstream commit moves, and reset `pkgrel`
> to `1` when you do. `omarchy-server/docs/packaging.md` §2.0 has the rules.

`scripts/publish.sh` builds the database **fresh from `out/`** with `repo-add`,
signs it, and uploads every asset to the `repo` release:

* the packages and their `.sig`
* `omarchy-server.db.tar.gz` / `.files.tar.gz` and their `.sig`
* `omarchy-server.db` / `.files` — which `repo-add` leaves as symlinks and a
  release asset cannot be, so they are published as real copies. `$repo.db` is
  the name pacman asks for, so this is not cosmetic.

Anything on the release the new database does not reference is then deleted.
The database is uploaded before those deletions, so a client fetching mid-run
sees either the old pair or the new one, never a database naming a file that
has already gone.

> **`out/` is the whole repository, not a delta.** The database used to be the
> published one with this run's packages added, which is how `fwall` — renamed
> to `tui-firewall`, asset deleted — kept a record in the database pointing at
> a 404 for every client that ran `pacman -Sy`. Rebuilding from `out/` cannot
> do that, at the price of a rule: **always publish a complete build.** A
> partial `out/` would drop the packages missing from it. The workflow
> therefore always runs `scripts/build.sh` with no package list, and has no
> "which packages" input; the alternative — downloading the still-referenced
> published packages into `out/` first — buys nothing over a two-minute build
> of all five.

Rehearsing, on any machine (no Arch and no pacman needed — the local step
borrows `repo-add` from a container):

```bash
./scripts/publish.sh --local      # assemble repo/, upload nothing
./scripts/verify.sh               # serve repo/ over HTTP and attack it
./scripts/publish.sh --dry-run    # read the live release, say what would move
```

`--dry-run` writes nothing to the release: it lists the assets a real run would
upload and the ones it would delete.

CI does the real thing on every push to `main` and on manual dispatch
(`.github/workflows/publish.yml`), inside `archlinux:latest`, using the
`GITHUB_TOKEN`.

## The signing key

The key currently in `pkgbuilds/omarchy-server-keyring/` is a **lab key**
(`792739C447F15D9172C59F8F4398BBFF2AE89B1A`, `Omarchy Server Lab
<lab@omarchy-server.invalid>`), generated without a passphrase by
`../omarchy-server/pkgs/keys/gen-lab-key.sh`. It exists so the whole signed
path could be proven end to end without waiting on a real key. **Replace it.**

Only the public half is in this repository. The private half lives in the
`PACMAN_GPG_KEY` secret (ASCII-armored), with `PACMAN_GPG_PASSPHRASE` optional
beside it.

Replacing the key:

1. Generate it offline, on a machine that is not this one.
2. Export the public key to `pkgbuilds/omarchy-server-keyring/omarchy-server.gpg`,
   write `<fingerprint>:4:` to `omarchy-server-trusted`, leave
   `omarchy-server-revoked` empty, and bump `pkgver` (a date) in that PKGBUILD.
3. `gh secret set PACMAN_GPG_KEY --repo edimarlnx/omarchy-server-pkgs < private.asc`
   (and `PACMAN_GPG_PASSPHRASE` if it has one).
4. Push. The workflow rebuilds and republishes everything under the new key.

One caveat, because it bites exactly once: a machine that is already installed
trusts only the old key, so the package that teaches it the new one has to be
signed by the old one. Rotating in a single build signs the new keyring with
the new key and every such machine rejects it. The order is therefore two
builds — first publish an `omarchy-server-keyring` that CONTAINS the new public
key while `PACMAN_GPG_KEY` is still the old private key, then switch the secret
and rebuild everything. `omarchy-server-revoked` is how the old fingerprint is
retired after that. Nothing automates this today; the workflow signs with
whatever single key the secret holds.
