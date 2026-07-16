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
