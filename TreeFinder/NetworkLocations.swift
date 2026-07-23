import AppKit
import NetFS
import Network

extension Notification.Name {
    static let networkLocationsChanged = Notification.Name("TFNetworkLocationsChanged")
    static let networkHostsChanged = Notification.Name("TFNetworkHostsChanged")
}

/// 네트워크 이웃 탐색(Bonjour _smb._tcp) — Finder 네트워크 뷰 대응 (워게임 [2026-07-16]_wargame_network_browse)
@MainActor
final class NetworkBrowser {
    static let shared = NetworkBrowser()
    private(set) var hosts: [String] = []   // 발견된 서비스 이름(컴퓨터 표시명), 정렬됨
    private var browser: NWBrowser?

    /// 네트워크 뷰 첫 진입 시 시작 — 앱 수명 동안 유지(재진입 즉시 표시). ponytail: stop 없음, AFP 레거시 제외.
    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return name
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            Task { @MainActor in
                NetworkBrowser.shared.hosts = names
                NotificationCenter.default.post(name: .networkHostsChanged, object: nil)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// 서비스명 → 호스트명 해석 후 NetFS 마운트 — 인증·공유 선택은 시스템 UI(Finder 규약)
    private var connecting = false   // 더블클릭 = 해석 2회 병렬 → 취소 직후 둘째가 창을 또 띄우는 레이스 차단 (제작자 제보 2026-07-23)

    func connect(toService name: String, completion: @escaping @MainActor (URL?) -> Void) {
        guard !connecting else { return }   // 중복 클릭 = 조용히 무시
        connecting = true
        ServiceResolver(name: name) { hostName in
            Task { @MainActor in
                let fallback = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
                    .map { $0 + ".local" }
                guard let host = hostName ?? fallback, let url = URL(string: "smb://\(host)") else {
                    NetworkBrowser.shared.connecting = false
                    completion(nil)
                    return
                }
                let started = NetworkLocationStore.shared.mount(url) { mounted in
                    NetworkBrowser.shared.connecting = false
                    completion(mounted)
                }
                if !started { NetworkBrowser.shared.connecting = false }   // mount가 무시하면 가드 즉시 해제
            }
        }
    }
}

/// Bonjour 서비스명 → 실제 호스트명(서비스명 ≠ 호스트명 — 공백 있는 Mac 이름 등).
/// NetService는 deprecated지만 해석용 공개 대체 API가 없다 — ponytail: 경고 감수.
private final class ServiceResolver: NSObject, NetServiceDelegate {
    private static var active: [ServiceResolver] = []   // resolve 동안 수명 유지
    private let service: NetService
    private let completion: (String?) -> Void
    private var finished = false

    @discardableResult
    init(name: String, completion: @escaping (String?) -> Void) {
        self.service = NetService(domain: "local.", type: "_smb._tcp.", name: name)
        self.completion = completion
        super.init()
        service.delegate = self
        Self.active.append(self)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) { finish(sender.hostName) }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { finish(nil) }
    func netServiceDidStop(_ sender: NetService) { finish(nil) }

    private func finish(_ host: String?) {
        guard !finished else { return }
        finished = true
        service.stop()
        completion(host)
        Self.active.removeAll { $0 === self }
    }
}

final class NetworkLocationItem {
    let remoteURL: URL          // smb://server/share — 영속 대상 (자격 증명 아님)
    let name: String
    var mountPoint: URL?        // nil = 연결 끊김(흐림 표시)

    init(remoteURL: URL, name: String, mountPoint: URL? = nil) {
        self.remoteURL = remoteURL
        self.name = name
        self.mountPoint = mountPoint
    }

    /// 같은 공유의 다른 URL 표기(`smb://nas/home` vs `smb://NAS._smb._tcp.local/home`)를 하나로 —
    /// "home 2개" 중복 제보의 원인(문자열 완전일치 판정) 교정 (제작자 제보 2026-07-23)
    var dedupeKey: String {
        var host = (remoteURL.host ?? "").lowercased()
        if host.hasSuffix(".") { host = String(host.dropLast()) }   // FQDN 후행 점("nas.local." 실측)
        if let range = host.range(of: "._smb._tcp") { host = String(host[..<range.lowerBound]) }
        if host.hasSuffix(".local") { host = String(host.dropLast(6)) }
        return host + remoteURL.path.lowercased()
    }
}

/// 트리 네트워크 그룹의 발견 호스트 행 마커 — 이름 문자열을 그대로 아이템으로 쓰면
/// NSOutlineView identity가 깨지므로 래퍼로 (제작자 지시 2026-07-23: 트리에도 발견 목록 표시)
final class NetworkHostItem {
    let name: String
    init(_ name: String) { self.name = name }
}

/// 네트워크 위치 기억/재연결 (워게임 [2026-07-16]_wargame_network_locations.md · 원본 1.3.0)
/// 영속 = remote URL + 표시명뿐 — 비밀번호는 키체인이 처리, 앱은 절대 저장하지 않는다.
@MainActor
final class NetworkLocationStore {
    static let shared = NetworkLocationStore()
    private static let key = "RememberedNetworkLocations"

