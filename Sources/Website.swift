import AppKit
import WebKit

enum WebsiteError: Error { case loginRequired, selectPlan, changedPage, timedOut, blockedNavigation }

func planURL(_ url: URL?) -> URL? {
    guard let url, url.scheme == "https", ["amytele.co", "www.amytele.co"].contains(url.host?.lowercased() ?? ""),
          url.path == "/clientarea.php", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.queryItems?.first(where: { $0.name == "action" })?.value == "productdetails",
          let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
          !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    var safe = URLComponents(string: "https://www.amytele.co/clientarea.php")!
    safe.queryItems = [URLQueryItem(name: "action", value: "productdetails"), URLQueryItem(name: "id", value: id)]
    return safe.url
}

enum PlanChoice: Equatable { case open(URL), choose, none }

func automaticPlanChoice(links: [String], preferred: URL?) -> PlanChoice {
    let candidates = Set(links.compactMap { planURL(URL(string: $0)) })
    if let preferred = planURL(preferred), candidates.contains(preferred) { return .open(preferred) }
    if candidates.count == 1, let only = candidates.first { return .open(only) }
    return candidates.isEmpty ? .none : .choose
}

func websiteUsage(_ text: String) throws -> Usage {
    func value(_ label: String) throws -> Double {
        let regex = try NSRegularExpression(pattern: label + #"\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)\s*(GiB|GB|MiB|MB|TiB|TB|KiB|KB|B)\b"#, options: .caseInsensitive)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let match = matches.first,
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange]), number.isFinite else { throw WebsiteError.changedPage }
        let unit = text[unitRange].uppercased()
        let exponent = ["B":0, "KB":1, "KIB":1, "MB":2, "MIB":2, "GB":3, "GIB":3, "TB":4, "TIB":4][unit]!
        let bytes = number * pow(1024, Double(exponent))
        guard bytes.isFinite else { throw WebsiteError.changedPage }
        return bytes
    }
    let used = try value("已用流量")
    let remaining = try value("剩余流量")
    guard used + remaining > 0, (used + remaining).isFinite else { throw WebsiteError.changedPage }
    return Usage(upload: 0, download: used, total: used + remaining, expiry: nil)
}

// A password field can belong to a hidden dialog, not the sign-in page.
// Valid traffic on the selected plan always takes precedence.
func classifyWebsitePage(text: String, currentURL: URL?, expectedURL: URL?, visibleLogin: Bool, authenticated: Bool = false) throws -> Usage {
    if let expected = planURL(expectedURL), planURL(currentURL) == expected,
       let usage = try? websiteUsage(text) { return usage }
    if visibleLogin && !authenticated { throw WebsiteError.loginRequired }
    throw WebsiteError.changedPage
}

