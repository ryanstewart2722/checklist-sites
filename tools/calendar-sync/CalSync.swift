// Checklist Calendar Sync
// Reads events from the Mac's Calendar app (every calendar under your online accounts:
// iCloud, Google, Exchange; skips Birthdays, Holidays and other subscribed calendars),
// writes them to ~/.checklist-sync/events.json, then runs upload.mjs to put them in Firebase.
//
// It lives in a small .app bundle so macOS can ask once for Calendar access.
// Run with --list to print the calendars it would include, without uploading.

import EventKit
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let dir = home.appendingPathComponent(".checklist-sync")
let listOnly = CommandLine.arguments.contains("--list")

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Ask for (or confirm) Calendar access ──
let store = EKEventStore()
var granted = false
var answered = false
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, err in
        granted = ok
        if let err { log("Calendar access error: \(err.localizedDescription)") }
        answered = true
    }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; answered = true }
}
while !answered { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
guard granted else {
    log("No Calendar access. Allow it in System Settings → Privacy & Security → Calendars → Checklist Calendar Sync.")
    exit(2)
}

// ── Which calendars ──
// Optional ~/.checklist-sync/config.json: { "excludeAccounts": ["outlook"] } (account names as in Calendar).
struct Config: Decodable { var excludeAccounts: [String]? }
let config = (try? Data(contentsOf: dir.appendingPathComponent("config.json")))
    .flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
let excluded = Set((config?.excludeAccounts ?? []).map { $0.lowercased() })

let accountTypes: Set<EKSourceType> = [.calDAV, .exchange, .mobileMe]
let skipTitle = try! NSRegularExpression(pattern: "holiday|birthday", options: .caseInsensitive)
let calendars = store.calendars(for: .event).filter { cal in
    cal.type != .birthday && cal.type != .subscription
        && accountTypes.contains(cal.source.sourceType)
        && !excluded.contains(cal.source.title.lowercased())
        && skipTitle.firstMatch(in: cal.title, range: NSRange(cal.title.startIndex..., in: cal.title)) == nil
}

if listOnly {
    for c in calendars { print("\(c.source.title)  —  \(c.title)") }
    exit(0)
}

// ── Events: from a week ago to 90 days ahead ──
let tz = TimeZone.current
var cal = Calendar(identifier: .gregorian)
cal.timeZone = tz
let today = cal.startOfDay(for: Date())
let start = cal.date(byAdding: .day, value: -7, to: today)!
let end = cal.date(byAdding: .day, value: 90, to: today)!

let dayFmt = DateFormatter()
dayFmt.locale = Locale(identifier: "en_US_POSIX"); dayFmt.timeZone = tz; dayFmt.dateFormat = "yyyy-MM-dd"
let timeFmt = DateFormatter()
timeFmt.locale = Locale(identifier: "en_US_POSIX"); timeFmt.timeZone = tz; timeFmt.dateFormat = "hh:mma"

var out: [[String: Any]] = []
var seen = Set<String>()
let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)

for ev in store.events(matching: predicate) {
    guard let s = ev.startDate, let e = ev.endDate else { continue }
    let title = (ev.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty { continue }
    // The same meeting often sits in two accounts' calendars; keep one.
    let key = title.lowercased() + "|" + String(Int(s.timeIntervalSince1970))
    if seen.contains(key) { continue }
    seen.insert(key)

    var day = cal.startOfDay(for: s)
    var first = true
    repeat {
        if day >= start && day < end {
            out.append([
                "date": dayFmt.string(from: day),
                "time": ev.isAllDay ? "All day" : (first ? timeFmt.string(from: s) : "All day"),
                "end": ev.isAllDay ? "" : timeFmt.string(from: e),
                "name": title,
                "calendar": ev.calendar.title,
                "account": ev.calendar.source.title,
                "allDay": ev.isAllDay,
                "sort": ev.isAllDay || !first ? 0 : Int(s.timeIntervalSince(day) / 60),
            ])
        }
        first = false
        day = cal.date(byAdding: .day, value: 1, to: day)!
        // All-day events end at midnight; timed events only show on their start day.
    } while ev.isAllDay && day < e && day < end
}

out.sort { (($0["date"] as! String), ($0["sort"] as! Int)) < (($1["date"] as! String), ($1["sort"] as! Int)) }

let payload: [String: Any] = [
    "syncedAt": ISO8601DateFormatter().string(from: Date()),
    "calendars": calendars.map { "\($0.source.title) — \($0.title)" },
    "events": out,
]

try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let file = dir.appendingPathComponent("events.json")
let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: file, options: .atomic)
log("Read \(out.count) events from \(calendars.count) calendars.")

// ── Upload ──
let node = ProcessInfo.processInfo.environment["CHECKLIST_NODE"] ?? "/usr/local/bin/node"
let uploader = dir.appendingPathComponent("upload.mjs").path
let p = Process()
p.executableURL = URL(fileURLWithPath: node)
p.arguments = [uploader, file.path]
do { try p.run(); p.waitUntilExit() } catch { log("Upload failed to start: \(error)"); exit(1) }
exit(p.terminationStatus)
