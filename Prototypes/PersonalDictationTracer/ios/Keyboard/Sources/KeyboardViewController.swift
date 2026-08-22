import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private enum Page {
        case letters
        case numbers
    }

    private enum ShiftState {
        case lowercase
        case uppercase
        case capsLock
    }

    private enum Key: Equatable {
        case character(String)
        case shift
        case delete
        case letters
        case numbers
        case space
        case returnKey
        case nextKeyboard
    }

    private static let letterRows: [[Key]] = [
        "qwertyuiop".map { .character(String($0)) },
        "asdfghjkl".map { .character(String($0)) },
        [.shift] + "zxcvbnm".map { .character(String($0)) } + [.delete],
        [.numbers, .nextKeyboard, .space, .returnKey],
    ]

    private static let numberRows: [[Key]] = [
        "1234567890".map { .character(String($0)) },
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
            .map(Key.character),
        [".", ",", "?", "!", "'"].map(Key.character) + [.delete],
        [.letters, .nextKeyboard, .space, .returnKey],
    ]

    private var page = Page.letters
    private var shiftState = ShiftState.lowercase
    private var lastShiftTap: Date?
    private var keyButtons: [(key: Key, button: UIButton)] = []
    private var stateTimer: Timer?

    var enableInputClicksWhenVisible: Bool { true }

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var dictationButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "mic.fill")
        configuration.imagePadding = 7
        configuration.title = "Start Voice"

        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "hex.dictate"
        button.accessibilityHint = "Starts or stops Hex voice entry for this text field"
        button.addTarget(self, action: #selector(handleDictationButton), for: .touchUpInside)
        return button
    }()

    private let rowsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 7
        stack.distribution = .fillEqually
        return stack
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .secondarySystemBackground
        configureLayout()
        rebuildRows()
        renderState(note: "Ready")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startStatePolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumeAndInsertIfAvailable()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stateTimer?.invalidate()
        stateTimer = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        button(for: .nextKeyboard)?.isHidden = !needsInputModeSwitchKey
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateReturnKeyTitle()
    }

    private func configureLayout() {
        let actionRow = UIStackView(arrangedSubviews: [statusLabel, dictationButton])
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = 12

        dictationButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        dictationButton.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let stack = UIStackView(arrangedSubviews: [actionRow, rowsStack])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 298)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { row in
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        keyButtons.removeAll(keepingCapacity: true)

        let rows = page == .letters ? Self.letterRows : Self.numberRows
        for keys in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .fill
            row.distribution = .fillProportionally
            row.spacing = 6

            for key in keys {
                let button = makeButton(for: key)
                row.addArrangedSubview(button)
                keyButtons.append((key, button))
                applyWidth(for: key, to: button)
            }
            rowsStack.addArrangedSubview(row)
        }

        updateKeyTitles()
    }

    private func makeButton(for key: Key) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .medium
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = backgroundColor(for: key)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .systemFont(ofSize: 20, weight: .regular)
            return attributes
        }

        let button = UIButton(configuration: configuration)
        button.isAccessibilityElement = true
        button.accessibilityLabel = accessibilityLabel(for: key)
        button.accessibilityIdentifier = accessibilityIdentifier(for: key)

        switch key {
        case .nextKeyboard:
            button.addTarget(
                self,
                action: #selector(handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        case .delete:
            button.addTarget(self, action: #selector(deleteBackward), for: .touchDown)
        default:
            button.addAction(UIAction { [weak self] _ in
                self?.handle(key)
            }, for: .touchUpInside)
        }

        return button
    }

    private func applyWidth(for key: Key, to button: UIButton) {
        switch key {
        case .space:
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 126).isActive = true
        case .shift, .delete, .letters, .numbers, .nextKeyboard, .returnKey:
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        case .character:
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
    }

    private func handle(_ key: Key) {
        UIDevice.current.playInputClick()

        switch key {
        case let .character(character):
            let text = shiftState == .lowercase ? character : character.uppercased()
            textDocumentProxy.insertText(text)
            if shiftState == .uppercase {
                shiftState = .lowercase
                updateKeyTitles()
            }
        case .shift:
            toggleShift()
        case .letters:
            page = .letters
            rebuildRows()
        case .numbers:
            page = .numbers
            rebuildRows()
        case .space:
            textDocumentProxy.insertText(" ")
        case .returnKey:
            textDocumentProxy.insertText("\n")
            if page == .letters, shiftState != .capsLock {
                shiftState = .uppercase
                updateKeyTitles()
            }
        case .delete, .nextKeyboard:
            break
        }
    }

    @objc private func deleteBackward() {
        UIDevice.current.playInputClick()
        textDocumentProxy.deleteBackward()
    }

    private func toggleShift() {
        let now = Date()
        if let lastShiftTap, now.timeIntervalSince(lastShiftTap) < 0.35 {
            shiftState = .capsLock
            self.lastShiftTap = nil
        } else {
            shiftState = shiftState == .lowercase ? .uppercase : .lowercase
            lastShiftTap = now
        }
        updateKeyTitles()
    }

    private func updateKeyTitles() {
        for (key, button) in keyButtons {
            switch key {
            case let .character(character):
                button.configuration?.title = shiftState == .lowercase
                    ? character
                    : character.uppercased()
            case .shift:
                button.configuration?.image = UIImage(
                    systemName: shiftState == .capsLock ? "capslock.fill" : "shift.fill"
                )
                button.configuration?.baseBackgroundColor = shiftState == .lowercase
                    ? .tertiarySystemFill
                    : .systemBackground
            case .delete:
                button.configuration?.image = UIImage(systemName: "delete.left.fill")
            case .letters:
                button.configuration?.title = "ABC"
            case .numbers:
                button.configuration?.title = "123"
            case .space:
                button.configuration?.title = "space"
            case .returnKey:
                break
            case .nextKeyboard:
                button.configuration?.image = UIImage(systemName: "globe")
            }
        }
        updateReturnKeyTitle()
    }

    private func updateReturnKeyTitle() {
        guard let returnButton = button(for: .returnKey) else { return }
        returnButton.configuration?.title = switch textDocumentProxy.returnKeyType {
        case .done: "done"
        case .go: "go"
        case .join: "join"
        case .next: "next"
        case .search, .google, .yahoo: "search"
        case .send: "send"
        case .continue: "continue"
        default: "return"
        }
    }

    private func button(for key: Key) -> UIButton? {
        keyButtons.first { $0.key == key }?.button
    }

    private func backgroundColor(for key: Key) -> UIColor {
        switch key {
        case .character, .space:
            .systemBackground
        case .returnKey:
            .systemBlue
        default:
            .tertiarySystemFill
        }
    }

    private func accessibilityLabel(for key: Key) -> String {
        switch key {
        case let .character(character): character
        case .shift: "Shift"
        case .delete: "Delete"
        case .letters: "Letters"
        case .numbers: "Numbers"
        case .space: "Space"
        case .returnKey: "Return"
        case .nextKeyboard: "Next keyboard"
        }
    }

    private func accessibilityIdentifier(for key: Key) -> String {
        switch key {
        case let .character(character): "hex.key.\(character)"
        case .shift: "hex.key.shift"
        case .delete: "hex.key.delete"
        case .letters: "hex.key.letters"
        case .numbers: "hex.key.numbers"
        case .space: "hex.key.space"
        case .returnKey: "hex.key.return"
        case .nextKeyboard: "hex.key.next-keyboard"
        }
    }

    @objc private func handleDictationButton() {
        guard hasFullAccess else {
            renderState(note: "Allow Full Access in Settings")
            return
        }

        guard let record = PrototypeMailbox.current() else {
            startDictationOrPromptArm()
            return
        }

        switch record.state {
        case .completed:
            consumeAndInsertIfAvailable()
        case .captureRequested, .capturing:
            PrototypeMailbox.requestStop(id: record.id)
            renderState(note: "Stopping…")
        case .stopRequested, .processing:
            renderState(note: statusForCurrentRecord())
        case .consumed, .failed:
            startDictationOrPromptArm()
        }
    }

    private func startDictationOrPromptArm() {
        guard PrototypeWarmSession.current()?.isReady() == true else {
            renderState(note: "Hold the Action Button to Arm Hex")
            return
        }

        PrototypeMailbox.requestCapture(
            documentIdentifier: textDocumentProxy.documentIdentifier
        )
        renderState(note: "Starting…")
    }

    private func startStatePolling() {
        stateTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(pollState),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
    }

    @objc private func pollState() {
        failInterruptedRequestIfNeeded()
        if PrototypeMailbox.current()?.state == .completed {
            consumeAndInsertIfAvailable()
        } else {
            renderState(note: statusForCurrentRecord())
        }
    }

    private func failInterruptedRequestIfNeeded() {
        guard
            PrototypeWarmSession.current()?.isReady() != true,
            let record = PrototypeMailbox.current()
        else {
            return
        }

        switch record.state {
        case .captureRequested, .capturing, .stopRequested, .processing:
            PrototypeMailbox.fail(
                id: record.id,
                message: "Hex is no longer armed. Use the Arm Hex shortcut."
            )
        case .completed, .consumed, .failed:
            break
        }
    }

    private func consumeAndInsertIfAvailable() {
        guard hasFullAccess else {
            renderState(note: "Allow Full Access in Settings")
            return
        }
        if let expectedDocument = PrototypeMailbox.current()?.documentIdentifier,
           expectedDocument != textDocumentProxy.documentIdentifier {
            renderState(note: "Return to the original field to insert")
            return
        }
        guard let consumed = PrototypeMailbox.consumeCompleted() else {
            renderState(note: statusForCurrentRecord())
            return
        }

        textDocumentProxy.insertText(consumed.transcript)
        PrototypeMailbox.markInserted(id: consumed.id)
        renderState(note: "Transcript inserted")
    }

    private func statusForCurrentRecord() -> String {
        guard let record = PrototypeMailbox.current() else {
            return PrototypeWarmSession.current()?.isReady() == true
                ? "Voice ready • tap Start Voice"
                : "Hold the Action Button to Arm Hex"
        }
        return switch record.state {
        case .captureRequested: "Starting • tap Stop to cancel"
        case .capturing: "Recording • tap Stop here"
        case .stopRequested: "Stopping recording…"
        case .processing: "Ronin is transcribing…"
        case .completed: "Transcript ready"
        case .consumed:
            if let insertedAt = record.insertedAt,
               Date().timeIntervalSince(insertedAt) < 2 {
                "Transcript inserted"
            } else if PrototypeWarmSession.current()?.isReady() == true {
                "Voice ready • tap Start Voice"
            } else {
                "Hold the Action Button to Arm Hex"
            }
        case .failed: record.errorMessage ?? "Dictation failed"
        }
    }

    private func renderState(note: String) {
        statusLabel.text = note

        guard hasFullAccess else {
            dictationButton.configuration?.title = "Full Access Required"
            dictationButton.configuration?.image = UIImage(systemName: "lock.fill")
            dictationButton.isEnabled = true
            return
        }

        let state = PrototypeMailbox.current()?.state
        switch state {
        case .captureRequested, .capturing:
            dictationButton.configuration?.image = UIImage(systemName: "stop.fill")
            dictationButton.configuration?.title = "Stop Voice"
            dictationButton.configuration?.baseBackgroundColor = .systemRed
            dictationButton.isEnabled = true
        case .stopRequested, .processing:
            dictationButton.configuration?.image = UIImage(systemName: "waveform")
            dictationButton.configuration?.title = "Sending…"
            dictationButton.configuration?.baseBackgroundColor = .systemBlue
            dictationButton.isEnabled = false
        case .completed:
            dictationButton.configuration?.image = UIImage(systemName: "arrow.down.to.line")
            dictationButton.configuration?.title = "Insert Transcript"
            dictationButton.configuration?.baseBackgroundColor = .systemBlue
            dictationButton.isEnabled = true
        case .consumed, .failed, nil:
            dictationButton.configuration?.image = UIImage(systemName: "mic.fill")
            dictationButton.configuration?.baseBackgroundColor = .systemBlue
            if PrototypeWarmSession.current()?.isReady() == true {
                dictationButton.configuration?.title = "Start Voice"
            } else {
                dictationButton.configuration?.title = "Arm with Action Button"
            }
            dictationButton.isEnabled = true
        }
    }
}
