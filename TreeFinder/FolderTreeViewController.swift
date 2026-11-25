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

    /// 이름 변경·휴지통 금지 경로 = 특수 폴더 + 그 링크 대상. ~/Documents가 /Volumes/SSD_1T/Documents를 가리키는 기기에서
    /// 볼륨 아래 실제 문서 폴더가 보호 밖이라 ⌘⌫ 한 번에 통째로 휴지통에 갈 수 있었다(출하 전 검증). 첫 사용 때 1회 계산
    /// (readlink 체인 — 특수 폴더 링크 대상의 lstat 1회 포함).
    private static let protectedPaths: Set<String> = Set(special.keys.flatMap { path in
        [path, DirectoryLister.symlinkTarget(URL(fileURLWithPath: path))?.path].compactMap { $0 }.map(PathPasteboard.normalized)
    })
    static func isProtected(_ path: String) -> Bool { protectedPaths.contains(PathPasteboard.normalized(path)) }

    static func name(forPath path: String) -> String { special[path] ?? "folder" }

    static func image(forPath path: String) -> NSImage? {
        NSImage(systemSymbolName: name(forPath: path), accessibilityDescription: nil)
    }
}

/// 트리 노드는 **메인 스레드 전용** — 자식 리스팅이 동기라 원래부터 메인에서만 쓰였고(§3),
/// 비로컬 볼륨 가드(VolumeMonitor)가 메인 격리 스냅숏이라 명시한다.
@MainActor
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
    /// 심링크 노드의 대상 경로(NFC) — 링크 아래 자식은 대상 경로로 만들어져, 부모 갱신이 대상 경로로 들어오면 링크 노드를
    /// 못 찾았다(출하 전 검증: ~/Documents 링크 기기에서 이름 변경·휴지통 후 옛 행이 남음). symlinkTarget = readlink 체인
    /// (체인 판정에 대상 lstat 1회 — 이 노드를 만든 열거의 resolvesToDirectory가 이미 대상 stat을 했으므로 새 위험 아님).
    let aliasKey: String?
    /// 경로 비교 키(NFC) 캐시 — 갱신 탐색이 폴더 감시마다(0.5초) 펼쳐 본 노드 전부를 훑으므로 매번 정규화하지 않게
    let pathKey: String
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
        self.aliasKey = DirectoryLister.symlinkTarget(url).map { PathPasteboard.normalized($0.path) }
        self.pathKey = PathPasteboard.normalized(url.standardizedFileURL.path)
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
        // 심링크 폴더는 해석 후 열거 — 안 하면 자식 0개라 확장 화살표조차 안 생긴다(§32).
        // **순서 주의**: 네트워크 볼륨 판정을 stat 이전에 한다. resolvedFolder는 대상 존재 확인(stat)을 하므로
        // 먼저 부르면 죽은 마운트에서 이미 메인 스레드가 얼어 있다 — readlink만 하는 symlinkTarget으로 가드(§3).
        if let target = DirectoryLister.symlinkTarget(url), VolumeMonitor.shared.isNonLocal(target) { return [] }
        let listURL = DirectoryLister.resolvedFolder(url)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: listURL, includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard DirectoryLister.resolvesToDirectory(u, values: v), !(v?.isPackage ?? false) else { return nil }
            return (u, v?.labelNumber ?? 0,
                    Self.customIconExists(at: u, mapped: SidebarSymbols.mappedName(forPath: u.path)))
        }
    }
}

/// 트리 Return·키패드 Enter = 선택 폴더 이름 변경 — 목록(TFTableView)과 같은 Finder 규약 (제작자 확정 2026-11-25)
final class TFOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        if code == 36 || code == 76, !event.modifierFlags.contains(.command), selectedRow >= 0 {
            onReturn?(); return
        }
        super.keyDown(with: event)
    }
}

