import AppKit
import ImageIO

/// 사용자 노출 문자열 단일 창구 — Localizable.xcstrings(en 소스·ko 번역) 조회 (decisions §8)
@inline(__always) func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// 이미지 EXIF 필드 — 미리보기 정보 테이블·정보 가져오기 창 공용 (규칙 4, decisions §17)
/// ImageIO 프로퍼티만 읽는다(풀 디코드·클라우드 다운로드 트리거 없음). 비이미지는 빈 배열.
enum FileInfoFields {
    static func exif(for url: URL) -> [(label: String, value: String)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }
        var rows: [(label: String, value: String)] = []
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            rows.append((L("Dimensions"), "\(w) × \(h)"))
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let camera = [tiff?[kCGImagePropertyTIFFMake] as? String,
                      tiff?[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { rows.append((L("Camera"), camera)) }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let parser = DateFormatter()
                parser.dateFormat = "yyyy:MM:dd HH:mm:ss"   // EXIF 고정 포맷 → 로캘 표시로 변환
                rows.append((L("Date taken"),
                             parser.date(from: raw).map { FileListViewController.dateText($0) } ?? raw))
            }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                rows.append((L("Focal length"), String(format: "%g mm", focal)))
            }
            if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                rows.append((L("Aperture"), String(format: "ƒ/%.1f", fNumber)))
            }
            if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
                rows.append((L("Exposure"), time < 1 ? String(format: "1/%.0f s", 1 / time)
                                                     : String(format: "%g s", time)))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first {
                rows.append(("ISO", "\(iso)"))
            }
        }
        return rows
    }
}

struct FileItem: Equatable {   // 메타 변화 감지(행 단위 갱신 — 깜빡임 방지)용 자동 합성
    let url: URL
    let name: String
    /// 탐색 가능한 컨테이너 — 패키지(.app 등)는 파일처럼 취급하므로 false
    let isDirectory: Bool
    let isPackage: Bool
    let fileSize: Int?
    let dateModified: Date?
    let dateCreated: Date?
    let kind: String
    /// Finder 라벨 번호(0=없음) — 이름 매칭 금지, 시스템 번호로 색 해석 (PLAYBOOK 2부 §3-2)
    let labelNumber: Int

    var icon: NSImage {
        // 네트워크 컴퓨터 등 비파일 URL 항목 (워게임 network_browse)
        url.isFileURL ? NSWorkspace.shared.icon(forFile: url.path)
                      : (NSImage(named: NSImage.networkName) ?? NSImage())
    }
}

/// 파일 목록 정렬 키 — rawValue가 NSSortDescriptor의 key로 그대로 쓰인다
enum SortKey: String {
    case name, dateModified, dateCreated, size, kind
}

/// 앱이 클립보드에 쓰는 모든 플레인 텍스트의 단일 창구 — NFC 보정(자모 분리 방지)이 여기서 일어난다.
/// 파일 URL 플레이버는 보정 대상이 아니다(디스크 실제 바이트 유지). decisions.md §5.
enum PathPasteboard {
    static let toggleKey = "NFCNormalizeClipboard"
    static var normalizesToNFC: Bool {
        UserDefaults.standard.object(forKey: toggleKey) as? Bool ?? true
    }

    static func normalized(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        // Swift ==는 정준동치라 NFD/NFC를 같다고 본다 — 스칼라 단위 비교(ClipboardNFCFixer 실측 함정 ②)
        return text.unicodeScalars.elementsEqual(nfc.unicodeScalars) ? text : nfc
    }

    static func copy(_ text: String) {
        let out = normalizesToNFC ? normalized(text) : text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
    }
}

/// 휴지통 "되돌려 놓기" 기록 — **TreeFinder가 지운 파일만** (2026-07-16 제작자 확정: 자체 기록 방식).
/// Finder의 비공개 put-back 포맷은 건드리지 않는다 — 공개 API만, OS 업데이트에 안전. 키 = NFC 정규화 경로.
enum RestoreRecords {
    private static let key = "TrashPutBackRecords"

