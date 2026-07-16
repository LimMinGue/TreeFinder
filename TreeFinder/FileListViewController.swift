import AppKit

/// 탭 하나 — 폴더 아이콘 + 이름 + ✕, 활성 탭은 얇은 테두리 필(pill) (원본 탭 레퍼런스 기준)
final class TabItemView: NSView {
    private let index: Int
    private let isActive: Bool
    private let onSelect: (Int) -> Void
    private let onClose: (Int) -> Void
    private let onDropFiles: (Int, [URL], Bool) -> Void
    private var springTimer: Timer?

    init(index: Int, icon tabIcon: NSImage?, title: String, active: Bool, closable: Bool,
         onSelect: @escaping (Int) -> Void, onClose: @escaping (Int) -> Void,
         onDropFiles: @escaping (Int, [URL], Bool) -> Void) {
        self.index = index
        self.isActive = active
        self.onSelect = onSelect
        self.onClose = onClose
        self.onDropFiles = onDropFiles
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

    override func mouseDown(with event: NSEvent) { onSelect(index) }   // ✕ 클릭은 버튼이 소비
    @objc private func closeTapped() { onClose(index) }

    // MARK: 드래그 스프링 오픈 + 드롭 (원본 1.1.10 — 호버하면 탭이 열리고, 놓으면 그 폴더로)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
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
        onDropFiles(index, urls, NSEvent.modifierFlags.contains(.option))
        return true
    }
}

/// 파일 목록 영역 상단의 커스텀 탭 스트립 (2026-07-16 제작자 확정 — 창 전체가 아니라 목록 영역 위)
final class TabBarView: NSView {
    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onAddTab: (() -> Void)?
    var onDropOnTab: ((Int, [URL], Bool) -> Void)?
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

