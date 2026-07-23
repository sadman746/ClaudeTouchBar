import Foundation

enum ScreenshotError: Error {
    case captureFailed(String)
}

/// Silently captures the whole screen to a temporary PNG using the system
/// `screencapture` tool. Requires the user to grant Screen Recording
/// permission to this app the first time it runs.
enum ScreenshotCapture {
    // The `claude` CLI can only Read files inside its working directory (~/Claude),
    // so screenshots must land there, not in the system temp folder — otherwise
    // its own file-access tool refuses to open them.
    private static let cacheDir = URL(fileURLWithPath: NSHomeDirectory() + "/Claude/.touchbar-cache")

    static func captureScreen(completion: @escaping (Result<URL, ScreenshotError>) -> Void) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("screenshot-\(UUID().uuidString).png")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", url.path]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(.failure(.captureFailed("\(error)"))) }
                return
            }
            process.waitUntilExit()

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                    completion(.success(url))
                } else {
                    completion(.failure(.captureFailed(err.isEmpty ? "screencapture ha fallito" : err)))
                }
            }
        }
    }
}
