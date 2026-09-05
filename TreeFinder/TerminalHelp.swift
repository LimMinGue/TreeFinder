import AppKit

/// 터미널 명령 치트시트 — 기본 유닉스 명령 요약 (제작자 지시 2026-07-16).
/// Enter로 제출된 명령을 감지해 터미널 하단 밴드에 표시한다.
/// ponytail: 콘텐츠 자체가 교육 텍스트라 xcstrings 대신 인라인 2개 국어 상수(§8 규칙의 의도적 예외).
/// 한국어 전용이던 것을 앱 언어에 따라 영어도 제공 — 영문 UI 사용자에게 한글 도움말이 뜨던 문제(전체 검토 2026-09-05 A17).
enum TerminalHelp {
    struct Entry {
        let title: String
        let lines: [(key: String, desc: String)]
    }

    /// 앱이 고른 로컬라이제이션(시스템 언어 순위 기준)이 한국어인가 — 목록·메뉴와 같은 기준
    private static let korean = Bundle.main.preferredLocalizations.first?.hasPrefix("ko") ?? false
    private static func T(_ ko: String, _ en: String) -> String { korean ? ko : en }

    /// 기본 안내 — 터미널 열릴 때부터 표시, 모르는 명령 실행 시에도 이걸로 복귀 (제작자 피드백 2026-07-16)
    static let general = Entry(
        title: T("명령 도움말 — 명령을 실행하면 해당 사용법이 여기 표시됩니다",
                 "Command help — run a command and its cheat sheet appears here"),
        lines: [
            ("vi · nano", T("텍스트 편집기 (실행하면 단축키 안내)", "text editors (run one for key hints)")),
            ("ls · cd · pwd", T("폴더 내용 보기 · 이동 · 현재 위치", "list folder · change folder · current location")),
            ("cp · mv · rm", T("복사 · 이동/이름 변경 · 삭제", "copy · move/rename · delete")),
            ("grep · find", T("텍스트 검색 · 파일 찾기", "search text · find files")),
            ("tar · zip · unzip", T("압축과 해제", "archive and extract")),
            (T("man 명령", "man command"), T("모든 명령의 공식 매뉴얼 (q로 종료)", "official manual for any command (q to quit)")),
        ])

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

