"""Automation regressions use redirected roots; native smoke requires owned CI."""

import hashlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PAYLOAD = "etc/update-motd.d/10-server-info"
COMMAND = "usr/local/bin/server-info"
REF = "v0.4.0"


def snapshot(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"kind": "absent"}
    value = {"mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}
    if stat.S_ISLNK(info.st_mode):
        return {**value, "kind": "symlink", "target": str(path.readlink())}
    if stat.S_ISDIR(info.st_mode):
        return {**value, "kind": "directory"}
    return {**value, "kind": "regular", "mtime": info.st_mtime_ns,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


class Fixture:
    def __init__(self, *, native=False):
        self.directory = Path(tempfile.mkdtemp(prefix="rzandal-motd-auto-"))
        self.native = native
        self.root = Path("/") if native else self.directory / "root"
        self.source = self.directory / "source"
        self.source.mkdir(mode=0o700)
        self.installer = self.directory / "install.sh"
        text = (REPO / "install.sh").read_text()
        if native:
            if (os.geteuid() != 0 or os.environ.get("RZANDAL_MOTD_CI") != "1"
                    or not Path("/.dockerenv").is_file()):
                raise RuntimeError("Native smoke requires the owned disposable CI container")
            if self.path("/var/lib/debian-server-info-motd").exists():
                raise RuntimeError("Native smoke refuses an existing installation")
        else:
            for name, path in (("MOTD_DIRECTORY", "/etc/update-motd.d"),
                               ("COMMAND_DIRECTORY", "/usr/local/bin"),
                               ("MOTD_FILE", "/etc/motd"), ("ISSUE_FILE", "/etc/issue"),
                               ("STATE_DIRECTORY", "/var/lib/debian-server-info-motd"),
                               ("SSHD_CONFIG_DIRECTORY", "/etc/ssh/sshd_config.d")):
                old = next(line for line in text.splitlines() if line.startswith(f"readonly {name}="))
                text = text.replace(old, f'readonly {name}="{self.path(path)}"')
            text = text.replace('/etc/os-release', str(self.path('/etc/os-release')))
            text = text.replace('"/var/lib/.${PROJECT_ID}.XXXXXX"',
                                f'"{self.root}/var/lib/.${{PROJECT_ID}}.XXXXXX"')
            self.path("/etc/os-release").parent.mkdir(parents=True)
            self.path("/etc/os-release").write_text("ID=debian\nNAME=Debian\nVERSION_ID=13\n")
        self.installer.write_text(text)
        for directory in ("/etc/update-motd.d", "/usr/local/bin", "/var/lib", "/etc/ssh/sshd_config.d"):
            self.path(directory).mkdir(parents=True, exist_ok=True)
        self.path("/etc/motd").write_text("Original static MOTD\n")
        self.path("/etc/issue").write_text("Original issue\n")
        self.path("/etc/update-motd.d/05-original").write_text("#!/bin/sh\nprintf 'Original dynamic MOTD\\n'\n")
        self.path("/etc/update-motd.d/05-original").chmod(0o751)
        self.path("/etc/ssh/sshd_config.d/99-existing.conf").write_text("PrintLastLog no\n")
        self.stage()
        self.initial = self.capture()

    def path(self, absolute):
        return self.root / absolute.lstrip("/")

    def stage(self, *, version="0.4.0", payload=None):
        for name in (PAYLOAD, COMMAND):
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            content = (REPO / name).read_text()
            if name == COMMAND and not self.native:
                content = content.replace('readonly MOTD_SCRIPT="/etc/update-motd.d/10-server-info"',
                                          f'readonly MOTD_SCRIPT="{self.path("/etc/update-motd.d/10-server-info")}"')
            if name == PAYLOAD and payload is not None:
                content = payload
            target.write_text(content)
        (self.source / "VERSION").write_text(version + "\n")
        self.checksums()

    def checksums(self):
        (self.source / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256((self.source / name).read_bytes()).hexdigest()}  {name}\n"
            for name in ("VERSION", PAYLOAD, COMMAND)))

    def capture(self):
        roots = [self.path(p) for p in ("/etc/update-motd.d", "/usr/local/bin/server-info",
                 "/var/lib/debian-server-info-motd", "/etc/motd", "/etc/issue", "/etc/ssh/sshd_config.d")]
        paths = set(roots)
        for root in roots:
            if root.is_dir() and not root.is_symlink():
                paths.update(root.rglob("*"))
        return {str(p): snapshot(p) for p in sorted(paths)}

    def run(self, action, *, ref=REF):
        args = ["bash", str(self.installer), "--" + action]
        if ref is not None:
            args += ["--source-ref", ref]
        if action not in {"check", "uninstall"}:
            args += ["--source-directory", str(self.source)]
        return subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              start_new_session=True, timeout=40)

    def close(self):
        shutil.rmtree(self.directory)


