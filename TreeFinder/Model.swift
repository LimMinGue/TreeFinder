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
    /// 헤더 우클릭 선택 컬럼용 (제작자 지시 2026-07-25) — 기본 숨김, 리스팅 시 배치 페치
    let dateLastOpened: Date?
    let dateAdded: Date?
    let tagNames: String   // 라벨 색 이름 목록(쉼표 구분) — 표시·정렬용

    var icon: NSImage {
        // 네트워크 컴퓨터 등 비파일 URL 항목 (워게임 network_browse)
        url.isFileURL ? NSWorkspace.shared.icon(forFile: url.path)
                      : (NSImage(named: NSImage.networkName) ?? NSImage())
    }
}

/// 파일 목록 정렬 키 — rawValue가 NSSortDescriptor의 key로 그대로 쓰인다
/// dateLastOpened·dateAdded·tags = 헤더 우클릭으로 표시하는 선택 컬럼 (제작자 지시 2026-07-25)
enum SortKey: String {
    case name, dateModified, dateCreated, dateLastOpened, dateAdded, size, kind, tags
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
        // 헤더 우클릭 선택 컬럼 (제작자 지시 2026-07-25) — 배치 페치라 비용 미미
        .contentAccessDateKey, .addedToDirectoryDateKey, .tagNamesKey,
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

