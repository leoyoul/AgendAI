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

    def test_package_script_outputs_dmg_and_keeps_zip_internal_only(self) -> None:
        script = (self.repo / "scripts" / "package_macos_app.sh").read_text()

        self.assertIn('DMG_PATH="$DIST_DIR/AgendAI-v${APP_VERSION}-macOS-universal.dmg"', script)
        self.assertIn("create_macos_dmg.sh", script)
        self.assertIn('PACKAGE_INTERNAL_ZIP', script)
        self.assertNotIn('ditto "$TMP_APP_DIR" "$APP_DIR"', script)

    def test_dmg_helper_creates_standard_drag_install_layout(self) -> None:
        script = (self.repo / "scripts" / "create_macos_dmg.sh").read_text()

        self.assertIn("hdiutil create", script)
        self.assertIn("hdiutil convert", script)
        self.assertIn("ln -s /Applications", script)
        self.assertIn("set position of item appName to {180, 180}", script)
        self.assertIn('set position of item "Applications" to {480, 180}', script)
        self.assertIn("$1 ~ /^\\/dev\\//", script)

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

    def test_package_embeds_sparkle_and_adds_framework_rpath(self) -> None:
        script = (self.repo / "scripts" / "package_macos_app.sh").read_text()

        self.assertIn("Sparkle.framework", script)
        self.assertIn(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework", script)
        self.assertNotIn('find "$ROOT_DIR/.build" -type d -name Sparkle.framework', script)
        self.assertIn("install_name_tool", script)
        self.assertIn("@executable_path/../Frameworks", script)
        self.assertIn("otool -L", script)

    def test_both_package_scripts_reject_missing_sparkle_public_key(self) -> None:
        for name in ("package_macos_app.sh", "package_macos_test_app.sh"):
            script = (self.repo / "scripts" / name).read_text()
            self.assertIn("SUPublicEDKey", script)
            self.assertIn("__SPARKLE_PUBLIC_KEY__", script)
            self.assertIn("拒绝打包", script)

    def test_appcast_generation_uses_dedicated_keychain_account(self) -> None:
        script = (self.repo / "scripts" / "generate_sparkle_appcast.sh").read_text()

        self.assertIn('SPARKLE_KEY_ACCOUNT:-com.local.aitingji', script)
        self.assertIn('generate_keys --account "$ACCOUNT" -p', script)
        self.assertIn('generate_appcast" \\', script)
        self.assertIn('--account "$ACCOUNT"', script)
        self.assertIn('sign_update" --account "$ACCOUNT" --verify', script)
        self.assertIn("钥匙串公钥与应用 SUPublicEDKey 不一致", script)
        self.assertIn('ditto "$APPCAST_PATH" "$TMP_DIR/appcast.xml"', script)

    def test_test_package_embeds_sparkle_and_adds_framework_rpath(self) -> None:
        script = (self.repo / "scripts" / "package_macos_test_app.sh").read_text()

        self.assertIn("Sparkle.framework", script)
        self.assertIn(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework", script)
        self.assertNotIn('find "$ROOT_DIR/.build" -type d -name Sparkle.framework', script)
        self.assertIn("install_name_tool", script)
        self.assertIn("@executable_path/../Frameworks", script)

    def test_codesign_walks_nested_components_before_parent(self) -> None:
        script = (self.repo / "scripts" / "codesign_macos_app.sh").read_text()

        self.assertIn("Contents/Frameworks", script)
        self.assertIn("Sparkle.framework", script)
        self.assertNotIn("--deep \\", script)
        self.assertIn("XPCServices/Installer.xpc", script)
        self.assertIn("XPCServices/Downloader.xpc", script)
        self.assertIn("/Autoupdate", script)
        self.assertIn("/Updater.app", script)
        self.assertIn("--options runtime", script)
        self.assertIn("--preserve-metadata=entitlements", script)
        self.assertIn("codesign -d --entitlements :-", script)
        self.assertIn("flags=.*runtime", script)
        self.assertIn("codesign --verify --deep --strict", script)

    def test_install_preserves_package_signature(self) -> None:
        script = (self.repo / "scripts" / "install_macos_app.sh").read_text()

        self.assertIn('codesign --verify --deep --strict', script)
        self.assertIn('hdiutil attach', script)
        self.assertIn('DMG_PATH="$ROOT_DIR/dist/AgendAI-v0.1.3-macOS-universal.dmg"', script)
        self.assertIn('ditto "$MOUNTED_APP" "$TARGET_APP"', script)
        self.assertIn("$1 ~ /^\\/dev\\//", script)
        self.assertNotIn('SOURCE_ZIP=', script)
        self.assertNotIn('codesign --force', script)

    def test_readme_describes_dmg_install_and_sparkle_updates(self) -> None:
        readme = (self.repo / "README.md").read_text()

        self.assertIn("AgendAI-v0.1.3-macOS-universal.dmg", readme)
        self.assertIn("Sparkle", readme)
        self.assertIn("ad-hoc", readme)
        self.assertIn("Developer ID", readme)

    def test_info_plist_allows_user_configured_http_model_endpoints(self) -> None:
        with (self.repo / "Packaging" / "AItingjiApp-Info.plist").open("rb") as file:
            info = plistlib.load(file)

        self.assertTrue(
            info["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"]
        )

    def test_update_feed_signature_never_expires_into_fallback_mode(self) -> None:
        for name in ("AItingjiApp-Info.plist", "AItingjiTestApp-Info.plist"):
            with (self.repo / "Packaging" / name).open("rb") as file:
                info = plistlib.load(file)

            self.assertTrue(info["SURequireSignedFeed"])
            self.assertEqual(info["SUSignedFeedFailureExpirationInterval"], 0)

    def test_production_app_has_v013_release_identity(self) -> None:
        with (self.repo / "Packaging" / "AItingjiApp-Info.plist").open("rb") as file:
            info = plistlib.load(file)

        self.assertEqual(info["CFBundleIdentifier"], "com.local.aitingji")
        self.assertEqual(info["CFBundleShortVersionString"], "0.1.3")
        self.assertEqual(info["CFBundleVersion"], "4")
        self.assertNotIn("AgendAIDataDirectoryName", info)

    def test_isolated_test_app_has_independent_identity_and_data_directory(self) -> None:
        with (self.repo / "Packaging" / "AItingjiTestApp-Info.plist").open("rb") as file:
            info = plistlib.load(file)

        self.assertEqual(info["CFBundleDisplayName"], "AgendAI 会小纪 测试版")
        self.assertEqual(info["CFBundleIdentifier"], "com.local.aitingji.test")
        self.assertEqual(info["CFBundleShortVersionString"], "0.1.3")
        self.assertEqual(info["CFBundleVersion"], "4")
        self.assertEqual(info["AgendAIDataDirectoryName"], "会小纪测试版")

    def test_test_app_scripts_do_not_target_the_production_app(self) -> None:
        package_script = (self.repo / "scripts" / "package_macos_test_app.sh").read_text()
        install_script = (self.repo / "scripts" / "install_macos_test_app.sh").read_text()
        data_script = (self.repo / "scripts" / "prepare_macos_test_data.sh").read_text()

        self.assertIn('DIST_DIR="$ROOT_DIR/dist-test"', package_script)
        self.assertIn('BUNDLE_ID="com.local.aitingji.test"', package_script)
        self.assertIn('TARGET_APP="/Applications/$APP_NAME.app"', install_script)
        self.assertIn('TARGET_ROOT="$HOME/Library/Application Support/会小纪测试版"', data_script)
        self.assertIn(".backup", data_script)
        self.assertIn("audio_file_path = NULL", data_script)
        self.assertNotIn('TARGET_APP="/Applications/AgendAI 会小纪.app"', install_script)


if __name__ == "__main__":
    unittest.main()
