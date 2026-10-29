// Synthetic responses only: no live subscription, Keychain, UI, or internet access.
final class StubProtocol: URLProtocol {
    static var statusCode = 200
    static var headers: [String: String] = [:]
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    if !value() { fatalError("FAILED: \(label)") }
}

func exercise(status: Int, headers: [String: String]) async -> Result<Usage, Error> {
    StubProtocol.statusCode = status
    StubProtocol.headers = headers
    StubProtocol.requests = []
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    do { return .success(try await fetchUsage(URL(string: "https://example.com/sub")!, configuration: config)) }
    catch { return .failure(error) }
}

let completed = DispatchSemaphore(value: 0)
Task.detached {
    let page = try! websiteUsage("套餐信息\n已用流量 : 12.50 GB\n剩余流量 : 87.50 GB\n29 日后流量重置")
    expect(page.used == 12.5 * 1_073_741_824 && page.total == 100 * 1_073_741_824, "website traffic parsing")
    expect(page.expiry == nil, "never confuse reset countdown with expiry")
    let mixed = try! websiteUsage("已用流量：512 MB\n剩余流量：1.5 GB")
    expect(mixed.total == 2 * 1_073_741_824, "mixed website units")
    for text in ["请登录", "已用流量 : -- GB 剩余流量 : 10 GB", "已用流量:1 GB 已用流量:2 GB 剩余流量:3 GB", "已用流量:1 GB", "已用流量:NaN GB 剩余流量:2 GB"] {
        expect((try? websiteUsage(text)) == nil, "reject incomplete or ambiguous website data")
    }
    let plan = planURL(URL(string: "https://amytele.co/clientarea.php?action=productdetails&id=1&token=TEST_ONLY"))
    expect(plan?.host == "www.amytele.co" && plan?.query == "action=productdetails&id=1", "store only canonical product URL without tokens")
    for url in ["https://evil.example/clientarea.php?action=productdetails&id=1", "http://amytele.co/clientarea.php?action=productdetails&id=1", "https://amytele.co/clientarea.php", "https://amytele.co/clientarea.php?action=productdetails&id=not-a-number"] {
        expect(planURL(URL(string: url)) == nil, "reject unintended product addresses")
    }
    expect(errorMessage(WebsiteError.loginRequired).contains("登录"), "explicit login-expiry message")
    let selected = URL(string: "https://www.amytele.co/clientarea.php?action=productdetails&id=1")!
    let other = URL(string: "https://www.amytele.co/clientarea.php?action=productdetails&id=2")!
    expect(automaticPlanChoice(links: [selected.absoluteString], preferred: nil) == .open(selected), "single plan selected automatically")
    expect(automaticPlanChoice(links: [selected.absoluteString, selected.absoluteString + "&extra=TEST"], preferred: nil) == .open(selected), "duplicate plan links do not require selection")
    expect(automaticPlanChoice(links: [selected.absoluteString, other.absoluteString], preferred: nil) == .choose, "multiple plans need a choice")
    expect(automaticPlanChoice(links: [selected.absoluteString, other.absoluteString], preferred: other) == .open(other), "reuse saved plan")
    expect(automaticPlanChoice(links: [selected.absoluteString], preferred: other) == .open(selected), "stale preference cannot select an absent plan")
    expect(automaticPlanChoice(links: ["https://evil.example/clientarea.php?action=productdetails&id=1", "https://www.amytele.co/logout.php"], preferred: nil) == .none, "never auto-follow external or account-action links")
    let sample = "已用流量:12 GB 剩余流量:88 GB"
    let signedIn = try! classifyWebsitePage(text: sample, currentURL: selected, expectedURL: selected, visibleLogin: true)
    expect(signedIn.used == 12 * 1_073_741_824, "valid plan data wins over password form")
    do {
        _ = try classifyWebsitePage(text: "加载中", currentURL: URL(string: "https://www.amytele.co/clientarea.php"), expectedURL: selected, visibleLogin: false)
        fatalError("Expected page mismatch")
    } catch WebsiteError.changedPage {} catch { fatalError("URL mismatch must not mean login expired") }
    do {
        _ = try classifyWebsitePage(text: "登录", currentURL: selected, expectedURL: selected, visibleLogin: true)
        fatalError("Expected explicit login form")
    } catch WebsiteError.loginRequired {} catch { fatalError("Wrong login classification") }
    do {
        _ = try classifyWebsitePage(text: "用户中心", currentURL: selected, expectedURL: selected, visibleLogin: true, authenticated: true)
        fatalError("Expected incomplete page")
    } catch WebsiteError.changedPage {} catch { fatalError("Authenticated dashboard must not mean logout") }
    do {
        _ = try classifyWebsitePage(text: sample, currentURL: selected, expectedURL: URL(string: "https://www.amytele.co/clientarea.php?action=productdetails&id=2"), visibleLogin: false)
        fatalError("Expected plan mismatch")
    } catch WebsiteError.changedPage {} catch { fatalError("Must not show another plan's data") }
    let good = await exercise(status: 200, headers: ["subscription-userinfo": "upload=10; download=20; total=100"])
    if case .success(let usage) = good { expect(usage.used == 30 && usage.remaining == 70, "successful response") }
    else { fatalError("Expected usage") }
    expect(StubProtocol.requests.count == 1, "one request per refresh")
    expect(StubProtocol.requests[0].httpMethod == "GET", "GET without HEAD probe")
    expect(StubProtocol.requests[0].value(forHTTPHeaderField: "Cookie") == nil, "no browser login cookie")
    expect(StubProtocol.requests[0].value(forHTTPHeaderField: "User-Agent") == "Clash", "client header")

    let forbidden = await exercise(status: 403, headers: [:])
    guard case .failure(let error) = forbidden, case FetchError.http(403, _) = error else { fatalError("Expected HTTP 403") }
    expect(StubProtocol.requests.count == 1, "403 never immediately retried")
    expect(errorMessage(error).contains("403"), "actionable status")
    var gate = RefreshGate()
    let now = Date(timeIntervalSince1970: 1000)
    gate.failed(error, now: now)
    expect(gate.remaining(manual: true, now: now) == 60, "manual cooldown")
    expect(gate.remaining(manual: false, now: now) == 1800, "automatic backoff")
    expect(gate.remaining(manual: true, now: now.addingTimeInterval(61)) == 0, "manual retry allowed after cooldown")

    let limited = await exercise(status: 429, headers: ["Retry-After": "120"])
    guard case .failure(let limitError) = limited, case FetchError.http(429, let delay) = limitError else { fatalError("Expected HTTP 429") }
    expect(delay == 120, "Retry-After seconds")
    gate.failed(limitError, now: now)
    expect(gate.remaining(manual: true, now: now) == 120, "server retry delay honored")
    expect(retryDelay("Thu, 01 Jan 1970 00:20:00 GMT", now: now) == 200, "Retry-After date")
    expect(retryDelay("invalid") == nil, "invalid retry header")

    let missing = await exercise(status: 200, headers: [:])
    guard case .failure(FetchError.missingUsage) = missing else { fatalError("Expected missing usage error") }
    let invalid = await exercise(status: 200, headers: ["subscription-userinfo": "upload=NaN; download=0; total=10"])
    guard case .failure(FetchError.invalidData) = invalid else { fatalError("Expected invalid data error") }
    expect(isManagementURL(URL(string: "https://example.com/Subscription/index?token=TEST")!), "management URL recognized")
    let privateError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "https://example.com/sub?token=PRIVATE"])
    expect(!errorMessage(privateError).contains("PRIVATE") && errorMessage(privateError).contains("超时"), "errors never reveal links")
    print("Website parsing, URL isolation and network regression checks passed; no real account or UI accessed.")
    completed.signal()
}
completed.wait()
