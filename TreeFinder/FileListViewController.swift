import AppKit
import Quartz   // QLPreviewPanel — 스페이스바 Quick Look 팝업 (제작자 지시 2026-07-25)

/// 탭 하나 — 폴더 아이콘 + 이름 + ✕, 활성 탭은 얇은 테두리 필(pill) (원본 탭 레퍼런스 기준)
final class TabItemView: NSView {
    private let index: Int
    private let isActive: Bool
    private let onSelect: (Int) -> Void
    private let onClose: (Int) -> Void
    private let onDropFiles: (Int, [URL], Bool, DropStackView?) -> Void
    private let acceptsDrops: Bool
    private var springTimer: Timer?

    init(index: Int, icon tabIcon: NSImage?, title: String, active: Bool, closable: Bool,
         acceptsDrops: Bool = true,
         onSelect: @escaping (Int) -> Void, onClose: @escaping (Int) -> Void,
         onDropFiles: @escaping (Int, [URL], Bool, DropStackView?) -> Void) {
        self.index = index
        self.isActive = active
        self.onSelect = onSelect
        self.onClose = onClose
        self.onDropFiles = onDropFiles
        self.acceptsDrops = acceptsDrops
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])   // 탭 위 드롭 = 그 탭 폴더로 (원본 1.1.10)
        wantsLayer = true
        layer?.cornerRadius = 7
        if active { layer?.borderWidth = 1 }
        // 색은 init에서 굳히지 않는다 — CGColor는 설정 시점 어피어런스로 고정되어
        // 라이트 컨텍스트에서 만들어진 탭이 다크 창에서 흰 필로 남는 버그 실측(2026-07-16 제작자 제보)

        let icon = NSImageView(image: tabIcon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
        ])
        if closable {
            let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
            close.isBordered = false
            close.font = .systemFont(ofSize: 9)
            close.contentTintColor = .secondaryLabelColor
            close.translatesAutoresizingMaskIntoConstraints = false
            addSubview(close)
            NSLayoutConstraint.activate([
                close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
                close.centerYAnchor.constraint(equalTo: centerYAnchor),
                close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ])
        } else {
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 활성 필 색을 현재 유효 어피어런스로 재해석 — 창 부착 시·라이트/다크 전환 시마다
    private func applyPillColors() {
        guard isActive else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPillColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPillColors()
    }

    /// 더블클릭 = 이름 수정 등 (터미널 탭 전용 — 미설정이면 무동작)
    var onDoubleClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {   // ✕ 클릭은 버튼이 소비
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick(index)
        } else {
            onSelect(index)
        }
    }

    @objc private func closeTapped() { onClose(index) }

    // MARK: 드래그 스프링 오픈 + 드롭 (원본 1.1.10 — 호버하면 탭이 열리고, 놓으면 그 폴더로)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops,   // 터미널 탭 등 드롭 미배선 스트립 = 거부(조용히 삼키지 않게 — 적대검증)
              sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        springTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.onSelect(self.index)   // 스프링 오픈 — 계속 끌고 들어가 내부 폴더에 드롭 가능
        }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        springTimer?.invalidate()
        springTimer = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        springTimer?.invalidate()
        springTimer = nil
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty else { return false }
        onDropFiles(index, urls, NSEvent.modifierFlags.contains(.option),
                    sender.draggingSource as? DropStackView)   // 스택 출처 = 이동/복사 메뉴 (§9 ①)
        return true
    }
}

/// 파일 목록 영역 상단의 커스텀 탭 스트립 (2026-07-16 제작자 확정 — 창 전체가 아니라 목록 영역 위)
final class TabBarView: NSView {
    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onAddTab: (() -> Void)?
    var onDropOnTab: ((Int, [URL], Bool, DropStackView?) -> Void)?
    /// 마지막 남은 탭도 ✕로 닫을 수 있는지. 파일 목록은 폴더가 항상 하나 떠 있어야 해서 기본 false
    /// (마지막 탭 닫기 = ⌘W로 창 닫기). 터미널은 0개 상태가 유효해 true (제작자 지시 2026-07-21)
    var allowsClosingLastTab = false
    var showsActiveAccent = false {
        didSet { needsDisplay = true }
    }
    private let stack = NSStackView()

    /// height 기본 40 = 상단 컨트롤 밴드 불변식(§11-1). 터미널 내부 스트립 등은 더 낮게 지정 가능.
    init(height: CGFloat = 40) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 상단 컨트롤 밴드 = 40pt (미리보기 페인의 Preview/Terminal 스위치 행과 동일 —
            // 탭 필(24pt)과 스위치가 같은 세로 위치, 컬럼 헤더 시작 = 터미널 시작선. 제작자 지적 2026-07-16)
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if showsActiveAccent {   // 듀얼 모드 활성 페인 표시
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }

    /// 파일 목록 탭 — URL에서 아이콘·이름 파생(네트워크 센티널 분기 포함)
    func update(urls: [URL], active: Int) {
        update(items: urls.map { url in
            url.isFileURL
                ? (NSWorkspace.shared.icon(forFile: url.path), FileManager.default.displayName(atPath: url.path))
                : (NSImage(systemSymbolName: "globe", accessibilityDescription: nil), L("Network"))
        }, active: active)
    }

    /// 더블클릭 콜백 — 터미널 탭 이름 수정용 (파일 탭은 미설정 = 무동작)
    var onDoubleClickTab: ((Int) -> Void)?

    /// 범용 탭 스트립 — 터미널 등 URL 없는 탭도 동일 필 디자인 공유 (규칙 4)
    func update(items: [(icon: NSImage?, title: String)], active: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let tab = TabItemView(
                index: index, icon: item.icon, title: item.title, active: index == active,
                closable: allowsClosingLastTab || items.count > 1,
                acceptsDrops: onDropOnTab != nil,   // 터미널 탭 스트립 = 드롭 거부 (적대검증)
                onSelect: { [weak self] in self?.onSelectTab?($0) },
                onClose: { [weak self] in self?.onCloseTab?($0) },
                onDropFiles: { [weak self] in self?.onDropOnTab?($0, $1, $2, $3) })
            tab.onDoubleClick = onDoubleClickTab
            stack.addArrangedSubview(tab)
        }
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L("New Tab"))!,
                           target: self, action: #selector(addClicked))
        add.isBordered = false
        stack.addArrangedSubview(add)
    }

    @objc private func addClicked() { onAddTab?() }
}

