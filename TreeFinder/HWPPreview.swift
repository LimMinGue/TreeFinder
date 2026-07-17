import AppKit
import CryptoKit

/// HWP/HWPX 미리보기 추출 (2026-07-16 제작자 지시 · rhwp 통합 같은 날 확정).
/// 1순위: 동반된 rhwp(MIT, github.com/edwardkim/rhwp) CLI로 **전 페이지 SVG 렌더** — PDF급 미리보기.
/// 폴백: 문서가 내장한 미리보기 리소스 —
/// · HWPX = zip(OWPML): `Preview/PrvImage.png`(첫 페이지) / `Preview/PrvText.txt`
/// · HWP 5.x = OLE 컴파운드 파일(CFB): `PrvImage` / `PrvText`(UTF-16LE) 스트림
enum HWPPreview {
    struct Result {
        let pages: [NSImage]   // rhwp 성공 = 전 페이지 / 폴백 = PrvImage 1장 / 텍스트 폴백 = 빈 배열
        let text: String?
    }

    static func isHWPFamily(_ url: URL) -> Bool {
        ["hwp", "hwpx"].contains(url.pathExtension.lowercased())
    }

    /// 백그라운드 큐에서 호출할 것 — 파일 IO + 외부 프로세스. 실패 시 nil(호출부는 QL 폴백).
    static func extract(from url: URL) -> Result? {
        if let pages = HWPRenderer.renderPages(of: url), !pages.isEmpty {
            return Result(pages: pages, text: nil)
        }
        // rhwp 부재/실패 — 내장 미리보기 리소스 폴백
        switch url.pathExtension.lowercased() {
        case "hwpx": return extractHWPX(url)
        case "hwp": return extractHWP(url)
        default: return nil
        }
    }

    // MARK: HWPX (zip) — /usr/bin/unzip 스트림 추출 (시스템 기본 탑재, zip 파서 자작 불필요)

    private static func unzipEntry(_ archive: URL, _ entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // 에러 출력은 버림
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0 && !data.isEmpty) ? data : nil
    }

    private static func extractHWPX(_ url: URL) -> Result? {
        let image = unzipEntry(url, "Preview/PrvImage.png").flatMap(NSImage.init(data:))
        var text: String?
        if let data = unzipEntry(url, "Preview/PrvText.txt") {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
        }
        return (image == nil && text == nil) ? nil : Result(pages: image.map { [$0] } ?? [], text: text)
    }

    // MARK: HWP (CFB/OLE) — 최소 컴파운드 파일 리더 (모든 읽기 경계 검사 — 손상 파일은 nil 폴백)

    private static func extractHWP(_ url: URL) -> Result? {
        guard let data = try? Data(contentsOf: url), let cfb = CFBReader(data) else { return nil }
        let image = cfb.stream(named: "PrvImage").flatMap(NSImage.init(data:))
        let text = cfb.stream(named: "PrvText").flatMap {
            String(data: $0, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        }
        return (image == nil && text == nil) ? nil : Result(pages: image.map { [$0] } ?? [], text: text)
    }
}

/// 압축파일 내부 파일 목록 (2026-07-18 제작자 지시) — /usr/bin/tar -tf(bsdtar/libarchive).
/// zip·tar·tgz·bz2·xz·jar·apk 등 libarchive가 나열 가능한 포맷 전부. **표시 전용**(추출·실행 없음).
/// 위원회 교차논쟁 반영: 스트리밍 읽기(바이트 상한)·타임아웃 킬러·stderr 미배수 데드락 차단·
/// 손실 허용 디코딩·macOS 잡음 필터·제어/양방향 문자 무력화(RTL 확장자 위장 방지)·정렬.
enum ArchiveListing {
    private static let lineCap = 2000        // 표시 줄 상한 — NSTextView TextKit 레이아웃 비용 기준(성능 위원)
    private static let byteCap = 4 << 20     // 읽기 바이트 상한 4MB — 압축폭탄·거대 gz 스트림 OOM 방어(성능·보안 위원)
    private static let timeoutSeconds = 15.0 // 네트워크 볼륨 무한 행 방지(동시성 위원)

