import AppKit

/// Help ▸ 오픈 소스 라이선스 — 동반 오픈 소스 고지문(THIRD-PARTY-NOTICES.txt)을 읽기 전용 텍스트 창으로
/// (제작자 확정 2026-09-05, decisions §34). MIT 등 "모든 사본에 고지 포함" 조건을 앱 안에서 이행하는 유일한 열람 경로.
/// 정보 가져오기 창과 같은 계열 — NSWindow + contentView 직접 설정(contentViewController fitting-size 붕괴 함정 회피).
final class LicensesWindowController: NSWindowController, NSWindowDelegate {
    private static var current: LicensesWindowController?   // 창 1개 — 재호출은 전면으로

    static func show() {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = LicensesWindowController()
        current = controller
        controller.showWindow(nil)
    }

    private init() {
        let contentRect = NSRect(x: 0, y: 0, width: 640, height: 660)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("Open Source Licenses")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        super.init(window: window)
        window.delegate = self

        let scroll = NSScrollView(frame: contentRect)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        let text = NSTextView(frame: contentRect)
        text.isEditable = false
        text.isSelectable = true
        text.usesFindBar = true   // ⌘F — 구성 요소 이름으로 찾기(195개 크레이트 표)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 14, height: 12)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.string = Self.noticesText()
        scroll.documentView = text
        window.contentView = scroll
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("코드 전용 생성") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }

    /// 번들 리소스의 고지문 — 파일이 없으면(잘못된 빌드) 사실대로 표시(빈 창 금지)
    private static func noticesText() -> String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return L("The notices file could not be found in this copy of TreeFinder.")
        }
        return text
    }
}