    private static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func record(trashed: URL, original: URL) {
        var records = load()
        records[PathPasteboard.normalized(trashed.path)] = original.path
        // 휴지통 비움 등으로 사라진 항목은 그때그때 정리 — 무한 성장 방지
        records = records.filter { FileManager.default.fileExists(atPath: $0.key) }
        UserDefaults.standard.set(records, forKey: key)
    }

    static func original(for trashed: URL) -> URL? {
        load()[PathPasteboard.normalized(trashed.path)].map { URL(fileURLWithPath: $0) }
    }

    static func remove(trashed: URL) {
        var records = load()
        records.removeValue(forKey: PathPasteboard.normalized(trashed.path))
        UserDefaults.standard.set(records, forKey: key)
    }
}

enum ExternalOpen {
    /// Settings ▸ Terminal에서 고른 앱으로 폴더 열기 (decisions §11)
    static func inTerminal(_ url: URL) {
        let path = UserDefaults.standard.string(forKey: SettingsKeys.terminalApp)
            ?? SettingsKeys.defaultTerminal
        let app = FileManager.default.fileExists(atPath: path)
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: SettingsKeys.defaultTerminal)   // 선택 앱이 삭제된 경우 폴백
        NSWorkspace.shared.open([url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

enum DirectoryLister {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .labelNumberKey,
    ]

    /// 블로킹 파일시스템 호출을 메인 스레드 밖으로 보낸다.
    /// ponytail: Task.detached 하나 — 네트워크 볼륨 지원 시 볼륨별 레인(VolumeLanes)으로 교체
    static func list(_ directory: URL, showHidden: Bool = false) async throws -> [FileItem] {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()   // 취소된 stale 리스팅은 syscall 시작 전에 스킵
            return try listSync(directory, showHidden: showHidden)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()   // detached는 취소를 상속하지 않으므로 직접 전파
        }
    }

    static func listSync(_ directory: URL, showHidden: Bool = false) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: resourceKeys, options: options)
        return sorted(urls.map(item(for:)))
    }

    /// 심링크는 리소스 키가 링크 자신을 보고하므로, 대상이 폴더인지는 링크를 따라가서 판정한다.
    /// (PLAYBOOK 2부 §5 — 폴더형 링크는 앱 안에서 폴더처럼 열려야 한다)
    static func resolvesToDirectory(_ url: URL, values: URLResourceValues?) -> Bool {
        if values?.isDirectory ?? false { return true }
        guard values?.isSymbolicLink ?? false else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func item(for url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let isPackage = values?.isPackage ?? false
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: resolvesToDirectory(url, values: values) && !isPackage,
            isPackage: isPackage,
            fileSize: values?.fileSize,
            dateModified: values?.contentModificationDate,
            dateCreated: values?.creationDate,
            kind: values?.localizedTypeDescription ?? "",
            labelNumber: values?.labelNumber ?? 0
        )
    }

    /// 재귀 파일명 검색 — 현재 폴더 하위 전체를 훑어 이름에 query가 든 항목 수집(Finder 패리티, 제작자 지시 2026-07-23).
    /// 반드시 비동기 컨텍스트에서 호출(블로킹 열거). 상한·취소·숨김/비로컬 가드 내장.
    static func recursiveNameSearch(_ query: String, in directory: URL,
                                    showHidden: Bool, cap: Int = 5000) -> [FileItem] {
        // 비로컬 볼륨은 재귀 열거가 행 위험 — 제외(SizeService 규약 승계)
        if (try? directory.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false { return [] }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: resourceKeys, options: options) else { return [] }
        // NFC 정규화 후 비교 — NFD로 저장된 한글 이름 vs NFC 입력 매칭 실패 방지(저비용 보험)
        let needle = query.precomposedStringWithCanonicalMapping
        var out: [FileItem] = []
        for case let url as URL in enumerator {
            if Task.isCancelled || out.count >= cap { break }
            let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            if name.localizedCaseInsensitiveContains(needle) { out.append(item(for: url)) }
        }
        return sorted(out)
    }

    /// 정체성 3요소(decisions §1): 폴더는 어떤 정렬에서도 항상 위 그룹.
    /// 그룹 안에서 선택 키로 정렬하고, 동률(폴더의 크기·종류 등)은 이름 오름차순 폴백.
    /// sizeOf: 측정된 폴더 크기 주입(SizeService) — 크기 정렬에 폴더도 참여
    static func sorted(_ items: [FileItem], by key: SortKey = .name, ascending: Bool = true,
                       sizeOf: ((FileItem) -> Int64?)? = nil) -> [FileItem] {
        func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
            switch key {
            case .name: return a.name.localizedStandardCompare(b.name)
            case .dateModified: return numeric(a.dateModified?.timeIntervalSince1970,
                                               b.dateModified?.timeIntervalSince1970)
            case .dateCreated: return numeric(a.dateCreated?.timeIntervalSince1970,
                                              b.dateCreated?.timeIntervalSince1970)
            case .size:
                let sizeA = sizeOf?(a) ?? a.fileSize.map(Int64.init)
                let sizeB = sizeOf?(b) ?? b.fileSize.map(Int64.init)
                return numeric(sizeA.map(Double.init), sizeB.map(Double.init))
            case .kind: return a.kind.localizedStandardCompare(b.kind)
            }
        }
        func numeric(_ a: Double?, _ b: Double?) -> ComparisonResult {
            let x = a ?? -.greatestFiniteMagnitude, y = b ?? -.greatestFiniteMagnitude
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        return items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }   // 폴더 우선 불변
            switch compare($0, $1) {
            case .orderedSame:   // 동률 2차 키 = 이름 오름차순(방향 무관)
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            }
        }
    }

    #if DEBUG
    static func selfTest() {
        func mk(_ name: String, dir: Bool, size: Int? = nil) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/" + name), name: name, isDirectory: dir,
                     isPackage: false, fileSize: size, dateModified: nil, dateCreated: nil, kind: "",
                     labelNumber: 0)
        }
        let out = sorted([mk("b.txt", dir: false), mk("Zeta", dir: true),
                          mk("apple", dir: true), mk("A 10.txt", dir: false), mk("A 2.txt", dir: false)])
        assert(out.map(\.name) == ["apple", "Zeta", "A 2.txt", "A 10.txt", "b.txt"],
               "folder-first + natural sort broken: \(out.map(\.name))")

        // 크기 내림차순: 폴더(크기 없음)는 여전히 위 그룹 + 이름 폴백, 파일은 크기 큰 순
        let bySize = sorted([mk("small.txt", dir: false, size: 10), mk("big.txt", dir: false, size: 999),
                             mk("zdir", dir: true), mk("adir", dir: true)],
                            by: .size, ascending: false)
        assert(bySize.map(\.name) == ["adir", "zdir", "big.txt", "small.txt"],
               "size sort + folder-first broken: \(bySize.map(\.name))")

        let nfd = "한글폴더".decomposedStringWithCanonicalMapping
        let fixed = PathPasteboard.normalized(nfd)
        assert(!nfd.unicodeScalars.elementsEqual("한글폴더".unicodeScalars), "NFD fixture not decomposed")
        assert(fixed.unicodeScalars.elementsEqual("한글폴더".unicodeScalars), "NFC normalize broken")
        assert(PathPasteboard.normalized("plain/ascii") == "plain/ascii", "ASCII must pass through")

        // 충돌 명명 + POSIX rename의 NFC 바이트 보존 (실제 임시 디렉터리 — 워게임 §1)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("tf-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("한글.txt")
        fm.createFile(atPath: file.path, contents: Data())
        assert(FileListViewController.availableURL(for: file).lastPathComponent == "한글 2.txt",
               "collision naming broken")
        if let renamed = try? FileListViewController.posixRename(file, toName: "새이름.txt") {
            let stored = (try? fm.contentsOfDirectory(atPath: tmp.path))?.first ?? ""
            assert(stored.unicodeScalars.elementsEqual(
                "새이름.txt".precomposedStringWithCanonicalMapping.unicodeScalars),
                "POSIX rename did not preserve NFC bytes")
            _ = renamed
        } else {
            assertionFailure("posixRename failed in selfTest")
        }

        // '/'↔':' 이름 변환 + 슬래시 rename이 디스크에 ':'으로 저장되는지 (제작자 지시 2026-07-23 — Finder 규약)
        assert(FileListViewController.diskName(fromDisplay: "개인/가족") == "개인:가족", "diskName '/'→':' broken")
        assert(FileListViewController.displayName(fromDisk: "개인:가족") == "개인/가족", "displayName ':'→'/' broken")
        let slashFile = tmp.appendingPathComponent("슬래시원본.txt")
        fm.createFile(atPath: slashFile.path, contents: Data())
        if let r = try? FileListViewController.posixRename(slashFile, toName: "가/나") {
            assert(fm.fileExists(atPath: tmp.appendingPathComponent("가:나").path),
                   "posixRename must store '/' as ':' on disk")
            assert(r.lastPathComponent == "가:나", "posixRename result should be the disk name")
        } else {
            assertionFailure("posixRename with slash failed")
        }

        // 재귀 파일명 검색 — 하위 폴더의 파일까지 찾는다 (제작자 지시 2026-07-23 — Finder 패리티)
        let deep = tmp.appendingPathComponent("하위/더하위")
        try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
        fm.createFile(atPath: deep.appendingPathComponent("찾을파일.log").path, contents: Data())
        let hits = DirectoryLister.recursiveNameSearch("찾을파일", in: tmp, showHidden: false)
        assert(hits.contains { $0.name == "찾을파일.log" }, "recursive name search must find nested file")

        // 색상 태그 — labelNumber 설정(6=빨강)/해제(0) 왕복 (제작자 지시 2026-07-23 — Finder 태그)
        var tagURL = tmp.appendingPathComponent("태그.txt")
        fm.createFile(atPath: tagURL.path, contents: Data())
        var rvSet = URLResourceValues(); rvSet.labelNumber = 6
        try? tagURL.setResourceValues(rvSet)
        assert((try? tagURL.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber == 6, "label set broken")
        var rvClear = URLResourceValues(); rvClear.labelNumber = 0
        try? tagURL.setResourceValues(rvClear)
        assert((try? tagURL.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber == 0, "label clear broken")

        // 네트워크 위치 중복 병합 키 — 같은 공유의 3가지 URL 표기가 한 키로 (제작자 제보 2026-07-23 "home 2개")
        let variants = ["smb://user@NAS._smb._tcp.local/home", "smb://user@NAS.local./home", "smb://nas/home"]
            .compactMap(URL.init(string:))
            .map { NetworkLocationItem(remoteURL: $0, name: "home").dedupeKey }
        assert(Set(variants).count == 1, "network dedupe key must unify URL spellings: \(variants)")

        // RestoreRecords 왕복 — 기록·조회(NFD 경로 폴백 포함)·제거 (decisions §14)
        let trashedFixture = tmp.appendingPathComponent("복원대상.txt")
        fm.createFile(atPath: trashedFixture.path, contents: Data())
        let originalFixture = tmp.appendingPathComponent("원위치/복원대상.txt")
        RestoreRecords.record(trashed: trashedFixture, original: originalFixture)
        assert(RestoreRecords.original(for: trashedFixture)?.path == originalFixture.path,
               "RestoreRecords lookup broken")
        let nfdTrashed = URL(fileURLWithPath: trashedFixture.path.decomposedStringWithCanonicalMapping)
        assert(RestoreRecords.original(for: nfdTrashed) != nil,
               "RestoreRecords must resolve NFD variant of the same path")
        RestoreRecords.remove(trashed: trashedFixture)
        assert(RestoreRecords.original(for: trashedFixture) == nil, "RestoreRecords remove broken")
    }
    #endif
}
