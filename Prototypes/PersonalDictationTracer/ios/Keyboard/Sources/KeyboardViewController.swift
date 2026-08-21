import UIKit

final class KeyboardViewController: UIInputViewController {
    private let stateLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    private lazy var insertButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Insert Pending Transcript"
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(insertPendingTranscript), for: .touchUpInside)
        return button
    }()

    private lazy var recordButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Open Hex & Record"
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(openHexAndRecord), for: .touchUpInside)
        return button
    }()

    private lazy var nextKeyboardButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.title = "Next Keyboard"
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(advanceKeyboard), for: .touchUpInside)
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .secondarySystemBackground
        let stack = UIStackView(
            arrangedSubviews: [stateLabel, recordButton, insertButton, nextKeyboardButton]
        )
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])

        renderState(note: "Keyboard loaded")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumeAndInsertIfAvailable(trigger: "keyboard activated")
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
    }

    @objc private func insertPendingTranscript() {
        consumeAndInsertIfAvailable(trigger: "button tapped")
    }

    @objc private func openHexAndRecord() {
        guard hasFullAccess else {
            renderState(note: "Enable Allow Full Access before starting dictation")
            return
        }

        let requestID = PrototypeMailbox.requestCapture()
        guard let url = URL(string: "hextracer://record?id=\(requestID.uuidString)") else {
            PrototypeMailbox.fail(id: requestID, message: "Could not construct the handoff URL.")
            renderState(note: "Could not construct handoff URL")
            return
        }
        guard let extensionContext else {
            PrototypeMailbox.fail(id: requestID, message: "Keyboard extension context is unavailable.")
            renderState(note: "Extension context unavailable")
            return
        }

        renderState(note: "Asking iOS to open Hex…")
        extensionContext.open(url) { [weak self] didOpen in
            Task { @MainActor in
                guard let self else { return }
                if didOpen {
                    self.renderState(note: "Hex handoff accepted")
                } else {
                    PrototypeMailbox.fail(
                        id: requestID,
                        message: "iOS rejected the keyboard-to-app handoff."
                    )
                    self.renderState(note: "iOS rejected the app handoff")
                }
            }
        }
    }

    @objc private func advanceKeyboard() {
        advanceToNextInputMode()
    }

    private func consumeAndInsertIfAvailable(trigger: String) {
        guard hasFullAccess else {
            renderState(note: "Allow Full Access before inserting a transcript")
            return
        }
        guard let consumed = PrototypeMailbox.consumeCompleted() else {
            renderState(note: "No completed request (\(trigger))")
            return
        }

        textDocumentProxy.insertText(consumed.transcript)
        PrototypeMailbox.markInserted(id: consumed.id)
        renderState(note: "Inserted \(consumed.id.uuidString.prefix(8)) once")
    }

    private func renderState(note: String) {
        let access = hasFullAccess ? "full access" : "restricted"
        if let record = PrototypeMailbox.current() {
            stateLabel.text = "\(note)\n\(access) · \(record.state.rawValue)\n\(record.id.uuidString)\n\(record.transcript)"
            insertButton.isEnabled = record.state == .completed
            recordButton.isEnabled = record.state == .consumed || record.state == .failed
        } else {
            stateLabel.text = "\(note)\n\(access) · mailbox empty"
            insertButton.isEnabled = false
            recordButton.isEnabled = true
        }
        recordButton.configuration?.title = hasFullAccess ? "Open Hex & Record" : "Full Access Required"
    }
}
