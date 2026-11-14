import Foundation
import ImageIO

enum ScreenshotError: Error {
    case captureFailed(String)
}

/// Silently captures the whole screen to a temporary PNG using the system
/// `screencapture` tool. Requires the user to grant Screen Recording
/// permission to this app the first time it runs.
enum ScreenshotCapture {
    // The `claude` CLI can only Read files inside its working directory (see
    // ClaudeRunner.workingDirectory), so screenshots must land there, not in the
    // system temp folder — otherwise its own file-access tool refuses to open them.
    private static let cacheDir = ClaudeRunner.workingDirectory.appendingPathComponent(".touchbar-cache")

    /// Removes any screenshots left behind by a multi-shot flow that never
    /// finished (app quit or crashed mid-session) — this directory holds
    /// nothing but this app's own temporary screenshots, so it's always
    /// safe to empty at launch, before any new capture can land in it.
    static func purgeStaleCache() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // Long edge Claude's vision works best at; anything larger is downsampled
    // on its side anyway, after paying to upload it.
    private static let maxPixelSize = 1568

    /// Converts a full-resolution Retina PNG (often several MB) into a JPEG
    /// capped at maxPixelSize. Smaller files are read faster by the CLI and
    /// keep the resumed session transcript from ballooning. Returns nil (and
    /// leaves the PNG alone) if anything goes wrong.
    private static func downscaled(_ png: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let jpg = png.deletingPathExtension().appendingPathExtension("jpg")
        guard let dest = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        try? FileManager.default.removeItem(at: png)
        return jpg
    }

    static func captureScreen(completion: @escaping (Result<URL, ScreenshotError>) -> Void) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("screenshot-\(UUID().uuidString).png")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", url.path]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            // screencapture is normally near-instant, but unlike ClaudeRunner's
            // call to `claude` this had no timeout at all — if it ever got stuck
            // (e.g. a Screen Recording permission prompt that can't show from
            // here), the Touch Bar would sit on "Thinking…" forever with
            // nothing to time it out, the exact bug already fixed for the
            // `claude` CLI call elsewhere in this app.
            let timeoutLock = NSLock()
            var didTimeOut = false
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    timeoutLock.lock(); didTimeOut = true; timeoutLock.unlock()
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutWorkItem)

            do {
                try process.run()
            } catch {
                timeoutWorkItem.cancel()
                DispatchQueue.main.async { completion(.failure(.captureFailed("\(error)"))) }
                return
            }
            process.waitUntilExit()
            timeoutWorkItem.cancel()

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            timeoutLock.lock()
            let timedOut = didTimeOut
            timeoutLock.unlock()

            let captured = !timedOut && process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
            let finalURL = captured ? (downscaled(url) ?? url) : url

            DispatchQueue.main.async {
                if timedOut {
                    completion(.failure(.captureFailed("Screenshot timed out")))
                } else if captured {
                    completion(.success(finalURL))
                } else {
                    completion(.failure(.captureFailed(err.isEmpty ? "screencapture failed" : err)))
                }
            }
        }
    }
}