final class FolderTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
                                      NSTextFieldDelegate {
    var onSelect: ((URL) -> Void)?
    /// 트리 폴더 이름 변경·휴지통 — 실행은 활성 페인(FileListViewController.renameFolder·moveToTrash)이 맡는다:
    /// posixRename(§38)·되돌려 놓기 기록·⌘Z를 목록과 같은 한 경로로 (제작자 지시 2026-11-25)
    var onRenameFolder: ((URL, String) -> Void)?
    var onTrashFolder: ((URL) -> Void)?
    /// 트리 포커스에서도 ⌘Z — NSWindow만 undo:에 응답해(실측) 창 자신의 빈 매니저로 가던 것을 활성 페인 매니저로 중계
    var activeUndoManager: (() -> UndoManager?)?
    /// "네트워크" 행 선택 — 목록을 네트워크 브라우즈로 (Finder 패리티, 워게임 network_browse)
    var onSelectNetwork: (() -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    /// (소스들, 타깃 폴더, 복사 강제, 드롭스택 출처) — 실제 이동/복사는 FileListViewController.performDrop이 수행
    var onDropFiles: (([URL], URL, Bool, DropStackView?) -> Void)?

    private let favoritesGroup = SidebarGroup(L("Favorites"))
    private let locationsGroup = SidebarGroup(L("Locations"))
    private let outlineView = TFOutlineView()
    private let dropStack = DropStackView()   // 프로퍼티 승격 — 드롭 완료 비움·검증 접근 (§9 ① 2026-07-23)

    // 인라인 이름 편집 상태 — 편집 중 트리 재구성(폴더 감시 0.5초·앱 복귀·볼륨 변화)이 행을 다시 그리면 편집기가 닫히며
    // 반쯤 친 이름이 확정된다(§30 같은 함정). 그동안 미뤘다가 끝나고 1회 실행 — 같은 종류는 키로 합친다.
    private var editingNode: FolderNode?
    private var editCancelled = false
    private var editWidth: NSLayoutConstraint?   // 라벨 셀은 글자 폭만큼이라 편집 칸을 행 끝까지 넓힌다
    private var deferredWork: [(key: String, work: () -> Void)] = []   // 순서 보존 — 같은 키는 최신 1건만
    private weak var responderBeforeEdit: NSResponder?   // 확정·취소 후 돌려줄 포커스(우클릭으로 시작했으면 목록 그대로)

    private func deferWhileEditing(_ key: String, _ work: @escaping () -> Void) -> Bool {
        guard editingNode != nil else { return false }
        // 같은 키는 빼고 맨 뒤로 — 제자리 교체는 P>Q·Q>P·P>Q(다시 실행) 순서를 뒤집어 즐겨찾기를 없는 경로로 되돌렸다(2차 검증)
        deferredWork.removeAll { $0.key == key }
        deferredWork.append((key, work))
        return true
    }

    /// 미룬 작업 실행 — 이름 변경 반영이 먼저(트리 전체 새로 고침이 먼저 돌면 옛 노드가 사라져 펼침 유지가 실패, 출하 전 검증)
    private func runDeferredWork() {
        let work = deferredWork
        deferredWork = []
        (work.filter { $0.key.hasPrefix("renamed") } + work.filter { !$0.key.hasPrefix("renamed") }).forEach { $0.work() }
    }

    /// Locations = 홈 + 로컬 볼륨 + 네트워크(컨테이너) + 휴지통 (제작자 지시 2026-07-16)
    private var localLocations: [FolderNode] = FolderTreeViewController.buildLocalLocations()
    private let networkGroup = NetworkGroupMarker()
    private var trashNode = FolderTreeViewController.makeTrashNode()

    /// Locations 루트 = 홈 + 로컬 볼륨. 볼륨 목록은 VolumeMonitor 스냅숏(오프메인 계산·메모리 조회) —
    /// 종전엔 여기서 mountedVolumeURLs + 볼륨 stat을 메인에서 직접 해 죽은 네트워크 마운트에 앱이 얼 수 있었다(§3, 2026-09-05 A5).
    /// 기존 노드는 URL이 같으면 재사용 — 마운트/언마운트마다 홈 트리 확장 상태가 붕괴하지 않게(재사용 없는 호출 = 설정 변경 재구성).
    private static func buildLocalLocations(reusing existing: [FolderNode] = []) -> [FolderNode] {
        let byURL = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ([home] + VolumeMonitor.shared.localVolumes).map { url in
            byURL[url] ?? FolderNode(url: url, symbolName: url == home ? nil : "internaldrive")
        }
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
        outlineView.onReturn = { [weak self] in self?.renameSelectedFolder() }

        let menu = NSMenu()
        menu.delegate = self
        // buildMenu가 isEnabled를 직접 관리 — 자동 활성화가 "즐겨찾기에 추가" 비활성을 표시 시점에 되돌리던 것 차단(A11)
        menu.autoenablesItems = false
        outlineView.menu = menu

        outlineView.registerForDraggedTypes([.fileURL])   // 트리 폴더로 드롭 (제작자 지적 2026-07-16)

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        // Drop Stack = 사이드바 하단 고정 선반 (decisions §9 ①)
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
        // 네트워크 위치(기억 공유) 변화 → 네트워크 그룹만 갱신. 로컬 볼륨 변화는 아래 VolumeMonitor.changed가 담당(A5)
        NotificationCenter.default.addObserver(forName: .networkLocationsChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.outlineView.reloadItem(self.networkGroup, reloadChildren: true)
        }
        // 볼륨 스냅숏 준비/변화(마운트·언마운트·추출) → Locations 재구성(노드 재사용 = 홈 확장 보존) + ⏏ 버튼 재렌더
        NotificationCenter.default.addObserver(forName: VolumeMonitor.changed, object: nil, queue: .main) {
            [weak self] _ in self?.rebuildLocations()
        }
        _ = VolumeMonitor.shared   // 스냅숏 부트스트랩(첫 refresh 트리거 — 옵저버 등록 후)
        // 다른 앱·터미널에서 폴더 이름을 바꾸고 TreeFinder로 돌아오는 순간 트리 최신화 (제작자 제보 2026-07-25).
        // FSEvents 전 트리 재귀 감시는 리로드 루프·CPU 폭주로 이미 폐기된 길(§18) — 복귀 시점 1회로 대체.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            #if DEBUG
            NSLog("TREE_AUTO_REFRESH (앱 활성화)")
            #endif
            self?.refreshTree()
        }
        // 발견 호스트 변화 → 네트워크 그룹만 갱신 (제작자 지시 2026-07-23 — 트리에도 발견 목록)
        NotificationCenter.default.addObserver(forName: .networkHostsChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.outlineView.reloadItem(self.networkGroup, reloadChildren: true)
        }
        // 숨김 표시 토글 등 설정 변경 → 트리 전체 재구성(FolderNode 캐시 무효화 — 목록과 동일 소스, 제작자 지적)
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) {
            [weak self] _ in self?.rebuildAll()
        }
        // 폴더 이름 변경(목록·트리·되돌리기 공용 통지) → 부모 노드·펼침·즐겨찾기 경로 (제작자 확정 2026-11-25)
        NotificationCenter.default.addObserver(forName: .directoryRenamed, object: nil, queue: .main) { [weak self] note in
            guard let from = note.userInfo?["from"] as? URL, let to = note.userInfo?["to"] as? URL else { return }
            self?.folderRenamed(from: from, to: to)
        }
        // 폴더 휴지통 이동 → 부모 노드에서 사라지게 (지금 보는 폴더 밖이어도 — 트리에서 지운 경우)
        NotificationCenter.default.addObserver(forName: .directoryTrashed, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            self?.refreshNode(at: url.deletingLastPathComponent())
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

    /// 볼륨 스냅숏 변화 → Locations 재구성(노드 재사용 = 홈 확장 보존). 편집 중이면 끝나고.
    private func rebuildLocations() {
        if deferWhileEditing("volumes", { [weak self] in self?.rebuildLocations() }) { return }
        localLocations = Self.buildLocalLocations(reusing: localLocations)
        outlineView.reloadItem(locationsGroup, reloadChildren: true)
        outlineView.expandItem(locationsGroup)
    }

    /// 설정 변경(숨김 표시 등) → 트리 전체 재구성. 편집 중이면 끝나고.
    private func rebuildAll() {
        if deferWhileEditing("settings", { [weak self] in self?.rebuildAll() }) { return }
        localLocations = Self.buildLocalLocations()
        trashNode = Self.makeTrashNode()
        outlineView.reloadData()
        outlineView.expandItem(favoritesGroup)
        outlineView.expandItem(locationsGroup)
        outlineView.expandItem(localLocations.first)
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
        onDropFiles?(sources, target, NSEvent.modifierFlags.contains(.option),
                     info.draggingSource as? DropStackView)   // 스택 출처 = 이동/복사 메뉴 (§9 ①)
        return true
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarGroup }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is SidebarGroup) }

    // 정식 셀렉터는 shouldShowOutlineCellForItem: — 종전 이름(…CellFor:)은 프로토콜과 안 맞아 한 번도 호출되지 않는 죽은 코드였다
    // (컴파일러 "nearly matches" 경고 2건, 전체 검토 2026-09-05 A6)
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
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
        // 착탈식 볼륨(USB·외장·디스크이미지) = 네트워크와 동일 ⏏ 셀 재사용 (제작자 지시 2026-07-25, 규칙 4).
        // 판정은 VolumeMonitor 메모리 조회(메인 stat 0 — §3/§6). 부트/Data는 판정식에서 제외돼 여기 안 옴.
        if let node = item as? FolderNode, VolumeMonitor.shared.isEjectable(node.url) {
            let cell = SidebarActionCellView.make(outlineView, identifier: "volumeCell")
            cell.configure(name: node.name,
                           icon: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil),
                           actionSymbol: "eject.fill", actionLabel: L("Eject")) {
                [weak self] in self?.ejectVolume(at: node.url)
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

    // 키보드 화살표 이동용 — 마우스 클릭(선택 변경 포함)은 rowClicked(action)가 담당.
    // 종전엔 클릭 한 번에 둘 다 발화해 show()가 2회 돌았다(리스팅 취소·FSEvents 재시작 중복, 2026-09-05 A16).
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing else { return }
        if let type = NSApp.currentEvent?.type, [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(type) { return }
        let item = outlineView.item(atRow: outlineView.selectedRow)
        if item is NetworkGroupMarker {
            onSelectNetwork?()
            return
        }
        guard let url = url(of: item) else { return }
        onSelect?(url)
    }

    private var isRevealing = false

    /// 경로가 루트 자신이거나 그 하위인가 — 루트가 "/"인 경우(후행 슬래시)도 안전하게 처리
    private static func isUnder(_ path: String, _ rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// View ▸ Expand to Open Folder — 탐색을 따라 트리를 펼치고 선택 (원본 1.1.2)
    func reveal(_ url: URL) {
        // 편집 중이면 끝나고 — 행 선택이 편집기를 닫아 반쯤 친 이름이 확정된다(다른 창의 휴지통 따라가기·탐색 키, 출하 전 검증)
        if deferWhileEditing("reveal", { [weak self] in self?.reveal(url) }) { return }
        // 홈뿐 아니라 **볼륨 루트까지** 후보 — 심링크가 홈 밖(다른 볼륨)을 가리켜도 트리가 따라온다
        // (제작자 확정 2026-08-06, §32. 이 기기: ~/Documents → /Volumes/SSD_1T/Documents).
        // 가장 긴 접두(= 가장 구체적인 루트)를 고른다 — 홈과 "/"가 동시에 맞으면 홈이 이긴다.
        guard let root = localLocations
            .filter({ Self.isUnder(url.path, $0.url.path) })
            .max(by: { $0.url.path.count < $1.url.path.count }) else { return }
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
        // 편집 중 = 끝나고 트리 전체 1회(refreshTree가 이 노드도 덮는다 — 0.5초마다 와도 한 번)
        if deferWhileEditing("tree", { [weak self] in self?.refreshTree() }) { return }
        let target = PathPasteboard.normalized(url.standardizedFileURL.path)
        // 자신의 행(태그·커스텀 아이콘)은 부모의 자식 목록이 그림 — 부모도 재평가 (제작자 제보 2026-07-23)
        let parent = PathPasteboard.normalized(
            url.deletingLastPathComponent().standardizedFileURL.path)
        // 같은 폴더가 링크 노드·실경로 노드 두 곳에 보일 수 있어 일치 노드 전부.
        // 변화가 있을 때만 reloadItem — 하위 활동이 잦은 폴더에서 주기적 깜빡임 방지 (제작자 제보 2026-07-23)
        for node in materializedNodes(matching: target) + (parent != target ? materializedNodes(matching: parent) : [])
        where node.refreshChildren() {
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    /// 트리 전체 최신화 — 이미 펼쳐본(materialize된) 노드의 자식만 다시 읽는다.
    /// 다른 앱·터미널이 바꾼 폴더 이름이 트리에 옛 이름으로 남던 문제의 단일 수렴점
    /// (제작자 제보 2026-07-25 — 우클릭 "새로 고침"·앱 복귀 시 자동 갱신 공용, 규칙 4).
    /// 원인: `FolderNode.children`는 영구 캐시인데 갱신 트리거가 "지금 보고 있는 폴더"(FSEvents·refreshNode)뿐이었음.
    /// - 변화가 있는 노드만 `reloadItem` — 무변화면 다시 그리지 않는다(§18 깜빡임 규약).
    /// - 미로드 노드는 건너뜀(다음 loadChildren이 최신). 비로컬 볼륨은 **하위로 내려가지 않음**
    ///   — 동기 리스팅이라 죽은 네트워크 마운트에서 메인 스레드가 얼어붙는다(§3, 같은 함정 4회째 방어).
    func refreshTree() {
        if deferWhileEditing("tree", { [weak self] in self?.refreshTree() }) { return }
        var stack = localLocations
        while let node = stack.popLast() {
            guard node.loadedChildren != nil, !VolumeMonitor.shared.isNonLocal(node.url) else { continue }
            let changed = node.refreshChildren()
            stack.append(contentsOf: node.loadedChildren ?? [])
            if changed { outlineView.reloadItem(node, reloadChildren: true) }
        }
    }

    /// 폴더 이름 변경 반영 — 새 이름 노드는 새 객체라 펼침이 풀리므로 이어 주고, 즐겨찾기 경로도 따라간다
    /// (휴지통 이동은 즐겨찾기를 그대로 둔다 — ⌘Z로 되살리면 다시 작동, 제작자 확정 2026-11-25).
    private func folderRenamed(from: URL, to: URL) {
        // 이벤트마다 따로 쌓는다 — 한 키로 합치면 편집 중 두 번째 이름 변경이 첫 번째의 즐겨찾기 경로 수정을 지웠다(출하 전 검증)
        if deferWhileEditing("renamed:\(from.path)>\(to.path)", { [weak self] in self?.folderRenamed(from: from, to: to) }) { return }
        let fromKey = PathPasteboard.normalized(from.standardizedFileURL.path)
        // 같은 폴더가 링크 아래·실경로 아래 두 곳에 노드로 있을 수 있어 일치 노드 전부를 본다
        let wasExpanded = materializedNodes(matching: fromKey).contains { outlineView.isItemExpanded($0) }
        refreshNode(at: from.deletingLastPathComponent())
        if wasExpanded {
            materializedNodes(matching: PathPasteboard.normalized(to.standardizedFileURL.path)).forEach { outlineView.expandItem($0) }
        }
        // 저장된 배열을 기준으로 고친다 — 창마다 메모리 배열을 저장하면 다른 창에서 추가한 즐겨찾기를 덮어썼다(출하 전 검증).
        // 같은 통지를 받은 다른 창은 이미 고쳐진 값을 읽어 메모리만 맞춘다.
        let saved = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? favorites.map(\.url.path)
        let rewritten = saved.map { path -> String in
            let key = PathPasteboard.normalized(path)
            guard key == fromKey || key.hasPrefix(fromKey + "/") else { return path }
            return to.path + key.dropFirst(fromKey.count)
        }
        if rewritten != saved { UserDefaults.standard.set(rewritten, forKey: Self.favoritesKey) }
        if favorites.map(\.url.path) != rewritten {
            favorites = rewritten.map { FavoriteItem(URL(fileURLWithPath: $0)) }
            outlineView.reloadItem(favoritesGroup, reloadChildren: true)
        }
    }

    /// 트리에 실재하는 루트(홈·볼륨)와 이미 로드된 하위만 순회해 경로 일치 노드를 찾는다(미로드 노드 강제 로드 금지).
    /// 심링크 노드는 링크 대상 경로로도 일치(aliasKey).
    private func materializedNodes(matching normalizedPath: String) -> [FolderNode] {
        var found: [FolderNode] = []
        var stack = localLocations   // 휴지통은 잎이라 제외, 즐겨찾기는 FolderNode 아님
        while let node = stack.popLast() {
            if node.pathKey == normalizedPath || node.aliasKey == normalizedPath { found.append(node) }
            if let loaded = node.loadedChildren { stack.append(contentsOf: loaded) }
        }
        return found
    }

    private func materializedNode(matching normalizedPath: String) -> FolderNode? {
        materializedNodes(matching: normalizedPath).first
    }

    #if DEBUG
    /// TF_STACK_DROP — 드롭스택 접근(명시 이동/복사·비움·prune 검증)
    var debugDropStack: DropStackView { dropStack }

    /// TF_TREE_COPYPATH — 메뉴 핸들러 실구동(representedObject 배선 + NFC 창구 경유)
    func debugCopyPath(_ url: URL) {
        let item = NSMenuItem()
        item.representedObject = url
        copyPathAction(item)
    }

    /// TF_TREE_REFRESH 검증용 — 비브런시 사이드바가 스냅숏에서 백지라, 트리 노드의 실제 자식을 로그로 확인
    func debugNodeChildNames(at url: URL) -> [String] {
        let target = PathPasteboard.normalized(url.standardizedFileURL.path)
        guard let node = materializedNode(matching: target) else { return ["<노드 미발견>"] }
        return (node.loadedChildren ?? []).map {
            $0.hasCustomIcon ? "\($0.name)[custom]" : $0.name
        }
    }

    /// TF_TREE_MANUAL — 우클릭 메뉴 구성을 실제 빌드 경로로 확인(사이드바 비브런시라 스냅숏이 백지, §18 한계 우회).
    /// url=nil → 빈 공간 우클릭 재현.
    func debugMenuTitles(forNodeAt url: URL?) -> [String] {
        let item: Any? = url.flatMap { u -> Any? in
            let key = PathPasteboard.normalized(u.standardizedFileURL.path)
            // 휴지통은 Locations 잎이라 materializedNode 순회 밖 — 실제 우클릭이 넘기는 trashNode를 그대로 쓴다 (TF_EMPTY_TRASH)
            if PathPasteboard.normalized(trashNode.url.standardizedFileURL.path) == key { return trashNode }
            return materializedNode(matching: key)
        }
        let menu = NSMenu()
        buildMenu(menu, item: item)
        return menu.items.map { $0.isSeparatorItem ? "─" : "\($0.title)\($0.isEnabled ? "" : "(비활성)")" }   // 목록 메뉴 로그와 같은 형식
    }

    /// TF_TREE_NETWORK — 네트워크 그룹 확장(Bonjour 시작) 후 자식 구성을 로그로 확인
    func debugExpandNetwork() { outlineView.expandItem(networkGroup) }

    // TF_TREE_EDIT — 트리 이름 변경·휴지통·키 경로 E2E (제작자 지시 2026-11-25)
    private func debugNode(_ url: URL) -> FolderNode? {   // 화면에 보이는 노드 우선(링크·실경로 두 곳에 있을 수 있음)
        let nodes = materializedNodes(matching: PathPasteboard.normalized(url.standardizedFileURL.path))
        return nodes.first { outlineView.row(forItem: $0) >= 0 } ?? nodes.first
    }
    func debugBeginRename(_ url: URL) {   // 메뉴 '이름 변경'과 같은 진입
        guard let node = debugNode(url) else { NSLog("TREE_EDIT begin: 노드 미발견 %@", url.path); return }
        if editingNode == nil, outlineView.row(forItem: node) < 0 {
            NSLog("TREE_EDIT begin: 행 없음 %@ (부모 펼침=%d)", url.path,
                  outlineView.parent(forItem: node).map { outlineView.isItemExpanded($0) ? 1 : 0 } ?? -1)
        }
        beginRename(node)
    }
    func debugEditState() -> String {
        let responder = view.window?.firstResponder
        let editor = responder as? NSTextView
        return "editing=\(editingNode?.name ?? "nil") responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil")"
            + " text=\(editor?.string ?? "-") sel=\(editor.map { NSStringFromRange($0.selectedRange()) } ?? "-")"
            + " deferred=\(deferredWork.map { $0.key.hasPrefix("renamed") ? "renamed" : $0.key })"
    }
    /// 트리 선택 + 포커스(목록 이동 억제) — 키 경로 검증용
    func debugSelectNode(_ url: URL) {
        guard let node = debugNode(url) else { NSLog("TREE_EDIT select: 노드 미발견 %@", url.path); return }
        isRevealing = true
        outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: node)), byExtendingSelection: false)
        isRevealing = false
        view.window?.makeFirstResponder(outlineView)
    }
    func debugIsExpanded(_ url: URL) -> Bool { debugNode(url).map { outlineView.isItemExpanded($0) } ?? false }
    func debugFavoritePaths() -> [String] { favorites.map(\.url.path) }
    func debugRemoveFavorite(path: String) {
        if let favorite = favorites.first(where: { $0.url.path == path }) { remove(favorite: favorite) }
    }

    /// TF_TREE_CLICK — 홈 행 중심 좌표(창 기준) — 합성 클릭으로 A16(이중 발화) 회귀 검증
    func debugHomeRowPoint() -> NSPoint? {
        guard let home = localLocations.first else { return nil }
        let row = outlineView.row(forItem: home)
        guard row >= 0 else { return nil }
        outlineView.scrollRowToVisible(row)   // 시작 폴더 reveal이 사이드바를 아래로 스크롤해 홈 행이 창 밖에 있던 실측(hit=nil)
        outlineView.window?.contentView?.layoutSubtreeIfNeeded()
        let rect = outlineView.rect(ofRow: row)
        let point = outlineView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let hit = view.window?.contentView?.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil"
        NSLog("TREE_CLICK row=%d point=%@ hit=%@", row, NSStringFromPoint(point), hit)
        return point
    }

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
    /// TF_EJECT_TEST — 착탈식 볼륨 노드가 실제로 ⏏ 버튼 셀(SidebarActionCellView)로 렌더되는지 결정적 검증
    /// (사이드바 비브런시라 뷰 렌더 스냅숏이 백지 — 셀 실체를 직접 조회, decisions §18 한계 우회).
    func debugEjectVolume(_ path: String) { ejectVolume(at: URL(fileURLWithPath: path)) }   // TF_EJECT_DO
    func debugEjectTreeInfo() -> [String] {
        localLocations.map { node in
            let row = outlineView.row(forItem: node)
            let view = row >= 0 ? outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) : nil
            let isAction = view is SidebarActionCellView
            return "\(node.name): ejectable=\(VolumeMonitor.shared.isEjectable(node.url)) cell=\(isAction ? "⏏SidebarActionCell" : "일반")"
        }
    }
    #endif

    @objc private func rowClicked() {
        #if DEBUG
        NSLog("TREE_ROW_CLICKED row=%d selected=%d", outlineView.clickedRow, outlineView.selectedRow)
        #endif
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
        buildMenu(menu, item: outlineView.clickedRow >= 0
                  ? outlineView.item(atRow: outlineView.clickedRow) : nil)
    }

    /// 우클릭 메뉴 구성 — 클릭 행(없으면 빈 공간)을 받는 단일 소스(검증에서도 같은 경로를 씀)
    private func buildMenu(_ menu: NSMenu, item: Any?) {
        menu.removeAllItems()
        // 사용자 새로 고침 — 목록 배경 메뉴와 동일 용어·심볼(규칙 6 용어 일관성, 제작자 지시 2026-07-25)
        let refresh = NSMenuItem(title: L("Refresh"), action: #selector(refreshTreeMenu(_:)), keyEquivalent: "")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("Refresh"))
        // 빈 공간 우클릭 = 새로 고침만 (탐색기 규약 — 지금까진 빈 메뉴가 떴음)
        guard let item else {
            menu.addItem(refresh)
            return
        }
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
        // 이름 변경·휴지통 — 목록 메뉴와 같은 용어·심볼·상대 순서(경로 복사 위). 특수 폴더·즐겨찾기 행은 회색
        // (숨기지 않음 — 목록의 '파일에서 폴더 전용 항목 회색'과 같은 규칙, 제작자 확정 2026-11-25)
        let modifiable = modifiableFolder(item)
        for (title, symbol, action) in [(L("Rename"), "character.cursor.ibeam", #selector(renameFolderMenu(_:))),
                                        (L("Move to Trash"), "trash", #selector(trashFolderMenu(_:)))] {
            let mi = entry(title, symbol, action)
            mi.representedObject = modifiable
            mi.isEnabled = modifiable != nil
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        // 목록 메뉴와 동일 용어·심볼 — 트리 폴더도 경로 복사 (제작자 지시 2026-07-24)
        menu.addItem(entry(L("Copy Path"), "link", #selector(copyPathAction(_:))))
        menu.addItem(.separator())
        menu.addItem(refresh)   // 탐색·클립보드와 성격이 달라 독립 구간 (디자이너)
        menu.addItem(.separator())
        if (item as? FolderNode) === trashNode {   // 사이드바 휴지통 우클릭 = 비우기 (Finder 규약, 제작자 확정 2026-09-11)
            let empty = NSMenuItem(title: L("Empty Trash…"), action: #selector(MainWindowController.emptyTrash(_:)),
                                   keyEquivalent: "")   // target nil = 응답 체인(창 컨트롤러가 목록 컨트롤러로 중계)
            empty.image = NSImage(systemSymbolName: "trash.slash", accessibilityDescription: L("Empty Trash…"))
            empty.isEnabled = !TrashLocations.items.isEmpty   // autoenables가 꺼진 메뉴라 직접 판정
            menu.addItem(empty)
            menu.addItem(.separator())
        }

        if item is FolderNode {
            if VolumeMonitor.shared.isEjectable(url) {   // 착탈식 볼륨 = 추출 (제작자 지시 2026-07-25)
                menu.addItem(entry(L("Eject"), "eject", #selector(ejectVolumeMenu(_:))))
                menu.addItem(.separator())
            }
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

    @objc private func ejectVolumeMenu(_ sender: NSMenuItem) {   // 착탈식 볼륨 폴더 메뉴 (제작자 지시 2026-07-25)
        guard let url = sender.representedObject as? URL else { return }
        ejectVolume(at: url)
    }

    /// 트리 인라인 ⏏ 버튼·컨텍스트 메뉴 공용 — 추출 실행은 VolumeEjector 단일 합류점(규칙 4).
    private func ejectVolume(at url: URL) {
        VolumeEjector.eject(url, presenter: view.window)
    }

    /// 인라인 ⏏ 버튼과 컨텍스트 메뉴 공용 — 조용한 실패 금지 (원본 1.3.1)
    /// 추출 실행은 VolumeEjector 단일 합류점(오프메인·인플라이트 가드, §3 — 제작자 지시 2026-07-25).
    private func eject(_ network: NetworkLocationItem) {
        guard let mountPoint = network.mountPoint else { return }
        VolumeEjector.eject(mountPoint, presenter: view.window)
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

    @objc private func refreshTreeMenu(_ sender: Any?) { refreshTree() }

    // MARK: 이름 변경 · 휴지통 (제작자 지시 2026-11-25)

    /// 이름 변경·휴지통 대상 = 트리의 일반 폴더만. 제외: 루트(홈·볼륨·/)·휴지통과 그 안·
    /// 특수 폴더(데스크탑·문서 등 심볼 매핑 — Finder도 못 바꾼다)·즐겨찾기 행(바로가기).
    private func modifiableFolder(_ item: Any?) -> FolderNode? {
        guard let node = item as? FolderNode, node !== trashNode,
              !localLocations.contains(where: { $0 === node }),
              !SidebarSymbols.isProtected(node.url.path),
              !FileListViewController.isTrashPath(node.url.standardizedFileURL.path) else { return nil }
        return node
    }

    private var selectedItem: Any? { outlineView.item(atRow: outlineView.selectedRow) }
    /// 창 컨트롤러의 키 분기용 — 트리 포커스 ⌘⌫·⌘R은 트리 폴더가 대상 (제작자 확정 2026-11-25)
    var isFocused: Bool { view.window?.firstResponder === outlineView }
    var canModifySelectedFolder: Bool { modifiableFolder(selectedItem) != nil }

    func renameSelectedFolder() {
        if let node = modifiableFolder(selectedItem) { beginRename(node) }
    }

    func trashSelectedFolder() {
        if let node = modifiableFolder(selectedItem) { onTrashFolder?(node.url) }
    }

    @objc private func renameFolderMenu(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FolderNode { beginRename(node) }
    }

    @objc private func trashFolderMenu(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FolderNode { onTrashFolder?(node.url) }
    }

    // 이름 입력 중이면 입력 되돌리기 — 아니면 활성 페인의 파일 작업 (목록과 같은 판정)
    @objc func undo(_ sender: Any?) {
        (FileListViewController.fieldEditorUndoManager(in: view.window) ?? activeUndoManager?())?.undo()
    }
    @objc func redo(_ sender: Any?) {
        (FileListViewController.fieldEditorUndoManager(in: view.window) ?? activeUndoManager?())?.redo()
    }

    /// 그 행에서 바로 편집 — 표시는 로컬라이즈드 이름이지만 편집 칸은 실제 디스크 이름(':'→'/', Finder 규약)
    private func beginRename(_ node: FolderNode) {
        guard editingNode == nil else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        // makeIfNecessary: true — 방금 스크롤한 행은 셀이 아직 없어 편집이 조용히 취소된다(목록 §30 실측과 같은 함정)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        responderBeforeEdit = view.window?.firstResponder
        editingNode = node
        editCancelled = false
        field.stringValue = FileListViewController.displayName(fromDisk: node.url.lastPathComponent)
        editWidth = field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)
        editWidth?.isActive = true
        field.isEditable = true
        field.delegate = self
        // 진입 실패면 상태를 되돌린다 — editingNode가 남으면 트리 갱신이 끝없이 보류된다(출하 전 검증)
        guard view.window?.makeFirstResponder(field) == true else {
            resetEditField(field, name: node.name)
            return
        }
        field.currentEditor()?.selectAll(nil)   // 폴더 = 이름 전체('2026.10 자료'가 '2026'만 잡히던 것 — 출하 전 검증)
    }

    private func resetEditField(_ field: NSTextField, name: String) {
        editingNode = nil
        field.isEditable = false
        field.delegate = nil
        editWidth?.isActive = false
        editWidth = nil
        field.stringValue = name   // 표시 이름 복원 — 바뀌면 이름 변경 통지가 새 노드로 다시 그린다(실패해도 원래대로)
    }

    /// 확정·취소 뒤 포커스 — 편집 전 자리(트리에서 Enter로 시작 = 트리, 목록 작업 중 우클릭 = 목록). 종전엔 늘 트리로 옮겨
    /// 이어서 목록 파일을 지우려던 ⌘⌫가 트리의 현재 폴더를 지울 수 있었다(출하 전 검증).
    private var focusAfterEdit: NSResponder {
        if let previous = responderBeforeEdit, !(previous is NSText),
           (previous as? NSView)?.window === view.window { return previous }
        return outlineView
    }

    /// Esc = 취소 (Return·Tab·바깥 클릭 = 확정 — 목록과 같은 Finder 규약)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard editingNode != nil, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        editCancelled = true
        view.window?.makeFirstResponder(focusAfterEdit)   // 편집 종료 → controlTextDidEndEditing(취소 표식)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = editingNode else { return }
        let newName = field.stringValue
        resetEditField(field, name: node.name)
        // Return·Tab은 편집 전 자리로 포커스 복귀(키보드 계속), 바깥 클릭은 사용자가 고른 곳을 그대로 둔다.
        // 아래 지연 블록에서 — 지금 옮기면 아웃라인 뷰가 편집 종료 처리 끝에 자기를 다시 첫 응답자로 만든다(실측)
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        let restoreFocus = movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue
        let focusTarget = focusAfterEdit
        // 확정·미룬 작업은 마우스 추적이 끝난 뒤(기본 모드) — 다른 행을 클릭해 편집이 끝나면 mouseDown 도중 행이 바뀌어
        // 테이블이 클릭 때 잡은 행 번호로 **엉뚱한 폴더**를 선택·이동했다(출하 전 검증 실측). reloadItem은 선택을 항목 기준으로 유지.
        let url = node.url
        let cancelled = editCancelled
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if restoreFocus { self.view.window?.makeFirstResponder(focusTarget) }
                if !cancelled { self.onRenameFolder?(url, newName) }   // 빈 이름·무변경은 받는 쪽이 거른다
                self.runDeferredWork()
            }
        }
    }

    @objc private func copyPathAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        PathPasteboard.copy(url.path)   // NFC 보정 단일 창구 (decisions §5)
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