    /// 백그라운드 큐에서 호출할 것. 실패(비아카이브·손상·단일 gz·미지원 포맷·상한 초과) 시 nil → 호출부 QL 폴백.
    static func list(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", url.path]              // 인자 고정 — 옵션 오인/주입 차단(보안 위원)
        // GUI 앱은 로캘이 C라 tar가 비ASCII 파일명을 8진 이스케이프로 뭉갬 → UTF-8 강제(실측).
        // 환경은 통째 교체가 아니라 병합 — PATH 보존(외부 디컴프레서 fork 대비, 보안·플랫폼 위원).
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice      // stderr 미배수 데드락 차단(Tester·성능 위원)
        guard (try? process.run()) != nil else { return nil }

        // 타임아웃 킬러는 블로킹 읽기 '이전에' 무장 — read가 안 풀리는 행에도 SIGTERM이 닿게(동시성 위원)
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: killer)

        // 스트리밍 읽기 — byteCap 도달 시 tar 종료(전량 버퍼링 금지, 압축폭탄·거대 gz 방어)
        let handle = out.fileHandleForReading
        var data = Data()
        while data.count < byteCap {
            let chunk = handle.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if process.isRunning { process.terminate() }        // 상한 초과분·미소진 스트림 정리
        _ = try? handle.readToEnd()                          // 파이프 배수 후 종료 대기
        process.waitUntilExit()
        killer.cancel()

        // gz(비-tar)·미지원 포맷·상한 초과(우리가 kill)는 모두 exit≠0 → 폴백. 정상 아카이브만 exit 0.
        guard process.terminationStatus == 0 else { return nil }
        // 손실 허용 UTF-8 디코딩 — 비UTF-8 이름 한 줄만 U+FFFD, 나머지 항목은 보존(QC 위원)
        return format(String(decoding: data, as: UTF8.self))
    }

    private static func format(_ raw: String) -> String {
        var entries: [String] = []
        raw.enumerateLines { line, _ in
            var name = line
            if name.hasPrefix("./") { name.removeFirst(2) }  // tar -C . . 의 상대 접두 제거
            guard !name.isEmpty, name != "." else { return }
            // macOS zip 잡음(리소스 포크·메타) 제외 — 유령 항목·개수 부풀림 방지(QC 위원)
            let base = ((name.hasSuffix("/") ? String(name.dropLast()) : name) as NSString).lastPathComponent
            if name.hasPrefix("__MACOSX/") || base == ".DS_Store" || base.hasPrefix("._") { return }
            entries.append(sanitized(name).precomposedStringWithCanonicalMapping)  // 정규화·무력화는 백그라운드에서
        }
        let total = entries.count
        if total == 0 { return L("This archive is empty.") }
        entries.sort { $0.localizedStandardCompare($1) == .orderedAscending }       // 형제 그룹화(앱 정체성)
        var shown = entries
        var truncated = false
        if shown.count > lineCap { shown = Array(shown.prefix(lineCap)); truncated = true }
        var text = String(format: L("%d items"), total) + "\n\n" + shown.joined(separator: "\n")
        if truncated { text += "\n\n… " + String(format: L("and %d more"), total - lineCap) }
        return text
    }

    /// 제어문자·양방향 서식문자 무력화 — RTL override(U+202E) 확장자 위장·가짜 행 삽입 방지(보안 위원)
    private static func sanitized(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x00...0x1F, 0x7F, 0x80...0x9F,                          // C0/C1 제어
                 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:        // 양방향 서식
                return "\u{FFFD}"
            default:
                return scalar
            }
        }))
    }
}

/// NSScrollView documentView용 수직 스택 — 페이지가 위에서부터 쌓이도록 (non-flipped 기본은 하단 기준)
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// rhwp CLI 래퍼 — HWP/HWPX를 페이지별 SVG로 렌더해 NSImage 배열로 (decisions §15 개정)
enum HWPRenderer {
    private static let pageCap = 20          // 대형 문서 메모리 방어 — 초과분은 생략
    private static let timeoutSeconds = 30.0 // 변환 행 방지

