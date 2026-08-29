#!/bin/bash

# Prove the published repository end to end, without publishing anything.
#
#   ./scripts/build.sh && ./scripts/publish.sh --local && ./scripts/verify.sh
#
# repo/ is served over HTTP -- the same transport a GitHub release asset URL
# uses -- to a clean archlinux container that has never seen these packages.
# The container trusts nothing but the key the keyring package delivers, and
# `SigLevel = Required` is what makes that trust load-bearing.
#
# Two things are checked that a file:// test cannot: that pacman reaches the
# repository over HTTP, bootstraps the trust anchor out of the keyring package
# and installs under `SigLevel = Required`; and that a HOSTILE mirror gets
# nowhere. The hostile half is the point of signing at all -- a checksum lives
# in a database the attacker rewrites, so the tests serve a package signed by
# an unrelated key and a package with no signature, with a database rebuilt
# around both so nothing but the signature disagrees.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir="$repo_root/repo"
image=${OMARCHY_BUILD_IMAGE:-archlinux:latest}

[[ -f $repo_dir/omarchy-server.db ]] || {
  echo "Error: $repo_dir has no omarchy-server.db. Run scripts/publish.sh --local first." >&2
  exit 1
}

docker run --rm -v "$repo_dir:/served:ro" "$image" bash -euo pipefail -c '
    fail=0
    check() {
      local label="$1"; shift
      if "$@" >/tmp/check.out 2>&1; then
        echo "  PASS  $label"
      else
        echo "  FAIL  $label"
        sed "s/^/        /" /tmp/check.out
        fail=1
      fi
    }
    # The negative half of the suite: the command MUST fail, and its output
    # must say why. A test that only asserts a non-zero exit passes when pacman
    # fails for an unrelated reason.
    check_rejected() {
      local label="$1" pattern="$2"; shift 2
      if "$@" >/tmp/check.out 2>&1; then
        echo "  FAIL  $label (the command SUCCEEDED)"
        sed "s/^/        /" /tmp/check.out
        fail=1
      elif grep -qiE "$pattern" /tmp/check.out; then
        echo "  PASS  $label"
      else
        echo "  FAIL  $label (rejected, but not for the expected reason)"
        sed "s/^/        /" /tmp/check.out
        fail=1
      fi
    }

    echo "== serving the repository over HTTP =="
    # The archlinux image ships neither python nor a web server.
    pacman -Sy --noconfirm --needed python >/dev/null
    # A pristine copy: the mount is read-only and the tamper stage below needs
    # to rewrite a database.
    cp -a /served /srv-good
    cp -a /served /srv-tampered
    (cd /srv-good && python3 -m http.server 8080 --bind 127.0.0.1 >/tmp/http-good.log 2>&1) &
    (cd /srv-tampered && python3 -m http.server 8081 --bind 127.0.0.1 >/tmp/http-bad.log 2>&1) &
    for _ in $(seq 1 50); do
      curl -fsS http://127.0.0.1:8080/omarchy-server.db -o /dev/null 2>/dev/null && break
      sleep 0.2
    done
    check "the database is reachable over HTTP" \
      curl -fsS http://127.0.0.1:8080/omarchy-server.db -o /tmp/probe.db

    cat >>/etc/pacman.conf <<EOF

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/\$arch

