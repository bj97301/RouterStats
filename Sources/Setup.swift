import Cocoa

/// First-run (and "Settings…") window: router address, username, password, ping target.
/// The login is tested against the router before anything is saved; the password goes to the Keychain.
final class SetupWindow: NSWindowController, NSWindowDelegate {
    private let address = NSTextField(), username = NSTextField(), password = NSSecureTextField(), ping = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let saveButton = NSButton(title: "Connect", target: nil, action: nil)
    private let onSave: (Config, String) -> Void

    init(existing: Config?, onSave: @escaping (Config, String) -> Void) {
        self.onSave = onSave
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "RouterStats Setup"
        super.init(window: w)
        w.delegate = self
        build(existing: existing)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.alignment = .right; l.font = .systemFont(ofSize: 13); return l
    }

    private func build(existing: Config?) {
        guard let v = window?.contentView else { return }
        let intro = NSTextField(wrappingLabelWithString: "Sign in to your ASUS router with the same username and password you use for its web page. The password is stored in your macOS Keychain.")
        intro.font = .systemFont(ofSize: 12); intro.textColor = .secondaryLabelColor

        address.placeholderString = "192.168.1.1"
        address.stringValue = existing?.address ?? defaultGateway() ?? "192.168.1.1"
        username.stringValue = existing?.username ?? "admin"
        password.placeholderString = existing == nil ? "" : "Unchanged"
        ping.stringValue = existing?.pingTarget ?? "8.8.8.8"
        ping.placeholderString = "8.8.8.8"

        let grid = NSGridView(views: [
            [label("Router address:"), address],
            [label("Username:"), username],
            [label("Password:"), password],
            [label("Ping target:"), ping],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10; grid.columnSpacing = 8
        grid.column(at: 1).width = 260

        status.font = .systemFont(ofSize: 12); status.textColor = .systemRed
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false

        saveButton.target = self; saveButton.action = #selector(connect)
        saveButton.keyEquivalent = "\r"; saveButton.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [spinner, NSView(), cancel, saveButton]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [intro, grid, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor), stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: 400), status.widthAnchor.constraint(equalToConstant: 400),
            buttons.widthAnchor.constraint(equalToConstant: 400),
        ])
        window?.initialFirstResponder = existing == nil ? password : address
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }

    @objc private func cancel() { close() }

    @objc private func connect() {
        let cfg = Config(address: address.stringValue.trimmingCharacters(in: .whitespaces),
                         username: username.stringValue.trimmingCharacters(in: .whitespaces),
                         pingTarget: ping.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "8.8.8.8" : ping.stringValue.trimmingCharacters(in: .whitespaces))
        var pw = password.stringValue
        if pw.isEmpty, let old = Config.current, let saved = Keychain.read(old.keychainAccount) { pw = saved }
        guard cfg.baseURL?.host != nil else { status.stringValue = RouterError.badAddress.errorDescription!; return }
        guard !cfg.username.isEmpty, !pw.isEmpty else { status.stringValue = "Enter the router's username and password."; return }

        status.stringValue = ""; spinner.startAnimation(nil); saveButton.isEnabled = false
        Task { @MainActor in
            defer { spinner.stopAnimation(nil); saveButton.isEnabled = true }
            do {
                try await RouterClient(config: cfg, password: pw).login()
            } catch {
                status.stringValue = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach the router at \(cfg.address): \(error.localizedDescription)"
                return
            }
            if let old = Config.current, old.keychainAccount != cfg.keychainAccount { Keychain.delete(old.keychainAccount) }
            guard Keychain.write(pw, account: cfg.keychainAccount) else { status.stringValue = "Couldn't save the password to the Keychain."; return }
            cfg.save()
            close()
            onSave(cfg, pw)
        }
    }
}