    private(set) var items: [NetworkLocationItem] = []

    private init() {
        items = Self.deduped((UserDefaults.standard.array(forKey: Self.key) as? [[String: String]] ?? [])
            .compactMap { entry in
                guard let remote = entry["remote"], let url = URL(string: remote),
                      let name = entry["name"] else { return nil }
                return NetworkLocationItem(remoteURL: url, name: name)
            })
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.refresh() }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.refresh() }
        }
        // 첫 refresh는 다음 틱으로 이연 — 정적 초기화(dispatch_once) 중 동기 notification이
        // 트리 reload → shared 재진입 → 데드락 트랩 실측 (2026-07-16 크래시 리포트)
        Task { @MainActor in self.refresh() }
    }

    private func save() {
        UserDefaults.standard.set(items.map { ["remote": $0.remoteURL.absoluteString, "name": $0.name] },
                                  forKey: Self.key)
    }

    /// 정규화 키 기준 중복 병합 — 마운트된 항목 우선 보존 (제작자 제보 2026-07-23 "home 2개")
    private static func deduped(_ list: [NetworkLocationItem]) -> [NetworkLocationItem] {
        var seen: [String: NetworkLocationItem] = [:]
        var out: [NetworkLocationItem] = []
        for item in list {
            if let existing = seen[item.dedupeKey] {
                if existing.mountPoint == nil, let mount = item.mountPoint { existing.mountPoint = mount }
                continue
            }
            seen[item.dedupeKey] = item
            out.append(item)
        }
        return out
    }

    /// 마운트 상태 대조 + 새 네트워크 마운트 자동 기억 (원본: "마운트한 모든 공유를 기억")
    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeNameKey, .volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var mountedByKey: [String: URL] = [:]   // dedupeKey → mount point
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == false,
                  let remote = values.volumeURLForRemounting else { continue }   // 재마운트 URL 없으면 기억 불가
            let probe = NetworkLocationItem(remoteURL: remote, name: "")
            mountedByKey[probe.dedupeKey] = volume
            if !items.contains(where: { $0.dedupeKey == probe.dedupeKey }) {   // 표기 달라도 같은 공유면 중복 기억 금지
                items.append(NetworkLocationItem(remoteURL: remote,
                                                 name: values.volumeName ?? remote.lastPathComponent,
                                                 mountPoint: volume))
            }
        }
        for item in items { item.mountPoint = mountedByKey[item.dedupeKey] }
        items = Self.deduped(items)   // 기존 저장분의 중복도 이 기회에 정리
        save()
        NotificationCenter.default.post(name: .networkLocationsChanged, object: nil)
    }

    func forget(_ item: NetworkLocationItem) {
        items.removeAll { $0 === item }
        save()
        NotificationCenter.default.post(name: .networkLocationsChanged, object: nil)
    }

    /// NetFS 마운트 — 키체인 우선, 필요할 때만 시스템 인증 UI (PLAYBOOK 2부 §2-5)
    /// ⌘K(서버에 연결)와 재연결이 공용. 성공 시 didMount 옵저버가 자동 기억.
    private var mounting = false   // 진행 중 가드 — 더블클릭·인증 창 중 재클릭이 창을 또 띄우는 것 방지 (제작자 제보 2026-07-23)

    /// 반환 false = 진행 중이라 무시됨(완료 콜백 안 옴 — 호출자는 자체 상태를 풀 것)
    @discardableResult
    func mount(_ remoteURL: URL, completion: @escaping @MainActor (URL?) -> Void) -> Bool {
        guard !mounting else { return false }   // 중복 요청 = 조용히 무시(첫 요청이 처리 중)
        mounting = true
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(
            remoteURL as CFURL, nil, nil, nil,
            openOptions, nil, &requestID, DispatchQueue.main) { status, _, mountpoints in
            let mounted = (mountpoints as? [String])?.first.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                NetworkLocationStore.shared.mounting = false
                completion(status == 0 ? mounted : nil)
            }
        }
        if status != 0 {
            mounting = false
            completion(nil)
        }
        return true
    }

    /// 원클릭 재연결
    func reconnect(_ item: NetworkLocationItem, completion: @escaping @MainActor (URL?) -> Void) {
        mount(item.remoteURL) { [weak self] mounted in
            if let mounted {
                item.mountPoint = mounted
                self?.refresh()
            }
            completion(mounted)
        }
    }
}
