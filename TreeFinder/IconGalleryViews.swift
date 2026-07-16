import AppKit
import Quartz
import QuickLookThumbnailing

/// 파일 목록 뷰 스타일 — 도구모음 세그먼트 0=icons·1=list·3=gallery (2=columns 미구현 비활성)
/// 탭별 상태(TabState.viewStyle)로 기억. 워게임 [2026-07-16]_wargame_icon_gallery_view.md
enum ViewStyle: String {
    case icons, list, gallery
}

/// QLThumbnailGenerator 결과 캐시 — 키에 수정일 포함(내용 변경 시 stale 방지), 상한 2000장 (워게임 §4)
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 2000 }

    private func key(_ item: FileItem, _ side: CGFloat) -> NSString {
        "\(PathPasteboard.normalized(item.url.path))|\(item.dateModified?.timeIntervalSince1970 ?? 0)|\(Int(side))" as NSString
    }

    func cached(for item: FileItem, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(item, side))
    }

    /// 반환 핸들은 셀 재사용·화면 이탈 시 cancel — ThumbnailsAgent(XPC) 큐 폭주 방지 (워게임 §4)
    func request(for item: FileItem, side: CGFloat,
                 completion: @escaping (NSImage) -> Void) -> QLThumbnailGenerator.Request {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let cacheKey = key(item, side)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [cache] representation, _ in
            guard let representation else { return }
            let image = representation.nsImage
            cache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async { completion(image) }
        }
        return request
    }

    func cancel(_ request: QLThumbnailGenerator.Request?) {
        guard let request else { return }
        QLThumbnailGenerator.shared.cancel(request)
    }
}

