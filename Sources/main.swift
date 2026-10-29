import AppKit
import Foundation
import Security
import LocalAuthentication

struct Usage {
    let upload: Double
    let download: Double
    let total: Double
    let expiry: Date?
    var used: Double { upload + download }
    var remaining: Double { max(0, total - used) }

    static func parse(_ header: String) throws -> Usage {
        var fields: [String: Double] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { continue }
            if ["upload", "download", "total", "expire"].contains(pair[0].lowercased()) {
                guard let value = Double(pair[1]), value.isFinite, value >= 0 else { throw FetchError.invalidData }
                fields[pair[0].lowercased()] = value
            }
        }
        guard let up = fields["upload"], let down = fields["download"], let total = fields["total"], (up + down).isFinite else { throw FetchError.invalidData }
        let expiry = fields["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return Usage(upload: up, download: down, total: total, expiry: expiry)
    }
}

enum FetchError: Error { case invalidData, unavailable, redirect }

func validURL(_ value: String) -> URL? {
    guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
          parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
    return parts.url
}

// Read response headers only; never download or retain the node configuration.
final class HeaderRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var callback: ((Result<HTTPURLResponse, Error>) -> Void)?
    private var session: URLSession?

    func run(_ url: URL, method: String) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            callback = { continuation.resume(with: $0) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 25
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            // The provider asks for subscription requests over the local connection.
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("clash/AmyUsage", forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            session.dataTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        let completion = callback
        callback = nil
        completion?(result)
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        if let response = response as? HTTPURLResponse { finish(.success(response)) }
        else { finish(.failure(FetchError.unavailable)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if callback != nil { finish(.failure(error ?? FetchError.unavailable)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, let original = task.originalRequest?.url,
              next.scheme == "https", next.host == original.host, next.port == original.port else {
            completionHandler(nil)
            finish(.failure(FetchError.redirect))
            return
        }
        completionHandler(request)
    }
}

func fetchUsage(_ url: URL) async throws -> Usage {
    for method in ["HEAD", "GET"] {
        let response = try await HeaderRequest().run(url, method: method)
        if (200..<300).contains(response.statusCode), let header = response.value(forHTTPHeaderField: "subscription-userinfo") {
            return try Usage.parse(header)
        }
        if method == "GET" { throw FetchError.unavailable }
    }
    throw FetchError.unavailable
}

enum Credential {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.AmyUsage.subscription", kSecAttrAccount as String: "primary"] }
    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func remove() -> Bool {
        let result = SecItemDelete(query as CFDictionary)
        return result == errSecSuccess || result == errSecItemNotFound
    }
}

func amount(_ bytes: Double) -> String { String(format: "%.2f GB", bytes / 1_073_741_824) }

// Agent applications still need an Edit menu for AppKit's command-key routing.
func installApplicationMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "Amy 流量")
    appMenu.addItem(withTitle: "退出 Amy 流量", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    menu.addItem(editItem)
    NSApp.mainMenu = menu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    let used = NSTextField(labelWithString: "—")
    let remaining = NSTextField(labelWithString: "—")
    let total = NSTextField(labelWithString: "总额度 —")
    let expiry = NSTextField(labelWithString: "")
    let updated = NSTextField(wrappingLabelWithString: "请先添加订阅链接")
    let status = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let refreshButton = NSButton(title: "立即刷新", target: nil, action: nil)
    var settings: NSWindow?
    let urlField = NSSecureTextField()
    let interval = NSPopUpButton()
    let titleOption = NSButton(checkboxWithTitle: "在菜单栏显示剩余流量", target: nil, action: nil)
    var timer: Timer?
    var savedURL: URL?
    var current: Usage?
    var lastUpdate: Date?
    var refreshing = false
    var generation = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        UserDefaults.standard.register(defaults: ["refreshMinutes": 30, "showRemaining": false])
        savedURL = Credential.read().flatMap(validURL)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        updateTitle()
        createPopover()
        configureTimer()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if savedURL != nil { refresh() } else { showSettings() }
    }

    func createPopover() {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 390))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.bottomAnchor, constant: -18)])
        let heading = NSTextField(labelWithString: "Amy 流量")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(heading)
        let subtitle = NSTextField(labelWithString: "剩余流量")
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        remaining.font = .monospacedDigitSystemFont(ofSize: 30, weight: .medium)
        stack.addArrangedSubview(remaining)
        used.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        stack.addArrangedSubview(used)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.style = .bar
        stack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for label in [total, expiry, updated, status] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        status.textColor = .systemOrange
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.bezelStyle = .rounded
        stack.addArrangedSubview(refreshButton)
        let buttons = NSStackView()
        buttons.spacing = 14
        buttons.addArrangedSubview(NSButton(title: "设置", target: self, action: #selector(showSettings)))
        buttons.addArrangedSubview(NSButton(title: "退出", target: self, action: #selector(quit)))
        stack.addArrangedSubview(buttons)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = controller.view.frame.size
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    @objc func refreshClicked() { refresh() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func woke() {
        guard UserDefaults.standard.integer(forKey: "refreshMinutes") > 0 else { return }
        if lastUpdate == nil || Date().timeIntervalSince(lastUpdate!) > Double(UserDefaults.standard.integer(forKey: "refreshMinutes")) * 60 { refresh() }
    }
    func configureTimer() {
        timer?.invalidate()
        guard savedURL != nil else { return }
        let minutes = UserDefaults.standard.integer(forKey: "refreshMinutes")
        guard minutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 30
    }
    func refresh() {
        guard !refreshing else { return }
        guard let url = savedURL else { showSettings(); return }
        refreshing = true
        refreshButton.isEnabled = false
        refreshButton.title = "正在刷新…"
        status.stringValue = ""
        let requestGeneration = generation
        Task { @MainActor in
            defer {
                refreshing = false
                refreshButton.isEnabled = true
                refreshButton.title = "立即刷新"
                if generation != requestGeneration, savedURL != nil { refresh() }
            }
            do {
                let value = try await fetchUsage(url)
                guard generation == requestGeneration else { return }
                current = value
                lastUpdate = Date()
                render()
            } catch {
                guard generation == requestGeneration else { return }
                status.stringValue = "更新失败，已保留上次数据。请检查网络、订阅链接，或稍后重试。"
                if current == nil { updated.stringValue = "尚未成功获取数据" }
                updateTitle()
            }
        }
    }
    func render() {
        guard let value = current else { return }
        used.stringValue = "已用  \(amount(value.used))"
        remaining.stringValue = value.total == 0 ? "不限量" : amount(value.remaining)
        total.stringValue = value.total == 0 ? "总额度：不限量" : "总额度  \(amount(value.total))"
        progress.doubleValue = value.total > 0 ? min(100, value.used / value.total * 100) : 0
        if let date = value.expiry { expiry.stringValue = "订阅到期  " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none) }
        else { expiry.stringValue = "" }
        if let date = lastUpdate { updated.stringValue = "更新于 " + DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .medium) }
        updateTitle()
    }
    func updateTitle() {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "Amy 流量")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        if UserDefaults.standard.bool(forKey: "showRemaining"), let value = current {
            button.title = value.total == 0 ? " 不限量" : " " + amount(value.remaining)
        } else { button.title = "" }
        button.toolTip = "Amy 流量 · 点击查看用量"
    }

    @objc func showSettings() {
        popover.performClose(nil)
        if let settings {
            NSApp.activate(ignoringOtherApps: true)
            settings.makeKeyAndOrderFront(nil)
            settings.makeFirstResponder(urlField)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Amy 流量设置"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        stack.addArrangedSubview(NSTextField(labelWithString: "粘贴 Amy 的 Clash 订阅链接"))
        urlField.placeholderString = savedURL == nil ? "https://…" : "已保存；留空保留现有链接"
        urlField.font = .systemFont(ofSize: 13)
        urlField.isEditable = true
        urlField.isSelectable = true
        let inputRow = NSStackView()
        inputRow.spacing = 8
        inputRow.addArrangedSubview(urlField)
        let pasteButton = NSButton(title: "粘贴链接", target: self, action: #selector(pasteSubscription))
        pasteButton.setContentHuggingPriority(.required, for: .horizontal)
        pasteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        inputRow.addArrangedSubview(pasteButton)
        stack.addArrangedSubview(inputRow)
        inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let help = NSTextField(wrappingLabelWithString: "链接仅保存在本机钥匙串，直接向订阅服务器查询。\n无需网站密码或浏览器权限，不使用第三方转换服务。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let row = NSStackView()
        row.spacing = 12
        row.addArrangedSubview(NSTextField(labelWithString: "自动刷新"))
        for (title, value) in [("仅手动", 0), ("每 15 分钟", 15), ("每 30 分钟", 30), ("每 60 分钟", 60)] {
            interval.addItem(withTitle: title)
            interval.lastItem?.tag = value
        }
        row.addArrangedSubview(interval)
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(titleOption)
        let note = NSTextField(wrappingLabelWithString: "用量以服务商返回为准；GB 按 1024³ 字节显示。\n关闭此窗口后，程序仍在顶部菜单栏运行。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        let actions = NSStackView()
        actions.spacing = 10
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        actions.addArrangedSubview(save)
        actions.addArrangedSubview(NSButton(title: "移除订阅", target: self, action: #selector(removeSubscription)))
        stack.addArrangedSubview(actions)
        settings = window
        interval.selectItem(withTag: UserDefaults.standard.integer(forKey: "refreshMinutes"))
        titleOption.state = UserDefaults.standard.bool(forKey: "showRemaining") ? .on : .off
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(urlField)
    }
    @objc func pasteSubscription() {
        // Clipboard access happens only in response to the user's button click.
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert("剪贴板中没有文字，请先复制 Clash 订阅链接。")
            return
        }
        urlField.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }
    func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
    @objc func saveSettings() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            guard let url = validURL(raw) else { alert("请输入有效的 HTTPS 订阅链接。"); return }
            guard Credential.save(url.absoluteString) else { alert("无法保存到本机钥匙串，设置未更改。"); return }
            savedURL = url
            generation += 1
            current = nil
            lastUpdate = nil
            used.stringValue = "—"
            remaining.stringValue = "—"
            total.stringValue = "总额度 —"
            expiry.stringValue = ""
            progress.doubleValue = 0
            updated.stringValue = "尚未成功获取数据"
            status.stringValue = ""
            urlField.stringValue = ""
            urlField.placeholderString = "已保存；留空保留现有链接"
        }
        guard savedURL != nil else { alert("请先粘贴订阅链接。"); return }
        UserDefaults.standard.set(interval.selectedTag(), forKey: "refreshMinutes")
        UserDefaults.standard.set(titleOption.state == .on, forKey: "showRemaining")
        configureTimer()
        updateTitle()
        settings?.close()
        refresh()
    }
    @objc func removeSubscription() {
        guard Credential.remove() else { alert("无法从钥匙串移除订阅，请重试。"); return }
        generation += 1
        savedURL = nil
        configureTimer()
        current = nil
        lastUpdate = nil
        urlField.stringValue = ""
        urlField.placeholderString = "https://…"
        used.stringValue = "—"
        remaining.stringValue = "—"
        total.stringValue = "总额度 —"
        expiry.stringValue = ""
        progress.doubleValue = 0
        updated.stringValue = "请先添加订阅链接"
        status.stringValue = ""
        updateTitle()
    }
}

if CommandLine.arguments.contains("--self-test") {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAILED: \(name)") }
    }
    let usage = try Usage.parse("upload=1073741824; download=2147483648; total=10737418240; expire=1800000000")
    check(usage.used == 3221225472 && usage.remaining == 7516192768, "traffic calculation")
    check(usage.expiry != nil, "expiry")
    let unlimited = try Usage.parse("upload=1; download=2; total=0; expire=0")
    check(unlimited.total == 0 && unlimited.expiry == nil, "unlimited subscription")
    let over = try Usage.parse("upload=10; download=20; total=5")
    check(over.remaining == 0, "over quota")
    for header in ["", "upload=1; total=5", "upload=-1; download=2; total=3", "upload=nan; download=1; total=3", "upload=inf; download=0; total=1"] {
        check((try? Usage.parse(header)) == nil, "invalid header")
    }
    check(validURL("https://example.com/sub?token=secret") != nil, "valid subscription")
    for url in ["http://example.com", "https://user:password@example.com", "file:///etc/passwd", "https://example.com/#secret", "invalid"] {
        check(validURL(url) == nil, "invalid URL")
    }
    print("All 15 usage and URL checks passed.")
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