class OptionsTests(unittest.TestCase):
    def test_unsafe_or_ambiguous_options_fail_before_host_access(self):
        for args in (["--install"], ["--update"], ["--repair"], ["--uninstall"],
                     ["--check", "--install"], ["--install", "--install"],
                     ["--install", "--source-ref", REF, "--root", "/tmp"], ["--check", "--root", "relative"],
                     ["--source-directory", "relative"], ["--check", "--source-directory", "/tmp"],
                     ["--install", "--source-ref", "../main"],
                     ["--install", "--source-ref", REF, "--source-directory", "/tmp", "--source-directory", "/tmp"]):
            with self.subTest(args=args):
                result = subprocess.run(["bash", str(REPO / "install.sh"), *args], capture_output=True,
                                        text=True, stdin=subprocess.DEVNULL, timeout=5)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


@unittest.skipUnless(os.geteuid() == 0, "Native ownership checks require root")
class AutomationTests(unittest.TestCase):
    def fixture(self):
        value = Fixture()
        self.addCleanup(value.close)
        return value

    def succeeds(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_absent_check_is_json_and_creates_no_target_state(self):
        fixture = self.fixture()
        before = fixture.capture()
        result = fixture.run("check")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertFalse(json.loads(result.stdout)["installed"])
        self.assertEqual(fixture.capture(), before)

    def test_unmodified_installer_checks_a_target_root_without_writing_or_sourcing_os_release(self):
        fixture = self.fixture()
        marker = fixture.directory / "must-not-exist"
        fixture.path("/etc/os-release").write_text(f'ID=\'debian\'\nVERSION_ID=\'13\'\nignored=$(touch "{marker}")\n')
        before = fixture.capture()
        result = subprocess.run(["bash", str(REPO / "install.sh"), "--check", "--root", str(fixture.root)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, start_new_session=True, timeout=10)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertFalse(json.loads(result.stdout)["installed"])
        self.assertFalse(marker.exists())
        self.assertEqual(fixture.capture(), before)

    def test_install_without_tty_check_and_repeat_preserve_files_and_ssh(self):
        fixture = self.fixture()
        ssh = fixture.capture()[str(fixture.path("/etc/ssh/sshd_config.d/99-existing.conf"))]
        self.succeeds(fixture.run("install"))
        healthy = fixture.capture()
        checked = fixture.run("check")
        self.succeeds(checked)
        value = json.loads(checked.stdout)
        self.assertTrue(value["healthy"] and value["desired_source_matches"])
        self.assertEqual(value["version"], "0.4.0")
        self.assertFalse(value["last_login_managed"])
        self.succeeds(fixture.run("install"))
        self.assertEqual(fixture.capture(), healthy)
        self.assertEqual(snapshot(fixture.path("/etc/ssh/sshd_config.d/99-existing.conf")), ssh)

    def test_modified_file_requires_explicit_repair(self):
        fixture = self.fixture()
        self.succeeds(fixture.run("install"))
        target = fixture.path("/" + PAYLOAD)
        target.write_text(target.read_text() + "# local modification\n")
        before = fixture.capture()
        checked = fixture.run("check")
        self.assertEqual(checked.returncode, 4)
        self.assertEqual(json.loads(checked.stdout)["target_status"], "modified")
        refused = fixture.run("update")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("use --repair explicitly", refused.stderr)
        self.assertEqual(fixture.capture(), before)
        self.succeeds(fixture.run("repair"))
        self.succeeds(fixture.run("check"))

    def test_missing_manual_command_is_repaired(self):
        fixture = self.fixture()
        self.succeeds(fixture.run("install"))
        fixture.path("/" + COMMAND).unlink()
        checked = fixture.run("check")
        self.assertEqual(checked.returncode, 4)
        self.assertEqual(json.loads(checked.stdout)["command_status"], "missing")
        self.succeeds(fixture.run("repair"))
        self.succeeds(fixture.run("check"))

    def test_v031_state_upgrade_retains_original_backups(self):
        fixture = self.fixture()
        fixture.stage(version="0.3.1")
        self.succeeds(fixture.run("install", ref="v0.3.1"))
        before = fixture.capture()
        result = fixture.run("check")
        self.assertEqual(result.returncode, 5)
        self.assertFalse(json.loads(result.stdout)["desired_source_matches"])
        self.assertEqual(fixture.capture(), before)
        fixture.stage()
        self.succeeds(fixture.run("update"))
        self.assertEqual(json.loads(fixture.run("check").stdout)["version"], "0.4.0")
        for path, record in before.items():
            if "/backup/" in path:
                self.assertEqual(snapshot(Path(path)), record)

    def test_corrupt_download_checksum_fails_before_writes(self):
        fixture = self.fixture()
        (fixture.source / PAYLOAD).write_text("#!/bin/bash\nexit 0\n")
        before = fixture.capture()
        result = fixture.run("install")
        self.assertEqual(result.returncode, 1)
        self.assertIn("checksum verification failed", result.stderr)
        self.assertEqual(fixture.capture(), before)

    def test_invalid_verified_bash_fails_before_writes(self):
        fixture = self.fixture()
        fixture.stage(payload="#!/bin/bash\nif\n")
        before = fixture.capture()
        result = fixture.run("install")
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid Bash syntax", result.stderr)
        self.assertEqual(fixture.capture(), before)

    def test_unprotected_source_is_refused(self):
        fixture = self.fixture()
        (fixture.source / COMMAND).chmod(0o666)
        before = fixture.capture()
        result = fixture.run("install")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not protected", result.stderr)
        self.assertEqual(fixture.capture(), before)

    def test_unmanaged_target_is_preserved(self):
        fixture = self.fixture()
        fixture.path("/" + COMMAND).write_text("Unmanaged command\n")
        before = fixture.capture()
        self.assertEqual(fixture.run("install").returncode, 1)
        self.assertEqual(fixture.capture(), before)

    def test_failed_install_restores_original_files_modes_and_absence(self):
        fixture = self.fixture()
        before = fixture.capture()
        fixture.stage(payload="#!/bin/bash\nexit 9\n")
        result = fixture.run("install")
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
        self.assertIn("all changes were rolled back", result.stderr)
        self.assertEqual(fixture.capture(), before)

    def test_failed_update_restores_previous_managed_files_and_state(self):
        fixture = self.fixture()
        self.succeeds(fixture.run("install"))
        before = fixture.capture()
        fixture.stage(version="0.4.1", payload="#!/bin/bash\nexit 9\n")
        result = fixture.run("update", ref="v0.4.1")
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
        self.assertEqual(fixture.capture(), before)
        self.succeeds(fixture.run("check"))

    def test_explicit_uninstall_restores_saved_motd_and_modes(self):
        fixture = self.fixture()
        self.succeeds(fixture.run("install"))
        self.succeeds(fixture.run("uninstall"))
        self.assertEqual(fixture.capture(), fixture.initial)
        self.succeeds(fixture.run("uninstall"))

    def test_check_refuses_a_competing_transaction_without_changes(self):
        fixture = self.fixture()
        before = fixture.capture()
        descriptor = os.open("/var/lib", os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = fixture.run("check")
            self.assertEqual(result.returncode, 1)
            self.assertIn("another MOTD installer is active", result.stderr)
        finally:
            os.close(descriptor)
        self.assertEqual(fixture.capture(), before)

    def test_check_refuses_symlink_state_without_following_it(self):
        fixture = self.fixture()
        self.succeeds(fixture.run("install"))
        outside = fixture.directory / "outside-version"
        outside.write_text("0.4.0\n")
        state = fixture.path("/var/lib/debian-server-info-motd/version")
        state.unlink()
        state.symlink_to(outside)
        before, outside_before = fixture.capture(), snapshot(outside)
        result = fixture.run("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid installation state file", result.stderr)
        self.assertEqual(fixture.capture(), before)
        self.assertEqual(snapshot(outside), outside_before)

    def test_update_preserves_existing_managed_last_login(self):
        fixture = self.fixture()
        self.succeeds(fixture.run("install"))
        dropin = fixture.path("/etc/ssh/sshd_config.d/00-debian-server-info-motd.conf")
        dropin.write_text("# Managed by Debian Server Info MOTD.\nPrintLastLog yes\n")
        dropin.chmod(0o644)
        record = fixture.path("/var/lib/debian-server-info-motd/last-login.sha256")
        record.write_text(hashlib.sha256(dropin.read_bytes()).hexdigest() + "\n")
        before = {str(p): snapshot(p) for p in (dropin, record)}
        fixture.stage(version="0.4.1")
        self.succeeds(fixture.run("update", ref="v0.4.1"))
        self.assertEqual({str(p): snapshot(p) for p in (dropin, record)}, before)
        self.assertTrue(json.loads(fixture.run("check", ref="v0.4.1").stdout)["last_login_managed"])


if __name__ == "__main__":
    unittest.main()
