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

  CPU:                     AMD EPYC 9575F 64-Core Processor · 1 vCPU (7%)
  Load average:            0.02 · 0.02 · 0.00 (1m · 5m · 15m)
  Memory:                  0.37 / 1.93 GiB (19%)
  Swap:                    0 / 1.58 GiB (0%)
  Disk (/):                2.31 / 27.8 GiB (9%)

  IPv4 for ens3:           192.0.2.10
  IPv6 for ens3:           2001:db8::10
  Processes:               92
  Login sessions:          2
```

During an interactive SSH login, the MOTD output ends with one blank line so
OpenSSH's native `Last login` notice is visually separated when `PrintLastLog`
is enabled. The project does not read or print login history itself, and the
manual `server-info` command does not add this trailing separator.

## Features

- Debian version and codename, kernel, and architecture
- Physical machine, virtual machine, or container detection
- Human-readable uptime
- CPU model, topology, and current utilization
- Load average, memory, swap, and root filesystem usage
- Independent IPv4 and IPv6 interface detection
- Multiple global addresses per selected interface
- Process and login session counts
- Graceful fallback when optional system information is unavailable
- Manual output without the welcome message through `server-info`
- Optional management of OpenSSH's native `Last login` notice
- Managed installation, updates, repair, rollback, and uninstallation

## Requirements

- Debian 13
- Root privileges, directly or through `sudo`
- `wget`, `sha256sum`, `run-parts`, `sleep`, and `cmp`

Network information requires the `ip` command provided by `iproute2`. If it is
unavailable, the rest of the system summary is still displayed.

Managing the native `Last login` notice requires `openssh-server` and an active
Debian `ssh.service`. The MOTD itself does not require OpenSSH.

## Install

The recommended installation uses the current verified release, **v0.3.0**:

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/v0.3.0/install.sh |
sudo bash -s -- --source-ref v0.3.0
```

Select **Install** from the interactive menu. When already logged in as root,
omit `sudo`.

Open a new SSH or local console session after installation to see the MOTD.

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

Run the installer for the release you want to use and select **Update**. To stay
on v0.3.0:

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/v0.3.0/install.sh |
sudo bash -s -- --source-ref v0.3.0
```

If a managed executable is missing or modified, the installer reports it and
offers to repair the installation. If the installed files, version, and source
reference are already current and valid, they are not rewritten.

## OpenSSH `Last login`

The project leaves OpenSSH configuration unchanged by default. If
`PrintLastLog` is effectively disabled during a new installation, the installer
offers to enable it explicitly; the default answer is **No**.

For an existing installation, run the installer and select **Configure OpenSSH
Last login**. The project uses a separately managed OpenSSH drop-in, validates
the configuration before applying it, and can stop managing the setting again
without forcing `PrintLastLog` off. A modified drop-in is preserved; otherwise
the managed drop-in is removed and OpenSSH resumes using its underlying
configuration. The same cleanup happens during uninstallation.

## Uninstall

Run the installer for the installed release and select **Uninstall**. After
confirmation, it removes the managed files and restores the MOTD configuration
saved during installation.

## Advanced installer usage

Installation from `main` or another Git ref, `--debug`, `--source-ref`, installed
paths, verification details, state handling, and rollback behavior are documented
in [docs/INSTALLER.md](docs/INSTALLER.md).

## License

[MIT](LICENSE)