    /// 폴더로 "열려는" URL이 심링크면 대상 경로로 해석한다 — Finder 규약(제작자 확정 2026-08-06, decisions §32).
    ///
    /// **왜 필요한가(실측)**: URL 기반 `contentsOfDirectory(at:)`·`enumerator(at:)`는 디렉토리를 가리키는
    /// 심링크에서 `NSPOSIXErrorDomain 20 "Not a directory"`로 **실패한다**(후행 슬래시·isDirectory:true를 줘도 동일).
    /// 경로 기반 API는 정상 동작하므로, 링크를 따라가지 않는 이 앱은 심링크 폴더를 아예 열지 못했다
    /// (이 기기의 `~/Documents`·`~/Downloads`가 실제 심링크 — 즐겨찾기 기본 항목이 오류였음).
    ///
    /// **해석 방식 = readlink 체인**(`resolvingSymlinksInPath()` 불채택): 대상을 stat 하지 않아 죽은
    /// 네트워크 마운트에서도 즉시 끝나고(실측 0.035ms), 끊긴 링크도 대상 경로를 정직하게 돌려주며,
    /// `/private/tmp`↔`/tmp` 치환으로 경로 표기가 흔들리지 않는다.
    /// 끊긴 링크·순환 링크·파일을 가리키는 링크는 **원본 URL을 그대로** 돌려준다(기존 오류 경로 유지).
    static func resolvedFolder(_ url: URL) -> URL {
        guard let target = symlinkTarget(url) else { return url }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return url }   // 끊김·파일·순환 → 원본 유지
        return target
    }

    /// 심링크가 가리키는 **후보** 경로 — readlink 체인만 돌고 대상은 **건드리지 않는다**(stat 0).
    /// 링크가 아니거나 자기 자신으로 돌아오면 nil.
    /// 죽은 네트워크 마운트를 가리킬 수 있는 자리(동기·메인 스레드 열거)에서는 **이걸로 먼저 판정**하고,
    /// 통과한 뒤에야 `resolvedFolder`(대상 존재 확인 = stat 포함)를 불러야 한다 — 순서가 뒤집히면
    /// 가드가 도는 시점엔 이미 stat이 끝나 §3 규약이 무력화된다(적대검증 지적).
    static func symlinkTarget(_ url: URL) -> URL? {
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { return nil }
        var current = url
        for _ in 0..<8 {   // 체인 상한 — 순환 링크(A→B→A) 무한 루프 차단
            guard (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
            else { break }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        current = current.standardizedFileURL   // 상대 링크 결합에서 생긴 '..' 정리
        return current == url ? nil : current
    }

    /// Finder 별칭(alias) 파일이 가리키는 대상 — 심링크와 달리 북마크 데이터라 전용 API가 필요하다.
    /// **옵션 고정이 이 창구의 존재 이유**: `.withoutMounting`을 빼면 죽은 볼륨을 가리키는 별칭이
    /// 조용히 마운트를 시도하고 인증 창이 뜬다(실측). 별칭이 아니거나 해석 실패면 nil.
    static func aliasTarget(_ url: URL) -> URL? {
        guard (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true else { return nil }
        return try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
    }

    /// 심링크·별칭이 가리키는 원본 경로(표시용) — 정보 가져오기의 '원본:' 행. 둘 다 아니면 nil.
    static func originalPath(of url: URL) -> String? {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return destination.hasPrefix("/")
                ? destination
                : url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
        }
        return aliasTarget(url)?.standardizedFileURL.path
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
        let isDirectory = resolvesToDirectory(url, values: values) && !isPackage
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            // 폴더는 크기를 SizeService가 채운다 — 심링크 폴더는 fileSize가 non-nil(링크 경로 문자열 길이)이라
            // 그냥 두면 "폴더인데 25바이트"가 확정값처럼 뜨고 크기 정렬·선택 합계까지 오염된다(QC 위원 지적).
            fileSize: isDirectory ? nil : values?.fileSize,
            dateModified: values?.contentModificationDate,
            dateCreated: values?.creationDate,
            kind: values?.localizedTypeDescription ?? "",
            labelNumber: values?.labelNumber ?? 0,
            dateLastOpened: values?.contentAccessDate,
            dateAdded: values?.addedToDirectoryDate,
            tagNames: (values?.tagNames ?? []).joined(separator: ", ")
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
            case .dateLastOpened: return numeric(a.dateLastOpened?.timeIntervalSince1970,
                                                 b.dateLastOpened?.timeIntervalSince1970)
            case .dateAdded: return numeric(a.dateAdded?.timeIntervalSince1970,
                                            b.dateAdded?.timeIntervalSince1970)
            case .tags: return a.tagNames.localizedStandardCompare(b.tagNames)
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
                     labelNumber: 0, dateLastOpened: nil, dateAdded: nil, tagNames: "")
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

        // 권한 오류 원인 판별 — TCC(전체 디스크 접근으로 풀림) vs 폴더 자체 권한 (제작자 지시 2026-08-06, §33).
        // 실측 근거: TCC=EPERM(1) · 폴더 권한=EACCES(13), 상위 코드는 둘 다 257.
        func permissionError(_ posix: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix))])
        }
        assert(FileListViewController.deniedByPrivacyPermission(permissionError(EPERM)),
               "EPERM은 TCC로 판정해 전체 디스크 접근을 안내해야 한다(휴지통 케이스 — 2026-07-17 회귀 방지)")
        assert(!FileListViewController.deniedByPrivacyPermission(permissionError(EACCES)),
               "EACCES는 폴더 권한 문제라 전체 디스크 접근을 안내하면 안 된다")
        assert(FileListViewController.deniedByPrivacyPermission(
                NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)),
               "underlying이 없으면 보수적으로 TCC 판정(종전 동작 유지)")
        assert(!FileListViewController.deniedByPrivacyPermission(
                NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)),
               "권한 오류가 아니면 전체 디스크 접근 안내 금지")

        // 심링크 폴더 해석 (제작자 제보 2026-08-06 "심링크 폴더를 즐겨찾기에 등록하면 정상작동 안 함", §32)
        let linkTarget = tmp.appendingPathComponent("링크대상")
        try? fm.createDirectory(at: linkTarget, withIntermediateDirectories: true)
        fm.createFile(atPath: linkTarget.appendingPathComponent("안의파일.txt").path, contents: Data(count: 7))
        let absLink = tmp.appendingPathComponent("절대링크")
        let relLink = tmp.appendingPathComponent("상대링크")
        let chainLink = tmp.appendingPathComponent("체인링크")
        let deadLink = tmp.appendingPathComponent("끊긴링크")
        let fileLink = tmp.appendingPathComponent("파일링크")
        try? fm.createSymbolicLink(atPath: absLink.path, withDestinationPath: linkTarget.path)
        try? fm.createSymbolicLink(atPath: relLink.path, withDestinationPath: "링크대상")     // 상대 경로
        try? fm.createSymbolicLink(atPath: chainLink.path, withDestinationPath: "상대링크")   // 링크 → 링크
        try? fm.createSymbolicLink(atPath: deadLink.path, withDestinationPath: "/없는경로/xyz")
        try? fm.createSymbolicLink(atPath: fileLink.path, withDestinationPath: "링크대상/안의파일.txt")
        // URL 기반 열거는 심링크 폴더에서 실패한다(이 버그의 근본) — 해석 후에는 성공해야 한다
        assert((try? fm.contentsOfDirectory(at: absLink, includingPropertiesForKeys: nil)) == nil,
               "전제 붕괴: contentsOfDirectory(at: 심링크)가 성공했다 — 해석 로직 재검토 필요")
        for link in [absLink, relLink, chainLink] {
            let resolved = resolvedFolder(link)
            assert(resolved.standardizedFileURL.path == linkTarget.standardizedFileURL.path,
                   "심링크 해석 실패: \(link.lastPathComponent) → \(resolved.path)")
            assert((try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil))?.count == 1,
                   "해석된 경로로 열거가 안 된다: \(link.lastPathComponent)")
        }
        // 끊긴 링크·파일 링크·일반 폴더는 원본 그대로(엉뚱한 진입 금지)
        assert(resolvedFolder(deadLink) == deadLink, "끊긴 링크는 원본 유지여야 한다")
        assert(resolvedFolder(fileLink) == fileLink, "파일을 가리키는 링크는 원본 유지여야 한다")
        assert(resolvedFolder(linkTarget) == linkTarget, "심링크가 아니면 그대로여야 한다")
        // 순환 링크(A→B→A)에서 무한 루프에 빠지지 않는다
        let cycleA = tmp.appendingPathComponent("순환A"), cycleB = tmp.appendingPathComponent("순환B")
        try? fm.createSymbolicLink(atPath: cycleA.path, withDestinationPath: "순환B")
        try? fm.createSymbolicLink(atPath: cycleB.path, withDestinationPath: "순환A")
        assert(resolvedFolder(cycleA) == cycleA, "순환 링크는 원본 유지여야 한다")
        // 심링크 폴더 행의 크기는 링크 자신의 바이트가 아니라 폴더 취급(SizeService가 채움)
        let linkItem = item(for: absLink)
        assert(linkItem.isDirectory && linkItem.fileSize == nil,
               "심링크 폴더 행은 폴더 + 크기 nil이어야 한다: isDirectory=\(linkItem.isDirectory) size=\(String(describing: linkItem.fileSize))")

        // 이름 충돌 판정은 링크를 따라가면 안 된다 — 따라가면 깨진 심링크를 "빈 이름"으로 보고
        // POSIX rename이 그 링크를 조용히 지운다(제작자 지시 2026-08-06 보완, §32 후속). 실측 재현된 자리.
        assert(!FileManager.default.fileExists(atPath: deadLink.path), "전제: 깨진 링크는 fileExists=false")
        assert(FileListViewController.nameIsTaken(atPath: deadLink.path),
               "깨진 심링크도 '이름이 이미 쓰임'으로 판정돼야 한다(lstat 기반)")
        assert(FileListViewController.availableURL(for: deadLink).lastPathComponent != deadLink.lastPathComponent,
               "깨진 심링크와 같은 이름은 충돌 회피 명명을 타야 한다")
        // 원본(심링크 대상) 경로 표시 — 정보 가져오기 '원본:' 행 (제작자 확정 2026-08-06)
        assert(originalPath(of: relLink) == linkTarget.standardizedFileURL.path,
               "상대 심링크의 원본 경로 해석 실패: \(String(describing: originalPath(of: relLink)))")
        assert(originalPath(of: linkTarget) == nil, "일반 폴더엔 원본 행이 없어야 한다")

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
