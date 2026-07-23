import AppKit

final class SidebarGroup {
    let title: String
    init(_ title: String) { self.title = title }
}

final class FavoriteItem {
    let url: URL
    var name: String { FileManager.default.displayName(atPath: url.path) }
    init(_ url: URL) { self.url = url }
}

/// "네트워크" 컨테이너 행 마커 — 자식 = NetworkLocationItem (제작자 지시 2026-07-16)
final class NetworkGroupMarker {}

/// Finder식 사이드바 모노크롬 심볼 매핑 — 파란 폴더 일색 시인성 문제 (제작자 지시 2026-07-16, decisions §18)
enum SidebarSymbols {
    private static let special: [String: String] = {
        var map = ["/Applications": "a.square", "/": "internaldrive"]
        let pairs: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"),
            (.downloadsDirectory, "arrow.down.circle"),
            (.documentDirectory, "doc.text"),
            (.picturesDirectory, "photo"),
            (.musicDirectory, "music.note"),
            (.moviesDirectory, "film"),
        ]
        for (dir, symbol) in pairs {
            if let path = FileManager.default.urls(for: dir, in: .userDomainMask).first?.path {
                map[path] = symbol
            }
        }
        map[FileManager.default.homeDirectoryForCurrentUser.path] = "house"
        return map
    }()

    static func mappedName(forPath path: String) -> String? { special[path] }

    static func name(forPath path: String) -> String { special[path] ?? "folder" }

    static func image(forPath path: String) -> NSImage? {
        NSImage(systemSymbolName: name(forPath: path), accessibilityDescription: nil)
    }
}

final class FolderNode {
    let url: URL
    let name: String
    /// 사이드바 모노크롬 심볼 — 특수 폴더는 매핑, 기본 folder (SidebarSymbols)
    let symbolName: String
    /// 휴지통 등 잎 고정 — 확장 화살표 평가의 조기 리스팅(TCC 접근)을 차단
    let isLeaf: Bool
    /// 색 지정 폴더는 트리에서도 지정 색으로 (제작자 지시 2026-07-16 — 모노크롬 통일의 예외)
    let labelNumber: Int          // Finder 태그 → 심볼 틴트
    let hasCustomIcon: Bool       // 커스텀 아이콘(Icon\r) → 실제 아이콘 표시
    private var children: [FolderNode]?

