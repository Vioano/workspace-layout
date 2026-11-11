import sys
from pathlib import Path
from unittest import TestCase, mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import workspace_layout

class LegacyOpenTests(TestCase):
    def test_disabled_before_metadata_or_file_access(self):
        args = ["workspace_layout.py", "open", "--workspace", "999", "--app", "example.app", "--file", "/does-not-exist"]
        with mock.patch.object(sys, "argv", args), mock.patch.object(workspace_layout, "native") as native:
            with self.assertRaisesRegex(ValueError, "binding before window creation"):
                workspace_layout.main()
            native.assert_not_called()