[omarchy-server]
SigLevel = Required DatabaseOptional
Server = http://127.0.0.1:8080
EOF

    echo
    echo "== keyring bootstrap =="
    pacman-key --init >/dev/null
    pacman-key --populate archlinux >/dev/null

    # The keyring package is signed by the very key it delivers, so it cannot
    # verify itself. The bootstrap is the same one archlinux-keyring needs:
    # fetch the package, read the key out of it, trust it locally, then install
    # the package under full verification. Everything after this point is
    # verified against that key.
    keyring_file=$(bsdtar -xOf /srv-good/omarchy-server.db "*/desc" |
      awk "/^%FILENAME%\$/ { getline; print }" | grep "^omarchy-server-keyring-")
    curl -fsS "http://127.0.0.1:8080/$keyring_file" -o "/tmp/$keyring_file"
    curl -fsS "http://127.0.0.1:8080/$keyring_file.sig" -o "/tmp/$keyring_file.sig"
    bsdtar -xOf "/tmp/$keyring_file" usr/share/pacman/keyrings/omarchy-server.gpg \
      >/tmp/omarchy-server.gpg
    bsdtar -xOf "/tmp/$keyring_file" usr/share/pacman/keyrings/omarchy-server-trusted \
      >/tmp/omarchy-server-trusted
    repo_key=$(cut -d: -f1 /tmp/omarchy-server-trusted)
    pacman-key --add /tmp/omarchy-server.gpg
    pacman-key --lsign-key "$repo_key"
    pacman -U --noconfirm "/tmp/$keyring_file"
    pacman-key --populate omarchy-server
    check "the repository key is in the pacman keyring" bash -c \
      "pacman-key --list-keys $repo_key | grep -q $repo_key"

    echo
    echo "== installing from the served repository =="
    pacman -Sy --noconfirm
    check "pacman synced the [omarchy-server] database" bash -c \
      "test -s /var/lib/pacman/sync/omarchy-server.db"
    check "the repository offers this profile packages" bash -c \
      "pacman -Sl omarchy-server | awk \"{print \\\$2}\" | sort >/tmp/list; for p in fwall omarchy-server omarchy-server-keyring omarchy-server-settings; do grep -qx \"\$p\" /tmp/list || exit 1; done"

    # SigLevel = Required is in force for both of these; an unsigned or badly
    # signed package would stop the transaction here.
    check "fwall installs from the remote repository" bash -c \
      "pacman -S --noconfirm fwall && test -x /usr/bin/fwall"
    check "omarchy-server installs from the remote repository" bash -c \
      "pacman -S --noconfirm omarchy-server && test -L /usr/bin/omarchy-version"
    check "the installed packages report the repository they came from" bash -c \
      "pacman -Qi omarchy-server | grep -qE \"^Version +: 4\\.0\\.1-1\" && pacman -Qi fwall | grep -qE \"^Version +: 0\\.1\\.0-1\""
    check "SigLevel = Required is actually in force" bash -c \
      "pacman-conf --repo=omarchy-server | grep -q \"SigLevel = PackageRequired\""
    check "the profile shipped its own repository definition" bash -c \
      "grep -qx \"Server = https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo\" /etc/pacman.d/omarchy-server.conf"

    echo
    echo "== a tampered package is refused =="
    # The realistic attack is not a flipped bit -- a checksum catches that, and
    # the checksum lives in a database the same attacker just rewrote. It is a
    # mirror that serves a package signed by SOMEBODY ELSE'"'"'S key, with a
    # database rebuilt around it so every checksum agrees. The only thing left
    # standing between that mirror and the machine is `SigLevel = Required`
    # against the key the keyring package delivered.
    export GNUPGHOME=/root/.gnupg-attacker
    install -d -m 700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase "" --quick-generate-key \
      "Not The Omarchy Server Key <attacker@example.invalid>" ed25519 sign never
    attacker_key=$(gpg --with-colons --list-secret-keys |
      awk -F: "/^fpr/ { print \$10; exit }")
    tampered=$(ls /srv-tampered/fwall-*.pkg.tar.zst)
    rm -f "$tampered.sig"
    gpg --batch --yes --detach-sign --no-armor -u "$attacker_key" -o "$tampered.sig" "$tampered"
    unset GNUPGHOME

    # The database is rebuilt (and left unsigned, which DatabaseOptional
    # allows) so nothing about it contradicts the package it points at.
    rm -f /srv-tampered/omarchy-server.db.sig /srv-tampered/omarchy-server.db.tar.gz.sig \
      /srv-tampered/omarchy-server.files.sig /srv-tampered/omarchy-server.files.tar.gz.sig
    repo-add /srv-tampered/omarchy-server.db.tar.gz /srv-tampered/*.pkg.tar.zst >/dev/null
    rm -f /srv-tampered/omarchy-server.db /srv-tampered/omarchy-server.files
    cp -f /srv-tampered/omarchy-server.db.tar.gz /srv-tampered/omarchy-server.db
    cp -f /srv-tampered/omarchy-server.files.tar.gz /srv-tampered/omarchy-server.files

    pacman -Rns --noconfirm fwall >/dev/null
    # The good package is in the download cache under the same file name, and a
    # cached file is not re-downloaded. Without this the test would verify the
    # copy it already trusts.
    rm -f /var/cache/pacman/pkg/fwall-*
    # The signature of the GOOD database is still in the sync directory, and a
    # -Syy that finds no .sig on the new mirror leaves it there to be checked
    # against a database it does not belong to.
    rm -f /var/lib/pacman/sync/omarchy-server.db.sig
    sed -i "s#Server = http://127.0.0.1:8080#Server = http://127.0.0.1:8081#" /etc/pacman.conf
    pacman -Syy --noconfirm >/dev/null

    # pacman answers a signature it cannot chain to a trusted key with
    # "required key missing from keyring": the attacker key is a perfectly
    # valid signature by a stranger, and a stranger is not the keyring.
    check_rejected "a package signed by another key is rejected" \
      "required key missing from keyring|unknown trust|invalid or corrupted" \
      pacman -S --noconfirm fwall
    check "the package from the hostile mirror did not install" bash -c \
      "! pacman -Qq fwall >/dev/null 2>&1"

    # And with no signature at all, which is what an attacker who has no key
    # would serve.
    rm -f "$tampered.sig" /var/cache/pacman/pkg/fwall-*
    # With Required the .sig is not optional metadata but a file of the
    # transaction, so its absence stops the download rather than the install.
    check_rejected "an unsigned package is rejected" \
      "pkg\.tar\.zst\.sig|missing required signature|invalid or corrupted" \
      pacman -S --noconfirm fwall
    check "the unsigned package did not install" bash -c \
      "! pacman -Qq fwall >/dev/null 2>&1"

    echo
    if (( fail )); then
      echo "RESULT: FAILED"
      exit 1
    fi
    echo "RESULT: OK"
  '
