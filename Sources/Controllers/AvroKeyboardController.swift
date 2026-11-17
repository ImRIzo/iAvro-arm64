import Cocoa
@preconcurrency import InputMethodKit
import os

/// Result slot for one background dictionary lookup. The main thread may wait
/// on it for a short time (or longer right before committing a word).
private final class SearchBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var words: [String]?

    func finish(_ result: [String]) {
        lock.lock()
        words = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> [String]? {
        lock.lock()
        if let w = words { lock.unlock(); return w }
        lock.unlock()
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        semaphore.signal()   // keep it signalled for any later waiter
        lock.lock()
        defer { lock.unlock() }
        return words
    }
}

@objc(AvroKeyboardController)
@MainActor
class AvroKeyboardController: IMKInputController, @unchecked Sendable {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.omicronlab.avro", category: "Controller")

    nonisolated(unsafe) private var currentClient: (any IMKTextInput)?
    private var prevSelected: Int = -1
    private var composedBuffer = ""
    private var currentCandidates: [String] = []
    private var selectedCandidateIndex: Int = 0
    private var prefixStr: String = ""
    private var termStr: String = ""
    private var suffixStr: String = ""
    private var usedArrowKeys = false

    // Background dictionary search
    private static let searchQueue = DispatchQueue(label: "avro.dictionary-search", qos: .userInteractive, attributes: .concurrent)
    /// How long a keystroke waits for the dictionary before showing a provisional list.
    private static let keystrokeBudget: DispatchTimeInterval = .milliseconds(12)
    private var readyResults: [String: [String]] = [:]
    private var pendingSearches: [String: SearchBox] = [:]

    /// Splits the buffer into leading punctuation / term / trailing punctuation.
    /// Compiled once instead of on every keystroke.
    private static let splitRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(^(?::`|\\.`|[-\\]\\\\~!@#&*()_=+\\[{}'\";<>/?|.,])*?(?=(?:,{2,}))|^(?::`|\\.`|[-\\]\\\\~!@#&*()_=+\\[{}'\";<>/?|.,])*)(.*?(?:,,)*)((?::`|\\.`|[-\\]\\\\~!@#&*()_=+\\[{}'\";<>/?|.,])*$)"
    )

    @objc override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        self.currentClient = inputClient as? (any IMKTextInput)
    }

    /// Resolve the text client. IMK proxies don't always survive a Swift
    /// protocol cast, so fall back to IMKInputController.client().
    private func resolveClient(_ sender: Any?) -> (any IMKTextInput)? {
        if let c = sender as? (any IMKTextInput) { return c }
        return self.client()
    }

    /// Bounds-safe access to the highlighted candidate.
    private var safeSelectedCandidate: String? {
        guard !currentCandidates.isEmpty else { return nil }
        let idx = (0..<currentCandidates.count).contains(selectedCandidateIndex) ? selectedCandidateIndex : 0
        return currentCandidates[idx]
    }

