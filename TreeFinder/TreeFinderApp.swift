import AppKit
import SwiftUI

@main
enum TreeFinderApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// Window 메뉴 열릴 때 — 키 창의 탭 목록(⌘1…)을 동적 삽입 (원본 Window 메뉴 규약)
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === NSApp.windowsMenu else { return }
        while menu.items.count > windowMenuStaticCount,
              menu.items[windowMenuStaticCount].tag == 777 {
            menu.removeItem(at: windowMenuStaticCount)
        }
        guard let controller = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        for (index, title) in controller.tabTitles.enumerated().reversed() {
            let item = NSMenuItem(title: title,
                                  action: #selector(MainWindowController.selectTabFromMenu(_:)),
                                  keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.tag = 777
            item.state = index == controller.activeTabIndex ? .on : .off
            item.representedObject = index
            item.target = nil
            menu.insertItem(item, at: windowMenuStaticCount)
        }
    }
    private var windowController: MainWindowController?
    private var settingsWindow: NSWindow?

    @objc private func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = L("Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DirectoryLister.selfTest()
        SizeService.selfTest()
        DropTerminalView.selfTest()
        #endif
        buildMainMenu()
        var startDirectory = FileManager.default.homeDirectoryForCurrentUser
        #if DEBUG
        // TF_START_DIR=<경로> → 시작 폴더 지정(검증용 — 홈 대형 폴더 크기 스캔이 SizeService 워커를 선점하는 것 회피)
        if let startPath = ProcessInfo.processInfo.environment["TF_START_DIR"] {
            startDirectory = URL(fileURLWithPath: startPath)
        }
        #endif
        let wc = MainWindowController(directory: startDirectory)
        // 마지막 세션(탭·폴더·분할 폭) 복원 — TF_ 검증 실행은 제외(디버그가 사용자 세션 오염 금지)
        if !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("TF_") }) {
            wc.restoreLastSession()
        }
        wc.showWindow(nil)
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        // /smoke 검증용 — 창 기하가 붕괴되면 여기서 바로 드러난다 (bootstrap.md §2)
        NSLog("TreeFinder window frame: %@", NSStringFromRect(wc.window?.frame ?? .zero))
        // 자기 창 스냅숏 — 스크린 권한 없이 실제 레이아웃을 검증하는 유일한 경로 (commands.md /smoke)
        // 1순위: 실픽셀 캡처(툴바·비브런시 포함, 자기 창은 권한 불요) / 폴백: cacheDisplay(비브런시 왜곡 있음)
        // TF_COLLAPSE_SIDEBAR=1 로 실행하면 접힌 상태를 스냅숏으로 검증할 수 있다
        // (응답 체인은 비활성 창에서 못 타므로 split item을 직접 접는다)
        if ProcessInfo.processInfo.environment["TF_COLLAPSE_SIDEBAR"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                wc.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }
                    .first?.splitViewItems.first?.isCollapsed = true
            }
        }
        // TF_EXTRA_TAB=1 → 탭 2개 상태를 스냅숏으로 검증
        if ProcessInfo.processInfo.environment["TF_EXTRA_TAB"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                wc.newWindowForTab(nil)
            }
        }
        // TF_DUAL_PANE=1 → 듀얼 페인 상태를 스냅숏으로 검증 / =2 → 켰다 끈 복원 상태 검증
        if let dualMode = ProcessInfo.processInfo.environment["TF_DUAL_PANE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                wc.toggleDualPane(nil)
            }
            if dualMode == "2" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    wc.toggleDualPane(nil)
                }
            }
        }
        // TF_VIEW_STYLE=icons|gallery → 뷰 스타일을 전환해 스냅숏으로 검증
        if let styleRaw = ProcessInfo.processInfo.environment["TF_VIEW_STYLE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                wc.debugSetViewStyle(styleRaw)
            }
        }
        // TF_FIT_COLUMNS=1 → 컬럼 적정 폭(구분선 더블클릭 경로)을 적용해 스냅숏으로 검증
        if ProcessInfo.processInfo.environment["TF_FIT_COLUMNS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                wc.debugFitColumns()
            }
        }
        // TF_NETWORK_VIEW=1 → 네트워크 브라우즈 목록을 스냅숏으로 검증 (발견 대기 후 +4s 별도 캡처)
        if ProcessInfo.processInfo.environment["TF_NETWORK_VIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                wc.debugShowNetwork()
            }
            // 로컬 네트워크 권한 승인이 끼어들 수 있어 2회 캡처(+4s·+20s 덮어쓰기)
            for delay in [4.0, 20.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-network.png")
                    NSLog("NETWORK hosts: %@", NetworkBrowser.shared.hosts.joined(separator: ", "))
                }
            }
        }
        // TF_TERMINAL_DROP=<경로> → 터미널 파일 드롭(경로 입력) E2E 검증 (+4s 별도 캡처)
        if let dropPath = ProcessInfo.processInfo.environment["TF_TERMINAL_DROP"] {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { preview()?.debugTerminalDrop(dropPath) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-terminal.png")
            }
        }
        // TF_TERMINAL_KEYSIM=<명령> → 합성 키 입력으로 감지 경로까지 E2E 검증
        if let simCommand = ProcessInfo.processInfo.environment["TF_TERMINAL_KEYSIM"] {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { preview()?.debugTerminalKeySim(simCommand) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-keysim.png")
            }
        }
        // TF_TERMINAL_SYNC=1 → vi 실행 중 "현재 폴더로 이동" = 새 탭 생성·cd 검증
        if ProcessInfo.processInfo.environment["TF_TERMINAL_SYNC"] == "1" {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { preview()?.debugTerminalKeySim("vi") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { preview()?.debugTerminalSync() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-termsync.png")
            }
        }
        // TF_TERMINAL_HELP=<명령> → 명령 도움말 밴드를 스냅숏으로 검증
        if let helpCommand = ProcessInfo.processInfo.environment["TF_TERMINAL_HELP"] {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { preview()?.debugTerminalHelp(helpCommand) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-termhelp.png")
            }
        }
        // TF_PREVIEW_FILE=<경로> → 해당 파일을 미리보기에 띄워 정보 테이블(EXIF 포함)을 스냅숏으로 검증
        if let previewPath = ProcessInfo.processInfo.environment["TF_PREVIEW_FILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                (wc.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController)?
                    .show(URL(fileURLWithPath: previewPath))
            }
        }
        // TF_OPEN_ABOUT=1 → About 패널(연락처 크레딧)을 열고 스냅숏으로 검증
        if ProcessInfo.processInfo.environment["TF_OPEN_ABOUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.showAboutPanel(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                guard let window = NSApp.keyWindow else { return }
                let out = URL(fileURLWithPath: "/tmp/treefinder-about.png")
                if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                    CGWindowID(window.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution]),
                   cg.width > 1 {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out)
                }
            }
        }
        // TF_MD_SAVE_TEST=1 → (TF_PREVIEW_FILE과 병용) 마크다운 편집 주입 → 저장 경로 검증
        if ProcessInfo.processInfo.environment["TF_MD_SAVE_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                (wc.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController)?
                    .debugMarkdownSaveTest()
            }
        }
        // TF_ZOOM_TEST=1 → (TF_PREVIEW_FILE과 병용) 확대 2단 상태를 스냅숏으로 검증
        if ProcessInfo.processInfo.environment["TF_ZOOM_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let preview = wc.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
                preview?.debugZoomIn()
                preview?.debugZoomIn()
            }
        }
        // TF_TERMINAL_TAB=1 → 터미널 탭 상태를 스냅숏으로 검증
        if ProcessInfo.processInfo.environment["TF_TERMINAL_TAB"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                (wc.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController)?.debugShowTerminal()
            }
        }
        // TF_TERMINAL_RESIZE=1 → 터미널 2탭 생성 후 창 리사이즈 시 도움말 밴드가 화면을 덮지 않는지 검증(제작자 제보 2026-07-18)
        if ProcessInfo.processInfo.environment["TF_TERMINAL_RESIZE"] == "1" {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { preview()?.debugAddTerminalTab() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {   // 리사이즈로 분할 재레이아웃 유발
                guard let window = wc.window else { return }
                var frame = window.frame
                frame.size.height += 220; frame.origin.y -= 220
                window.setFrame(frame, display: true, animate: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-termresize.png")
            }
        }
        // TF_SELECT_TO_PREVIEW=1 → (TF_TERMINAL_TAB과 병용) 터미널 탭에 있어도 파일 선택 시 미리보기로
        // 자동 전환되는지 검증 (+3.5s 스냅숏). debugSetViewStyle이 0.4s 뒤 첫 항목을 선택한다.
        if ProcessInfo.processInfo.environment["TF_SELECT_TO_PREVIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { wc.debugSetViewStyle("list") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-selectpreview.png")
            }
        }
        // TF_RUN_SCRIPT=<경로> → .sh 더블클릭 경로(목록 → 새 터미널 탭 실행) E2E 검증 (+4s 스냅숏)
        if let scriptPath = ProcessInfo.processInfo.environment["TF_RUN_SCRIPT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { wc.debugRunScript(scriptPath) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-runscript.png")
            }
        }
        // TF_TERMINAL_BROADCAST=<명령> → 탭 2개 + 브로드캐스트로 같은 입력이 양쪽에 나가는지 검증 (+5s 스냅숏)
        // TF_TERMINAL_HELP_OFF=1 과 병용하면 도움말 밴드 끈 상태도 같은 스냅숏에 담긴다
        if let simCommand = ProcessInfo.processInfo.environment["TF_TERMINAL_BROADCAST"] {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { preview()?.debugBroadcastKeySim(simCommand) }
            if ProcessInfo.processInfo.environment["TF_TERMINAL_HELP_OFF"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { preview()?.debugToggleTerminalHelp() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-broadcast.png")
            }
        }
        // TF_ARCHIVE_SORT=<키> → (TF_PREVIEW_FILE과 병용) 압축 표를 해당 컬럼으로 정렬(헤더 클릭 검증)
        if let sortKey = ProcessInfo.processInfo.environment["TF_ARCHIVE_SORT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                (wc.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController)?
                    .debugSortArchive(sortKey)
            }
        }
        // TF_OPEN_GETINFO=<경로> → 정보 가져오기 창을 열고 별도 스냅숏으로 검증
        if let infoPath = ProcessInfo.processInfo.environment["TF_OPEN_GETINFO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                GetInfoWindowController.show(for: URL(fileURLWithPath: infoPath))
                // 보조 디스플레이 캡처가 백지로 나오는 환경 실측 — 스냅숏 검증은 주 화면으로 고정
                if let window = GetInfoWindowController.open.last?.window,
                   let screen = NSScreen.screens.first {
                    let visible = screen.visibleFrame
                    window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                                  y: visible.midY - window.frame.height / 2))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let window = GetInfoWindowController.open.last?.window else { return }
                let out = URL(fileURLWithPath: "/tmp/treefinder-getinfo.png")
                // 창 서버 캡처가 이 보조 창에서 백지로 나오는 환경 실측 — 뷰 직접 렌더로 전환
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        view.cacheDisplay(in: view.bounds, to: rep)
                    }
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                }
                NSLog("GetInfo window frame: %@", NSStringFromRect(window.frame))
            }
        }
        // TF_OPEN_SETTINGS=1 → Settings 창을 열고 별도 스냅숏으로 검증
        if ProcessInfo.processInfo.environment["TF_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.openSettings(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let window = self?.settingsWindow else { return }
                let out = URL(fileURLWithPath: "/tmp/treefinder-settings.png")
                if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                    CGWindowID(window.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution]),
                   cg.width > 1 {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out)
                }
                NSLog("Settings window frame: %@", NSStringFromRect(window.frame))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = wc.window else { return }
            let out = URL(fileURLWithPath: "/tmp/treefinder-window.png")
            if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                CGWindowID(window.windowNumber),
                                                [.boundsIgnoreFraming, .bestResolution]),
               cg.width > 1 {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out)
            }
            // 창 서버 캡처가 백지를 반환하는 환경 실측(2026-07-16) — 뷰 직접 렌더 병행 저장
            Self.debugCaptureContent(of: window, to: "/tmp/treefinder-window-view.png")
        }
        #endif
    }

    #if DEBUG
    /// 뷰 직접 렌더 스냅숏 — 창 서버 캡처가 백지인 환경 대응. 비브런시가 투명으로
    /// 렌더되어 다크 글자가 흰 PNG 바탕에 묻히므로 창 배경색 위에 합성한다(실측 2026-07-16).
    private static func debugCaptureContent(of window: NSWindow?, to path: String) {
        guard let window, let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let size = view.bounds.size
        let composite = NSImage(size: size)
        composite.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: size))
        composite.unlockFocus()
        if let tiff = composite.tiffRepresentation, let outRep = NSBitmapImageRep(data: tiff) {
            try? outRep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        let about = NSMenuItem(title: L("About TreeFinder"),
                               action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Check for Updates…"), action: nil, keyEquivalent: "")   // Sparkle 도입 시 활성
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit TreeFinder"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, titled: "TreeFinder", to: main)

        let fileMenu = NSMenu(title: L("File"))
        let newTab = NSMenuItem(title: L("New Tab"),
                                action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(newTab)
        fileMenu.addItem(withTitle: L("New Text Document"),
                         action: #selector(MainWindowController.newTextDocument(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: L("Open"),
                         action: #selector(MainWindowController.openSelected(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("Get Info"),   // 선택 없으면 현재 폴더 (decisions §17)
                         action: #selector(MainWindowController.getInfoSelected(_:)), keyEquivalent: "i")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("Restore"),   // 휴지통 put-back — TreeFinder 삭제분만 (decisions §14)
                         action: #selector(MainWindowController.restoreSelected(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("Close Tab"),
                         action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
        addSubmenu(fileMenu, titled: L("File"), to: main)

        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Find"),
                         action: #selector(MainWindowController.focusSearch(_:)), keyEquivalent: "f")
        editMenu.addItem(.separator())
        // ⌘R — F2는 macOS 밝기 키 (원본 1.1.9 규약)
        editMenu.addItem(withTitle: L("Rename"),
                         action: #selector(MainWindowController.renameSelected(_:)), keyEquivalent: "r")
        let copyPath = NSMenuItem(title: L("Copy Path"),
                                  action: #selector(MainWindowController.copyPath(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(copyPath)
        addSubmenu(editMenu, titled: L("Edit"), to: main)

        let viewMenu = NSMenu(title: L("View"))
        let hidden = NSMenuItem(title: L("Show Hidden Files"),
                                action: #selector(MainWindowController.toggleShowHidden(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(hidden)
        let previewPane = NSMenuItem(title: L("Show Preview Pane"),
                                     action: #selector(MainWindowController.togglePreview(_:)), keyEquivalent: "p")
        previewPane.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(previewPane)
        let dualPane = NSMenuItem(title: L("Dual Pane"),
                                  action: #selector(MainWindowController.toggleDualPane(_:)), keyEquivalent: "d")
        dualPane.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(dualPane)
        viewMenu.addItem(.separator())
        // 뷰 스타일 라디오 — ⌥⌘1/2/3 (⌘1..9는 탭 전환 배정, Finder ⌘1..4의 근접 대안)
        for (index, (title, style)) in [(L("Icons"), "icons"), (L("List"), "list"),
                                        (L("Gallery"), "gallery")].enumerated() {
            let entry = NSMenuItem(title: title,
                                   action: #selector(MainWindowController.applyViewStyle(_:)),
                                   keyEquivalent: "\(index + 1)")
            entry.keyEquivalentModifierMask = [.command, .option]
            entry.representedObject = style
            viewMenu.addItem(entry)
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: L("Expand to Open Folder"),
                                    action: #selector(MainWindowController.toggleExpandToOpenFolder(_:)),
                                    keyEquivalent: ""))
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: L("Enter Full Screen"),
                                    action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        addSubmenu(viewMenu, titled: L("View"), to: main)

        let fileOpsMenu = main.item(withTitle: L("File"))?.submenu
        fileOpsMenu?.insertItem(NSMenuItem.separator(), at: 1)
        let newFolderItem = NSMenuItem(title: L("New Folder"),
                                       action: #selector(MainWindowController.newFolder(_:)), keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileOpsMenu?.insertItem(newFolderItem, at: 2)
        let trashItem = NSMenuItem(title: L("Move to Trash"),
                                   action: #selector(MainWindowController.deleteSelected(_:)), keyEquivalent: "\u{08}")
        trashItem.keyEquivalentModifierMask = [.command]
        fileOpsMenu?.insertItem(trashItem, at: 3)

        let goMenu = NSMenu(title: L("Go"))
        let back = NSMenuItem(title: L("Back"),
                              action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        let forward = NSMenuItem(title: L("Forward"),
                                 action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "]")
        let up = NSMenuItem(title: L("Enclosing Folder"),
                            action: #selector(MainWindowController.goUp(_:)), keyEquivalent: "\u{F700}")
        up.keyEquivalentModifierMask = [.command]
        goMenu.addItem(back)
        goMenu.addItem(forward)
        goMenu.addItem(up)
        goMenu.addItem(.separator())
        let goToFolder = NSMenuItem(title: L("Go to Folder…"),
                                    action: #selector(MainWindowController.goToFolder(_:)), keyEquivalent: "g")
        goToFolder.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(goToFolder)
        goMenu.addItem(NSMenuItem(title: L("Edit Address…"),
                                  action: #selector(MainWindowController.goToFolder(_:)), keyEquivalent: "l"))
        goMenu.addItem(NSMenuItem(title: L("Connect to Server…"),
                                  action: #selector(MainWindowController.connectToServer(_:)), keyEquivalent: "k"))
        addSubmenu(goMenu, titled: L("Go"), to: main)

        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(withTitle: L("Minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Zoom"),
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let nextTab = NSMenuItem(title: L("Show Next Tab"),
                                 action: #selector(MainWindowController.showNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        windowMenu.addItem(nextTab)
        let previousTab = NSMenuItem(title: L("Show Previous Tab"),
                                     action: #selector(MainWindowController.showPreviousTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        windowMenu.addItem(previousTab)
        windowMenu.addItem(.separator())
        windowMenuStaticCount = windowMenu.items.count   // 이 뒤로 동적 탭 목록 삽입
        windowMenu.delegate = self
        addSubmenu(windowMenu, titled: L("Window"), to: main)
        NSApp.windowsMenu = windowMenu   // Fill·Center·타일링은 시스템이 자동 주입

        let helpMenu = NSMenu(title: L("Help"))
        let reportBug = NSMenuItem(title: L("Report a Bug…"), action: #selector(reportBug(_:)), keyEquivalent: "")
        reportBug.target = self
        helpMenu.addItem(reportBug)
        addSubmenu(helpMenu, titled: L("Help"), to: main)
        NSApp.helpMenu = helpMenu   // 시스템 검색 필드 자동 포함

        NSApp.mainMenu = main
    }

    private var windowMenuStaticCount = 0

    /// TreeFinder에 대하여 — 표준 패널 + 연락처 크레딧 (2026-07-16 제작자 지시)
    @objc private func showAboutPanel(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: L("Bug reports and inquiries:") + " ",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph])
        credits.append(NSAttributedString(
            string: "iamwhatiam78@gmail.com",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .link: URL(string: "mailto:iamwhatiam78@gmail.com")!,
                         .paragraphStyle: paragraph]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func reportBug(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let body = "\n\n—\nTreeFinder \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "iamwhatiam78@gmail.com"
        components.queryItems = [URLQueryItem(name: "subject", value: "TreeFinder Bug Report"),
                                 URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func addSubmenu(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
