"""Keep cold compilation separate from the bounded TLS test run."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("nio_harness", ROOT / "Scripts/test-nio.py")
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class HarnessBuildTests(unittest.TestCase):
    def run_harness(self, args=None, failure=None, output="Executed 39 tests, with 0 failures"):
        args = args or SimpleNamespace(all=False, coverage=False, sanitize_thread=False)
        temporary = ROOT / ".tmp"
        temporary.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="nio-harness-test-", dir=temporary) as directory:
            target = Path(directory)
            target.resolve().relative_to((ROOT / ".tmp").resolve())
            commands = []

            def run(command, **options):
                commands.append((command, options))
                if command[1] == failure:
                    raise subprocess.CalledProcessError(1, command)
                options["stdout"].write(output if command[1] == "test" else "Build complete")
                return SimpleNamespace(returncode=0)

            with patch.object(HARNESS.subprocess, "run", side_effect=run):
                result = HARNESS.run_tests(ROOT, target, {}, args)
            return result, commands

    def test_build_precedes_skip_build_test_without_extending_test_deadline(self):
        count, commands = self.run_harness()
        self.assertEqual(count, 39)
        self.assertEqual([command[1] for command, _ in commands], ["build", "test"])
        self.assertIn("--build-tests", commands[0][0])
        self.assertIn("--skip-build", commands[1][0])
        self.assertEqual(commands[0][1]["timeout"], 600)
        self.assertEqual(commands[1][1]["timeout"], 180)

    def test_instrumentation_matches_build_and_test(self):
        args = SimpleNamespace(all=True, coverage=True, sanitize_thread=True)
        count, commands = self.run_harness(args)
        self.assertEqual(count, 39)
        for command, options in commands:
            self.assertIn("--enable-code-coverage", command)
            self.assertIn("--sanitize", command)
            self.assertIn("thread", command)
            self.assertNotIn("--filter", command)
            self.assertEqual(options["timeout"], 600)

    def test_build_failure_never_starts_tests(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_harness(failure="build")

    def test_test_failure_still_propagates(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_harness(failure="test")

    def test_incomplete_or_skipped_results_are_rejected(self):
        for output in ["", "Executed 35 tests, with 0 failures", "Executed 39 tests, with 0 failures; skipped 1"]:
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                self.run_harness(output=output)


if __name__ == "__main__":
    unittest.main()
