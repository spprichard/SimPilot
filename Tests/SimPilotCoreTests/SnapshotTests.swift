import Testing
@testable import SimPilotCore

@Suite struct SnapshotTests {
    @Test func settingsRootOffersRowsAndSearchField() throws {
        let snapshot = try Fixture.snapshot("settings-root")
        let tap = snapshot.targets(.tap).map(\.name)

        #expect(snapshot.pid == 43353)
        #expect(tap.contains("General"))
        #expect(tap.contains("Accessibility"))
        #expect(snapshot.targets(.type).map(\.name) == ["Search"])
        // The same Dictate button is reported twice in different branches.
        #expect(tap.filter { $0 == "Dictate" }.count == 1)
    }

    @Test func rowUnderToolbarIsOccluded() throws {
        let snapshot = try Fixture.snapshot("settings-root")
        let screenTime = try #require(snapshot.controls.first { $0.name == "Screen Time" && $0.kind == "Button" })

        #expect(screenTime.occluded)
        #expect(!snapshot.targets(.tap).contains { $0.name == "Screen Time" })
    }

    @Test func nestedSameNamedButtonsCollapse() throws {
        let snapshot = try Fixture.snapshot("settings-general")
        let about = snapshot.targets(.tap).filter { $0.name == "About" }

        #expect(about.count == 1)
        #expect(about.first?.frame.width == 362)
        #expect(snapshot.targets(.tap).first?.name == "Settings")
    }

    @Test func fingerprintIsStableAndDistinguishesScreens() throws {
        let first = try Fixture.snapshot("settings-root")
        let second = try Fixture.snapshot("settings-root")
        let general = try Fixture.snapshot("settings-general")

        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint != general.fingerprint)
    }

    @Test func secureOnlyAppliesToTextInputs() {
        let root = AXElement(type: "Application", frame: Rect(x: 0, y: 0, width: 400, height: 800), pid: 1, children: [
            AXElement(type: "Button", label: "Face ID & Passcode", frame: Rect(x: 0, y: 100, width: 400, height: 50)),
            AXElement(type: "TextField", label: "Passcode", frame: Rect(x: 0, y: 200, width: 400, height: 50)),
        ])
        let snapshot = Snapshot(elements: [root])

        #expect(snapshot.targets(.tap).map(\.name).contains("Face ID & Passcode"))
        #expect(snapshot.targets(.type).isEmpty)
    }

    @Test func allowLabelsRestrictTapTargets() throws {
        let snapshot = try Fixture.snapshot("settings-root")

        #expect(snapshot.targets(.tap, allowLabels: ["general"]).map(\.name) == ["General"])
    }
}
