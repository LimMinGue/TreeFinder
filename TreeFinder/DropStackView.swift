import AppKit

/// Path Finder식 Drop Stack — 여러 폴더에서 파일을 모아뒀다가 목적지에서 한 번에 끌어다 놓는 임시 선반.
/// 세션 한정(영속 없음). 앱 내부 드롭 = 이동/복사 선택 메뉴 후 완료 시 자동 비움(제작자 확정 2026-07-23).
/// 타 앱으로 드래그 아웃은 결과를 알 수 없어 유지 — ✕로 수동 비우기. (decisions §9 ①)
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

    @objc private func clearTapped() { clear() }

    /// 스택 비우기 — ✕ 버튼과 앱 내부 드롭 완료 콜백이 공용 (제작자 확정 2026-07-23)
    func clear() {
        urls = []
        refresh()
    }

    /// 소멸 파일 자동 정리 — 스택에 담긴 뒤 다른 경로로 지워진 항목이 "존재하지 않음" 오류를 내지 않게.
    /// 가드(적대검증 2026-07-23): ① 비로컬 볼륨은 판정 생략·보존 — 죽은 마운트 동기 stat이 드래그 시작
    /// 순간 메인 스레드를 얼리는 함정(volumeIsLocal 규약) + 일시 언마운트를 "소멸"로 오판 방지
    /// ② 존재 판정은 lstat 기반(attributesOfItem) — 타깃이 사라진 심링크 자체를 오삭제하지 않게
    func pruneMissing() {
        let alive = urls.filter { url in
            if let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal,
               !isLocal { return true }
            return (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
        }
        if alive.count != urls.count {
            urls = alive
            refresh()
        }
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
        pruneMissing()   // 드래그 시작 시점 정리 — 잔존 항목 오류 재발 방어 (Tester 위원)
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

    #if DEBUG
    /// TF_STACK_DROP — 드래그 인 없이 스택에 직접 적재(검증용, 실경로는 performDragOperation과 동일 append)
    func debugAdd(_ newURLs: [URL]) {
        for url in newURLs where !urls.contains(url) { urls.append(url) }
        refresh()
    }
    #endif
}
