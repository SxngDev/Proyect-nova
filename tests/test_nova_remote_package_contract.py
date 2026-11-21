from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "ThreeOneOSFive/helpers/VesperDashRemoteSync.swift").read_text()
SERVICE = (ROOT / "ThreeOneOSFive/helpers/DevicePatchService.swift").read_text()
CONTENT = (ROOT / "ThreeOneOSFive/ContentView.swift").read_text()


class NOVARemotePackageContractTests(unittest.TestCase):
    def test_service_entry_is_limited_to_nova_bundle(self):
        self.assertIn("project.allBundleIdentifiers == [target]", SERVICE)
        self.assertIn("Bundle.main.bundleIdentifier", SERVICE)
        self.assertIn("return try apply(project: project)", SERVICE)
        self.assertIn("guard bundleIDs == [target]", SERVICE)

    def test_remote_activation_decodes_structured_package_before_apply(self):
        self.assertIn('document.filename.lowercased().hasSuffix(".3105")', REMOTE)
        self.assertIn('$0.filename.lowercased().hasSuffix(".3105")', REMOTE)
        self.assertIn("PatchPackageCodec.inspect(data)", REMOTE)
        self.assertIn("PatchPackageCodec.decode(data, password: nil)", REMOTE)
        self.assertIn("DevicePatchService.applyNOVAPackage(project: project)", REMOTE)

    def test_remote_receipt_link_is_persisted_and_reconciled(self):
        self.assertIn('"NOVA.activeRemotePackages.v1"', REMOTE)
        self.assertIn("projectID: UUID", REMOTE)
        self.assertIn("transactionID: UUID?", REMOTE)
        self.assertIn("DevicePatchService.receipt(", REMOTE)
        self.assertIn("UserDefaults.standard.set(data, forKey: Self.activeRecordsDefaultsKey)", REMOTE)
        self.assertIn("DevicePatchService.latestPreparedReceipt", REMOTE)
        self.assertIn("DevicePatchService.restoreNOVAPackage(receipt: prepared)", REMOTE)

    def test_maintenance_and_deactivation_restore_before_removing_cached_files(self):
        stale_restore = REMOTE.index("try await restore(record)")
        stale_cleanup = REMOTE.index("try removeStaleManagedFiles(in: directory, retaining: expectedNames)")
        self.assertLess(stale_restore, stale_cleanup)
        deactivate_start = REMOTE.index("func deactivate() async")
        deactivate_end = REMOTE.index("private func apply(", deactivate_start)
        deactivate = REMOTE[deactivate_start:deactivate_end]
        self.assertIn("try await restore(record)", deactivate)
        self.assertIn("if let directory = try? managedDirectory", deactivate)

    def test_nova_card_syncs_when_first_shown(self):
        card_start = REMOTE.index("struct NOVAReceivedDocumentsCard")
        card = REMOTE[card_start:]
        self.assertIn(".onAppear {", card)
        self.assertIn("if shouldSyncOnReentry { syncNow() }", card)

    def test_nova_switch_plays_feedback_only_after_store_success(self):
        store_start = REMOTE.index("func setApplied(")
        store_end = REMOTE.index("func deactivate()", store_start)
        operation = REMOTE[store_start:store_end]
        self.assertIn("async -> Bool", operation)
        self.assertIn("return false", operation)
        self.assertIn("return true", operation)
        self.assertIn("guard succeeded else { return }", REMOTE)
        self.assertIn("if desiredState { onApplied() } else { onRestored() }", REMOTE)
        self.assertIn("onApplied: { PatchAudioFeedback.bypassActivated() }", CONTENT)
        self.assertIn("onRestored: { PatchAudioFeedback.originalRestored() }", CONTENT)
        self.assertIn('static func bypassActivated() { play(resource: "ACTIVADA", ext: "m4a") }', CONTENT)
        self.assertIn('static func originalRestored() { play(resource: "DESACTIVADA", ext: "m4a") }', CONTENT)


if __name__ == "__main__":
    unittest.main()
