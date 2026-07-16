import AppKit

/// 경로 바 세그먼트 — 더블클릭 = 해당 폴더로 이동 (DESIGN_REFERENCE §9)
final class PathSegmentView: NSStackView {
    private let url: URL
    private let onNavigate: (URL) -> Void

    init(url: URL, onNavigate: @escaping (URL) -> Void) {
        self.url = url
        self.onNavigate = onNavigate
        super.init(frame: .zero)
        spacing = 3
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        // 실제 경로가 아니라 로컬라이즈드 표시 이름(Users→사용자)을 그린다
        let label = NSTextField(labelWithString: FileManager.default.displayName(atPath: url.path))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        addArrangedSubview(icon)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onNavigate(url)   // 클릭 즉시 이동 (제작자 지시 2026-07-16 — 더블클릭에서 승격)
    }
}

/// 창 전폭 하단 경로 바(DESIGN_REFERENCE §9) — 선택 항목의 경로, 세그먼트 더블클릭 이동
final class PathBarView: NSView {
    var onNavigate: ((URL) -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ url: URL?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        var path = ""
        for (i, component) in url.pathComponents.enumerated() {
            path = component == "/" ? "/" : (path.hasSuffix("/") ? path + component : path + "/" + component)
            if i > 0 {
                let sep = NSTextField(labelWithString: "›")
                sep.font = .systemFont(ofSize: 11)
                sep.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(sep)
            }
            stack.addArrangedSubview(PathSegmentView(url: URL(fileURLWithPath: path)) { [weak self] in
                self?.onNavigate?($0)
            })
        }
    }
}

/// 3분할 + 하단 경로 바 + 상태바를 수직으로 쌓는 컨테이너
final class MainContentViewController: NSViewController {
    let pathBar = PathBarView()
    let statusLabel = NSTextField(labelWithString: "")
    private let split: NSSplitViewController

    init(split: NSSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        addChild(split)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let statusRow = NSView()
        statusRow.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 22),
        ])

        func separator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }

        // NSStackView는 고유 높이 없는 split view에 남는 공간을 주지 않는다(수직 붕괴 실측)
        // — 명시적 제약으로 split이 잔여 공간을 전부 차지하게 고정
        let container = NSView()
        let sep1 = separator()
        let sep2 = separator()
        for sub in [split.view, sep1, pathBar, sep2, statusRow] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: container.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            sep1.topAnchor.constraint(equalTo: split.view.bottomAnchor),
            sep1.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            pathBar.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            pathBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            sep2.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            sep2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statusRow.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            statusRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }
}

