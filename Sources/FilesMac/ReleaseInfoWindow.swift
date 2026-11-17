import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class ReleaseInfoWindow: NSWindowController {
    enum Page { case about, releaseNotes, updates(version: String?) }

    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextView()
    private let releaseButton = NSButton(title: L("GitHub 릴리스 열기", "Open GitHub Release"),
                                         target: nil, action: nil)
    private let checkUpdate: @Sendable (String, Bool) async throws -> ReleaseUpdate
    private var updateTask: Task<Void, Never>?
    private var updatePage: URL?

    init(checkUpdate: @escaping @Sendable (String, Bool) async throws -> ReleaseUpdate = ReleaseUpdates.check(currentVersion:isPreview:)) {
        self.checkUpdate = checkUpdate
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 460, height: 360)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); stack.translatesAutoresizingMaskIntoConstraints = false
        heading.font = .systemFont(ofSize: 22, weight: .semibold); stack.addArrangedSubview(heading)
        body.isEditable = false; body.isSelectable = true; body.drawsBackground = false
        body.font = .systemFont(ofSize: 13); body.textContainerInset = NSSize(width: 4, height: 6)
        let scroll = NSScrollView(); scroll.documentView = body; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder; stack.addArrangedSubview(scroll)
        releaseButton.target = self
        releaseButton.action = #selector(openUpdatePage)
        releaseButton.isHidden = true
        stack.addArrangedSubview(releaseButton)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
    }

    func present(_ page: Page) {
        updateTask?.cancel()
        updateTask = nil
        updatePage = nil
        releaseButton.isHidden = true
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? L("개발 빌드", "Development Build")
        let build = info?["CFBundleVersion"] as? String ?? "SwiftPM"
        let isPreview = info?["FilesReleaseChannel"] as? String != "stable"
        switch page {
        case .about:
            window?.title = L("Files macOS 정보", "About Files macOS")
            heading.stringValue = "Files macOS"
            body.string = L("""
            버전: \(version) (\(build))

            Windows Files의 사용자 경험을 macOS AppKit과 네이티브 파일 API로 재구현하는 독립 프로젝트입니다.

            기준 원본: Files v4.2.9
            라이선스: MIT

            데이터 안전 원칙
            • 교차 볼륨 이동은 복사·SHA-256 검증 후에만 원본을 삭제합니다.
            • 덮어쓰기와 실행 취소는 파일 identity를 재검증합니다.
            • 자격 증명은 명령행이나 로그에 포함하지 않습니다.
            """, """
            Version: \(version) (\(build))

            An independent AppKit and native-file-API reimplementation of the Windows Files experience for macOS.

            Upstream baseline: Files v4.2.9
            License: MIT

            Data safety
            • Cross-volume moves delete sources only after copy and SHA-256 verification.
            • Replacement and undo revalidate file identity.
            • Credentials are never placed in command arguments or logs.
            """)
        case .releaseNotes:
            window?.title = L("릴리스 노트", "Release Notes")
            if !isPreview {
                heading.stringValue = L("Files macOS 릴리스 노트", "Files macOS Release Notes")
                body.string = L("정식 버전 \(version) (\(build))\n\n설치 이미지의 Release Notes.txt에서 기능, 지원 범위와 복구 절차를 확인할 수 있습니다.",
                                "Stable version \(version) (\(build))\n\nSee Release Notes.txt in the disk image for features, supported environments, and recovery steps.")
                break
            }
            heading.stringValue = L("개발 프리뷰 릴리스 노트", "Development Preview Release Notes")
            body.string = L("""
            현재 채널: 개발 프리뷰

            포함
            • 네이티브 탭·분할 pane과 4개 파일 보기
            • 안전한 복사·이동·삭제·이름 변경·Undo
            • 검색·Quick Look·속성·Finder 태그·SHA-256
            • ZIP/7z/RAR, 원격 FTP/FTPS/SFTP/SMB, Git 기본 작업
            • 한국어/영어, 시스템/밝게/어둡게, 단축키·툴바 설정

            알려진 제한
            • 정식 서명·공증·DMG·업데이트 채널은 아직 출시 게이트 대기입니다.
            • Intel, 실제 SMB 장시간, 모든 지원 macOS/파일 시스템 매트릭스 검증이 남아 있습니다.
            • Windows 전용 COM, NTFS ADS, WSL, Start 고정은 제공하지 않습니다.

            복구
            파일 작업 결과 창과 작업 저널을 먼저 확인하고, 검증되지 않은 대상은 원본을 삭제하지 마십시오.
            """, """
            Channel: Development Preview

            Included
            • Native tabs, split panes, and four file views
            • Safe copy, move, delete, rename, and undo
            • Search, Quick Look, properties, Finder tags, and SHA-256
            • ZIP/7z/RAR, FTP/FTPS/SFTP/SMB, and core Git operations
            • Korean/English, system/light/dark, shortcut and toolbar settings

            Known limitations
            • Developer ID signing, notarization, DMG, and update channel remain release gates.
            • Intel, sustained real SMB, and the full supported OS/filesystem matrix remain unverified.
            • Windows-only COM, NTFS ADS, WSL, and Start pinning are not provided.

            Recovery
            Check the operation result window and journal first. Never delete a source whose destination has not been verified.
            """)
        case .updates(let version):
            window?.title = L("업데이트 확인", "Check for Updates")
            heading.stringValue = L("업데이트 확인", "Check for Updates")
            if let version {
                startUpdateCheck(version, isPreview: isPreview)
            } else {
                body.string = L("업데이트를 확인하려면 설치된 앱을 실행하세요.",
                                "Run the installed app to check for updates.")
            }
        }
        body.scrollToBeginningOfDocument(nil); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }

    private func startUpdateCheck(_ version: String, isPreview: Bool) {
        body.string = L("GitHub에서 정식 배포 버전을 확인하고 있습니다…", "Checking GitHub for a stable release…")
        updateTask = Task { [weak self, checkUpdate] in
            do {
                let result = try await checkUpdate(version, isPreview)
                guard !Task.isCancelled, let self else { return }
                switch result {
                case .unavailable:
                    self.body.string = L("다운로드할 수 있는 정식 배포 버전이 없습니다.",
                                         "No stable release is available for download.")
                case .upToDate:
                    self.body.string = L("현재 버전 \(version)보다 새로운 정식 배포 버전이 없습니다.",
                                         "There is no stable release newer than your version \(version).")
                case .available(let latest, let page):
                    self.updatePage = page
                    self.releaseButton.isHidden = false
                    self.body.string = L("현재 버전 \(version)\n정식 배포 버전 \(latest)\n\nGitHub 릴리스에서 설치 이미지와 체크섬을 다운로드할 수 있습니다.",
                                         "Installed version \(version)\nAvailable stable release \(latest)\n\nDownload the disk image and its checksum from the GitHub release.")
                }
                self.body.scrollToBeginningOfDocument(nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.body.string = L("업데이트를 확인할 수 없습니다. 연결을 확인한 뒤 다시 시도하세요.",
                                     "Could not check for updates. Check the connection and try again.")
            }
        }
    }

    @objc private func openUpdatePage() {
        if let updatePage { NSWorkspace.shared.open(updatePage) }
    }
#if DEBUG
    var qaVisible: Bool { window?.isVisible == true }
    var qaText: String { body.string }
    var qaUpdateActionVisible: Bool { !releaseButton.isHidden }
#endif
}
