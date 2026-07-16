import AppKit
import CoreServices

/// 정보 가져오기(Get Info) 창 — decisions §17: 읽기 전용 · Finder 전 섹션.
/// 크기 = SizeService 조회만(자체 스캔 금지 — PLAYBOOK 1부 §2.5 계약), EXIF = FileInfoFields 공용(규칙 4).
/// ponytail: 열람 중 파일 변경은 v1 스냅숏(FSEvents 추적 없음) — 요구 시 후속.
final class GetInfoWindowController: NSWindowController, NSWindowDelegate {

    /// 열린 정보 창 보관(수명 유지 — openNewWindow 패턴). 같은 항목 재호출 = 기존 창 전면 (decisions §17).
    private(set) static var open: [GetInfoWindowController] = []

    private let url: URL
    private let pathKey: String   // NFC 정규화 경로 — 중복 창 판정 키
    /// 폴더 크기 상태 — nil = 계산 중(도착 시 제자리 교체, 값→계산 중 역행 없음)
    private var folderSize: FolderSize?
    private var settingsObserver: NSObjectProtocol?

    static func show(for url: URL) {
        let key = PathPasteboard.normalized(url.standardizedFileURL.path)
        if let existing = open.first(where: { $0.pathKey == key }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = GetInfoWindowController(url: url)
        open.append(controller)
        controller.showWindow(nil)
    }

    private init(url: URL) {
        self.url = url
        self.pathKey = PathPasteboard.normalized(url.standardizedFileURL.path)
        // contentView 직접 설정 — contentViewController의 fitting-size 창 붕괴 함정(4회 실측) 회피
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = String(format: L("%@ Info"), FileManager.default.displayName(atPath: url.path))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        // center()가 다중 디스플레이 배치에서 가시 영역 밖에 놓을 수 있음(스냅숏 백지 실측) — 화면 안으로 클램프
        if let visible = (NSApp.mainWindow?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame {
            var frame = window.frame
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
            window.setFrame(frame, display: false)
        }
        startFolderSizeIfNeeded()
        // 날짜 포맷(ISO 토글) 등 설정 변경 즉시 반영 — 목록과 동일 규약
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    required init?(coder: NSCoder) { fatalError("코드 전용 생성") }

    func windowWillClose(_ notification: Notification) {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        Self.open.removeAll { $0 === self }
    }

    private func rebuild() {
        window?.contentView = buildContent()
    }

    /// 폴더 크기 — SizeService 조회만(스캔 시작 주체 단일화·캐시·"≥" 규약이 actor 소유).
    /// 비로컬 볼륨은 요청 자체를 걸지 않는다(행 걸린 마운트가 워커 점유 — 목록과 동일 가드).
    private func startFolderSizeIfNeeded() {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .volumeIsLocalKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory ?? false, !(values.isPackage ?? false) else { return }
        guard values.volumeIsLocal ?? false else {
            folderSize = .excluded   // v1: 비로컬 = 측정 안 함("—")
            rebuild()
            return
        }
        Task { [weak self] in
            guard let url = self?.url else { return }
            let size = await SizeService.shared.size(for: url)
            guard let self else { return }   // 창이 닫혔으면 늦은 결과 폐기
            self.folderSize = size
            self.rebuild()
        }
    }

    /// 크기 상태 → 표기 (measured/≥/— 3분기 — 목록 Size 컬럼과 동일 규약)
    private static func sizeText(_ size: FolderSize?, exact: Bool) -> String? {
        switch size {
        case nil: return nil
        case .excluded: return "—"
        case .partial(let bytes): return "≥ " + byteFormatter.string(fromByteCount: bytes)
        case .measured(let bytes):
            let formatted = byteFormatter.string(fromByteCount: bytes)
            guard exact else { return formatted }
            return String(format: L("%1$@ (%2$@ bytes)"), formatted,
                          exactFormatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)")
        }
    }

    // MARK: - 콘텐츠 구성

    private func buildContent() -> NSView {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 조회 실패(권한 없음 등)여도 이름·아이콘은 표시한다 — 워게임 카운터액션
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey,
                                         .creationDateKey, .contentModificationDateKey,
                                         .contentAccessDateKey, .isDirectoryKey, .isPackageKey,
                                         .hasHiddenExtensionKey, .labelNumberKey, .isUserImmutableKey]
        let values = try? url.resourceValues(forKeys: keys)
        let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)

        stack.addArrangedSubview(headerView(values: values, isFolder: isFolder))
        if let tags = tagsView(labelNumber: values?.labelNumber ?? 0) {
            stack.addArrangedSubview(tags)
        }

        addSection(to: stack, title: L("General:"), content: generalRows(values: values, isFolder: isFolder))
        addSection(to: stack, title: L("More Info:"), content: moreInfoRows(values: values))
        addSection(to: stack, title: L("Name & Extension:"), content: nameExtensionView(values: values))
        addSection(to: stack, title: L("Comments:"), content: commentsView())
        addSection(to: stack, title: L("Preview:"), content: previewView())
        addSection(to: stack, title: L("Sharing & Permissions:"), content: permissionsView())

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // 창 배경 의존 금지 — 뷰 단독 렌더(스냅숏 검증)에서도 배경이 남도록 직접 그린다(백지 스냅숏 실측)
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func headerView(values: URLResourceValues?, isFolder: Bool) -> NSView {
        let icon = NSImageView()
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 36, height: 36)
        icon.image = image

        let name = NSTextField(labelWithString: FileManager.default.displayName(atPath: url.path))
        name.font = .boldSystemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle

        let modified = NSTextField(labelWithString: String(format: L("Modified: %@"),
                                                           FileListViewController.dateText(values?.contentModificationDate)))
        modified.font = .systemFont(ofSize: 11)
        modified.textColor = .secondaryLabelColor

        let titleColumn = NSStackView(views: [name, modified])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2

        let sizeText = isFolder
            ? (Self.sizeText(folderSize, exact: false) ?? "—")
            : values?.fileSize.map { Self.byteFormatter.string(fromByteCount: Int64($0)) } ?? "—"
        let size = NSTextField(labelWithString: sizeText)
        size.font = .boldSystemFont(ofSize: 13)

        let row = NSStackView(views: [icon, titleColumn, NSView(), size])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// 태그 표시(읽기 전용) — 라벨 번호 기반, 이름 매칭 금지 (PLAYBOOK 2부 §3-2)
    private func tagsView(labelNumber: Int) -> NSView? {
        let colors = NSWorkspace.shared.fileLabelColors
        let names = NSWorkspace.shared.fileLabels
        guard labelNumber > 0, labelNumber < colors.count, labelNumber < names.count else { return nil }
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 11)
        dot.textColor = colors[labelNumber]
        let name = NSTextField(labelWithString: names[labelNumber])
        name.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [dot, name])
        row.spacing = 4
        return row
    }

