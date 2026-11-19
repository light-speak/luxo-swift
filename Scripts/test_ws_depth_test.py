"""Keep generated consumers and dependency caches outside the WS source manifest."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ws_harness", ROOT / "Scripts/test-ws-depth.py")
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class SourceManifestTests(unittest.TestCase):
    def test_generated_and_dependency_trees_are_excluded(self):
        temporary = ROOT / ".tmp"
        temporary.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ws-source-test-", dir=temporary) as directory:
            base = Path(directory)
            base.resolve().relative_to(temporary.resolve())
            included = [
                "swift/Package.swift", "swift/Package.resolved", "swift/Scripts/test-ws-depth.py",
                "swift/Sources/Client.swift", "swift/Tests/Peer.swift", "core/go.mod", "core/go.sum",
                "core/tests/sdk-interop/ws-codable/main.go",
                "core/tests/sdk-interop/ws-codable/main_test.go",
            ]
            excluded = [
                "swift/Tests/Consumer/.build/Dependency.swift", "swift/Tests/Consumer/.tmp/Generated.swift",
                "swift/Tests/.git/Hidden.swift", "swift/Sources/.build/Derived.swift",
            ]
            for name in included + excluded:
                target = base / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(name)
            with patch.object(HARNESS, "__file__", str(base / "swift/Scripts/test-ws-depth.py")):
                observed = HARNESS.source_hashes(base / "swift", base / "core")
            self.assertEqual(set(observed), set(included))


if __name__ == "__main__":
    unittest.main()
