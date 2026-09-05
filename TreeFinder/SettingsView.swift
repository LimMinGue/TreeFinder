import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsKeys {
    static let isoDates = "DateFormatISO"
    static let terminalApp = "TerminalAppPath"
    static let terminalFontName = "TerminalFontName"
    static let terminalFontSize = "TerminalFontSize"
    static let terminalTheme = "TerminalTheme"
    static let alwaysExtensions = "AlwaysShowExtensions"
    static let showHidden = "ShowHiddenFiles"
    static let iconSize = "IconGridSize"   // 아이콘 뷰 아이콘 한 변(pt) — 슬라이더 (제작자 지시 2026-07-25)
    static let hiddenColumns = "HiddenListColumns"   // 파일 목록 숨긴 컬럼 키 목록 — 헤더 우클릭 (제작자 지시 2026-07-25)
    static let expandToOpenFolder = "ExpandToOpenFolder"
    // 마지막 세션(탭 경로들·활성 탭) — 재실행 시 복원 (제작자 지시 2026-07-17)
    static let lastTabs = "LastSessionTabs"
    static let lastActiveTab = "LastSessionActiveTab"
    static let defaultTerminal = "/System/Applications/Utilities/Terminal.app"
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("TFSettingsChanged")
}

/// 설정 화면 — SwiftUI Form (decisions §11 제작자 승인 예외, 그 외 화면은 AppKit 유지)
struct SettingsView: View {
    @AppStorage(PathPasteboard.toggleKey) private var nfcFix = true
    @AppStorage(SettingsKeys.isoDates) private var isoDates = false
    @AppStorage(SettingsKeys.alwaysExtensions) private var alwaysExtensions = true
    @AppStorage(SettingsKeys.terminalApp) private var terminalApp = SettingsKeys.defaultTerminal
    @AppStorage(SettingsKeys.terminalFontName) private var terminalFontName = "Menlo"
    @AppStorage(SettingsKeys.terminalFontSize) private var terminalFontSize = 12.0
    @AppStorage(SettingsKeys.terminalTheme) private var terminalTheme = TerminalTheme.all[0].id

    /// 고정폭 폰트 패밀리 (파워라인/Nerd Font 포함 — 설치된 것만)
    private let monoFamilies: [String] = {
        var families = NSFontManager.shared.availableFontFamilies.filter {
            NSFont(name: $0, size: 12)?.isFixedPitch ?? false
        }
        let current = UserDefaults.standard.string(forKey: SettingsKeys.terminalFontName) ?? "Menlo"
        if !families.contains(current) { families.insert(current, at: 0) }
        return families
    }()

    /// 터미널 후보 = 알려진 앱 중 설치된 것 + 저장된 사용자 지정 앱("Other…"로 고른 것). 저장값이 후보에 없으면
    /// SwiftUI Picker가 빈 선택으로 어긋나던 것 교정 + 원본 명세(DESIGN_REFERENCE §11)의 Other… 복원 (2026-09-05 A18)
    @State private var terminalCandidates: [(name: String, path: String)] =
        SettingsView.knownTerminals(including: UserDefaults.standard.string(forKey: SettingsKeys.terminalApp))

    private static func knownTerminals(including saved: String?) -> [(name: String, path: String)] {
        var paths = [SettingsKeys.defaultTerminal, "/Applications/iTerm.app", "/Applications/Warp.app",
                     "/Applications/Ghostty.app", "/Applications/WezTerm.app",
                     "/Applications/Tabby.app", "/Applications/Hyper.app"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        if let saved, FileManager.default.fileExists(atPath: saved), !paths.contains(saved) { paths.append(saved) }
        return paths.map { (FileManager.default.displayName(atPath: $0), $0) }
    }

    /// Other… — 임의 앱 선택(NSOpenPanel). 목록에 추가하고 즉시 선택.
    private func chooseOtherTerminal() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if !terminalCandidates.contains(where: { $0.path == url.path }) {
                terminalCandidates.append((FileManager.default.displayName(atPath: url.path), url.path))
            }
            terminalApp = url.path
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Date Format", selection: $isoDates) {
                    Text("System Locale").tag(false)
                    Text("ISO Date and Time (2026-06-09 17:07:45)").tag(true)
                }
                Toggle("Always show file extensions", isOn: $alwaysExtensions)
            } header: { Text("General") } footer: {
                Text("Show extensions even for files macOS would normally hide them for, the way Windows Explorer does.")
            }

            Section {
                Toggle("Fix Korean text in clipboard (NFD → NFC)", isOn: $nfcFix)
            } header: { Text("Clipboard") } footer: {
                Text("Paths copied from TreeFinder are normalized so Korean characters don't break apart when pasted into other apps. Nothing leaves this Mac.")
            }

            Section {
                HStack {
                    Picker("Open in Terminal with", selection: $terminalApp) {
                        ForEach(terminalCandidates, id: \.path) { candidate in
                            Text(candidate.name).tag(candidate.path)
                        }
                    }
                    Button("Other…") { chooseOtherTerminal() }
                }
                Picker("Terminal font", selection: $terminalFontName) {
                    ForEach(monoFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Font size: \(Int(terminalFontSize)) pt", value: $terminalFontSize, in: 9...24)
                Picker("Terminal theme", selection: $terminalTheme) {
                    ForEach(TerminalTheme.all, id: \.id) { Text(LocalizedStringKey($0.name)).tag($0.id) }
                }
            } header: { Text("Terminal") } footer: {
                Text("Used by the \"Open in Terminal\" command. The embedded Terminal tab always runs your login shell. Pick a Nerd Font if your prompt uses powerline glyphs. The theme applies to the embedded Terminal tab only.")
            }

            Section {
                Text("TreeFinder collects no data and sends nothing off this Mac. Network credentials are handled by the macOS Keychain and are never stored by the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: { Text("Privacy") }

            Section {
                LabeledContent("Version",
                               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            } header: { Text("Updates") } footer: {
                Text("Automatic update checks will be available in a future release.")
            }
        }
        .formStyle(.grouped)
        // 높이 미지정 시 호스팅 창이 480×32로 붕괴(fitting-size 함정 실측 2026-07-16) — 고정 크기 필수
        .frame(width: 480, height: 540)
        // 저장된 터미널 앱이 삭제됐으면 기본 Terminal로 되돌린다 — ExternalOpen의 폴백과 화면 표시를 일치(A18)
        .onAppear { if !FileManager.default.fileExists(atPath: terminalApp) { terminalApp = SettingsKeys.defaultTerminal } }
        .onChange(of: isoDates) { NotificationCenter.default.post(name: .settingsChanged, object: nil) }
        .onChange(of: alwaysExtensions) { NotificationCenter.default.post(name: .settingsChanged, object: nil) }
        .onChange(of: terminalFontName) { NotificationCenter.default.post(name: .settingsChanged, object: nil) }
        .onChange(of: terminalFontSize) { NotificationCenter.default.post(name: .settingsChanged, object: nil) }
        .onChange(of: terminalTheme) { NotificationCenter.default.post(name: .settingsChanged, object: nil) }
    }
}
