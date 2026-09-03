# Installer reference

This document contains advanced and development-oriented details for
`install.sh`. For normal installation and day-to-day usage, see the project
[README](../README.md).

## Source references

The installer downloads all managed project files from one Git reference. Its
default source reference is `main`, but a branch or release tag can be selected
with `--source-ref`.

When piping an installer from a specific ref, use the same ref in both the URL
and `--source-ref`. This keeps the installer and its payload on the same version.

### Current development branch

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/main/install.sh |
sudo bash
```

Because `main` is the default source reference, no extra option is required.

### Versioned release

```bash
release_ref=v0.2.0

wget --quiet --https-only -O- \
"https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/${release_ref}/install.sh" |
sudo bash -s -- --source-ref "$release_ref"
```

Release tags use the project version from the root `VERSION` file with a `v`
prefix. The same form can be used for an older release tag.

### Another branch or ref

```bash
source_ref=my-branch

wget --quiet --https-only -O- \
"https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/${source_ref}/install.sh" |
sudo bash -s -- --source-ref "$source_ref"
```

## Command-line options

```text
Usage: install.sh [--debug] [--source-ref <branch-or-tag>]

Options:
  --debug                       Show detailed operation output
  --source-ref <branch-or-tag>  Download files from this Git ref
  -h, --help                    Show this help message
```

Unknown options, duplicate `--debug` or `--source-ref` options, and invalid
source references are rejected before installation starts.

## Debug mode

`--debug` replaces the compact interactive progress display with detailed
validation, download, checksum, comparison, and recovery messages.

For `main`:

```bash
wget --no-verbose --https-only -O- \
https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/main/install.sh |
sudo bash -s -- --debug
```

For another ref, combine `--debug` with `--source-ref` and use that same ref in
the download URL.

To show installer help without making changes:

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/main/install.sh |
bash -s -- --help
```

## Managed operations

The interactive installer supports installation, updates, repair of modified or
missing managed executables, OpenSSH `Last login` configuration, and
uninstallation.

During an update, the installer compares the installed version, source
reference, and managed checksums with the selected source. If a managed
executable is missing or modified, it reports the mismatch and offers to repair
it from the repository. If the installation is already current and valid, the
managed files are not rewritten.

## Verification and safety

Before making managed changes, the installer:

- downloads the MOTD script, manual command, `VERSION`, and `SHA256SUMS` over
  HTTPS from one source reference;
- verifies all managed SHA-256 checksums;
- validates the Bash syntax of both executable files;
- refuses to overwrite unmanaged target files;
- saves the previous `/etc/motd`, `/etc/issue`, and executable modes of active
  `/etc/update-motd.d` scripts;
- records the installed version, source reference, managed checksums, and
  recovery state under `/var/lib/debian-server-info-motd`;
- attempts automatic rollback if installation, update, repair, or removal
  fails.

While installed, `10-server-info` is the only active dynamic MOTD script managed
by this project. Uninstallation restores the previously saved static MOTD files
and script modes.

## OpenSSH `Last login`

The MOTD does not require OpenSSH and does not read or print login history. The
installer can optionally manage OpenSSH's native `Last login` notice.

If `PrintLastLog` is effectively disabled during a new installation, the
installer offers to enable it explicitly; the default answer is **No**.

For an existing installation, select **Configure OpenSSH Last login**. When a
change is confirmed, the installer:

- creates `/etc/ssh/sshd_config.d/00-debian-server-info-motd.conf` without
  editing existing OpenSSH configuration files;
- validates the complete configuration with `sshd -t` before applying it;
- reloads the active Debian `ssh.service` and verifies the effective setting;
- records ownership of the drop-in in the installation state.

The managed drop-in is removed during uninstallation, restoring the previous
effective configuration. If the file has been modified after installation, the
uninstaller preserves it instead of deleting user changes.

## Installed state

Persistent installer state is stored under:

```text
/var/lib/debian-server-info-motd
```

It tracks the source reference and project version used for the installation,
managed checksums, saved MOTD configuration, and recovery information needed by
update, repair, rollback, and uninstall operations.
