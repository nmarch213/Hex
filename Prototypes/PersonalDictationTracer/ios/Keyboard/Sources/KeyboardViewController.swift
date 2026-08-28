import UIKit
import os.log

@MainActor
final class KeyboardViewController: UIInputViewController,
    UIInputViewAudioFeedback,
    UIGestureRecognizerDelegate
{
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

    private struct GlideCommit {
        var insertedText: String
        let candidateWords: [String]
        let isCapitalized: Bool
        let leadingSpace: String
        let documentIdentifier: UUID?
        let path: [PrototypeGlidePoint]
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
    private var statePollingTask: Task<Void, Never>?
    private var latestSnapshot: PrototypeIPCSnapshot?
    private var swipeToTypeEnabled = false
    private var glidePoints: [PrototypeGlidePoint] = []
    private var isSuppressingTapForGlide = false
    private var lastGlideCommit: GlideCommit?
    private var glideTrailClearWorkItem: DispatchWorkItem?
    private var keyboardHeightConstraint: NSLayoutConstraint?

    private lazy var glideDecoder: PrototypeGlideDecoder? = {
        guard let resourceURL = Bundle(for: Self.self).url(
            forResource: "english-glide-frequency",
            withExtension: "txt"
        ),
        let contents = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            HexLog.app.error("Glide lexicon resource is unavailable")
            return nil
        }

        let entries = PrototypeGlideLexicon.entries(from: contents)
        guard entries.isEmpty == false else {
            HexLog.app.error("Glide lexicon contains no usable entries")
            return nil
        }
        HexLog.app.notice("Loaded \(entries.count) local glide words")
        return PrototypeGlideDecoder(entries: entries)
    }()

    private lazy var glidePanRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleGlidePan(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
        return recognizer
    }()

    private let glideTrailLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.72).cgColor
        layer.lineWidth = 4
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }()

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

    private lazy var cancelButton: UIButton = {
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "xmark")

        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "hex.cancel-dictation"
        button.accessibilityLabel = "Cancel Dictation"
        button.accessibilityHint = "Discards the current voice input and resets Hex"
        button.addTarget(self, action: #selector(handleCancelButton), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    private let rowsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 7
        stack.distribution = .fillEqually
        return stack
    }()

    private let candidateRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        return stack
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        hasDictationKey = true
        swipeToTypeEnabled = PrototypeKeyboardPreferences.isSwipeToTypeEnabled()
        view.backgroundColor = .secondarySystemBackground
        configureLayout()
        rebuildRows()
        configureGlideInput()
        renderState(note: "Ready")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSwipeToTypeSetting()
        startStatePolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumeAndInsertIfAvailable()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statePollingTask?.cancel()
        statePollingTask = nil
        clearGlideCandidates()
        requestCancellationForClosingKeyboard()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        rowsStack.layer.addSublayer(glideTrailLayer)
        glideTrailLayer.frame = rowsStack.bounds
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        button(for: .nextKeyboard)?.isHidden = !needsInputModeSwitchKey
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        validateGlideReplacement()
        updateReturnKeyTitle()
    }

    private func configureLayout() {
        let actionRow = UIStackView(
            arrangedSubviews: [statusLabel, cancelButton, dictationButton]
        )
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = 12

        dictationButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        dictationButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
        cancelButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
        cancelButton.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let stack = UIStackView(
            arrangedSubviews: [actionRow, candidateRow, rowsStack]
        )
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

        let candidateHeightConstraint = candidateRow.heightAnchor.constraint(
            equalToConstant: 34
        )
        candidateHeightConstraint.priority = .defaultHigh
        candidateHeightConstraint.isActive = true

        let heightConstraint = view.heightAnchor.constraint(
            equalToConstant: swipeToTypeEnabled ? 340 : 298
        )
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        keyboardHeightConstraint = heightConstraint
    }

    private func configureGlideInput() {
        rowsStack.addGestureRecognizer(glidePanRecognizer)
        rowsStack.layer.addSublayer(glideTrailLayer)
        updateSwipeToTypeConfiguration()
    }

    private func refreshSwipeToTypeSetting() {
        let isEnabled = PrototypeKeyboardPreferences.isSwipeToTypeEnabled()
        guard isEnabled != swipeToTypeEnabled else { return }
        swipeToTypeEnabled = isEnabled
        updateSwipeToTypeConfiguration()
    }

    private func updateSwipeToTypeConfiguration() {
        candidateRow.isHidden = swipeToTypeEnabled == false
        keyboardHeightConstraint?.constant = swipeToTypeEnabled ? 340 : 298
        if swipeToTypeEnabled {
            showGlideCandidates([])
            _ = glideDecoder
        } else {
            clearGlideCandidates()
        }
        view.setNeedsLayout()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === glidePanRecognizer,
              swipeToTypeEnabled,
              page == .letters,
              glideDecoder != nil else {
            return false
        }
        return character(at: gestureRecognizer.location(in: rowsStack)) != nil
    }

    @objc private func handleGlidePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: rowsStack)
        switch recognizer.state {
        case .began:
            clearGlideCandidates()
            glideTrailClearWorkItem?.cancel()
            let translation = recognizer.translation(in: rowsStack)
            let origin = PrototypeGlidePoint(
                x: Double(location.x - translation.x),
                y: Double(location.y - translation.y)
            )
            glidePoints = [origin]
            appendGlidePoint(location)
            isSuppressingTapForGlide = true
            updateGlideTrail()
        case .changed:
            appendGlidePoint(location)
            updateGlideTrail()
        case .ended:
            appendGlidePoint(location)
            finishGlide()
            scheduleGlideEnd()
        case .cancelled, .failed:
            glidePoints.removeAll(keepingCapacity: true)
            scheduleGlideEnd()
        default:
            break
        }
    }

    private func appendGlidePoint(_ point: CGPoint) {
        let candidate = PrototypeGlidePoint(
            x: Double(point.x),
            y: Double(point.y)
        )
        guard glidePoints.last.map({ $0.distance(to: candidate) >= 2 }) != false else {
            return
        }
        glidePoints.append(candidate)
    }

    private func finishGlide() {
        guard let glideDecoder else {
            glidePoints.removeAll(keepingCapacity: true)
            return
        }

        let path = glidePoints
        glidePoints.removeAll(keepingCapacity: true)
        let keyCenters = currentLetterCenters
        let startedAt = CACurrentMediaTime()
        let candidates = glideDecoder.candidates(
            for: path,
            keyCenters: keyCenters,
            limit: 3
        )
        let elapsedMilliseconds = Int(
            (CACurrentMediaTime() - startedAt) * 1_000
        )
        HexLog.app.debug(
            "Glide decoded \(candidates.count) candidates in \(elapsedMilliseconds) ms"
        )

        guard let first = candidates.first, first.score <= 6 else {
            showGlideCandidates([])
            return
        }
        commitGlideWord(first.word, candidates: candidates, path: path)
    }

    private func commitGlideWord(
        _ word: String,
        candidates: [PrototypeGlideCandidate],
        path: [PrototypeGlidePoint]
    ) {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let leadingSpace = context.last.map { character in
            character.isLetter || character.isNumber ? " " : ""
        } ?? ""
        let isCapitalized = shiftState != .lowercase
            || shouldCapitalizeGlideWord(after: context)
        let displayedWord = styledGlideWord(word, isCapitalized: isCapitalized)
        let insertedText = leadingSpace + displayedWord + " "

        textDocumentProxy.insertText(insertedText)
        UIDevice.current.playInputClick()
        lastGlideCommit = GlideCommit(
            insertedText: insertedText,
            candidateWords: candidates.map(\.word),
            isCapitalized: isCapitalized,
            leadingSpace: leadingSpace,
            documentIdentifier: currentDocumentIdentifier,
            path: path
        )
        showGlideCandidates(candidates.map(\.word))

        if shiftState == .uppercase {
            shiftState = .lowercase
            updateKeyTitles()
        }
        logGlideFixture(path: path, selectedWord: word)
    }

    private func replaceLastGlideWord(with candidateIndex: Int) {
        guard var commit = lastGlideCommit,
              commit.candidateWords.indices.contains(candidateIndex),
              commit.documentIdentifier == currentDocumentIdentifier,
              textDocumentProxy.documentContextBeforeInput?.hasSuffix(
                  commit.insertedText
              ) == true else {
            clearGlideCandidates()
            return
        }

        for _ in commit.insertedText {
            textDocumentProxy.deleteBackward()
        }
        let replacement = styledGlideWord(
            commit.candidateWords[candidateIndex],
            isCapitalized: commit.isCapitalized
        )
        commit.insertedText = commit.leadingSpace + replacement + " "
        textDocumentProxy.insertText(commit.insertedText)
        UIDevice.current.playInputClick()
        lastGlideCommit = commit
        showGlideCandidates(commit.candidateWords)
        logGlideFixture(
            path: commit.path,
            selectedWord: commit.candidateWords[candidateIndex]
        )
    }

    private func showGlideCandidates(_ words: [String]) {
        candidateRow.arrangedSubviews.forEach { view in
            candidateRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for index in 0..<3 {
            var configuration = UIButton.Configuration.plain()
            configuration.baseForegroundColor = .label
            configuration.title = words.indices.contains(index)
                ? styledGlideWord(
                    words[index],
                    isCapitalized: lastGlideCommit?.isCapitalized == true
                )
                : ""

            let button = UIButton(configuration: configuration)
            button.isEnabled = words.indices.contains(index)
            button.accessibilityLabel = words.indices.contains(index)
                ? "Replace with \(configuration.title ?? words[index])"
                : nil
            button.addAction(UIAction { [weak self] _ in
                self?.replaceLastGlideWord(with: index)
            }, for: .touchUpInside)
            candidateRow.addArrangedSubview(button)
        }
    }

    private func clearGlideCandidates() {
        lastGlideCommit = nil
        showGlideCandidates([])
    }

    private func validateGlideReplacement() {
        guard let commit = lastGlideCommit else { return }
        guard commit.documentIdentifier == currentDocumentIdentifier,
              textDocumentProxy.documentContextBeforeInput?.hasSuffix(
                  commit.insertedText
              ) == true else {
            clearGlideCandidates()
            return
        }
    }

    private func styledGlideWord(
        _ word: String,
        isCapitalized: Bool
    ) -> String {
        guard isCapitalized, let first = word.first else {
            return word.lowercased()
        }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    private func shouldCapitalizeGlideWord(after context: String) -> Bool {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        return ".!?".contains(last)
    }

    private func character(at point: CGPoint) -> Character? {
        for (key, button) in keyButtons {
            guard case let .character(character) = key,
                  let letter = character.first else {
                continue
            }
            let frame = button.convert(button.bounds, to: rowsStack)
                .insetBy(dx: -8, dy: -8)
            if frame.contains(point) {
                return letter
            }
        }
        return nil
    }

    private var currentLetterCenters: [Character: PrototypeGlidePoint] {
        Dictionary(uniqueKeysWithValues: keyButtons.compactMap { key, button in
            guard case let .character(character) = key,
                  let letter = character.first else {
                return nil
            }
            let center = button.convert(
                CGPoint(x: button.bounds.midX, y: button.bounds.midY),
                to: rowsStack
            )
            return (
                letter,
                PrototypeGlidePoint(x: Double(center.x), y: Double(center.y))
            )
        })
    }

    private func updateGlideTrail() {
        guard let first = glidePoints.first else {
            glideTrailLayer.path = nil
            return
        }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: first.x, y: first.y))
        for point in glidePoints.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        glideTrailLayer.path = path.cgPath
    }

    private func scheduleGlideEnd() {
        let clearWorkItem = DispatchWorkItem { [weak self] in
            self?.glideTrailLayer.path = nil
        }
        glideTrailClearWorkItem?.cancel()
        glideTrailClearWorkItem = clearWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.16,
            execute: clearWorkItem
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.isSuppressingTapForGlide = false
        }
    }

    private func logGlideFixture(
        path: [PrototypeGlidePoint],
        selectedWord: String
    ) {
        #if DEBUG
        let width = max(Double(rowsStack.bounds.width), 1)
        let height = max(Double(rowsStack.bounds.height), 1)
        let normalizedPath = path.map { point in
            String(
                format: "[%.4f,%.4f]",
                point.x / width,
                point.y / height
            )
        }.joined(separator: ",")
        HexLog.app.debug(
            "Glide prototype selected \(selectedWord, privacy: .private) for path [\(normalizedPath, privacy: .private)]"
        )
        #endif
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
                guard let self, isSuppressingTapForGlide == false else { return }
                clearGlideCandidates()
                handle(key)
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
        guard isSuppressingTapForGlide == false else { return }
        clearGlideCandidates()
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
        clearGlideCandidates()
        guard hasFullAccess else {
            renderState(note: "Allow Full Access in Settings")
            return
        }

        do {
            let snapshot = try PrototypeMailbox.keyboardSnapshot(
                documentIdentifier: currentDocumentIdentifier
            )
            latestSnapshot = snapshot
            guard let record = snapshot.mailbox else {
                try startDictationOrPromptArm()
                return
            }

            switch record.state {
            case .completed:
                if isCurrentTextDestination(for: record) {
                    consumeAndInsertIfAvailable(snapshot: snapshot)
                } else {
                    try PrototypeMailbox.discardCompleted(id: record.id)
                    refreshState(note: "Pending transcript discarded")
                }
            case .captureRequested, .capturing:
                let stopRequested = try PrototypeMailbox.requestKeyboardStop(
                    id: record.id,
                    documentIdentifier: currentDocumentIdentifier
                )
                refreshState(
                    note: stopRequested
                        ? "Stopping…"
                        : "Voice entry cancelled because the original text destination is unavailable"
                )
            case .stopRequested, .processing, .cancelRequested:
                renderState(note: status(for: snapshot), snapshot: snapshot)
            case .consumed, .failed:
                try startDictationOrPromptArm()
            }
        } catch {
            renderIPCFailure(error)
        }
    }

    @objc private func handleCancelButton() {
        guard hasFullAccess else {
            renderState(note: "Allow Full Access in Settings")
            return
        }

        do {
            guard let record = try PrototypeMailbox.current() else {
                refreshState(note: "Voice input reset")
                return
            }
            try PrototypeMailbox.requestCancel(id: record.id)
            refreshState(note: "Cancelling…")
        } catch {
            renderIPCFailure(error)
        }
    }

    private func startDictationOrPromptArm() throws(PrototypeIPCError) {
        guard try PrototypeWarmSession.current()?.isReady() == true else {
            renderState(note: "Hold the Action Button to Arm Hex")
            return
        }

        guard let documentIdentifier = currentDocumentIdentifier else {
            renderState(note: "This text destination cannot be used for safe voice insertion")
            return
        }

        try PrototypeMailbox.requestCapture(documentIdentifier: documentIdentifier)
        refreshState(note: "Starting…")
    }

    private func startStatePolling() {
        statePollingTask?.cancel()
        statePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollState()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func pollState() async {
        let documentIdentifier = currentDocumentIdentifier
        let pollingTask = Task.detached(priority: .utility) {
            do {
                return Result<PrototypeIPCSnapshot, PrototypeIPCError>.success(
                    try PrototypeMailbox.keyboardSnapshot(
                        documentIdentifier: documentIdentifier
                    )
                )
            } catch let error as PrototypeIPCError {
                return .failure(error)
            } catch {
                preconditionFailure("Unexpected keyboard IPC error: \(error)")
            }
        }
        let result = await pollingTask.value
        guard !Task.isCancelled else { return }

        switch result {
        case let .success(snapshot):
            latestSnapshot = snapshot
            if snapshot.mailbox?.state == .completed {
                consumeAndInsertIfAvailable(snapshot: snapshot)
            } else {
                renderState(note: status(for: snapshot), snapshot: snapshot)
            }
        case let .failure(error):
            renderIPCFailure(error)
        }
    }

    private func consumeAndInsertIfAvailable(
        snapshot: PrototypeIPCSnapshot? = nil
    ) {
        guard hasFullAccess else {
            renderState(note: "Allow Full Access in Settings")
            return
        }
        do {
            let currentRecord = try snapshot?.mailbox ?? PrototypeMailbox.current()
            let destinationBeforeConsume = currentDocumentIdentifier
            if let record = currentRecord,
               !PrototypeDestinationIdentityFence.permitsInsertion(
                   expected: record.documentIdentifier,
                   beforeConsume: destinationBeforeConsume,
                   afterConsume: destinationBeforeConsume
               ) {
                let currentSnapshot = try (
                    snapshot
                        ?? PrototypeMailbox.keyboardSnapshot(
                            documentIdentifier: currentDocumentIdentifier
                        )
                )
                renderState(
                    note: "Return to the original text destination to insert",
                    snapshot: currentSnapshot
                )
                return
            }
            guard let record = currentRecord,
                  let consumed = try PrototypeMailbox.consumeCompleted(
                      id: record.id,
                      documentIdentifier: destinationBeforeConsume
                  ) else {
                refreshState()
                return
            }

            guard PrototypeDestinationIdentityFence.permitsInsertion(
                expected: consumed.documentIdentifier,
                beforeConsume: destinationBeforeConsume,
                afterConsume: currentDocumentIdentifier
            ) else {
                try PrototypeMailbox.discardConsumed(id: consumed.id)
                refreshState(note: "Text destination changed • dictate again")
                return
            }

            clearGlideCandidates()
            textDocumentProxy.insertText(consumed.transcript)
            try PrototypeMailbox.markInserted(id: consumed.id)
            refreshState(note: "Transcript inserted")
        } catch {
            if let ipcError = error as? PrototypeIPCError {
                renderIPCFailure(ipcError)
            } else {
                assertionFailure("Unexpected keyboard IPC error: \(error)")
            }
        }
    }

    private func status(for snapshot: PrototypeIPCSnapshot) -> String {
        let warmSessionReady = snapshot.warmSession?.isReady() == true
        guard let record = snapshot.mailbox else {
            return warmSessionReady
                ? "Voice ready • tap Start Voice"
                : "Hold the Action Button to Arm Hex"
        }
        return switch record.state {
        case .captureRequested: "Starting • tap Stop to cancel"
        case .capturing: "Recording • tap Stop here"
        case .stopRequested: "Stopping recording…"
        case .cancelRequested: "Cancelling voice entry…"
        case .processing: "Ronin is transcribing…"
        case .completed: "Transcript ready"
        case .consumed:
            if let insertedAt = record.insertedAt,
               Date().timeIntervalSince(insertedAt) < 2 {
                "Transcript inserted"
            } else if warmSessionReady {
                "Voice ready • tap Start Voice"
            } else {
                "Hold the Action Button to Arm Hex"
            }
        case .failed: record.errorMessage ?? "Dictation failed"
        }
    }

    private func refreshState(note: String? = nil) {
        do {
            let snapshot = try PrototypeMailbox.keyboardSnapshot(
                documentIdentifier: currentDocumentIdentifier
            )
            latestSnapshot = snapshot
            renderState(note: note ?? status(for: snapshot), snapshot: snapshot)
        } catch {
            renderIPCFailure(error)
        }
    }

    private func renderState(
        note: String,
        snapshot: PrototypeIPCSnapshot? = nil
    ) {
        statusLabel.text = note

        guard hasFullAccess else {
            cancelButton.isHidden = true
            dictationButton.configuration?.title = "Full Access Required"
            dictationButton.configuration?.image = UIImage(systemName: "lock.fill")
            dictationButton.isEnabled = true
            return
        }

        let snapshot = snapshot ?? latestSnapshot
        let record = snapshot?.mailbox
        let warmSessionReady = snapshot?.warmSession?.isReady() == true
        switch record?.state {
        case .captureRequested, .capturing:
            cancelButton.isHidden = false
            cancelButton.isEnabled = true
            dictationButton.configuration?.image = UIImage(systemName: "stop.fill")
            dictationButton.configuration?.title = "Stop Voice"
            dictationButton.configuration?.baseBackgroundColor = .systemRed
            dictationButton.isEnabled = true
        case .stopRequested, .processing:
            cancelButton.isHidden = false
            cancelButton.isEnabled = true
            dictationButton.configuration?.image = UIImage(systemName: "waveform")
            dictationButton.configuration?.title = "Sending…"
            dictationButton.configuration?.baseBackgroundColor = .systemBlue
            dictationButton.isEnabled = false
        case .cancelRequested:
            cancelButton.isHidden = false
            cancelButton.isEnabled = false
            dictationButton.configuration?.image = UIImage(systemName: "xmark")
            dictationButton.configuration?.title = "Cancelling…"
            dictationButton.configuration?.baseBackgroundColor = .systemOrange
            dictationButton.isEnabled = false
        case .completed:
            cancelButton.isHidden = false
            cancelButton.isEnabled = true
            if let record, isCurrentTextDestination(for: record) {
                dictationButton.configuration?.image = UIImage(systemName: "arrow.down.to.line")
                dictationButton.configuration?.title = "Insert Transcript"
                dictationButton.configuration?.baseBackgroundColor = .systemBlue
            } else {
                dictationButton.configuration?.image = UIImage(systemName: "trash")
                dictationButton.configuration?.title = "Discard Pending"
                dictationButton.configuration?.baseBackgroundColor = .systemOrange
            }
            dictationButton.isEnabled = true
        case .consumed, .failed, nil:
            cancelButton.isHidden = true
            dictationButton.configuration?.image = UIImage(systemName: "mic.fill")
            dictationButton.configuration?.baseBackgroundColor = .systemBlue
            if warmSessionReady {
                dictationButton.configuration?.title = "Start Voice"
            } else {
                dictationButton.configuration?.title = "Arm with Action Button"
            }
            dictationButton.isEnabled = true
        }
    }

    private func isCurrentTextDestination(for record: PrototypeMailboxRecord) -> Bool {
        let currentDocument = currentDocumentIdentifier
        return PrototypeDestinationIdentityFence.permitsInsertion(
            expected: record.documentIdentifier,
            beforeConsume: currentDocument,
            afterConsume: currentDocument
        )
    }

    /// Some host text inputs return no Objective-C document identifier even though
    /// the Swift SDK imports this property as non-optional. Read it dynamically so
    /// absence fails closed instead of manufacturing a wildcard destination.
    private var currentDocumentIdentifier: UUID? {
        (textDocumentProxy as? NSObject)?
            .value(forKey: "documentIdentifier") as? UUID
    }

    private func requestCancellationForClosingKeyboard() {
        guard hasFullAccess else { return }
        do {
            guard let record = try PrototypeMailbox.current() else { return }
            switch record.state {
            case .captureRequested, .capturing, .stopRequested, .processing:
                try PrototypeMailbox.requestCancel(id: record.id)
            case .cancelRequested, .completed, .consumed, .failed:
                break
            }
        } catch {
            HexLog.app.error("Keyboard close cancellation failed")
        }
    }

    private func renderIPCFailure(_: PrototypeIPCError) {
        latestSnapshot = nil
        HexLog.app.error("Keyboard extension IPC failed")
        statusLabel.text = "Hex keyboard state unavailable"
        dictationButton.configuration?.image = UIImage(systemName: "exclamationmark.triangle.fill")
        dictationButton.configuration?.title = "Reopen Hex"
        dictationButton.configuration?.baseBackgroundColor = .systemOrange
        dictationButton.isEnabled = false
    }
}
