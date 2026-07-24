import AppKit

/// 대량 파일 연산의 진행률 오버레이 — 400ms 지연 후 표시(빠른 연산은 깜빡임 없음, 원본 1.1.19 규약)
@MainActor
final class OperationProgressPanel: NSView {
    var onCancel: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        // 색은 viewDidMoveToWindow에서 — init 시점 CGColor 캐시는 어피어런스 전환에 안 따라감(탭 필 버그 동일 계열)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = false
        bar.minValue = 0
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .accessoryBar
        cancel.font = .systemFont(ofSize: 11)

        for sub in [titleLabel, detailLabel, bar, cancel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 340),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bottomAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyPanelColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPanelColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPanelColors()
    }

    @objc private func cancelTapped() { onCancel?() }

    func present(in host: NSView, title: String, total: Int) {
        titleLabel.stringValue = title
        bar.maxValue = Double(total)
        bar.doubleValue = 0
        detailLabel.stringValue = ""
        guard superview !== host else { return }
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
        ])
    }

    func update(index: Int, total: Int, name: String) {
        bar.doubleValue = Double(index)
        detailLabel.stringValue = "\(index)/\(total) · \(name)"
    }

    func dismiss() { removeFromSuperview() }
}

/// 항목 단위 순회 + 진행률 + 취소 (PLAYBOOK 3부 §2.4 — 원샷 API는 진행률·취소가 필요한 순간 다시 짜게 된다)
/// 파일 연산은 detached에서 실행 — 메인 스레드 블로킹 제거(대형 폴더 복사가 UI를 얼리던 문제)
@MainActor
final class FileOperationEngine {
    struct Item {
        let name: String
        /// 블로킹 파일 연산 — 성공 시 메인에서 실행할 undo 등록 클로저를 반환
        let execute: @Sendable () throws -> (@MainActor () -> Void)?
    }

    private let panel = OperationProgressPanel()
    private let reportError: @MainActor (Error) -> Void
    private var currentTask: Task<Void, Never>?

    init(reportError: @escaping @MainActor (Error) -> Void) {
        self.reportError = reportError
        panel.onCancel = { [weak self] in self?.currentTask?.cancel() }
    }

    /// completion의 succeeded = 전 항목 완주(취소·오류 중단이면 false) — 호출측이 "완료 시에만" 후처리를
    /// 걸 수 있게 (드롭스택 비움이 취소·실패에도 실행되던 결함 교정, 적대검증 2026-07-23)
    func run(title: String, items: [Item], in host: NSView,
             completion: @escaping @MainActor (_ succeeded: Bool) -> Void) {
        guard !items.isEmpty else { completion(true); return }
        let previous = currentTask
        currentTask = Task { [weak self] in
            _ = await previous?.value   // 연산 직렬화 — 순서 섞임 방지
            guard let self else { return }
            let show = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.panel.present(in: host, title: title, total: items.count)
            }
            var failure: Error?
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }   // 취소 = 항목 경계에서 중단(완료분 유지)
                self.panel.update(index: index + 1, total: items.count, name: item.name)
                do {
                    let registerUndo = try await Task.detached(priority: .userInitiated) {
                        try item.execute()
                    }.value
                    registerUndo?()
                } catch {
                    failure = error
                    break
                }
            }
            show.cancel()
            self.panel.dismiss()
            if let failure { self.reportError(failure) }
            completion(failure == nil && !Task.isCancelled)
        }
    }
}
