# Debian Server Info MOTD

Lightweight dynamic system information MOTD for Debian 13 servers.

It displays a compact system summary on SSH and local console logins. The same
information is also available at any time through the `server-info` command.

## Example output

```text
Welcome to debian-server running Debian 13 (trixie)

System information as of 02.09.2026 15:11 UTC

  Kernel:                  6.12.105+deb13-amd64, x86_64
  System type:             Virtual machine (KVM)

  Uptime:                  7 days, 12 hours, 36 minutes

  CPU:                     AMD EPYC 9575F 64-Core Processor · 1 vCPU
  Load average:            0.02 · 0.02 · 0.00 (1m · 5m · 15m)
  Memory:                  0.37 / 1.93 GiB (19%)
  Swap:                    0 / 1.58 GiB (0%)
  Disk (/):                2.31 / 27.8 GiB (9%)

  IPv4 for ens3:           192.0.2.10
  IPv6 for ens3:           2001:db8::10
  Processes:               92
  Login sessions:          2
```

## Features

- Debian version and codename, kernel, and architecture
- Physical machine, virtual machine, or container detection
- Human-readable uptime
- CPU model and virtual CPU count, or physical core and thread counts
- Load average, memory, swap, and root filesystem usage
- Independent IPv4 and IPv6 interface detection
- Multiple global addresses per selected interface
- Process and login session counts
- Graceful fallback when optional system information is unavailable
- Manual output without the welcome message through `server-info`
- Managed installation, updates, repair, rollback, and uninstallation

## Requirements

- Debian 13
- Root privileges, directly or through `sudo`
- `wget`, `sha256sum`, `run-parts`, `sleep`, and `cmp`

Network information requires the `ip` command provided by `iproute2`. If it is
unavailable, the rest of the system summary is still displayed.

## Install from `main`

The default installation follows the current `main` branch:

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/main/install.sh |
sudo bash
```

Select **Install** from the interactive menu. When already logged in as root,
omit `sudo`.

Open a new SSH or local console session after installation to see the MOTD.

## Install a versioned release

For a reproducible installation, use the same release tag in the download URL
and in `--source-ref`:

```bash
release_ref=v0.1.0

wget --quiet --https-only -O- \
"https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/${release_ref}/install.sh" |
sudo bash -s -- --source-ref "$release_ref"
```

The project version is defined in the root `VERSION` file. Release tags use the
same number with a `v` prefix. The installer verifies `VERSION` together with
both executable files and records the installed version and source reference in
its managed state.

## Manual usage

Show the same system information without the welcome message:

```bash
server-info
```

Show command help:

```bash
server-info --help
```

## Update or repair

Run the installer again with the same source reference you chose during
installation. For the current `main` branch:

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/main/install.sh |
sudo bash
```

Select **Update**. If either managed executable is missing or modified, the
installer reports it and offers to repair the installation from the repository.
When the files, version, and source reference are already current and valid, no
installed file is rewritten.

To move an installation to another branch or release, run that ref's installer
and pass the same ref explicitly through `--source-ref`.

## Uninstall

Run the same installer and select **Uninstall**. After confirmation, it removes
the managed files and restores the MOTD configuration saved during installation.

## Installer behavior

The installer:

- downloads the MOTD script, manual command, `VERSION`, and `SHA256SUMS` over
  HTTPS from one source reference;
- verifies all managed SHA-256 checksums and both scripts' Bash syntax before
  making changes;
- refuses to overwrite unmanaged target files;
- backs up `/etc/motd`, `/etc/issue`, and the executable modes of active
  `/etc/update-motd.d` scripts;
- makes `10-server-info` the only active dynamic MOTD script while installed;
- records the installed version, source reference, managed checksums, and
  recovery state under
  `/var/lib/debian-server-info-motd`;
- attempts an automatic rollback if installation, update, repair, or removal
  fails;
- restores the previous static MOTD files and script modes during uninstallation.

## Debug mode

Use `--debug` to show validation, download, checksum, comparison, and recovery
details:

```bash
wget --no-verbose --https-only -O- \
https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/main/install.sh |
sudo bash -s -- --debug
```

Use `--source-ref <branch-or-tag>` together with `--debug` when inspecting a
specific release or development branch. Successful installation, update,
repair, and removal messages include the relevant project version.

Show all installer options without making changes:

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RazisID12/debian-server-info-motd/main/install.sh |
bash -s -- --help
```

## Installed files

| Path | Purpose |
| --- | --- |
| `/etc/update-motd.d/10-server-info` | Dynamic login summary |
| `/usr/local/bin/server-info` | Manual system information command |
| `/var/lib/debian-server-info-motd/` | Version, source ref, checksums, backups, and installation state |

## License

[MIT](LICENSE)
