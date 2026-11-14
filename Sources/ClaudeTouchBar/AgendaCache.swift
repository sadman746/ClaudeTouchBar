import AppKit
import EventKit

/// Reads Calendar through EventKit inside the app itself, which holds the
/// Calendars permission — unlike `tb`'s AppleScript path (~10-20s, misses some
/// recurring occurrences). Two outputs:
///  - a one-line ambient summary for the idle Touch Bar ("📅 15:00 Call · ✉️ 3");
///  - a plain-text cache file that `tb cal-list` reads instead of AppleScript.
final class AgendaCache {

    /// Read by `tb cal-list`; one event per line, prefixed with a sortable
    /// "YYYY-MM-DD HH:MM" so the script can filter by day with plain string
    /// comparison. Kept outside .touchbar-cache, which is wiped at launch.
    static let cacheFile = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/ClaudeTouchBar/calendar.txt")

    private static let daysAhead = 8
    private static let refreshInterval: TimeInterval = 5 * 60

    private let store = EKEventStore()
    private var timer: Timer?
    private(set) var summary = "📅 …"
    private var nextEventText: String?
    private var unreadMail: Int?

    /// Fired on the main queue whenever `summary` changes.
    var onChange: ((String) -> Void)?

    func start() {
        requestAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                NotificationCenter.default.addObserver(self, selector: #selector(self.storeChanged), name: .EKEventStoreChanged, object: self.store)
            }
            self.refresh()
            self.timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    @objc private func storeChanged() {
        refresh()
    }

    private func requestAccess(_ done: @escaping (Bool) -> Void) {
        let finish: (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: finish)
        } else {
            store.requestAccess(to: .event, completion: finish)
        }
    }

    func refresh() {
        refreshCalendar()
        refreshUnreadMail()
    }

    // MARK: - Calendar

    private func refreshCalendar() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: Self.daysAhead, to: dayStart) else { return }
        let predicate = store.predicateForEvents(withStart: dayStart, end: end, calendars: nil)
        // predicateForEvents expands recurring events into their occurrences.
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        let sortable = DateFormatter()
        sortable.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = events.map { event -> String in
            let time = event.isAllDay
                ? sortable.string(from: event.startDate).prefix(10) + " tutto-il-giorno"
                : Substring(sortable.string(from: event.startDate))
            return "\(time) | \(event.calendar.title): \(event.title ?? "(senza titolo)")"
        }
        writeCache(lines)

        let now = Date()
        let next = events.first { !$0.isAllDay && $0.endDate > now }
        nextEventText = next.map { describe($0, now: now) }
        publish()
    }

    private func describe(_ event: EKEvent, now: Date) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let title = event.title ?? "(senza titolo)"
        let calendar = Calendar.current
        if event.startDate <= now { return "ora: \(title)" }
        if calendar.isDateInToday(event.startDate) { return "\(time.string(from: event.startDate)) \(title)" }
        if calendar.isDateInTomorrow(event.startDate) { return "domani \(time.string(from: event.startDate)) \(title)" }
        let day = DateFormatter()
        day.dateFormat = "dd/MM HH:mm"
        return "\(day.string(from: event.startDate)) \(title)"
    }

    private func writeCache(_ lines: [String]) {
        let dir = Self.cacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? body.write(to: Self.cacheFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Mail

    /// Only counted while Mail is already running: `tell application "Mail"`
    /// would otherwise launch it every five minutes just for a badge.
    private func refreshUnreadMail() {
        let mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        guard mailRunning, let account = Config.mailAccount else {
            unreadMail = nil
            publish()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let count = Self.countUnread(account: account)
            DispatchQueue.main.async {
                self?.unreadMail = count
                self?.publish()
            }
        }
    }

    private static func countUnread(account: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The account name travels as an argument, never spliced into the script.
        process.arguments = [
            "-e", "on run argv",
            "-e", "tell application \"Mail\" to count (messages of mailbox \"INBOX\" of account (item 1 of argv) whose read status is false)",
            "-e", "end run",
            account
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Same rule as everywhere else in this app: nothing may hang forever.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return Int(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    // MARK: -

    private func publish() {
        var parts = ["📅 " + (nextEventText ?? "Nessun impegno in arrivo")]
        if let unreadMail { parts.append("✉️ \(unreadMail)") }
        let new = parts.joined(separator: "  ·  ")
        guard new != summary else { return }
        summary = new
        onChange?(new)
    }
}
