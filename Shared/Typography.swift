import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import CoreText
#endif

public extension Font {
    /// Rounded display face from the design. Falls back to SF Rounded until Fredoka is bundled.
    static func fredoka(_ size: CGFloat) -> Font {
        InstalledFonts.has("Fredoka") ? .custom("Fredoka", size: size).weight(.bold) : .system(size: size, weight: .bold, design: .rounded)
    }

    static func plexSans(_ size: CGFloat) -> Font {
        InstalledFonts.has("IBM Plex Sans") ? .custom("IBM Plex Sans", size: size) : .system(size: size)
    }

    static func plexMono(_ size: CGFloat) -> Font {
        InstalledFonts.has("IBM Plex Mono") ? .custom("IBM Plex Mono", size: size) : .system(size: size, design: .monospaced)
    }
}

/// Which font families this device actually has, so the design degrades instead of disappearing.
/// Read once, lazily — on the Mac that's after `Fonts.registerBundled()` has run at launch.
enum InstalledFonts {
    private static let families: Set<String> = {
        #if canImport(UIKit)
        return Set(UIFont.familyNames)
        #else
        return Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
        #endif
    }()

    static func has(_ family: String) -> Bool { families.contains(family) }
}
