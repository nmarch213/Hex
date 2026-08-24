import SwiftUI

@main
struct HexKeyboardTracerApp: App {
    @StateObject private var controller = PrototypeDictationController()
    @StateObject private var intentRouter = PrototypeAppIntentRouter.shared

    var body: some Scene {
        WindowGroup {
            DictationTracerView(controller: controller)
                .onReceive(intentRouter.$armRequestID.compactMap { $0 }) { requestID in
                    controller.handleArmShortcut()
                    intentRouter.consumeArmRequest(id: requestID)
                }
        }
    }
}

private struct DictationTracerView: View {
    @ObservedObject var controller: PrototypeDictationController
    @State private var seededTranscript = "Hello from the Hex keyboard tracer."

    var body: some View {
        NavigationStack {
            Form {
                Section("Dictation") {
                    Text(controller.state.status)
                        .font(.callout)

                    Button(primaryButtonTitle) {
                        controller.toggleRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.state.isRecording ? .red : .accentColor)
                    .disabled(controller.state.isBusy && !controller.state.isRecording)

                    Text(
                        controller.state.isArmed
                            ? "Swipe back to the app where you want to type. In the Hex keyboard, tap Start Voice, speak, then tap Stop Voice. Keep Hex armed while you dictate; iOS shows the orange microphone indicator."
                            : "Run the Arm Hex shortcut—ideally from the Action Button—then swipe back. The keyboard can start and stop voice entry without leaving your text field."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    LabeledContent(
                        "Keyboard voice",
                        value: controller.state.isArmed ? "Armed" : "Off"
                    )
                    if let session = controller.state.warmSessionRecord,
                       session.state == .armed,
                       controller.state.isArmed {
                        LabeledContent(
                            "Armed until",
                            value: session.expiresAt.formatted(date: .omitted, time: .shortened)
                        )
                    }
                }

                Section("Private server") {
                    LabeledContent("Origin", value: controller.state.serverURLString)
                    LabeledContent(
                        "Credential",
                        value: controller.state.credentialStatus
                    )
                    SecureField("Device Credential", text: tokenBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Credential") {
                        controller.saveCredential()
                    }
                    Text("The prototype pins Ronin as its only origin and stores the Device Credential in this device's Keychain. Rotate it after testing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Hex transcript transforms") {
                    Toggle("Remove filler words", isOn: preferenceBinding(\.removeFillerWords))
                    Toggle("Spoken punctuation", isOn: preferenceBinding(\.spokenPunctuation))
                    Toggle("Lowercase", isOn: preferenceBinding(\.lowercase))
                    Toggle("Remove punctuation", isOn: preferenceBinding(\.removePunctuation))
                }

                #if DEBUG
                Section("Mailbox diagnostics") {
                    TextEditor(text: $seededTranscript)
                        .frame(minHeight: 80)
                    Button("Seed Final Transcript") {
                        controller.seedMailbox(transcript: seededTranscript)
                    }
                    .disabled(seededTranscript.isEmpty || controller.state.isBusy)
                    Button("Clear Mailbox", role: .destructive) {
                        controller.clearMailbox()
                    }
                    .disabled(controller.state.isBusy)
                }
                #endif

                Section("Full request state") {
                    if let record = controller.state.mailboxRecord {
                        LabeledContent("Request", value: record.id.uuidString)
                        LabeledContent("State", value: record.state.rawValue)
                        LabeledContent(
                            "Created",
                            value: record.createdAt.formatted(date: .numeric, time: .standard)
                        )
                        if let roundTrip = record.roundTripMilliseconds {
                            LabeledContent("Round trip", value: "\(roundTrip) ms")
                        }
                        if let upstream = record.upstreamMilliseconds {
                            LabeledContent("Parakeet", value: "\(upstream) ms")
                        }
                        if let service = record.serviceMilliseconds {
                            LabeledContent("Service before commit", value: "\(service) ms")
                        }
                        if let insertion = record.stopToInsertionMilliseconds {
                            LabeledContent("Stop to insertion", value: "\(insertion) ms")
                        }
                        if let returnToInsertion = record.returnToInsertionMilliseconds {
                            LabeledContent("Return to insertion", value: "\(returnToInsertion) ms")
                        }
                        if let errorMessage = record.errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("Mailbox empty")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("App Group") {
                    Text(PrototypeMailbox.appGroupID)
                        .font(.caption.monospaced())
                    if controller.state.hasIPCFailure {
                        Button("Reset Keyboard State", role: .destructive) {
                            controller.resetKeyboardState()
                        }
                        Text("Reset removes an unusable pending request and disarms microphone capture. It does not change the saved Ronin credential.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Hex")
            .toolbar {
                Button("Refresh") {
                    controller.refreshMailbox()
                }
            }
            .onAppear {
                controller.refreshMailbox()
            }
        }
    }

    private var primaryButtonTitle: String {
        if controller.state.isRecording {
            return "Stop & Transcribe"
        }
        if controller.state.isArmed {
            return "Disarm Keyboard Dictation"
        }
        return "Arm & Swipe Back"
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: { controller.state.token },
            set: { token in controller.setToken(token) }
        )
    }

    private func preferenceBinding(
        _ keyPath: WritableKeyPath<PrototypeDictationPreferences, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { controller.state.transcriptPreferences[keyPath: keyPath] },
            set: { value in
                var preferences = controller.state.transcriptPreferences
                preferences[keyPath: keyPath] = value
                controller.setTranscriptPreferences(preferences)
            }
        )
    }
}