    private func generalRows(values: URLResourceValues?, isFolder: Bool) -> NSView {
        let column = verticalStack()
        addRow(to: column, L("Kind"), values?.localizedTypeDescription)
        let sizeValue: String?
        if isFolder {
            sizeValue = Self.sizeText(folderSize, exact: true) ?? L("Calculating…")
        } else if let bytes = values?.fileSize {
            sizeValue = String(format: L("%1$@ (%2$@ bytes)"),
                               Self.byteFormatter.string(fromByteCount: Int64(bytes)),
                               Self.exactFormatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)")
        } else {
            sizeValue = nil
        }
        addRow(to: column, L("Size"), sizeValue)
        addRow(to: column, L("Where"), Self.locationText(for: url))
        addRow(to: column, L("Created"), Self.dateOrNil(values?.creationDate))
        addRow(to: column, L("Modified"), Self.dateOrNil(values?.contentModificationDate))

        let locked = readOnlyCheckbox(L("Locked"), checked: values?.isUserImmutable ?? false)
        column.addArrangedSubview(locked)
        return column
    }

    private func moreInfoRows(values: URLResourceValues?) -> NSView {
        let column = verticalStack()
        addRow(to: column, L("Last opened"), Self.dateOrNil(values?.contentAccessDate))

        // EXIF — 공용 빌더(FileInfoFields.exif, 미리보기 정보 테이블과 단일 경로 — 규칙 4)
        for field in FileInfoFields.exif(for: url) {
            addRow(to: column, field.label, field.value)
        }

        if column.arrangedSubviews.isEmpty {
            let empty = NSTextField(labelWithString: "—")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            column.addArrangedSubview(empty)
        }
        return column
    }

