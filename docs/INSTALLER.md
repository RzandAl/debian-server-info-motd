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
https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/main/install.sh |
sudo bash
```

Because `main` is the default source reference, no extra option is required.

### Versioned release

```bash
release_ref=v0.4.0

wget --quiet --https-only -O- \
"https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/${release_ref}/install.sh" |
sudo bash -s -- --source-ref "$release_ref"
```

Release tags use the project version from the root `VERSION` file with a `v`
prefix. The same form can be used for an older release tag.

### Another branch or ref

```bash
source_ref=my-branch

wget --quiet --https-only -O- \
"https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/${source_ref}/install.sh" |
sudo bash -s -- --source-ref "$source_ref"
```

## Command-line options

```text
Usage: install.sh [--debug] [--source-ref <ref>] [--install|--update|--repair|--check|--uninstall]

Options:
  --debug                       Show detailed operation output
  --source-ref <branch-or-tag>  Download files from this Git ref
  --install                    Install or update without interactive questions
  --update                     Update an existing installation without questions
  --repair                     Explicitly repair managed executables without questions
  --check                      Print read-only JSON installation health
  --uninstall                  Explicitly uninstall without questions
  --source-directory <path>    Use a protected local source with an explicit ref
  --root <path>                Inspect a protected target root; --check only
  -h, --help                    Show this help message
```

Unknown options, duplicate `--debug` or `--source-ref` options, and invalid
source references are rejected before installation starts.

## Automation

Select one explicit action to bypass the menu and all `/dev/tty` questions.
Every automated mutation requires `--source-ref`; no action flag preserves the
existing interactive behavior. An explicit automated uninstall is the caller's
authorization to remove the managed installation and restore its saved MOTD.

```bash
sudo bash install.sh --install --source-ref v0.4.0
sudo bash install.sh --check --source-ref v0.4.0
sudo bash install.sh --repair --source-ref v0.4.0
```

`--install` ensures installation: a fresh install, a healthy matching no-op,
or an update to the selected source. `--update` requires existing managed state.
Neither silently overwrites modified/missing managed executables; that requires
`--repair`. Repair reuses the native update transaction and original backups.
Unexpected symlinks, unmanaged files, invalid state, or changed static MOTD and
saved script modes remain blockers rather than being overwritten.

Automated installation never detects, prompts for, or changes OpenSSH's
`PrintLastLog`. An update preserves existing optional Last login management.
Explicit uninstall follows the native ownership rules for any existing managed
drop-in; automatic installation does not create one.

### Read-only health

`--check` creates no installation state or lock file and performs no downloads.
It validates native state, metadata and saved SHA-256 values before invoking
healthy managed executables with bounded timeouts. Missing or modified executables
are reported without executing them. `os-release` is parsed as data, never
sourced as a shell script. Output is one JSON object; debug/errors go to stderr.

| Status | Meaning |
| --- | --- |
| `0` | Healthy installed state; requested source matches when specified |
| `1` | Invalid/unsupported state, ownership/conflict, or execution error |
| `2` | Invalid or ambiguous arguments |
| `3` | Cleanly absent installation; JSON has `installed: false` |
| `4` | Managed executables missing, modified, or failing runtime verification |
| `5` | Healthy installation with a different requested source reference |

Installed JSON includes schema version, installed/healthy flags, requested-source
match, installed ref/version, payload/command SHA-256, executable statuses and
existing Last login management/status. Checks without `--source-ref` assess the
recorded installation. Callers must also compare the returned version and hashes
with their independently pinned source; a version marker alone is insufficient.

`--check --root /protected/target` inspects an alternate root, including its
Debian identity. Runtime checks use chroot into that root. The root must be
canonical, root-owned and protected; writable non-sticky ancestors are refused.
`--root` is rejected for mutations. Production install paths remain unchanged.

### Protected source staging

`--source-directory /protected/source` is available with `--install`, `--update`
or `--repair` and an explicit ref. The staged tree must contain the exact MOTD
script, manual command, `VERSION` and `SHA256SUMS` paths used by network downloads.
Files and directories must be regular/real, root-owned and protected from group
or other writes, with protected ancestors. The same checksum and Bash syntax
verification runs before writes; no network request is made.

Automation callers should stage and independently verify one immutable release,
including the installer itself, before executing it. This option does not make
an unknown local source trusted merely because it supplies its own manifest.

### Concurrency and recovery limits

Installer instances take a nonblocking exclusive lock on the existing target
`/var/lib` directory inode. This serializes cooperating instances without a new
lock file, including read-only checks; unrelated tools do not use this contract.
Filesystem and recovery checks remain necessary even while that lock is held.

Each managed executable verification has a 15-second timeout and a 3-second
forced-stop grace. Normal failures and handled signals reuse native rollback
and preserve incomplete recovery data. SIGKILL or power loss cannot execute a
shell trap; this installer does not claim independent crash/reboot recovery.
An orchestrator must report an interrupted module separately and keep an
already verified Base intact. Do not treat missing final state as proof that no
module writes occurred, or remove unmanaged files to hide an interruption.

Primary references: [flock(1)](https://manpages.debian.org/trixie/util-linux/flock.1.en.html)
and [timeout(1)](https://manpages.debian.org/trixie/coreutils/timeout.1.en.html).

## Debug mode

`--debug` replaces the compact interactive progress display with detailed
validation, download, checksum, comparison, and recovery messages.

For `main`:

```bash
wget --no-verbose --https-only -O- \
https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/main/install.sh |
sudo bash -s -- --debug
```

For another ref, combine `--debug` with `--source-ref` and use that same ref in
the download URL.

To show installer help without making changes:

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/main/install.sh |
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

Select the same action again to stop management. If the managed drop-in still
matches the recorded checksum, the installer removes it, validates the complete
OpenSSH configuration, reloads `ssh.service`, and reports the resulting
effective setting. This does not force `PrintLastLog no`; OpenSSH resumes using
the remaining system configuration.

If the managed drop-in is already missing, the installer removes only the stale
ownership record. If it was modified after installation, the installer preserves
the file byte-for-byte and removes only its ownership record. Every path is
transactional: a failed validation or reload restores the previous file and
state.

Uninstallation follows the same ownership rules. An unchanged managed drop-in
is removed, while a modified file is preserved instead of deleting user changes.

## Installed paths

| Path | Purpose |
| --- | --- |
| `/etc/update-motd.d/10-server-info` | Dynamic login summary |
| `/usr/local/bin/server-info` | Manual system information command |
| `/var/lib/debian-server-info-motd/` | Version, source ref, checksums, backups, and installation state |
| `/etc/ssh/sshd_config.d/00-debian-server-info-motd.conf` | Optional managed OpenSSH `Last login` setting |

## Installed state

Persistent installer state is stored under:

```text
/var/lib/debian-server-info-motd
```

It tracks the source reference and project version used for the installation,
managed checksums, saved MOTD configuration, and recovery information needed by
update, repair, rollback, and uninstall operations.
