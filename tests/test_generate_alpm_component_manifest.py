from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "generate-alpm-component-manifest.py"
SPEC = importlib.util.spec_from_file_location("alpm_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ComponentManifestTest(unittest.TestCase):
    def test_records_existing_owned_files_deterministically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / MODULE.DEFAULT_DB / "bash-5.3.3-1"
            package.mkdir(parents=True)
            (package / "desc").write_text("%NAME%\nbash\n", encoding="utf-8")
            (package / "files").write_text(
                "%FILES%\nusr/bin/zsh\nusr/bin/bash\nusr/share/doc/\nmissing\n",
                encoding="utf-8",
            )
            (root / "usr/bin").mkdir(parents=True)
            (root / "usr/bin/bash").touch()
            (root / "usr/bin/zsh").touch()

            records = MODULE.component_records(root, root / MODULE.DEFAULT_DB)

            self.assertEqual(
                records,
                [
                    ("/usr/bin/bash", "alpm/bash", "weekly"),
                    ("/usr/bin/zsh", "alpm/bash", "weekly"),
                ],
            )

    def test_rejects_parent_traversal(self) -> None:
        self.assertIsNone(MODULE.canonical_path("../../etc/shadow"))


if __name__ == "__main__":
    unittest.main()
