import AppKit

/// Path Finder식 Drop Stack — 여러 폴더에서 파일을 모아뒀다가 목적지에서 한 번에 끌어다 놓는 임시 선반.
/// 세션 한정(영속 없음). 드래그 아웃해도 비워지지 않음 — ✕로 수동 비우기. (decisions §9 ①)
final class DropStackView: NSView, NSDraggingSource {
    private(set) var urls: [URL] = []
    private let titleLabel = NSTextField(labelWithString: L("Drop Stack"))
    private let hintLabel = NSTextField(labelWithString: L("Drag files here"))
    private let iconStack = NSStackView()
    private let clearButton = NSButton(title: "✕", target: nil, action: #selector(clearTapped))

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 8

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        iconStack.orientation = .horizontal
        iconStack.spacing = 2
        clearButton.target = self
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 10)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.toolTip = L("Clear")

        for sub in [titleLabel, hintLabel, iconStack, clearButton] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            clearButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconStack.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
            iconStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // 점선 테두리 — 드롭 존임을 시각화
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 4), xRadius: 7, yRadius: 7)
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }

    private func refresh() {
        titleLabel.stringValue = urls.isEmpty
            ? L("Drop Stack")
            : L("Drop Stack") + " (\(urls.count))"
        hintLabel.isHidden = !urls.isEmpty
        clearButton.isHidden = urls.isEmpty
        iconStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in urls.prefix(8) {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
            ])
            iconStack.addArrangedSubview(icon)
        }
        toolTip = urls.map(\.lastPathComponent).joined(separator: "\n")
    }

    @objc private func clearTapped() {
        urls = []
        refresh()
    }

    // MARK: 드래그 인 (수집)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropped = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !dropped.isEmpty else { return false }
        for url in dropped where !urls.contains(url) { urls.append(url) }
        refresh()
        return true
    }

    // MARK: 드래그 아웃 (일괄 전달 — 목록·트리·탭·타 앱 어디로든)

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty else { return }
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil),
                                         size: NSSize(width: 24, height: 24)),
                                  contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation { [.copy, .move] }
}