let websiteSnapshotScript = #"""
(() => {
  const visible = e => {
    const style = getComputedStyle(e);
    return e.getClientRects().length > 0 && style.display !== 'none' &&
      style.visibility !== 'hidden' && style.visibility !== 'collapse' && style.opacity !== '0';
  };
  const passwords = [...document.querySelectorAll('input[type="password"]')].filter(visible);
  const login = passwords.some(input => {
    const form = input.closest('form');
    if (!form) return false;
    const hasIdentity = [...form.querySelectorAll('input[type="email"], input[name="username"], input[name="email"]')].some(visible);
    const hasLoginButton = [...form.querySelectorAll('button[type="submit"],input[type="submit"],button:not([type])')]
      .some(button => visible(button) && /登录|登入|log\s*in|sign\s*in/i.test(button.innerText || button.value || ''));
    return hasIdentity && hasLoginButton;
  });
  const authenticated = [...document.querySelectorAll('a[href]')].some(link => {
    try { const url = new URL(link.href); return visible(link) && url.origin === location.origin && url.pathname === '/logout.php'; }
    catch { return false; }
  });
  const plans = [...document.querySelectorAll('a[href]')].filter(link => {
    try {
      const url = new URL(link.href);
      return url.origin === location.origin && url.pathname === '/clientarea.php' &&
        url.searchParams.get('action') === 'productdetails';
    } catch { return false; }
  }).map(link => link.href);
  return {text: document.body.innerText, login, authenticated, plans};
})()
"""#

// A dedicated WebKit session. It neither reads Safari data nor exports cookies.
@MainActor final class WebsiteReader: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var pending: CheckedContinuation<Usage, Error>?
    private var deadline: Timer?
    private var poll: Timer?
    private var requestID = UUID()
    private var expectedURL: URL?
    private var recoveredNavigation = false
    private let dataStore = WKWebsiteDataStore.default()
    private let loginStatus = NSTextField(wrappingLabelWithString: "请登录，程序会自动查找套餐。")
    private var loginPoll: Timer?
    private var loginEpoch = UUID()
    private var preferredPlan: URL?
    private var automaticVisits = Set<URL>()
    var onSelection: ((URL, Usage) -> Void)?
    var onCleared: (() -> Void)?

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 620), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    func showLogin(preferredURL: URL? = nil) {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        if pending != nil { finish(.failure(WebsiteError.selectPlan)) }
        preferredPlan = planURL(preferredURL)
        automaticVisits.removeAll()
        loginEpoch = UUID()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Amy 官方网站 · 登录后自动查询"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12)])
        let explanation = NSTextField(wrappingLabelWithString: "只需在下方 Amy 官方网页登录，程序会自动进入套餐并查询流量。多个套餐时，请选择一个。\n登录会话保存在本机，与 Safari 独立；程序不读取密码输入框，不自动修改套餐设置。")
        stack.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        loginStatus.stringValue = "请登录，程序会自动查找套餐。"
        loginStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(loginStatus)
        loginStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let actions = NSStackView(views: [NSButton(title: "重新查找套餐", target: self, action: #selector(openHome)), NSButton(title: "手动使用当前套餐", target: self, action: #selector(selectPlan))])
        actions.spacing = 12
        stack.addArrangedSubview(actions)
        let view = makeWebView()
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let preferred = planURL(preferredURL) {
            view.load(URLRequest(url: preferred, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
        } else { openHome() }
    }

    @objc private func openHome() {
        preferredPlan = nil
        automaticVisits.removeAll()
        loginStatus.stringValue = "正在查找套餐…"
        makeWebView().load(URLRequest(url: URL(string: "https://www.amytele.co/clientarea.php")!))
    }

    private func inspectLogin(attempt: Int = 0) {
        guard window != nil, pending == nil, let view = webView, !view.isLoading else { return }
        loginPoll?.invalidate(); loginPoll = nil
        let epoch = loginEpoch
        let pageURL = view.url
        view.evaluateJavaScript(websiteSnapshotScript) { [weak self] result, _ in
            guard let self, self.window != nil, self.loginEpoch == epoch,
                  view.url == pageURL, !view.isLoading else { return }
            guard let data = result as? [String: Any] else {
                self.loginStatus.stringValue = "页面尚未准备好，请完成登录后稍候。"
                self.scheduleLoginInspection(attempt: attempt + 1)
                return
            }
            if let url = planURL(view.url), let text = data["text"] as? String,
               let usage = try? websiteUsage(text) {
                self.loginStatus.stringValue = "已获取流量，正在完成设置。"
                self.onSelection?(url, usage)
                self.window?.close()
                return
            }
            if data["login"] as? Bool == true && data["authenticated"] as? Bool != true {
                self.loginStatus.stringValue = "请完成登录或网站验证，后续步骤会自动进行。"
                // Watch local page state only; do not submit credentials or issue keep-alive requests.
                self.scheduleLoginInspection(attempt: 0, delay: 3)
                return
            }
            if data["authenticated"] as? Bool == true, planURL(view.url) == nil {
                switch automaticPlanChoice(links: data["plans"] as? [String] ?? [], preferred: self.preferredPlan) {
                case .open(let url):
                    if self.automaticVisits.insert(url).inserted {
                        self.loginStatus.stringValue = "登录成功，正在自动读取套餐流量…"
                        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
                        return
                    }
                    self.loginStatus.stringValue = "套餐页面未能打开。请在下方选择套餐，程序会自动读取。"
                    return
                case .choose:
                    self.loginStatus.stringValue = "找到多个套餐，请在下方选择一个；打开后会自动完成绑定。"
                    return
                case .none:
                    let services = URL(string: "https://www.amytele.co/clientarea.php?action=services")!
                    if attempt >= 2, self.automaticVisits.insert(services).inserted {
                        self.loginStatus.stringValue = "登录成功，正在查找产品服务列表…"
                        view.load(URLRequest(url: services, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
                        return
                    }
                }
            }
            if attempt >= 10 {
                self.loginStatus.stringValue = "暂未找到可读取的流量。请确认登录完成，或在下方打开具体套餐。"
                return
            }
            self.scheduleLoginInspection(attempt: attempt + 1)
        }
    }

    private func scheduleLoginInspection(attempt: Int, delay: TimeInterval = 1) {
        guard window != nil, attempt <= 10 else { return }
        let epoch = loginEpoch
        loginPoll = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.loginEpoch == epoch else { return }
                self.inspectLogin(attempt: attempt)
            }
        }
    }

    @objc private func selectPlan() {
        guard let view = webView, let url = planURL(view.url), !view.isLoading else { showAlert("请先登录，并打开显示已用和剩余流量的套餐页面。"); return }
        view.evaluateJavaScript("document.body.innerText") { [weak self] result, error in
            guard let self, planURL(view.url) == url, error == nil, let text = result as? String else { return }
            do {
                let usage = try websiteUsage(text)
                self.onSelection?(url, usage)
                self.window?.close()
            } catch { self.showAlert("未能识别当前页面的流量。请确认已打开具体套餐，且已用/剩余流量已经显示。")} 
        }
    }

    func fetch(_ url: URL) async throws -> Usage {
        guard planURL(url) != nil else { throw WebsiteError.selectPlan }
        guard pending == nil, window == nil else { throw WebsiteError.selectPlan }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            expectedURL = url
            recoveredNavigation = false
            requestID = UUID()
            deadline = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finish(.failure(WebsiteError.timedOut)) }
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            makeWebView().load(request)
        }
    }

    private func inspect(attempt: Int = 0) {
        guard pending != nil, let view = webView else { return }
        let id = requestID
        // Only rendered text is read, never password input values or cookies.
        view.evaluateJavaScript(websiteSnapshotScript) { [weak self] result, _ in
            guard let self, self.pending != nil, self.requestID == id else { return }
            guard let data = result as? [String: Any] else { self.finish(.failure(WebsiteError.changedPage)); return }
            let authenticated = data["authenticated"] as? Bool == true
            if authenticated, let expected = self.expectedURL, planURL(view.url) != expected, !self.recoveredNavigation {
                // The website may return to the account dashboard despite a valid session.
                // Follow the user's saved plan once, without clicking any account actions.
                self.recoveredNavigation = true
                view.load(URLRequest(url: expected, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
                return
            }
            do {
                let usage = try classifyWebsitePage(text: data["text"] as? String ?? "", currentURL: view.url,
                    expectedURL: self.expectedURL, visibleLogin: data["login"] as? Bool == true, authenticated: authenticated)
                self.finish(.success(usage)); return
            } catch WebsiteError.loginRequired {
                if attempt >= 2 { self.finish(.failure(WebsiteError.loginRequired)); return }
            }
            catch { /* Wait briefly for client-side content or navigation to settle. */ }
            if attempt >= 8 { self.finish(.failure(WebsiteError.changedPage)); return }
            self.poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.inspect(attempt: attempt + 1) }
            }
        }
    }

    private func finish(_ result: Result<Usage, Error>) {
        let continuation = pending
        pending = nil
        deadline?.invalidate(); deadline = nil
        poll?.invalidate(); poll = nil
        expectedURL = nil
        releaseWebView()
        continuation?.resume(with: result)
    }
    private func releaseWebView() {
        guard window == nil else { return }
        // Keep the same browser session alive between refreshes. Recreating it
        // for every request can discard transient page/session state.
        webView?.stopLoading()
    }
    func windowWillClose(_ notification: Notification) {
        loginPoll?.invalidate(); loginPoll = nil
        loginEpoch = UUID()
        webView?.removeFromSuperview()
        window?.contentView = nil
        window = nil
        releaseWebView()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loginEpoch = UUID()
        loginPoll?.invalidate(); loginPoll = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if pending != nil { inspect() }
        else if window != nil { inspectLogin() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if pending != nil { finish(.failure(error)) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if pending != nil { finish(.failure(error)) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if pending != nil { finish(.failure(WebsiteError.changedPage)) } }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        guard let url = action.request.url, url.scheme == "https", ["amytele.co", "www.amytele.co"].contains(url.host?.lowercased() ?? "") else {
            decisionHandler(.cancel)
            if pending != nil { finish(.failure(WebsiteError.blockedNavigation)) }
            else { showAlert("此登录窗口只允许访问 Amy 官方网站。外部链接未打开。") }
            return
        }
        decisionHandler(.allow)
    }
    func clearSession() {
        if pending != nil { finish(.failure(WebsiteError.loginRequired)) }
        window?.close()
        releaseWebView()
        webView?.navigationDelegate = nil
        webView = nil
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in self?.onCleared?() }
        }
    }
    private func showAlert(_ message: String) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "好"); alert.runModal()
    }
}