    private func nameExtensionView(values: URLResourceValues?) -> NSView {
        let column = verticalStack()
        let field = NSTextField(string: url.lastPathComponent)
        field.isEditable = false        // 읽기 전용 v1 (decisions §17)
        field.isSelectable = true
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 264).isActive = true
        column.addArrangedSubview(field)
        column.addArrangedSubview(readOnlyCheckbox(L("Hide extension"),
                                                   checked: values?.hasHiddenExtension ?? false))
        return column
    }

    private func commentsView() -> NSView {
        // Spotlight 코멘트 — 읽기 전용 표시 (decisions §17)
        let comment = (MDItemCreate(kCFAllocatorDefault, url.path as CFString))
            .flatMap { MDItemCopyAttribute($0, kMDItemFinderComment) as? String } ?? ""
        let field = NSTextField(wrappingLabelWithString: comment)
        field.font = .systemFont(ofSize: 11)
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.isBezeled = true
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 264),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return field
    }

    private func previewView() -> NSView {
        // 고해상도 아이콘 — QL 썸네일 미사용(클라우드 플레이스홀더 다운로드 트리거 방지 + 미리보기 패널과 역할 분리)
        let icon = NSImageView()
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 128, height: 128)
        icon.image = image
        let row = NSStackView(views: [NSView(), icon, NSView()])
        row.orientation = .horizontal
        row.distribution = .equalCentering
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 264).isActive = true
        return row
    }

    private func permissionsView() -> NSView {
        let column = verticalStack()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bits = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0

        let grid = NSGridView()
        grid.columnSpacing = 24
        grid.rowSpacing = 4
        func headerCell(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 10)
            field.textColor = .secondaryLabelColor
            return field
        }
        func cell(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11)
            return field
        }
        grid.addRow(with: [headerCell(L("Name")), headerCell(L("Privilege"))])
        if let owner = attrs?[.ownerAccountName] as? String {
            let display = owner == NSUserName() ? String(format: L("%@ (me)"), owner) : owner
            grid.addRow(with: [cell(display), cell(Self.privilegeText(bits >> 6))])
        }
        if let group = attrs?[.groupOwnerAccountName] as? String {
            grid.addRow(with: [cell(group), cell(Self.privilegeText(bits >> 3))])
        }
        grid.addRow(with: [cell("everyone"), cell(Self.privilegeText(bits))])
        column.addArrangedSubview(grid)
        return column
    }

    // MARK: - 공용 소부품

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// 라벨(우정렬 72pt) + 값 — 값 없으면 행 생략 (미리보기 정보 테이블과 동일 규약)
    private func addRow(to column: NSStackView, _ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        let labelField = NSTextField(labelWithString: label + ":")
        labelField.font = .systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let valueField = NSTextField(wrappingLabelWithString: value)
        valueField.font = .systemFont(ofSize: 11)
        valueField.preferredMaxLayoutWidth = 180
        let row = NSStackView(views: [labelField, valueField])
        row.alignment = .firstBaseline
        row.spacing = 6
        column.addArrangedSubview(row)
    }

    private func readOnlyCheckbox(_ title: String, checked: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = checked ? .on : .off
        box.isEnabled = false           // 읽기 전용 v1 (decisions §17)
        box.font = .systemFont(ofSize: 11)
        return box
    }

    private func addSection(to stack: NSStackView, title: String, content: NSView) {
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down",
                                                 accessibilityDescription: nil) ?? NSImage())
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .boldSystemFont(ofSize: 11)
        let header = NSStackView(views: [chevron, titleField])
        header.spacing = 4
        stack.addArrangedSubview(header)

        content.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(content)
        // 섹션 본문 들여쓰기 — 헤더 아래 8pt
        stack.setCustomSpacing(6, after: header)
    }

    // MARK: - 값 도우미

    private static let byteFormatter = ByteCountFormatter()
    private static let exactFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func dateOrNil(_ date: Date?) -> String? {
        guard date != nil else { return nil }
        let text = FileListViewController.dateText(date)
        return text == "—" ? nil : text
    }

    /// 위치 행 — 로컬라이즈드 표시 이름 브레드크럼(하단 경로 바와 동일 규약)
    private static func locationText(for url: URL) -> String {
        var parts: [String] = []
        var current = url.standardizedFileURL.deletingLastPathComponent()
        while current.path.count > 1 {
            parts.append(FileManager.default.displayName(atPath: current.path))
            current = current.deletingLastPathComponent()
        }
        parts.append(FileManager.default.displayName(atPath: "/"))
        return parts.reversed().joined(separator: " ▸ ")
    }

    /// POSIX 권한 3비트 → Finder식 권한 문구 (실행 비트는 Finder처럼 표시 생략)
    private static func privilegeText(_ bits: Int) -> String {
        switch (bits & 0b100 != 0, bits & 0b010 != 0) {
        case (true, true): return L("Read & Write")
        case (true, false): return L("Read only")
        case (false, true): return L("Write only")
        case (false, false): return L("No Access")
        }
    }
}
