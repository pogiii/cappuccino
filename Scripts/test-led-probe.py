"""CLI/lifecycle checks using only the probe's simulated LED backend."""
import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path


PROBE = str(Path(sys.argv.pop(1)).resolve())


class LEDProbeTests(unittest.TestCase):
    def run_probe(self, *arguments):
        return subprocess.run(
            [PROBE, *arguments], capture_output=True, text=True, timeout=10
        )

    def test_help_requires_no_hardware(self):
        result = self.run_probe("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)
        self.assertNotIn("requested LED", result.stdout)

    def test_inspect_is_read_only(self):
        result = self.run_probe("inspect", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Read-only inspection complete", result.stdout)
        self.assertNotIn("requested LED", result.stdout)

    def test_invalid_arguments_fail_before_hardware_access(self):
        invalid = [
            ["test", "0"], ["test", "-1"], ["test", "301"], ["test", "1.5"],
            ["test", "nan"], ["test", "1", "extra"], ["inspect", "extra"],
            ["restore", "extra"], ["unknown"], ["--dry-run", "--dry-run"],
            ["inspect", "--recover"], ["restore", "--recover"],
            ["test", "--recover", "--recover"], ["test", "--simulate-resets"],
            ["test", "--simulate-resets", "1"],
            ["test", "--dry-run", "--simulate-resets", "0"],
            ["test", "--dry-run", "--simulate-resets", "21"],
            ["inspect", "--dry-run", "--simulate-resets", "1"],
            ["test", "--dry-run", "--simulate-resets", "1", "--simulate-resets", "1"],
        ]
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                result = self.run_probe(*arguments)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Usage:", result.stderr)
                self.assertNotIn("Cappuccino LED-only probe", result.stdout)

    def test_timeout_restores_auto(self):
        started = time.monotonic()
        result = self.run_probe("test", "1", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(time.monotonic() - started, 0.9)
        self.assertEqual(result.stdout.count("requested LED On"), 1)
        self.assertEqual(result.stdout.count("requested LED Auto"), 1)
        self.assertLess(
            result.stdout.index("requested LED On"),
            result.stdout.index("requested LED Auto"),
        )

    def assert_cleanup_is_last_write(self, output):
        self.assertEqual(output.count("requested LED Auto"), 1)
        after_cleanup = output.split("requested LED Auto", 1)[1]
        self.assertNotIn("requested LED On", after_cleanup)
        self.assertNotIn("LED recovery attempt", after_cleanup)

    def test_recovery_does_not_rewrite_a_healthy_led(self):
        result = self.run_probe("test", "1", "--recover", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("requested LED On"), 1)
        self.assertNotIn("LED recovery attempt", result.stdout)
        self.assert_cleanup_is_last_write(result.stdout)

    def test_recovery_reapplies_after_a_simulated_system_reset(self):
        result = self.run_probe(
            "test", "1", "--recover", "--dry-run", "--simulate-resets", "1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Simulated system reset: LED Off", result.stdout)
        self.assertIn("LED recovery attempt 1/8", result.stdout)
        self.assertEqual(result.stdout.count("requested LED On"), 2)
        self.assert_cleanup_is_last_write(result.stdout)

    def test_one_write_mode_does_not_recover_a_simulated_reset(self):
        result = self.run_probe("test", "1", "--dry-run", "--simulate-resets", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Simulated system reset: LED Off", result.stdout)
        self.assertNotIn("LED recovery attempt", result.stdout)
        self.assertEqual(result.stdout.count("requested LED On"), 1)
        self.assert_cleanup_is_last_write(result.stdout)

    def test_recovery_gives_up_and_cleans_up_when_retry_limit_is_exhausted(self):
        result = self.run_probe(
            "test", "4", "--recover", "--dry-run", "--simulate-resets", "9"
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Recovery limit of 8 attempts reached", result.stderr)
        self.assertEqual(result.stdout.count("LED recovery attempt"), 8)
        self.assertEqual(result.stdout.count("requested LED On"), 9)
        self.assert_cleanup_is_last_write(result.stdout)

    def test_signals_restore_auto_before_exit(self):
        cases = [
            (number, recover)
            for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
            for recover in (False, True)
        ]
        for number, recover in cases:
            with self.subTest(signal=number, recover=recover):
                arguments = [PROBE, "test", "30", "--dry-run"]
                marker = b"LED test started"
                if recover:
                    arguments += ["--recover", "--simulate-resets", "20"]
                    marker = b"LED recovery attempt 1/8"
                process = subprocess.Popen(
                    arguments,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                try:
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            stdout, stderr = process.communicate(timeout=0.1)
                            self.fail(f"Exited before ready: {stdout!r} {stderr!r}")
                        except subprocess.TimeoutExpired as pending:
                            if marker in (pending.output or b""):
                                break
                            if time.monotonic() >= deadline:
                                self.fail("Probe did not become ready")
                    process.send_signal(number)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 128 + number, stderr)
                    if recover:
                        self.assertGreaterEqual(stdout.count(b"requested LED On"), 2)
                        self.assertLess(
                            stdout.index(b"LED recovery stopped"),
                            stdout.index(b"requested LED Auto"),
                        )
                    else:
                        self.assertEqual(stdout.count(b"requested LED On"), 1)
                    self.assert_cleanup_is_last_write(stdout.decode())
                finally:
                    if process.poll() is None:
                        process.kill()  # This process uses only the simulated LED.
                        process.communicate(timeout=5)

    def test_restore_only_requests_auto(self):
        result = self.run_probe("restore", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("requested LED Auto", result.stdout)
        self.assertNotIn("requested LED On", result.stdout)


if __name__ == "__main__":
    unittest.main()