    init(url: URL, symbolName: String? = nil, isLeaf: Bool = false) {
        self.url = url
        // "/" → "Macintosh HD" 등 로컬라이즈드 표시 이름 (사이드바 전용 — 목록은 실제 이름)
        self.name = FileManager.default.displayName(atPath: url.path)
        let mapped = symbolName ?? SidebarSymbols.mappedName(forPath: url.path)
        self.symbolName = mapped ?? "folder"
        self.isLeaf = isLeaf
        self.labelNumber = (try? url.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber ?? 0
        // 특수 폴더(매핑·명시 심볼)는 심볼 고정 — 아이콘 앱이 남긴 표준 모양 Icon\r을
        // 커스텀으로 오판해 파란 폴더가 되는 사례 방지 (제작자 제보 2026-07-16: 문서·다운로드)
        self.hasCustomIcon = Self.customIconExists(at: url, mapped: mapped)
    }

    /// 커스텀 아이콘 판정 단일 소스 — init과 refreshChildren 재평가 공용(규칙 4)
    static func customIconExists(at url: URL, mapped: String?) -> Bool {
        (mapped == nil) && FileManager.default.fileExists(atPath: url.path + "/Icon\r")
    }

    /// 이미 로드(펼쳐본)된 자식 — 강제 로드 없이 조회(트리 노드 탐색용). 미로드면 nil.
    var loadedChildren: [FolderNode]? { children }

    /// ponytail: 동기 리스팅 — 로컬 폴더 전제. 네트워크 볼륨 지원 시 볼륨별 레인으로 이동
    func loadChildren() -> [FolderNode] {
        if isLeaf { return [] }
        if let children { return children }
        let nodes = childDirectoryEntries().map { FolderNode(url: $0.url) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        children = nodes
        return nodes
    }

    /// 디스크 변경 반영 — 자식을 다시 읽되 URL·라벨·커스텀 아이콘이 같은 기존 노드는 재사용해 확장 상태를 보존한다.
    /// 태그(labelNumber)·커스텀 아이콘(Icon\r)이 바뀐 노드는 재생성해 표시 갱신 (제작자 제보 2026-07-23).
    /// 미로드 노드는 무연산(다음 loadChildren이 최신). 반환 = 실제 변화 여부(false면 다시 그릴 필요 없음).
    @discardableResult
    func refreshChildren() -> Bool {
        guard !isLeaf, let existing = children else { return false }
        let byURL = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let updated = childDirectoryEntries().map { entry -> FolderNode in
            if let node = byURL[entry.url], node.labelNumber == entry.label,
               node.hasCustomIcon == entry.custom { return node }   // 재사용
            return FolderNode(url: entry.url)   // 신규 or 태그·아이콘 변경 → 재생성(표시 갱신)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // 전부 재사용 + 순서 동일이면 무변화 — 하위 폴더 활동이 잦아도 트리를 다시 그리지 않는다(깜빡임 방지)
        let changed = updated.map(ObjectIdentifier.init) != existing.map(ObjectIdentifier.init)
        children = updated
        return changed
    }

    /// 자식 폴더 (URL, 라벨번호, 커스텀 아이콘) 목록 — loadChildren·refreshChildren 공용(규칙 4).
    /// labelNumber는 이미 하는 resourceValues 페치에 얹어 읽음, 커스텀 아이콘은 fileExists 1회(가벼움).
    /// 숨김 = 목록과 동일 설정, 폴더만(패키지=파일).
    private func childDirectoryEntries() -> [(url: URL, label: Int, custom: Bool)] {
        let showHidden = UserDefaults.standard.bool(forKey: SettingsKeys.showHidden)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .labelNumberKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard DirectoryLister.resolvesToDirectory(u, values: v), !(v?.isPackage ?? false) else { return nil }
            return (u, v?.labelNumber ?? 0,
                    Self.customIconExists(at: u, mapped: SidebarSymbols.mappedName(forPath: u.path)))
        }
    }
}

final class FolderTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelect: ((URL) -> Void)?
    /// "네트워크" 행 선택 — 목록을 네트워크 브라우즈로 (Finder 패리티, 워게임 network_browse)
    var onSelectNetwork: (() -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    /// (소스들, 타깃 폴더, 복사 강제) — 실제 이동/복사는 FileListViewController.performDrop이 수행
    var onDropFiles: (([URL], URL, Bool) -> Void)?

    private let favoritesGroup = SidebarGroup(L("Favorites"))
    private let locationsGroup = SidebarGroup(L("Locations"))
    private let outlineView = NSOutlineView()

    /// Locations = 홈 + 로컬 볼륨 + 네트워크(컨테이너) + 휴지통 (제작자 지시 2026-07-16)
    private var localLocations: [FolderNode] = FolderTreeViewController.buildLocalLocations()
    private let networkGroup = NetworkGroupMarker()
    private var trashNode = FolderTreeViewController.makeTrashNode()

    private static func buildLocalLocations() -> [FolderNode] {
        var nodes = [FolderNode(url: FileManager.default.homeDirectoryForCurrentUser)]
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        nodes += volumes
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? false }
            .map { FolderNode(url: $0, symbolName: "internaldrive") }
        return nodes
    }

    /// 휴지통 = 잎 노드 — 클릭 시 목록으로 탐색(FDA 없으면 목록의 기존 오류 표면화가 담당)
    private static func makeTrashNode() -> FolderNode {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return FolderNode(url: trash, symbolName: "trash", isLeaf: true)
    }

    private var networkItems: [NetworkLocationItem] { NetworkLocationStore.shared.items }

    /// 발견 호스트(Bonjour) 래퍼 캐시 — 이름→아이템 재사용으로 reload 시 identity 유지
    /// (제작자 지시 2026-07-23: 트리 네트워크에도 목록처럼 실제 발견 컴퓨터 표시)
    private var hostItemCache: [String: NetworkHostItem] = [:]
    private var networkHosts: [NetworkHostItem] {
        NetworkBrowser.shared.hosts.map { name in
            if let cached = hostItemCache[name] { return cached }
            let item = NetworkHostItem(name)
            hostItemCache[name] = item
            return item
        }
    }
    /// 네트워크 그룹 자식 = 발견 컴퓨터(위) + 기억된 공유(아래)
    private var networkChildren: [Any] { networkHosts as [Any] + networkItems as [Any] }

    private static let favoritesKey = "FavoriteURLs"

    /// UserDefaults 영속 — 최초 실행은 기본 6종으로 시딩
    private var favorites: [FavoriteItem] = {
        if let paths = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            return paths.map { FavoriteItem(URL(fileURLWithPath: $0)) }
        }
        let fm = FileManager.default
        var urls: [URL] = []
        for dir: FileManager.SearchPathDirectory in
            [.desktopDirectory, .downloadsDirectory, .documentDirectory, .picturesDirectory, .musicDirectory] {
            if let url = fm.urls(for: dir, in: .userDomainMask).first { urls.append(url) }
        }
        urls.append(URL(fileURLWithPath: "/Applications"))
        return urls.map(FavoriteItem.init)
    }()

