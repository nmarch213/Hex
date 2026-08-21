import SwiftUI

@main
struct HexKeyboardTracerApp: App {
    @StateObject private var controller = PrototypeDictationController()

    var body: some Scene {
        WindowGroup {
            DictationTracerView(controller: controller)
                .onOpenURL { url in
                    controller.handleKeyboardLaunch(url)
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
                    Text(controller.status)
                        .font(.callout)

                    Button(controller.isRecording ? "Stop & Transcribe" : "Record") {
                        controller.toggleRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRecording ? .red : .accentColor)
                    .disabled(controller.isBusy && !controller.isRecording)
                }

                Section("Private server") {
                    LabeledContent("Origin", value: controller.serverURLString)
                    SecureField("Bearer token", text: $controller.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("The prototype pins Ronin as its only origin and stores the token in this device's Keychain. Rotate it after testing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Hex transcript transforms") {
                    Toggle("Remove filler words", isOn: $controller.removeFillerWords)
                    Toggle("Spoken punctuation", isOn: $controller.spokenPunctuation)
                    Toggle("Lowercase", isOn: $controller.lowercase)
                    Toggle("Remove punctuation", isOn: $controller.removePunctuation)
                }

                Section("Mailbox seam") {
                    TextEditor(text: $seededTranscript)
                        .frame(minHeight: 80)
                    Button("Seed Final Transcript") {
                        PrototypeMailbox.seedCompleted(transcript: seededTranscript)
                        controller.refreshMailbox()
                    }
                    .disabled(seededTranscript.isEmpty || controller.isBusy)
                    Button("Clear Mailbox", role: .destructive) {
                        PrototypeMailbox.clear()
                        controller.refreshMailbox()
                    }
                    .disabled(controller.isBusy)
                }

                Section("Full request state") {
                    if let record = controller.mailboxRecord {
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
                            LabeledContent("Service total", value: "\(service) ms")
                        }
                        if let insertion = record.stopToInsertionMilliseconds {
                            LabeledContent("Stop to insertion", value: "\(insertion) ms")
                        }
                        if let returnToInsertion = record.returnToInsertionMilliseconds {
                            LabeledContent("Return to insertion", value: "\(returnToInsertion) ms")
                        }
                        if !record.rawTranscript.isEmpty {
                            LabeledContent("Raw", value: record.rawTranscript)
                        }
                        if !record.transcript.isEmpty {
                            LabeledContent("Final", value: record.transcript)
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
                }
            }
            .navigationTitle("Hex Dictation Tracer")
            .toolbar {
                Button("Refresh") {
                    controller.refreshMailbox()
                }
            }
            .onAppear {
                controller.refreshMailbox()
                controller.resumePendingCaptureIfNeeded()
            }
        }
    }
}
