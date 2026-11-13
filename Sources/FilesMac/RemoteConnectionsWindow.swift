import AppKit
import FilesCore

@MainActor
final class RemoteConnectionsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let profileStore: RemoteProfileStore
    private let credentialStore: KeychainRemoteCredentialStore
    private let hostTrustStore: SFTPHostTrustStore
    private let hostKeyScanner = SFTPHostKeyScanner()
    private var profiles: [RemoteConnectionProfile] = []
    private var pendingIdentityBookmark: Data?
    private let table = NSTableView(), name = NSTextField(), host = NSTextField(), port = NSTextField()
    private let rootPath = NSTextField(), username = NSTextField(), password = NSSecureTextField()
    private let protocolPopup = NSPopUpButton(), saveButton = NSButton(), deleteButton = NSButton(), connectButton = NSButton(), trustButton = NSButton(), identityButton = NSButton(), sftpConnectButton = NSButton()

    init(profileStore: RemoteProfileStore, credentialStore: KeychainRemoteCredentialStore = .init()) {
        self.profileStore = profileStore; self.credentialStore = credentialStore
        self.hostTrustStore = SFTPHostTrustStore(fileURL: profileStore.fileURL.deletingLastPathComponent().appendingPathComponent("known_hosts"))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("원격 연결", "Remote Connections"); panel.isReleasedWhenClosed = false
        buildUI(); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .horizontal; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root); NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let list = NSStackView(); list.orientation = .vertical; list.spacing = 8; list.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let column = NSTableColumn(identifier: .init("remote")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 34; table.delegate = self; table.dataSource = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; list.addArrangedSubview(scroll)
        let listButtons = NSStackView(); listButtons.orientation = .horizontal
        listButtons.addArrangedSubview(NSButton(title: L("추가", "Add"), target: self, action: #selector(addProfile(_:))))
        deleteButton.title = L("삭제", "Delete"); deleteButton.target = self; deleteButton.action = #selector(deleteProfile(_:)); listButtons.addArrangedSubview(deleteButton)
        list.addArrangedSubview(listButtons); root.addArrangedSubview(list)
        let form = NSStackView(); form.orientation = .vertical; form.spacing = 8
        form.addArrangedSubview(NSTextField(wrappingLabelWithString: L("암호는 프로필 파일이 아니라 macOS Keychain에 저장됩니다. 인증서와 SSH host key 검증은 연결 시 생략하지 않습니다.", "Passwords are stored in macOS Keychain, not the profile file. Certificate and SSH host-key validation is never skipped when connecting.")))
        protocolPopup.addItems(withTitles: RemoteProtocol.allCases.map { $0.rawValue.uppercased() }); protocolPopup.target = self; protocolPopup.action = #selector(protocolChanged(_:))
        identityButton.title = L("개인 키 선택…", "Choose Private Key…"); identityButton.target = self; identityButton.action = #selector(chooseIdentity(_:))
        for (label, field) in [(L("이름", "Name"), name), (L("프로토콜", "Protocol"), protocolPopup), (L("호스트", "Host"), host), (L("포트", "Port"), port), (L("루트 경로", "Root Path"), rootPath), (L("사용자 이름", "Username"), username), (L("암호", "Password"), password)] {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            let title = NSTextField(labelWithString: label); title.alignment = .right; title.widthAnchor.constraint(equalToConstant: 100).isActive = true
            row.addArrangedSubview(title); row.addArrangedSubview(field); form.addArrangedSubview(row)
        }
        let identityRow = NSStackView(); identityRow.orientation = .horizontal; identityRow.spacing = 8
        let identityLabel = NSTextField(labelWithString: L("SFTP 개인 키", "SFTP Private Key")); identityLabel.alignment = .right; identityLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        identityRow.addArrangedSubview(identityLabel); identityRow.addArrangedSubview(identityButton); form.addArrangedSubview(identityRow)
        password.placeholderString = L("변경할 때만 입력", "Enter only to change")
        let controls = NSStackView(); controls.orientation = .horizontal; controls.addArrangedSubview(NSView())
        trustButton.title = L("호스트 키 확인…", "Verify Host Key…"); trustButton.target = self; trustButton.action = #selector(verifyHostKey(_:)); controls.addArrangedSubview(trustButton)
        sftpConnectButton.title = L("SFTP 목록 연결", "Connect SFTP Listing"); sftpConnectButton.target = self; sftpConnectButton.action = #selector(connectSFTP(_:)); controls.addArrangedSubview(sftpConnectButton)
        connectButton.title = L("Finder에서 연결", "Connect in Finder"); connectButton.target = self; connectButton.action = #selector(connectSMB(_:)); controls.addArrangedSubview(connectButton)
        saveButton.title = L("저장", "Save"); saveButton.keyEquivalent = "\r"; saveButton.target = self; saveButton.action = #selector(saveProfile(_:)); controls.addArrangedSubview(saveButton)
        form.addArrangedSubview(controls); root.addArrangedSubview(form)
    }

    func present() { reload(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    private func reload() {
        do { profiles = try profileStore.load(); table.reloadData(); if !profiles.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); populate(profiles[0]) } else { clearForm() }; updateControls() }
        catch { showError(error) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("RemoteCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let t = NSTextField(labelWithString: ""); t.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(t); c.textField = t; NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        let profile = profiles[row]; cell.textField?.stringValue = "\(profile.name)  \(profile.remoteProtocol.rawValue.uppercased())"; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if let profile = selected { populate(profile) }; updateControls() }
    private var selected: RemoteConnectionProfile? { profiles.indices.contains(table.selectedRow) ? profiles[table.selectedRow] : nil }
    private var selectedProtocol: RemoteProtocol { RemoteProtocol.allCases[protocolPopup.indexOfSelectedItem.clamped(to: RemoteProtocol.allCases.indices)] }
    private func populate(_ profile: RemoteConnectionProfile) {
        name.stringValue = profile.name; protocolPopup.selectItem(at: RemoteProtocol.allCases.firstIndex(of: profile.remoteProtocol) ?? 0)
        host.stringValue = profile.host; port.stringValue = String(profile.port); rootPath.stringValue = profile.rootPath
        username.stringValue = profile.username ?? ""; password.stringValue = ""
        pendingIdentityBookmark = profile.identityBookmark; updateIdentityTitle()
    }
    private func clearForm() { name.stringValue = ""; protocolPopup.selectItem(at: 0); host.stringValue = ""; port.stringValue = String(RemoteProtocol.ftp.defaultPort); rootPath.stringValue = "/"; username.stringValue = ""; password.stringValue = ""; pendingIdentityBookmark = nil; updateIdentityTitle() }
    private func updateControls() {
        deleteButton.isEnabled = selected != nil; connectButton.isEnabled = selected?.remoteProtocol == .smb
        trustButton.isEnabled = selected?.remoteProtocol == .sftp; identityButton.isEnabled = selectedProtocol == .sftp
        sftpConnectButton.isEnabled = selected.flatMap { try? SFTPConnectionPreparation().prepare(profile: $0, knownHostsFile: hostTrustStore.fileURL) } != nil
    }
    @objc private func addProfile(_ sender: Any?) { table.deselectAll(nil); clearForm(); updateControls(); window?.makeFirstResponder(name) }
    @objc private func protocolChanged(_ sender: Any?) { port.stringValue = String(selectedProtocol.defaultPort); updateControls() }
    @objc private func saveProfile(_ sender: Any?) {
        do {
            let current = selected, credentialID = password.stringValue.isEmpty ? current?.credentialID : (current?.credentialID ?? UUID().uuidString)
            let profile = try RemoteConnectionProfile(id: current?.id ?? UUID(), name: name.stringValue, remoteProtocol: selectedProtocol,
                host: host.stringValue, port: Int(port.stringValue), rootPath: rootPath.stringValue,
                username: username.stringValue, credentialID: credentialID, identityBookmark: pendingIdentityBookmark)
            if !password.stringValue.isEmpty, let credentialID {
                try credentialStore.save(RemoteCredential(username: profile.username ?? "", secret: Data(password.stringValue.utf8)), id: credentialID)
            }
            if let current, let index = profiles.firstIndex(where: { $0.id == current.id }) { profiles[index] = profile } else { profiles.append(profile) }
            try profileStore.save(profiles); password.stringValue = ""; reload()
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { table.selectRowIndexes([index], byExtendingSelection: false) }
        } catch { showError(error) }
    }
    @objc private func deleteProfile(_ sender: Any?) {
        guard let selected else { return }
        do { if let id = selected.credentialID { try credentialStore.remove(id: id) }; profiles.removeAll { $0.id == selected.id }; try profileStore.save(profiles); reload() }
        catch { showError(error) }
    }
    @objc private func connectSMB(_ sender: Any?) {
        do { guard let selected else { return }; NSWorkspace.shared.open(try selected.smbMountURL()) }
        catch { showError(error) }
    }
    @objc private func chooseIdentity(_ sender: Any?) {
        guard let window else { return }; let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = L("SFTP 인증에 사용할 개인 키 파일을 선택하세요.", "Choose the private key file used for SFTP authentication.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do { self.pendingIdentityBookmark = try SFTPIdentityReference().create(for: url); self.updateIdentityTitle() }
            catch { self.showError(error) }
        }
    }
    private func updateIdentityTitle() {
        guard let pendingIdentityBookmark,
              let resolved = try? SFTPIdentityReference().resolve(pendingIdentityBookmark) else {
            identityButton.title = L("개인 키 선택…", "Choose Private Key…"); return
        }
        identityButton.title = resolved.url.lastPathComponent + (resolved.stale ? L(" (다시 선택 필요)", " (Reselect Required)") : "")
    }
    @objc private func verifyHostKey(_ sender: Any?) {
        guard let profile = selected, profile.remoteProtocol == .sftp, let window else { return }
        trustButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await hostKeyScanner.scan(profile: profile)
                let candidate = candidates.first(where: { $0.keyType == "ssh-ed25519" }) ?? candidates[0]
                let alert = NSAlert(); alert.messageText = L("SFTP 호스트 키를 신뢰하시겠습니까?", "Trust This SFTP Host Key?")
                alert.informativeText = "\(profile.host):\(profile.port)\n\(candidate.keyType)\n\(candidate.sha256Fingerprint)\n\n" + L("서버 관리자가 제공한 fingerprint와 직접 비교한 뒤 승인하세요.", "Compare this fingerprint directly with the server administrator before approving.")
                alert.addButton(withTitle: L("일치함 — 신뢰", "Matches — Trust")); alert.addButton(withTitle: L("취소", "Cancel"))
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn, let self else { self?.updateControls(); return }
                    do { try self.hostTrustStore.approve(candidate, fingerprint: candidate.sha256Fingerprint); self.updateControls() }
                    catch { self.showError(error); self.updateControls() }
                }
            } catch { showError(error); updateControls() }
        }
    }
    @objc private func connectSFTP(_ sender: Any?) {
        guard let profile = selected, let window else { return }; sftpConnectButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try SFTPConnectionPreparation().prepare(profile: profile, knownHostsFile: hostTrustStore.fileURL)
                let access = prepared.key.identityFile.startAccessingSecurityScopedResource()
                defer { if access { prepared.key.identityFile.stopAccessingSecurityScopedResource() } }
                guard access else { throw SFTPBackendError.invalidIdentity }
                let entries = try await SFTPRemoteProvider().list(profile: profile, key: prepared.key, remotePath: profile.rootPath)
                let preview = entries.prefix(8).map(\.name).joined(separator: "\n")
                let alert = NSAlert(); alert.messageText = L("SFTP 연결 성공", "SFTP Connection Succeeded")
                alert.informativeText = L("항목 \(entries.count)개", "\(entries.count) items") + (preview.isEmpty ? "" : "\n\n" + preview)
                alert.beginSheetModal(for: window) { _ in }; updateControls()
            } catch { showError(error); updateControls() }
        }
    }
    private func showError(_ error: Error) { guard let window else { return }; let alert = NSAlert(); alert.messageText = L("원격 연결 작업 실패", "Remote Connection Failed"); alert.informativeText = String(describing: error); alert.beginSheetModal(for: window) }