    /// 범용 탭 스트립 — 터미널 등 URL 없는 탭도 동일 필 디자인 공유 (규칙 4)
    func update(items: [(icon: NSImage?, title: String)], active: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            stack.addArrangedSubview(TabItemView(
                index: index, icon: item.icon, title: item.title, active: index == active,
                closable: items.count > 1,   // 마지막 1개는 ✕ 숨김 (QC)
                onSelect: { [weak self] in self?.onSelectTab?($0) },
                onClose: { [weak self] in self?.onCloseTab?($0) },
                onDropFiles: { [weak self] in self?.onDropOnTab?($0, $1, $2) }))
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

final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                    NSMenuDelegate, NSTextFieldDelegate,
                                    NSCollectionViewDataSource, NSCollectionViewDelegate {

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let row = editingRow else { return }
        editingRow = nil
        field.isEditable = false
        field.delegate = nil
        let hadPendingRefresh = pendingRefresh   // EditGuard 보류분 — 어느 경로로 끝나도 흡수
        pendingRefresh = false
        guard items.indices.contains(row) else {
            if hadPendingRefresh { reloadCurrentDirectory() }
            return
        }
        let item = items[row]
        let newName = field.stringValue
        guard !newName.isEmpty, newName != item.name else {
            field.stringValue = item.name
            if hadPendingRefresh { reloadCurrentDirectory() }
            return
        }
        do {
            let renamed = try Self.posixRename(item.url, toName: newName)
            registerRenameUndo(current: renamed, originalName: item.name)
        } catch {
            field.stringValue = item.name
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

    private(set) var directory: URL?
    private var allItems: [FileItem] = []   // 필터 전 원본
    private var items: [FileItem] = []      // 필터+정렬 적용본 (테이블 표시)
    private var filterText = ""
    private let tableView = NSTableView()
    private let tabBar = TabBarView()
    private let messageLabel = NSTextField(labelWithString: "")

    // MARK: 뷰 스타일 상태 (워게임 [2026-07-16]_wargame_icon_gallery_view.md)
    private(set) var viewStyle: ViewStyle = .list
    var onViewStyleChange: ((ViewStyle) -> Void)?
    private let tableScroll = NSScrollView()
    private let collectionView = TFCollectionView()
    private let collectionScroll = NSScrollView()
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
        addColumn(.name, title: L("Name"), width: 280, minWidth: 160)
        addColumn(.dateModified, title: L("Date Modified"), width: 150, minWidth: 100)
        addColumn(.dateCreated, title: L("Date Created"), width: 150, minWidth: 100)
        addColumn(.size, title: L("Size"), width: 80, minWidth: 60)
        addColumn(.kind, title: L("Kind"), width: 140, minWidth: 80)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true   // 격자 배경 — 행 구분(2026-07-16 제작자 지시)
        tableView.style = .inset
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.target = self
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
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelectTab = { [weak self] index in self?.selectTab(index) }
        tabBar.onCloseTab = { [weak self] index in self?.closeTab(index) }
        tabBar.onAddTab = { [weak self] in self?.addTab() }
        tabBar.onDropOnTab = { [weak self] index, urls, forceCopy in
            guard let self, self.tabURLs.indices.contains(index) else { return }
            self.performDrop(urls, into: self.tabURLs[index], forceCopy: forceCopy)
        }

        let container = NSView()
        container.addSubview(tabBar)
        container.addSubview(tableScroll)
        container.addSubview(galleryBox)
        container.addSubview(collectionScroll)
        container.addSubview(messageLabel)
        NSLayoutConstraint.activate([
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
            // 갤러리 박스 내부 — 미리보기가 캡션 위 공간 전부
            galleryPreview.topAnchor.constraint(equalTo: galleryBox.topAnchor, constant: 8),
            galleryPreview.leadingAnchor.constraint(equalTo: galleryBox.leadingAnchor, constant: 8),
            galleryPreview.trailingAnchor.constraint(equalTo: galleryBox.trailingAnchor, constant: -8),
            galleryCaption.topAnchor.constraint(equalTo: galleryPreview.bottomAnchor, constant: 6),
            galleryCaption.bottomAnchor.constraint(equalTo: galleryBox.bottomAnchor, constant: -6),
            galleryCaption.leadingAnchor.constraint(equalTo: galleryBox.leadingAnchor, constant: 16),
            galleryCaption.trailingAnchor.constraint(equalTo: galleryBox.trailingAnchor, constant: -16),
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
        layout.itemSize = NSSize(width: 100, height: 112)
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
        view.window?.makeFirstResponder(style == .list ? tableView : collectionView)
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
            if viewStyle == .list {
                tableView.reloadData()          // stale row count 해소 후 노출 (QC 위원 크래시 경로)
            } else {
                collectionView.collectionViewLayout = viewStyle == .icons
                    ? Self.makeGridLayout() : Self.makeStripLayout()
                // 레이아웃 교체 후 재등록 — 교체가 등록 테이블을 무효화하는 AppKit 동작 방어
                collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.reuseIdentifier)
                collectionView.reloadData()
            }
            tableScroll.isHidden = viewStyle != .list
            collectionScroll.isHidden = viewStyle == .list
            galleryBox.isHidden = viewStyle != .gallery
            if viewStyle != .gallery {
                galleryDebounce?.cancel()
                galleryPreview.previewItem = nil   // 동영상 백그라운드 재생 중단 (QC 위원)
                galleryCaption.stringValue = ""
            }
        }
    }

    // MARK: 활성 뷰 선택/리로드 추상화 — 테이블 직접 참조 금지 (QC 위원 전수 21곳 반영)

    private func activeSelectionIndexes() -> IndexSet {
        viewStyle == .list
            ? tableView.selectedRowIndexes
            : IndexSet(collectionView.selectionIndexPaths.map(\.item))
    }

    private func setActiveSelection(_ indexes: IndexSet, scrollToFirst: Bool) {
        if viewStyle == .list {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            if scrollToFirst, let first = indexes.first { tableView.scrollRowToVisible(first) }
        } else {
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
    private func reloadActiveViewRaw() {
        if viewStyle == .list { tableView.reloadData() } else { collectionView.reloadData() }
    }

    /// 프로그램적 선택 변경 뒤 공용 통지 — 컬렉션은 델리게이트가 침묵하므로 명시 호출 필수 (QC 위원)
    private func selectionDidSync() {
        let indexes = activeSelectionIndexes()
        // 갤러리는 대형 미리보기와 같은 항목(마지막 선택) 기준 — 정보 페인 불일치 방지 (검증 minor)
        let anchor = viewStyle == .gallery ? indexes.last : indexes.first
        onSelect?(anchor.flatMap { items.indices.contains($0) ? items[$0] : nil })
        notifyStatus()
        if viewStyle == .gallery { updateGalleryPreview() }
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

    private func refreshTabBar() {
        tabBar.update(urls: tabURLs, active: activeTab)
    }

    private func addColumn(_ key: SortKey, title: String, width: CGFloat, minWidth: CGFloat) {
        let column = NSTableColumn(identifier: .init(key.rawValue))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
        tableView.addTableColumn(column)
    }

    /// 네트워크 브라우즈 센티널 — show(directory:) 단일 초크포인트로 탭·히스토리·듀얼 페인 공짜 (워게임 network_browse)
    static let networkURL = URL(string: "treefinder://network")!
    var isNetworkBrowse: Bool { directory == Self.networkURL }

    func show(directory: URL) {
        onActivate?()
        if !navigatingViaHistory, let old = self.directory, old != directory {
            backStack.append(old)
            forwardStack.removeAll()
        }
        navigatingViaHistory = false
        self.directory = directory
        filterText = ""   // 폴더 이동 시 검색 필터 초기화 (Finder 규약)
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
            var failure: String?
            do {
                listed = try await DirectoryLister.list(
                    directory, showHidden: UserDefaults.standard.bool(forKey: SettingsKeys.showHidden))
            } catch is CancellationError {
                return
            } catch {
                failure = String(format: L("Can't read this folder — %@"), error.localizedDescription)
            }
            guard let self, !Task.isCancelled else { return }
            self.allItems = listed
            self.rebuildItems(scrollToTop: true)
            self.messageLabel.stringValue = failure ?? ""
            self.messageLabel.isHidden = (failure == nil)
            self.selectionDidSync()   // onSelect(nil) + 갤러리 미리보기 초기화
            self.requestFolderSizes()
        }
    }

    /// 네트워크 브라우즈 항목 재구성 — 발견된 SMB 호스트(Bonjour). 정렬·검색·상태바는 기존 경로 공용.
    private func reloadNetworkItems() {
        guard isNetworkBrowse else { return }
        allItems = NetworkBrowser.shared.hosts.compactMap { name in
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
                  let url = URL(string: "smb://\(encoded)") else { return nil }
            return FileItem(url: url, name: name, isDirectory: false, isPackage: false,
                            fileSize: nil, dateModified: nil, dateCreated: nil,
                            kind: L("Network computer"), labelNumber: 0)
        }
        // 로컬 네트워크 권한 거부/초기 탐색 중 = 결과 0 — 정직한 상태 라벨 (워게임 §4)
        messageLabel.stringValue = allItems.isEmpty ? L("Searching for network computers…") : ""
        messageLabel.isHidden = !allItems.isEmpty
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
                    self.tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                                              columnIndexes: IndexSet(integer: 3))
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

    /// 필터+정렬을 원본에 재적용 — 검색·정렬·설정 변경이 전부 이 경로 하나를 탄다
    private func rebuildItems(scrollToTop: Bool = false, preserveSelection: Bool = false,
                              scrollToSelection: Bool = false) {
        let selected = preserveSelection
            ? Set(activeSelectionIndexes().compactMap { items.indices.contains($0) ? items[$0].url : nil })
            : []
        let base = filterText.isEmpty
            ? allItems
            : allItems.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        items = DirectoryLister.sorted(base, by: sortKey, ascending: sortAscending,
                                       sizeOf: { [weak self] in self?.effectiveSize($0) })
        reloadActiveViewRaw()
        if preserveSelection {
            // 백그라운드 리빌드(FSEvents·폴더 크기)가 뷰포트를 점프시키지 않도록 스크롤은 정렬 변경만 (검증 minor)
            restoreSelection(urls: selected, scrollToFirst: scrollToSelection)
            selectionDidSync()   // 컬렉션의 프로그램적 선택은 델리게이트 침묵 — 명시 재발행 (QC 위원)
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
        rebuildItems()
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

    @objc func undo(_ sender: Any?) { fileUndoManager.undo() }
    @objc func redo(_ sender: Any?) { fileUndoManager.redo() }

    private func selectedURLs() -> [URL] {
        activeSelectionIndexes().compactMap { items.indices.contains($0) ? items[$0].url : nil }
    }

    /// 충돌 회피 명명 — 덮어쓰기 절대 없음 ("이름 2", "이름 3"…)
    static func availableURL(for proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let parent = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let base = ext.isEmpty ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// FileManager.moveItem은 대상 경로를 syscall 직전 NFD로 재정규화(함정 ③) — POSIX rename에 NFC 바이트 직접
    static func posixRename(_ url: URL, toName newName: String) throws -> URL {
        let name = PathPasteboard.normalized(newName)
        let destPath = url.deletingLastPathComponent().path + "/" + name
        guard !FileManager.default.fileExists(atPath: destPath) else {
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
                            items: items, in: view) { [weak self] in
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
        operationEngine.run(title: L("Duplicating items…"), items: items, in: view) { [weak self] in
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
        operationEngine.run(title: L("Moving to Trash…"), items: items, in: view) { [weak self] in
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
        operationEngine.run(title: L("Restoring items…"), items: items, in: view) { [weak self] in
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
        operationEngine.run(title: L("Compressing items…"), items: [item], in: view) { [weak self] in
            self?.reloadCurrentDirectory()
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard let directory, directory.isFileURL else { return }
        do {
            let dest = Self.availableURL(for: directory.appendingPathComponent("untitled folder"))
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            registerUndoCreated(dest, action: L("New Folder"))
        } catch { reportError(error) }
        reloadCurrentDirectory()
    }

    @objc func renameSelected(_ sender: Any?) {
        // 인라인 rename은 리스트 전용 — 아이콘 모드에서 숨은 테이블의 stale row 편집 방지 (워게임 §4)
        guard viewStyle == .list else { return }
        let row = tableView.selectedRow
        guard row >= 0,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
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
    }

    /// 파일 조작 후 현재 폴더 재리스팅 (선택 유지) — 내용이 변했으므로 크기 캐시도 무효화
    func reloadCurrentDirectory() {
        guard let directory else { return }
        let prefix = sizeKey(directory) + "/"
        folderSizes = folderSizes.filter {
            !($0.key.hasPrefix(prefix) && !$0.key.dropFirst(prefix.count).contains("/"))
        }
        Task { await SizeService.shared.invalidate(childrenOf: directory) }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let listed = try? await DirectoryLister.list(
                directory, showHidden: UserDefaults.standard.bool(forKey: SettingsKeys.showHidden))
            else { return }
            guard let self, !Task.isCancelled else { return }
            self.allItems = listed
            self.rebuildItems(preserveSelection: true)
            self.requestFolderSizes()
        }
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
        for item in selected where !item.isDirectory { NSWorkspace.shared.open(item.url) }
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
        // 이벤트 경로가 감시 폴더 "자신"일 때만(=직계 자식 변경) 리로드한다.
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let target = Unmanaged<FileListViewController>.fromOpaque(info).takeUnretainedValue()
            guard let watched = target.directory?.standardizedFileURL.path else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let watchedNFC = PathPasteboard.normalized(watched)
            for path in paths.prefix(Int(numEvents)) {
                let eventDir = PathPasteboard.normalized(
                    URL(fileURLWithPath: path).standardizedFileURL.path)
                if eventDir == watchedNFC {
                    target.directoryDidChange()
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
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: 컨텍스트 메뉴 (원본 레퍼런스 구성 — DESIGN_REFERENCE §13, 미구현 파일 조작은 비활성)

    func menuNeedsUpdate(_ menu: NSMenu) {
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
        guard let row = activeClickedIndex(), items.indices.contains(row) else {
            buildBackgroundMenu(menu)   // 빈 영역 우클릭
            return
        }
        if !activeSelectionIndexes().contains(row) {   // Finder 규약: 우클릭 항목을 선택으로
            setActiveSelection(IndexSet(integer: row), scrollToFirst: false)
            if viewStyle != .list { selectionDidSync() }   // 컬렉션 프로그램적 선택 = 델리게이트 침묵
        }
        let item = items[row]
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
        menu.addItem(.separator())
        menu.addItem(entry(L("Cut"), "scissors", #selector(cut(_:))))
        menu.addItem(entry(L("Copy"), "doc.on.doc", #selector(copy(_:))))
        let canPaste = NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        menu.addItem(entry(L("Paste"), "doc.on.clipboard", #selector(paste(_:)), enabled: canPaste))
        menu.addItem(entry(L("Duplicate"), "square.filled.on.square", #selector(duplicateSelected(_:))))
        menu.addItem(entry(L("Compress"), "doc.zipper", #selector(compressSelected(_:))))
        menu.addItem(.separator())
        // 인라인 rename은 리스트 전용 (워게임 §4 — 미구현은 비활성, §13 규약)
        menu.addItem(entry(L("Rename"), "character.cursor.ibeam", #selector(renameSelected(_:)),
                           enabled: viewStyle == .list))
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
        guard FileManager.default.createFile(atPath: dest.path, contents: Data()) else { return }
        fileUndoManager.registerUndo(withTarget: self) { target in
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size == 0 { try? FileManager.default.removeItem(at: dest) }   // 내용이 생겼으면 지우지 않음
            target.reloadCurrentDirectory()
        }
        fileUndoManager.setActionName(L("New Text Document"))
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
        performDrop(sources, into: target, forceCopy: NSEvent.modifierFlags.contains(.option))
        return true
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let idA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
              let idB = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier else { return false }
        return idA.isEqual(idB)
    }

    func performDrop(_ sources: [URL], into target: URL, forceCopy: Bool) {
        var moving = false
        let items: [FileOperationEngine.Item] = sources.compactMap { source in
            guard source != target else { return nil }
            guard !target.path.hasPrefix(source.path + "/") else { return nil }   // 자기 하위로 이동 금지
            let isMove = !forceCopy && sameVolume(source, target)                 // 1.1.10 규약
            guard !(isMove && source.deletingLastPathComponent() == target) else { return nil }   // 같은 폴더 = no-op
            if isMove { moving = true }
            return transferItem(source: source, into: target, isMove: isMove)
        }
        operationEngine.run(title: moving ? L("Moving items…") : L("Copying items…"),
                            items: items, in: view) { [weak self] in
            self?.reloadCurrentDirectory()
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
                ? item.name
                : FileManager.default.displayName(atPath: item.url.path)   // hide-extension 플래그 존중
        case "dateModified": return Self.dateText(item.dateModified)
        case "dateCreated": return Self.dateText(item.dateCreated)
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let item = items[row]
        let key = tableColumn.identifier.rawValue
        guard let text = columnText(for: item, key: key) else { return nil }
        let cell: NSTableCellView
        if key == "name" {
            let nameCell = CellFactory.iconText(tableView, identifier: .init("nameCell"))
            nameCell.imageView?.image = item.icon
            cell = nameCell
        } else {
            cell = CellFactory.text(tableView, identifier: .init(key + "Cell"),
                                    alignment: key == "size" ? .right : .left)
        }
        cell.textField?.stringValue = text
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

    /// 리스트 type-select — 컬렉션과 동일한 첫 글자 점프 (파워유저 위원)
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items.indices.contains(row) ? items[row].name : nil
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
                           isCut: cutSourceURLs.contains(item.url))
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
        performDrop(sources, into: target, forceCopy: NSEvent.modifierFlags.contains(.option))
        return true
    }
}