/// 라이트/다크 전환을 콜백으로 노출 — CGColor 캐시 재해석용 (탭 필 흰 배경 버그와 동일 계열 방지)
final class AppearanceObservingView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// 아이콘 그리드/갤러리 스트립 공용 셀.
/// 선택 시각(디자이너 위원 확정): 그리드 = 아이콘 라운드 백드롭 + 라벨 액센트 필(흰 텍스트),
/// 스트립 = 액센트 2pt 라운드 스트로크. 태그 틴트는 라벨 필에만 — 선택 시 액센트 필이 대체(중첩 탁함 방지).
final class FileIconItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FileIconItem")
    enum Variant { case grid, strip }

    private let backdrop = NSView()
    private let icon = NSImageView()
    private let labelPill = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var variant: Variant = .grid
    private var tagColor: NSColor?
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var representedPath = ""
    private var gridConstraints: [NSLayoutConstraint] = []
    private var stripConstraints: [NSLayoutConstraint] = []

    override func loadView() {
        let root = AppearanceObservingView()
        root.onAppearanceChange = { [weak self] in self?.refreshSelectionAppearance() }
        root.wantsLayer = true
        root.layer?.cornerRadius = 4

        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        labelPill.wantsLayer = true
        labelPill.layer?.cornerRadius = 7
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.alignment = .center
        // 2줄 랩 + 중간 생략 — 확장자 보존 (디자이너 위원, Finder 규약)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.preferredMaxLayoutWidth = 90

        for sub in [backdrop, labelPill, icon, nameLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        // 그리드 100×112: 백드롭 72² 상단, 아이콘 64² 중앙, 라벨 필 그 아래 (디자이너 위원 치수 확정)
        gridConstraints = [
            backdrop.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            backdrop.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            backdrop.widthAnchor.constraint(equalToConstant: 72),
            backdrop.heightAnchor.constraint(equalToConstant: 72),
            icon.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            labelPill.topAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: 2),
            labelPill.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            labelPill.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor),
            labelPill.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            labelPill.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            nameLabel.topAnchor.constraint(equalTo: labelPill.topAnchor, constant: 1),
            nameLabel.bottomAnchor.constraint(equalTo: labelPill.bottomAnchor, constant: -1),
            nameLabel.leadingAnchor.constraint(equalTo: labelPill.leadingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(equalTo: labelPill.trailingAnchor, constant: -5),
        ]
        // 스트립 56²: 라벨 없는 정사각 썸네일 (디자이너 위원 — Finder 갤러리 규약)
        stripConstraints = [
            icon.topAnchor.constraint(equalTo: root.topAnchor),
            icon.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ]
        view = root
    }

    func configure(item: FileItem, variant: Variant, isCut: Bool) {
        self.variant = variant
        representedPath = item.url.path
        NSLayoutConstraint.deactivate(gridConstraints + stripConstraints)
        NSLayoutConstraint.activate(variant == .grid ? gridConstraints : stripConstraints)
        backdrop.isHidden = variant == .strip
        labelPill.isHidden = variant == .strip
        nameLabel.isHidden = variant == .strip
        if variant == .grid {
            let showExtensions = UserDefaults.standard.object(forKey: SettingsKeys.alwaysExtensions) as? Bool ?? true
            nameLabel.stringValue = showExtensions
                ? item.name
                : FileManager.default.displayName(atPath: item.url.path)
        }
        let colors = NSWorkspace.shared.fileLabelColors
        tagColor = (item.labelNumber > 0 && item.labelNumber < colors.count)
            ? colors[item.labelNumber].withAlphaComponent(0.30)
            : nil
        view.alphaValue = isCut ? 0.45 : 1.0   // 잘라내기 흐림 — 리스트 α0.45와 동일 규약

        // 아이콘 즉시 표시 → 썸네일 비동기 교체 (셀 재사용 레이스는 경로 비교로 폐기)
        ThumbnailCache.shared.cancel(thumbnailRequest)
        thumbnailRequest = nil
        hasThumbnail = false
        let side: CGFloat = variant == .grid ? 64 : 56
        if let thumbnail = ThumbnailCache.shared.cached(for: item, side: side) {
            applyThumbnail(thumbnail)
        } else {
            icon.image = item.icon
            let path = representedPath
            thumbnailRequest = ThumbnailCache.shared.request(for: item, side: side) { [weak self] image in
                guard let self, self.representedPath == path else { return }
                self.applyThumbnail(image)
            }
        }
        refreshSelectionAppearance()
    }

    private var hasThumbnail = false

    private func applyThumbnail(_ image: NSImage) {
        icon.image = image
        hasThumbnail = true
        refreshSelectionAppearance()   // 헤어라인 포함 색 일괄 재적용
    }

    func cancelThumbnail() {
        ThumbnailCache.shared.cancel(thumbnailRequest)
        thumbnailRequest = nil
    }

    override var isSelected: Bool { didSet { refreshSelectionAppearance() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { refreshSelectionAppearance() } }

    private func refreshSelectionAppearance() {
        let selected = isSelected || highlightState == .forSelection
        // CGColor는 해석 시점 어피어런스로 고정 — 반드시 유효 어피어런스 컨텍스트에서 (탭 필 버그 동일 계열)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            // 썸네일 헤어라인 — 밝은/어두운 사진이 배경에 묻히는 것 방지 (디자이너 위원)
            icon.layer?.borderWidth = hasThumbnail ? 1 : 0
            icon.layer?.borderColor = NSColor.separatorColor.cgColor
            switch variant {
            case .grid:
                backdrop.layer?.backgroundColor = selected
                    ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil
                labelPill.layer?.backgroundColor = selected
                    ? NSColor.controlAccentColor.cgColor : tagColor?.cgColor
                nameLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor   // 시맨틱 (§8)
                view.layer?.borderWidth = 0
            case .strip:
                view.layer?.borderColor = NSColor.controlAccentColor.cgColor
                view.layer?.borderWidth = selected ? 2 : 0
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        icon.image = nil
        icon.layer?.borderWidth = 0
        hasThumbnail = false
        view.alphaValue = 1
        backdrop.layer?.backgroundColor = nil
        labelPill.layer?.backgroundColor = nil
        representedPath = ""
    }
}

/// 더블클릭·type-select·우클릭 좌표를 노출하는 컬렉션 뷰 (clickedRow 대응물 — 워게임 §4)
final class TFCollectionView: NSCollectionView {
    var onDoubleClick: (() -> Void)?
    var onTypeSelect: ((String) -> Void)?
    private(set) var clickedIndexPath: IndexPath?
    private var typeBuffer = ""
    private var typeResetTimer: Timer?

    override func menu(for event: NSEvent) -> NSMenu? {
        clickedIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)   // 선택 갱신 먼저 — 직전 선택이 열리는 사고 방지 (워게임 §4)
        if event.clickCount == 2,
           indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            onDoubleClick?()
        }
    }

    // type-select — NSCollectionView에는 기본 동작이 없음 (파워유저 위원, 이번 범위 포함)
    override func keyDown(with event: NSEvent) {
        if let chars = event.charactersIgnoringModifiers,
           let first = chars.unicodeScalars.first,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.function),   // 화살표 등 기능 키 제외
           CharacterSet.alphanumerics.contains(first) {
            typeBuffer += chars
            typeResetTimer?.invalidate()
            typeResetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.typeBuffer = ""
            }
            onTypeSelect?(typeBuffer)
            return
        }
        super.keyDown(with: event)
    }
}

/// 좌측 정렬 고정 그리드 — flow 레이아웃의 행별 여백 재분배로 열이 흔들리는 것 방지 (디자이너 위원)
final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let attributes = super.layoutAttributesForElements(in: rect)
            .compactMap { $0.copy() as? NSCollectionViewLayoutAttributes }
        var nextX: [CGFloat: CGFloat] = [:]   // 행(minY) → 다음 x
        for attribute in attributes.sorted(by: {
            ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
        }) {
            let rowKey = attribute.frame.minY.rounded()
            var frame = attribute.frame
            frame.origin.x = nextX[rowKey] ?? sectionInset.left
            attribute.frame = frame
            nextX[rowKey] = frame.maxX + minimumInteritemSpacing
        }
        return attributes
    }
}

/// 갤러리 대형 미리보기 — 포커스를 받지 않아 필름스트립의 화살표 탐색을 보존 (파워유저 위원)
final class PassivePreviewView: QLPreviewView {
    override var acceptsFirstResponder: Bool { false }
}
