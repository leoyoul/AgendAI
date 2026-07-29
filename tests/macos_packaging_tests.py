import plistlib
import unittest
from pathlib import Path


class MacOSPackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Path(__file__).resolve().parents[1]

    def test_project_tree_does_not_keep_installable_agendai_app_bundles(self) -> None:
        app_bundles = [
            path
            for path in self.repo.rglob("AgendAI 会小纪.app")
            if ".build" not in path.parts
        ]

        self.assertEqual(app_bundles, [])

    def test_package_script_outputs_zip_not_indexable_app_bundle(self) -> None:
        script = (self.repo / "scripts" / "package_macos_app.sh").read_text()

        self.assertIn("ditto -c -k", script)
        self.assertIn('ZIP_PATH="$DIST_DIR/$APP_NAME.app.zip"', script)
        self.assertNotIn('ditto "$TMP_APP_DIR" "$APP_DIR"', script)

    def test_package_script_excludes_voiceprint_sidecar_resources(self) -> None:
        script = (self.repo / "scripts" / "package_macos_app.sh").read_text()

        self.assertNotIn("voiceprint_sidecar", script)
        self.assertNotIn("setup_voiceprint_sidecar", script)
        self.assertNotIn("SIDECAR_", script)

    def test_check_script_rejects_voiceprint_sidecar_resources(self) -> None:
        script = (self.repo / "scripts" / "check_macos.sh").read_text()

        self.assertIn('find "$resources_dir" -name voiceprint_sidecar', script)
        self.assertIn('find "$resources_dir" -name setup_voiceprint_sidecar.sh', script)
        self.assertIn("安装包仍包含已移除的说话人 sidecar 资源", script)

    def test_package_uses_stable_local_designated_requirement(self) -> None:
        package_script = (self.repo / "scripts" / "package_macos_app.sh").read_text()
        signing_script = (self.repo / "scripts" / "codesign_macos_app.sh").read_text()

        self.assertIn('scripts/codesign_macos_app.sh', package_script)
        self.assertIn('BUNDLE_ID="${TINGLAN_BUNDLE_ID:-com.local.aitingji}"', signing_script)
        self.assertIn('--requirements "$DESIGNATED_REQUIREMENT"', signing_script)
        self.assertIn('codesign -d -r-', signing_script)
        self.assertNotIn('codesign --force --deep --sign -', package_script)

    def test_install_preserves_package_signature(self) -> None:
        script = (self.repo / "scripts" / "install_macos_app.sh").read_text()

        self.assertIn('codesign --verify --deep --strict', script)
        self.assertNotIn('codesign --force', script)

    def test_info_plist_allows_user_configured_http_model_endpoints(self) -> None:
        with (self.repo / "Packaging" / "AItingjiApp-Info.plist").open("rb") as file:
            info = plistlib.load(file)

        self.assertTrue(
            info["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"]
        )


if __name__ == "__main__":
    unittest.main()
