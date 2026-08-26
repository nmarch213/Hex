import AppIntents

struct ArmHexIntent: AppIntent {
    static let title: LocalizedStringResource = "Arm Hex"
    static let description = IntentDescription(
        "Opens Hex and prepares voice entry from the Hex keyboard."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            PrototypeAppIntentRouter.shared.requestArm()
        }
        return .result()
    }
}

struct HexAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ArmHexIntent(),
            phrases: [
                "Arm \(.applicationName)",
                "Start voice typing with \(.applicationName)",
                "Start keyboard dictation with \(.applicationName)",
            ],
            shortTitle: "Arm Hex",
            systemImageName: "mic.fill"
        )
    }
}
