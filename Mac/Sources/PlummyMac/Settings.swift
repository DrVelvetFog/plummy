import Foundation
import PlummyShared

/// User choices from the menu bar, kept between launches.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var onChange: (() -> Void)?

    /// Cursor size in points (the design's default is 72).
    var cursorSize: Double {
        get { defaults.object(forKey: "cursorSize") as? Double ?? 72 }
        set { defaults.set(newValue, forKey: "cursorSize"); onChange?() }
    }

    var glow: Bool {
        get { defaults.object(forKey: "glow") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "glow"); onChange?() }
    }

    var showCursor: Bool {
        get { defaults.object(forKey: "showCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCursor"); onChange?() }
    }

    /// Where the phone sits under the screen, 0 = left edge, 1 = right edge.
    var phonePosition: Double {
        get { defaults.object(forKey: "phonePosition") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "phonePosition"); onChange?() }
    }

    /// When idle, hide the big cursor and let the phone's eyes follow your own mouse.
    var followMouse: Bool {
        get { defaults.object(forKey: "followMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followMouse"); onChange?() }
    }

    var captions: Bool {
        get { defaults.object(forKey: "captions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captions"); onChange?() }
    }

    /// Lets her click, type, press keys and open things when you ask. On by default; turn it off with
    /// "Let Her Use the Computer" in the menu. The dangerous paths stay blocked in code regardless
    /// (terminals, password fields, logout/lock/force-quit), and ⌃⌥S stops her.
    var computerControl: Bool {
        get { defaults.object(forKey: "computerControl") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "computerControl"); onChange?() }
    }

    /// Make her pause for a ⌃⌥Y confirm before clicking a risky, irreversible-looking button
    /// (Send, Delete, Buy, Submit…). On by default.
    var confirmRisky: Bool {
        get { defaults.object(forKey: "confirmRisky") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "confirmRisky"); onChange?() }
    }

    /// Show a small "what she's doing right now" card with a Stop button while she acts. On by default.
    var activityPanel: Bool {
        get { defaults.object(forKey: "activityPanel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "activityPanel"); onChange?() }
    }

    /// Keep an evidence-tiered record of what she does and reads, in ~/Documents/Plummy Journal.
    /// On by default; local only. Turn it off for no disk writes at all.
    var journalActions: Bool {
        get { defaults.object(forKey: "journalActions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "journalActions"); onChange?() }
    }

    /// Think with Claude (cloud) when an Anthropic key is set. Off by default: the local Ollama brain
    /// is used unless you turn this on, so screenshots never leave the Mac without an explicit choice.
    var useClaudeBrain: Bool {
        get { defaults.object(forKey: "useClaudeBrain") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "useClaudeBrain") }
    }

    /// How the cursor's path shows while it flies.
    var trail: PointerTrail {
        get { PointerTrail(rawValue: defaults.string(forKey: "trail") ?? "") ?? .comet }
        set { defaults.set(newValue.rawValue, forKey: "trail"); onChange?() }
    }

    /// The mood picked by hand in the menu.
    var mood: Mood {
        get { Mood(rawValue: defaults.string(forKey: "mood") ?? "") ?? .listening }
        set { defaults.set(newValue.rawValue, forKey: "mood"); onChange?() }
    }
}
