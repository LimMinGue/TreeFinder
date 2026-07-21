import AppKit
import SwiftTerm

/// 내장 터미널 색 테마 — 설정에서 선택 (제작자 지시 2026-07-21).
/// 색은 16진 리터럴로만 보관하고 NSColor/SwiftTerm.Color 변환은 적용 시점에 — 팔레트가 데이터로만 남게.
struct TerminalTheme {
    let id: String        // UserDefaults 저장 값 (표시 이름과 분리 — 번역이 바뀌어도 선택이 유지)
    let name: String      // 설정 Picker 표시 이름 (xcstrings 키)
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    /// 16개: 표준 8색(검·빨·초·노·파·자·청·흰) + 밝은 8색
    let ansi: [UInt32]

    /// 기본값은 현재 렌더와 동일한 검정 배경 — 업데이트로 기존 사용자의 터미널 모양이 바뀌지 않게
    static let all: [TerminalTheme] = [
        TerminalTheme(id: "default", name: "Default",
                      background: 0x000000, foreground: 0xD5D5D5, cursor: 0xFFFFFF,
                      ansi: [0x000000, 0x990001, 0x00A603, 0x999900,
                             0x0300B2, 0xB200B2, 0x00A5B2, 0xBFBFBF,
                             0x8A898A, 0xE50001, 0x00D800, 0xE5E500,
                             0x0700FE, 0xE500E5, 0x00E5E5, 0xE5E5E5]),
        TerminalTheme(id: "solarizedDark", name: "Solarized Dark",
                      background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1,
                      ansi: solarized),
        TerminalTheme(id: "solarizedLight", name: "Solarized Light",
                      background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75,
                      ansi: solarized),
        TerminalTheme(id: "dracula", name: "Dracula",
                      background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2,
                      ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
                             0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                             0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
                             0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]),
        TerminalTheme(id: "nord", name: "Nord",
                      background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xD8DEE9,
                      ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                             0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                             0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                             0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]),
    ]

    /// Solarized는 다크/라이트가 같은 팔레트를 공유 — 전경/배경만 다름 (Ethan Schoonover 원안)
    private static let solarized: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900,
        0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
        0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]

    static var current: TerminalTheme {
        let id = UserDefaults.standard.string(forKey: SettingsKeys.terminalTheme)
        return all.first { $0.id == id } ?? all[0]
    }

    var backgroundColor: NSColor { Self.nsColor(background) }

    /// 팔레트 + 전경/배경/커서를 한 번에 — 세션 생성 시와 설정 변경 시 공용 경로
    func apply(to terminal: TerminalView) {
        terminal.nativeBackgroundColor = Self.nsColor(background)
        terminal.nativeForegroundColor = Self.nsColor(foreground)
        terminal.caretColor = Self.nsColor(cursor)
        terminal.installColors(ansi.map(Self.terminalColor))
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// SwiftTerm.Color는 채널당 0...65535 — 8비트 값은 257배(0xFF → 0xFFFF)
    private static func terminalColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257,
                        green: UInt16((hex >> 8) & 0xFF) * 257,
                        blue: UInt16(hex & 0xFF) * 257)
    }
}
