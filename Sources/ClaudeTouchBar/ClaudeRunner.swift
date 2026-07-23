import Foundation

enum ClaudeRunnerError: Error {
    case executableNotFound
    case timedOut
    case nonZeroExit(String)
}

/// Shells out to the already-authenticated `claude` CLI (same login this Mac uses
/// in the terminal) instead of talking to the Anthropic API directly, so no
/// separate API key or billing setup is needed.
enum ClaudeRunner {

    private static let timeout: TimeInterval = 45

    // A dedicated, persistent session ID keeps every Touch Bar question in one
    // continuous conversation, isolated from Sadman's own manual chats in ~/Claude.
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

    private static func resolveExecutable() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func describe(imagePath: String, completion: @escaping (Result<String, ClaudeRunnerError>) -> Void) {
        let prompt = """
        Guarda lo screenshot che si trova in questo percorso: \(imagePath)
        Spiega in italiano, in modo colloquiale e molto sintetico (massimo 2 frasi brevi, \
        meno di 200 caratteri in totale) cosa vedi/cosa sta succedendo sullo schermo. \
        La risposta verrà letta scorrendo su una Touch Bar strettissima, quindi niente elenchi, \
        niente markdown, solo testo semplice su un'unica riga logica.
        """
        ask(prompt, completion: completion)
    }

    static func ask(_ prompt: String, completion: @escaping (Result<String, ClaudeRunnerError>) -> Void) {
        guard let executable = resolveExecutable() else {
            completion(.failure(.executableNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            // --safe-mode skips CLAUDE.md/hooks/plugins/MCP servers (keeps OAuth working,
            // unlike --bare) so the CLI doesn't probe unrelated folders (Desktop, Photos, ...)
            // and trigger a pile of unrelated permission prompts for a one-shot screenshot query.
            // Running with cwd = ~/Claude keeps every session transcript in the same,
            // easy-to-find project bucket Sadman already uses for this assistant.
            var args = ["-p", "--safe-mode", "--no-chrome", "--strict-mcp-config", "-n", "ClaudeTouchBar"]
            args += sessionStarted ? ["--resume", sessionID] : ["--session-id", sessionID]
            args.append(prompt)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Claude")

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            var didTimeOut = false
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    didTimeOut = true
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

            process.waitUntilExit()
            timeoutWorkItem.cancel()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if didTimeOut {
                    completion(.failure(.timedOut))
                } else if process.terminationStatus != 0 {
                    completion(.failure(.nonZeroExit(err.isEmpty ? "Errore sconosciuto" : err)))
                } else if out.isEmpty {
                    completion(.failure(.nonZeroExit("Nessuna risposta")))
                } else {
                    sessionStarted = true
                    completion(.success(out))
                }
            }
        }
    }
}