    private func saveFavorites() {
        UserDefaults.standard.set(favorites.map(\.url.path), forKey: Self.favoritesKey)
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.autoresizesOutlineColumn = false
        outlineView.floatsGroupRows = false
        // 이미 선택된 행 재클릭도 이동해야 함(Finder 규약) — 선택 변경 통지만으로는 재클릭이 무반응
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        outlineView.registerForDraggedTypes([.fileURL])   // 트리 폴더로 드롭 (제작자 지적 2026-07-16)

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        // Drop Stack = 사이드바 하단 고정 선반 (decisions §9 ①)
        let dropStack = DropStackView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        dropStack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(dropStack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dropStack.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            dropStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            dropStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            dropStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        outlineView.expandItem(favoritesGroup)
        outlineView.expandItem(locationsGroup)
        outlineView.expandItem(localLocations.first)   // 홈만 기본 확장 — 루트/볼륨은 접힌 채
        // 볼륨 마운트/언마운트·네트워크 위치 변화 → Locations 재구성 (USB 미반영 기존 버그도 해결)
        NotificationCenter.default.addObserver(forName: .networkLocationsChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.localLocations = Self.buildLocalLocations()
            self.outlineView.reloadItem(self.locationsGroup, reloadChildren: true)
            self.outlineView.expandItem(self.locationsGroup)
        }
        // 발견 호스트 변화 → 네트워크 그룹만 갱신 (제작자 지시 2026-07-23 — 트리에도 발견 목록)
        NotificationCenter.default.addObserver(forName: .networkHostsChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.outlineView.reloadItem(self.networkGroup, reloadChildren: true)
        }
        // 숨김 표시 토글 등 설정 변경 → 트리 전체 재구성(FolderNode 캐시 무효화 — 목록과 동일 소스, 제작자 지적)
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.localLocations = Self.buildLocalLocations()
            self.trashNode = Self.makeTrashNode()
            self.outlineView.reloadData()
            self.outlineView.expandItem(self.favoritesGroup)
            self.outlineView.expandItem(self.locationsGroup)
            self.outlineView.expandItem(self.localLocations.first)
        }
        #if DEBUG
        // TF_DUMP_TREE=1 → 트리 구성 로그 검증(창 서버·비브런시 캡처가 백지인 환경의 대안 경로)
        // TF_DUMP_TREE=<경로> → 해당 폴더 자식 노드들의 심볼·태그·커스텀 아이콘 판정 로그
        if let dump = ProcessInfo.processInfo.environment["TF_DUMP_TREE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                NSLog("TREE favorites: %@", self.favorites
                    .map { "\($0.name)[\(SidebarSymbols.name(forPath: $0.url.path))]" }.joined(separator: ", "))
                NSLog("TREE locations: %@ | Network(%d) | %@[%@]",
                      self.localLocations.map { "\($0.name)[\($0.symbolName)]" }.joined(separator: ", "),
                      self.networkItems.count, self.trashNode.name, self.trashNode.symbolName)
                NSLog("TREE home children: %@",
                      self.localLocations.first?.loadChildren().map(\.name).joined(separator: ", ") ?? "")
                if dump != "1" {
                    NSLog("TREE dump %@: %@", dump, FolderNode(url: URL(fileURLWithPath: dump)).loadChildren()
                        .map { "\($0.name)[\($0.symbolName)|label=\($0.labelNumber)|custom=\($0.hasCustomIcon)]" }
                        .joined(separator: ", "))
                }
            }
        }
        #endif
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return 2
        case let group as SidebarGroup:
            // Locations = 로컬 위치들 + 네트워크(컨테이너) + 휴지통
            return group === favoritesGroup ? favorites.count : localLocations.count + 2
        case is NetworkGroupMarker: return networkChildren.count
        case let node as FolderNode: return node.loadChildren().count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: return index == 0 ? favoritesGroup : locationsGroup
        case let group as SidebarGroup:
            if group === favoritesGroup { return favorites[index] }
            if index < localLocations.count { return localLocations[index] }
            return index == localLocations.count ? networkGroup : trashNode
        case is NetworkGroupMarker: return networkChildren[index]
        case let node as FolderNode: return node.loadChildren()[index]
        default: return item as Any
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item {
        case is SidebarGroup: return true
        case is NetworkGroupMarker: return true   // 확장 시 Bonjour 시작 — 빈 상태에서도 펼쳐 검색 유도
        case let node as FolderNode: return !node.loadChildren().isEmpty
        default: return false
        }
    }

    /// 네트워크 그룹 확장 = Bonjour 브라우즈 시작(목록 진입과 동일 게이트 — 상시 탐색 안 함)
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard notification.userInfo?["NSObject"] is NetworkGroupMarker else { return }
        NetworkBrowser.shared.start()
    }

    // MARK: 드롭 타깃 (같은 볼륨=이동·다른 볼륨=복사·Option=복사 강제 — 목록과 동일 규약)

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard url(of: item) != nil,
              info.draggingPasteboard.canReadObject(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        if index != NSOutlineViewDropOnItemIndex {   // 폴더 "위" 드롭으로 고정 (사이 삽입 없음)
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let target = url(of: item),
              let sources = info.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !sources.isEmpty else { return false }
        onDropFiles?(sources, target, NSEvent.modifierFlags.contains(.option))
        return true
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarGroup }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is SidebarGroup) }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellFor item: Any) -> Bool {
        !(item is SidebarGroup)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroup {
            let id = NSUserInterfaceItemIdentifier("groupCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = group.title
            return cell
        }
        if item is NetworkGroupMarker {
            let cell = CellFactory.iconText(outlineView, identifier: .init("folderCell"))
            cell.textField?.stringValue = L("Network")
            cell.imageView?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            return cell
        }
        if let host = item as? NetworkHostItem {
            // 발견된 네트워크 컴퓨터 — 목록과 동일 소스(Bonjour), 클릭 = 연결 (제작자 지시 2026-07-23)
            let cell = CellFactory.iconText(outlineView, identifier: .init("folderCell"))
            cell.textField?.stringValue = host.name
            cell.imageView?.image = NSImage(systemSymbolName: "desktopcomputer",
                                            accessibilityDescription: nil)
            cell.imageView?.contentTintColor = nil
            cell.alphaValue = 1
            return cell
        }
        if let network = item as? NetworkLocationItem {
            let cell = SidebarActionCellView.make(outlineView, identifier: "networkCell")
            let mounted = network.mountPoint != nil
            cell.configure(name: network.name,
                           icon: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil),
                           actionSymbol: "eject.fill", actionLabel: L("Eject"),
                           actionHidden: !mounted) { [weak self] in self?.eject(network) }
            cell.alphaValue = mounted ? 1 : 0.45   // 연결 끊김 = 흐림 (원본 1.3.0)
            return cell
        }
        if let favorite = item as? FavoriteItem {
            // Explorer식 핀 — 클릭 = 즐겨찾기 해제 (제작자 지시 2026-07-16)
            let cell = SidebarActionCellView.make(outlineView, identifier: "favoriteCell")
            cell.configure(name: favorite.name,
                           icon: SidebarSymbols.image(forPath: favorite.url.path),
                           actionSymbol: "pin.fill", actionLabel: L("Remove from Favorites")) {
                [weak self] in self?.remove(favorite: favorite)
            }
            cell.alphaValue = 1
            return cell
        }
        let cell = CellFactory.iconText(outlineView, identifier: .init("folderCell"))
        if let node = item as? FolderNode {
            cell.textField?.stringValue = node.name
            // 기본 = Finder식 모노크롬 심볼(§18). 색 지정 폴더만 예외 — 커스텀 아이콘은 실제 아이콘,
            // 태그만 있으면 심볼을 라벨 색으로 틴트 (제작자 지시 2026-07-16 — CD 빨간 폴더 사례)
            if node.hasCustomIcon {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
                cell.imageView?.contentTintColor = nil
            } else {
                cell.imageView?.image = NSImage(systemSymbolName: node.symbolName,
                                                accessibilityDescription: nil)
                let colors = NSWorkspace.shared.fileLabelColors
                cell.imageView?.contentTintColor =
                    (node.labelNumber > 0 && node.labelNumber < colors.count)
                    ? colors[node.labelNumber] : nil   // 재사용 셀 리셋 겸용
            }
        }
        return cell
    }

    private func url(of item: Any?) -> URL? {
        (item as? FolderNode)?.url ?? (item as? FavoriteItem)?.url
            ?? (item as? NetworkLocationItem)?.mountPoint
    }

    // 키보드 화살표 이동용 — 마우스 재클릭은 rowClicked가 담당
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing else { return }
        let item = outlineView.item(atRow: outlineView.selectedRow)
        if item is NetworkGroupMarker {
            onSelectNetwork?()
            return
        }
        guard let url = url(of: item) else { return }
        onSelect?(url)
    }

    private var isRevealing = false

    /// View ▸ Expand to Open Folder — 탐색을 따라 트리를 펼치고 선택 (원본 1.1.2)
    func reveal(_ url: URL) {
        guard let root = localLocations.first else { return }
        let rootPath = root.url.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { return }   // 홈 트리 한정
        isRevealing = true
        defer { isRevealing = false }
        var current = root
        outlineView.expandItem(current)
        for component in url.pathComponents.dropFirst(root.url.pathComponents.count) {
            guard let next = current.loadChildren().first(where: {
                $0.url.lastPathComponent == component
            }) else { return }
            outlineView.expandItem(next)
            current = next
        }
        let row = outlineView.row(forItem: current)
        guard row >= 0, outlineView.selectedRow != row else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    /// 파일 목록의 디렉토리 내용 변경(파일 조작·FSEvents) → 대응 트리 노드만 갱신(확장 상태 보존).
    /// (제작자 지시 2026-07-23 — 트리 자동 새로고침). materialize(펼쳐본)된 노드만 대상, 없으면 무연산.
    /// 한계: FSEvents는 현재 보고 있는 폴더 하나만 감시하므로, 그 밖 위치의 폴더 변경은 여전히 미반영.
    func refreshNode(at url: URL) {
        let target = PathPasteboard.normalized(url.standardizedFileURL.path)
        // 변화가 있을 때만 reloadItem — 하위 활동이 잦은 폴더에서 주기적 깜빡임 방지 (제작자 제보 2026-07-23)
        if let node = materializedNode(matching: target), node.refreshChildren() {
            outlineView.reloadItem(node, reloadChildren: true)
        }
        // 자신의 행(태그·커스텀 아이콘)은 부모의 자식 목록이 그림 — 부모도 재평가 (제작자 제보 2026-07-23)
        let parent = PathPasteboard.normalized(
            url.deletingLastPathComponent().standardizedFileURL.path)
        if parent != target, let parentNode = materializedNode(matching: parent), parentNode.refreshChildren() {
            outlineView.reloadItem(parentNode, reloadChildren: true)
        }
    }

    /// 트리에 실재하는 루트(홈·볼륨)와 이미 로드된 하위만 순회해 경로 일치 노드를 찾는다(미로드 노드 강제 로드 금지).
    private func materializedNode(matching normalizedPath: String) -> FolderNode? {
        var stack = localLocations   // 휴지통은 잎이라 제외, 즐겨찾기는 FolderNode 아님
        while let node = stack.popLast() {
            if PathPasteboard.normalized(node.url.standardizedFileURL.path) == normalizedPath { return node }
            if let loaded = node.loadedChildren { stack.append(contentsOf: loaded) }
        }
        return nil
    }

    #if DEBUG
    /// TF_TREE_REFRESH 검증용 — 비브런시 사이드바가 스냅숏에서 백지라, 트리 노드의 실제 자식을 로그로 확인
    func debugNodeChildNames(at url: URL) -> [String] {
        let target = PathPasteboard.normalized(url.standardizedFileURL.path)
        guard let node = materializedNode(matching: target) else { return ["<노드 미발견>"] }
        return (node.loadedChildren ?? []).map {
            $0.hasCustomIcon ? "\($0.name)[custom]" : $0.name
        }
    }

    /// TF_TREE_NETWORK — 네트워크 그룹 확장(Bonjour 시작) 후 자식 구성을 로그로 확인
    func debugExpandNetwork() { outlineView.expandItem(networkGroup) }

    /// TF_TREE_SYNC — 트리 선택을 네트워크 그룹 행으로 강제(호스트 클릭·연결 실패 상황 재현)
    func debugSelectNetworkRow() {
        let row = outlineView.row(forItem: networkGroup)
        guard row >= 0 else { return }
        isRevealing = true   // onSelectNetwork 발화 억제 — 트리 선택만 이동
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRevealing = false
    }

    /// TF_TREE_SYNC — 현재 트리 선택 행의 표시명(복귀 검증용)
    func debugSelectedName() -> String {
        let item = outlineView.item(atRow: outlineView.selectedRow)
        if let node = item as? FolderNode { return "폴더:\(node.name)" }
        if item is NetworkGroupMarker { return "네트워크그룹" }
        if let host = item as? NetworkHostItem { return "호스트:\(host.name)" }
        return String(describing: item)
    }
    func debugNetworkChildren() -> [String] {
        networkChildren.map {
            if let host = $0 as? NetworkHostItem { return "호스트:\(host.name)" }
            if let share = $0 as? NetworkLocationItem {
                return "공유:\(share.name)\(share.mountPoint != nil ? "(마운트됨)" : "")"
            }
            return "?"
        }
    }
    #endif

    @objc private func rowClicked() {
        guard outlineView.clickedRow >= 0 else { return }
        let item = outlineView.item(atRow: outlineView.clickedRow)
        if item is NetworkGroupMarker {
            onSelectNetwork?()   // 네트워크 브라우즈 (Finder 패리티)
            return
        }
        if let host = item as? NetworkHostItem {
            connectHostAndOpen(host)   // 발견 컴퓨터 클릭 = 연결(목록 더블클릭과 동일 경로)
            return
        }
        if let network = item as? NetworkLocationItem, network.mountPoint == nil {
            reconnectAndOpen(network)   // 흐린 항목 원클릭 재연결 (원본 1.3.0)
            return
        }
        guard let url = url(of: item) else { return }
        onSelect?(url)   // 중복 발화는 show()의 loadTask 취소로 무해
    }

    /// 발견 호스트 연결 — NetworkBrowser.connect(서비스명 해석→NetFS 마운트→탐색) 재사용
    private func connectHostAndOpen(_ host: NetworkHostItem) {
        NetworkBrowser.shared.connect(toService: host.name) { [weak self] mountPoint in
            if let mountPoint {
                self?.onSelect?(mountPoint)
            } else {
                let alert = NSAlert()
                alert.messageText = String(format: L("Couldn't connect to %@"), host.name)
                if let window = self?.view.window { alert.beginSheetModal(for: window) }
            }
        }
    }

    private func reconnectAndOpen(_ network: NetworkLocationItem) {
        NetworkLocationStore.shared.reconnect(network) { [weak self] mountPoint in
            if let mountPoint {
                self?.onSelect?(mountPoint)
            } else {
                let alert = NSAlert()
                alert.messageText = String(format: L("Couldn't connect to %@"), network.name)
                if let window = self?.view.window { alert.beginSheetModal(for: window) }
            }
        }
    }

    // MARK: 컨텍스트 메뉴 (Add to Favorites)

    // 원본 레퍼런스 구성: Open in New Tab / New Window / Terminal ─ Add to Favorites (2026-07-16)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outlineView.clickedRow >= 0 else { return }
        let item = outlineView.item(atRow: outlineView.clickedRow)
        if let host = item as? NetworkHostItem {
            let connect = NSMenuItem(title: L("Connect"), action: #selector(connectHost(_:)), keyEquivalent: "")
            connect.target = self
            connect.representedObject = host
            connect.image = NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: L("Connect"))
            menu.addItem(connect)
            return
        }
        if let network = item as? NetworkLocationItem {
            buildNetworkMenu(menu, for: network)
            return
        }
        guard let url = url(of: item) else { return }

        func entry(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = url
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return mi
        }
        menu.addItem(entry(L("Open in New Tab"), "plus.square.on.square", #selector(openInNewTab(_:))))
        menu.addItem(entry(L("Open in New Window"), "macwindow.badge.plus", #selector(openInNewWindow(_:))))
        menu.addItem(entry(L("Open in Terminal"), "terminal", #selector(openInTerminal(_:))))
        menu.addItem(.separator())

        if item is FolderNode {
            let add = entry(L("Add to Favorites"), "pin", #selector(addFavorite(_:)))
            add.isEnabled = !favorites.contains { $0.url == url }
            menu.addItem(add)
        } else if let favorite = item as? FavoriteItem {
            let remove = entry(L("Remove from Favorites"), "pin.slash", #selector(removeFavorite(_:)))
            remove.representedObject = favorite
            menu.addItem(remove)
        }
    }

    /// 네트워크 위치 메뉴 — 마운트됨: 열기류+추출 / 끊김: 연결. 공통: 네트워크 위치 지우기 (원본 1.3.0·1.3.1)
    private func buildNetworkMenu(_ menu: NSMenu, for network: NetworkLocationItem) {
        func entry(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = network
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return mi
        }
        if let mountPoint = network.mountPoint {
            let openTab = entry(L("Open in New Tab"), "plus.square.on.square", #selector(openInNewTab(_:)))
            openTab.representedObject = mountPoint
            let openWindow = entry(L("Open in New Window"), "macwindow.badge.plus", #selector(openInNewWindow(_:)))
            openWindow.representedObject = mountPoint
            let openTerminal = entry(L("Open in Terminal"), "terminal", #selector(openInTerminal(_:)))
            openTerminal.representedObject = mountPoint
            menu.addItem(openTab)
            menu.addItem(openWindow)
            menu.addItem(openTerminal)
            menu.addItem(.separator())
            menu.addItem(entry(L("Eject"), "eject", #selector(ejectNetwork(_:))))
        } else {
            menu.addItem(entry(L("Connect"), "bolt.horizontal", #selector(connectNetwork(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(entry(L("Forget Network Location"), "pin.slash", #selector(forgetNetwork(_:))))
    }

    @objc private func connectNetwork(_ sender: NSMenuItem) {
        guard let network = sender.representedObject as? NetworkLocationItem else { return }
        reconnectAndOpen(network)
    }

    @objc private func connectHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? NetworkHostItem else { return }
        connectHostAndOpen(host)
    }

    @objc private func ejectNetwork(_ sender: NSMenuItem) {
        guard let network = sender.representedObject as? NetworkLocationItem else { return }
        eject(network)
    }

    /// 인라인 ⏏ 버튼과 컨텍스트 메뉴 공용 — 조용한 실패 금지 (원본 1.3.1)
    private func eject(_ network: NetworkLocationItem) {
        guard let mountPoint = network.mountPoint else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mountPoint)
        } catch {
            guard let window = view.window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc private func forgetNetwork(_ sender: NSMenuItem) {
        guard let network = sender.representedObject as? NetworkLocationItem else { return }
        NetworkLocationStore.shared.forget(network)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    @objc private func openInNewWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewWindow?(url)
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ExternalOpen.inTerminal(url)
    }

    /// 파일 목록 컨텍스트 메뉴의 L("Add to Favorites")도 이 경로로 들어온다
    func addFavorite(url: URL) {
        guard !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(FavoriteItem(url))
        saveFavorites()
        outlineView.reloadItem(favoritesGroup, reloadChildren: true)
        outlineView.expandItem(favoritesGroup)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        addFavorite(url: url)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let favorite = sender.representedObject as? FavoriteItem else { return }
        remove(favorite: favorite)
    }

    /// 핀 버튼과 컨텍스트 메뉴 공용
    private func remove(favorite: FavoriteItem) {
        favorites.removeAll { $0 === favorite }
        saveFavorites()
        outlineView.reloadItem(favoritesGroup, reloadChildren: true)
    }
}
