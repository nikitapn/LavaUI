#!/usr/bin/env python3
"""Exercise docs tool selection without compiling LavaUI or requiring a GPU."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
TOOL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
name = Path(sys.argv[0]).name
with open(os.environ["DOCS_SELECTION_TEST_LOG"], "a") as log:
    log.write(json.dumps({"path": sys.argv[0], "args": args}) + "\n")
if name == "npdoc" and any(part in [".build_asan", ".build_tsan"] for part in Path(sys.argv[0]).parts):
    print("ASan runtime does not come first in initial library list", file=sys.stderr)
    sys.exit(1)
if name == "swift":
    module = args[args.index("--target") + 1]
    output = Path(args[args.index("-emit-symbol-graph-dir") + 2])
    output.mkdir(parents=True, exist_ok=True)
    (output / (module + ".symbols.json")).write_text("{}")
elif "--help" in args:
    print("--doc-json")
elif name == "npdoc":
    Path(args[args.index("--out") + 1]).write_text("{}")
elif name == "npidl":
    (Path(args[args.index("--output-dir") + 1]) / "lava.doc.json").write_text("{}")
'''


class DocsToolSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="docs tool selection ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.site = self.root / "HelloWorld"
        scripts = self.site / "scripts"
        (scripts / "lib").mkdir(parents=True)
        shutil.copy(REPO / "scripts/docs-api.sh", scripts / "docs-api.sh")
        shutil.copy(REPO / "scripts/lib/lava.sh", scripts / "lib/lava.sh")
        self.nprpc = self.root / "nprpc"
        marker = self.nprpc / "include/nprpc/nprpc.hpp"
        marker.parent.mkdir(parents=True)
        marker.touch()
        self.normal = self.tool(".build_relwith_debinfo/npdoc/npdoc")
        self.asan = self.tool(".build_asan/npdoc/npdoc")
        tsan = self.tool(".build_tsan/npdoc/npdoc")
        # A sanitizer build newer than release caused the production failure.
        for path in (self.asan, tsan):
            os.utime(path, (2_000_000_000, 2_000_000_000))
        self.tool(".build_lava_shm/npidl/npidl")
        self.bin = self.root / "bin"
        self.executable(self.bin / "swift")
        self.log = self.root / "calls.jsonl"
        self.env = {key: value for key, value in os.environ.items()
                    if key not in {"NPDOC", "NPIDL", "NPRPC_BUILD_DIR", "LAVA_LIB_LOADED"}}
        self.env.update(NPRPC_ROOT=str(self.nprpc),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        DOCS_SELECTION_TEST_LOG=str(self.log))

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(TOOL)
        path.chmod(0o755)
        return path

    def tool(self, relative):
        return self.executable(self.nprpc / relative)

    def run_docs(self, **env):
        result = subprocess.run(["bash", str(self.site / "scripts/docs-api.sh")],
                                env={**self.env, **env}, capture_output=True,
                                text=True, timeout=15)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def assert_extractor(self, expected, **env):
        result, calls = self.run_docs(**env)
        self.assertEqual(result.returncode, 0, result.stderr)
        extraction = next(call for call in calls if "--out" in call["args"])
        self.assertEqual(extraction["path"], str(expected))
        self.assertTrue((self.site / ".build/docs/api.json").is_file())

    def test_newer_sanitizer_builds_do_not_override_release(self):
        self.assert_extractor(self.normal)

    def test_release_fallback(self):
        self.normal.unlink()
        self.assert_extractor(self.tool(".build_release/npdoc/npdoc"))

    def test_shm_fallback(self):
        self.normal.unlink()
        self.assert_extractor(self.tool(".build_lava_shm/npdoc/npdoc"))

    def test_relative_configured_build(self):
        custom = self.tool(".build_custom/npdoc/npdoc")
        self.assert_extractor(custom, NPRPC_BUILD_DIR=".build_custom")

    def test_absolute_configured_build(self):
        custom = self.tool(".build_custom/npdoc/npdoc")
        self.assert_extractor(custom, NPRPC_BUILD_DIR=str(custom.parents[1]))

    def test_explicit_tool_override(self):
        custom = self.tool(".build_custom/npdoc/npdoc")
        self.assert_extractor(custom, NPDOC=str(custom))

    def test_broken_override_fails_before_swift_builds(self):
        result, calls = self.run_docs(NPDOC=str(self.asan))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("npdoc could not run", result.stderr)
        self.assertFalse(any(Path(call["path"]).name == "swift" for call in calls))

    def test_missing_release_does_not_fall_back_to_sanitizers(self):
        self.normal.unlink()
        result, calls = self.run_docs()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("normal NPRPC build", result.stderr)
        self.assertFalse(calls)


if __name__ == "__main__":
    unittest.main()
