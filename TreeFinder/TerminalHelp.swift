import AppKit

/// 터미널 명령 치트시트 — 기본 유닉스 명령의 한국어 요약 (제작자 지시 2026-07-16).
/// Enter로 제출된 명령을 감지해 터미널 하단 밴드에 표시한다.
/// ponytail: 콘텐츠 자체가 한국어 교육 텍스트라 xcstrings 대신 상수(§8 규칙의 의도적 예외 — 제작자 확인 대상).
enum TerminalHelp {
    struct Entry {
        let title: String
        let lines: [(key: String, desc: String)]
    }

    /// 명령줄 → 항목 조회. sudo 접두·경로(/usr/bin/vi)는 벗겨서 판별.
    static func entry(forCommandLine line: String) -> Entry? {
        var tokens = line.split(separator: " ").map(String.init)
        if tokens.first == "sudo" { tokens.removeFirst() }
        guard let first = tokens.first, !first.isEmpty else { return nil }
        let command = (first as NSString).lastPathComponent
        return table[command]
    }

    /// 밴드 렌더 — 제목(볼드) + "키 — 설명" 줄들(키는 고정폭)
    static func render(_ entry: Entry) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: entry.title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                         .foregroundColor: NSColor.labelColor])
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        for line in entry.lines {
            result.append(NSAttributedString(
                string: "\n" + line.key,
                attributes: [.font: keyFont, .foregroundColor: NSColor.labelColor]))
            result.append(NSAttributedString(
                string: "   " + line.desc,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return result
    }

    private static let table: [String: Entry] = {
        var table: [String: Entry] = [:]
        func add(_ names: [String], _ title: String, _ lines: [(String, String)]) {
            let entry = Entry(title: title, lines: lines)
            for name in names { table[name] = entry }
        }

        add(["vi", "vim"], "vi / vim — 텍스트 편집기", [
            ("i / a", "입력 모드 시작 (커서 앞 / 뒤)"),
            ("esc", "입력 모드 종료 → 명령 모드"),
            (":w  :q  :wq", "저장 / 종료 / 저장 후 종료"),
            (":q!", "저장하지 않고 강제 종료"),
            ("x / dw / dd", "글자 삭제 / 단어 삭제 / 줄 삭제"),
            ("yy / p", "줄 복사 / 붙여넣기"),
            ("u / ctrl+r", "실행 취소 / 다시 실행"),
            ("/단어", "아래로 검색 (n 다음 · N 이전)"),
            (":%s/A/B/g", "문서 전체에서 A를 B로 치환"),
            ("gg / G / :10", "문서 처음 / 끝 / 10행으로 이동"),
        ])
        add(["nano"], "nano — 간단 편집기", [
            ("ctrl+O", "저장"),
            ("ctrl+X", "종료"),
            ("ctrl+W", "검색"),
            ("ctrl+K / ctrl+U", "줄 잘라내기 / 붙여넣기"),
            ("ctrl+G", "도움말"),
        ])
        add(["ls"], "ls — 폴더 내용 보기", [
            ("-l", "자세히 (권한·소유자·크기·날짜)"),
            ("-a", "숨김 파일 포함"),
            ("-h", "크기를 KB/MB 단위로"),
            ("-t", "수정 시각순 정렬"),
            ("ls -alh", "자주 쓰는 조합"),
        ])
        add(["cd"], "cd — 폴더 이동", [
            ("cd 경로", "해당 폴더로 이동"),
            ("cd ~  또는  cd", "홈 폴더로"),
            ("cd ..", "상위 폴더로"),
            ("cd -", "직전 폴더로 되돌아가기"),
        ])
        add(["pwd"], "pwd — 현재 위치", [
            ("pwd", "현재 폴더의 전체 경로 표시"),
        ])
        add(["cp"], "cp — 복사", [
            ("cp 원본 대상", "파일 복사"),
            ("-r", "폴더 통째로 복사"),
            ("-p", "권한·수정 시각 보존"),
            ("-i", "덮어쓰기 전에 확인"),
        ])
        add(["mv"], "mv — 이동·이름 변경", [
            ("mv A B", "A를 B로 이동 (같은 폴더면 이름 변경)"),
            ("-i", "덮어쓰기 전에 확인"),
            ("-n", "기존 파일을 덮어쓰지 않음"),
        ])
        add(["rm"], "rm — 삭제 (휴지통 없음 — 복구 불가!)", [
            ("rm 파일", "파일 삭제"),
            ("-r", "폴더와 내용 전부 삭제"),
            ("-i", "하나씩 확인하며 삭제"),
            ("-f", "확인 없이 강제 (주의)"),
        ])
        add(["mkdir"], "mkdir — 폴더 생성", [
            ("mkdir 이름", "폴더 생성"),
            ("-p", "중간 경로까지 한 번에 (a/b/c)"),
        ])
        add(["cat"], "cat — 내용 출력", [
            ("cat 파일", "내용 전체 출력"),
            ("-n", "줄 번호와 함께"),
            ("cat A B > C", "A와 B를 이어 C로 저장"),
        ])
        add(["less", "more"], "less — 페이지 단위 보기", [
            ("스페이스 / b", "다음 / 이전 페이지"),
            ("/단어", "검색 (n 다음)"),
            ("g / G", "처음 / 끝으로"),
            ("q", "종료"),
        ])
        add(["head", "tail"], "head / tail — 앞·뒤 부분 보기", [
            ("head -n 20 파일", "앞 20줄"),
            ("tail -n 20 파일", "뒤 20줄"),
            ("tail -f 로그", "실시간 추적 (ctrl+C로 중단)"),
        ])
        add(["grep"], "grep — 텍스트 검색", [
            ("grep 패턴 파일", "패턴이 있는 줄 출력"),
            ("-i", "대소문자 무시"),
            ("-r", "폴더 전체 재귀 검색"),
            ("-n", "줄 번호 표시"),
            ("-v", "패턴이 없는 줄만"),
            ("-E", "확장 정규식"),
        ])
        add(["find"], "find — 파일 찾기", [
            ("find . -name \"*.txt\"", "이름 패턴으로 찾기"),
            ("-type f / -type d", "파일만 / 폴더만"),
            ("-size +10M", "10MB보다 큰 것"),
            ("-mtime -7", "최근 7일 내 수정"),
            ("-exec 명령 {} \\;", "찾은 항목마다 명령 실행"),
        ])
        add(["chmod"], "chmod — 권한 변경", [
            ("chmod 755 파일", "rwxr-xr-x (소유자 전부·나머지 읽기/실행)"),
            ("chmod +x 파일", "실행 권한 추가"),
            ("u/g/o × r/w/x", "기호식: chmod u+w, go-r 등"),
            ("-R", "폴더 내 전체 적용"),
        ])
        add(["chown"], "chown — 소유자 변경", [
            ("chown 사용자:그룹 파일", "소유자·그룹 변경"),
            ("-R", "폴더 내 전체 적용"),
        ])
        add(["tar"], "tar — 묶기·압축", [
            ("tar -czf a.tar.gz 폴더", "gzip 압축으로 묶기"),
            ("tar -xzf a.tar.gz", "풀기"),
            ("tar -tzf a.tar.gz", "내용 목록만 보기"),
            ("-C 경로", "지정 위치에 풀기"),
        ])
        add(["zip"], "zip — 압축", [
            ("zip -r a.zip 폴더", "폴더를 zip으로"),
            ("-e", "암호 걸기"),
        ])
        add(["unzip"], "unzip — 압축 해제", [
            ("unzip a.zip", "현재 폴더에 풀기"),
            ("-d 경로", "지정 위치에 풀기"),
            ("-l", "내용 목록만 보기"),
        ])
        add(["ssh"], "ssh — 원격 접속", [
            ("ssh 사용자@호스트", "원격 셸 접속"),
            ("-p 포트", "포트 지정 (기본 22)"),
            ("-i 키파일", "개인 키로 인증"),
        ])
        add(["scp"], "scp — 원격 복사", [
            ("scp 파일 user@host:경로", "업로드"),
            ("scp user@host:경로 파일", "다운로드"),
            ("-r", "폴더 통째로"),
            ("-P 포트", "포트 지정 (대문자 P)"),
        ])
        add(["curl"], "curl — URL 요청", [
            ("curl URL", "응답을 화면에 출력"),
            ("-O", "원격 이름 그대로 저장"),
            ("-o 이름", "지정한 이름으로 저장"),
            ("-L", "리다이렉트 따라가기"),
            ("-I", "응답 헤더만 보기"),
        ])
        add(["ps"], "ps — 프로세스 목록", [
            ("ps aux", "전체 프로세스"),
            ("ps aux | grep 이름", "특정 프로세스 찾기"),
        ])
        add(["kill", "killall"], "kill — 프로세스 종료", [
            ("kill PID", "정상 종료 요청 (TERM)"),
            ("kill -9 PID", "강제 종료 (KILL)"),
            ("killall 이름", "프로세스 이름으로 종료"),
        ])
        add(["top"], "top — 실시간 모니터", [
            ("top", "CPU·메모리 사용 현황"),
            ("o cpu / o mem", "정렬 기준 변경 (macOS)"),
            ("q", "종료"),
        ])
        add(["df"], "df — 디스크 여유 공간", [
            ("df -h", "볼륨별 사용량을 읽기 쉽게"),
        ])
        add(["du"], "du — 폴더 크기", [
            ("du -sh 폴더", "폴더 크기 합계"),
            ("du -h -d 1", "1단계 하위 폴더별 크기"),
        ])
        add(["ln"], "ln — 링크 생성", [
            ("ln -s 원본 링크", "심볼릭 링크 (바로가기)"),
            ("ln 원본 링크", "하드 링크"),
        ])
        add(["man"], "man — 매뉴얼", [
            ("man 명령", "공식 매뉴얼 열기"),
            ("스페이스 / q", "다음 페이지 / 종료"),
            ("/단어", "매뉴얼 안 검색"),
        ])
        add(["which"], "which — 명령 위치", [
            ("which 명령", "실행 파일의 경로 확인"),
        ])
        add(["history"], "history — 명령 기록", [
            ("history", "입력했던 명령 목록"),
            ("!번호", "해당 번호 명령 재실행"),
            ("ctrl+r", "기록에서 검색"),
        ])
        add(["touch"], "touch — 빈 파일", [
            ("touch 파일", "빈 파일 생성 (있으면 수정 시각만 갱신)"),
        ])
        add(["git"], "git — 버전 관리", [
            ("git status", "변경 상태 확인"),
            ("git add . / git commit -m \"메시지\"", "스테이징 / 커밋"),
            ("git push / git pull", "원격에 반영 / 가져오기"),
            ("git log --oneline", "이력 한 줄씩"),
        ])
        return table
    }()
}