final class MainWindowController: NSWindowController, NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleShowHidden(_:)):
            menuItem.state = UserDefaults.standard.bool(forKey: SettingsKeys.showHidden) ? .on : .off
        case #selector(togglePreview(_:)):
            menuItem.state = (splitController?.splitViewItems.last?.isCollapsed == false) ? .on : .off
        case #selector(toggleDualPane(_:)):
            menuItem.state = isDualPane ? .on : .off
        case #selector(applyViewStyle(_:)):
            let current = listController?.viewStyle.rawValue
            menuItem.state = (current == menuItem.representedObject as? String) ? .on : .off
        case #selector(restoreSelected(_:)):
            return listController?.canRestoreSelection ?? false   // 기록 있는 선택에서만 활성
        case #selector(toggleExpandToOpenFolder(_:)):
            let on = UserDefaults.standard.object(forKey: SettingsKeys.expandToOpenFolder) as? Bool ?? true
            menuItem.state = on ? .on : .off
        default: break
        }
        return true
    }

    private static let byteFormatter = ByteCountFormatter()
    private static var openWindows: [MainWindowController] = []   // 새 창 유지용
    // 듀얼 페인(decisions §9 ②) — 창 크롬·메뉴·도구모음은 전부 "활성 페인" 기준으로 라우팅
    private var panes: [FileListViewController] = []
    private var activePaneIndex = 0
    private var listController: FileListViewController? {
        panes.indices.contains(activePaneIndex) ? panes[activePaneIndex] : nil
    }
    private weak var splitController: NSSplitViewController?
    private weak var treeController: FolderTreeViewController?
    private weak var previewController: PreviewViewController?
    private weak var contentController: MainContentViewController?
    fileprivate var searchItem: NSSearchToolbarItem?
    fileprivate var titleLabel: NSTextField?
    fileprivate var viewSegmented: NSSegmentedControl?

    var isDualPane: Bool { panes.count == 2 }

    /// 사이드바에 포커스가 있어도 ⌘↑가 동작하도록, 항상 응답 체인에 있는 윈도우 컨트롤러가 받아서 전달
    @objc func goUp(_ sender: Any?) {
        listController?.goUp(sender)
    }

    @objc func goBack(_ sender: Any?) {
        listController?.goBack(sender)
    }

    @objc func goForward(_ sender: Any?) {
        listController?.goForward(sender)
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        listController?.applyFilter(sender.stringValue)
    }

    // 도구모음·메뉴가 포커스 위치와 무관하게 동작하도록 윈도우 컨트롤러가 중계
    @objc func newFolder(_ sender: Any?) { listController?.newFolder(sender) }
    @objc func deleteSelected(_ sender: Any?) { listController?.deleteSelected(sender) }
    @objc func newTextDocument(_ sender: Any?) { listController?.newTextDocument(sender) }
    @objc func restoreSelected(_ sender: Any?) { listController?.restoreSelected(sender) }
    @objc func openSelected(_ sender: Any?) { listController?.openSelected() }
    @objc func renameSelected(_ sender: Any?) { listController?.renameSelected(sender) }
    @objc func getInfoSelected(_ sender: Any?) { listController?.getInfoSelected(sender) }
    @objc func closeTab(_ sender: Any?) {
        // 마지막 탭이면 창을 닫는다 (원본 ⌘W = Close Tab 규약)
        if listController?.closeActiveTab() == false { window?.performClose(sender) }
    }
    @objc func focusSearch(_ sender: Any?) {
        guard let field = searchItem?.searchField else { return }
        window?.makeFirstResponder(field)
    }
    @objc func showNextTab(_ sender: Any?) { listController?.selectNextTab() }
    @objc func showPreviousTab(_ sender: Any?) { listController?.selectPreviousTab() }
    @objc func selectTabFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        listController?.activateTab(index)
    }
    var tabTitles: [String] { listController?.tabTitles ?? [] }
    var activeTabIndex: Int { listController?.activeTabIndex ?? 0 }
    @objc func toggleShowHidden(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: SettingsKeys.showHidden), forKey: SettingsKeys.showHidden)
        listController?.reloadCurrentDirectory()
        // 트리도 같은 설정을 따른다(제작자 지적 2026-07-16 — 트리·리스트 불일치) — 트리 재구성 통지
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
    @objc func toggleExpandToOpenFolder(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: SettingsKeys.expandToOpenFolder) as? Bool ?? true
        defaults.set(!current, forKey: SettingsKeys.expandToOpenFolder)
    }

    // MARK: Finder 규약 — ⇧⌘G 폴더로 이동 / ⌘K 서버에 연결 (제작자 지시 2026-07-16)

    @objc func goToFolder(_ sender: Any?) {
        promptForText(message: L("Go to the folder:"), placeholder: "~/Documents",
                      initial: listController?.directory?.path ?? "", ok: L("Go")) {
            [weak self] input in
            guard let self, let input, !input.isEmpty else { return }
            let expanded = (input as NSString).expandingTildeInPath
            // NFC/NFD 폴백 해석 — SMB 등 정규화 상이 저장 대비 (decisions §5)
            let candidates = [expanded,
                              PathPasteboard.normalized(expanded),
                              expanded.decomposedStringWithCanonicalMapping]
            for candidate in candidates {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    self.listController?.show(directory: URL(fileURLWithPath: candidate))
                    return
                }
            }
            self.presentSimpleAlert(L("The folder can't be found."))
        }
    }

    @objc func connectToServer(_ sender: Any?) {
        promptForText(message: L("Connect to Server"), placeholder: "smb://server/share", ok: L("Connect")) {
            [weak self] input in
            guard let self, let input else { return }
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme != nil else {
                self.presentSimpleAlert(L("Invalid server address."))
                return
            }
            NetworkLocationStore.shared.mount(url) { [weak self] mountPoint in
                if let mountPoint {
                    self?.listController?.show(directory: mountPoint)   // didMount 옵저버가 자동 기억
                } else {
                    self?.presentSimpleAlert(String(format: L("Couldn't connect to %@"), trimmed))
                }
            }
        }
    }

    private func promptForText(message: String, placeholder: String, initial: String = "",
                               ok: String, completion: @escaping (String?) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func presentSimpleAlert(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    @objc func copyPath(_ sender: Any?) {
        listController?.copyPath(sender)
    }

    @objc func togglePreview(_ sender: Any?) {
        splitController?.splitViewItems.last?.animator().isCollapsed.toggle()
    }

    @objc func applySort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        listController?.applySort(raw: raw)
    }

    // MARK: 뷰 스타일 (아이콘/리스트/갤러리 — 워게임 [2026-07-16]_wargame_icon_gallery_view.md)

    fileprivate static func segmentIndex(of style: ViewStyle) -> Int {
        switch style {
        case .icons: return 0
        case .list: return 1
        case .gallery: return 3
        }
    }

    @objc func viewSwitcherChanged(_ sender: NSSegmentedControl) {
        let style: ViewStyle
        switch sender.selectedSegment {
        case 0: style = .icons
        case 3: style = .gallery
        default: style = .list
        }
        listController?.setViewStyle(style)
    }

    /// View 메뉴 라디오 항목 (⌥⌘1/2/3 — ⌘1..9는 탭 전환에 배정됨)
    @objc func applyViewStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = ViewStyle(rawValue: raw) else { return }
        listController?.setViewStyle(style)
    }

    /// 활성 페인의 뷰 스타일을 도구모음 세그먼트·미리보기 패널 모드에 반영
    private func syncViewChrome() {
        let style = listController?.viewStyle ?? .list
        viewSegmented?.selectedSegment = Self.segmentIndex(of: style)
        // 갤러리 모드 = 패널 정보 전용 — 대형 프리뷰 좌우 중복 방지 (디자이너 위원)
        previewController?.infoOnlyMode = (style == .gallery)
    }

    #if DEBUG
    func debugShowNetwork() {   // TF_NETWORK_VIEW 스냅숏 검증용
        listController?.show(directory: FileListViewController.networkURL)
    }

    func debugFitColumns() {   // TF_FIT_COLUMNS 스냅숏 검증용
        listController?.debugFitColumns()
    }

    func debugSetViewStyle(_ raw: String) {   // TF_VIEW_STYLE 스냅숏 검증용
        guard let style = ViewStyle(rawValue: raw) else { return }
        listController?.setViewStyle(style)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.listController?.debugSelectFirstItem()   // 선택 시각·갤러리 미리보기까지 스냅숏에 포함
        }
    }
    #endif

    /// File ▸ New Tab(⌘T) — 커스텀 탭 스트립(파일 목록 영역 스코프)에 새 탭 (decisions §10)
    override func newWindowForTab(_ sender: Any?) {
        listController?.addTab()
    }

    // MARK: 듀얼 페인 (decisions §9 ② — 워게임 [2026-07-16]_wargame_dual_pane)

    /// 페인 하나의 클로저 일괄 배선 — 크롬 갱신 클로저는 전부 `pane === 활성` 가드
    private func wirePane(_ list: FileListViewController) {
        list.onActivate = { [weak self, weak list] in
            guard let self, let list else { return }
            self.activate(pane: list)
        }
        list.onAddFavorite = { [weak self] url in self?.treeController?.addFavorite(url: url) }
        list.onSelect = { [weak self, weak list] item in
            guard let self, let list, list === self.listController else { return }
            // 네트워크 컴퓨터 등 비파일 URL은 미리보기·경로 바 대상 아님 (워게임 network_browse)
            let fileURL = (item?.url.isFileURL == true) ? item?.url : nil
            self.previewController?.show(fileURL)
            let directoryURL = (list.directory?.isFileURL == true) ? list.directory : nil
            self.contentController?.pathBar.show(fileURL ?? directoryURL)   // 선택 없으면 현재 폴더 (§9)
        }
        list.onStatusChange = { [weak self, weak list] total, selected, bytes, calculating in
            guard let self, let list, list === self.listController else { return }   // 비활성 FSEvents 방어
            var text = selected == 0
                ? String(format: L("%d items"), total)
                : String(format: L("%1$d of %2$d selected · %3$@"), selected, total, Self.byteFormatter.string(fromByteCount: bytes))
            if calculating { text += " · " + L("Calculating sizes…") }   // 원본 1.1.6 규약
            self.contentController?.statusLabel.stringValue = text
        }
        list.onDirectoryChange = { [weak self, weak list] url in
            guard let self, let list, list === self.listController else { return }
            self.refreshChrome(directory: url)
        }
        // 스타일 변경은 디렉터리 이동이 아니라 refreshChrome을 안 탐 — 별도 통지 필수 (코드정합 위원)
        list.onViewStyleChange = { [weak self, weak list] _ in
            guard let self, let list, list === self.listController else { return }
            self.syncViewChrome()
        }
    }

    /// 상호작용한 페인을 활성으로 승격 + 크롬을 그 페인 기준으로 재갱신 (단일 진입점)
    private func activate(pane: FileListViewController) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index != activePaneIndex else { return }
        activePaneIndex = index
        for (i, p) in panes.enumerated() { p.showsActiveIndicator = isDualPane && i == index }
        if let url = pane.directory { refreshChrome(directory: url) }
        pane.notifyStatus()
    }

    /// 창 크롬(타이틀·검색·경로 바·미리보기 폴더·트리 동기화)을 활성 페인 기준으로
    private func refreshChrome(directory url: URL) {
        if url == FileListViewController.networkURL {   // 네트워크 브라우즈 — 파일 경로 파생 금지
            searchItem?.searchField.placeholderString = String(format: L("Search %@"), L("Network"))
            searchItem?.searchField.stringValue = ""
            titleLabel?.stringValue = L("Network")
            previewController?.currentDirectory = nil
            contentController?.pathBar.show(nil)
            syncViewChrome()
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
        searchItem?.searchField.placeholderString = String(format: L("Search %@"), name)
        searchItem?.searchField.stringValue = ""   // 폴더 이동 = 필터 리셋과 동기
        titleLabel?.stringValue = name
        previewController?.currentDirectory = url
        contentController?.pathBar.show(url)   // 기본 경로 표시는 동기 경로 — 비동기 Task 취소와 무관하게 즉시
        syncViewChrome()   // 탭·페인 전환에 따른 뷰 세그먼트/패널 모드 동기화
        if UserDefaults.standard.object(forKey: SettingsKeys.expandToOpenFolder) as? Bool ?? true {
            treeController?.reveal(url)                      // View ▸ Expand to Open Folder
        }
    }

    /// View ▸ Dual Pane(⇧⌘D) — 두 번째 목록 페인 삽입/제거. 기본 꺼짐, 두 번째 페인은 현재 폴더로 시작
    @objc func toggleDualPane(_ sender: Any?) {
        guard let split = splitController else { return }
        if isDualPane {
            let second = panes.removeLast()
            if let item = split.splitViewItems.first(where: { $0.viewController === second }) {
                split.removeSplitViewItem(item)
            }
            activePaneIndex = 0
            panes[0].showsActiveIndicator = false   // 단일 모드 = 표시 불필요
            if let url = panes[0].directory { refreshChrome(directory: url) }
            panes[0].notifyStatus()
        } else {
            let second = FileListViewController()
            wirePane(second)
            panes.append(second)
            let item = NSSplitViewItem(contentListWithViewController: second)
            item.minimumThickness = 320
            split.insertSplitViewItem(item, at: 2)   // [사이드바 | 페인1 | 페인2 | 미리보기]
            if let w = window, w.frame.width < 1250 {   // 4분할 최소폭 확보 — 짓눌린 페인 방지
                var frame = w.frame
                frame.size.width = min(1250, w.screen?.visibleFrame.width ?? 1250)
                w.setFrame(frame, display: true, animate: true)
            }
            second.show(directory: panes[0].directory ?? FileManager.default.homeDirectoryForCurrentUser)
            panes[0].showsActiveIndicator = false
            second.showsActiveIndicator = true      // show()의 onActivate가 활성 승격 완료한 상태
        }
    }

    static func openNewWindow(directory: URL) {
        let controller = MainWindowController(directory: directory)
        openWindows.append(controller)
        if let newWindow = controller.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { note in
                MainWindowController.openWindows.removeAll { $0.window === (note.object as? NSWindow) }
            }
        }
        controller.showWindow(nil)
    }

    // 주의: 기본값 파라미터 금지 — `MainWindowController()`가 상속된 빈 init()으로 해석되어
    // 창 없는 컨트롤러가 생기는 사고 실측(2026-07-16). 항상 directory를 명시할 것.
    convenience init(directory: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TreeFinder"
        self.init(window: window)

        let tree = FolderTreeViewController()
        let list = FileListViewController()
        let preview = PreviewViewController()

        // 트리·즐겨찾기·드롭은 항상 "활성 페인"으로 라우팅 (워게임 §4)
        tree.onSelect = { [weak self] url in self?.listController?.show(directory: url) }
        tree.onSelectNetwork = { [weak self] in
            self?.listController?.show(directory: FileListViewController.networkURL)
        }
        tree.onOpenInNewTab = { [weak self] url in self?.listController?.addTab(showing: url) }
        tree.onOpenInNewWindow = { url in MainWindowController.openNewWindow(directory: url) }
        tree.onDropFiles = { [weak self] sources, target, forceCopy in
            self?.listController?.performDrop(sources, into: target, forceCopy: forceCopy)
        }

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: tree)
        sidebarItem.minimumThickness = 180
        let listItem = NSSplitViewItem(contentListWithViewController: list)
        listItem.minimumThickness = 320
        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 220
        previewItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(listItem)
        split.addSplitViewItem(previewItem)

        let content = MainContentViewController(split: split)
        content.pathBar.onNavigate = { [weak self] url in self?.listController?.show(directory: url) }
        window.contentViewController = content
        treeController = tree
        previewController = preview
        contentController = content
        splitController = split
        panes = [list]
        wirePane(list)

        window.tabbingMode = .disallowed   // 탭은 커스텀 스트립(목록 영역)이 담당 — 창 탭 금지
        window.titleVisibility = .hidden   // 타이틀은 도구모음 안 라벨로 (토글·◀▶ 왼쪽 배치를 위해)
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // contentViewController 설정이 창을 뷰의 fitting size로 축소시킨다(프로그래매틱 뷰 = intrinsic size 없음)
        // — 반드시 설정 "후"에 크기를 지정해야 함
        let defaultSize = NSSize(width: 1100, height: 700)
        window.setContentSize(defaultSize)
        window.contentMinSize = NSSize(width: 700, height: 450)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        if window.frame.height < 450 {   // 이전 실행이 저장해둔 붕괴 프레임 방어
            window.setContentSize(defaultSize)
            window.center()
        }

        list.show(directory: directory)
    }
}