        add(["vi", "vim"], T("vi / vim — 텍스트 편집기", "vi / vim — text editor"), [
            ("i / a", T("입력 모드 시작 (커서 앞 / 뒤)", "start insert mode (before / after cursor)")),
            ("esc", T("입력 모드 종료 → 명령 모드", "leave insert mode → command mode")),
            (":w  :q  :wq", T("저장 / 종료 / 저장 후 종료", "save / quit / save and quit")),
            (":q!", T("저장하지 않고 강제 종료", "quit without saving")),
            ("x / dw / dd", T("글자 삭제 / 단어 삭제 / 줄 삭제", "delete character / word / line")),
            ("yy / p", T("줄 복사 / 붙여넣기", "copy line / paste")),
            ("u / ctrl+r", T("실행 취소 / 다시 실행", "undo / redo")),
            (T("/단어", "/word"), T("아래로 검색 (n 다음 · N 이전)", "search forward (n next · N previous)")),
            (":%s/A/B/g", T("문서 전체에서 A를 B로 치환", "replace A with B in the whole file")),
            ("gg / G / :10", T("문서 처음 / 끝 / 10행으로 이동", "go to top / bottom / line 10")),
        ])
        add(["nano"], T("nano — 간단 편집기", "nano — simple editor"), [
            ("ctrl+O", T("저장", "save")),
            ("ctrl+X", T("종료", "quit")),
            ("ctrl+W", T("검색", "search")),
            ("ctrl+K / ctrl+U", T("줄 잘라내기 / 붙여넣기", "cut line / paste")),
            ("ctrl+G", T("도움말", "help")),
        ])
        add(["ls"], T("ls — 폴더 내용 보기", "ls — list folder contents"), [
            ("-l", T("자세히 (권한·소유자·크기·날짜)", "long format (permissions · owner · size · date)")),
            ("-a", T("숨김 파일 포함", "include hidden files")),
            ("-h", T("크기를 KB/MB 단위로", "sizes in KB/MB")),
            ("-t", T("수정 시각순 정렬", "sort by modification time")),
            ("ls -alh", T("자주 쓰는 조합", "common combination")),
        ])
        add(["cd"], T("cd — 폴더 이동", "cd — change folder"), [
            (T("cd 경로", "cd path"), T("해당 폴더로 이동", "go to that folder")),
            (T("cd ~  또는  cd", "cd ~  or  cd"), T("홈 폴더로", "go home")),
            ("cd ..", T("상위 폴더로", "go to the parent folder")),
            ("cd -", T("직전 폴더로 되돌아가기", "go back to the previous folder")),
        ])
        add(["pwd"], T("pwd — 현재 위치", "pwd — current location"), [
            ("pwd", T("현재 폴더의 전체 경로 표시", "print the full path of the current folder")),
        ])
        add(["cp"], T("cp — 복사", "cp — copy"), [
            (T("cp 원본 대상", "cp source dest"), T("파일 복사", "copy a file")),
            ("-r", T("폴더 통째로 복사", "copy a whole folder")),
            ("-p", T("권한·수정 시각 보존", "keep permissions and timestamps")),
            ("-i", T("덮어쓰기 전에 확인", "ask before overwriting")),
        ])
        add(["mv"], T("mv — 이동·이름 변경", "mv — move · rename"), [
            ("mv A B", T("A를 B로 이동 (같은 폴더면 이름 변경)", "move A to B (rename if same folder)")),
            ("-i", T("덮어쓰기 전에 확인", "ask before overwriting")),
            ("-n", T("기존 파일을 덮어쓰지 않음", "never overwrite existing files")),
        ])
        add(["rm"], T("rm — 삭제 (휴지통 없음 — 복구 불가!)", "rm — delete (no Trash — cannot be undone!)"), [
            (T("rm 파일", "rm file"), T("파일 삭제", "delete a file")),
            ("-r", T("폴더와 내용 전부 삭제", "delete a folder and everything inside")),
            ("-i", T("하나씩 확인하며 삭제", "confirm each deletion")),
            ("-f", T("확인 없이 강제 (주의)", "force, no confirmation (careful)")),
        ])
        add(["mkdir"], T("mkdir — 폴더 생성", "mkdir — create folder"), [
            (T("mkdir 이름", "mkdir name"), T("폴더 생성", "create a folder")),
            ("-p", T("중간 경로까지 한 번에 (a/b/c)", "create intermediate folders too (a/b/c)")),
        ])
        add(["cat"], T("cat — 내용 출력", "cat — print contents"), [
            (T("cat 파일", "cat file"), T("내용 전체 출력", "print the whole file")),
            ("-n", T("줄 번호와 함께", "with line numbers")),
            ("cat A B > C", T("A와 B를 이어 C로 저장", "concatenate A and B into C")),
        ])
        add(["less", "more"], T("less — 페이지 단위 보기", "less — page through a file"), [
            (T("스페이스 / b", "space / b"), T("다음 / 이전 페이지", "next / previous page")),
            (T("/단어", "/word"), T("검색 (n 다음)", "search (n for next)")),
            ("g / G", T("처음 / 끝으로", "top / bottom")),
            ("q", T("종료", "quit")),
        ])
        add(["head", "tail"], T("head / tail — 앞·뒤 부분 보기", "head / tail — first · last lines"), [
            (T("head -n 20 파일", "head -n 20 file"), T("앞 20줄", "first 20 lines")),
            (T("tail -n 20 파일", "tail -n 20 file"), T("뒤 20줄", "last 20 lines")),
            (T("tail -f 로그", "tail -f log"), T("실시간 추적 (ctrl+C로 중단)", "follow live (ctrl+C to stop)")),
        ])
        add(["grep"], T("grep — 텍스트 검색", "grep — search text"), [
            (T("grep 패턴 파일", "grep pattern file"), T("패턴이 있는 줄 출력", "print lines matching the pattern")),
            ("-i", T("대소문자 무시", "ignore case")),
            ("-r", T("폴더 전체 재귀 검색", "search folders recursively")),
            ("-n", T("줄 번호 표시", "show line numbers")),
            ("-v", T("패턴이 없는 줄만", "only lines that do not match")),
            ("-E", T("확장 정규식", "extended regular expressions")),
        ])
        add(["find"], T("find — 파일 찾기", "find — find files"), [
            ("find . -name \"*.txt\"", T("이름 패턴으로 찾기", "find by name pattern")),
            ("-type f / -type d", T("파일만 / 폴더만", "files only / folders only")),
            ("-size +10M", T("10MB보다 큰 것", "larger than 10 MB")),
            ("-mtime -7", T("최근 7일 내 수정", "modified in the last 7 days")),
            (T("-exec 명령 {} \\;", "-exec command {} \\;"), T("찾은 항목마다 명령 실행", "run a command on each result")),
        ])
        add(["chmod"], T("chmod — 권한 변경", "chmod — change permissions"), [
            (T("chmod 755 파일", "chmod 755 file"), T("rwxr-xr-x (소유자 전부·나머지 읽기/실행)", "rwxr-xr-x (owner all · others read/execute)")),
            (T("chmod +x 파일", "chmod +x file"), T("실행 권한 추가", "add execute permission")),
            ("u/g/o × r/w/x", T("기호식: chmod u+w, go-r 등", "symbolic form: chmod u+w, go-r …")),
            ("-R", T("폴더 내 전체 적용", "apply to everything in a folder")),
        ])
        add(["chown"], T("chown — 소유자 변경", "chown — change owner"), [
            (T("chown 사용자:그룹 파일", "chown user:group file"), T("소유자·그룹 변경", "change owner and group")),
            ("-R", T("폴더 내 전체 적용", "apply to everything in a folder")),
        ])
        add(["tar"], T("tar — 묶기·압축", "tar — archive · compress"), [
            (T("tar -czf a.tar.gz 폴더", "tar -czf a.tar.gz folder"), T("gzip 압축으로 묶기", "create a gzip-compressed archive")),
            ("tar -xzf a.tar.gz", T("풀기", "extract")),
            ("tar -tzf a.tar.gz", T("내용 목록만 보기", "list contents only")),
            (T("-C 경로", "-C path"), T("지정 위치에 풀기", "extract into a given folder")),
        ])
        add(["zip"], T("zip — 압축", "zip — compress"), [
            (T("zip -r a.zip 폴더", "zip -r a.zip folder"), T("폴더를 zip으로", "zip a folder")),
            ("-e", T("암호 걸기", "encrypt with a password")),
        ])
        add(["unzip"], T("unzip — 압축 해제", "unzip — extract"), [
            ("unzip a.zip", T("현재 폴더에 풀기", "extract into the current folder")),
            (T("-d 경로", "-d path"), T("지정 위치에 풀기", "extract into a given folder")),
            ("-l", T("내용 목록만 보기", "list contents only")),
        ])
        add(["ssh"], T("ssh — 원격 접속", "ssh — remote login"), [
            (T("ssh 사용자@호스트", "ssh user@host"), T("원격 셸 접속", "open a remote shell")),
            (T("-p 포트", "-p port"), T("포트 지정 (기본 22)", "choose a port (default 22)")),
            (T("-i 키파일", "-i keyfile"), T("개인 키로 인증", "authenticate with a private key")),
        ])
        add(["scp"], T("scp — 원격 복사", "scp — remote copy"), [
            (T("scp 파일 user@host:경로", "scp file user@host:path"), T("업로드", "upload")),
            (T("scp user@host:경로 파일", "scp user@host:path file"), T("다운로드", "download")),
            ("-r", T("폴더 통째로", "whole folder")),
            (T("-P 포트", "-P port"), T("포트 지정 (대문자 P)", "choose a port (capital P)")),
        ])
        add(["curl"], T("curl — URL 요청", "curl — request a URL"), [
            ("curl URL", T("응답을 화면에 출력", "print the response")),
            ("-O", T("원격 이름 그대로 저장", "save with the remote file name")),
            (T("-o 이름", "-o name"), T("지정한 이름으로 저장", "save under a given name")),
            ("-L", T("리다이렉트 따라가기", "follow redirects")),
            ("-I", T("응답 헤더만 보기", "headers only")),
        ])
        add(["ps"], T("ps — 프로세스 목록", "ps — process list"), [
            ("ps aux", T("전체 프로세스", "all processes")),
            (T("ps aux | grep 이름", "ps aux | grep name"), T("특정 프로세스 찾기", "find a specific process")),
        ])
        add(["kill", "killall"], T("kill — 프로세스 종료", "kill — terminate a process"), [
            ("kill PID", T("정상 종료 요청 (TERM)", "ask to terminate (TERM)")),
            ("kill -9 PID", T("강제 종료 (KILL)", "force kill (KILL)")),
            (T("killall 이름", "killall name"), T("프로세스 이름으로 종료", "terminate by process name")),
        ])
        add(["top"], T("top — 실시간 모니터", "top — live monitor"), [
            ("top", T("CPU·메모리 사용 현황", "CPU and memory usage")),
            ("o cpu / o mem", T("정렬 기준 변경 (macOS)", "change sort key (macOS)")),
            ("q", T("종료", "quit")),
        ])
        add(["df"], T("df — 디스크 여유 공간", "df — free disk space"), [
            ("df -h", T("볼륨별 사용량을 읽기 쉽게", "usage per volume, human-readable")),
        ])
        add(["du"], T("du — 폴더 크기", "du — folder size"), [
            (T("du -sh 폴더", "du -sh folder"), T("폴더 크기 합계", "total size of a folder")),
            ("du -h -d 1", T("1단계 하위 폴더별 크기", "size of each first-level subfolder")),
        ])
        add(["ln"], T("ln — 링크 생성", "ln — create links"), [
            (T("ln -s 원본 링크", "ln -s target link"), T("심볼릭 링크 (바로가기)", "symbolic link (shortcut)")),
            (T("ln 원본 링크", "ln target link"), T("하드 링크", "hard link")),
        ])
        add(["man"], T("man — 매뉴얼", "man — manual"), [
            (T("man 명령", "man command"), T("공식 매뉴얼 열기", "open the official manual")),
            (T("스페이스 / q", "space / q"), T("다음 페이지 / 종료", "next page / quit")),
            (T("/단어", "/word"), T("매뉴얼 안 검색", "search inside the manual")),
        ])
        add(["which"], T("which — 명령 위치", "which — locate a command"), [
            (T("which 명령", "which command"), T("실행 파일의 경로 확인", "show the executable's path")),
        ])
        add(["history"], T("history — 명령 기록", "history — command history"), [
            ("history", T("입력했던 명령 목록", "list previous commands")),
            (T("!번호", "!number"), T("해당 번호 명령 재실행", "rerun the command with that number")),
            ("ctrl+r", T("기록에서 검색", "search the history")),
        ])
        add(["touch"], T("touch — 빈 파일", "touch — empty file"), [
            (T("touch 파일", "touch file"), T("빈 파일 생성 (있으면 수정 시각만 갱신)", "create an empty file (or update its timestamp)")),
        ])
        add(["git"], T("git — 버전 관리", "git — version control"), [
            ("git status", T("변경 상태 확인", "show changes")),
            (T("git add . / git commit -m \"메시지\"", "git add . / git commit -m \"message\""), T("스테이징 / 커밋", "stage / commit")),
            ("git push / git pull", T("원격에 반영 / 가져오기", "push to / pull from the remote")),
            ("git log --oneline", T("이력 한 줄씩", "history, one line each")),
        ])
        return table
    }()
}
