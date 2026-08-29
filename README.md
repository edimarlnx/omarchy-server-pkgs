# omarchy-server-pkgs

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
| `fwall` | addon: a terminal UI over the system firewall |

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

Then `sudo pacman -Sy fwall`.

## Layout

```
pkgbuilds/<pkg>/      the PKGBUILDs, one directory each
server-profile/       overlay/ addons/ branding/, vendored from the lab repo
scripts/sync-overlay.sh   refresh server-profile/ from ../omarchy-server
scripts/build.sh          build and sign the packages into out/
scripts/publish.sh        repo-add --sign, then upload to the `repo` release
scripts/verify.sh         serve repo/ over HTTP and install it in a container
.github/workflows/        publish.yml, the workflow that does all of the above
```

`out/` and `repo/` are build output and are gitignored.

## Where the sources come from

Nothing here vendors upstream code. The PKGBUILDs pull pinned commits:

| Package | Source |
|---|---|
| `omarchy-server`, `omarchy-server-settings` | `https://github.com/edimarlnx/omarchy.git`, branch `server`, commit `468b511` |
| `fwall` | `https://github.com/edimarlnx/tui-tools.git`, commit `f512fc4` |

Exporting `OMARCHY_SRC` or `FWALL_SRC` substitutes a local checkout for either,
which is how the lab repository builds against its working tree and how the ISO
builder builds offline. `OMARCHY_GIT_URL` / `FWALL_GIT_URL` replace the URL
outright.

## Building

```bash
./scripts/build.sh                 # all four packages into out/
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
trust anchor out of the keyring package, installs `fwall` and `omarchy-server`
under `SigLevel = Required`, and then points the same container at a hostile
mirror: the same packages, a database rebuilt so every checksum agrees, and a
`fwall` signed by a freshly generated stranger's key. pacman must refuse it
("required key missing from keyring"), and must also refuse the same package
with no signature at all.

Last run, 2026-08-29, against the lab key: **13 assertions, all PASS** — HTTP
transport, keyring bootstrap, `pacman -Sy`, `fwall` and `omarchy-server`
installed under `SigLevel = PackageRequired`, the shipped
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

`scripts/publish.sh` fetches the currently published database, adds this run's
packages to it, signs it, and uploads every asset to the `repo` release:

* the packages and their `.sig`
* `omarchy-server.db.tar.gz` / `.files.tar.gz` and their `.sig`
* `omarchy-server.db` / `.files` — which `repo-add` leaves as symlinks and a
  release asset cannot be, so they are published as real copies. `$repo.db` is
  the name pacman asks for, so this is not cosmetic.

A package asset is deleted only once the database stops referencing it, so a
run that rebuilds one package does not strand the other three.

CI does this on every push to `main` and on manual dispatch
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
