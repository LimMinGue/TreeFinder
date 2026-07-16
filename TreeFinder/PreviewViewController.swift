import AppKit
import Quartz
import SwiftTerm
import UniformTypeIdentifiers
import WebKit

/// 파일 드롭을 받는 터미널 — 드롭 = 전체 경로 입력 (Terminal.app 규약, 제작자 지시 2026-07-16)
final class DropTerminalView: LocalProcessTerminalView {
    var onDropFiles: (([URL]) -> Void)?
    /// Enter로 제출된 입력 줄 — 명령 도움말 밴드 트리거 (제작자 지시 2026-07-16)
    var onCommandSubmit: ((String) -> Void)?
    private var inputLine = ""
    private var keyMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    // keyDown은 SwiftTerm에서 open이 아니라 오버라이드 불가 — 로컬 모니터로 감청(포커스가 이 뷰일 때만)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        } else if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let self, event.window === self.window,
                   let responder = self.window?.firstResponder,
                   responder === self || (responder as? NSView)?.isDescendant(of: self) == true {
                    self.trackInput(event)
                }
                return event
            }
        }
    }

    /// ponytail: 키 입력 기반 줄 추적 — 히스토리(↑)·붙여넣기로 만든 명령은 v1 미감지(오탐보다 안전).
    private func trackInput(_ event: NSEvent) {
        guard let characters = event.characters else { return }
        for scalar in characters.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x0A:                     // Enter — 명령 제출
                let line = inputLine.trimmingCharacters(in: .whitespaces)
                inputLine = ""
                if !line.isEmpty { onCommandSubmit?(line) }
            case 0x7F, 0x08:                     // Backspace
                if !inputLine.isEmpty { inputLine.removeLast() }
            case 0x03, 0x15, 0x1B:               // Ctrl+C · Ctrl+U · ESC — 줄 취소
                inputLine = ""
            case 0x20...0x7E:                    // 인쇄 가능 ASCII
                inputLine.append(Character(scalar))
            case 0xF700...0xF8FF:                // 방향키 등 기능 키 — 추적 불가면 리셋이 오탐보다 안전
                inputLine = ""
            default:
                break
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("코드 전용 생성") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }
}