    /// Returns the bare term from a full candidate (strips prefix/suffix), or nil if lengths don't fit.
    private func termPart(of candidate: String) -> String? {
        let ns = candidate as NSString
        let prefLen = (prefixStr as NSString).length
        let sufLen = (suffixStr as NSString).length
        let len = ns.length - (prefLen + sufLen)
        guard len >= 0, prefLen + len <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: prefLen, length: len))
    }

    @objc override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        self.currentClient = resolveClient(sender)
        CandidatesPanel.shared.delegate = self
    }

    @objc override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        if UserDefaults.standard.bool(for: .includeDictionary) {
            CacheManager.shared.persist()
        }
        super.deactivateServer(sender)
    }

    // MARK: - Background dictionary lookup

    /// Dictionary words for `term`. Starts a background search if needed and waits
    /// briefly (or, with `wait`, until it finishes). Returns nil if not ready yet;
    /// the candidate list is then refreshed when the search completes.
    private func dictionaryWords(for term: String, wait: Bool) -> [String]? {
        if let ready = readyResults[term] { return ready }

        let box: SearchBox
        if let existing = pendingSearches[term] {
            box = existing
        } else {
            box = SearchBox()
            pendingSearches[term] = box
            Self.searchQueue.async { [weak self] in
                let words = Database.shared.find(term: term)
                box.finish(words)
                Task { @MainActor [weak self] in
                    self?.searchFinished(term: term, words: words)
                }
            }
        }

        if let words = box.wait(timeout: wait ? .seconds(5) : Self.keystrokeBudget) {
            pendingSearches[term] = nil
            storeResult(words, for: term)
            return words
        }
        Self.log.debug("dictionary lookup for \(term, privacy: .public) still running — showing provisional list")
        return nil
    }

    private func storeResult(_ words: [String], for term: String) {
        if readyResults.count > 64 { readyResults.removeAll(keepingCapacity: true) }
        readyResults[term] = words
    }

    private func searchFinished(term: String, words: [String]) {
        pendingSearches[term] = nil
        guard readyResults[term] == nil else { return }   // already used synchronously
        storeResult(words, for: term)
        // Refresh only if the user is still composing this term and hasn't started
        // navigating the provisional list.
        guard term == termStr, !composedBuffer.isEmpty, !usedArrowKeys else { return }
        findCurrentCandidates()
        updateCandidatesPanel()
    }

    /// Before committing, make sure the list includes dictionary words.
    private func ensureFullCandidates() {
        guard UserDefaults.standard.bool(for: .includeDictionary),
              !composedBuffer.isEmpty, !termStr.isEmpty,
              readyResults[termStr] == nil,
              !usedArrowKeys,
              CacheManager.shared.array(forKey: termStr) == nil else { return }
        findCurrentCandidates(waitForDictionary: true)
        updateCandidatesPanel()
    }

    // MARK: - Candidate Finding

    private func findCurrentCandidates(waitForDictionary: Bool = false) {
        let started = ContinuousClock.now
        defer {
            Self.log.debug("candidates for \(self.composedBuffer, privacy: .public): \(self.currentCandidates.count) in \((ContinuousClock.now - started).milliseconds, format: .fixed(precision: 2)) ms")
        }
        currentCandidates.removeAll()
        selectedCandidateIndex = 0
        guard !composedBuffer.isEmpty else { return }

        guard let regex = Self.splitRegex,
              let match = regex.firstMatch(
                  in: composedBuffer,
                  range: NSRange(composedBuffer.startIndex..., in: composedBuffer)),
              match.numberOfRanges > 3 else {
            return
        }

        let nsString = composedBuffer as NSString
        self.prefixStr = AvroParser.shared.parse(nsString.substring(with: match.range(at: 1)))
        self.termStr = nsString.substring(with: match.range(at: 2))
        self.suffixStr = AvroParser.shared.parse(nsString.substring(with: match.range(at: 3)))

        let suggestions = SuggestionEngine.shared.getList(self.termStr) { term in
            self.dictionaryWords(for: term, wait: waitForDictionary)
        }
        let useDict = UserDefaults.standard.bool(for: .includeDictionary)

        if !suggestions.isEmpty {
            currentCandidates = suggestions

            var prevString: String?
            if useDict {
                prevSelected = -1
                prevString = CacheManager.shared.string(forKey: self.termStr)
            }

            for i in 0..<currentCandidates.count {
                let item = currentCandidates[i]
                if useDict, let prev = prevString, item == prev {
                    prevSelected = i
                }
                currentCandidates[i] = "\(self.prefixStr)\(item)\(self.suffixStr)"
            }

            // Emoticons
            if composedBuffer != self.termStr && useDict {
                if let smiley = AutoCorrect.shared.find(composedBuffer) {
                    currentCandidates.insert(smiley, at: 0)
                }
            }
        } else {
            currentCandidates.append(self.prefixStr)
        }
    }

    internal override func updateComposition() {
        currentClient?.setMarkedText(
            composedBuffer,
            selectionRange: NSRange(location: composedBuffer.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func updateCandidatesPanel() {
        if !currentCandidates.isEmpty {
            if CandidatesPanel.shared.useCustomPanel {
                CandidatesPanel.shared.updateCandidates(currentCandidates)
                CandidatesPanel.shared.show(for: currentClient)

                if prevSelected > -1 {
                    CandidatesPanel.shared.selectCandidate(at: prevSelected)
                }
            } else {
                let defaults = UserDefaults.standard
                if CandidatesPanel.shared.panelType != defaults.integer(for: .candidatePanelType) {
                    CandidatesPanel.shared.reallocate()
                }
                CandidatesPanel.shared.imkUpdateCandidates()
                CandidatesPanel.shared.imkShow(kIMKLocateCandidatesBelowHint)

            // Fallback: some web editors (e.g. Google Docs) report cursor
            // position (0,0), placing the panel at the bottom-left corner.
            // Reposition near the mouse cursor instead.
            let frame = CandidatesPanel.shared.imkCandidateFrame()

            if frame.origin.x < 1, frame.origin.y < 1 {
                var point = NSEvent.mouseLocation
                point.y -= 36
                CandidatesPanel.shared.imkSetCandidateFrameTopLeft(point)
            }

            if prevSelected > -1 {
                for _ in 0..<prevSelected {
                    if CandidatesPanel.shared.panelType == kIMKSingleColumnScrollingCandidatePanel {
                        CandidatesPanel.shared.moveDown(self)
                    } else if CandidatesPanel.shared.panelType == kIMKSingleRowSteppingCandidatePanel {
                        CandidatesPanel.shared.moveRight(self)
                    }
                }
            }
            } // end IMK else
        } else {
            CandidatesPanel.shared.hide()
        }
    }

    // MARK: - IMK Candidate Callbacks (used when custom panel is off)

    @objc override func candidates(_ sender: Any!) -> [Any]! {
        currentCandidates
    }

    @objc override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        guard !CandidatesPanel.shared.useCustomPanel, let candidateString else { return }
        if UserDefaults.standard.bool(for: .includeDictionary) {
            if !termStr.isEmpty {
                let isFirst = candidateString.string == currentCandidates.first
                if !(isFirst && prevSelected == -1), let term = termPart(of: candidateString.string) {
                    CacheManager.shared.setString(term, forKey: termStr)

                    if let tmpArray = CacheManager.shared.base(forKey: candidateString.string),
                       tmpArray.count > 1 {
                        CacheManager.shared.setString(tmpArray[1], forKey: tmpArray[0])
                    }
                }
            }
        }
        selectedCandidateIndex = currentCandidates.firstIndex(of: candidateString.string) ?? 0
    }

    @objc override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard !CandidatesPanel.shared.useCustomPanel, let candidateString else { return }
        currentClient?.insertText(candidateString.string, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        clearCompositionBuffer()
        currentCandidates.removeAll()
        updateCandidatesPanel()

        usedArrowKeys = false
        if UserDefaults.standard.bool(for: .includeDictionary) {
            CacheManager.shared.scheduleSave()
        }
    }

    // MARK: - Candidate Actions

    private func commitCandidate(_ candidate: String) {
        currentClient?.insertText(candidate, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        clearCompositionBuffer()
        currentCandidates.removeAll()
        updateCandidatesPanel()

        usedArrowKeys = false
        if UserDefaults.standard.bool(for: .includeDictionary) {
            CacheManager.shared.scheduleSave()
        }
    }

    @objc override func commitComposition(_ sender: Any!) {
        guard !composedBuffer.isEmpty else { return }

        resolveClient(sender)?.insertText(composedBuffer, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        clearCompositionBuffer()
        currentCandidates.removeAll()
        updateCandidatesPanel()
    }

    @objc override func composedString(_ sender: Any!) -> Any! {
        let buffer = composedBuffer
        return NSAttributedString(string: buffer)
    }

    private func clearCompositionBuffer() {
        composedBuffer = ""
        readyResults.removeAll(keepingCapacity: true)
        currentClient?.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    // MARK: - Input Handling

    @objc override func inputText(_ string: String!, client sender: Any!) -> Bool {
        self.currentClient = resolveClient(sender)
        guard let string, !string.isEmpty else { return false }

        if string == " " {
            // Nothing being composed → let the app type a normal space.
            guard !composedBuffer.isEmpty else { return false }
            ensureFullCandidates()
            let candidate = (CandidatesPanel.shared.useCustomPanel
                             ? CandidatesPanel.shared.selectedCandidate : nil)
                ?? safeSelectedCandidate
                ?? composedBuffer
            Self.log.debug("space → commit \(candidate, privacy: .public)")
            commitCandidate(candidate)
            // Insert the space ourselves so the candidate window can't swallow it.
            currentClient?.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            return true
        }

        // Number key selection (1-9) when custom panel is visible
        if CandidatesPanel.shared.useCustomPanel,
           CandidatesPanel.shared.isVisible,
           let digit = string.first, digit >= "1", digit <= "9" {
            ensureFullCandidates()
            let index = Int(String(digit))! - 1
            if index < currentCandidates.count {
                commitCandidate(currentCandidates[index])
                return true
            }
        }

        composedBuffer += string
        findCurrentCandidates()
        updateComposition()
        updateCandidatesPanel()
        return true
    }

    @objc func deleteBackward(_ sender: Any?) {
        guard !composedBuffer.isEmpty else { return }
        composedBuffer.removeLast()
        findCurrentCandidates()
        updateComposition()
        updateCandidatesPanel()
    }

    @objc func insertTab(_ sender: Any?) {
        commitText("\t")
    }

    @objc func insertNewline(_ sender: Any?) {
        if UserDefaults.standard.bool(for: .commitNewLineOnEnter) {
            commitText("\n")
        } else {
            commitText("")
        }
    }

    @objc func moveUp(_ sender: Any?) {
        if CandidatesPanel.shared.isVisible {
            usedArrowKeys = true
            CandidatesPanel.shared.moveUp(self)
        }
    }

    @objc func moveDown(_ sender: Any?) {
        if CandidatesPanel.shared.isVisible {
            usedArrowKeys = true
            CandidatesPanel.shared.moveDown(self)
        }
    }

    @objc func moveLeft(_ sender: Any?) {
        if CandidatesPanel.shared.isVisible {
            usedArrowKeys = true
            CandidatesPanel.shared.moveLeft(self)
        }
    }

    @objc func moveRight(_ sender: Any?) {
        if CandidatesPanel.shared.isVisible {
            usedArrowKeys = true
            CandidatesPanel.shared.moveRight(self)
        }
    }

    @objc func cancelOperation(_ sender: Any?) {
        clearCompositionBuffer()
        currentCandidates.removeAll()
        CandidatesPanel.shared.hide()
    }

    @objc override func didCommand(by aSelector: Selector, client sender: Any!) -> Bool {
        self.currentClient = resolveClient(sender)
        guard !composedBuffer.isEmpty else { return false }

        // Escape: cancel composition (both modes)
        if aSelector == #selector(cancelOperation(_:)) {
            cancelOperation(sender)
            return true
        }

        // All navigable commands
        if responds(to: aSelector) {
            if aSelector == #selector(insertTab(_:)) ||
               aSelector == #selector(insertNewline(_:)) ||
               aSelector == #selector(deleteBackward(_:)) ||
               aSelector == #selector(moveLeft(_:)) ||
               aSelector == #selector(moveRight(_:)) ||
               aSelector == #selector(moveUp(_:)) ||
               aSelector == #selector(moveDown(_:)) {
                perform(aSelector, with: sender)
                return true
            }
        }
        return false
    }

    private func commitText(_ string: String) {
        ensureFullCandidates()
        if CandidatesPanel.shared.useCustomPanel {
            if let candidate = CandidatesPanel.shared.selectedCandidate {
                commitCandidate(candidate)
                if !string.isEmpty {
                    currentClient?.insertText(string, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                }
            } else {
                NSSound.beep()
            }
        } else {
            if let candidate = safeSelectedCandidate {
                candidateSelected(NSAttributedString(string: candidate))
                currentClient?.insertText(string, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            } else {
                NSSound.beep()
            }
        }
    }

    @objc override func menu() -> NSMenu! {
        let appMenu = (NSApp.delegate as? AppDelegate)?.menu
        return appMenu
    }

    @objc override func showPreferences(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.imPref?.showPreferencesWindow()
    }
}

// MARK: - CandidatePanelDelegate

extension AvroKeyboardController: CandidatePanelDelegate {
    func candidateSelectionChanged(to candidate: String, at index: Int) {
        if UserDefaults.standard.bool(for: .includeDictionary) {
            if !termStr.isEmpty {
                let isFirst = candidate == currentCandidates.first
                if !(isFirst && prevSelected == -1), let term = termPart(of: candidate) {
                    CacheManager.shared.setString(term, forKey: termStr)

                    if let tmpArray = CacheManager.shared.base(forKey: candidate),
                       tmpArray.count > 1 {
                        CacheManager.shared.setString(tmpArray[1], forKey: tmpArray[0])
                    }
                }
            }
        }
        selectedCandidateIndex = index
    }

    func candidateSelected(_ candidate: String, at index: Int) {
        commitCandidate(candidate)
    }
}
