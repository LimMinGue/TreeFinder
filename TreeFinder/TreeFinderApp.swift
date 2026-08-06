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
        // =3 → 빈 공간 합성 클릭으로 활성 페인 전환 검증 (페인1→페인2 순, TF_PANE_FOCUS 로그)
        if let dualMode = ProcessInfo.processInfo.environment["TF_DUAL_PANE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                wc.toggleDualPane(nil)
            }
            if dualMode == "2" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    wc.toggleDualPane(nil)
                }
            }
            if dualMode == "3" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { wc.debugClickPaneEmptyArea(0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { wc.debugClickPaneEmptyArea(1) }
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
        // TF_STACK_DROP=move|copy|prune;<src경로> → 드롭스택 명시 이동/복사·완료 비움·소멸 정리 검증 (TF_START_DIR=목적지 병용)
        if let spec = ProcessInfo.processInfo.environment["TF_STACK_DROP"] {
            let parts = spec.split(separator: ";", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    wc.debugStackDrop(mode: parts[0], source: URL(fileURLWithPath: parts[1]))
                }
            }
        }
        // TF_TERMINAL_CWD=1 → 최초 터미널을 열고 셸 pid 로그 — 시작 폴더를 외부 lsof로 실측 (제작자 지시 2026-07-23)
        // 주의: TF_START_DIR(홈이 아닌 폴더) 병용 필수 — 홈 단독 실행은 구 동작(항상 홈)과 구분 불가한 위양성
        if ProcessInfo.processInfo.environment["TF_TERMINAL_CWD"] == "1" {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { preview()?.debugLogTerminalPid() }
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
        // TF_TERMINAL_BTOP=1 → btop 등 전체 화면 TUI의 시작 렌더 진단 (제작자 제보 2026-08-01)
        // 버퍼 채움을 50ms 간격으로 로그해 "빈 박스" 구간을 ms 단위로 특정하고, 같은 시점 스냅숏과 대조한다.
        // 동기화 출력(DEC 2026) 듀티와 터미널 크기 재협상 횟수도 함께 기록 — 표시 지연의 3대 용의자를 한 번에 가른다.
        if ProcessInfo.processInfo.environment["TF_TERMINAL_BTOP"] == "1" {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            // 터미널을 크게 — 프레임이 커야 청크가 많아져 표시 지연이 드러난다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let window = wc.window, let screen = window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.visibleFrame, display: true, animate: false)
                if let split = wc.contentViewController?.children
                    .compactMap({ $0 as? NSSplitViewController }).first?.splitView {
                    let dividers = split.arrangedSubviews.count - 1
                    if dividers >= 1 { split.setPosition(split.bounds.width * 0.28, ofDividerAt: dividers - 1) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { preview()?.debugTrackTerminalSize(seconds: 8.0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { preview()?.debugTerminalKeySim("btop") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { preview()?.debugSampleSyncDuty(seconds: 6.0) }
            // btop 입력 이후 경과 시간별 버퍼 채움 — 빈 박스 구간의 시작·끝을 ms 단위로 특정
            for ms in stride(from: 50, through: 1500, by: 50) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(ms) / 1000.0) {
                    preview()?.debugLogTerminalFill("t\(ms)")
                }
            }
            // 버퍼와 화면이 어긋나는지 대조할 스냅숏(빈 박스 구간 / 직후 / 정상화 후)
            for ms in [300, 400, 3000] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(ms) / 1000.0) {
                    Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-btop-t\(ms).png")
                }
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
        // TF_TERMINAL_CLOSE_REOPEN=1 → exit로 마지막 탭까지 닫히는지(+미리보기 복귀) → 다시 터미널 탭을
        // 열면 새 셸이 생기는지 검증. 스냅숏 2장(/tmp/treefinder-closed.png · treefinder-reopen.png)
        if ProcessInfo.processInfo.environment["TF_TERMINAL_CLOSE_REOPEN"] == "1" {
            let preview = { [weak wc] in
                wc?.contentViewController?.children
                    .compactMap { $0 as? NSSplitViewController }.first?
                    .splitViewItems.last?.viewController as? PreviewViewController
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { preview()?.debugTerminalKeySim("exit") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-closed.png")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { preview()?.debugShowTerminal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-reopen.png")
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
        // TF_SEARCH=<검색어> → (TF_START_DIR 병용) 재귀 파일명 검색 결과·위치 표시를 스냅숏으로 검증 (제작자 지시 2026-07-23)
        if let query = ProcessInfo.processInfo.environment["TF_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { wc.debugSearch(query) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-search.png")
            }
        }
        // TF_TREE_REFRESH=<폴더명> → (TF_START_DIR 병용) 시작 폴더에 폴더 생성 후 좌측 트리 자동 갱신 검증 (제작자 지시 2026-07-23)
        // 비브런시 사이드바가 스냅숏에서 백지라, 트리 노드 자식을 before/after 로그로 확인
        if let folderName = ProcessInfo.processInfo.environment["TF_TREE_REFRESH"] {
            let startDir = startDirectory
            // 런치 시 네트워크 위치 첫 갱신(이연)이 트리를 재구성하므로, 정착 후 노드를 펼쳐 정상 상태를 재현
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { wc.debugRevealTree(startDir) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSLog("TREE_REFRESH before: [%@]", wc.debugTreeChildNames(of: startDir).joined(separator: ", "))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { wc.debugCreateFolder(folderName) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSLog("TREE_REFRESH after: [%@]", wc.debugTreeChildNames(of: startDir).joined(separator: ", "))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-tree.png")
            }
        }
        // TF_FDA_PROBE=1 → 권한 거부의 두 원인(TCC / POSIX)이 오류로 구분되는지 실측 (제작자 지시 2026-08-06).
        // 결과(실측 확정): TCC 거부 = NSCocoaError 257 / **NSPOSIXErrorDomain 1(EPERM)**,
        //                  POSIX 권한 거부 = NSCocoaError 257 / **NSPOSIXErrorDomain 13(EACCES)**.
        //
        // **[경고 — 이 훅을 다시 쓸 때 반드시 읽을 것]**
        // ① `open`으로 띄워야 TCC 거부가 재현된다(셸 직접 실행은 부모 터미널의 전체 디스크 접근을 상속 — 실측).
        // ② 그런데 **Debug 빌드는 설치본과 번들 ID가 같아서(com.limmingue.TreeFinder), `open` 실험이
        //    실제 TreeFinder 앱의 권한 기록을 오염시킨다** — 2026-08-06 실측 중 사진·미디어 보관함·데스크탑·
        //    이동식 볼륨 4건이 앱 이름으로 등록되고 사용자에게 권한 창이 떴다(제작자 방해).
        // ③ 그래서 접근 대상은 **프롬프트가 뜨지 않는 FDA 계열(Safari·Mail·휴지통)만**으로 고정한다.
        //    시스템/SIP 경로·데스크탑·문서·사진·이동식 볼륨은 **절대 추가하지 말 것**(추가했다가 프롬프트를 띄운 실사례).
        // 판별식이 이미 확정됐으므로 이 훅은 회귀 확인용으로만 쓴다.
        if ProcessInfo.processInfo.environment["TF_FDA_PROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                var cases: [(String, URL)] = [
                    ("TCC:Safari", home.appendingPathComponent("Library/Safari")),
                    ("TCC:Mail", home.appendingPathComponent("Library/Mail")),
                    ("TCC:Trash", home.appendingPathComponent(".Trash")),
                ]
                // POSIX 권한 거부 대조군 — 임시 폴더를 0000으로 만들어 비교(끝나면 원복)
                let posix = FileManager.default.temporaryDirectory.appendingPathComponent("tf-fdaprobe-posix")
                try? FileManager.default.createDirectory(at: posix, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: posix.path)
                cases.append(("POSIX:0000", posix))
                var report: [String] = []
                for (label, url) in cases {
                    do {
                        let n = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).count
                        report.append("\(label) = 성공(\(n)건) 경로=\(url.path)")
                    } catch {
                        let e = error as NSError
                        let posixCode = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map {
                            "\($0.domain)/\($0.code)"
                        } ?? "없음"
                        report.append("\(label) = 실패 domain=\(e.domain) code=\(e.code) underlying=\(posixCode) 설명=\(e.localizedDescription)")
                    }
                }
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: posix.path)
                try? FileManager.default.removeItem(at: posix)
                for line in report { NSLog("FDA_PROBE %@", line) }
                // `open`으로 띄우면 stdout이 없고 os_log 회수도 환경을 타므로 파일로도 남긴다(회수 경로 단일화)
                try? (report.joined(separator: "\n") + "\n")
                    .write(toFile: "/tmp/tf-fda-probe.txt", atomically: true, encoding: .utf8)
            }
        }
        // TF_LISTING_FAIL=delete|chmod → (TF_START_DIR 병용) 보고 있는 폴더가 사라지거나 권한을 잃었을 때
        // 갱신 실패가 표면화되는지 실측 (제작자 확정 2026-08-06: 목록 비우고 오류 배너 — 이전엔 스테일 목록이 그대로 남았다)
        if let failMode = ProcessInfo.processInfo.environment["TF_LISTING_FAIL"] {
            let target = startDirectory
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSLog("LISTING_FAIL before 항목=[%@] 배너=%@",
                      wc.debugItemNames().joined(separator: ", "), wc.debugMessageText())
                // 앱 밖에서 벌어진 일을 재현 — FSEvents가 갱신을 유발한다
                if failMode == "delete" {
                    try? FileManager.default.removeItem(at: target)   // 삭제는 FSEvents가 갱신을 유발
                } else {
                    // 권한 변경은 FSEvents 대상이 아니다(디렉터리 이벤트만 감시) — 사용자가 파일 조작을 해
                    // 갱신이 도는 순간을 재현(감사에서 "새 폴더를 만들었는데 화면이 그대로"였던 그 경로)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { wc.debugReload() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                NSLog("LISTING_FAIL after 항목=[%@] 전체디스크접근버튼=%@ 배너=%@",
                      wc.debugItemNames().joined(separator: ", "),
                      wc.debugFDAButtonVisible() ? "노출" : "숨김", wc.debugMessageText())
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-listingfail.png")
                if failMode != "delete" {   // 검증 픽스처 원복(권한 되돌리기) — 정리 못 하면 폴더가 잠긴 채 남는다
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                }
            }
        }
        // TF_SYMLINK=<링크폴더이름> → (TF_START_DIR=부모 폴더 병용) 심링크 폴더 전 경로 실측 (제작자 제보 2026-08-06, §32):
        // ① 부모 목록에서 링크 행의 크기 표시 ② 트리 노드 자식(확장 화살표 근거) ③ 링크 폴더 진입 시 해석된 경로·항목
        // ④ 드롭 타깃 해석(같은 폴더 no-op — 해석 전엔 원본이 "이름 2"로 개명되던 자리) ⑤ 렌더 스냅숏
        if let linkName = ProcessInfo.processInfo.environment["TF_SYMLINK"] {
            let parent = startDirectory
            let link = parent.appendingPathComponent(linkName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { wc.debugRevealTree(parent) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                NSLog("SYMLINK 부모목록=[%@] 크기셀=%@ 트리자식=[%@]",
                      wc.debugItemNames().joined(separator: ", "),
                      wc.debugSizeCellText(named: linkName),
                      wc.debugTreeChildNames(of: link).joined(separator: ", "))
            }
            // 링크 폴더 안의 파일을 **링크 표기 경로**로 그 폴더 자신에게 드롭 = 같은 폴더 no-op이어야 한다.
            // (해석 전엔 '문서.txt' → '문서 2.txt' 개명이 일어났다 — 검증에서 실제로 재현된 자리)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                let inside = ((try? FileManager.default.contentsOfDirectory(atPath: link.path)) ?? [])
                    .sorted().first.map { link.appendingPathComponent($0) }
                if let inside { wc.debugPerformDrop(inside, into: link) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NSLog("SYMLINK 드롭후 대상폴더=[%@]",
                      ((try? FileManager.default.contentsOfDirectory(atPath: link.path)) ?? [])
                        .sorted().joined(separator: ", "))
                wc.debugShow(link)   // 즐겨찾기·트리 클릭과 동일 경로(show)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                NSLog("SYMLINK 진입경로=%@ 항목=[%@]",
                      wc.debugCurrentDirectory(), wc.debugItemNames().joined(separator: ", "))
                NSLog("SYMLINK 트리선택=%@", wc.debugTreeSelectedName())
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-symlink.png")
            }
        }
        // TF_TREE_MANUAL=<하위폴더>/<대상폴더> → (TF_START_DIR 병용, 홈 아래 경로) 트리를 그 하위까지 펼친 뒤
        // 앱 바깥에서 대상 폴더 이름을 바꿔(터미널·타 앱 재현) ① 옛 이름이 남는지(버그 재현)
        // ② refreshTree()로 고쳐지는지 ③ 우클릭 메뉴 구성에 "새로 고침"이 있는지 로그 검증 (제작자 제보 2026-07-25)
        if let spec = ProcessInfo.processInfo.environment["TF_TREE_MANUAL"] {
            let parts = spec.split(separator: "/").map(String.init)
            if parts.count == 2 {
                let parent = startDirectory.appendingPathComponent(parts[0])
                let target = parent.appendingPathComponent(parts[1])
                let renamed = parent.appendingPathComponent(parts[1] + "-바뀐이름")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { wc.debugRevealTree(parent) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NSLog("TREE_MANUAL before: [%@]", wc.debugTreeChildNames(of: parent).joined(separator: ", "))
                    try? FileManager.default.moveItem(at: target, to: renamed)   // 외부 이름 변경 재현
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    NSLog("TREE_MANUAL stale: [%@]", wc.debugTreeChildNames(of: parent).joined(separator: ", "))
                    wc.debugRefreshTree()   // 우클릭 "새로 고침"과 동일 경로
                    // 동기 로그 — 앱 활성화 자동 갱신이 끼어들 틈 없이 수동 경로 단독 효과를 확정
                    NSLog("TREE_MANUAL afterManual: [%@]",
                          wc.debugTreeChildNames(of: parent).joined(separator: ", "))
                }
                // 2차: 외부 이름 변경 후 다른 앱 → TreeFinder 복귀(셸이 전환) = 자동 갱신 단독 검증
                DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
                    NSLog("TREE_MANUAL autoAfter: [%@]",
                          wc.debugTreeChildNames(of: parent).joined(separator: ", "))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    NSLog("TREE_MANUAL after: [%@]", wc.debugTreeChildNames(of: parent).joined(separator: ", "))
                    NSLog("TREE_MANUAL menu(folder): [%@]",
                          wc.debugTreeMenuTitles(forNodeAt: parent).joined(separator: " | "))
                    NSLog("TREE_MANUAL menu(empty): [%@]",
                          wc.debugTreeMenuTitles(forNodeAt: nil).joined(separator: " | "))
                }
            }
        }
        // TF_TREE_NETWORK=1 → 트리 네트워크 그룹 확장(Bonjour 시작) 후 자식 구성(발견 호스트+기억 공유) 로그 검증 (제작자 제보 2026-07-23)
        if ProcessInfo.processInfo.environment["TF_TREE_NETWORK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { wc.debugExpandNetwork() }
            for delay in [4.0, 10.0] {   // Bonjour 발견 + 로컬 네트워크 권한 지연 대비 2회
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSLog("TREE_NETWORK children: [%@]", wc.debugNetworkChildren().joined(separator: ", "))
                }
            }
        }
        // TF_TREE_COPYPATH=<경로> → 트리 경로 복사 핸들러 구동 → 클립보드 내용 로그(NFC 보정 확인)
        if let copyPath = ProcessInfo.processInfo.environment["TF_TREE_COPYPATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                wc.debugTreeCopyPath(copyPath)
            }
        }
        // TF_TREE_SYNC=1 → (TF_START_DIR 병용) 트리 선택을 네트워크로 보낸 뒤 목록 파일 선택 시
        // 트리가 현재 폴더로 복귀(reveal)하는지 로그 검증 (제작자 제보 2026-07-23)
        if ProcessInfo.processInfo.environment["TF_TREE_SYNC"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                wc.debugSelectNetworkRow()
                NSLog("TREE_SYNC before: %@", wc.debugTreeSelectedName())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { wc.debugSelectFirstFile() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSLog("TREE_SYNC after: %@", wc.debugTreeSelectedName())
            }
        }
        // TF_ICON_REFRESH=<자식폴더명> → (TF_START_DIR 병용) 자식 폴더의 Icon\r 삭제가 FSEvents로
        // 트리 custom 재평가에 반영되는지 로그 검증 (제작자 제보 2026-07-23)
        if let iconFolder = ProcessInfo.processInfo.environment["TF_ICON_REFRESH"] {
            let startDir = startDirectory
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { wc.debugRevealTree(startDir) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NSLog("ICON_REFRESH before: [%@]", wc.debugTreeChildNames(of: startDir).joined(separator: ", "))
                // 커스텀 아이콘 제거를 외부 변경처럼 재현 — FSEvents 경유(eventDir=자식폴더, 부모=watched)
                try? FileManager.default.removeItem(
                    at: startDir.appendingPathComponent(iconFolder).appendingPathComponent("Icon\r"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NSLog("ICON_REFRESH after: [%@]", wc.debugTreeChildNames(of: startDir).joined(separator: ", "))
            }
        }
        // TF_FLICKER_TEST=1 → (TF_START_DIR 병용) 파일 선택 후 폴더에 연속 변경 발생 시
        // 선택 재발행(=미리보기 재로드) 횟수를 로그 검증 — 초기 1회 이후 0이어야 (제작자 제보 2026-07-23)
        if ProcessInfo.processInfo.environment["TF_FLICKER_TEST"] == "1" {
            let startDir = startDirectory
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { wc.debugSelectFirstFile() }
            // 초기화(선택·최초 리스팅) 정착 후 기준값 → 기존 파일 연속 "수정"(실사용 시나리오 — 다른 세션의
            // 파일 수정) → 선택 재발행·전체 reloadData 둘 다 증가 0이어야(= 시각적 깜빡임 없음)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                NSLog("FLICKER baseline: selectNotify=%d fullReload=%d",
                      wc.debugSelectNotifyCount(), wc.debugFullReloadCount())
            }
            for i in 1...5 {   // FSEvents 리로드 연발 유발 — 코얼레싱(0.5s) 간격보다 띄엄
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(i) * 0.7) {
                    try? Data("수정 \(i)".utf8).write(to: startDir.appendingPathComponent("가나다.txt"))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                NSLog("FLICKER final: selectNotify=%d fullReload=%d (baseline과 같아야 — 증가 = 깜빡임)",
                      wc.debugSelectNotifyCount(), wc.debugFullReloadCount())
            }
        }
        // TF_NEW_FOLDER=1 → (TF_START_DIR 병용) 새 폴더가 이름변경 상태로 생성되는지 스냅숏 검증 (제작자 지시 2026-07-23)
        if ProcessInfo.processInfo.environment["TF_NEW_FOLDER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { wc.debugNewFolder() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                // 크기 결과는 수십 ms 만에 도착 — 그 뒤에도 편집이 살아 있어야 한다(제작자 제보 2026-07-26)
                NSLog("NEW_FOLDER %@", wc.debugEditingState())   // editingRow≠nil·필드에디터면 이름변경 진입 성공
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-newfolder.png")
            }
            // 편집 종료(포커스 이동 = 커밋) → 편집 중 보류했던 크기 갱신이 흡수돼 표시되는지 실측
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { wc.debugCommitEditing() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
                NSLog("NEW_FOLDER afterCommit %@ size=%@", wc.debugEditingState(),
                      wc.debugSizeCellText(named: "untitled folder"))
            }
        }
        // TF_NEW_TEXTDOC=1 → (TF_START_DIR 병용) 새 텍스트 문서가 이름변경 상태로 생성되는지 실측 (제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_NEW_TEXTDOC"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { wc.debugNewTextDocument() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSLog("NEW_TEXTDOC %@", wc.debugEditingState())   // editingRow≠nil·필드에디터면 이름변경 진입 성공
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-newtextdoc.png")
            }
        }
        // TF_EJECT_TEST=1 → (TF_START_DIR=/Volumes 병용) 착탈식 볼륨 추출 판정·트리 ⏏·목록 메뉴 노출 비파괴 검증 (제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_EJECT_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                let roots = VolumeMonitor.shared.ejectableRoots.map(\.path).sorted()
                NSLog("EJECT_TEST ejectableRoots=%@", roots.description)
                for p in ["/Volumes/TF테스트USB", "/", "/System/Volumes/Data"] {
                    NSLog("EJECT_TEST isEjectable(%@)=%@", p,
                          VolumeMonitor.shared.isEjectable(URL(fileURLWithPath: p)) ? "true" : "false")
                }
                for line in wc.debugEjectTreeInfo() { NSLog("EJECT_TEST tree %@", line) }
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-eject.png")
            }
        }
        // TF_EJECT_DO=1 → (TF_START_DIR=/Volumes/TF테스트USB 병용) 볼륨 안을 보는 중 그 볼륨 추출 → 홈 이탈 + 언마운트 실측 (파괴적, 제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_EJECT_DO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSLog("EJECT_DO before dir=%@ mounted=%@", wc.debugCurrentDirectory(),
                      FileManager.default.fileExists(atPath: "/Volumes/TF테스트USB") ? "true" : "false")
                wc.debugEjectVolume("/Volumes/TF테스트USB")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                NSLog("EJECT_DO after dir=%@ mounted=%@", wc.debugCurrentDirectory(),
                      FileManager.default.fileExists(atPath: "/Volumes/TF테스트USB") ? "true" : "false")
            }
        }
        // TF_ICON_RENAME=1 → (TF_START_DIR 병용) 아이콘 뷰에서 첫 항목 인라인 이름변경 진입 실측 (제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_ICON_RENAME"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { wc.debugSetViewStyle("icons") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { wc.debugSelectFirstFile() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { wc.debugRename() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                NSLog("ICON_RENAME %@", wc.debugEditingState())   // editingRow≠nil·필드에디터면 편집 진입 성공
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-iconrename.png")
            }
        }
        // TF_QUICKLOOK=1 → (TF_START_DIR 병용) 스페이스바 Quick Look 팝업 실측 (제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_QUICKLOOK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { wc.debugQuickLook() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                NSLog("QUICKLOOK open %@", wc.debugQuickLookState())   // visible=true·item=선택파일이면 성공
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                let consumed = wc.debugQuickLookCloseViaSpace()       // Space 닫기 경로 = 소비(되튕김 없음)
                NSLog("QUICKLOOK closeConsumed=%@", consumed ? "true" : "false")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                NSLog("QUICKLOOK afterClose %@", wc.debugQuickLookState())   // visible=false면 깜빡임 없이 닫힘
            }
        }
        // TF_QUICKLOOK_FOLLOW=1 → (TF_START_DIR 병용, 이름 다른 파일 2개 이상 필요) 팝업이 선택 이동을 따라가는지 실측 (제작자 제보 2026-08-07)
        // 기존 TF_QUICKLOOK(열기·Space 닫기)은 이 버그를 재현하지 못해 회귀 기준선으로 보존하고 별도 스위치로 분리.
        // 한 줄에 selected=(목록의 실제 선택)과 item=(패널이 보는 파일)을 같이 찍는다 — 하나만 찍으면
        // "키 미배달"과 "배달됐지만 QL이 안 따라감"을 구분할 수 없다.
        if ProcessInfo.processInfo.environment["TF_QUICKLOOK_FOLLOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { wc.debugQuickLook() }   // 첫 항목 선택 + 팝업 열기
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                NSLog("QLFOLLOW open %@ selected=%@", wc.debugQuickLookState(), wc.debugSelectedName())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                // 선택 이동은 반드시 실제 키 경로로 — selectionDidSync를 부르는 헬퍼를 쓰면 수정 전에도 통과한다(위양성)
                NSLog("QLFOLLOW arrowConsumed=%@", wc.debugQuickLookArrowDown() ? "true" : "false")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) {
                NSLog("QLFOLLOW afterArrow %@ selected=%@", wc.debugQuickLookState(), wc.debugSelectedName())
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-qlfollow.png")
            }
            // 마우스 경로 — 첫 클릭은 비활성 창의 활성화 클릭에 먹히는 것이 실측돼(선택 불변) 다른 행으로 한 번 더 보낸다.
            // 그래도 selected= 가 안 바뀌면 무효 판정(헬퍼 주석 규칙) — 화살표 결과만 채택한다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { wc.debugClickListRow(2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) { wc.debugClickListRow(3) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                NSLog("QLFOLLOW afterClick %@ selected=%@", wc.debugQuickLookState(), wc.debugSelectedName())
            }
            // 마우스와 같은 델리게이트로 수렴하는 경로를 활성 상태(owner=yes)에서 검증 — 합성 클릭 무효 시의 본 판정.
            // 소유권 복구와 선택 변경은 반드시 분리(붙이면 updateController가 스스로 갱신해 위양성).
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) { wc.debugRestoreQuickLookOwnership() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) {
                NSLog("QLFOLLOW restored %@ selected=%@", wc.debugQuickLookState(), wc.debugSelectedName())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.8) { wc.debugSelectRowViaDelegate(2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.6) {
                NSLog("QLFOLLOW afterSelect %@ selected=%@", wc.debugQuickLookState(), wc.debugSelectedName())
            }
        }
        // TF_COLUMN_MENU=1 → (TF_START_DIR 병용) 헤더 우클릭 메뉴 구조 로그 + 최근사용일·태그 컬럼 표시 후 렌더 (제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_COLUMN_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                for line in wc.debugColumnHeaderMenu() { NSLog("COLMENU %@", line) }
                wc.debugShowColumn("dateLastOpened"); wc.debugShowColumn("tags")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-columnmenu.png")
            }
        }
        // TF_TYPESELECT=1 → (TF_START_DIR 병용) type-select 매처(완성형·초성·라틴) + inputContext 실측 (제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_TYPESELECT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { wc.debugTypeSelectProbe() }
        }
        // TF_COLUMNS=1 → (TF_START_DIR 병용) 컬럼 뷰 전환 + 폴더 선택 캐스케이드 실측 (제작자 지시 2026-07-25)
        if ProcessInfo.processInfo.environment["TF_COLUMNS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { wc.debugSetViewStyle("columns") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { wc.debugBrowserSelectFolder() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                NSLog("COLUMNS selection=%@", wc.debugBrowserSelection())
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-columns.png")
            }
        }
        // TF_SET_TAG=<1~7> → (TF_START_DIR 병용) 첫 항목에 색상 태그 적용 후 목록 행 색 + 스와치 뷰 렌더 검증 (제작자 지시 2026-07-23)
        if let tagRaw = ProcessInfo.processInfo.environment["TF_SET_TAG"], let n = Int(tagRaw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { wc.debugSetTag(n) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                Self.debugCaptureContent(of: wc.window, to: "/tmp/treefinder-tag.png")
                Self.debugRenderSwatch(current: n, to: "/tmp/treefinder-swatch.png")
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
    /// TF_SET_TAG — 태그 색 점 스와치 뷰를 단독 렌더(메뉴는 스냅숏 곤란 → 뷰 직접 캡처)
    private static func debugRenderSwatch(current: Int, to path: String) {
        let sw = TagSwatchView(current: current, onPick: { _ in })
        guard let rep = sw.bitmapImageRepForCachingDisplay(in: sw.bounds) else { return }
        sw.cacheDisplay(in: sw.bounds, to: rep)
        let img = NSImage(size: sw.bounds.size)
        img.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: sw.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: sw.bounds.size))
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

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
        // 뷰 스타일 라디오 — ⌥⌘1/2/3/4 (⌘1..9는 탭 전환 배정, Finder ⌘1..4의 근접 대안). 컬럼 추가 2026-07-25.
        for (index, (title, style)) in [(L("Icons"), "icons"), (L("List"), "list"),
                                        (L("Columns"), "columns"), (L("Gallery"), "gallery")].enumerated() {
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
