# Prepare a GnuPG home the `builder` user can sign with, and set `sign_args`
# for makepkg. Sourced by scripts/build.sh and scripts/build-selinux.sh, which
# both run as root inside a build container.
#
# Inputs (environment):
#   OMARCHY_NO_SIGN=1   skip signing entirely; sign_args stays empty
#   GNUPGHOME_HOST      a GnuPG home bind mounted from the host (read-only)
#   GNUPGHOME           a GnuPG home already readable here
#   OMARCHY_SIGN_KEY    which key to use when the home holds more than one
#
# Outputs: $gnupg_dir, $sign_key, $sign_args.
#
# Nothing about the key material comes from this repository — only the PUBLIC
# half is here, inside pkgbuilds/omarchy-server-keyring/.

prepare_signing_key() {
  sign_args=()
  sign_key=""
  gnupg_dir=/home/builder/gnupg

  if [[ ${OMARCHY_NO_SIGN:-0} == 1 ]]; then
    return 0
  fi

  # A GnuPG home mounted from the host is read-only and owned by another uid;
  # copy it where the builder can use it.
  install -d -m 700 -o builder -g builder "$gnupg_dir"
  if [[ -n ${GNUPGHOME_HOST:-} ]]; then
    cp -a "$GNUPGHOME_HOST/." "$gnupg_dir/"
  elif [[ -n ${GNUPGHOME:-} && $GNUPGHOME != "$gnupg_dir" ]]; then
    cp -a "$GNUPGHOME/." "$gnupg_dir/"
  else
    echo "Error: no GNUPGHOME with the signing key (or set OMARCHY_NO_SIGN=1)." >&2
    exit 1
  fi

  # An unattended signer cannot answer a pinentry prompt. When the GnuPG home
  # carries a `passphrase` file (the workflow writes one from the
  # PACMAN_GPG_PASSPHRASE secret), point gpg at it through loopback pinentry.
  # The path has to be rewritten here because the home just moved.
  if [[ -f $gnupg_dir/passphrase ]]; then
    printf 'pinentry-mode loopback\npassphrase-file %s\n' "$gnupg_dir/passphrase" \
      >>"$gnupg_dir/gpg.conf"
    echo "allow-loopback-pinentry" >>"$gnupg_dir/gpg-agent.conf"
    chmod 600 "$gnupg_dir/passphrase"
  fi

  # A GnuPG home copied from somewhere else can carry that other agent's
  # sockets. gpg would try to reuse them and fail with a key that is plainly
  # there; deleting them makes the builder's first gpg call start its own.
  rm -f "$gnupg_dir"/S.*

  chown -R builder:builder "$gnupg_dir"
  chmod 700 "$gnupg_dir"

  # Every gpg call from here on runs AS THE BUILDER, so no root-owned agent
  # socket is ever left behind in the builder's home.
  sign_key=${OMARCHY_SIGN_KEY:-}
  if [[ -z $sign_key ]]; then
    sign_key=$(as_builder "GNUPGHOME='$gnupg_dir' gpg --with-colons --list-secret-keys" |
      awk -F: '$1 == "fpr" { print $10; exit }')
  fi
  [[ -n $sign_key ]] || { echo "Error: no secret key found in the GnuPG home." >&2; exit 1; }
  echo "Signing with $sign_key"
  sign_args=(--sign --key "$sign_key")
}
