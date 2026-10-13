"""Unmodified installer and real payload, only inside the owned Debian CI root."""

import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("automation", Path(__file__).with_name("test-automation.py"))
automation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(automation)


class NativeAutomationTests(unittest.TestCase):
    def succeeds(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_full_lifecycle_without_tty_preserves_base_and_ssh(self):
        fixture = automation.Fixture(native=True)
        self.addCleanup(fixture.close)
        protected = [Path(p) for p in ("/etc/hostname", "/etc/resolv.conf", "/etc/default/locale",
                     "/etc/localtime", "/etc/timezone", "/etc/apt/sources.list",
                     "/etc/ssh/sshd_config.d/99-existing.conf")]
        before_base = {str(p): automation.snapshot(p) for p in protected}
        result = fixture.run("check")
        self.assertEqual(result.returncode, 3)
        self.assertFalse(json.loads(result.stdout)["installed"])
        self.assertEqual(fixture.capture(), fixture.initial)

        fixture.stage(version="0.3.1")
        self.succeeds(fixture.run("install", ref="v0.3.1"))
        self.assertEqual(fixture.run("check").returncode, 5)
        fixture.stage()
        self.succeeds(fixture.run("update"))
        self.succeeds(fixture.run("check"))
        healthy = fixture.capture()
        self.succeeds(fixture.run("install"))
        self.assertEqual(fixture.capture(), healthy)
        self.assertFalse(json.loads(fixture.run("check").stdout)["last_login_managed"])

        command = fixture.path("/" + automation.COMMAND)
        command.unlink()
        self.assertEqual(fixture.run("check").returncode, 4)
        self.succeeds(fixture.run("repair"))
        self.succeeds(fixture.run("check"))
        healthy = fixture.capture()

        fixture.stage(version="0.4.1", payload="#!/bin/bash\nexit 9\n")
        failed = fixture.run("update", ref="v0.4.1")
        self.assertEqual(failed.returncode, 9, failed.stdout + failed.stderr)
        self.assertEqual(fixture.capture(), healthy)
        self.succeeds(fixture.run("check"))

        self.succeeds(fixture.run("uninstall"))
        self.assertEqual(fixture.capture(), fixture.initial)
        failed = fixture.run("install", ref="v0.4.1")
        self.assertEqual(failed.returncode, 9, failed.stdout + failed.stderr)
        self.assertEqual(fixture.capture(), fixture.initial)
        fixture.stage()
        self.succeeds(fixture.run("install"))
        self.succeeds(fixture.run("check"))
        self.assertEqual({str(p): automation.snapshot(p) for p in protected}, before_base)
        self.succeeds(fixture.run("uninstall"))


if __name__ == "__main__":
    unittest.main()
