import AppKit
import ApplicationServices
import ScreenCaptureKit
import EventKit

/// The Phase-1 "quick tools" pack: clipboard, the user's selection, saving a screenshot, showing a
/// file in Finder, arranging the front window, and adding reminders / calendar events. These sit
/// beside ComputerControl's mouse-and-keyboard primitives; RealtimeHost gates and dispatches them.
enum PlummyTools {

    // MARK: Clipboard

    static func readClipboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    static func writeClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: The user's selection (for "summarise this")

    /// The text the user has selected anywhere on screen, or the focused field's whole text as a
    /// fallback. Needs Accessibility. Returns nil when there is nothing (or no permission).
    static func readSelection() -> String? {
        guard ComputerControl.isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement
        if let selected = axString(element, kAXSelectedTextAttribute), !selected.isEmpty { return selected }
        if let value = axString(element, kAXValueAttribute), !value.isEmpty { return value }
        return nil
    }

    // MARK: Files

    /// Saves a screenshot of the main display to the Desktop. Returns a short message for the user.
    static func saveScreenshot(name: String?) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                return "I couldn't find the display to capture."
            }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return "I couldn't encode the screenshot."
            }
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            var base = (name?.isEmpty == false ? name! : "Screenshot \(stamp())")
            base = base.replacingOccurrences(of: "/", with: "-")
            let filename = base.lowercased().hasSuffix(".png") ? base : base + ".png"
            try png.write(to: desktop.appendingPathComponent(filename))
            return "Saved to the Desktop as \(filename)."
        } catch {
            return "Screenshot failed: \(error.localizedDescription)"
        }
    }

    /// Shows a file or folder in Finder.
    static func revealInFinder(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return "I couldn't find \(path)." }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
        return "Showing \(URL(fileURLWithPath: expanded).lastPathComponent) in Finder."
    }

    // MARK: Windows

    static let windowPlaces = ["left", "right", "top", "bottom", "top-left", "top-right",
                               "bottom-left", "bottom-right", "full", "center"]

    /// Moves / resizes the frontmost app's focused window within the main screen's visible area.
    static func arrangeWindow(_ place: String) -> String {
        guard ComputerControl.isTrusted else {
            return "I need Accessibility permission to move windows. Allow Plummy in System Settings, Privacy & Security, Accessibility."
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return "There's no front window to move." }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return "That app has no window I can move."
        }
        let window = windowRef as! AXUIElement
        guard let screen = NSScreen.main else { return "I couldn't read the screen size." }
        let vf = screen.visibleFrame                 // Cocoa coords, bottom-left origin
        let halfW = vf.width / 2, halfH = vf.height / 2
        let key = place.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let target: CGRect
        switch key {
        case "left", "lefthalf":          target = CGRect(x: vf.minX, y: vf.minY, width: halfW, height: vf.height)
        case "right", "righthalf":        target = CGRect(x: vf.minX + halfW, y: vf.minY, width: halfW, height: vf.height)
        case "top", "tophalf":            target = CGRect(x: vf.minX, y: vf.minY + halfH, width: vf.width, height: halfH)
        case "bottom", "bottomhalf":      target = CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: halfH)
        case "topleft":                   target = CGRect(x: vf.minX, y: vf.minY + halfH, width: halfW, height: halfH)
        case "topright":                  target = CGRect(x: vf.minX + halfW, y: vf.minY + halfH, width: halfW, height: halfH)
        case "bottomleft":                target = CGRect(x: vf.minX, y: vf.minY, width: halfW, height: halfH)
        case "bottomright":               target = CGRect(x: vf.minX + halfW, y: vf.minY, width: halfW, height: halfH)
        case "full", "fullscreen", "maximize", "max": target = vf
        case "center", "centre", "middle":
            target = CGRect(x: vf.midX - vf.width * 0.35, y: vf.midY - vf.height * 0.35,
                            width: vf.width * 0.7, height: vf.height * 0.7)
        default:
            return "I can do left, right, top, bottom, the four corners, full or center."
        }
        // Convert Cocoa (bottom-left origin) to Accessibility (top-left origin of the primary display).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        var axPosition = CGPoint(x: target.minX, y: primaryHeight - target.maxY)
        var axSize = CGSize(width: target.width, height: target.height)
        if let value = AXValueCreate(.cgPoint, &axPosition) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &axSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        return "Moved the window \(place)."
    }

    // MARK: Reminders & Calendar (EventKit)

    static func addReminder(_ text: String, due: String?) async -> String {
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToReminders() else {
                return "Reminders access is off for Plummy (System Settings, Privacy & Security, Reminders)."
            }
        } catch {
            return "I couldn't get Reminders access: \(error.localizedDescription)"
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due, let date = parseDate(due) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        do {
            try store.save(reminder, commit: true)
            return "Reminder added: \(text)."
        } catch {
            return "I couldn't save the reminder: \(error.localizedDescription)"
        }
    }

    static func addCalendarEvent(_ title: String, start: String, end: String?) async -> String {
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToEvents() else {
                return "Calendar access is off for Plummy (System Settings, Privacy & Security, Calendars)."
            }
        } catch {
            return "I couldn't get Calendar access: \(error.localizedDescription)"
        }
        guard let startDate = parseDate(start) else {
            return "I need a start time I can read, like 2026-10-07 15:00."
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = end.flatMap(parseDate) ?? startDate.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return "Event added: \(title)."
        } catch {
            return "I couldn't save the event: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
