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

    // The CLI can only read/write files under its working directory, so this
    // also doubles as the root for ScreenshotCapture's cache folder.
    static let workingDirectory = URL(fileURLWithPath: NSHomeDirectory())

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
        Look at the screenshot at this path: \(imagePath)
        Describe, briefly and conversationally (2 short sentences max, under 200 \
        characters total), what's on screen / what's happening. The answer will be \
        read scrolling across a narrow Touch Bar, so no lists, no markdown, plain \
        text on a single logical line.
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
            var args = ["-p", "--safe-mode", "--no-chrome", "--strict-mcp-config", "-n", "ClaudeTouchBar"]
            args += sessionStarted ? ["--resume", sessionID] : ["--session-id", sessionID]
            args.append(prompt)
            process.arguments = args
            process.currentDirectoryURL = workingDirectory

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
                    completion(.failure(.nonZeroExit(err.isEmpty ? "Unknown error" : err)))
                } else if out.isEmpty {
                    completion(.failure(.nonZeroExit("No response")))
                } else {
                    sessionStarted = true
                    completion(.success(out))
                }
            }
        }
    }
}
