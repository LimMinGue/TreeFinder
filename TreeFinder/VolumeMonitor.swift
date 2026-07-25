import AppKit

/// 마운트된 "추출 가능" 볼륨 루트 스냅숏 — 트리·목록 추출 판정 공용(규칙 4).
/// (제작자 지시 2026-07-25: 네트워크·USB 등 착탈식 볼륨을 트리 ⏏·목록 메뉴로 추출.)
///
/// **§3/§6 규약**: 추출 가능 판정은 순수 메모리 조회(`isEjectable`) — 메인 스레드 stat 0.
/// 스냅숏 재계산(볼륨 열거·플래그 stat)만 오프메인에서 하므로, 죽은 네트워크 마운트가 있어도
/// 우클릭·트리 스크롤이 UI를 얼리지 않는다(11인 위원회 적대검증 4렌즈 만장일치 must-fix 반영).
@MainActor
final class VolumeMonitor {
    static let shared = VolumeMonitor()
    static let changed = Notification.Name("TFVolumesChanged")

    private(set) var ejectableRoots: Set<URL> = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.refresh() }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// 클릭/노드 URL이 추출 가능 볼륨 루트인가 — 순수 메모리 비교(메인 스레드 stat 없음, 죽은 마운트 무해).
    func isEjectable(_ url: URL) -> Bool {
        ejectableRoots.contains(url.standardizedFileURL)
    }

    /// 마운트/언마운트 시 스냅숏 재계산 — 열거·stat는 오프메인(죽은 네트워크 마운트를 백그라운드에 격리).
    private func refresh() {
        Task.detached {
            let roots = VolumeMonitor.computeOffMain()
            await MainActor.run {
                VolumeMonitor.shared.ejectableRoots = roots
                NotificationCenter.default.post(name: VolumeMonitor.changed, object: nil)
            }
        }
    }

    /// 실측 판정식(2026-07-25 DMG 실측): `isVolume && (ejectable || removable || 비로컬)`.
    /// 부트'/'·Data(ejectable=false·local=true)는 자동 제외, USB/외장/디스크이미지/네트워크는 포함.
    /// nil 안전 스펠링(QC 지적): 모든 비교를 명시 `== true`/`== false`로 — try? 실패(v=nil)는 전부 비추출.
    nonisolated private static func computeOffMain() -> Set<URL> {
        let keys: [URLResourceKey] = [.isVolumeKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeIsLocalKey]
        // .skipHiddenVolumes — 시스템 마운트(cryptex·CoreSimulator·autofs 등)를 배제해 트리(buildLocalLocations)와
        // 동일한 "사용자 볼륨" 집합으로 정렬(제작자 실측 2026-07-25: 미적용 시 /home·시뮬 볼륨 오노출).
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var roots: Set<URL> = []
        for u in volumes {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isVolume == true else { continue }
            if v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsLocal == false {
                roots.insert(u.standardizedFileURL)
            }
        }
        return roots
    }
}

/// 볼륨 추출 실행 공용(규칙 4) — 트리 ⏏ 버튼·트리 메뉴·목록 메뉴·네트워크 eject의 단일 합류점.
/// 오프메인 언마운트(§3 — USB 캐시 플러시·느린 네트워크 언마운트가 UI를 얼리지 않음)
/// + 인플라이트 가드(반복 클릭 레이스 차단) + 실패만 표면화(조용한 실패 금지).
/// **메인 스레드 전용**(inFlight는 메인에서만 접근). 다중 파티션 장치는 macOS 표준대로 장치 전체 추출(제작자 확정 2026-07-25).
enum VolumeEjector {
    private static var inFlight: Set<URL> = []

    static func eject(_ url: URL, presenter: NSWindow?) {
        let key = url.standardizedFileURL
        guard !inFlight.contains(key) else { return }   // 이미 추출 중 — 중복 요청 무시(레이스)
        inFlight.insert(key)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            DispatchQueue.main.async {
                inFlight.remove(key)
                if case .failure(let error) = result, let window = presenter {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }
}
