import AppKit

/// 사이드바 행 공용 — 아이콘 + 이름 + 우측 액션 버튼(즐겨찾기 핀=해제 / 네트워크 ⏏=언마운트)
final class SidebarActionCellView: NSTableCellView {
    var onAction: (() -> Void)?
    private let actionButton = NSButton(title: "", target: nil, action: #selector(actionTapped))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        actionButton.target = self
        actionButton.isBordered = false
        actionButton.contentTintColor = .secondaryLabelColor
        // 글리프는 행 아이콘(16px)보다 한 단계 작게 (제작자 지적 2026-07-16: 핀·⏏가 너무 큼)
        actionButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        for sub in [icon, label, actionButton] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func make(_ outlineView: NSOutlineView, identifier id: String) -> SidebarActionCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        return outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarActionCellView
            ?? SidebarActionCellView(identifier: identifier)
    }

    func configure(name: String, icon: NSImage?, actionSymbol: String, actionLabel: String,
                   actionHidden: Bool = false, onAction: @escaping () -> Void) {
        textField?.stringValue = name
        imageView?.image = icon
        actionButton.image = NSImage(systemSymbolName: actionSymbol, accessibilityDescription: actionLabel)
        actionButton.toolTip = actionLabel
        actionButton.isHidden = actionHidden
        self.onAction = onAction
    }

    @objc private func actionTapped() { onAction?() }
}

/// Finder식 인라인 색 점 — 컨텍스트 메뉴에 태그 색상 7개 + 지우기(×)를 한 줄로 (제작자 지시 2026-07-23).
/// 클릭 = 선택 항목에 라벨 일괄 적용 후 메뉴 닫힘. 현재 라벨(단일)은 액센트 링으로 표시.
final class TagSwatchView: NSView {
    /// Finder 시각 순서(빨·주·노·초·파·보·회)의 labelNumber — fileLabelColors 인덱스
    private let labels = [6, 7, 5, 2, 4, 3, 1]
    private let current: Int
    private let onPick: (Int) -> Void
    private let diameter: CGFloat = 15
    private let gap: CGFloat = 11
    private let leftInset: CGFloat = 21   // 메뉴 텍스트 좌측 정렬

    init(current: Int, onPick: @escaping (Int) -> Void) {
        self.current = current
        self.onPick = onPick
        let width = leftInset + CGFloat(labels.count + 1) * (diameter + gap) + 10
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func dotRect(_ index: Int) -> NSRect {
        NSRect(x: leftInset + CGFloat(index) * (diameter + gap),
               y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = NSWorkspace.shared.fileLabelColors
        for (i, label) in labels.enumerated() {
            let r = dotRect(i)
            if label < colors.count { colors[label].setFill() }
            NSBezierPath(ovalIn: r).fill()
            NSColor.separatorColor.setStroke()
            let edge = NSBezierPath(ovalIn: r); edge.lineWidth = 0.5; edge.stroke()
            if label == current {   // 현재 라벨 = 액센트 링
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3)); ring.lineWidth = 2; ring.stroke()
            }
        }
        // 지우기(×) — 색 없음. 테두리 있는 빈 원 + × 로 또렷하게(옅은 배경에 묻히지 않게)
        let cr = dotRect(labels.count)
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(ovalIn: cr).fill()
        NSColor.tertiaryLabelColor.setStroke()
        let border = NSBezierPath(ovalIn: cr); border.lineWidth = 1; border.stroke()
        let x = NSBezierPath(); let m: CGFloat = 4.5
        x.move(to: NSPoint(x: cr.minX + m, y: cr.minY + m)); x.line(to: NSPoint(x: cr.maxX - m, y: cr.maxY - m))
        x.move(to: NSPoint(x: cr.minX + m, y: cr.maxY - m)); x.line(to: NSPoint(x: cr.maxX - m, y: cr.minY + m))
        NSColor.secondaryLabelColor.setStroke(); x.lineWidth = 1.5; x.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0...labels.count where dotRect(i).insetBy(dx: -4, dy: -4).contains(p) {
            onPick(i < labels.count ? labels[i] : 0)   // 마지막 = 지우기(0)
            enclosingMenuItem?.menu?.cancelTracking()
            return
        }
    }
}

enum CellFactory {
    static func iconText(_ outlineOrTable: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = outlineOrTable.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func text(_ table: NSTableView, identifier: NSUserInterfaceItemIdentifier,
                     alignment: NSTextAlignment = .left) -> NSTableCellView {
        if let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.alignment = alignment
        text.textColor = .secondaryLabelColor  // 메타데이터 열은 한 단계 연하게 (Explorer 1.1.14 규약)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
