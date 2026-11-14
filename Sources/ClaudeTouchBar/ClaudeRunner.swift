import Foundation

enum ClaudeRunnerError: Error {
    case executableNotFound
    case timedOut
    case cancelled
    case nonZeroExit(String)
}

/// Live updates pushed while `claude` is still running, so the Touch Bar can
/// show something better than a static "Thinking…" for the whole request.
enum ClaudeProgress {
    /// The answer text streamed so far (already flattened to one line).
    case text(String)
    /// A short Italian status line for the tool the model just invoked.
    case tool(String)
}

/// Handle for an in-flight request — lets the Touch Bar's Stop button kill it.
final class ClaudeRequest {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    fileprivate func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled { process.terminate() }
    }

    fileprivate var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

/// Shells out to the already-authenticated `claude` CLI (same login this Mac uses
/// in the terminal) instead of talking to the Anthropic API directly, so no
/// separate API key or billing setup is needed.
enum ClaudeRunner {

    private static let timeout: TimeInterval = 45

    // Without an explicit --model the CLI uses its default (heaviest) model:
    // measured ~5.9s for a one-word answer vs ~2.7s with Sonnet. One-line
    // Touch Bar answers don't need more than that.
    private static let model = "sonnet"

    // Past this much idle time, we start a fresh session instead of resuming.
    // Without this, --resume keeps reloading an ever-growing transcript (every
    // analyzed screenshot stays in it as inline base64) on every single
    // question, forever — a multi-week session measured at 7MB/176 messages
    // took ~7.7s just to resume for a one-word answer, vs ~3.2s fresh.
    private static let inactivityResetThreshold: TimeInterval = 20 * 60

    // The CLI can only read/write files under its working directory, so this
    // also doubles as the root for ScreenshotCapture's cache folder.
    static let workingDirectory = URL(fileURLWithPath: NSHomeDirectory())

    // The one tool the assistant is allowed to run: a "safe box" dispatcher that
    // is the ONLY way to touch Apple Calendar / Notes / Mail. Everything else on
    // the Mac stays denied. All AppleScript lives inside this script, so we never
    // grant the agent free-form osascript/shell.
    // build-app.sh copies it into the bundle, so the app works wherever the
    // repo was cloned; the fallback covers `swift run` from the repo root.
    static let tbToolPath = Bundle.main.path(forResource: "tb", ofType: nil)
        ?? FileManager.default.currentDirectoryPath + "/tb-tools/tb"

    // Persistent system prompt: enforces one-line Italian answers and teaches the
    // assistant how to drive Calendar/Notes/Mail through the `tb` tool.
    static let systemPrompt: String = {
        let tb = tbToolPath
        // Calendar names, note folders and the mail account are personal:
        // they come from the config file, never from the source.
        var personal = ""
        if let calendars = Config.calendars {
            personal += " Calendari disponibili: \(calendars)."
        }
        if Config.hasVault {
            personal += " Le note vanno in Obsidian; cartella predefinita per le note veloci: \(Config.noteDefaultFolder)."
            if let folders = Config.noteFolders { personal += " Cartelle: \(folders)." }
        } else {
            personal += " Le note non sono configurate: i comandi note-* non funzionano."
        }
        if let account = Config.mailAccount {
            personal += " I comandi mail-* usano l'account \(account)."
        } else {
            personal += " La posta non è configurata: i comandi mail-* non funzionano."
        }
        return """
        Rispondi sempre e rigorosamente in italiano, indipendentemente dalla lingua della domanda. \
        Le risposte devono essere sempre brevi e concise, senza spiegazioni superflue, su un'unica \
        riga logica, senza markdown né elenchi (verranno lette scorrendo su una Touch Bar stretta). \
        Per agire su Calendario e Mail (di Apple) e sulle Note (nel vault Obsidian) usa ESCLUSIVAMENTE \
        questo strumento, sempre col percorso completo: \(tb) <comando> [argomenti]. Comandi: \
        cal-list [giorni]; \
        cal-add <calendario> "AAAA-MM-GG HH:MM" <minuti> <titolo> [note]; \
        cal-del <calendario> "AAAA-MM-GG" <testo-nel-titolo>; \
        note-list [cartella]; note-read <testo-nel-titolo>; note-add <cartella> <titolo> <corpo>; note-del <testo-nel-titolo>; \
        mail-list [numero]; mail-read <n>; mail-search <testo> [numero]; mail-compose <destinatario> <oggetto> <corpo>; mail-del <n>; \
        brief (agenda di oggi + numero mail non lette). Per riepiloghi tipo "cosa ho oggi" usa brief. \
        La mail NON si invia: mail-compose apre solo una \
        bozza, che invii tu a mano. Scegli il calendario o la cartella in base al contenuto della richiesta. Le date vanno \
        sempre nel formato AAAA-MM-GG.\(personal)
        """
    }()