/// 태그 라벨 색을 행 전체 배경으로 (교차 행 배경 위에 우선 — decisions §9)
final class TagRowView: NSTableRowView {
    var tagColor: NSColor? {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tagColor else { return }
        tagColor.setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// 리스트 테이블 — Finder 키 규약(제작자 지시 2026-07-23): Enter=이름변경, ⌘↓=열기/폴더 진입.
/// 화살표 선택·type-select는 NSTableView 기본 동작에 위임(super).
/// type-select는 NSTextInputClient 경로로 한글 완성형 지원 (제작자 지시 2026-07-25, 조사 반영 — 컬렉션 뷰와 통일)
final class TFTableView: NSTableView, NSTextInputClient {
    var onRename: (() -> Void)?
    var onOpen: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onQuickLook: (() -> Void)?   // 스페이스바 = Quick Look (제작자 지시 2026-07-25)
    var onTypeSelect: ((String) -> Void)? { didSet { typeSelect.onQuery = onTypeSelect } }
    let typeSelect = TypeSelectController()
    // 빈 공간 클릭(선택 무변화)도 듀얼 페인 활성 승격 — super(선택 변화 통지) "이전"이어야
    // onSelect의 활성 페인 가드가 새 활성 기준으로 통과한다 (제작자 제보 2026-07-23)
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        // 조합 중이 아닐 때만 특수키 가로채기 — 조합 중 Return=완성형 커밋 등은 IME 우선
        if !typeSelect.hasMarked {
            let cmd = event.modifierFlags.contains(.command)
            let code = Int(event.keyCode)
            if (code == 36 || code == 76), !cmd, selectedRow >= 0 {   // Return·키패드 Enter → 이름변경
                onRename?(); return
            }
            if code == 125, cmd, selectedRow >= 0 {                   // ⌘↓ → 열기/폴더 진입
                onOpen?(); return
            }
            if code == 49, !cmd, !event.modifierFlags.contains(.option) {   // Space → Quick Look (Finder 규약)
                onQuickLook?(); return
            }
        }
        // 인쇄 문자·조합 중 = IME 경로(완성형 수신), 나머지(화살표 등) = super 네비게이션 (조사 §Q3)
        if typeSelect.shouldRoute(event), inputContext?.handleEvent(event) == true { return }
        super.keyDown(with: event)
    }

    // NSTextInputClient — 컬렉션 뷰와 동일 최소 구현(규칙 4: 로직은 TypeSelectController 공용)
    func insertText(_ string: Any, replacementRange: NSRange) { typeSelect.insert(TypeSelectController.string(from: string)) }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        typeSelect.setMarked(TypeSelectController.string(from: string))
    }
    func unmarkText() { typeSelect.unmark() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { typeSelect.markedRange }
    func hasMarkedText() -> Bool { typeSelect.hasMarked }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}

final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                    NSMenuDelegate, NSTextFieldDelegate,
                                    NSCollectionViewDataSource, NSCollectionViewDelegate,
                                    NSBrowserDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let row = editingRow else { return }
        editingRow = nil
        field.isEditable = false
        field.delegate = nil
        let iconItem = editingIconItem   // 아이콘 뷰 인라인 rename (제작자 지시 2026-07-25)
        editingIconItem = nil
        iconItem?.endEditing()
        let hadPendingRefresh = pendingRefresh   // EditGuard 보류분 — 어느 경로로 끝나도 흡수
        pendingRefresh = false
        // 아이콘 경로는 no-op/오류에도 항상 리로드 — 재구성이 라벨을 올바로 되돌린다(list는 flicker 회피로 리로드 생략)
        guard items.indices.contains(row) else {
            if hadPendingRefresh || iconItem != nil { reloadCurrentDirectory() }
            return
        }
        let item = items[row]
        let newName = field.stringValue
        // 표시명('/')을 디스크명(':')으로 변환해 비교 — 안 그러면 '개인/가족' 표시 == '개인:가족' 디스크가
        // 서로 다르다고 오판돼, 변경 없는 편집도 '이미 존재' 오류를 낸다 (제작자 지시 2026-07-23)
        guard !newName.isEmpty, Self.diskName(fromDisplay: newName) != item.name else {
            if iconItem == nil { field.stringValue = Self.displayName(fromDisk: item.name) }
            if hadPendingRefresh || iconItem != nil { reloadCurrentDirectory() }
            return
        }
        do {
            let renamed = try Self.posixRename(item.url, toName: newName)
            registerRenameUndo(current: renamed, originalName: item.name)
        } catch {
            if iconItem == nil { field.stringValue = Self.displayName(fromDisk: item.name) }
            reportError(error)
        }
        reloadCurrentDirectory()
    }

    private func registerRenameUndo(current: URL, originalName: String) {
        fileUndoManager.registerUndo(withTarget: self) { target in
            if let back = try? Self.posixRename(current, toName: originalName) {
                target.registerRenameUndo(current: back, originalName: current.lastPathComponent)
            }
            target.reloadCurrentDirectory()
        }
        fileUndoManager.setActionName(L("Rename"))
    }

    var onSelect: ((FileItem?) -> Void)?
    /// .sh 실행 요청 — 미리보기 패널의 새 터미널 탭으로 라우팅 (제작자 지시 2026-07-21)
    var onRunScript: ((URL) -> Void)?
    var onAddFavorite: ((URL) -> Void)?
    /// 듀얼 페인 — 사용자 상호작용 시 이 페인을 활성으로 승격 (워게임 dual_pane §4)
    var onActivate: (() -> Void)?
    /// 듀얼 모드에서 활성 페인 표시(탭 스트립 액센트 라인)
    var showsActiveIndicator: Bool = false {
        didSet { tabBar.showsActiveAccent = showsActiveIndicator }
    }
    /// (전체 항목 수, 선택 수, 선택 바이트 합, 크기 계산 중 여부) — 상태바 표시용
    var onStatusChange: ((Int, Int, Int64, Bool) -> Void)?
    /// 폴더 이동 통지 — 검색 필드 placeholder 등 창 크롬 갱신용
    var onDirectoryChange: ((URL) -> Void)?
    /// 현재 폴더 내용 변경(파일 조작·FSEvents) → 트리 노드 갱신 신호 (제작자 지시 2026-07-23)
    var onContentsChanged: ((URL) -> Void)?

    private(set) var directory: URL?
    private var allItems: [FileItem] = []   // 필터 전 원본
    private var items: [FileItem] = []      // 필터+정렬 적용본 (테이블 표시)
    private var filterText = ""
    private var searchTask: Task<Void, Never>?
    private var searchResults: [FileItem]?   // nil = 검색 아님(현재 폴더). 값이 있으면 하위 트리 검색 결과
    /// 검색 기준 폴더의 **조상 심링크까지 푼** 경로 — Spotlight 결과 경로와 표기를 맞춰 '들어있는 폴더'를 상대화한다.
    /// 백그라운드에서 1회 계산(셀 그릴 때마다 파일시스템을 만지지 않기 위해).
    private var searchBase: String?
    private var spotlightQuery: NSMetadataQuery?          // Spotlight 검색 (Finder 패리티 — 이름+내용)
    private var spotlightObserver: NSObjectProtocol?
    private let tableView = TFTableView()
    private let tabBar = TabBarView()
    private let messageLabel = NSTextField(labelWithString: "")
    /// 권한 오류 시에만 노출 — 전체 디스크 접근 설정 바로가기 (제작자 제보 2026-07-17)
    private lazy var fdaButton = NSButton(title: L("Open Full Disk Access Settings…"),
                                          target: self, action: #selector(openFullDiskAccessSettings(_:)))

    // MARK: 뷰 스타일 상태 (워게임 [2026-07-16]_wargame_icon_gallery_view.md)
    private(set) var viewStyle: ViewStyle = .list
    var onViewStyleChange: ((ViewStyle) -> Void)?
    private let tableScroll = NSScrollView()
    private let collectionView = TFCollectionView()
    private let collectionScroll = NSScrollView()
    // 아이콘 크기 슬라이더 — icons 모드 전용 우하단 플로팅(Finder 규약, 제작자 지시 2026-07-25)
    private let iconSizeBar = NSVisualEffectView()
    private let iconSizeSlider = NSSlider()
    // 컬럼 뷰 = 네이티브 NSBrowser(Finder Miller 컬럼, 제작자 지시 2026-07-25). ponytail: 계단식 리스트 자작 대신 플랫폼 기본.
    private let browser = NSBrowser()
    private var browserChildrenCache: [URL: [URL]] = [:]   // 폴더 URL → 자식 URL(정렬됨) — 컬럼 재리스팅 최소화
    private var browserItemByURL: [URL: FileItem] = [:]     // URL → FileItem(표시·leaf 판정)
    private let galleryBox = NSView()
    private let galleryPreview = PassivePreviewView(frame: .zero, style: .normal)!
    private let galleryCaption = NSTextField(labelWithString: "")
    private var gridModeConstraints: [NSLayoutConstraint] = []
    private var stripModeConstraints: [NSLayoutConstraint] = []
    private var galleryDebounce: DispatchWorkItem?   // 화살표 스크럽 시 QLPreview 풀 로드 방지 (150ms)
    private var sizeRebuildScheduled = false          // 크기순 정렬 중 폴더 크기 도착 rebuild 코얼레싱
    private var loadTask: Task<Void, Never>?
    private var sortKey: SortKey = .name
    private var sortAscending = true
    // 탭별 상태(URL·히스토리·정렬) — 라이브 변수(backStack 등)는 항상 "활성 탭"의 작업본 (decisions §10 후속)
    private struct TabState {
        var url: URL
        var backStack: [URL] = []
        var forwardStack: [URL] = []
        var sortKey: SortKey = .name
        var sortAscending = true
        var viewStyle: ViewStyle = .list
    }
    private var tabs: [TabState] = []
    private var tabURLs: [URL] { tabs.map(\.url) }
    private var activeTab = 0
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var navigatingViaHistory = false
    private var fsEventStream: FSEventStreamRef?
    private var pendingRefresh = false   // EditGuard — rename 편집 중 보류된 갱신
    private var pendingRenameURL: URL?   // 새 폴더 생성 직후 이름변경 진입 대상 (제작자 지시 2026-07-23)
    private var folderSizes: [String: FolderSize] = [:]   // 표시용 사본 (진실은 SizeService 캐시)
    private var pendingScanCount = 0                       // 상태바 "Calculating…" 표시용
    private lazy var operationEngine = FileOperationEngine(reportError: { [weak self] in
        self?.reportError($0)
    })

    private static let sizeFormatter = ByteCountFormatter()
    private static let localeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let isoTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private static let localeTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// 오늘/어제는 날짜 대신 "오늘 14:32" 식으로 (2026-07-16 제작자 지시). 그 이전은 기존 포맷 유지.
    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let iso = UserDefaults.standard.bool(forKey: SettingsKeys.isoDates)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            let day = calendar.isDateInToday(date) ? L("Today") : L("Yesterday")
            let time = (iso ? isoTimeFormatter : localeTimeFormatter).string(from: date)
            return "\(day) \(time)"
        }
        return (iso ? isoFormatter : localeFormatter).string(from: date)
    }

    override func loadView() {
        // 컬럼 구성 = 제작자 Finder 습관 기준(decisions §1): 이름·수정일·생성일·크기·종류
        // + 헤더 우클릭 선택 컬럼(최근 사용일·추가된 날짜·태그, 기본 숨김 — 제작자 지시 2026-07-25)
        addColumn(.name, title: L("Name"), width: 280, minWidth: 160)
        addColumn(.dateModified, title: L("Date Modified"), width: 150, minWidth: 100)
        addColumn(.dateCreated, title: L("Date Created"), width: 150, minWidth: 100)
        addColumn(.dateLastOpened, title: L("Date Last Opened"), width: 150, minWidth: 100)
        addColumn(.dateAdded, title: L("Date Added"), width: 150, minWidth: 100)
        addColumn(.size, title: L("Size"), width: 80, minWidth: 60)
        addColumn(.kind, title: L("Kind"), width: 140, minWidth: 80)
        addColumn(.tags, title: L("Tags"), width: 120, minWidth: 80)
        applyColumnVisibility()   // 저장된 표시 상태(기본: 최근사용일·추가된날짜·태그 숨김)
        setupColumnHeaderMenu()   // 헤더 우클릭 = 컬럼 표시/숨김 메뉴

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true   // 격자 배경 — 행 구분(2026-07-16 제작자 지시)
        tableView.style = .inset
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.target = self
        tableView.onRename = { [weak self] in self?.renameSelected(nil) }   // Enter = 이름변경 (Finder 규약)
        tableView.onOpen = { [weak self] in self?.openSelected() }          // ⌘↓ = 열기/진입 (Finder 규약)
        tableView.onMouseDown = { [weak self] in self?.onActivate?() }      // 빈 공간 클릭 = 페인 활성
        tableView.onTypeSelect = { [weak self] query in self?.typeSelect(query) }   // 한글 완성형 IME 경로 (제작자 지시 2026-07-25)
        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook() }   // 스페이스바 Quick Look

        tableView.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false
        tableView.menu = contextMenu
        collectionView.menu = contextMenu   // 동일 메뉴 공유 — menuNeedsUpdate가 활성 스타일로 분기

        // 드래그 소스(밖으로: Finder 등) + 드롭 타깃(안으로)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) {
            [weak self] _ in self?.reloadActiveView()   // 날짜 포맷·확장자 표시 등 즉시 반영
        }
        // 네트워크 브라우즈 중 발견 결과 증감 → 목록 재구성 (워게임 network_browse)
        NotificationCenter.default.addObserver(forName: .networkHostsChanged, object: nil, queue: .main) {
            [weak self] _ in self?.reloadNetworkItems()
        }
        // 볼륨 추출/언마운트(트리 ⏏·목록 메뉴·Finder 외부) 시 현재 폴더가 그 볼륨 하위면 홈으로 이탈 (제작자 지시 2026-07-25)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self.navigateAwayIfInside(volume)
        }

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        // 아이콘/갤러리 컬렉션 뷰 — 선택 계열 전제 설정 3종 필수 (파워유저 위원)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.collectionViewLayout = Self.makeGridLayout()
        // 주의: register는 레이아웃 할당 "후" — 레이아웃 교체가 등록 테이블을 무효화하는 AppKit 동작 실측
        collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.reuseIdentifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.onDoubleClick = { [weak self] in self?.openSelected() }
        collectionView.onTypeSelect = { [weak self] prefix in self?.typeSelect(prefix) }
        collectionView.onQuickLook = { [weak self] in self?.toggleQuickLook() }   // 스페이스바 Quick Look
        collectionView.onMouseDown = { [weak self] in self?.onActivate?() }   // 빈 공간 클릭 = 페인 활성
        collectionScroll.documentView = collectionView
        collectionScroll.hasVerticalScroller = true
        collectionScroll.autohidesScrollers = true
        collectionScroll.translatesAutoresizingMaskIntoConstraints = false
        collectionScroll.isHidden = true

        // 갤러리 상단 대형 미리보기 + 파일명 캡션 (디자이너 위원 — Finder 갤러리 규약)
        galleryPreview.shouldCloseWithWindow = true
        galleryPreview.translatesAutoresizingMaskIntoConstraints = false
        galleryCaption.font = .systemFont(ofSize: 12)
        galleryCaption.textColor = .secondaryLabelColor
        galleryCaption.alignment = .center
        galleryCaption.lineBreakMode = .byTruncatingMiddle
        galleryCaption.translatesAutoresizingMaskIntoConstraints = false
        galleryBox.translatesAutoresizingMaskIntoConstraints = false
        galleryBox.isHidden = true
        galleryBox.addSubview(galleryPreview)
        galleryBox.addSubview(galleryCaption)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        // labelWithString:은 단일행 라벨 — 랩핑을 켜지 않으면 maximumNumberOfLines=0이어도 잘림(제작자 제보)
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 420
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.usesSingleLineMode = false
        messageLabel.cell?.wraps = true
        messageLabel.cell?.isScrollable = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        fdaButton.isHidden = true
        fdaButton.bezelStyle = .rounded
        fdaButton.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelectTab = { [weak self] index in self?.selectTab(index) }
        tabBar.onCloseTab = { [weak self] index in self?.closeTab(index) }
        tabBar.onAddTab = { [weak self] in self?.addTab() }
        tabBar.onDropOnTab = { [weak self] index, urls, forceCopy, stack in
            guard let self, self.tabURLs.indices.contains(index) else { return }
            self.performDrop(urls, into: self.tabURLs[index], forceCopy: forceCopy, stackSource: stack)
        }

        let container = NSView()
        container.addSubview(tabBar)
        container.addSubview(tableScroll)
        container.addSubview(galleryBox)
        container.addSubview(collectionScroll)
        container.addSubview(messageLabel)
        container.addSubview(fdaButton)
        NSLayoutConstraint.activate([
            fdaButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            fdaButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            collectionScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            collectionScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            collectionScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            // 갤러리 박스 내부 — 미리보기가 캡션 위 공간 전부
            galleryPreview.topAnchor.constraint(equalTo: galleryBox.topAnchor, constant: 8),
            galleryPreview.leadingAnchor.constraint(equalTo: galleryBox.leadingAnchor, constant: 8),
            galleryPreview.trailingAnchor.constraint(equalTo: galleryBox.trailingAnchor, constant: -8),
            galleryCaption.topAnchor.constraint(equalTo: galleryPreview.bottomAnchor, constant: 6),
            galleryCaption.bottomAnchor.constraint(equalTo: galleryBox.bottomAnchor, constant: -6),
            galleryCaption.leadingAnchor.constraint(equalTo: galleryBox.leadingAnchor, constant: 16),
            galleryCaption.trailingAnchor.constraint(equalTo: galleryBox.trailingAnchor, constant: -16),
        ])
        // 아이콘 크기 슬라이더 — icons 모드 전용 우하단 플로팅 캡슐 (제작자 지시 2026-07-25, Finder 규약)
        iconSizeBar.material = .popover
        iconSizeBar.blendingMode = .withinWindow
        iconSizeBar.state = .active
        iconSizeBar.wantsLayer = true
        iconSizeBar.layer?.cornerRadius = 7
        iconSizeBar.isHidden = true
        iconSizeBar.translatesAutoresizingMaskIntoConstraints = false
        iconSizeSlider.minValue = Double(IconGridMetrics.minSide)
        iconSizeSlider.maxValue = Double(IconGridMetrics.maxSide)
        iconSizeSlider.doubleValue = Double(IconGridMetrics.side)
        iconSizeSlider.isContinuous = true
        iconSizeSlider.controlSize = .small
        iconSizeSlider.target = self
        iconSizeSlider.action = #selector(iconSizeChanged(_:))
        iconSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        let smallGlyph = NSImageView()
        let largeGlyph = NSImageView()
        smallGlyph.image = NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil)
        largeGlyph.image = NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil)
        smallGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        largeGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        smallGlyph.contentTintColor = .secondaryLabelColor
        largeGlyph.contentTintColor = .secondaryLabelColor
        for glyph in [smallGlyph, largeGlyph] { glyph.translatesAutoresizingMaskIntoConstraints = false }
        iconSizeBar.addSubview(smallGlyph)
        iconSizeBar.addSubview(iconSizeSlider)
        iconSizeBar.addSubview(largeGlyph)
        container.addSubview(iconSizeBar)
        NSLayoutConstraint.activate([
            iconSizeBar.trailingAnchor.constraint(equalTo: collectionScroll.trailingAnchor, constant: -16),
            iconSizeBar.bottomAnchor.constraint(equalTo: collectionScroll.bottomAnchor, constant: -12),
            iconSizeBar.heightAnchor.constraint(equalToConstant: 26),
            smallGlyph.leadingAnchor.constraint(equalTo: iconSizeBar.leadingAnchor, constant: 9),
            smallGlyph.centerYAnchor.constraint(equalTo: iconSizeBar.centerYAnchor),
            iconSizeSlider.leadingAnchor.constraint(equalTo: smallGlyph.trailingAnchor, constant: 7),
            iconSizeSlider.centerYAnchor.constraint(equalTo: iconSizeBar.centerYAnchor),
            iconSizeSlider.widthAnchor.constraint(equalToConstant: 92),
            largeGlyph.leadingAnchor.constraint(equalTo: iconSizeSlider.trailingAnchor, constant: 7),
            largeGlyph.trailingAnchor.constraint(equalTo: iconSizeBar.trailingAnchor, constant: -9),
            largeGlyph.centerYAnchor.constraint(equalTo: iconSizeBar.centerYAnchor),
        ])
        // 컬럼 뷰(NSBrowser) — 목록 영역 전체, 기본 숨김. 계단식 탐색은 네이티브 (제작자 지시 2026-07-25)
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.isHidden = true
        browser.delegate = self
        browser.target = self
        browser.action = #selector(browserClicked(_:))
        browser.doubleAction = #selector(browserDoubleClicked(_:))
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.allowsEmptySelection = true
        browser.allowsMultipleSelection = true
        browser.separatesColumns = true
        browser.takesTitleFromPreviousColumn = false
        browser.menu = contextMenu   // 파일 컨텍스트 메뉴 공유(menuNeedsUpdate가 컬럼 분기)
        container.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // icons: 컬렉션이 목록 영역 전체 / gallery: 상단 갤러리 박스 + 하단 필름스트립(76pt)
        gridModeConstraints = [
            collectionScroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
        ]
        stripModeConstraints = [
            collectionScroll.heightAnchor.constraint(equalToConstant: 76),
            galleryBox.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            galleryBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            galleryBox.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            galleryBox.bottomAnchor.constraint(equalTo: collectionScroll.topAnchor),
        ]
        NSLayoutConstraint.activate(gridModeConstraints)
        view = container
    }

    // MARK: 뷰 스타일 전환 (워게임 §4 — 트랜잭션 순서 고정)

    private static func makeGridLayout() -> NSCollectionViewFlowLayout {
        let layout = LeftAlignedFlowLayout()
        layout.itemSize = IconGridMetrics.itemSize(IconGridMetrics.side)   // 슬라이더 값 (제작자 지시 2026-07-25)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return layout
    }

    private static func makeStripLayout() -> NSCollectionViewFlowLayout {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 56, height: 56)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        return layout
    }

    /// 아이콘 크기 슬라이더 — 드래그 중 즉시 리사이즈(상수만·선택 보존), 놓으면 새 해상도 썸네일 갱신 (제작자 지시 2026-07-25).
    @objc private func iconSizeChanged(_ sender: NSSlider) {
        let side = CGFloat(sender.doubleValue.rounded())
        UserDefaults.standard.set(Double(side), forKey: SettingsKeys.iconSize)
        guard viewStyle == .icons,
              let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        layout.itemSize = IconGridMetrics.itemSize(side)
        for case let cell as FileIconItem in collectionView.visibleItems() { cell.updateGridSide(side) }
        layout.invalidateLayout()
        if NSApp.currentEvent?.type == .leftMouseUp {   // 드래그 종료 → 새 해상도 썸네일(선택 보존)
            let selection = collectionView.selectionIndexPaths
            collectionView.reloadData()
            collectionView.selectionIndexPaths = selection
        }
    }

    // MARK: 컬럼 뷰 (NSBrowser — Finder Miller 컬럼, 제작자 지시 2026-07-25)

    /// 루트 = 현재 폴더로 브라우저 재적재. 캐시 비움 후 컬럼 0부터 다시 그림.
    private func reloadBrowser() {
        browserChildrenCache.removeAll()
        browserItemByURL.removeAll()
        browser.loadColumnZero()
    }

    /// 폴더 자식 URL(폴더 우선 자연 정렬·숨김 설정 준수) — 컬럼 델리게이트 반복 호출 캐시.
    /// ponytail: 동기 리스팅(로컬 전제). 비로컬 볼륨 지원은 VolumeLanes 후속.
    private func browserChildURLs(of folder: URL) -> [URL] {
        if let cached = browserChildrenCache[folder] { return cached }
        let showHidden = UserDefaults.standard.bool(forKey: SettingsKeys.showHidden)
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        // 심링크 폴더는 해석 후 열거 — 안 하면 오류 문구도 없이 빈 컬럼이 열린다(§32)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: DirectoryLister.resolvedFolder(folder),
            includingPropertiesForKeys: DirectoryLister.resourceKeys, options: options)) ?? []
        let items = DirectoryLister.sorted(urls.map(DirectoryLister.item(for:)))
        for item in items { browserItemByURL[item.url] = item }
        let childURLs = items.map(\.url)
        browserChildrenCache[folder] = childURLs
        return childURLs
    }

    private func browserItem(_ url: URL) -> FileItem {
        browserItemByURL[url] ?? DirectoryLister.item(for: url)
    }

    private func selectedBrowserURL() -> URL? {
        guard let indexPath = browser.selectionIndexPath else { return nil }
        return browser.item(at: indexPath) as? URL
    }

    @objc private func browserClicked(_ sender: NSBrowser) {
        onActivate?()   // 듀얼 페인 활성 승격 (테이블·컬렉션과 대칭)
        let url = selectedBrowserURL()
        onSelect?(url.map { browserItem($0) })   // 미리보기·경로 바·상태바 갱신
        notifyStatus()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()   // 컬럼 뷰에서도 QL이 선택 따라감
        }
    }

    @objc private func browserDoubleClicked(_ sender: NSBrowser) {
        guard let url = selectedBrowserURL() else { return }
        if browserItem(url).isDirectory {
            show(directory: url)   // 폴더 = 루트 변경(진입) — 리스트/아이콘과 동일 탐색
        } else {
            openSelected()   // 파일 = 열기(selectedURLs 컬럼 인지 경유)
        }
    }

    // NSBrowserDelegate (item-based) — 노드 = 파일 URL
    func rootItem(for browser: NSBrowser) -> Any? { directory }
    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let folder = (item as? URL) ?? directory else { return 0 }
        return browserChildURLs(of: folder).count
    }
    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let folder = (item as? URL) ?? directory ?? FileManager.default.homeDirectoryForCurrentUser
        let children = browserChildURLs(of: folder)
        return children.indices.contains(index) ? children[index] : folder
    }
    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let url = item as? URL else { return false }
        return !browserItem(url).isDirectory   // 폴더만 다음 컬럼(패키지=파일=leaf)
    }
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        guard let url = item as? URL else { return "" }
        return Self.displayName(fromDisk: browserItem(url).name)   // '개인:가족' → '개인/가족' 표시
    }
    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let browserCell = cell as? NSBrowserCell,
              let url = browser.item(atRow: row, inColumn: column) as? URL else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        browserCell.image = icon
    }

    #if DEBUG
    func debugQuickLook() {   // TF_QUICKLOOK — 첫 항목 선택 후 스페이스바 Quick Look 토글
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeFirstResponder(tableView)
        setActiveSelection(IndexSet(integer: 0), scrollToFirst: false)
        selectionDidSync()
        toggleQuickLook()
    }
    func debugQuickLookState() -> String {
        let panel = QLPreviewPanel.shared()
        let visible = QLPreviewPanel.sharedPreviewPanelExists() && (panel?.isVisible ?? false)
        let item = (panel?.currentPreviewItem as? NSURL)?.lastPathComponent ?? "nil"
        return "visible=\(visible) item=\(item)"
    }
    /// 열린 패널에 Space를 handle로 전달 = 닫기 경로. return true(소비)면 목록으로 안 되튕겨 이중 토글 없음.
    func debugQuickLookCloseViaSpace() -> Bool {
        guard let panel = QLPreviewPanel.shared(),
              let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
        else { return false }
        return previewPanel(panel, handle: space)   // true = Space 소비(되튕김 차단)
    }
    /// TF_COLUMN_MENU — 헤더 우클릭 메뉴 구조(캡처 배치·토글/회색/체크) + 컬럼 토글 렌더 검증
    func debugColumnHeaderMenu() -> [String] {
        updateHeaderColumnMenuStates()
        return (headerColumnMenu?.items ?? []).map { item in
            let toggle = item.representedObject != nil
            return "\(item.title)[\(toggle ? "토글" : "회색")\(item.isEnabled ? "" : "·비활성")\(item.state == .on ? "·✓" : "")]"
        }
    }
    func debugShowColumn(_ key: String) {
        tableView.tableColumns.first(where: { $0.identifier.rawValue == key })?.isHidden = false
    }
    /// TF_TYPESELECT — 매처 실측(완성형 prefix·초성·라틴) + inputContext 존재 확인.
    /// IME 실입력은 헤드리스 재현 불가(조사 §검증) → 매처 로직과 입력 클라이언트 준비만 검증.
    func debugTypeSelectProbe() {
        for query in ["강", "고", "ㄱ", "app", "ban"] {
            typeSelect(query)
            let name = activeSelectionIndexes().first.flatMap { items.indices.contains($0) ? items[$0].name : nil } ?? "nil"
            NSLog("TYPESELECT query=%@ selected=%@", query, name)
        }
        view.window?.makeFirstResponder(tableView)
        NSLog("TYPESELECT tableInputContext=%@ collectionInputContext=%@",
              tableView.inputContext != nil ? "yes" : "no",
              collectionView.inputContext != nil ? "yes" : "no")
        // 합성 아래 화살표 → IME가 안 삼키고 super 네비게이션 보존 (조사 §함정1 회귀)
        setActiveSelection(IndexSet(integer: 0), scrollToFirst: false)
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function,
                timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) {
            tableView.keyDown(with: down)
        }
        NSLog("TYPESELECT arrowDown selectedRow=%d (1 기대 — 네비게이션 보존)", tableView.selectedRow)
        // 합성 keyDown 'b' → keyDown→inputContext.handleEvent→insertText→매처→banana (라틴 실키 경로 회귀)
        setActiveSelection(IndexSet(), scrollToFirst: false)
        tableView.typeSelect.reset()
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11) {
            tableView.keyDown(with: event)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let name = self.activeSelectionIndexes().first.flatMap {
                self.items.indices.contains($0) ? self.items[$0].name : nil } ?? "nil"
            NSLog("TYPESELECT synthKeyB selected=%@ (banana.txt 기대 — 라틴 실키 경로)", name)
        }
    }
    func debugBrowserSelectFolder() {   // TF_COLUMNS — 컬럼 0의 첫 폴더 선택 → 두 번째 컬럼 캐스케이드 검증
        guard let root = directory else { return }
        let children = browserChildURLs(of: root)
        guard let idx = children.firstIndex(where: { browserItem($0).isDirectory }) else { return }
        browser.selectRow(idx, inColumn: 0)
        browserClicked(browser)
    }
    func debugBrowserSelection() -> String { selectedBrowserURL()?.lastPathComponent ?? "nil" }
    #endif

    // MARK: Quick Look 팝업 (스페이스바 — Finder 규약, 제작자 지시 2026-07-25)

    /// 스페이스바 → 시스템 Quick Look 패널 토글. 오른쪽 사이드 미리보기와 독립(순수 추가).
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func quickLookURLs() -> [URL] {
        selectedURLs().filter { $0.isFileURL }   // 네트워크 센티널 등 비파일 제외
    }

    private var activeListResponder: NSView {
        switch viewStyle {
        case .list: return tableView
        case .columns: return browser
        case .icons, .gallery: return collectionView
        }
    }

    /// 컬럼 뷰 등 하위 뷰가 스페이스를 소비 안 하면 컨트롤러가 받음(리스트/아이콘은 자체 가로채 onQuickLook).
    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 49,   // Space
           !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option) {
            toggleQuickLook(); return
        }
        super.keyDown(with: event)
    }

    // QLPreviewPanelController (informal, 응답 체인) — 활성 페인이 패널 제어(듀얼 페인 무료 라우팅)
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = self
        panel.dataSource = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = nil
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs().count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = quickLookURLs()
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
    /// 패널이 열린 채 받은 키 처리 (Finder 규약)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let code = Int(event.keyCode)
        if code == 49 {   // Space = 닫기. 직접 닫고 소비 — 목록으로 되튕겨 onQuickLook 이중 토글되던 깜빡임 차단 (제작자 제보 2026-07-25)
            panel.orderOut(nil)
            return true
        }
        if [123, 124, 125, 126].contains(code) {   // 화살표 = 목록 탐색(선택 이동 → reloadData가 QL 따라감)
            activeListResponder.keyDown(with: event)
            return true
        }
        return false
    }

    func setViewStyle(_ style: ViewStyle) {
        guard style != viewStyle else { return }
        let selection = Set(activeSelectionIndexes().compactMap {
            items.indices.contains($0) ? items[$0].url : nil
        })
        viewStyle = style
        applyViewStyleLayout()
        restoreSelection(urls: selection, scrollToFirst: true)
        selectionDidSync()
        // firstResponder 이관 — 안 하면 전환 직후 ⌘A·화살표가 숨은 뷰로 감 (파워유저 위원)
        let responder: NSResponder = style == .list ? tableView : (style == .columns ? browser : collectionView)
        view.window?.makeFirstResponder(responder)
        onViewStyleChange?(style)
    }

    /// 제약 스왑 → 레이아웃 교체(새 인스턴스·비애니메이션) → unhide 전 reload — 순서 불변 (QC 위원)
    private func applyViewStyleLayout() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            NSLayoutConstraint.deactivate(gridModeConstraints + stripModeConstraints)
            NSLayoutConstraint.activate(viewStyle == .gallery ? stripModeConstraints : gridModeConstraints)
            view.layoutSubtreeIfNeeded()
            switch viewStyle {
            case .list:
                tableView.reloadData()          // stale row count 해소 후 노출 (QC 위원 크래시 경로)
            case .icons, .gallery:
                collectionView.collectionViewLayout = viewStyle == .icons
                    ? Self.makeGridLayout() : Self.makeStripLayout()
                // 레이아웃 교체 후 재등록 — 교체가 등록 테이블을 무효화하는 AppKit 동작 방어
                collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.reuseIdentifier)
                collectionView.reloadData()
            case .columns:
                reloadBrowser()   // NSBrowser 루트 = 현재 폴더 (제작자 지시 2026-07-25)
            }
            tableScroll.isHidden = viewStyle != .list
            collectionScroll.isHidden = !(viewStyle == .icons || viewStyle == .gallery)
            galleryBox.isHidden = viewStyle != .gallery
            iconSizeBar.isHidden = viewStyle != .icons   // 슬라이더는 아이콘 모드 전용 (제작자 지시 2026-07-25)
            browser.isHidden = viewStyle != .columns
            if viewStyle != .gallery {
                galleryDebounce?.cancel()
                galleryPreview.previewItem = nil   // 동영상 백그라운드 재생 중단 (QC 위원)
                galleryCaption.stringValue = ""
            }
        }
    }

    // MARK: 활성 뷰 선택/리로드 추상화 — 테이블 직접 참조 금지 (QC 위원 전수 21곳 반영)

    private func activeSelectionIndexes() -> IndexSet {
        switch viewStyle {
        case .list: return tableView.selectedRowIndexes
        case .columns: return []   // 브라우저 선택은 items 인덱스와 무관 — selectedURLs()가 컬럼 인지 (제작자 지시 2026-07-25)
        case .icons, .gallery: return IndexSet(collectionView.selectionIndexPaths.map(\.item))
        }
    }

    private func setActiveSelection(_ indexes: IndexSet, scrollToFirst: Bool) {
        switch viewStyle {
        case .list:
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            if scrollToFirst, let first = indexes.first { tableView.scrollRowToVisible(first) }
        case .columns:
            break   // 컬럼 선택은 브라우저가 관리 — 숨은 컬렉션의 scrollToItems 크래시 방지 (제작자 지시 2026-07-25)
        case .icons, .gallery:
            collectionView.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
            if scrollToFirst, let first = indexes.first {
                collectionView.scrollToItems(
                    at: [IndexPath(item: first, section: 0)],
                    scrollPosition: viewStyle == .gallery ? .nearestHorizontalEdge : .nearestVerticalEdge)
            }
        }
    }

    private func restoreSelection(urls: Set<URL>, scrollToFirst: Bool) {
        // 빈 집합도 명시적으로 비운다 — 숨은 테이블의 stale 선택 부활 방지 (검증 워크플로 major)
        setActiveSelection(IndexSet(items.indices.filter { urls.contains(items[$0].url) }),
                           scrollToFirst: scrollToFirst)
    }

    private func activeClickedIndex() -> Int? {
        if viewStyle == .list {
            let row = tableView.clickedRow
            return row >= 0 ? row : nil
        }
        return collectionView.clickedIndexPath?.item
    }

    /// items가 변하지 않은 호출부(cut/copy/설정 변경)용 — reloadData가 선택을 비우므로(실측) URL 기준 보존.
    /// 안 하면 연속 ⌘X에서 잘라내기가 조용히 복사로 강등 (검증 워크플로 major)
    private func reloadActiveView() {
        let selected = Set(selectedURLs())
        reloadActiveViewRaw()
        restoreSelection(urls: selected, scrollToFirst: false)
    }

    /// 선택 보존 없는 원시 reload — items를 방금 바꾼 rebuildItems 전용(잘못된 URL 캡처 방지)
    #if DEBUG
    private(set) var debugFullReloadCount = 0   // TF_FLICKER_TEST — 전체 reloadData(=가시 행 전부 재생성) 횟수
    #endif

    private func reloadActiveViewRaw() {
        #if DEBUG
        debugFullReloadCount += 1
        #endif
        if viewStyle == .list { tableView.reloadData() } else { collectionView.reloadData() }
    }

    #if DEBUG
    private(set) var debugSelectNotifyCount = 0   // TF_FLICKER_TEST — 선택 재발행(=미리보기 재로드) 횟수
    #endif

    /// 프로그램적 선택 변경 뒤 공용 통지 — 컬렉션은 델리게이트가 침묵하므로 명시 호출 필수 (QC 위원)
    private func selectionDidSync() {
        #if DEBUG
        debugSelectNotifyCount += 1
        #endif
        let indexes = activeSelectionIndexes()
        // 갤러리는 대형 미리보기와 같은 항목(마지막 선택) 기준 — 정보 페인 불일치 방지 (검증 minor)
        let anchor = viewStyle == .gallery ? indexes.last : indexes.first
        onSelect?(anchor.flatMap { items.indices.contains($0) ? items[$0] : nil })
        notifyStatus()
        if viewStyle == .gallery { updateGalleryPreview() }
        // Quick Look 팝업이 열려 있으면 선택 이동을 따라감 (Finder 규약, 제작자 지시 2026-07-25)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    private func updateGalleryPreview() {
        galleryDebounce?.cancel()
        // 다중 선택 시 마지막 항목 표시 (디자이너 위원 — Finder 갤러리 규약)
        guard let last = activeSelectionIndexes().last, items.indices.contains(last) else {
            galleryPreview.previewItem = nil
            galleryCaption.stringValue = ""
            return
        }
        let url = items[last].url
        galleryCaption.stringValue = FileManager.default.displayName(atPath: url.path)
        let work = DispatchWorkItem { [weak self] in
            self?.galleryPreview.previewItem = url as NSURL
        }
        galleryDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)   // 스크럽 디바운스
    }

    #if DEBUG
    func debugRunScript(_ url: URL) { openFile(url) }   // TF_RUN_SCRIPT — .sh 더블클릭과 동일 경로

    func debugSelectFirstItem() {   // TF_VIEW_STYLE 스냅숏 검증용 — 선택 시각/갤러리 미리보기 확인
        guard !items.isEmpty else { return }
        setActiveSelection(IndexSet(integer: 0), scrollToFirst: true)
        selectionDidSync()
    }
    #endif

    /// 한글 음절의 초성(호환 자모) — keyDown 경로는 IME 조합을 못 받으므로 초성 점프로 대응 (검증 워크플로)
    private static let choseongTable: [Character] = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ",
                                                     "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    private static func choseong(of name: String) -> Character? {
        guard let scalar = PathPasteboard.normalized(name).unicodeScalars.first,
              (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        return choseongTable[Int((scalar.value - 0xAC00) / 588)]
    }

    /// type-select — 아이콘/갤러리 공용. 영문/숫자 프리픽스 + 한글 초성 점프(ㄱ → 가~깋)
    private func typeSelect(_ prefix: String) {
        onActivate?()   // 테이블 type-select와 대칭 — 듀얼 페인 크롬 어긋남 방지 (검증 minor)
        let query = PathPasteboard.normalized(prefix).localizedLowercase
        let index: Int?
        if query.count == 1, let jamo = query.first,
           (0x3131...0x314E).contains(jamo.unicodeScalars.first?.value ?? 0) {
            index = items.firstIndex(where: { Self.choseong(of: $0.name) == jamo })
        } else {
            index = items.firstIndex(where: {
                PathPasteboard.normalized($0.name).localizedLowercase.hasPrefix(query)
            })
        }
        guard let index else { return }
        setActiveSelection(IndexSet(integer: index), scrollToFirst: true)
        selectionDidSync()
    }

    // MARK: 탭 (파일 목록 영역 스코프 — decisions §10)

    func addTab(showing url: URL? = nil) {
        guard let target = url ?? directory else { return }
        saveActiveTabState()
        tabs.append(TabState(url: target, viewStyle: viewStyle))   // 새 탭 = 빈 히스토리·현재 뷰 스타일 상속
        activeTab = tabs.count - 1
        loadActiveTabState()
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTab else { refreshTabBar(); return }
        saveActiveTabState()
        activeTab = index
        loadActiveTabState()
    }

    private func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        if index == activeTab {
            tabs.remove(at: index)
            activeTab = min(activeTab, tabs.count - 1)
            loadActiveTabState()
        } else {
            // 비활성 탭 닫기 — 활성 탭 리로드·히스토리 오염 없이 제거만
            if index < activeTab { activeTab -= 1 }
            tabs.remove(at: index)
            refreshTabBar()
        }
    }

    private func saveActiveTabState() {
        guard tabs.indices.contains(activeTab) else { return }
        tabs[activeTab].backStack = backStack
        tabs[activeTab].forwardStack = forwardStack
        tabs[activeTab].sortKey = sortKey
        tabs[activeTab].sortAscending = sortAscending
        tabs[activeTab].viewStyle = viewStyle
    }

    private func loadActiveTabState() {
        let tab = tabs[activeTab]
        backStack = tab.backStack
        forwardStack = tab.forwardStack
        sortKey = tab.sortKey
        sortAscending = tab.sortAscending
        // 뷰 스타일은 show() 이전에 복원 — 리로드가 올바른 활성 뷰로 가도록 (코드정합 위원)
        if tab.viewStyle != viewStyle {
            // stale 아이템이 새 스타일로 렌더되며 썸네일 요청까지 나가는 것 차단 — 빈 화면이 오표시보다 안전 (검증 minor)
            allItems = []
            items = []
            viewStyle = tab.viewStyle
            applyViewStyleLayout()
            // 포커스가 목록 계열이었다면 새 활성 뷰로 이관 — 키보드 탐색 유지 (검증 minor)
            if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) {
                view.window?.makeFirstResponder(viewStyle == .list ? tableView : collectionView)
            }
            onViewStyleChange?(viewStyle)
        }
        // 헤더 정렬 화살표 동기화 — sortDescriptorsDidChange가 같은 값으로 재설정(무해)
        tableView.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: sortAscending)]
        navigatingViaHistory = true   // 탭 전환·복원은 그 탭의 히스토리에 push하지 않는다
        show(directory: tab.url)
    }

    /// 세션 저장 주체 여부 — 주(첫) 페인만 켠다(듀얼 페인 경합 방지). TF_ 검증 실행에선 꺼짐.
    var persistsSession = false

    private func refreshTabBar() {
        tabBar.update(urls: tabURLs, active: activeTab)
        guard persistsSession else { return }
        // 탭 변동의 단일 초크포인트 — 여기서 세션 저장 (재실행 복원용, 네트워크 센티널 제외)
        UserDefaults.standard.set(tabURLs.filter(\.isFileURL).map(\.path), forKey: SettingsKeys.lastTabs)
        UserDefaults.standard.set(activeTab, forKey: SettingsKeys.lastActiveTab)
    }

    /// 마지막 세션 복원 — 소멸된 폴더는 걸러냄 (제작자 지시 2026-07-17)
    func restoreSession(tabPaths: [String], active: Int) {
        // 심링크 경로로 저장된 탭(§32 이전 세션)은 isDirectory=false라 통째로 사라졌다 — 해석 창구 경유(§32)
        let dirs = tabPaths.map { DirectoryLister.resolvedFolder(URL(fileURLWithPath: $0)) }.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        guard !dirs.isEmpty else { return }
        tabs = dirs.map { TabState(url: $0, viewStyle: viewStyle) }
        activeTab = min(max(0, active), tabs.count - 1)
        loadActiveTabState()
    }

    private func addColumn(_ key: SortKey, title: String, width: CGFloat, minWidth: CGFloat) {
        let column = NSTableColumn(identifier: .init(key.rawValue))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
        tableView.addTableColumn(column)
    }

    // MARK: 헤더 우클릭 = 컬럼 표시/숨김 (Finder 규약, 캡처 기준 — 제작자 지시 2026-07-25)

    private var headerColumnMenu: NSMenu?

    /// 저장된 숨김 컬럼 적용 — 미저장 기본 = 최근사용일·추가된날짜·태그 숨김(Finder 기본). 이름은 항상 표시.
    private func applyColumnVisibility() {
        let hidden: Set<String>
        if let saved = UserDefaults.standard.array(forKey: SettingsKeys.hiddenColumns) as? [String] {
            hidden = Set(saved)
        } else {
            hidden = [SortKey.dateLastOpened.rawValue, SortKey.dateAdded.rawValue, SortKey.tags.rawValue]
        }
        for column in tableView.tableColumns where column.identifier.rawValue != SortKey.name.rawValue {
            column.isHidden = hidden.contains(column.identifier.rawValue)
        }
    }

    /// 헤더 우클릭 메뉴 구성 = 캡처 배치. 토글(데이터 있음)·회색 비활성(공개 API 부재/페치 비용, §17 규약).
    private func setupColumnHeaderMenu() {
        let menu = NSMenu()
        menu.delegate = self            // menuNeedsUpdate에서 이 메뉴로 분기해 체크마크 갱신
        menu.autoenablesItems = false   // 회색 항목 상태 수동 유지
        func toggle(_ key: SortKey, _ title: String) {
            let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            menu.addItem(item)
        }
        func grayed(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false   // 데이터 없음 — Finder도 회색(제작자 확정 2026-07-25)
            menu.addItem(item)
        }
        toggle(.dateModified, L("Date Modified"))
        toggle(.dateCreated, L("Date Created"))
        toggle(.dateLastOpened, L("Date Last Opened"))
        toggle(.dateAdded, L("Date Added"))
        toggle(.size, L("Size"))
        toggle(.kind, L("Kind"))
        grayed(L("Last Modified By"))
        grayed(L("Shared By"))
        grayed(L("Version"))
        grayed(L("Comments"))
        toggle(.tags, L("Tags"))
        headerColumnMenu = menu
        tableView.headerView?.menu = menu
    }

    /// 메뉴 열릴 때 체크마크 = 현재 표시 상태 (menuNeedsUpdate에서 호출)
    private func updateHeaderColumnMenuStates() {
        guard let menu = headerColumnMenu else { return }
        for item in menu.items {
            guard let key = item.representedObject as? String,
                  let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == key }) else { continue }
            item.state = column.isHidden ? .off : .on
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == key }) else { return }
        column.isHidden.toggle()
        let hidden = tableView.tableColumns.filter(\.isHidden).map { $0.identifier.rawValue }
        UserDefaults.standard.set(hidden, forKey: SettingsKeys.hiddenColumns)
    }

    /// 네트워크 브라우즈 센티널 — show(directory:) 단일 초크포인트로 탭·히스토리·듀얼 페인 공짜 (워게임 network_browse)
    static let networkURL = URL(string: "treefinder://network")!
    var isNetworkBrowse: Bool { directory == Self.networkURL }

    func show(directory: URL) {
        // 심링크 폴더는 여기서 **한 번** 대상으로 해석한다(Finder 규약 — decisions §32). 이 한 줄이
        // 목록 리스팅·FSEvents 감시 경로·크기 캐시 키·검색 스코프·탭 세션 저장까지 전부 실경로로 정렬한다
        // (self.directory 대입은 앱 통틀어 이 함수 하나뿐 = 단일 초크포인트).
        let directory = DirectoryLister.resolvedFolder(directory)
        onActivate?()
        if !navigatingViaHistory, let old = self.directory, old != directory {
            backStack.append(old)
            forwardStack.removeAll()
        }
        navigatingViaHistory = false
        self.directory = directory
        filterText = ""   // 폴더 이동 시 검색 필터 초기화 (Finder 규약)
        tableView.typeSelect.reset(); collectionView.typeSelect.reset()   // type-select 버퍼 리셋 (조사 §함정6)
        searchTask?.cancel(); stopSpotlight(); searchResults = nil   // 진행 중 검색 취소 (제작자 지시 2026-07-23)
        if tabs.isEmpty { tabs = [TabState(url: directory, viewStyle: viewStyle)] } else { tabs[activeTab].url = directory }
        refreshTabBar()
        loadTask?.cancel()
        if isNetworkBrowse {   // 네트워크 브라우즈 — 가상 목록(Bonjour 발견 호스트)
            stopWatcher()
            view.window?.title = L("Network")
            onDirectoryChange?(directory)
            NetworkBrowser.shared.start()
            reloadNetworkItems()
            return
        }
        restartWatcher(for: directory)
        view.window?.title = FileManager.default.displayName(atPath: directory.path)
        onDirectoryChange?(directory)
        loadTask = Task { [weak self] in
            var listed: [FileItem] = []
            var failure: Error?
            do {
                listed = try await DirectoryLister.list(
                    directory, showHidden: UserDefaults.standard.bool(forKey: SettingsKeys.showHidden))
            } catch is CancellationError {
                return
            } catch {
                failure = error
            }
            guard let self, !Task.isCancelled else { return }
            self.allItems = listed
            self.rebuildItems(scrollToTop: true)
            self.showListingFailure(failure)
            self.selectionDidSync()   // onSelect(nil) + 갤러리 미리보기 초기화
            self.requestFolderSizes()
        }
    }

    /// 리스팅 실패 표면화 단일 창구(규칙 4) — 폴더를 여는 경로(show)와 갱신 경로(reloadCurrentDirectory) 공용.
    /// nil을 주면 이전 오류를 해제한다. 조용한 실패 금지: 갱신 실패를 삼키면 **사라진 폴더의 목록이 그대로 남고**
    /// 그 위에서 만든 새 폴더·붙여넣기는 디스크에만 반영돼 사용자가 실패한 줄 알고 반복한다
    /// (제작자 확정 2026-08-06: 목록을 비우고 배너 표시 — Finder는 배너를 안 띄우지만 정직함을 택함).
    private func showListingFailure(_ error: Error?) {
        guard let error else {
            messageLabel.stringValue = ""
            messageLabel.isHidden = true
            fdaButton.isHidden = true
            return
        }
        var text = String(format: L("Can't read this folder — %@"), error.localizedDescription)
        // 휴지통 등 보호 폴더 = 전체 디스크 접근 필요 — 사유만 말고 해결법 안내 (제작자 제보 2026-07-17)
        let permissionDenied = (error as NSError).domain == NSCocoaErrorDomain
            && (error as NSError).code == NSFileReadNoPermissionError
        if permissionDenied {
            text += "\n\n" + L("Allow TreeFinder under System Settings ▸ Privacy & Security ▸ Full Disk Access, then relaunch the app.")
        }
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        fdaButton.isHidden = !permissionDenied
    }

    /// 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 전체 디스크 접근 바로 열기
    @objc private func openFullDiskAccessSettings(_ sender: Any?) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 네트워크 브라우즈 항목 재구성 — 발견된 SMB 호스트(Bonjour). 정렬·검색·상태바는 기존 경로 공용.
    private func reloadNetworkItems() {
        guard isNetworkBrowse else { return }
        allItems = NetworkBrowser.shared.hosts.compactMap { name in
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
                  let url = URL(string: "smb://\(encoded)") else { return nil }
            return FileItem(url: url, name: name, isDirectory: false, isPackage: false,
                            fileSize: nil, dateModified: nil, dateCreated: nil,
                            kind: L("Network computer"), labelNumber: 0,
                            dateLastOpened: nil, dateAdded: nil, tagNames: "")
        }
        // 로컬 네트워크 권한 거부/초기 탐색 중 = 결과 0 — 정직한 상태 라벨 (워게임 §4)
        messageLabel.stringValue = allItems.isEmpty ? L("Searching for network computers…") : ""
        messageLabel.isHidden = !allItems.isEmpty
        fdaButton.isHidden = true   // 이전 권한 오류 잔상 방지
        rebuildItems(preserveSelection: true)
        selectionDidSync()
        notifyStatus()
    }

    /// 네트워크 컴퓨터 연결 — 호스트명 해석 → NetFS(인증·공유 선택 = 시스템 UI) → 마운트 지점으로 탐색
    private func connectToNetworkComputer(_ item: FileItem) {
        NetworkBrowser.shared.connect(toService: item.name) { [weak self] mounted in
            guard let self else { return }
            if let mounted {
                self.show(directory: mounted)
            } else {
                let alert = NSAlert()
                alert.messageText = String(format: L("Couldn't connect to %@"), item.name)
                if let window = self.view.window { alert.beginSheetModal(for: window) }
            }
        }
    }

    // MARK: 폴더 크기 (SizeService — 워게임 [2026-07-16]_wargame_size_service.md)

    private func sizeKey(_ url: URL) -> String { PathPasteboard.normalized(url.standardizedFileURL.path) }

    /// 현재 목록의 폴더들 크기를 요청 — 스캔 시작 주체는 SizeService 하나, 여긴 조회+표시만
    private func requestFolderSizes() {
        guard let directory else { return }
        guard searchResults == nil else { return }   // 검색 결과(하위 트리 전체)는 크기 스캔 안 함 (제작자 지시 2026-07-23)
        // 비로컬 볼륨은 v1 제외 — 행 걸린 마운트가 스캔 워커를 점유하는 것 방지 (워게임 §4)
        guard (try? directory.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? false else { return }
        let generation = directory
        for item in allItems where item.isDirectory {
            let key = sizeKey(item.url)
            guard folderSizes[key] == nil else { continue }
            pendingScanCount += 1
            Task { [weak self] in
                let size = await SizeService.shared.size(for: item.url)
                guard let self else { return }
                self.pendingScanCount = max(0, self.pendingScanCount - 1)
                guard self.directory == generation else { return }   // 이동했으면 표시 생략(캐시는 유지)
                self.folderSizes[key] = size
                if self.sortKey == .size {
                    self.scheduleSizeRebuild()                       // 크기 정렬 중엔 순서 갱신 (0.3초 코얼레싱)
                } else if self.viewStyle == .list,                   // 아이콘/갤러리엔 크기 컬럼 없음 — stale 테이블 부분 리로드 금지
                          let row = self.items.firstIndex(where: { $0.url == item.url }) {
                    // 컬럼 번호는 반드시 식별자로 조회 — 하드코딩 3은 §27에서 컬럼 3종이 끼어들며
                    // '최근 사용일'을 가리키게 됐다(크기 칸이 제때 안 그려지던 잠복 회귀).
                    let sizeColumn = self.tableView.column(withIdentifier: .init(SortKey.size.rawValue))
                    if sizeColumn >= 0 {   // 상태바 갱신은 계속돼야 하므로 return 아님
                        self.reloadRows(IndexSet(integer: row), columns: IndexSet(integer: sizeColumn))
                    }
                }
                self.notifyStatus()
            }
        }
        notifyStatus()
    }

    /// 크기순 정렬 중 폴더 크기 도착마다 전체 재정렬하면 대량 폴더에서 프리즈 — 0.3초 묶음 (QC 위원)
    private func scheduleSizeRebuild() {
        guard !sizeRebuildScheduled else { return }
        sizeRebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.sizeRebuildScheduled = false
            if self.sortKey == .size { self.rebuildItems(preserveSelection: true) }
        }
    }

    /// 파일 크기 + 측정된 폴더 크기 (정렬·상태바 합산 공용)
    private func effectiveSize(_ item: FileItem) -> Int64? {
        if let size = item.fileSize { return Int64(size) }
        switch folderSizes[sizeKey(item.url)] {
        case .measured(let bytes), .partial(let bytes): return bytes
        default: return nil
        }
    }

    /// 표시 항목 계산(필터+정렬) 단일 소스 — rebuildItems와 행 단위 갱신 경로 공용(규칙 4)
    private func computeItems() -> [FileItem] {
        let base: [FileItem]
        if let searchResults {
            base = searchResults                                 // 재귀 파일명 검색 결과(하위 폴더 포함)
        } else if filterText.isEmpty {
            base = allItems
        } else {
            // 재귀 검색 완료 전 빠른 첫 페인 — 현재 폴더 내 매칭만 즉시 표시(곧 검색 결과로 교체)
            base = allItems.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        return DirectoryLister.sorted(base, by: sortKey, ascending: sortAscending,
                                      sizeOf: { [weak self] in self?.effectiveSize($0) })
    }

    /// 필터+정렬을 원본에 재적용 — 검색·정렬·설정 변경이 전부 이 경로 하나를 탄다
    private func rebuildItems(scrollToTop: Bool = false, preserveSelection: Bool = false,
                              scrollToSelection: Bool = false) {
        let selected = preserveSelection
            ? Set(activeSelectionIndexes().compactMap { items.indices.contains($0) ? items[$0].url : nil })
            : []
        items = computeItems()
        reloadActiveViewRaw()
        if preserveSelection {
            // 백그라운드 리빌드(FSEvents·폴더 크기)가 뷰포트를 점프시키지 않도록 스크롤은 정렬 변경만 (검증 minor)
            restoreSelection(urls: selected, scrollToFirst: scrollToSelection)
            // 선택이 실제로 변했을 때만 재발행 — 같은 선택의 재발행은 미리보기 재로드·경로바·트리 reveal을
            // 매번 유발해, 파일이 계속 바뀌는 폴더(빌드·서버)에서 주기적 깜빡임이 됨 (제작자 제보 2026-07-23).
            // Finder 규약: 폴더 내용이 바뀌어도 미리보기는 다시 로드하지 않는다.
            let restored = Set(activeSelectionIndexes().compactMap {
                items.indices.contains($0) ? items[$0].url : nil
            })
            if restored != selected {
                selectionDidSync()   // 컬렉션의 프로그램적 선택은 델리게이트 침묵 — 명시 재발행 (QC 위원)
            }
            // 무변화면 재발행 생략 — 상태바는 아래 공통 notifyStatus()가 갱신
        } else {
            // 테이블 reload는 인덱스 기준 선택을 유지(실측) — 새 목록에서 엉뚱한 행이 선택되는 것 방지 (검증 major)
            setActiveSelection(IndexSet(), scrollToFirst: false)
            selectionDidSync()
            if scrollToTop, !items.isEmpty {
                if viewStyle == .list {
                    tableView.scrollRowToVisible(0)
                } else {
                    collectionView.scroll(.zero)
                }
            }
        }
        notifyStatus()
    }

    func applyFilter(_ text: String) {
        filterText = text
        searchTask?.cancel()
        stopSpotlight()
        searchResults = nil
        rebuildItems()   // 즉시: 현재 폴더 내 매칭(빠른 첫 페인) 또는 전체 복귀
        guard !text.isEmpty, let directory, directory.isFileURL else { return }
        startSpotlightSearch(text, in: directory)
    }

    /// Spotlight(NSMetadataQuery) — Finder와 같은 색인 조회라 즉시·이름+내용 매칭 (제작자 피드백 2026-07-23:
    /// 자작 순회는 대형 트리에서 수십 초 + 내용 미검색 → 교체. 실측: 문서 폴더 0.85초).
    /// 미색인 볼륨 방어 = 0건이면 기존 재귀 이름 검색 폴백(그때만 디스크 순회 — 비용 미미).
    private func startSpotlightSearch(_ text: String, in directory: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [directory]
        query.predicate = NSPredicate(
            format: "(kMDItemFSName CONTAINS[cd] %@) OR (kMDItemTextContent CONTAINS[cd] %@)", text, text)
        spotlightObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            guard let self else { return }
            query.disableUpdates()
            query.stop()
            // 결과 경로만 메인에서 뽑고(가벼움), FileItem 변환(리소스 페치)은 백그라운드로.
            // 주의: NSMetadataItemURLKey는 nil 반환(실측) — kMDItemPath로 뽑아야 한다.
            let urls = (0..<min(query.resultCount, 5000)).compactMap { i -> URL? in
                guard let path = (query.result(at: i) as? NSMetadataItem)?
                    .value(forAttribute: "kMDItemPath") as? String else { return nil }
                return URL(fileURLWithPath: path)
            }
            self.stopSpotlight()
            self.finishSearch(text, in: directory, urls: urls)
        }
        spotlightQuery = query
        query.start()
    }

    /// Spotlight 결과 → FileItem 변환(백그라운드) → 표시. 0건이면 재귀 이름 검색 폴백(미색인 볼륨).
    private func finishSearch(_ text: String, in directory: URL, urls: [URL]) {
        let showHidden = UserDefaults.standard.bool(forKey: SettingsKeys.showHidden)
        searchTask = Task.detached(priority: .userInitiated) {
            let matches = urls.isEmpty
                ? DirectoryLister.recursiveNameSearch(
                    PathPasteboard.normalized(text), in: directory, showHidden: showHidden)
                : DirectoryLister.sorted(urls.map(DirectoryLister.item(for:)))
            let base = directory.resolvingSymlinksInPath().standardizedFileURL.path   // 여기서 1회(오프메인)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.filterText == text, self.directory == directory else { return }   // stale 결과 폐기
                self.searchBase = base
                self.searchResults = matches
                self.rebuildItems(scrollToTop: true)
            }
        }
    }

    private func stopSpotlight() {
        if let observer = spotlightObserver { NotificationCenter.default.removeObserver(observer) }
        spotlightObserver = nil
        spotlightQuery?.stop()
        spotlightQuery = nil
    }

    @objc func goBack(_ sender: Any?) {
        guard let old = directory, let target = backStack.popLast() else { return }
        forwardStack.append(old)
        navigatingViaHistory = true
        show(directory: target)
    }

    @objc func goForward(_ sender: Any?) {
        guard let old = directory, let target = forwardStack.popLast() else { return }
        backStack.append(old)
        navigatingViaHistory = true
        show(directory: target)
    }

    // MARK: 파일 조작 (워게임 [2026-07-16]_wargame_file_operations.md — 덮어쓰기 금지·휴지통 전용)

    private let fileUndoManager = UndoManager()
    override var undoManager: UndoManager? { fileUndoManager }
    private var cutSourceURLs: Set<URL> = []   // 앱 내 잘라내기 상태
    private var editingRow: Int?
    private weak var editingIconItem: FileIconItem?   // 아이콘 뷰 인라인 rename 중인 셀 (제작자 지시 2026-07-25)

    @objc func undo(_ sender: Any?) { fileUndoManager.undo() }
    @objc func redo(_ sender: Any?) { fileUndoManager.redo() }

    private func selectedURLs() -> [URL] {
        if viewStyle == .columns {   // 컬럼 뷰 선택은 깊은 컬럼일 수 있어 items 인덱스와 무관 (제작자 지시 2026-07-25)
            return browser.selectionIndexPaths.compactMap { browser.item(at: $0) as? URL }
        }
        return activeSelectionIndexes().compactMap { items.indices.contains($0) ? items[$0].url : nil }
    }

    /// 목록 우클릭 "추출" — 선택된 착탈식 볼륨 전체 추출(Finder 규약, 제작자 확정 2026-07-25).
    /// 판정 = VolumeMonitor 메모리 조회, 추출 = VolumeEjector 오프메인 합류점(규칙 4).
    @objc func ejectSelectedVolumes(_ sender: Any?) {
        var targets = selectedURLs().filter { VolumeMonitor.shared.isEjectable($0) }
        if targets.isEmpty, let u = (sender as? NSMenuItem)?.representedObject as? URL,
           VolumeMonitor.shared.isEjectable(u) { targets = [u] }   // 선택 밖 항목 우클릭 폴백
        for volume in targets {
            navigateAwayIfInside(volume)   // 자기 볼륨 응시 시 먼저 이탈(미리보기·워처 해제 → 자기유발 busy 예방)
            VolumeEjector.eject(volume, presenter: view.window)
        }
    }

    /// 현재 폴더가 대상 볼륨 하위(또는 자신)면 홈으로 이탈 — 유령 목록·죽은 미리보기 방지.
    /// 목록 추출·트리 추출·Finder 외부 추출(didUnmount) 공용 단일 경로(규칙 4, 제작자 지시 2026-07-25).
    private func navigateAwayIfInside(_ volume: URL) {
        guard let dir = directory, dir.isFileURL else { return }
        let d = dir.standardizedFileURL.path
        let v = volume.standardizedFileURL.path
        if d == v || d.hasPrefix(v.hasSuffix("/") ? v : v + "/") {
            show(directory: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    // MARK: Finder 색상 태그 (제작자 지시 2026-07-23)

    private static func labelNumber(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber ?? 0
    }

    /// 선택 항목의 단일 라벨(전부 같으면 그 번호, 섞였거나 없으면 0) — 스와치 링 표시용
    private func uniformLabel(of urls: [URL]) -> Int {
        let set = Set(urls.map { Self.labelNumber(of: $0) })
        return set.count == 1 ? (set.first ?? 0) : 0
    }

    /// 색상 태그 일괄 적용 — labelNumber 설정(0=지우기)이 Finder tagNames까지 동시 반영(실측).
    /// undo는 이전 라벨을 담은 역적용을 등록(대칭 — redo도 자동). 실패는 표면화.
    private func applyLabels(_ assignments: [(url: URL, label: Int)]) {
        guard !assignments.isEmpty else { return }
        let inverse = assignments.map { (url: $0.url, label: Self.labelNumber(of: $0.url)) }
        var failure: Error?
        for (url, label) in assignments {
            do {
                var u = url
                var values = URLResourceValues()
                values.labelNumber = label
                try u.setResourceValues(values)
            } catch { failure = error }
        }
        fileUndoManager.registerUndo(withTarget: self) { $0.applyLabels(inverse) }
        fileUndoManager.setActionName(L("Tags"))
        reloadCurrentDirectory()   // 목록 행 색 즉시 반영 + onContentsChanged로 트리 틴트 갱신
        if let failure { reportError(failure) }
    }

    /// 컨텍스트 메뉴 색 점 클릭 진입점 (선택 전체에 적용)
    func setTagLabel(_ number: Int, for urls: [URL]) {
        applyLabels(urls.map { (url: $0, label: number) })
    }

    /// 충돌 회피 명명 — 덮어쓰기 절대 없음 ("이름 2", "이름 3"…)
    /// 이름이 이미 쓰이고 있는가 — **링크를 따라가지 않는다**(lstat 기반, 규칙 4로 이름 충돌 판정 단일 창구).
    /// `fileExists`는 대상을 따라가므로 **깨진 심링크를 "없다"고 보고**한다: 그 이름으로 rename하면
    /// POSIX rename이 링크를 조용히 지우고 그 자리를 차지한다(실측 재현 — 링크 소실).
    /// 복사·이동 계열은 반대로 오류 516(이미 존재)으로 실패해 "충돌 회피 명명"이 무력화된다.
    static func nameIsTaken(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func availableURL(for proposed: URL) -> URL {
        guard nameIsTaken(atPath: proposed.path) else { return proposed }
        let parent = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let base = ext.isEmpty ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !nameIsTaken(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// 사용자 표시 이름 → 디스크(POSIX) 이름: macOS 규약상 표시 '/'는 디스크에 콜론 ':'으로 저장(Finder 동일, 실측 확인).
    /// NFC 정규화도 함께. leaf 이름 전용(부모 경로엔 적용 금지). (제작자 지시 2026-07-23)
    static func diskName(fromDisplay name: String) -> String {
        PathPasteboard.normalized(name).replacingOccurrences(of: "/", with: ":")
    }

    /// 디스크(POSIX) 이름 → 사용자 표시 이름: 콜론 ':'을 화면 '/'로 되돌린다(Finder 규약, 트리와 일치).
    static func displayName(fromDisk name: String) -> String {
        name.replacingOccurrences(of: ":", with: "/")
    }

    /// FileManager.moveItem은 대상 경로를 syscall 직전 NFD로 재정규화(함정 ③) — POSIX rename에 NFC 바이트 직접
    static func posixRename(_ url: URL, toName newName: String) throws -> URL {
        let name = diskName(fromDisplay: newName)   // 표시 '/' → 디스크 ':' (제작자 지시 2026-07-23)
        let destPath = url.deletingLastPathComponent().path + "/" + name
        guard !nameIsTaken(atPath: destPath) else {   // 링크 미추종(깨진 심링크 조용한 덮어쓰기 방지)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                          userInfo: [NSLocalizedDescriptionKey: L("An item with the same name already exists.")])
        }
        let rc = url.withUnsafeFileSystemRepresentation { src -> Int32 in
            guard let src else { return -1 }
            return destPath.withCString { rename(src, $0) }
        }
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return URL(fileURLWithPath: destPath)
    }

    private func registerUndoMove(current: URL, original: URL, action: String) {
        fileUndoManager.registerUndo(withTarget: self) { target in
            let restored = (try? FileManager.default.moveItem(at: current, to: original)) != nil
            target.reloadCurrentDirectory()
            if restored { target.registerUndoMove(current: original, original: current, action: action) }
        }
        fileUndoManager.setActionName(action)
    }

    private func registerUndoCreated(_ url: URL, action: String) {
        fileUndoManager.registerUndo(withTarget: self) { target in
            var trashed: NSURL?
            try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            target.reloadCurrentDirectory()
        }
        fileUndoManager.setActionName(action)
    }

    private func reportError(_ error: Error) {
        guard let window = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        if !cutSourceURLs.isEmpty {
            cutSourceURLs = []
            reloadActiveView()
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        cutSourceURLs = Set(selectedURLs())
        reloadActiveView()   // 잘라내기 흐림 반영 — 아이콘 셀 α0.45 동일 규약
    }

    /// 이동/복사 한 건 — 진행률 엔진용 Item (충돌 회피 명명은 실행 시점에 판정)
    private func transferItem(source: URL, into target: URL, isMove: Bool) -> FileOperationEngine.Item {
        FileOperationEngine.Item(name: source.lastPathComponent) { [weak self] in
            let dest = Self.availableURL(for: target.appendingPathComponent(source.lastPathComponent))
            if isMove {
                try FileManager.default.moveItem(at: source, to: dest)
                return { self?.registerUndoMove(current: dest, original: source, action: L("Move")) }
            } else {
                try FileManager.default.copyItem(at: source, to: dest)
                return { self?.registerUndoCreated(dest, action: L("Copy")) }
            }
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let directory, directory.isFileURL,
              let urls = NSPasteboard.general.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        // 다른 앱이 클립보드를 바꿨으면 cut 상태는 무효 — 복사로 강등 (워게임 §4)
        let isMove = !cutSourceURLs.isEmpty && cutSourceURLs == Set(urls)
        let items = urls
            .filter { !(isMove && $0.deletingLastPathComponent() == directory) }   // 같은 폴더 이동 = no-op
            .map { transferItem(source: $0, into: directory, isMove: isMove) }
        operationEngine.run(title: isMove ? L("Moving items…") : L("Copying items…"),
                            items: items, in: view) { [weak self] _ in
            if isMove {
                self?.cutSourceURLs = []
                NSPasteboard.general.clearContents()
            }
            self?.reloadCurrentDirectory()
        }
    }

    @objc func duplicateSelected(_ sender: Any?) {
        let items = selectedURLs().map { url in
            FileOperationEngine.Item(name: url.lastPathComponent) { [weak self] in
                let ext = url.pathExtension
                let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
                let proposedName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
                let dest = Self.availableURL(for: url.deletingLastPathComponent().appendingPathComponent(proposedName))
                try FileManager.default.copyItem(at: url, to: dest)
                return { self?.registerUndoCreated(dest, action: L("Duplicate")) }
            }
        }
        operationEngine.run(title: L("Duplicating items…"), items: items, in: view) { [weak self] _ in
            self?.reloadCurrentDirectory()
        }
    }

    @objc func deleteSelected(_ sender: Any?) {
        let items = selectedURLs().map { url in
            FileOperationEngine.Item(name: url.lastPathComponent) { [weak self] in
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                guard let trashedURL = trashed as URL? else { return nil }
                RestoreRecords.record(trashed: trashedURL, original: url)   // 되돌려 놓기용 원위치 기록
                return { self?.registerUndoMove(current: trashedURL, original: url, action: L("Move to Trash")) }
            }
        }
        operationEngine.run(title: L("Moving to Trash…"), items: items, in: view) { [weak self] _ in
            self?.reloadCurrentDirectory()
        }
    }

    /// File ▸ Restore — 휴지통 항목을 원위치로. TreeFinder가 지운 기록이 있는 항목만 (decisions §14)
    @objc func restoreSelected(_ sender: Any?) {
        let candidates = selectedURLs().compactMap { trashed in
            RestoreRecords.original(for: trashed).map { (trashed: trashed, original: $0) }
        }
        guard !candidates.isEmpty else { return }
        let items = candidates.map { pair in
            FileOperationEngine.Item(name: pair.trashed.lastPathComponent) { [weak self] in
                // 원래 폴더가 사라졌으면 재생성, 같은 이름이 생겼으면 "이름 2" — 덮어쓰기 금지 규약 유지
                try FileManager.default.createDirectory(at: pair.original.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let dest = Self.availableURL(for: pair.original)
                try FileManager.default.moveItem(at: pair.trashed, to: dest)
                RestoreRecords.remove(trashed: pair.trashed)
                return { self?.registerUndoMove(current: dest, original: pair.trashed, action: L("Restore")) }
            }
        }
        operationEngine.run(title: L("Restoring items…"), items: items, in: view) { [weak self] _ in
            self?.reloadCurrentDirectory()
        }
    }

    /// 선택 중 하나라도 되돌려 놓기 기록이 있으면 메뉴 활성
    var canRestoreSelection: Bool {
        selectedURLs().contains { RestoreRecords.original(for: $0) != nil }
    }

    /// 선택 항목 압축 — Finder "압축"처럼 현재 폴더에 zip 생성 (2026-07-16 제작자 지시)
    /// 단일 = "이름.zip", 다중 = "아카이브.zip" — 충돌 시 "이름 2" 규약, 덮어쓰기 없음
    @objc func compressSelected(_ sender: Any?) {
        guard let directory else { return }
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let baseName = urls.count == 1 ? urls[0].lastPathComponent + ".zip" : L("Archive") + ".zip"
        let dest = Self.availableURL(for: directory.appendingPathComponent(baseName))
        let names = urls.map(\.lastPathComponent)
        let item = FileOperationEngine.Item(name: dest.lastPathComponent) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", "-y", "-q", dest.path] + names   // -y = 심볼릭 링크 보존
            process.currentDirectoryURL = directory   // 상대 경로로 담아 아카이브 내부 경로를 깨끗하게
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: dest)   // 실패 잔해 정리
                throw NSError(domain: "TreeFinder", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: L("Couldn't compress the selected items.")])
            }
            return { self?.registerUndoCreated(dest, action: L("Compress")) }
        }
        operationEngine.run(title: L("Compressing items…"), items: [item], in: view) { [weak self] _ in
            self?.reloadCurrentDirectory()
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard let directory, directory.isFileURL else { return }
        do {
            let dest = Self.availableURL(for: directory.appendingPathComponent("untitled folder"))
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            registerUndoCreated(dest, action: L("New Folder"))
            pendingRenameURL = dest   // 생성 직후 이름변경 상태로 (Finder 규약, 제작자 지시 2026-07-23)
        } catch { reportError(error) }
        reloadCurrentDirectory()
    }

    @objc func renameSelected(_ sender: Any?) {
        guard searchResults == nil else { return }   // 검색 결과 중 rename 비활성 (제작자 지시 2026-07-23)
        if viewStyle == .list {
            let row = tableView.selectedRow
            // makeIfNecessary: true — 방금 스크롤해 보이게 만든 행이라도 셀 뷰 생성은 다음 화면 갱신
            // 주기에 일어나, false면 편집이 조용히 취소된다(제작자 제보 2026-07-26 실측). 대상은 1행뿐.
            guard row >= 0,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            editingRow = row
            field.isEditable = true
            field.delegate = self
            view.window?.makeFirstResponder(field)
            // 확장자 앞부분만 선택 (Finder 규약)
            if let editor = field.currentEditor() {
                let name = field.stringValue as NSString
                let dot = name.range(of: ".", options: .backwards)
                editor.selectedRange = NSRange(location: 0, length: dot.location == NSNotFound ? name.length : dot.location)
            }
        } else if viewStyle == .icons {   // 아이콘 뷰 인라인 rename (제작자 지시 2026-07-25) — 갤러리는 라벨 없어 제외
            let selection = activeSelectionIndexes()
            guard selection.count == 1, let index = selection.first, items.indices.contains(index) else { return }
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
            guard let cell = collectionView.item(at: indexPath) as? FileIconItem else { return }
            editingRow = index
            editingIconItem = cell
            cell.beginEditing(fullName: items[index].name, delegate: self)   // 확장자 앞부분 선택은 셀 내부
        }
    }

    /// 파일 조작 후 현재 폴더 재리스팅 (선택 유지).
    /// 행 구성(URL 순서)이 그대로면 **바뀐 행만 조용히 갱신** — 전체 reloadData는 가시 행 전부(아이콘 포함)를
    /// 재생성해, 파일이 계속 수정되는 폴더에서 주기적 깜빡임이 됨(제작자 제보 2026-07-23, Finder 규약).
    /// 크기 캐시 무효화·재스캔도 구성 변화 때만(메타 변경마다 대형 폴더 재스캔 방지).
    func reloadCurrentDirectory() {
        // 네트워크 브라우즈(비파일 센티널)는 이 경로를 타면 안 된다 — 실측상 contentsOfDirectory가 오류 260을
        // 던지므로, 아래 오류 표면화가 가상 목록 위에 배너를 띄우게 된다(지금까진 try?가 우연히 막고 있었다).
        guard let directory, directory.isFileURL else { return }
        onContentsChanged?(directory)   // 트리 노드 자동 갱신 — 자체 변화 감지 내장
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let listed: [FileItem]
            do {
                listed = try await DirectoryLister.list(
                    directory, showHidden: UserDefaults.standard.bool(forKey: SettingsKeys.showHidden))
            } catch is CancellationError {
                return
            } catch {
                // 갱신 실패(폴더 삭제·권한 상실 등)를 삼키면 사라진 목록이 그대로 남는다 — show()와 동일하게 표면화
                guard let self, !Task.isCancelled else { return }
                self.allItems = []
                self.rebuildItems()
                self.showListingFailure(error)
                self.pendingRenameURL = nil          // 실패했으면 이름변경 진입 예약도 폐기(다음 폴더로 새지 않게)
                if self.viewStyle == .columns { self.reloadBrowser() }   // 컬럼 뷰에 stale 컬럼이 남지 않게
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.showListingFailure(nil)   // 이전 실패 배너 해제
            let oldItems = self.items
            self.allItems = listed
            let newItems = self.computeItems()
            if newItems.map(\.url) == oldItems.map(\.url) {
                var changedRows = IndexSet()
                for (i, item) in newItems.enumerated() where item != oldItems[i] { changedRows.insert(i) }
                self.items = newItems
                if !changedRows.isEmpty { self.reloadRows(changedRows) }   // 수정일 등 메타만 제자리 교체
                self.notifyStatus()
            } else {
                let prefix = self.sizeKey(directory) + "/"
                self.folderSizes = self.folderSizes.filter {
                    !($0.key.hasPrefix(prefix) && !$0.key.dropFirst(prefix.count).contains("/"))
                }
                Task { await SizeService.shared.invalidate(childrenOf: directory) }
                self.rebuildItems(preserveSelection: true)
                self.requestFolderSizes()
                // 컬럼 뷰: 루트 구성 변화 시에만 브라우저 재적재(메타 변화엔 안 함 — 깜빡임 방지).
                // 한계(v1): 재적재는 컬럼 0으로 접힘(깊은 컬럼 선택 소실). 탐색·미리보기·열기는 무영향.
                if self.viewStyle == .columns { self.reloadBrowser() }
            }
            self.beginPendingRename()   // 새 폴더 생성 직후 이름변경 진입 (제작자 지시 2026-07-23)
        }
    }

    /// 지정 행만 다시 그리기 — 선택 보존(컬렉션은 reload가 선택을 지울 수 있어 재적용).
    /// **편집 중인 행은 제외**: 행을 다시 그리면 AppKit이 필드 에디터의 first responder를 뺏어
    /// 인라인 이름변경이 즉시 닫힌다(제작자 제보 2026-07-26 — 새 폴더의 크기 결과가 수십 ms 만에
    /// 도착해 편집을 죽이던 스택 실측). 보류분은 편집 종료 시 pendingRefresh가 흡수.
    private func reloadRows(_ rows: IndexSet, columns: IndexSet? = nil) {
        var rows = rows
        if let editingRow, rows.contains(editingRow) {
            rows.remove(editingRow)
            pendingRefresh = true
        }
        guard !rows.isEmpty else { return }
        if viewStyle == .list {
            tableView.reloadData(forRowIndexes: rows,
                                 columnIndexes: columns ?? IndexSet(integersIn: 0..<tableView.numberOfColumns))
        } else {
            let paths = Set(rows.map { IndexPath(item: $0, section: 0) })
            let selection = collectionView.selectionIndexPaths
            collectionView.reloadItems(at: paths)
            collectionView.selectItems(at: selection, scrollPosition: [])
        }
    }

    /// 새 폴더 생성 후 리로드가 끝나면 그 행을 선택하고 이름변경 편집에 진입 (Finder 규약)
    private func beginPendingRename() {
        guard let url = pendingRenameURL else { return }
        pendingRenameURL = nil
        // 디렉토리 URL의 후행 슬래시·표준화 차이로 == 가 어긋나므로 경로로 비교 (실측)
        let target = url.standardizedFileURL.path
        // 리스트·아이콘 공용 — 갤러리는 인라인 라벨이 없어 편집 진입 없이 선택만 (제작자 지시 2026-07-25)
        guard viewStyle == .list || viewStyle == .icons,
              let row = items.firstIndex(where: { $0.url.standardizedFileURL.path == target }) else { return }
        setActiveSelection(IndexSet(integer: row), scrollToFirst: true)
        DispatchQueue.main.async { [weak self] in self?.renameSelected(nil) }   // 셀 생성 후 편집 진입
    }

    /// ⌘O — 선택 항목 열기 (더블클릭과 동일: 단일 폴더 = 이동, 파일 = 실행)
    func openSelected() {
        let selected = activeSelectionIndexes().compactMap { items.indices.contains($0) ? items[$0] : nil }
        // 네트워크 컴퓨터 = 연결로 인터셉트 — NSWorkspace.open은 Finder가 마운트 UI를 탈취 (워게임 network_browse)
        if let network = selected.first(where: { !$0.url.isFileURL }) {
            connectToNetworkComputer(network)
            return
        }
        if selected.count == 1, let only = selected.first, only.isDirectory {
            show(directory: only.url)
            return
        }
        for item in selected where !item.isDirectory { openFile(item.url) }
    }

    /// 파일 열기 단일 경로(더블클릭·⌘O 공용) — .sh는 앱 연결 대신 우측 터미널 패널에서 실행 (제작자 지시 2026-07-21)
    private func openFile(_ url: URL) {
        // Finder 별칭(alias) 파일이 폴더를 가리키면 앱 안에서 연다 (제작자 확정 2026-08-06).
        // 그냥 두면 NSWorkspace.open이 Finder에 넘겨 파일 매니저 밖으로 튕기고, 죽은 볼륨 별칭은
        // false만 돌려주고 아무 일도 안 일어난다(조용한 실패 — 둘 다 실측).
        if let target = DirectoryLister.aliasTarget(url),
           (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            show(directory: target)
            return
        }
        if url.pathExtension.lowercased() == "sh", let onRunScript {
            onRunScript(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// ⌘W — 활성 탭 닫기. 마지막 탭이면 false 반환(호출자가 창을 닫음)
    @discardableResult
    func closeActiveTab() -> Bool {
        guard tabURLs.count > 1 else { return false }
        closeTab(activeTab)
        return true
    }

    // Window 메뉴 — 탭 순환·목록 (⌃⇥ / ⌃⇧⇥ / ⌘1…)
    var tabTitles: [String] {
        tabURLs.map { $0.isFileURL ? FileManager.default.displayName(atPath: $0.path) : L("Network") }
    }
    var activeTabIndex: Int { activeTab }
    func activateTab(_ index: Int) { selectTab(index) }
    func selectNextTab() {
        guard tabURLs.count > 1 else { return }
        selectTab((activeTab + 1) % tabURLs.count)
    }
    func selectPreviousTab() {
        guard tabURLs.count > 1 else { return }
        selectTab((activeTab - 1 + tabURLs.count) % tabURLs.count)
    }

    // MARK: FSEvents 자동 새로고침 (kqueue 금지 — TCC 프롬프트 유발, PLAYBOOK 2부 §1-1)

    private func restartWatcher(for url: URL) {
        stopWatcher()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // 주의: FSEvents는 재귀 감시 — 홈을 보면 ~ 전체 트리 이벤트가 흘러들어 리로드 루프가 됨(실측).
        // 이벤트 경로가 감시 폴더 "자신"(=직계 자식 변경) 또는 "직계 자식 폴더 바로 안"일 때만 리로드 —
        // 후자는 자식 폴더의 태그·커스텀 아이콘(Icon\r) 변경을 트리·목록에 반영하기 위함
        // (제작자 제보 2026-07-23: 커스텀 아이콘 삭제가 트리에 미반영). 더 깊은 경로는 계속 차단(폭주 방지).
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let target = Unmanaged<FileListViewController>.fromOpaque(info).takeUnretainedValue()
            guard let watched = target.directory?.standardizedFileURL.path else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let watchedNFC = PathPasteboard.normalized(watched)
            for path in paths.prefix(Int(numEvents)) {
                let eventURL = URL(fileURLWithPath: path).standardizedFileURL
                let eventDir = PathPasteboard.normalized(eventURL.path)
                let eventParent = PathPasteboard.normalized(eventURL.deletingLastPathComponent().path)
                if eventDir == watchedNFC {
                    target.directoryDidChange()   // 직계 자식 변경 = 전체 리로드
                    return
                }
                if eventParent == watchedNFC {
                    // 자식 폴더 "안" 변경 = 트리 메타(태그·Icon\r)만 재평가 — 전체 리로드 금지.
                    // 개발 폴더 등에서 하위 활동이 잦으면 목록·미리보기가 주기적으로 깜빡이는 부작용 실측
                    // (제작자 제보 2026-07-23) — 트리는 변화 있을 때만 다시 그림.
                    target.childMetaDidChange()
                    return
                }
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,   // 0.5초 코얼레싱 — 연속 변경 폭주 방지
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func stopWatcher() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    private func directoryDidChange() {
        // EditGuard: 인라인 rename 중엔 리스트를 다시 그리지 않는다(원본 1.1.15 계열 — PLAYBOOK 3부 §3.1)
        guard editingRow == nil else {
            pendingRefresh = true
            return
        }
        reloadCurrentDirectory()
    }

    /// 자식 폴더 내부 변경 — 트리 노드 메타(태그·커스텀 아이콘)만 재평가. 목록·미리보기는 건드리지 않는다.
    private func childMetaDidChange() {
        guard let directory, directory.isFileURL else { return }
        onContentsChanged?(directory)
    }

    deinit {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func notifyStatus() {   // 듀얼 페인 활성 전환 시 상태바 재발행에도 사용
        let selected = activeSelectionIndexes()
        let bytes = selected.reduce(Int64(0)) {
            $0 + (items.indices.contains($1) ? (effectiveSize(items[$1]) ?? 0) : 0)
        }
        onStatusChange?(items.count, selected.count, bytes, pendingScanCount > 0)
    }

    @objc func goUp(_ sender: Any?) {
        guard let directory, directory.isFileURL, directory.path != "/" else { return }
        show(directory: directory.deletingLastPathComponent())
    }

    /// 도구모음 정렬 메뉴 → 헤더 클릭과 동일 경로(sortDescriptors)로 — 헤더 표시 자동 동기화
    func applySort(raw: String) {
        guard let key = SortKey(rawValue: raw) else { return }
        let ascending = key == sortKey ? !sortAscending : true
        tableView.sortDescriptors = [NSSortDescriptor(key: raw, ascending: ascending)]
    }

    /// 선택 항목의 경로를 클립보드로 — PathPasteboard 경유(NFC 보정, decisions.md §5)
    @objc func copyPath(_ sender: Any?) {
        let rows = activeSelectionIndexes()
        let paths: [String]
        if rows.isEmpty {
            guard let directory else { return }
            paths = [directory.path]   // 선택이 없으면 현재 폴더 경로
        } else {
            paths = rows.compactMap { items.indices.contains($0) ? items[$0].url.path : nil }
        }
        PathPasteboard.copy(paths.joined(separator: "\n"))
    }

    @objc private func didDoubleClick(_ sender: Any?) {
        guard tableView.clickedRow >= 0, items.indices.contains(tableView.clickedRow) else { return }
        let item = items[tableView.clickedRow]
        if !item.url.isFileURL {
            connectToNetworkComputer(item)   // 네트워크 컴퓨터 (워게임 network_browse)
            return
        }
        if item.isDirectory {
            show(directory: item.url)
        } else {
            openFile(item.url)
        }
    }

    // MARK: 컨텍스트 메뉴 (원본 레퍼런스 구성 — DESIGN_REFERENCE §13, 미구현 파일 조작은 비활성)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerColumnMenu {   // 헤더 우클릭 = 체크마크만 갱신(항목 재구성 아님, 제작자 지시 2026-07-25)
            updateHeaderColumnMenuStates()
            return
        }
        menu.removeAllItems()
        if isNetworkBrowse {   // 가상 항목 — 파일 조작 메뉴 금지, 연결만 (워게임 network_browse)
            guard let row = activeClickedIndex(), items.indices.contains(row) else { return }
            if !activeSelectionIndexes().contains(row) {
                setActiveSelection(IndexSet(integer: row), scrollToFirst: false)
                if viewStyle != .list { selectionDidSync() }
            }
            let connect = NSMenuItem(title: L("Connect"), action: #selector(connectClicked(_:)), keyEquivalent: "")
            connect.target = self
            connect.representedObject = items[row].name
            connect.image = NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: L("Connect"))
            menu.addItem(connect)
            return
        }
        let item: FileItem
        if viewStyle == .columns {
            // 컬럼 뷰: 우클릭 대상 = 현재 브라우저 선택(셀 클릭이 선택을 바꾼 뒤 메뉴가 뜸). 선택 없으면 배경 메뉴.
            guard let selectedURL = selectedBrowserURL() else { buildBackgroundMenu(menu); return }
            item = browserItem(selectedURL)
        } else {
            guard let row = activeClickedIndex(), items.indices.contains(row) else {
                buildBackgroundMenu(menu)   // 빈 영역 우클릭
                return
            }
            if !activeSelectionIndexes().contains(row) {   // Finder 규약: 우클릭 항목을 선택으로
                setActiveSelection(IndexSet(integer: row), scrollToFirst: false)
                if viewStyle != .list { selectionDidSync() }   // 컬렉션 프로그램적 선택 = 델리게이트 침묵
            }
            item = items[row]
        }
        let url = item.url

        func entry(_ title: String, _ symbol: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = action == nil ? nil : self
            mi.representedObject = url
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            mi.isEnabled = enabled && action != nil   // action 없음 = Phase 2 예정(정직한 비활성)
            return mi
        }

        menu.addItem(entry(L("Open"), "arrow.up.right.square", #selector(openClicked(_:))))
        let openWith = entry(L("Open With"), "square.dashed", #selector(noop))
        openWith.submenu = openWithSubmenu(for: url)
        menu.addItem(openWith)
        if item.isPackage {
            menu.addItem(entry(L("Show Package Contents"), "shippingbox", #selector(showPackageContents(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(entry(L("Open in New Tab"), "plus.square.on.square",
                           #selector(openInNewTabClicked(_:)), enabled: item.isDirectory))
        menu.addItem(entry(L("Open in New Window"), "macwindow.badge.plus",
                           #selector(openInNewWindowClicked(_:)), enabled: item.isDirectory))
        menu.addItem(entry(L("Show in Finder"), "magnifyingglass.circle", #selector(showInFinderClicked(_:))))
        menu.addItem(entry(L("Open in Terminal"), "terminal",
                           #selector(openInTerminalClicked(_:)), enabled: item.isDirectory))
        // 착탈식 볼륨(네트워크·USB·외장·디스크이미지) = 추출 (제작자 지시 2026-07-25).
        // 판정은 VolumeMonitor 메모리 조회 — 죽은 마운트에도 메인 스레드 stat 없음(§3/§6, 위원회 must-fix).
        if VolumeMonitor.shared.isEjectable(url) {
            menu.addItem(.separator())
            menu.addItem(entry(L("Eject"), "eject", #selector(ejectSelectedVolumes(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(entry(L("Cut"), "scissors", #selector(cut(_:))))
        menu.addItem(entry(L("Copy"), "doc.on.doc", #selector(copy(_:))))
        let canPaste = NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        menu.addItem(entry(L("Paste"), "doc.on.clipboard", #selector(paste(_:)), enabled: canPaste))
        menu.addItem(entry(L("Duplicate"), "square.filled.on.square", #selector(duplicateSelected(_:))))
        menu.addItem(entry(L("Compress"), "doc.zipper", #selector(compressSelected(_:))))
        menu.addItem(.separator())
        // 인라인 rename = 리스트 + 아이콘(갤러리는 라벨 없어 제외) (제작자 지시 2026-07-25)
        menu.addItem(entry(L("Rename"), "character.cursor.ibeam", #selector(renameSelected(_:)),
                           enabled: viewStyle == .list || viewStyle == .icons))
        menu.addItem(entry(L("Move to Trash"), "trash", #selector(deleteSelected(_:))))
        if RestoreRecords.original(for: url) != nil {   // TreeFinder가 지운 휴지통 항목만 (decisions §14)
            menu.addItem(entry(L("Restore"), "arrow.uturn.backward", #selector(restoreSelected(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(entry(L("Add to Favorites"), "pin",
                           #selector(addToFavoritesClicked(_:)), enabled: item.isDirectory))
        menu.addItem(entry(L("Share"), "square.and.arrow.up", #selector(shareClicked(_:))))
        menu.addItem(entry(L("Copy Path"), "link", #selector(copyPath(_:))))
        menu.addItem(.separator())
        // Finder 색상 태그 — 선택 전체에 색 점 클릭으로 일괄 지정/해제 (제작자 지시 2026-07-23)
        let tagURLs = selectedURLs()
        let tagHeader = NSMenuItem(title: L("Tags"), action: nil, keyEquivalent: "")
        tagHeader.isEnabled = false
        menu.addItem(tagHeader)
        let swatchItem = NSMenuItem()
        swatchItem.view = TagSwatchView(current: uniformLabel(of: tagURLs)) { [weak self] label in
            self?.setTagLabel(label, for: tagURLs)
        }
        menu.addItem(swatchItem)
        menu.addItem(.separator())
        menu.addItem(entry(L("Get Info"), "info.circle", #selector(getInfoSelected(_:))))
    }

    // 빈 영역 우클릭 — 제작자 캡처 구성 그대로 (2026-07-16, decisions §18)
    private func buildBackgroundMenu(_ menu: NSMenu) {
        func entry(_ title: String, _ symbol: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            mi.isEnabled = enabled
            return mi
        }
        menu.addItem(entry(L("New Folder"), "folder.badge.plus", #selector(newFolder(_:))))
        menu.addItem(entry(L("New Text Document"), "doc.badge.plus", #selector(newTextDocument(_:))))
        let canPaste = NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        menu.addItem(entry(L("Paste"), "doc.on.clipboard", #selector(paste(_:)), enabled: canPaste))
        menu.addItem(.separator())
        menu.addItem(entry(L("Open in New Tab"), "plus.square.on.square", #selector(openCurrentInNewTab(_:))))
        menu.addItem(entry(L("Open in Terminal"), "terminal", #selector(openCurrentInTerminal(_:))))
        menu.addItem(.separator())

        // Sort By ▸ — 헤더 클릭·도구모음과 동일 경로(applySort), 현재 키 체크
        let sortItem = entry(L("Sort By"), "arrow.up.arrow.down", nil)
        let sortSubmenu = NSMenu()
        for (title, key) in [(L("Name"), SortKey.name), (L("Date Modified"), .dateModified),
                             (L("Date Created"), .dateCreated), (L("Size"), .size), (L("Kind"), .kind)] {
            let mi = NSMenuItem(title: title, action: #selector(sortFromMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key.rawValue
            mi.state = key == sortKey ? .on : .off
            sortSubmenu.addItem(mi)
        }
        sortItem.submenu = sortSubmenu
        menu.addItem(sortItem)

        // View Options ▸ — View 메뉴 라디오와 동일 경로(setViewStyle → onViewStyleChange 크롬 동기화)
        let viewItem = entry(L("View Options"), "square.grid.2x2", nil)
        let viewSubmenu = NSMenu()
        for (title, style) in [(L("Icons"), ViewStyle.icons), (L("List"), .list), (L("Gallery"), .gallery)] {
            let mi = NSMenuItem(title: title, action: #selector(viewStyleFromMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = style.rawValue
            mi.state = style == viewStyle ? .on : .off
            viewSubmenu.addItem(mi)
        }
        viewItem.submenu = viewSubmenu
        menu.addItem(viewItem)

        menu.addItem(entry(L("Refresh"), "arrow.clockwise", #selector(refreshClicked(_:))))
        menu.addItem(.separator())
        menu.addItem(entry(L("Get Info"), "info.circle", #selector(getInfoCurrentFolder(_:))))
    }

    @objc private func connectClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let item = items.first(where: { $0.name == name }) else { return }
        connectToNetworkComputer(item)
    }

    @objc private func openCurrentInTerminal(_ sender: Any?) {
        guard let directory else { return }
        ExternalOpen.inTerminal(directory)
    }

    @objc private func openCurrentInNewTab(_ sender: Any?) {
        guard let directory else { return }
        addTab(showing: directory)
    }

    @objc private func sortFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        applySort(raw: raw)
    }

    @objc private func viewStyleFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = ViewStyle(rawValue: raw) else { return }
        setViewStyle(style)
    }

    @objc private func refreshClicked(_ sender: Any?) {
        reloadCurrentDirectory()
    }

    @objc private func getInfoCurrentFolder(_ sender: Any?) {
        guard let directory, directory.isFileURL else { return }
        GetInfoWindowController.show(for: directory)
    }

    /// 정보 가져오기 — 선택 없으면 현재 폴더(Finder ⌘I 규약), 항목당 창·상한 10 (decisions §17)
    @objc func getInfoSelected(_ sender: Any?) {
        var urls = selectedURLs().filter(\.isFileURL)
        if urls.isEmpty, let directory, directory.isFileURL { urls = [directory] }
        guard !urls.isEmpty else { return }
        let cap = 10
        if urls.count > cap {
            urls = Array(urls.prefix(cap))
            let alert = NSAlert()
            alert.messageText = String(format: L("Showing info for the first %d items."), cap)
            if let window = view.window { alert.beginSheetModal(for: window) }
        }
        urls.forEach(GetInfoWindowController.show(for:))
    }

    /// Windows Explorer의 "New ▸ Text Document" (원본 1.5.6 — undo는 파일이 빈 동안만 제거)
    @objc func newTextDocument(_ sender: Any?) {
        guard let directory, directory.isFileURL else { return }
        let dest = Self.availableURL(for: directory.appendingPathComponent("untitled.txt"))
        // createFile은 실패를 Bool로만 알린다 — 삼키면 "눌러도 아무 일도 안 일어나는" 조용한 실패가 된다
        guard FileManager.default.createFile(atPath: dest.path, contents: Data()) else {
            reportError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                userInfo: [NSLocalizedDescriptionKey:
                                            String(format: L("Can't create “%@”."), dest.lastPathComponent)]))
            return
        }
        fileUndoManager.registerUndo(withTarget: self) { target in
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size == 0 { try? FileManager.default.removeItem(at: dest) }   // 내용이 생겼으면 지우지 않음
            target.reloadCurrentDirectory()
        }
        fileUndoManager.setActionName(L("New Text Document"))
        pendingRenameURL = dest   // 생성 직후 이름변경 상태로 — 새 폴더와 동일 (Finder 규약, 제작자 지시 2026-07-25)
        reloadCurrentDirectory()
    }

    private func openWithSubmenu(for url: URL) -> NSMenu {
        let submenu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        func appEntry(_ app: URL, isDefault: Bool) -> NSMenuItem {
            let name = FileManager.default.displayName(atPath: app.path)
            let mi = NSMenuItem(title: isDefault ? String(format: L("%@ (default)"), name) : name,
                                action: #selector(openWithApp(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [url, app]
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            return mi
        }
        if let defaultApp {
            submenu.addItem(appEntry(defaultApp, isDefault: true))
            submenu.addItem(.separator())
        }
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) where app != defaultApp {
            submenu.addItem(appEntry(app, isDefault: false))
        }
        let other = NSMenuItem(title: L("Other…"), action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = url
        submenu.addItem(other)
        return submenu
    }

    @objc private func noop() {}   // Open With 부모 항목 활성화용

    @objc private func openClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1],
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openWithOther(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func showPackageContents(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        show(directory: url)
    }

    @objc private func openInNewTabClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        addTab(showing: url)
    }

    @objc private func openInNewWindowClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainWindowController.openNewWindow(directory: url)
    }

    @objc private func showInFinderClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openInTerminalClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ExternalOpen.inTerminal(url)
    }

    @objc private func addToFavoritesClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onAddFavorite?(url)
    }

    private var sharingPicker: NSSharingServicePicker?
    @objc private func shareClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard let index = activeSelectionIndexes().first else { return }
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker
        // 앵커는 활성 뷰 기준 — 숨은 테이블 rect에 띄우면 위치가 엉킴 (QC 위원)
        if viewStyle == .list {
            picker.show(relativeTo: tableView.rect(ofRow: index), of: tableView, preferredEdge: .minY)
        } else {
            picker.show(relativeTo: collectionView.frameForItem(at: index),
                        of: collectionView, preferredEdge: .minY)
        }
    }

    // MARK: 드래그 앤 드롭 (원본 1.1.10 규약 — 같은 볼륨=이동·다른 볼륨=복사·Option=복사 강제)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // 네트워크 컴퓨터 등 비파일 항목은 드래그 제외 (워게임 network_browse)
        guard items.indices.contains(row), items[row].url.isFileURL else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard directory?.isFileURL == true,
              info.draggingPasteboard.canReadObject(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        // 폴더 행 위가 아니면 전체(=현재 폴더) 드롭으로 승격
        if !(dropOperation == .on && items.indices.contains(row) && items[row].isDirectory) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let baseDirectory = directory,
              let sources = info.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !sources.isEmpty else { return false }
        let target = (dropOperation == .on && items.indices.contains(row) && items[row].isDirectory)
            ? items[row].url
            : baseDirectory
        performDrop(sources, into: target, forceCopy: NSEvent.modifierFlags.contains(.option),
                    stackSource: info.draggingSource as? DropStackView)
        return true
    }

    /// 드롭 가드 비교 키(규칙 4 — performDrop·runStackDrop 공용): 심링크 해석(§32) + 표준화 + NFC.
    /// 셋 다 필요하다 — 링크/실경로 표기 차이는 "같은 폴더 no-op"과 "자기 하위 금지"를 조용히 무력화하고,
    /// 그 결과가 파일 개명(a.txt → a 2.txt)이나 중첩 폴더 폭주로 나타난다(실측).
    private static func dropKey(_ url: URL) -> String {
        PathPasteboard.normalized(DirectoryLister.resolvedFolder(url).standardizedFileURL.path)
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let idA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
              let idB = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier else { return false }
        return idA.isEqual(idB)
    }

    func performDrop(_ sources: [URL], into target: URL, forceCopy: Bool, stackSource: DropStackView? = nil) {
        // 타깃이 심링크 폴더면 먼저 해석한다(§32) — 안 하면 아래 가드 3개가 전부 어긋난다(실측):
        // ① sameVolume이 링크가 있는 볼륨을 봐서 "다른 볼륨=복사"가 이동으로 뒤집힘 → **원본 소실**
        // ② 같은 폴더 no-op 판정 실패 → moveItem이 충돌 회피 명명을 타 'a.txt' → 'a 2.txt' 개명
        // ③ 자기 하위 금지 판정(문자열 접두) 실패 → 자기 자신 링크에 복사 시 177단 중첩 폴더 잔해
        let target = DirectoryLister.resolvedFolder(target)
        // 드롭스택 출처 = 이동/복사 선택 메뉴 경유 (제작자 확정 2026-07-23 — 암묵 이동 금지)
        if let stack = stackSource {
            presentStackDropMenu(sources, into: target, stack: stack)
            return
        }
        var moving = false
        let targetKey = Self.dropKey(target)
        let items: [FileOperationEngine.Item] = sources.compactMap { source in
            let sourceKey = Self.dropKey(source)
            guard sourceKey != targetKey else { return nil }
            guard !targetKey.hasPrefix(sourceKey + "/") else { return nil }       // 자기 하위로 이동 금지
            let isMove = !forceCopy && sameVolume(source, target)                 // 1.1.10 규약
            guard !(isMove && Self.dropKey(source.deletingLastPathComponent()) == targetKey) else { return nil }   // 같은 폴더 = no-op
            if isMove { moving = true }
            return transferItem(source: source, into: target, isMove: isMove)
        }
        operationEngine.run(title: moving ? L("Moving items…") : L("Copying items…"),
                            items: items, in: view) { [weak self] _ in
            self?.reloadCurrentDirectory()
        }
    }

    /// 드롭스택 드롭 컨텍스트 — 메뉴 항목의 representedObject로 전달 (공유 상태 없음)
    private final class StackDropRequest: NSObject {
        let sources: [URL], target: URL, move: Bool
        weak var stack: DropStackView?
        init(sources: [URL], target: URL, move: Bool, stack: DropStackView) {
            self.sources = sources; self.target = target; self.move = move; self.stack = stack
        }
    }

    /// 드롭스택 드롭 = "여기로 이동/여기로 복사/취소" 메뉴 (탐색기 우클릭 드래그 규약 — 제작자 컨펌 2026-07-23)
    private func presentStackDropMenu(_ sources: [URL], into target: URL, stack: DropStackView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, move) in [(L("Move Here"), true), (L("Copy Here"), false)] {
            let item = NSMenuItem(title: title, action: #selector(stackDropChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = StackDropRequest(sources: sources, target: target, move: move, stack: stack)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Cancel"), action: nil, keyEquivalent: ""))   // 선택 = 닫힘만
        // 드래그 세션이 완전히 끝난 다음 틱에 커서 위치로 표시 — 세션 진행 중 popUp은 이벤트 루프 충돌
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            let point = self.view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            menu.popUp(positioning: nil, at: point, in: self.view)
        }
    }

    @objc private func stackDropChosen(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? StackDropRequest, let stack = request.stack else { return }
        runStackDrop(request.sources, into: request.target, move: request.move, stack: stack)
    }

    #if DEBUG
    /// TF_STACK_DROP — 메뉴 선택 이후 실행 경로를 직접 구동(팝업 메뉴는 자동화 불가)
    func debugRunStackDrop(_ sources: [URL], into target: URL, move: Bool, stack: DropStackView) {
        runStackDrop(sources, into: target, move: move, stack: stack)
    }

    /// TF_SYMLINK — 드래그앤드롭과 동일 경로(performDrop)로 심링크 폴더에 드롭 (볼륨 오판·no-op 가드 실측)
    func debugPerformDrop(_ sources: [URL], into target: URL) {
        performDrop(sources, into: target, forceCopy: false)
    }

    /// TF_SYMLINK — 현재 목록 항목 이름(리스팅 성공 여부 실측)
    func debugItemNames() -> [String] { items.map(\.name) }

    /// TF_LISTING_FAIL — 오류 배너 문구(숨김이면 빈 문자열)
    func debugMessageText() -> String { messageLabel.isHidden ? "" : messageLabel.stringValue }
    #endif

    /// 명시 선택된 이동/복사 실행 — 이동은 크로스 볼륨도 이동(FileManager.moveItem = 복사+원본 제거,
    /// 1.1.10 "다른 볼륨=복사 강등"은 암묵 드래그 한정·명시 선택은 사용자 의사 우선 — QC 위원).
    /// 완료 시 스택 비움(이동·복사 공통 — 제작자 확정 2026-07-23). 취소·오류 중단 시엔 스택 유지 —
    /// 부분 이동분은 다음 드래그의 pruneMissing이 정리 (적대검증 반영).
    private func runStackDrop(_ sources: [URL], into target: URL, move: Bool, stack: DropStackView) {
        // 같은 폴더 판정은 정규화 경로 비교 — URL ==는 후행 슬래시·NFC/NFD 표기 차이에 오판,
        // 어긋나면 이동이 충돌 회피 명명을 타고 "이름 2" 개명이 됨 (적대검증 반영)
        let targetKey = Self.dropKey(target)
        let items: [FileOperationEngine.Item] = sources.compactMap { source in
            let sourceKey = Self.dropKey(source)
            guard sourceKey != targetKey else { return nil }
            guard !targetKey.hasPrefix(sourceKey + "/") else { return nil }   // 자기 하위로 이동 금지
            let parentKey = Self.dropKey(source.deletingLastPathComponent())
            guard !(move && parentKey == targetKey) else { return nil }   // 같은 폴더 이동 = no-op
            return transferItem(source: source, into: target, isMove: move)
        }
        guard !items.isEmpty else { return }   // 전부 no-op = 스택 유지
        operationEngine.run(title: move ? L("Moving items…") : L("Copying items…"),
                            items: items, in: view) { [weak self, weak stack] succeeded in
            self?.reloadCurrentDirectory()
            if succeeded { stack?.clear() }
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    /// 태그 풀 로우 컬러 (decisions §9 ③ — Path Finder 스타일, 시스템 라벨 색 번호 기반)
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("tagRow")
        let rowView = tableView.makeView(withIdentifier: id, owner: nil) as? TagRowView ?? {
            let view = TagRowView()
            view.identifier = id
            return view
        }()
        let label = items.indices.contains(row) ? items[row].labelNumber : 0
        let colors = NSWorkspace.shared.fileLabelColors
        rowView.tagColor = (label > 0 && label < colors.count)
            ? colors[label].withAlphaComponent(0.30)
            : nil
        return rowView
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        sortKey = key
        sortAscending = descriptor.ascending
        rebuildItems(preserveSelection: true, scrollToSelection: true)   // 재정렬 후 선택 가시화 (Finder 규약)
    }

    /// 컬럼 텍스트 단일 소스 — 셀 렌더와 적정 폭 계산(구분선 더블클릭)이 같은 경로 (규칙 4)
    private func columnText(for item: FileItem, key: String) -> String? {
        switch key {
        case "name":
            let showExtensions = UserDefaults.standard.object(forKey: SettingsKeys.alwaysExtensions) as? Bool ?? true
            return showExtensions
                ? Self.displayName(fromDisk: item.name)                    // 디스크 ':' → 표시 '/' (제작자 지시 2026-07-23)
                : FileManager.default.displayName(atPath: item.url.path)   // hide-extension 존중(':'→'/' 내장)
        case "dateModified": return Self.dateText(item.dateModified)
        case "dateCreated": return Self.dateText(item.dateCreated)
        case "dateLastOpened": return Self.dateText(item.dateLastOpened)   // 최근 사용일 (제작자 지시 2026-07-25)
        case "dateAdded": return Self.dateText(item.dateAdded)             // 추가된 날짜
        case "tags": return item.tagNames.isEmpty ? "—" : item.tagNames    // 태그(라벨 색 이름)
        case "size":
            if let size = item.fileSize { return Self.sizeFormatter.string(fromByteCount: Int64(size)) }
            switch folderSizes[sizeKey(item.url)] {
            case .measured(let bytes): return Self.sizeFormatter.string(fromByteCount: bytes)
            case .partial(let bytes):   // 접근 불가 하위 존재 — "≥" 정직 표기 (워게임 §5 QC)
                return "≥ " + Self.sizeFormatter.string(fromByteCount: bytes)
            case .excluded, .none: return "—"
            }
        case "kind": return item.kind
        default: return nil
        }
    }

    /// 검색 결과에서 파일이 '들어있는 폴더'를 현재 폴더 기준 상대 경로로 — 동명 구분 (제작자 지시 2026-07-23).
    /// 현재 폴더 직속이거나 검색 중이 아니면 nil(위치 생략).
    private func searchLocationText(for item: FileItem) -> String? {
        guard searchResults != nil, let directory, directory.isFileURL else { return nil }
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        // Spotlight(kMDItemPath)는 조상 심링크까지 푼 실경로를 준다 — 현재 폴더 표기와 다르면 상대화가 실패해
        // 짧은 상대 경로 대신 전체 절대 경로가 뜬다. 두 표기 모두를 기준으로 시도한다(§32 후속).
        for base in [directory.standardizedFileURL.path, searchBase].compactMap({ $0 }) {
            if parent == base { return nil }
            if parent.hasPrefix(base + "/") { return String(parent.dropFirst(base.count + 1)) }
        }
        return parent
    }

    /// 파일명(진하게) + 들어있는 폴더(회색·소형) 한 줄 조합 — 검색 결과 이름 셀용.
    /// attributed 문자열은 라벨의 lineBreakMode를 무시하고 랩핑됨(실측 — 제작자 제보 "줄바뀜") →
    /// 단락 스타일로 한 줄 + 꼬리 줄임(…)을 명시.
    static func nameWithLocation(_ name: String, location: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(string: name, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraph])
        s.append(NSAttributedString(string: "   " + location, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: paragraph]))
        return s
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let item = items[row]
        let key = tableColumn.identifier.rawValue
        guard let text = columnText(for: item, key: key) else { return nil }
        let cell: NSTableCellView
        if key == "name" {
            let nameCell = CellFactory.iconText(tableView, identifier: .init("nameCell"))
            nameCell.imageView?.image = item.icon
            if let location = searchLocationText(for: item) {
                // 검색 결과 = 파일명 + 들어있는 폴더(회색) 한 줄 — 하위 폴더 동명 파일 구분 (제작자 지시 2026-07-23)
                nameCell.textField?.attributedStringValue = Self.nameWithLocation(text, location: location)
            } else {
                nameCell.textField?.stringValue = text
            }
            cell = nameCell
        } else {
            cell = CellFactory.text(tableView, identifier: .init(key + "Cell"),
                                    alignment: key == "size" ? .right : .left)
            cell.textField?.stringValue = text
        }
        cell.alphaValue = cutSourceURLs.contains(item.url) ? 0.45 : 1.0   // 잘라내기 행 흐림
        return cell
    }

    /// 헤더 구분선 더블클릭 = 컬럼 적정 폭 (Excel/Finder 규약 — 제작자 지시 2026-07-16).
    /// AppKit이 구분선 더블클릭 시 이 델리게이트를 호출한다.
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        guard tableView.tableColumns.indices.contains(column) else { return 100 }
        let tableColumn = tableView.tableColumns[column]
        let key = tableColumn.identifier.rawValue
        // 셀 폰트 = NSTextField(labelWithString:) 기본(시스템 13pt) — CellFactory 실측
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        var width = tableColumn.headerCell.cellSize.width + 8   // 헤더 제목 + 정렬 화살표 여유
        // ponytail: 측정은 앞 2000행 상한 — 대량 폴더 프리즈 방지(그 이후 행은 대개 동질)
        for item in items.prefix(2000) {
            guard let text = columnText(for: item, key: key) else { continue }
            width = max(width, (text as NSString).size(withAttributes: attributes).width)
        }
        // 셀 내부 여백: 이름 = 아이콘(2+16+6)+우측 2 / 메타 = 좌우 2+2 (CellFactory 실측) + 셀 간 여유
        width += key == "name" ? 30 : 10
        return max(min(ceil(width), 1200), tableColumn.minWidth)   // 폭주 상한·최소 폭 존중
    }

    #if DEBUG
    func debugFitColumns() {   // TF_FIT_COLUMNS 검증용 — 구분선 더블클릭과 동일 경로
        for (index, column) in tableView.tableColumns.enumerated() {
            let width = self.tableView(tableView, sizeToFitWidthOfColumn: index)
            NSLog("FIT column %@ -> %.0f", column.identifier.rawValue, width)
            column.width = width
        }
    }

    func debugCreateFolder(named name: String) {   // TF_TREE_REFRESH — 폴더 생성 후 reloadCurrentDirectory(트리 갱신 발화)
        guard let directory, directory.isFileURL else { return }
        try? FileManager.default.createDirectory(
            at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        reloadCurrentDirectory()
    }

    func debugNewFolder() { newFolder(nil) }   // TF_NEW_FOLDER — 새 폴더=이름변경 상태 진입 검증
    func debugNewTextDocument() { newTextDocument(nil) }   // TF_NEW_TEXTDOC — 새 텍스트 문서=이름변경 상태 진입 검증
    func debugEditingState() -> String {   // 이름변경 편집 진입 여부 실측(편집 중이면 editingRow≠nil·필드에디터 firstResponder)
        let fr = view.window?.firstResponder
        return "editingRow=\(String(describing: editingRow)) firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")"
    }
    /// TF_NEW_FOLDER — 편집 종료(포커스 이동 = 커밋) 후 보류분(pendingRefresh) 흡수 실측용
    func debugCommitEditing() { view.window?.makeFirstResponder(tableView) }
    /// TF_NEW_FOLDER — 편집 중 보류했던 크기가 종료 후 실제로 표시되는지(빈 폴더 = "0바이트" 계열)
    func debugSizeCellText(named name: String) -> String {
        guard let index = items.firstIndex(where: { $0.name == name }) else { return "행없음" }
        return columnText(for: items[index], key: SortKey.size.rawValue) ?? "nil"
    }

    func debugSetTag(_ number: Int) {   // TF_SET_TAG — 첫 항목에 색상 태그 적용(목록 행 색 검증)
        guard !items.isEmpty else { return }
        setActiveSelection(IndexSet(integer: 0), scrollToFirst: true)
        if viewStyle != .list { selectionDidSync() }
        setTagLabel(number, for: [items[0].url])
    }
    #endif

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard viewStyle == .list else { return }   // 숨은 테이블의 잔여 통지 차단
        // FSEvents 리로드(프로그램적 선택 변화)가 비활성 페인의 활성을 훔치지 않도록
        // 사용자 상호작용(테이블이 포커스)일 때만 활성 승격 (워게임 §4)
        if view.window?.firstResponder === tableView { onActivate?() }
        let row = tableView.selectedRow
        onSelect?(row >= 0 && items.indices.contains(row) ? items[row] : nil)
        notifyStatus()
    }

    /// 리스트 type-select = 내장 경로 폐기, IME(NSTextInputClient) 경로로 통일 (제작자 지시 2026-07-25, 조사 반영).
    /// nil 반환으로 NSTableView 내장 type-select 비활성 — 완성형 못하는 라틴 경로 + IME 이중발화 차단.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        nil
    }

    // MARK: NSCollectionViewDataSource / Delegate (아이콘·갤러리 — 워게임 [2026-07-16]_wargame_icon_gallery_view.md)

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileIconItem.reuseIdentifier, for: indexPath)
        guard let iconItem = cell as? FileIconItem, items.indices.contains(indexPath.item) else { return cell }
        let item = items[indexPath.item]
        iconItem.configure(item: item,
                           variant: viewStyle == .gallery ? .strip : .grid,
                           isCut: cutSourceURLs.contains(item.url),
                           gridSide: IconGridMetrics.side)
        return cell
    }

    // didSelect/didDeselect는 사용자 상호작용에서만 발화 — firstResponder 가드 불필요 (QC 위원)
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onActivate?()
        selectionDidSync()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onActivate?()
        selectionDidSync()
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? FileIconItem)?.cancelThumbnail()   // 화면 이탈 셀의 썸네일 요청 취소 (워게임 §4)
    }

    // MARK: 컬렉션 드래그&드롭 — 테이블과 동일 규약(1.1.10) 미러

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        // 네트워크 컴퓨터 등 비파일 항목은 드래그 제외 (워게임 network_browse)
        guard items.indices.contains(indexPath.item), items[indexPath.item].url.isFileURL else { return nil }
        return items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard directory?.isFileURL == true,
              draggingInfo.draggingPasteboard.canReadObject(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        let index = proposedIndexPath.pointee.item
        // 폴더 아이템 위가 아니면 전체(=현재 폴더) 드롭으로 승격 — setDropRow(-1) 대응 (QC 위원)
        if !(dropOperation.pointee == .on && items.indices.contains(index) && items[index].isDirectory) {
            proposedIndexPath.pointee = NSIndexPath(forItem: items.count, inSection: 0)
            dropOperation.pointee = .before
        }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let baseDirectory = directory,
              let sources = draggingInfo.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !sources.isEmpty else { return false }
        let target = (dropOperation == .on && items.indices.contains(indexPath.item) && items[indexPath.item].isDirectory)
            ? items[indexPath.item].url
            : baseDirectory
        performDrop(sources, into: target, forceCopy: NSEvent.modifierFlags.contains(.option),
                    stackSource: draggingInfo.draggingSource as? DropStackView)
        return true
    }
}
