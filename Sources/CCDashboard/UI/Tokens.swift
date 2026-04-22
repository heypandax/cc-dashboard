import AppKit
import SwiftUI

// Design tokens — continuous with the app icon palette.
// Source of truth: design/mainwindow-export/asset-93e50a07.js

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:     Double((hex >> 16) & 0xFF) / 255,
            green:   Double((hex >>  8) & 0xFF) / 255,
            blue:    Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Light / dark adaptive color backed by an NSColor dynamic provider.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        }))
    }
}

enum CC {
    // Brand
    static let indigoTop  = Color(hex: 0x2E4A6B)
    static let indigoBot  = Color(hex: 0x1B2E4A)
    static let indigoDeep = Color(hex: 0x0F1A2E)

    // Accents —— 基色在 card fill / badge capsule 里直接用,
    // *Ink 作为 label 颜色用 light/dark 自适应,避免深底闷糊。
    static let mint     = Color(hex: 0x4ADE80)   // allow / trust
    static let mintDeep = Color(hex: 0x22A14E)   // bottom of allow gradient
    static let inkOnMint = Color(hex: 0x06381B)  // dark text on mint gradient button (gradient 自身就是亮绿,不随主题变)
    static let amber    = Color(hex: 0xE3A53B)   // stale / moderate risk
    static let red      = Color(hex: 0xE0564F)   // deny / destructive

    static let mintInk  = Color(light: Color(hex: 0x0E6B32), dark: Color(hex: 0x6EE59A))
    static let amberInk = Color(light: Color(hex: 0x7A4E0C), dark: Color(hex: 0xE3A53B))
    static let redInk   = Color(light: Color(hex: 0x8E1C17), dark: Color(hex: 0xFF8A84))

    // App icon motif
    static let cardFace = Color(hex: 0xE8F0FC)   // white card body in the icon motif

    enum Status {
        static let running = Color(hex: 0x2A6FD6)
        static let waiting = Color(hex: 0xD79318)
        static let idle    = Color(hex: 0x8A8E99)
        static let done    = Color(hex: 0x2E8957)
        static let error   = Color(hex: 0xC4443D)
    }

    static let mono     = Font.system(.caption, design: .monospaced)
    static let monoTiny = Font.system(.caption2, design: .monospaced)
}
