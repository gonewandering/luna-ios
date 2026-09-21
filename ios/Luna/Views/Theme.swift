import SwiftUI

enum Palette {
    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
    // One dark palette for every surface, independent of the device appearance.
    static let canvas = color(0x101613)
    static let card = color(0x1B2520)
    static let code = color(0x141D18)
    static let codeKeyword = color(0xD9B3FF)
    static let codeString = color(0xACD995)
    static let codeNumber = color(0xF2C38B)
    static let codeType = color(0x83D8D0)
    static let codeFunction = color(0x9ACBFF)
    static let codeDeleted = color(0xFFA7AD)
    static let ink = color(0xF0F3EF)
    static let muted = color(0xA0B0A5)
    static let sectionLabel = color(0x708879)
    static let forest = color(0xA2CEB0)
    static let button = forest
    static let onAccent = color(0x12221A)
    static let line = color(0x34483B)
    static let userBubble = color(0x263B2F)
    static let orange = color(0xE4AD86)
    static let markBackground = color(0x284A38)
    static let moon = color(0xF2E8C8)
}

struct LunaMark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(Palette.markBackground)
            Circle().fill(Palette.moon).frame(width: size * 0.54, height: size * 0.54).offset(x: -size * 0.06)
            Circle().fill(Palette.markBackground).frame(width: size * 0.44, height: size * 0.44).offset(x: size * 0.07, y: -size * 0.075)
            Circle().fill(Palette.orange).frame(width: size * 0.075, height: size * 0.075).offset(x: size * 0.25, y: -size * 0.24)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 16)
            .foregroundStyle(Palette.onAccent).background(Palette.button.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 17))
    }
}
