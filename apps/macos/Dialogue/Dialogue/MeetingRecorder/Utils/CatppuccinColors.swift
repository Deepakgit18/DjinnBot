import DialogueCore
import SwiftUI

/// Catppuccin Mocha palette colors for speaker differentiation.
/// Each color is used as a subtle row background tint for transcript entries.
///
/// Enrolled speakers get a fixed color chosen during enrollment.
/// Other speakers get a hash-based color from the remaining palette slots.
enum CatppuccinSpeaker {

    // MARK: - Mocha Accent Colors

    static let rosewater = Color(red: 245/255, green: 224/255, blue: 220/255)
    static let flamingo  = Color(red: 242/255, green: 205/255, blue: 205/255)
    static let pink      = Color(red: 245/255, green: 194/255, blue: 231/255)
    static let mauve     = Color(red: 203/255, green: 166/255, blue: 247/255)
    static let red       = Color(red: 243/255, green: 139/255, blue: 168/255)
    static let maroon    = Color(red: 235/255, green: 160/255, blue: 172/255)
    static let peach     = Color(red: 250/255, green: 179/255, blue: 135/255)
    static let yellow    = Color(red: 249/255, green: 226/255, blue: 175/255)
    static let green     = Color(red: 166/255, green: 227/255, blue: 161/255)
    static let teal      = Color(red: 148/255, green: 226/255, blue: 213/255)
    static let sky       = Color(red: 137/255, green: 220/255, blue: 235/255)
    static let sapphire  = Color(red: 116/255, green: 199/255, blue: 236/255)
    static let blue      = Color(red: 137/255, green: 180/255, blue: 250/255)
    static let lavender  = Color(red: 180/255, green: 190/255, blue: 254/255)

    // MARK: - Speaker Text Colors (darker variants for label text)

    static let subtext0  = Color(red: 166/255, green: 173/255, blue: 200/255)
    static let overlay0  = Color(red: 108/255, green: 112/255, blue: 134/255)

    /// Ordered palette for assigning colors to speakers.
    /// Chosen for maximum visual distinction between adjacent entries.
    static let palette: [Color] = [
        mauve, peach, teal, pink, sapphire, yellow,
        green, flamingo, blue, maroon, sky, lavender,
        rosewater, red,
    ]

    /// Human-readable names for each palette color (same order as `palette`).
    static let paletteNames: [String] = [
        "Mauve", "Peach", "Teal", "Pink", "Sapphire", "Yellow",
        "Green", "Flamingo", "Blue", "Maroon", "Sky", "Lavender",
        "Rosewater", "Red",
    ]

    /// Returns a consistent Catppuccin color for a speaker label.
    ///
    /// 1. If the speaker label matches an enrolled voice with an assigned color,
    ///    that color is returned directly.
    /// 2. Otherwise, a hash-based color is chosen from palette slots that are
    ///    NOT reserved by enrolled voices.
    static func color(for speaker: String) -> Color {
        // Check if this speaker is an enrolled voice with an assigned color.
        if let index = enrolledColorIndex(for: speaker) {
            return palette[index % palette.count]
        }

        // Hash into the unreserved palette.
        let unreserved = unreservedPalette()
        if unreserved.isEmpty { return palette[abs(speaker.hashValue) % palette.count] }
        let hash = abs(speaker.hashValue)
        return unreserved[hash % unreserved.count]
    }

    /// Row background opacity for light/dark appearance.
    /// Subtle enough to read text over, strong enough to differentiate speakers.
    static let rowBackgroundOpacity: Double = 0.12

    /// Speaker label text color — uses the full-strength accent.
    static func labelColor(for speaker: String) -> Color {
        color(for: speaker)
    }

    // MARK: - Enrolled Color Helpers

    /// Returns the palette index for an enrolled voice matching this speaker label,
    /// or nil if no enrolled voice matches.
    private static func enrolledColorIndex(for speaker: String) -> Int? {
        let voices = VoiceID.shared.allEnrolledVoices()
        // Speaker labels may be just the userID (after VoiceID rename)
        // or prefixed like "Local-sky", "Remote-sky".
        for voice in voices {
            guard let idx = voice.colorIndex else { continue }
            if speaker == voice.userID
                || speaker.hasSuffix("-\(voice.userID)") {
                return idx
            }
        }
        return nil
    }

    /// Palette colors NOT reserved by any enrolled voice.
    private static func unreservedPalette() -> [Color] {
        let reserved = Set(
            VoiceID.shared.allEnrolledVoices().compactMap(\.colorIndex)
        )
        return palette.enumerated()
            .filter { !reserved.contains($0.offset) }
            .map(\.element)
    }
}