    /// 동반 바이너리 (TreeFinder/Vendor/rhwp — 번들 리소스로 복사됨)
    private static var binaryURL: URL? {
        guard let url = Bundle.main.url(forResource: "rhwp", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// 캐시 폴더 — 키 = SHA256(NFC 경로 | 수정일): 내용이 바뀌면 자동 재렌더
    private static func cacheDirectory(for url: URL) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(PathPasteboard.normalized(url.path))|\(mtime)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("TreeFinder/rhwp/\(digest)", isDirectory: true)
    }

    static func renderPages(of url: URL) -> [NSImage]? {
        guard let binary = binaryURL, let cacheDir = cacheDirectory(for: url) else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDir.path) {
            let staging = cacheDir.deletingLastPathComponent()
                .appendingPathComponent(cacheDir.lastPathComponent + ".tmp-\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: staging)
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = binary
            // --font-style: 시스템 폰트 local() 참조 — NSImage(CoreSVG)가 로컬 폰트로 텍스트 렌더
            process.arguments = ["export-svg", url.path, "-o", staging.path, "--font-style"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: killer)
            process.waitUntilExit()
            killer.cancel()
            guard process.terminationStatus == 0 else {
                try? fm.removeItem(at: staging)
                return nil
            }
            try? fm.removeItem(at: cacheDir)
            try? fm.moveItem(at: staging, to: cacheDir)   // 완성본만 캐시로 승격 — 부분 결과 방지
        }
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return nil }
        let svgs = files.filter { $0.pathExtension.lowercased() == "svg" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let pages = svgs.prefix(pageCap).compactMap { NSImage(contentsOf: $0) }
        return pages.isEmpty ? nil : pages
    }
}

/// CFB(Compound File Binary) 최소 리더 — 디렉터리에서 이름으로 스트림 하나를 꺼내는 용도만.
/// 참조: MS-CFB. FAT/miniFAT/DIFAT 체인 지원, 모든 오프셋 경계 검사(악성/손상 파일에 크래시 금지).
private struct CFBReader {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private struct Entry { let name: String; let type: UInt8; let start: UInt32; let size: Int }
    private let entries: [Entry]
    private let miniStream: Data

    private static let endOfChain: UInt32 = 0xFFFFFFFE
    private static let freeSect: UInt32 = 0xFFFFFFFF
    private static let miniCutoff = 4096
    private static let chainCap = 1 << 20   // 순환 체인 방어

    /// 리틀엔디언 UInt32 — Data 슬라이스의 startIndex 오프셋 주의
    private static func u32(in chunk: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(chunk[chunk.startIndex + offset + index]) << (8 * UInt32(index))
        }
        return value
    }

    init?(_ data: Data) {
        self.data = data
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return Self.u32(in: data, at: offset)
        }

        // 헤더: 매직 + 섹터 크기
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard data.count >= 512, data.prefix(8).elementsEqual(magic),
              let sectorShift = u16(30), sectorShift >= 7, sectorShift <= 12,
              let miniShift = u16(32), miniShift >= 4, miniShift <= 12 else { return nil }
        let sectorSize = 1 << sectorShift
        self.sectorSize = sectorSize
        self.miniSectorSize = 1 << miniShift

        func sectorData(_ sector: UInt32) -> Data? {
            let start = 512 + Int(sector) * sectorSize
            guard start >= 512, start + sectorSize <= data.count else { return nil }
            return data.subdata(in: start..<(start + sectorSize))
        }

        // DIFAT: 헤더 109개 + 연장 체인 → FAT 섹터 목록 → FAT
        var fatSectors: [UInt32] = []
        for index in 0..<109 {
            guard let value = u32(76 + index * 4) else { return nil }
            if value < Self.freeSect - 1 { fatSectors.append(value) }
        }
        var difatSector = u32(68) ?? Self.endOfChain
        var difatCount = 0
        while difatSector < Self.endOfChain - 1, difatCount < 1024 {
            guard let chunk = sectorData(difatSector) else { break }
            let perSector = sectorSize / 4 - 1
            for index in 0..<perSector {
                let value = Self.u32(in: chunk, at: index * 4)
                if value < Self.freeSect - 1 { fatSectors.append(value) }
            }
            difatSector = Self.u32(in: chunk, at: perSector * 4)
            difatCount += 1
        }
        var fat: [UInt32] = []
        for sector in fatSectors {
            guard let chunk = sectorData(sector) else { return nil }
            for index in 0..<(sectorSize / 4) {
                fat.append(Self.u32(in: chunk, at: index * 4))
            }
        }
        self.fat = fat

