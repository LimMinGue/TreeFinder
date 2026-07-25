import AppKit
import Quartz
import QuickLookThumbnailing

/// 파일 목록 뷰 스타일 — 도구모음 세그먼트 0=icons·1=list·3=gallery (2=columns 미구현 비활성)
/// 탭별 상태(TabState.viewStyle)로 기억. 워게임 [2026-07-16]_wargame_icon_gallery_view.md
enum ViewStyle: String {
    case icons, list, columns, gallery
}

/// 아이콘 그리드 치수 단일 소스(규칙 4) — 슬라이더가 조절하는 "아이콘 한 변(pt)" 기준 파생.
/// (제작자 지시 2026-07-25: 아이콘 크기 슬라이더.) 기존 고정값(아이콘 64·백드롭 72·아이템 100×112)이 기본.
enum IconGridMetrics {
    static let minSide: CGFloat = 40
    static let maxSide: CGFloat = 128
    static let defaultSide: CGFloat = 64
    /// 저장된 아이콘 크기(없으면 64), 범위 클램프.
    static var side: CGFloat {
        let raw = UserDefaults.standard.object(forKey: SettingsKeys.iconSize) as? Double ?? Double(defaultSide)
        return min(max(CGFloat(raw), minSide), maxSide)
    }
    static func itemSize(_ side: CGFloat) -> NSSize { NSSize(width: side + 36, height: side + 48) }
    static func backdrop(_ side: CGFloat) -> CGFloat { side + 8 }
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
    // 아이콘 크기 슬라이더용 — 상수를 조절해 백드롭·아이콘 크기 스케일 (제작자 지시 2026-07-25)
    private var backdropW: NSLayoutConstraint!
    private var backdropH: NSLayoutConstraint!
    private var iconW: NSLayoutConstraint!
    private var iconH: NSLayoutConstraint!
    private var gridSide: CGFloat = IconGridMetrics.defaultSide

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
        // 그리드: 백드롭(아이콘+8)² 상단, 아이콘(가변)² 중앙, 라벨 필 그 아래. 기본 아이콘 64/백드롭 72/아이템 100×112.
        // 크기 상수는 configure(gridSide:)에서 슬라이더 값으로 갱신 (제작자 지시 2026-07-25, 디자이너 치수 규약 유지).
        backdropW = backdrop.widthAnchor.constraint(equalToConstant: IconGridMetrics.backdrop(IconGridMetrics.defaultSide))
        backdropH = backdrop.heightAnchor.constraint(equalToConstant: IconGridMetrics.backdrop(IconGridMetrics.defaultSide))
        iconW = icon.widthAnchor.constraint(equalToConstant: IconGridMetrics.defaultSide)
        iconH = icon.heightAnchor.constraint(equalToConstant: IconGridMetrics.defaultSide)
        gridConstraints = [
            backdrop.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            backdrop.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            backdropW, backdropH,
            icon.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            iconW, iconH,
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

    func configure(item: FileItem, variant: Variant, isCut: Bool,
                   gridSide: CGFloat = IconGridMetrics.defaultSide) {
        self.variant = variant
        self.gridSide = gridSide
        representedPath = item.url.path
        NSLayoutConstraint.deactivate(gridConstraints + stripConstraints)
        NSLayoutConstraint.activate(variant == .grid ? gridConstraints : stripConstraints)
        if variant == .grid {   // 슬라이더 값 반영 — 아이콘·백드롭 크기 스케일 (제작자 지시 2026-07-25)
            iconW.constant = gridSide
            iconH.constant = gridSide
            backdropW.constant = IconGridMetrics.backdrop(gridSide)
            backdropH.constant = IconGridMetrics.backdrop(gridSide)
            nameLabel.preferredMaxLayoutWidth = gridSide + 26
        }
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
        let side: CGFloat = variant == .grid ? gridSide : 56
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

    /// 슬라이더 드래그 중 즉시 리사이즈 — 재구성/썸네일 재요청 없이 상수만 조절(선택 보존). (제작자 지시 2026-07-25)
    func updateGridSide(_ side: CGFloat) {
        guard variant == .grid else { return }
        gridSide = side
        iconW.constant = side
        iconH.constant = side
        backdropW.constant = IconGridMetrics.backdrop(side)
        backdropH.constant = IconGridMetrics.backdrop(side)
        nameLabel.preferredMaxLayoutWidth = side + 26
    }

    /// 인라인 이름변경 진입 — 라벨을 편집 필드로 전환, 확장자 앞부분 선택 (제작자 지시 2026-07-25, Finder 규약).
    func beginEditing(fullName: String, delegate: NSTextFieldDelegate) {
        nameLabel.stringValue = fullName
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byClipping
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.isBordered = true
        nameLabel.bezelStyle = .roundedBezel
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = .textBackgroundColor
        nameLabel.textColor = .labelColor   // 선택 흰 텍스트가 흰 편집 배경에 묻히는 것 방지
        nameLabel.delegate = delegate
        view.window?.makeFirstResponder(nameLabel)
        if let editor = nameLabel.currentEditor() {
            let ns = fullName as NSString
            let dot = ns.range(of: ".", options: .backwards)
            editor.selectedRange = NSRange(location: 0, length: dot.location == NSNotFound ? ns.length : dot.location)
        }
    }

    /// 편집 종료 — 라벨 속성 원복(재사용 셀 오염 방지). 표시 문자열은 이후 configure가 재설정.
    func endEditing() {
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.delegate = nil
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
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

/// type-select IME 처리 공용(규칙 4) — 리스트·아이콘 뷰가 NSTextInputClient 메서드를 얇게 위임.
/// **조사(2026-07-25)**: keyDown의 charactersIgnoringModifiers는 한글 2벌식에서 라틴("r")만 준다(완성형·자모 아님).
/// 완성형 조합은 `inputContext.handleEvent`로 IME를 돌려야 오고, 커밋 음절은 insertText·조합중은 setMarkedText로 수신.
/// 자모→음절 전진 합성은 불필요(IME가 함). 매칭(완성형 prefix + 단일 자모 초성)은 기존 typeSelect 재사용.
final class TypeSelectController {
    var onQuery: ((String) -> Void)?
    private var committed = ""
    private var marked = ""
    private var resetTimer: Timer?
    private var query: String { committed + marked }
    var hasMarked: Bool { !marked.isEmpty }
    private var markedUTF16 = 0

    func reset() { committed = ""; marked = ""; markedUTF16 = 0; resetTimer?.invalidate(); resetTimer = nil }

    /// keyDown을 IME로 흘릴지 판정: 조합 중이면 전부(자모 삭제 등), 아니면 인쇄 문자만(화살표·삭제·수식키 제외 → super 네비게이션 보존).
    func shouldRoute(_ event: NSEvent) -> Bool {
        if hasMarked { return true }
        let mods = event.modifierFlags
        guard !mods.contains(.command), !mods.contains(.control), !mods.contains(.function) else { return false }
        guard let first = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(first) && first.value != 0x7F
    }

    func insert(_ text: String) { committed += text; marked = ""; markedUTF16 = 0; fire() }
    func setMarked(_ text: String) { marked = text; markedUTF16 = text.utf16.count; fire() }
    func unmark() { marked = ""; markedUTF16 = 0 }
    var markedRange: NSRange {
        markedUTF16 > 0 ? NSRange(location: 0, length: markedUTF16) : NSRange(location: NSNotFound, length: 0)
    }

    private func fire() {
        resetTimer?.invalidate()
        resetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.reset() }
        if !query.isEmpty { onQuery?(query) }
    }

    /// NSTextInputClient insert/setMarked의 Any(String 또는 NSAttributedString) → String
    static func string(from any: Any) -> String {
        (any as? String) ?? (any as? NSAttributedString)?.string ?? ""
    }
}

/// 더블클릭·type-select·우클릭 좌표를 노출하는 컬렉션 뷰 (clickedRow 대응물 — 워게임 §4)
/// type-select는 NSTextInputClient 경로로 한글 완성형 지원 (제작자 지시 2026-07-25, 조사 반영).
final class TFCollectionView: NSCollectionView, NSTextInputClient {
    var onDoubleClick: (() -> Void)?
    var onTypeSelect: ((String) -> Void)? { didSet { typeSelect.onQuery = onTypeSelect } }
    var onMouseDown: (() -> Void)?
    var onQuickLook: (() -> Void)?   // 스페이스바 = Quick Look (제작자 지시 2026-07-25)
    private(set) var clickedIndexPath: IndexPath?
    let typeSelect = TypeSelectController()

    override func menu(for event: NSEvent) -> NSMenu? {
        clickedIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()   // 빈 공간 클릭도 듀얼 페인 활성 승격 (제작자 제보 2026-07-23)
        super.mouseDown(with: event)   // 선택 갱신 먼저 — 직전 선택이 열리는 사고 방지 (워게임 §4)
        if event.clickCount == 2,
           indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            onDoubleClick?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 125, event.modifierFlags.contains(.command),   // ⌘↓ = 열기/진입 (Finder 규약)
           !selectionIndexPaths.isEmpty {
            onDoubleClick?()
            return
        }
        if !typeSelect.hasMarked, Int(event.keyCode) == 49,   // Space → Quick Look (Finder 규약)
           !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option) {
            onQuickLook?(); return
        }
        // 인쇄 문자·조합 중 = IME 경로(완성형 수신), 나머지(화살표 등) = super 네비게이션 (조사 §Q3)
        if typeSelect.shouldRoute(event), inputContext?.handleEvent(event) == true { return }
        super.keyDown(with: event)
    }

    // NSTextInputClient — IME가 완성형(insertText)·조합중(setMarkedText)을 여기로 전달, 나머지는 최소 스텁
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
        return window.convertToScreen(convert(bounds, to: nil))   // 후보창 위치(2벌식은 미사용, 타 IME 좌상단 방지)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
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