#if DEBUG
    var qaProfileCount: Int { profiles.count }
    func qaCreateProfile() {
        if !profiles.contains(where: { $0.name == "QA SFTP" }) {
            addProfile(nil); name.stringValue = "QA SFTP"; protocolPopup.selectItem(at: RemoteProtocol.allCases.firstIndex(of: .sftp) ?? 0)
            host.stringValue = "qa.example.com"; port.stringValue = "22"; rootPath.stringValue = "/fixture"; username.stringValue = "qa-user"; saveProfile(nil)
        }
        if !profiles.contains(where: { $0.name == "QA SMB" }) {
            addProfile(nil); name.stringValue = "QA SMB"; protocolPopup.selectItem(at: RemoteProtocol.allCases.firstIndex(of: .smb) ?? 0)
            host.stringValue = "nas.example.com"; port.stringValue = "445"; rootPath.stringValue = "/fixture"; username.stringValue = "qa-user"; saveProfile(nil)
        }
        if let index = profiles.firstIndex(where: { $0.name == "QA SMB" }) { table.selectRowIndexes([index], byExtendingSelection: false); populate(profiles[index]); updateControls() }
    }
    var qaSMBConnectEnabled: Bool { connectButton.isEnabled }
    func qaSFTPTrustEnabled() -> Bool {
        guard let sftp = profiles.firstIndex(where: { $0.remoteProtocol == .sftp }) else { return false }
        table.selectRowIndexes([sftp], byExtendingSelection: false); populate(profiles[sftp]); updateControls(); let enabled = trustButton.isEnabled
        if let smb = profiles.firstIndex(where: { $0.remoteProtocol == .smb }) { table.selectRowIndexes([smb], byExtendingSelection: false); populate(profiles[smb]); updateControls() }
        return enabled
    }
    func qaSFTPIdentityEnabled() -> Bool {
        guard let sftp = profiles.firstIndex(where: { $0.remoteProtocol == .sftp }) else { return false }
        table.selectRowIndexes([sftp], byExtendingSelection: false); populate(profiles[sftp]); updateControls(); let enabled = identityButton.isEnabled
        if let smb = profiles.firstIndex(where: { $0.remoteProtocol == .smb }) { table.selectRowIndexes([smb], byExtendingSelection: false); populate(profiles[smb]); updateControls() }
        return enabled
    }
    var qaSFTPConnectDisabledWithoutTrustAndIdentity: Bool {
        guard let sftp = profiles.firstIndex(where: { $0.remoteProtocol == .sftp }) else { return false }
        table.selectRowIndexes([sftp], byExtendingSelection: false); populate(profiles[sftp]); updateControls(); let disabled = !sftpConnectButton.isEnabled
        if let smb = profiles.firstIndex(where: { $0.remoteProtocol == .smb }) { table.selectRowIndexes([smb], byExtendingSelection: false); populate(profiles[smb]); updateControls() }
        return disabled
    }
#endif
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int { Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1)) }
}