// MARK: - 상단 도구모음 — Finder 형태 (2026-07-16 제작자 지시, decisions §10 개정)

private extension NSToolbarItem.Identifier {
    static let back = Self("back"), forward = Self("forward"), windowTitle = Self("windowTitle")
    static let newFolder = Self("newFolder"), deleteFile = Self("deleteFile")
    static let sortMenu = Self("sortMenu"), viewSwitcher = Self("viewSwitcher")
    static let togglePreview = Self("togglePreview"), searchField = Self("searchField")
}

extension MainWindowController: NSToolbarDelegate {
    private func button(_ id: NSToolbarItem.Identifier, _ symbol: String,
                        _ label: String, _ action: Selector?) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.action = action   // target nil = 응답 체인. 미구현 셀렉터는 자동 비활성(정직한 목업)
        return item
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .back: return button(id, "chevron.left", L("Back"), Selector(("goBack:")))
        case .forward: return button(id, "chevron.right", L("Forward"), Selector(("goForward:")))
        case .windowTitle:
            // 폴더명 타이틀 — 경로 표시는 하단 경로 바가 담당(중복 제거, 제작자 지적 2026-07-16)
            let item = NSToolbarItem(itemIdentifier: id)
            let label = NSTextField(labelWithString: "TreeFinder")
            label.font = .boldSystemFont(ofSize: 15)
            label.lineBreakMode = .byTruncatingTail
            item.view = label
            titleLabel = label
            return item
        case .newFolder: return button(id, "folder.badge.plus", L("New Folder"), Selector(("newFolder:")))
        case .deleteFile: return button(id, "trash", L("Move to Trash"), Selector(("deleteSelected:")))
        case .togglePreview: return button(id, "sidebar.right", L("Show/Hide Preview"), #selector(togglePreview(_:)))
        case .sortMenu:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: L("Sort By"))
            item.label = L("Sort By")
            let menu = NSMenu()
            for (title, key) in [(L("Name"), SortKey.name), (L("Date Modified"), .dateModified),
                                 (L("Date Created"), .dateCreated), (L("Size"), .size), (L("Kind"), .kind)] {
                let entry = NSMenuItem(title: title, action: #selector(applySort(_:)), keyEquivalent: "")
                entry.representedObject = key.rawValue
                menu.addItem(entry)
            }
            item.menu = menu
            return item
        case .viewSwitcher:
            // Finder식 뷰 전환 세그먼트 — 0=아이콘·1=리스트·3=갤러리, 2=컬럼만 비활성(정직한 목업)
            let symbols = ["square.grid.2x2", "list.bullet", "rectangle.split.3x1", "squares.below.rectangle"]
            let segmented = NSSegmentedControl(
                images: symbols.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) },
                trackingMode: .selectOne, target: self, action: #selector(viewSwitcherChanged(_:)))
            segmented.selectedSegment = Self.segmentIndex(of: listController?.viewStyle ?? .list)
            segmented.setEnabled(false, forSegment: 2)
            viewSegmented = segmented
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = segmented
            item.label = L("View")
            return item
        case .searchField:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = L("Search")
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            (item.searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
            searchItem = item
            return item
        default: return nil
        }
    }

    // 트래킹 세퍼레이터 없음 — 사이드바를 접고 펴도 도구모음 아이템이 이동하지 않는 정적 배치
    // 토글·◀▶는 폴더명(타이틀 라벨) 왼쪽 (2026-07-16 제작자 지시)
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .back, .forward, .windowTitle, .flexibleSpace,
         .newFolder, .deleteFile, .space, .sortMenu, .viewSwitcher, .space, .togglePreview, .searchField]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