final class PreviewViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    /// 수동 동기화 버튼이 cd할 대상 — 폴더 이동 시 MainWindowController가 갱신
    var currentDirectory: URL?

    /// 갤러리 뷰 중복 방지 — 대형 프리뷰는 숨기고 정보 테이블을 상단으로 (워게임 icon_gallery §4, 디자이너 위원)
    var infoOnlyMode = false {
        didSet {
            guard oldValue != infoOnlyMode, isViewLoaded else { return }
            NSLayoutConstraint.deactivate(infoOnlyMode ? normalModeConstraints : infoOnlyConstraints)
            NSLayoutConstraint.activate(infoOnlyMode ? infoOnlyConstraints : normalModeConstraints)
            if infoOnlyMode {
                previewView.previewItem = nil   // 진입 = 재생 중단
                updateVisibility()
            } else {
                show(currentURL)                // 복귀 = QL/HWP 포함 전 경로 재구성으로 일원화
            }
        }
    }
    private var normalModeConstraints: [NSLayoutConstraint] = []
    private var infoOnlyConstraints: [NSLayoutConstraint] = []

    private let previewView = QLPreviewView(frame: .zero, style: .normal)!
    private let placeholder = NSTextField(labelWithString: L("No Selection"))
    private let tabs = NSSegmentedControl(labels: [L("Preview"), L("Terminal")],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let terminalContainer = NSView()
    private let infoStack = NSStackView()   // Get Info 수준 정보 테이블 (원본 1.5.0)
    private let syncButton = NSButton(title: L("Go to Current Folder"),
                                      image: NSImage(systemSymbolName: "folder.badge.gearshape",
                                                     accessibilityDescription: nil)!,
                                      target: nil, action: #selector(syncTerminalFolder))
    private var terminalView: LocalProcessTerminalView?
    // 명령 도움말 밴드 — 터미널 하단 분할(기본 15%, 디바이더 드래그로 조절) (제작자 지시 2026-07-16)
    private var terminalSplit: NSSplitView?
    private let terminalHelpText = NSTextView()
    private lazy var terminalHelpPane: NSScrollView = {
        terminalHelpText.isEditable = false
        terminalHelpText.textContainerInset = NSSize(width: 10, height: 8)
        terminalHelpText.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = terminalHelpText
        scroll.hasVerticalScroller = true
        return scroll
    }()
    private var observingSettings = false
    private var currentURL: URL?

    // 자체 미리보기 — HWP/HWPX(rhwp 전 페이지)·일반 이미지 공용 파이프라인 (decisions §15)
    // QLPreviewView는 배율 API가 없어 확대/축소 대상 콘텐츠는 자체 스크롤로 표시 (2026-07-16 제작자 지시)
    private let hwpPagesScroll = NSScrollView()
    private let hwpPagesStack = FlippedStackView()
    private let hwpTextScroll = NSScrollView()
    private let hwpTextView = NSTextView()
    private var customPreviewActive = false
    private var hwpResult: HWPPreview.Result?
    private var hwpLoadToken = 0   // 비동기 추출 레이스 방지 — 최신 선택만 반영

    // 확대/축소 컨트롤 (상단 밴드 좌측 — 커스텀 미리보기 활성 시에만 노출)
    private let zoomOutButton = NSButton(title: "−", target: nil, action: #selector(zoomOut))
    private let zoomInButton = NSButton(title: "+", target: nil, action: #selector(zoomIn))
    private let zoomResetButton = NSButton(title: "100%", target: nil, action: #selector(zoomReset))

    // 마크다운 에디터 — Toast UI Editor(MIT, NHN) 동반, WYSIWYG 편집+저장 (decisions §16)
    private var mdWebView: WKWebView?
    private var mdEditorLoaded = false                      // 셸 HTML 로드 완료
    private var mdPendingContent: String?                   // 로드 완료 전 대기 콘텐츠
    private var mdCurrentURL: URL?                          // 저장 대상 (선택 이동과 무관하게 유지)
    private var mdDirty = false
    private var markdownActive = false
    private let mdSaveButton = NSButton(title: "", target: nil, action: #selector(saveMarkdown))

    override func loadView() {
        let container = AppearanceObservingView()
        container.onAppearanceChange = { [weak self] in self?.rebuildMarkdownForAppearance() }

        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.shouldCloseWithWindow = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .tertiaryLabelColor

        // 터미널 영역 (자동 cd 없음 — decisions §6). 동기화 버튼 = 스위치와 같은 행 우측(디자이너 검토 반영)
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        syncButton.target = self
        syncButton.imagePosition = .imageLeading
        syncButton.bezelStyle = .accessoryBar
        syncButton.font = .systemFont(ofSize: 11)
        syncButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(syncButton)

        // 마크다운 저장 버튼 — 동기화 버튼과 같은 자리(터미널/마크다운은 동시 노출 없음), 변경 시에만
        mdSaveButton.target = self
        mdSaveButton.title = L("Save")
        mdSaveButton.bezelStyle = .accessoryBar
        mdSaveButton.font = .systemFont(ofSize: 11)
        mdSaveButton.isHidden = true
        mdSaveButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mdSaveButton)

        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        // 페이지 스크롤 — 세로 스택에 페이지 이미지들(레이아웃 규칙: 오버레이 뷰 intrinsic 무력화, §15)
        hwpPagesStack.orientation = .vertical
        hwpPagesStack.alignment = .width
        hwpPagesStack.spacing = 12
        hwpPagesStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        hwpPagesStack.translatesAutoresizingMaskIntoConstraints = false
        hwpPagesScroll.documentView = hwpPagesStack
        hwpPagesScroll.hasVerticalScroller = true
        hwpPagesScroll.hasHorizontalScroller = true   // 확대 시 가로 스크롤
        hwpPagesScroll.isHidden = true
        hwpPagesScroll.translatesAutoresizingMaskIntoConstraints = false

        // 확대/축소 — 핀치(allowsMagnification) + 버튼(−/％/+), 0.25×~5× (2026-07-16 제작자 지시)
        for scroll in [hwpPagesScroll, hwpTextScroll] {
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.25
            scroll.maxMagnification = 5.0
            NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification,
                                                   object: scroll, queue: .main) { [weak self] _ in
                self?.updateZoomLabel()
            }
        }
        for (button, tooltip) in [(zoomOutButton, L("Zoom Out")), (zoomInButton, L("Zoom In")),
                                  (zoomResetButton, L("Actual Size"))] {
            button.target = self
            button.isBordered = false
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tooltip
            button.isHidden = true
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
        }
        NSLayoutConstraint.activate([
            hwpPagesStack.topAnchor.constraint(equalTo: hwpPagesScroll.contentView.topAnchor),
            hwpPagesStack.leadingAnchor.constraint(equalTo: hwpPagesScroll.contentView.leadingAnchor),
            hwpPagesStack.widthAnchor.constraint(equalTo: hwpPagesScroll.contentView.widthAnchor),
        ])
        // 잔여 공간 흡수는 항상 preview 쪽 — intrinsic 불확정 방어 (4번째 fitting-size 실측, §15)
        previewView.setContentHuggingPriority(.init(1), for: .vertical)
        hwpTextView.isEditable = false
        hwpTextView.font = .systemFont(ofSize: 12)
        hwpTextView.textContainerInset = NSSize(width: 12, height: 12)
        hwpTextView.autoresizingMask = [.width]
        hwpTextScroll.documentView = hwpTextView
        hwpTextScroll.hasVerticalScroller = true
        hwpTextScroll.isHidden = true
        hwpTextScroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(tabs)
        container.addSubview(previewView)
        container.addSubview(hwpPagesScroll)
        container.addSubview(hwpTextScroll)
        container.addSubview(placeholder)
        container.addSubview(infoStack)
        container.addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            // 상단 컨트롤 밴드 40pt — 파일 목록 탭 스트립과 동일 높이·동일 세로 중심 (제작자 지적 2026-07-16)
            tabs.centerYAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            tabs.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            syncButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),   // 스위치와 같은 선상
            syncButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            mdSaveButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            mdSaveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            // 확대/축소 클러스터 — 밴드 좌측 (40pt 밴드 불변식 유지, §11-1)
            zoomOutButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            zoomOutButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            zoomResetButton.leadingAnchor.constraint(equalTo: zoomOutButton.trailingAnchor, constant: 6),
            zoomResetButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            zoomInButton.leadingAnchor.constraint(equalTo: zoomResetButton.trailingAnchor, constant: 6),
            zoomInButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),

            previewView.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // HWP 미리보기 뷰 2종 — QL 프리뷰와 같은 영역
            hwpPagesScroll.topAnchor.constraint(equalTo: previewView.topAnchor),
            hwpPagesScroll.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            hwpPagesScroll.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            hwpPagesScroll.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            hwpTextScroll.topAnchor.constraint(equalTo: previewView.topAnchor),
            hwpTextScroll.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            hwpTextScroll.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            hwpTextScroll.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),

            infoStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            terminalContainer.topAnchor.constraint(equalTo: previewView.topAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // 일반: 프리뷰가 위, 정보가 하단 고정 / 정보 전용(갤러리): 정보가 상단으로 (워게임 icon_gallery §4)
        normalModeConstraints = [
            previewView.bottomAnchor.constraint(equalTo: infoStack.topAnchor, constant: -10),
            infoStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ]
        infoOnlyConstraints = [
            infoStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 48),
        ]
        NSLayoutConstraint.activate(normalModeConstraints)
        view = container
        updateVisibility()
    }

    /// Get Info 수준 정보(원본 1.5.0) — 값 없는 필드는 행 생략. 이미지는 EXIF 확장(§7).
    private func rebuildInfo(for url: URL?) {
        infoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey,
                                         .creationDateKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }

        let name = NSTextField(labelWithString: FileManager.default.displayName(atPath: url.path))
        name.font = .boldSystemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        infoStack.addArrangedSubview(name)

        func row(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let labelField = NSTextField(labelWithString: label)
            labelField.font = .systemFont(ofSize: 11)
            labelField.textColor = .secondaryLabelColor
            labelField.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let valueField = NSTextField(labelWithString: value)
            valueField.font = .systemFont(ofSize: 11)
            valueField.lineBreakMode = .byTruncatingMiddle
            let rowStack = NSStackView(views: [labelField, valueField])
            rowStack.spacing = 8
            infoStack.addArrangedSubview(rowStack)
        }
        let byteFormatter = ByteCountFormatter()
        row(L("Kind"), values.localizedTypeDescription)
        row(L("Size"), values.fileSize.map { byteFormatter.string(fromByteCount: Int64($0)) })
        row(L("Created"), FileListViewController.dateText(values.creationDate) == "—" ? nil
            : FileListViewController.dateText(values.creationDate))
        row(L("Modified"), FileListViewController.dateText(values.contentModificationDate) == "—" ? nil
            : FileListViewController.dateText(values.contentModificationDate))
        row(L("Last opened"), FileListViewController.dateText(values.contentAccessDate) == "—" ? nil
            : FileListViewController.dateText(values.contentAccessDate))

        // EXIF — 공용 빌더(FileInfoFields.exif, 정보 가져오기 창과 단일 경로 — 규칙 4)
        for field in FileInfoFields.exif(for: url) {
            row(field.label, field.value)
        }
    }

    /// 확대/축소 가능 콘텐츠 판정 — HWP 계열 + 일반 이미지(QL은 배율 API가 없어 자체 뷰로)
    private static func usesCustomPreview(_ url: URL) -> Bool {
        if HWPPreview.isHWPFamily(url) { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if type?.conforms(to: .image) ?? false { return true }
        return isPlainTextCandidate(type)   // 내용 스니핑은 백그라운드에서 (제작자 지시 — 확장자 무관)
    }

    /// 시스템 타입만으로 미리보기가 안 되는 "정체불명 데이터" — 내용이 텍스트인지 스니핑할 후보.
    /// QL이 이미 잘 그리는 타입(텍스트·이미지·AV·PDF·아카이브)과 폴더는 제외 (제작자 지시 2026-07-16).
    private static func isPlainTextCandidate(_ type: UTType?) -> Bool {
        guard let type else { return true }
        for known in [UTType.text, .image, .audiovisualContent, .pdf, .archive, .directory]
        where type.conforms(to: known) { return false }
        return true
    }

    /// 내용 기반 플레인 텍스트 판정 — 확장자가 아니라 바이트로: NUL 없는 유효 UTF-8이면 텍스트.
    /// ponytail: UTF-8 한정(EUC-KR 등 레거시 인코딩은 QL 폴백) · 1MB 상한 후 생략 표기.
    private static func sniffPlainText(_ url: URL) -> String? {
        let cap = 1_000_000
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap) else { return nil }
        if data.isEmpty { return "" }   // 빈 파일도 텍스트 취급
        if data.contains(0) { return nil }   // NUL = 바이너리
        var text = String(data: data, encoding: .utf8)
        if text == nil, data.count == cap {   // 상한 경계에서 잘린 멀티바이트 방어
            for trim in 1...3 where text == nil {
                text = String(data: data.dropLast(trim), encoding: .utf8)
            }
        }
        guard let text else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > cap ? text + "\n\n… (" + L("Preview truncated") + ")" : text
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    }

    func show(_ url: URL?) {
        // 마크다운 편집 중 저장 안 된 변경 — 조용한 유실 금지: 물어보고 진행 (decisions §16)
        if mdDirty, let editing = mdCurrentURL, editing != url {
            promptSaveMarkdown(editing: editing) { [weak self] in self?.show(url) }
            return
        }
        currentURL = url
        hwpLoadToken += 1
        hwpResult = nil
        markdownActive = url.map(Self.isMarkdown) ?? false
        customPreviewActive = !markdownActive && (url.map(Self.usesCustomPreview) ?? false)
        if let url, markdownActive {
            previewView.previewItem = nil
            if !infoOnlyMode { loadMarkdown(url) }
            rebuildInfo(for: url)
            updateVisibility()
            return
        }
        if let url, customPreviewActive, !infoOnlyMode {
            previewView.previewItem = nil
            let token = hwpLoadToken
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: HWPPreview.Result?
                if HWPPreview.isHWPFamily(url) {
                    result = HWPPreview.extract(from: url)   // rhwp 전 페이지 → 내장 리소스 폴백
                } else {
                    // 이미지 → 페이지 뷰 / 정체불명 데이터가 텍스트면 → 텍스트 뷰 / 둘 다 아니면 QL 폴백
                    result = NSImage(contentsOf: url).map { HWPPreview.Result(pages: [$0], text: nil) }
                        ?? Self.sniffPlainText(url).map { HWPPreview.Result(pages: [], text: $0) }
                }
                DispatchQueue.main.async {
                    guard let self, token == self.hwpLoadToken else { return }   // 선택이 이미 이동함
                    self.applyCustomResult(result)
                }
            }
        } else {
            // 정보 전용 모드에선 숨은 QLPreviewView에 로드 금지 — 갤러리와 이중 디코딩 방지 (검증 워크플로)
            previewView.previewItem = (infoOnlyMode || customPreviewActive) ? nil : url as NSURL?
        }
        rebuildInfo(for: url)
        updateVisibility()
    }

    // MARK: 마크다운 에디터 (Toast UI Editor — decisions §16)

    private func ensureMarkdownEditor() -> WKWebView {
        if let mdWebView { return mdWebView }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "tf")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isHidden = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: previewView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
        ])
        mdWebView = webView
        if let html = Bundle.main.url(forResource: "markdown-editor", withExtension: "html"),
           let resources = Bundle.main.resourceURL {
            webView.loadFileURL(html, allowingReadAccessTo: resources)
        }
        return webView
    }

    private func loadMarkdown(_ url: URL) {
        // 같은 파일 재선택(FSEvents 재발행 포함) = 편집 상태 보존 — 에디터 리셋 금지
        guard url != mdCurrentURL else { updateVisibility(); return }
        mdCurrentURL = url
        mdDirty = false
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let webView = ensureMarkdownEditor()
        if mdEditorLoaded {
            initMarkdownEditor(webView, content: content)
        } else {
            mdPendingContent = content
        }
    }

    private func initMarkdownEditor(_ webView: WKWebView, content: String) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let data = try? JSONSerialization.data(withJSONObject: content, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("tfInit(\(json), \(dark), 'ko-KR')")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        mdEditorLoaded = true
        if let content = mdPendingContent {
            mdPendingContent = nil
            initMarkdownEditor(webView, content: content)
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "tf", let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "dirty":
            mdDirty = true
            updateVisibility()
        case "save":
            saveMarkdown()
        case "error":
            NSLog("TF markdown editor JS error: %@", body["message"] as? String ?? "?")
        default:
            break
        }
    }

    @objc private func saveMarkdown() {
        guard let url = mdCurrentURL, let webView = mdWebView else { return }
        webView.evaluateJavaScript("tfGetMarkdown()") { [weak self] result, _ in
            guard let self, let markdown = result as? String else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                self.mdDirty = false
                self.updateVisibility()
            } catch {
                guard let window = self.view.window else { return }
                let alert = NSAlert()
                alert.messageText = L("Couldn't save the file.")
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// 선택 이동 시 저장 안 된 변경 처리 — 저장/버리기 시트 후 이어서 진행
    private func promptSaveMarkdown(editing url: URL, completion: @escaping () -> Void) {
        guard let window = view.window, let webView = mdWebView else {
            mdDirty = false
            completion()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(format: L("Do you want to save changes to %@?"), url.lastPathComponent)
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Discard"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                webView.evaluateJavaScript("tfGetMarkdown()") { result, _ in
                    if let markdown = result as? String {
                        try? markdown.write(to: url, atomically: true, encoding: .utf8)
                    }
                    self.mdDirty = false
                    completion()
                }
            } else {
                self.mdDirty = false
                completion()
            }
        }
    }

    /// 라이트/다크 전환 — Toast UI 테마는 생성 시 고정이라 현재 내용 그대로 재초기화
    private func rebuildMarkdownForAppearance() {
        guard markdownActive, mdEditorLoaded, let webView = mdWebView else { return }
        webView.evaluateJavaScript("tfGetMarkdown()") { [weak self] result, _ in
            guard let self, let markdown = result as? String else { return }
            self.initMarkdownEditor(webView, content: markdown)
        }
    }

    private func applyCustomResult(_ result: HWPPreview.Result?) {
        if let result {
            hwpResult = result
            if result.pages.isEmpty {
                hwpTextView.string = result.text ?? ""
                hwpTextView.scrollToBeginningOfDocument(nil)
            } else {
                populateHWPPages(result.pages)
            }
            zoomReset()   // 새 콘텐츠 = 배율 초기화
        } else {
            // 추출 실패(손상·비표준) — QL 폴백(큰 파일 아이콘이라도 표시)
            customPreviewActive = false
            previewView.previewItem = infoOnlyMode ? nil : currentURL as NSURL?
        }
        updateVisibility()
    }

    // MARK: 확대/축소 (2026-07-16 제작자 지시 — 핀치 + 버튼, 0.25×~5×)

    private var zoomTargetScroll: NSScrollView? {
        if !hwpPagesScroll.isHidden { return hwpPagesScroll }
        if !hwpTextScroll.isHidden { return hwpTextScroll }
        return nil
    }

    @objc private func zoomIn() { applyZoom { $0 * 1.25 } }
    @objc private func zoomOut() { applyZoom { $0 / 1.25 } }
    @objc private func zoomReset() { applyZoom { _ in 1.0 } }

    private func applyZoom(_ transform: (CGFloat) -> CGFloat) {
        guard let scroll = zoomTargetScroll else { return }
        let clamped = min(max(transform(scroll.magnification), scroll.minMagnification), scroll.maxMagnification)
        // 보이는 영역 중심 유지 — 확대해도 읽던 곳이 그대로
        let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(clamped, centeredAt: center)
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        let magnification = zoomTargetScroll?.magnification ?? 1.0
        zoomResetButton.title = "\(Int((magnification * 100).rounded()))%"
    }

    /// 페이지 이미지들을 세로 스택으로 — 폭 채움 + 종횡비 고정(intrinsic 붕괴 함정 회피, §15 규칙)
    private func populateHWPPages(_ pages: [NSImage]) {
        hwpPagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for image in pages {
            let pageView = NSImageView(image: image)
            pageView.imageScaling = .scaleProportionallyUpOrDown
            pageView.wantsLayer = true
            pageView.effectiveAppearance.performAsCurrentDrawingAppearance {
                pageView.layer?.borderWidth = 1
                pageView.layer?.borderColor = NSColor.separatorColor.cgColor
            }
            pageView.translatesAutoresizingMaskIntoConstraints = false
            for axis in [NSLayoutConstraint.Orientation.vertical, .horizontal] {
                pageView.setContentHuggingPriority(.init(1), for: axis)
                pageView.setContentCompressionResistancePriority(.init(1), for: axis)
            }
            let ratio = image.size.height / max(image.size.width, 1)
            pageView.heightAnchor.constraint(equalTo: pageView.widthAnchor, multiplier: ratio).isActive = true
            hwpPagesStack.addArrangedSubview(pageView)
        }
        hwpPagesScroll.contentView.scroll(to: .zero)
    }

    @objc private func tabChanged() {
        if tabs.selectedSegment == 1 { ensureTerminal() }
        updateVisibility()
    }

    /// 셸은 창당 1개 — 탭 전환·패널 접힘에도 생존 (decisions §6)
    private func ensureTerminal() {
        guard terminalView == nil else { return }
        let terminal = DropTerminalView(frame: .zero)
        terminal.onDropFiles = { [weak self] urls in self?.typePathsInTerminal(urls) }
        terminal.onCommandSubmit = { [weak self] line in self?.updateTerminalHelp(for: line) }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        // [터미널 | 명령 도움말 밴드] 수직 분할 — 셸 재시작 시 터미널만 교체(밴드·분할 유지)
        let split: NSSplitView
        if let existing = terminalSplit {
            split = existing
        } else {
            split = NSSplitView()
            split.isVertical = false
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            split.addArrangedSubview(terminalHelpPane)
            terminalHelpPane.isHidden = true
            terminalContainer.addSubview(split, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([   // 스위치 행 바로 아래까지 꽉 차게 (제작자 지적 — 노란 선 정렬)
                split.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                split.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
                split.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            ])
            terminalSplit = split
        }
        split.insertArrangedSubview(terminal, at: 0)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        terminal.startProcess(executable: shell, execName: "-\(shellName)")   // 로그인 셸
        terminal.menu = buildTerminalMenu(for: terminal)
        terminalView = terminal
        applyTerminalFont()
        // 기본 안내를 처음부터 표시 — 레이아웃 확정 후 분할 위치 지정
        DispatchQueue.main.async { [weak self] in self?.showTerminalHelp(TerminalHelp.general) }
        if !observingSettings {
            observingSettings = true
            NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) {
                [weak self] _ in self?.applyTerminalFont()
            }
        }
    }

    /// iTerm2 컨텍스트 메뉴에서 단일 세션에 적용 가능한 항목만 (제작자 지시 2026-07-16)
    private func buildTerminalMenu(for terminal: LocalProcessTerminalView) -> NSMenu {
        let menu = NSMenu()
        func entry(_ title: String, _ symbol: String?, _ action: Selector, _ target: AnyObject?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
            return item
        }
        menu.addItem(entry(L("Copy"), "doc.on.doc", Selector(("copy:")), terminal))
        menu.addItem(entry(L("Paste"), "doc.on.clipboard", Selector(("paste:")), terminal))
        menu.addItem(entry(L("Select All"), "checklist", Selector(("selectAll:")), terminal))
        menu.addItem(.separator())
        menu.addItem(entry(L("Search the Web for Selection"), "magnifyingglass",
                           #selector(searchWebForSelection), self))
        menu.addItem(.separator())
        menu.addItem(entry(L("Go to Current Folder"), "folder.badge.gearshape",
                           #selector(syncTerminalFolder), self))
        menu.addItem(entry(L("Clear Buffer"), "xmark.rectangle", #selector(clearTerminalBuffer), self))
        menu.addItem(.separator())
        menu.addItem(entry(L("Restart Shell"), "arrow.clockwise", #selector(restartShell), self))
        return menu
    }

    @objc private func searchWebForSelection() {
        guard let text = terminalView?.getSelection(), !text.isEmpty,
              let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(query)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func clearTerminalBuffer() {
        guard let terminalView else { return }
        terminalView.getTerminal().resetToInitialState()   // 스크롤백 포함 초기화
        terminalView.send(txt: "\u{0C}")                   // Ctrl+L — 셸이 프롬프트 다시 그림
    }

    @objc private func restartShell() {
        terminalView?.removeFromSuperview()                // PTY 마스터 해제 → 기존 셸 SIGHUP
        terminalView = nil
        ensureTerminal()
        updateVisibility()
    }

    /// 터미널 폰트는 특성을 탐(파워라인 글리프 등) — Settings에서 지정 (제작자 지시 2026-07-16)
    private func applyTerminalFont() {
        guard let terminalView else { return }
        let name = UserDefaults.standard.string(forKey: SettingsKeys.terminalFontName) ?? "Menlo"
        let storedSize = UserDefaults.standard.double(forKey: SettingsKeys.terminalFontSize)
        let size = storedSize > 0 ? storedSize : 12
        terminalView.font = NSFont(name: name, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// NFC 정규화 + 단일 인용 이스케이프 — cd 동기화·파일 드롭 공용 (decisions §6 인젝션 방지)
    private static func shellQuoted(_ path: String) -> String {
        "'" + PathPasteboard.normalized(path).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 수동 동기화 — 셸 유휴 여부와 무관하게 사용자가 명시적으로 누른 경우만 cd (decisions §6)
    @objc private func syncTerminalFolder() {
        guard let terminalView, let directory = currentDirectory else { return }
        terminalView.send(txt: "cd \(Self.shellQuoted(directory.path))\n")
        view.window?.makeFirstResponder(terminalView)
    }

    /// 명령 도움말 밴드 — 터미널 열릴 때부터 표시(기본 안내), 아는 명령 실행 시 해당 치트시트로 교체.
    /// 숨기지 않는다 — "안 보여서 없는 줄 알았다" 제작자 피드백. 크기는 디바이더 드래그(기본 15%).
    private func showTerminalHelp(_ entry: TerminalHelp.Entry) {
        terminalHelpText.textStorage?.setAttributedString(TerminalHelp.render(entry))
        terminalHelpText.scrollToBeginningOfDocument(nil)
        guard terminalHelpPane.isHidden, let split = terminalSplit else { return }
        terminalHelpPane.isHidden = false
        split.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.height * 0.85, ofDividerAt: 0)   // 기본 = 하단 15%
    }

    private func updateTerminalHelp(for line: String) {
        showTerminalHelp(TerminalHelp.entry(forCommandLine: line) ?? TerminalHelp.general)
    }

    /// 파일 드롭 = 전체 경로 입력 (Terminal.app 규약 — 제작자 지시 2026-07-16).
    /// 개행 없이 경로+공백만 입력 — 명령 완성은 사용자 몫(임의 실행 금지, 보안 위원)
    private func typePathsInTerminal(_ urls: [URL]) {
        guard let terminalView, !urls.isEmpty else { return }
        let quoted = urls.map { Self.shellQuoted($0.path) }.joined(separator: " ")
        terminalView.send(txt: quoted + " ")
        view.window?.makeFirstResponder(terminalView)
    }

    #if DEBUG
    func debugShowTerminal() {   // TF_TERMINAL_TAB=1 스냅숏 검증용
        tabs.selectedSegment = 1
        tabChanged()
    }

    func debugTerminalDrop(_ path: String) {   // TF_TERMINAL_DROP=<경로> — 드롭 경로 입력 E2E 검증
        typePathsInTerminal([URL(fileURLWithPath: path)])
    }

    func debugTerminalHelp(_ line: String) {   // TF_TERMINAL_HELP=<명령> — 도움말 밴드 검증
        updateTerminalHelp(for: line)
    }

    /// TF_TERMINAL_KEYSIM=<명령> — 합성 키 이벤트로 "실제 타이핑 → 감지" 경로 E2E 검증
    /// (postEvent → sendEvent → 로컬 모니터: 실입력과 동일 디스패치 경로)
    func debugTerminalKeySim(_ text: String) {
        guard let window = view.window, let terminalView else { return }
        window.makeFirstResponder(terminalView)
        for character in text + "\r" {
            let string = String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: string, charactersIgnoringModifiers: string,
                isARepeat: false, keyCode: 0) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    func debugZoomIn() { zoomIn() }   // TF_ZOOM_TEST=1 스냅숏 검증용

    func debugMarkdownSaveTest() {   // TF_MD_SAVE_TEST=1 — 편집 주입 후 저장 경로 E2E 검증
        mdWebView?.evaluateJavaScript(
            "editor.setMarkdown('# 저장 테스트\\n\\n에디터에서 수정된 내용')") { [weak self] _, _ in
            self?.saveMarkdown()
        }
    }
    #endif

    private func updateVisibility() {
        let terminal = (tabs.selectedSegment == 1)
        terminalContainer.isHidden = !terminal
        syncButton.isHidden = !terminal   // 터미널 탭에서만 노출
        previewView.isHidden = terminal || currentURL == nil || infoOnlyMode
            || customPreviewActive || markdownActive
        let customActive = !terminal && !infoOnlyMode && customPreviewActive && currentURL != nil
        let hasPages = !(hwpResult?.pages.isEmpty ?? true)
        hwpPagesScroll.isHidden = !(customActive && hasPages)
        hwpTextScroll.isHidden = !(customActive && !hasPages && hwpResult?.text != nil)
        // 마크다운 에디터 + 저장 버튼(변경 있을 때만)
        let markdownVisible = !terminal && !infoOnlyMode && markdownActive && currentURL != nil
        mdWebView?.isHidden = !markdownVisible
        mdSaveButton.isHidden = !(markdownVisible && mdDirty)
        // 확대/축소 클러스터 — 배율 적용 가능한 자체 뷰가 보일 때만
        let zoomable = zoomTargetScroll != nil
        zoomInButton.isHidden = !zoomable
        zoomOutButton.isHidden = !zoomable
        zoomResetButton.isHidden = !zoomable
        if zoomable { updateZoomLabel() }
        placeholder.isHidden = terminal || currentURL != nil
        infoStack.isHidden = terminal || currentURL == nil
        if terminal, let terminalView { view.window?.makeFirstResponder(terminalView) }
    }
}