        func chain(from start: UInt32, table: [UInt32]) -> [UInt32] {
            var sectors: [UInt32] = []
            var current = start
            while current < Self.endOfChain - 1, sectors.count < Self.chainCap {
                sectors.append(current)
                guard Int(current) < table.count else { return sectors }
                current = table[Int(current)]
            }
            return sectors
        }

        func readChain(_ start: UInt32, size: Int) -> Data? {
            var out = Data(capacity: size)
            for sector in chain(from: start, table: fat) {
                guard let chunk = sectorData(sector) else { return nil }
                out.append(chunk)
                if out.count >= size { break }
            }
            guard out.count >= size else { return nil }
            return out.prefix(size)
        }

        // 디렉터리 엔트리 (128바이트씩)
        guard let dirStart = u32(48) else { return nil }
        var directoryData = Data()
        for sector in chain(from: dirStart, table: fat) {
            guard let chunk = sectorData(sector) else { return nil }
            directoryData.append(chunk)
        }
        var entries: [Entry] = []
        var offset = 0
        while offset + 128 <= directoryData.count {
            let slice = directoryData.subdata(in: offset..<(offset + 128))
            let nameLength = Int(slice[64]) | Int(slice[65]) << 8   // 널 포함 바이트 수
            if nameLength >= 2, nameLength <= 64 {
                let nameData = slice.subdata(in: 0..<(nameLength - 2))
                let name = String(data: nameData, encoding: .utf16LittleEndian) ?? ""
                let type = slice[66]
                let start = Self.u32(in: slice, at: 116)
                let size = Int(Self.u32(in: slice, at: 120))
                entries.append(Entry(name: name, type: type, start: start, size: size))
            }
            offset += 128
        }
        self.entries = entries

        // miniFAT + 루트 엔트리의 미니 스트림 컨테이너
        var miniFAT: [UInt32] = []
        if let miniStart = u32(60), miniStart < Self.endOfChain - 1 {
            for sector in chain(from: miniStart, table: fat) {
                guard let chunk = sectorData(sector) else { break }
                for index in 0..<(sectorSize / 4) {
                    miniFAT.append(Self.u32(in: chunk, at: index * 4))
                }
            }
        }
        self.miniFAT = miniFAT
        if let root = entries.first(where: { $0.type == 5 }) {
            self.miniStream = readChain(root.start, size: root.size) ?? Data()
        } else {
            self.miniStream = Data()
        }
    }

    /// 이름으로 스트림 읽기 — 4096 미만은 miniFAT 체인(미니 스트림 내부), 이상은 FAT 체인
    func stream(named name: String) -> Data? {
        guard let entry = entries.first(where: { $0.name == name && $0.type == 2 }),
              entry.size > 0, entry.size < 64 << 20 else { return nil }
        if entry.size < Self.miniCutoff {
            var out = Data(capacity: entry.size)
            var current = entry.start
            var hops = 0
            while current < Self.endOfChain - 1, hops < Self.chainCap {
                let start = Int(current) * miniSectorSize
                guard start >= 0, start + miniSectorSize <= miniStream.count else { return nil }
                out.append(miniStream.subdata(in: start..<(start + miniSectorSize)))
                if out.count >= entry.size { break }
                guard Int(current) < miniFAT.count else { return nil }
                current = miniFAT[Int(current)]
                hops += 1
            }
            guard out.count >= entry.size else { return nil }
            return out.prefix(entry.size)
        }
        // 일반 FAT 체인
        var out = Data(capacity: entry.size)
        var current = entry.start
        var hops = 0
        while current < Self.endOfChain - 1, hops < Self.chainCap {
            let start = 512 + Int(current) * sectorSize
            guard start >= 512, start + sectorSize <= data.count else { return nil }
            out.append(data.subdata(in: start..<(start + sectorSize)))
            if out.count >= entry.size { break }
            guard Int(current) < fat.count else { return nil }
            current = fat[Int(current)]
            hops += 1
        }
        guard out.count >= entry.size else { return nil }
        return out.prefix(entry.size)
    }
}
