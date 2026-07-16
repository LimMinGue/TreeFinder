import Foundation

enum FolderSize: Equatable {
    case excluded            // ~/Library·휴지통 — 측정 안 함("—")
    case measured(Int64)
    case partial(Int64)      // 접근 불가 하위 존재 — "≥" 표기 (QC: 정확한 값처럼 보이면 안 됨)
}

/// 폴더 크기 계산의 단일 소유자 (워게임 [2026-07-16]_wargame_size_service.md · PLAYBOOK 3부 §1.2)
/// 스캔을 시작할 수 있는 코드는 이 actor뿐 — 패널·컬럼은 조회만.
actor SizeService {
    static let shared = SizeService()

    private var cache: [String: FolderSize] = [:]                  // 키 = NFC 정규화 경로 (§5 규약)
    private var inflight: [String: Task<FolderSize, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 2                                  // CPU/IO 포화 방지

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    /// TCC 함정(PLAYBOOK 2부 §1-2): 이 경로들로는 절대 하강하지 않는다 — "다른 앱 데이터" 프롬프트 방지
    /// ponytail: 경로 prefix 판정 — 심링크 우회는 로컬 홈 트리 전제라 v1 범위 밖
    static let excludedRoots = [homePath + "/Library", homePath + "/.Trash"]

    static func isExcluded(_ path: String) -> Bool {
        excludedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func key(_ url: URL) -> String {
        PathPasteboard.normalized(url.standardizedFileURL.path)
    }

    func size(for url: URL) async -> FolderSize {
        let key = Self.key(url)
        if let cached = cache[key] { return cached }
        if let task = inflight[key] { return await task.value }
        if Self.isExcluded(url.path) {
            cache[key] = .excluded
            return .excluded
        }
        let task = Task<FolderSize, Never> { [weak self] in
            await self?.acquireSlot()
            let result = await Task.detached(priority: .utility) { Self.scan(url) }.value
            await self?.releaseSlot()
            return result
        }
        inflight[key] = task
        let result = await task.value
        cache[key] = result
        inflight[key] = nil
        return result
    }

    /// 파일 조작·FSEvents 후 stale 방지 — 직계 자식만 무효화(전체 무효화는 재스캔 폭주)
    func invalidate(childrenOf directory: URL) {
        let prefix = Self.key(directory) + "/"
        for key in cache.keys where key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/") {
            cache[key] = nil
        }
        // 부모 체인도 stale — 상위 폴더 측정값 무효화
        var parent = directory
        while parent.pathComponents.count > 1 {
            cache[Self.key(parent)] = nil
            parent.deleteLastPathComponent()
        }
    }

    private func acquireSlot() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    private func releaseSlot() {
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// 재귀 합산 — 논리 크기(fileSizeKey, 클라우드 placeholder 대응 PLAYBOOK 2부 §2-7)
    nonisolated static func scan(_ root: URL) -> FolderSize {
        var total: Int64 = 0
        var partial = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in partial = true; return true }) else {
            return .partial(0)
        }
        for case let url as URL in enumerator {
            if isExcluded(url.path) {
                enumerator.skipDescendants()
                partial = true
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                partial = true
                continue
            }
            if let size = values.fileSize { total += Int64(size) }
        }
        return partial ? .partial(total) : .measured(total)
    }

    #if DEBUG
    nonisolated static func selfTest() {
        assert(isExcluded(homePath + "/Library"), "Library must be excluded")
        assert(isExcluded(homePath + "/Library/Caches/x"), "Library subtree must be excluded")
        assert(!isExcluded(homePath + "/Documents"), "Documents must not be excluded")

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("tf-size-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: tmp) }
        let sub = tmp.appendingPathComponent("sub")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        fm.createFile(atPath: tmp.appendingPathComponent("a.bin").path, contents: Data(count: 1000))
        fm.createFile(atPath: sub.appendingPathComponent("b.bin").path, contents: Data(count: 234))
        assert(scan(tmp) == .measured(1234), "recursive sum broken: \(scan(tmp))")
    }
    #endif
}