    // A dedicated, persistent session ID keeps every Touch Bar question in one
    // continuous conversation, isolated from any manual `claude` chats you run
    // yourself from the same working directory.
    private static var sessionID: String = {
        if let saved = UserDefaults.standard.string(forKey: "ClaudeTouchBarSessionID") {
            return saved
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "ClaudeTouchBarSessionID")
        return new
    }()

    private static var sessionStarted: Bool {
        get { UserDefaults.standard.bool(forKey: "ClaudeTouchBarSessionStarted") }
        set { UserDefaults.standard.set(newValue, forKey: "ClaudeTouchBarSessionStarted") }
    }

    private static var lastUsedAt: Date? {
        get {
            let stored = UserDefaults.standard.double(forKey: "ClaudeTouchBarLastUsedAt")
            return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "ClaudeTouchBarLastUsedAt")
        }
    }

    private static func startFreshSession() {
        let new = UUID().uuidString
        sessionID = new
        UserDefaults.standard.set(new, forKey: "ClaudeTouchBarSessionID")
        sessionStarted = false
    }

    /// Starts a brand-new session (instead of --resume) once the previous one has
    /// sat idle past inactivityResetThreshold, so the transcript claude has to
    /// reload never grows unbounded across days/weeks of use.
    private static func rotateSessionIfIdle() {
        defer { lastUsedAt = Date() }
        // No recorded last-use (e.g. right after installing this check) is
        // treated the same as "too idle" — rotating costs nothing extra (a
        // fresh session vs. a resume) and immediately caps any pre-existing
        // session that had already grown large.
        if let last = lastUsedAt, Date().timeIntervalSince(last) <= inactivityResetThreshold {
            return
        }
        startFreshSession()
    }

    /// User-requested reset (the "/new" chat command) — starts fresh right away,
    /// regardless of how recently the previous session was used.
    static func startNewSession() {
        startFreshSession()
        lastUsedAt = Date()
    }

    private static func flattenToSingleLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func resolveExecutable() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // None of the hardcoded candidates matched — fall back to scanning $PATH,
        // so a future install method this list doesn't happen to cover (nvm,
        // volta, a different Homebrew prefix, a manual reinstall, ...) doesn't
        // just silently break the app with "claude CLI not found".
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Maps a `tb` invocation to what the Touch Bar should say while it runs.
    private static func toolStatus(name: String, command: String) -> String {
        if name == "Read" { return "Guardo lo screenshot…" }
        let sub = command.components(separatedBy: " ").dropFirst().first ?? ""
        switch sub {
        case "cal-list": return "Leggo il calendario…"
        case "cal-add", "cal-del": return "Aggiorno il calendario…"
        case "note-list", "note-read": return "Cerco nelle note…"
        case "note-add", "note-del": return "Aggiorno le note…"
        case "mail-compose": return "Preparo la bozza…"
        case "mail-list", "mail-read", "mail-search", "mail-del": return "Controllo la posta…"
        case "brief": return "Preparo il riepilogo…"
        default: return "Ci lavoro…"
        }
    }

    @discardableResult
    static func describeMultiple(imagePaths: [String], caption: String, onProgress: @escaping (ClaudeProgress) -> Void = { _ in }, completion: @escaping (Result<String, ClaudeRunnerError>) -> Void) -> ClaudeRequest? {
        let list = imagePaths.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        var prompt = """
        Guarda questi screenshot, nell'ordine indicato:
        \(list)
        """
        if !caption.isEmpty {
            prompt += "\nRichiesta dell'utente riguardo a questi screenshot: \(caption)"
        } else {
            // No caption: default to a useful reading of the screen's own content
            // (e.g. a completed quiz/review page showing selected answers and
            // correctness) rather than a shallow one-line description that skips
            // the actual details visible on screen.
            prompt += "\nSe lo screenshot è una pagina di riepilogo/risultati di un quiz con risposte già date e confermate, riporta punteggio e quali risposte erano sbagliate e perché, invece di descrivere la pagina. Altrimenti descrivi cosa c'è di rilevante."
        }
        // Deliberate boundary: checking or explaining answers already
        // given is fine; picking an option for a question not yet answered
        // (e.g. a live test) is not — whatever the caption asks.
        prompt += """

        Se lo screenshot mostra domande di quiz/test non ancora risposte, non indicare quale opzione \
        scegliere: al massimo spiega l'argomento in generale. \
        Rispondi in modo breve e conciso. La risposta verrà letta scorrendo su \
        una Touch Bar stretta, quindi niente elenchi, niente markdown, testo \
        semplice su un'unica riga logica.
        """
        return ask(prompt, onProgress: onProgress, completion: completion)
    }

    @discardableResult
    static func ask(_ prompt: String, onProgress: @escaping (ClaudeProgress) -> Void = { _ in }, completion: @escaping (Result<String, ClaudeRunnerError>) -> Void) -> ClaudeRequest? {
        guard let executable = resolveExecutable() else {
            completion(.failure(.executableNotFound))
            return nil
        }
        rotateSessionIfIdle()
        let request = ClaudeRequest()

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            // --safe-mode skips CLAUDE.md/hooks/plugins/MCP servers (keeps OAuth working,
            // unlike --bare) so the CLI doesn't probe unrelated folders (Desktop, Photos, ...)
            // and trigger a pile of unrelated permission prompts. --allowedTools then grants
            // exactly one capability — the `tb` dispatcher — so the assistant can act on
            // Apple Calendar/Notes/Mail and nothing else, with no interactive confirmation
            // (which the Touch Bar couldn't show anyway).
            // stream-json + partial messages: answer text arrives token by token
            // (first words after ~1.8s instead of waiting for the whole reply),
            // and tool_use events tell us what `tb` command is running.
            var args = [
                "-p", "--safe-mode", "--no-chrome", "-n", "ClaudeTouchBar",
                "--model", model,
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--allowedTools", "Bash(\(tbToolPath):*)",
                "--append-system-prompt", systemPrompt
            ]
            args += sessionStarted ? ["--resume", sessionID] : ["--session-id", sessionID]
            args.append(prompt)
            process.arguments = args
            process.currentDirectoryURL = workingDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // Drain both pipes on dedicated background threads while the process
            // runs, instead of reading after waitUntilExit(). macOS pipes have a
            // small buffer (~64KB): if nothing is reading while the child writes
            // past that (e.g. a `brief` with a busy agenda, or a long note read
            // back), the child blocks on the write and waitUntilExit() never
            // returns — the Touch Bar sits on "Thinking…" indefinitely. Each
            // thread does a blocking readDataToEndOfFile(), which keeps
            // unblocking the writer and only returns once its pipe hits EOF.
            //
            // (An earlier version of this fix used FileHandle.readabilityHandler
            // + DispatchGroup instead. That traded the write-side deadlock for a
            // read-side one: if the EOF signal was ever missed, the group's
            // wait() blocked forever even after the child had already exited —
            // completion() never fired and "Thinking…" stuck around with no
            // process left to blame. The bounded wait(timeout:) below is a hard
            // ceiling specifically so that failure mode can't recur.)
            //
            // stdout is now a stream of JSON lines, so its thread reads chunk by
            // chunk (availableData blocks until data or EOF) and parses each
            // complete line as it lands, instead of one read at the very end.
            let readQueue = DispatchQueue(label: "com.claudetouchbar.pipereader", attributes: .concurrent)
            let readGroup = DispatchGroup()
            let bufferLock = NSLock()
            var finalResult: String?
            var resultIsError = false
            var errData = Data()

            readGroup.enter()
            readQueue.async {
                var pending = Data()
                var streamed = ""
                let handle = stdout.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = pending.subdata(in: pending.startIndex..<newline)
                        pending.removeSubrange(pending.startIndex...newline)
                        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                        switch event["type"] as? String {
                        case "stream_event":
                            guard let inner = event["event"] as? [String: Any] else { break }
                            switch inner["type"] as? String {
                            case "message_start":
                                // Each model turn (before/after a tool call) is a
                                // new message — only the last one is the answer.
                                streamed = ""
                            case "content_block_delta":
                                if let delta = inner["delta"] as? [String: Any],
                                   delta["type"] as? String == "text_delta",
                                   let piece = delta["text"] as? String {
                                    streamed += piece
                                    let snapshot = flattenToSingleLine(streamed)
                                    DispatchQueue.main.async { onProgress(.text(snapshot)) }
                                }
                            default: break
                            }
                        case "assistant":
                            let message = event["message"] as? [String: Any]
                            for block in message?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                                let name = block["name"] as? String ?? ""
                                let command = (block["input"] as? [String: Any])?["command"] as? String ?? ""
                                let status = toolStatus(name: name, command: command)
                                DispatchQueue.main.async { onProgress(.tool(status)) }
                            }
                        case "result":
                            bufferLock.lock()
                            finalResult = event["result"] as? String
                            resultIsError = event["is_error"] as? Bool ?? false
                            bufferLock.unlock()
                        default: break
                        }
                    }
                }
                readGroup.leave()
            }
            readGroup.enter()
            readQueue.async {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                bufferLock.lock(); errData = data; bufferLock.unlock()
                readGroup.leave()
            }

            // Written from timeoutWorkItem (a background queue) and read back
            // below on this queue — plain Bool would be a data race between the
            // two threads. Sharing bufferLock instead of a second lock costs
            // nothing extra: both critical sections are microseconds long.
            var didTimeOut = false
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    bufferLock.lock(); didTimeOut = true; bufferLock.unlock()
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            do {
                try process.run()
            } catch {
                timeoutWorkItem.cancel()
                DispatchQueue.main.async { completion(.failure(.executableNotFound)) }
                return
            }
            request.attach(process)

            process.waitUntilExit()
            timeoutWorkItem.cancel()
            // Exiting closes the process's end of each pipe, so both reader
            // threads hit EOF and return right after. The 5s cap is a hard
            // ceiling so a pipe/fd quirk can never leave completion() unfired.
            _ = readGroup.wait(timeout: .now() + 5)

            bufferLock.lock()
            let finalOut = finalResult ?? ""
            let finalIsError = resultIsError
            let finalErrData = errData
            let finalDidTimeOut = didTimeOut
            bufferLock.unlock()
            let wasCancelled = request.isCancelled
            // The Touch Bar label renders in single-line mode, which simply stops
            // at the first embedded newline instead of wrapping — if the model
            // slips a line break in despite being told not to, the rest of the
            // answer would silently disappear. Flatten to one line defensively.
            let out = flattenToSingleLine(finalOut)
            let err = flattenToSingleLine(String(data: finalErrData, encoding: .utf8) ?? "")

            DispatchQueue.main.async {
                if wasCancelled || finalDidTimeOut {
                    // A run killed before it ever succeeded may have left a
                    // half-created session behind; reusing its ID with
                    // --session-id would then fail, so start clean next time.
                    if !sessionStarted { startFreshSession() }
                    completion(.failure(wasCancelled ? .cancelled : .timedOut))
                } else if process.terminationStatus != 0 || finalIsError {
                    completion(.failure(.nonZeroExit(err.isEmpty ? (out.isEmpty ? "Unknown error" : out) : err)))
                } else if out.isEmpty {
                    completion(.failure(.nonZeroExit("No response")))
                } else {
                    sessionStarted = true
                    completion(.success(out))
                }
            }
        }
        return request
    }
}
