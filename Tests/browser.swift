import WebKit

// Render synthetic HTML in a private, windowless WebKit instance. No accounts,
// live website requests, Keychain access, or application installation.
@MainActor final class BrowserFixtures: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<[String: Any], Error>?
    private var view: WKWebView?
    func snapshot(_ html: String) async throws -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        view.navigationDelegate = self
        self.view = view
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString("<!doctype html><html><body>\(html)</body></html>", baseURL: URL(string: "https://www.amytele.co/clientarea.php")!)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(websiteSnapshotScript) { [weak self] result, error in
            guard let self else { return }
            let pending = self.continuation; self.continuation = nil
            if let data = result as? [String: Any] { pending?.resume(returning: data) }
            else { pending?.resume(throwing: error ?? WebsiteError.changedPage) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let pending = continuation; continuation = nil; pending?.resume(throwing: error)
    }
}

func browserExpect(_ result: @autoclosure () -> Bool, _ label: String) {
    guard result() else { fatalError("Browser fixture failed: \(label)") }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            let fixture = BrowserFixtures()
            let login = try await fixture.snapshot("<form><input type=email><input type=password><button type=submit>登录</button><a href='#'>忘记密码</a></form>")
            browserExpect(login["login"] as? Bool == true, "visible login form")
            let dashboard = try await fixture.snapshot("""
              <a href='/logout.php'>退出账户</a>
              <a href='/clientarea.php?action=productdetails&amp;id=1'>已激活的产品</a>
              <a href='/clientarea.php?action=productdetails&amp;id=1'>重复入口</a>
              <a href='https://evil.example/clientarea.php?action=productdetails&amp;id=2'>外部入口</a>
              <form style='display:none'><input type=email><input type=password><button type=submit>登录</button></form>
              """)
            browserExpect(dashboard["login"] as? Bool == false, "hidden login ignored")
            browserExpect(dashboard["authenticated"] as? Bool == true, "signed-in dashboard")
            let links = dashboard["plans"] as? [String] ?? []
            browserExpect(links.count == 2, "external link excluded")
            browserExpect(automaticPlanChoice(links: links, preferred: nil) == .open(URL(string: "https://www.amytele.co/clientarea.php?action=productdetails&id=1")!), "rendered dashboard automatically finds one plan")
            let plan = try await fixture.snapshot("<a href='/logout.php'>退出</a><div>已用流量 : 12.50 GB</div><div>剩余流量 : 87.50 GB</div>")
            let usage = try websiteUsage(plan["text"] as? String ?? "")
            browserExpect(usage.total == 100 * 1_073_741_824, "rendered usage extracted")
            print("Windowless WebKit fixture checks passed: login, hidden forms, dashboard links and traffic.")
            exit(0)
        } catch {
            print("Windowless WebKit fixture checks failed.")
            exit(1)
        }
    }
    application.run()
}
