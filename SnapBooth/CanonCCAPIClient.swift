import Foundation
import Security
import UIKit

/// Focused Canon CCAPI client for the iPad booth workflow. Unlike an external
/// UVC capture device, CCAPI asks the camera itself to take the picture, so the
/// R50 V hot shoe and AD-E1 flash participate in the exposure.
actor CanonCCAPIClient {
    static let cameraID = "canon-ccapi-wifi"
    static let displayName = "佳能 EOS R50 V · Wi-Fi/闪光"
    static let defaultAddress = "http://192.168.1.2:8080"
    static let addressDefaultsKey = "CanonCCAPIBaseURL"
    static let usernameDefaultsKey = "CanonCCAPIUsername"

    struct Connection: Sendable {
        let model: String
        let versionPrefix: String
    }

    private let session: URLSession
    private let authenticationDelegate: CanonCCAPISessionDelegate
    private var baseURL: URL
    private var versionPrefix = "/ccapi/ver100"
    private var advertisedPaths: [String] = []
    private var model = "佳能 EOS R50 V"
    private var liveViewStarted = false
    private var frameSerial: UInt64 = 0

    init(address: String = CanonCCAPIClient.savedAddress) {
        let initialURL = Self.normalizedURL(address) ?? URL(string: Self.defaultAddress)!
        let username = Self.savedUsername
        let delegate = CanonCCAPISessionDelegate(
            host: initialURL.host ?? "",
            username: username,
            password: CanonCredentialStore.password(username: username) ?? ""
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        authenticationDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        baseURL = initialURL
    }

    static var savedAddress: String {
        if let launchAddress = ProcessInfo.processInfo.argumentValue(after: "--canon-ccapi-url") {
            UserDefaults.standard.set(launchAddress, forKey: addressDefaultsKey)
            return launchAddress
        }
        return UserDefaults.standard.string(forKey: addressDefaultsKey) ?? defaultAddress
    }

    static var savedUsername: String {
        UserDefaults.standard.string(forKey: usernameDefaultsKey) ?? ""
    }

    func configure(address: String, username: String, password: String) throws {
        guard let url = Self.normalizedURL(address) else { throw CCAPIError.invalidAddress }
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = url
        versionPrefix = "/ccapi/ver100"
        liveViewStarted = false
        UserDefaults.standard.set(Self.addressString(url), forKey: Self.addressDefaultsKey)
        UserDefaults.standard.set(cleanUsername, forKey: Self.usernameDefaultsKey)
        let effectivePassword: String
        if cleanUsername.isEmpty {
            CanonCredentialStore.save(password: "", username: "")
            effectivePassword = ""
        } else if password.isEmpty, let saved = CanonCredentialStore.password(username: cleanUsername) {
            effectivePassword = saved
        } else {
            CanonCredentialStore.save(password: password, username: cleanUsername)
            effectivePassword = password
        }
        authenticationDelegate.update(host: url.host ?? "", username: cleanUsername, password: effectivePassword)
    }

    func configuredAddress() -> String { Self.addressString(baseURL) }

    func connect() async throws -> Connection {
        var discoveryPaths: [String] = []
        for rootPath in ["/ccapi", "/ccapi/"] {
            if let value = try? await json(path: rootPath) {
                discoveryPaths.append(contentsOf: Self.cameraPaths(in: value))
                if discoveryPaths.isEmpty,
                   let developer = try? await json(path: "/ccapi/ver100/topurlfordev") {
                    discoveryPaths.append(contentsOf: Self.cameraPaths(in: developer))
                }
                break
            }
        }
        advertisedPaths = discoveryPaths.removingDuplicates()
        var candidates = advertisedPaths
            .filter { $0.hasSuffix("/deviceinformation") }
            .sorted { Self.versionNumber($0) > Self.versionNumber($1) }
        candidates.append(contentsOf: [
            "/ccapi/ver110/deviceinformation", "/ccapi/ver100/deviceinformation"
        ])
        candidates = candidates.removingDuplicates()

        var lastError: Error?
        for infoPath in candidates {
            do {
                let info = try await json(path: infoPath)
                versionPrefix = String(infoPath.dropLast("/deviceinformation".count))
                model = Self.findString(keys: ["productname", "model", "name"], in: info)
                    ?? "佳能 EOS R50 V"
                return Connection(model: model, versionPrefix: versionPrefix)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CCAPIError.cameraNotFound
    }

    func startLiveView() async throws {
        if liveViewStarted { return }
        let path = operationPath(suffix: "/shooting/liveview")
        do {
            _ = try await request(path: path, method: "POST", json: [
                "cameradisplay": "on", "liveviewsize": "small"
            ])
        } catch let error as CCAPIError where error.statusCode == 400 {
            _ = try await request(path: path, method: "POST", json: ["cameradisplay": "on"])
        }
        liveViewStarted = true
    }

    func stopLiveView() async {
        guard liveViewStarted else { return }
        let path = operationPath(suffix: "/shooting/liveview")
        if (try? await request(path: path, method: "DELETE")) == nil {
            _ = try? await request(path: path, method: "POST", json: [
                "cameradisplay": "on", "liveviewsize": "off"
            ])
        }
        liveViewStarted = false
    }

    func liveViewFrame() async throws -> UIImage {
        frameSerial &+= 1
        let paths = [
            operationPath(suffix: "/shooting/liveview/flip"),
            operationPath(suffix: "/shooting/liveview/flipdetail") + "?kind=image",
            operationPath(suffix: "/shooting/liveview")
        ]
        var lastError: Error?
        for path in paths {
            do {
                let suffix = path.contains("?") ? "&t=\(frameSerial)" : "?t=\(frameSerial)"
                let (data, _) = try await request(path: path + suffix, accept: "image/jpeg,application/octet-stream,*/*")
                if let image = Self.image(fromLiveViewData: data) { return image }
                lastError = CCAPIError.invalidImage
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CCAPIError.invalidImage
    }

    func capturePhoto() async throws -> UIImage {
        let before = (try? await newestMediaPaths(limit: 12)) ?? []
        let shutterPath = operationPath(suffix: "/shooting/control/shutterbutton")
        do {
            _ = try await request(path: shutterPath, method: "POST", json: ["af": true], timeout: 310)
        } catch let accepted as CCAPIError where accepted.isCanonCaptureInProgress {
            // R50 V 1.2.0 can return 503 after accepting the exposure. Do not
            // send a second shutter command; wait for the new card item.
        } catch let directError as CCAPIError where directError.statusCode == 404 || directError.statusCode == 405 {
            let manual = operationPath(suffix: "/shooting/control/shutterbutton/manual")
            do {
                _ = try await request(path: manual, method: "POST", json: ["af": true, "action": "full_press"], timeout: 310)
            } catch let postError as CCAPIError where postError.statusCode == 405 {
                _ = try await request(path: manual, method: "PUT", json: ["af": true, "action": "full_press"], timeout: 310)
            }
            try? await Task.sleep(for: .milliseconds(120))
            if (try? await request(path: manual, method: "POST", json: ["af": false, "action": "release"])) == nil {
                _ = try await request(path: manual, method: "PUT", json: ["af": false, "action": "release"])
            }
        }

        // The shutter response only acknowledges the command. The full JPEG is
        // written to the card asynchronously, so wait for a new contents URL.
        let old = Set(before)
        var latest = before.first
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))
        var attempt = 0
        while clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(attempt < 6 ? 500 : 1_000))
            attempt += 1
            if let paths = try? await newestMediaPaths(limit: 12) {
                latest = paths.first ?? latest
                if let newPath = paths.first(where: { !old.contains($0) }) {
                    return try await downloadImage(path: newPath)
                }
            }
        }

        // If the camera does not expose a stable pre-capture list, the newest
        // card item is still a better fallback than a low-resolution UVC frame.
        if before.isEmpty, let latest { return try await downloadImage(path: latest) }
        throw CCAPIError.photoDidNotAppear
    }

    func latestPhoto() async throws -> UIImage {
        guard let path = try await newestMediaPaths(limit: 1).first else {
            throw CCAPIError.noPhotos
        }
        return try await downloadImage(path: path)
    }

    private func newestMediaPaths(limit: Int) async throws -> [String] {
        var queue = [operationPath(suffix: "/contents")]
        var index = 0
        var visited = Set<String>()
        var media: [String] = []
        while index < queue.count, visited.count < 24, media.count < limit {
            let container = queue[index]
            index += 1
            guard visited.insert(container).inserted else { continue }
            let paths = try await contentPaths(container: container)
            for raw in paths {
                guard let path = normalizedCameraPath(raw) else { continue }
                if Self.isPhotoPath(path) {
                    if !media.contains(path) { media.append(path) }
                } else if path.contains("/contents"), !visited.contains(path), !queue.contains(path) {
                    queue.append(path)
                }
                if media.count >= limit { break }
            }
        }
        return Array(media.prefix(limit))
    }

    private func contentPaths(container: String) async throws -> [String] {
        let numberValue = try? await json(path: container + "?kind=number")
        let pages = Self.findInt(key: "pagenumber", in: numberValue as Any) ?? 0
        if pages > 0 {
            var result: [String] = []
            do {
                let first = try await json(path: "\(container)?page=1&order=desc")
                result.append(contentsOf: Self.findStringArray(key: "path", in: first))
                if pages > 1 {
                    for page in 2...min(pages, 3) {
                        let value = try await json(path: "\(container)?page=\(page)&order=desc")
                        result.append(contentsOf: Self.findStringArray(key: "path", in: value))
                    }
                }
            } catch {
                // R50 V firmware 1.2 rejects order=desc. Its plain pages are
                // oldest-first, so walk backward from the final page and
                // reverse each page to put the newest capture first.
                for page in stride(from: pages, through: max(1, pages - 2), by: -1) {
                    let value = try await json(path: "\(container)?page=\(page)")
                    result.append(contentsOf: Self.findStringArray(key: "path", in: value).reversed())
                }
            }
            return result
        }
        return Self.findStringArray(key: "path", in: try await json(path: container))
    }

    private func downloadImage(path: String) async throws -> UIImage {
        for candidate in [path, path + "?kind=main", path + "?type=main"] {
            if let (data, _) = try? await request(path: candidate, accept: "image/jpeg,image/*,*/*"),
               let image = UIImage(data: data) {
                return image
            }
        }
        throw CCAPIError.invalidImage
    }

    private func json(path: String) async throws -> Any {
        let (data, _) = try await request(path: path, accept: "application/json")
        guard !data.isEmpty else { return [:] }
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    private func request(
        path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        accept: String = "application/json",
        timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let url: URL
        if let absolute = URL(string: path), absolute.scheme != nil {
            guard absolute.host == baseURL.host, absolute.port == baseURL.port else {
                throw CCAPIError.invalidCameraPath
            }
            url = absolute
        } else {
            guard let built = URL(string: Self.addressString(baseURL) + (path.hasPrefix("/") ? path : "/" + path)) else {
                throw CCAPIError.invalidCameraPath
            }
            url = built
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? (method == "GET" ? 7 : 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CCAPIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data.prefix(500), encoding: .utf8) ?? ""
                throw CCAPIError.http(http.statusCode, detail)
            }
            return (data, http)
        } catch let error as CCAPIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw CCAPIError.timedOut
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CCAPIError.transport(error.localizedDescription)
        }
    }

    private func normalizedCameraPath(_ raw: String) -> String? {
        if let absolute = URL(string: raw), absolute.scheme != nil {
            guard absolute.host == baseURL.host, absolute.port == baseURL.port else { return nil }
            var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false)
            components?.scheme = nil
            components?.host = nil
            components?.port = nil
            return components?.string
        }
        return raw.hasPrefix("/ccapi/") ? raw : nil
    }

    private func operationPath(suffix: String) -> String {
        advertisedPaths
            .filter { $0.hasSuffix(suffix) }
            .max { Self.versionNumber($0) < Self.versionNumber($1) }
            ?? versionPrefix + suffix
    }

    private static func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: expanded),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        if components.port == nil { components.port = components.scheme == "https" ? 443 : 8080 }
        components.path = ""
        return components.url
    }

    private static func addressString(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func versionNames(in value: Any) -> [String] {
        var found = Set<String>()
        func visit(_ node: Any) {
            if let string = node as? String {
                let expression = try? NSRegularExpression(pattern: "ver[0-9]{3}")
                let range = NSRange(string.startIndex..., in: string)
                expression?.matches(in: string, range: range).forEach {
                    if let match = Range($0.range, in: string) { found.insert(String(string[match])) }
                }
            } else if let dictionary = node as? [String: Any] {
                dictionary.forEach { key, child in visit(key); visit(child) }
            } else if let array = node as? [Any] {
                array.forEach(visit)
            }
        }
        visit(value)
        return Array(found)
    }

    private static func cameraPaths(in value: Any) -> [String] {
        var found: [String] = []
        func visit(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                if let path = dictionary["path"] as? String,
                   path.range(of: #"^/ccapi/ver[0-9]{3}/"#, options: .regularExpression) != nil {
                    found.append(path)
                }
                dictionary.values.forEach(visit)
            } else if let array = node as? [Any] {
                array.forEach(visit)
            }
        }
        visit(value)
        return found
    }

    private static func versionNumber(_ value: String) -> Int {
        Int(value.components(separatedBy: "ver").last ?? "0") ?? 0
    }

    private static func findString(keys: Set<String>, in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key.lowercased()), let string = child as? String, !string.isEmpty { return string }
                if let result = findString(keys: keys, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array { if let result = findString(keys: keys, in: child) { return result } }
        }
        return nil
    }

    private static func findStringArray(key: String, in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            if let strings = dictionary[key] as? [String] { return strings }
            for child in dictionary.values {
                let result = findStringArray(key: key, in: child)
                if !result.isEmpty { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                let result = findStringArray(key: key, in: child)
                if !result.isEmpty { return result }
            }
        }
        return []
    }

    private static func findInt(key: String, in value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            if let number = dictionary[key] as? NSNumber { return number.intValue }
            for child in dictionary.values { if let result = findInt(key: key, in: child) { return result } }
        } else if let array = value as? [Any] {
            for child in array { if let result = findInt(key: key, in: child) { return result } }
        }
        return nil
    }

    private static func isPhotoPath(_ path: String) -> Bool {
        let lower = path.components(separatedBy: "?")[0].lowercased()
        return [".jpg", ".jpeg", ".heif", ".heic"].contains { lower.hasSuffix($0) }
    }

    private static func image(fromLiveViewData data: Data) -> UIImage? {
        if let direct = UIImage(data: data) { return direct }
        // flipdetail may wrap the JPEG in Canon packets. Finding SOI/EOI keeps
        // this client compatible without accepting arbitrary external URLs.
        let bytes = [UInt8](data)
        guard let start = bytes.indices.first(where: { $0 + 1 < bytes.count && bytes[$0] == 0xff && bytes[$0 + 1] == 0xd8 }) else {
            return nil
        }
        var end: Int?
        if start + 2 < bytes.count {
            for index in stride(from: bytes.count - 2, through: start + 2, by: -1) {
                if bytes[index] == 0xff, bytes[index + 1] == 0xd9 { end = index + 2; break }
            }
        }
        guard let end else { return nil }
        return UIImage(data: data.subdata(in: start..<end))
    }
}

enum CCAPIError: LocalizedError {
    case invalidAddress
    case invalidCameraPath
    case cameraNotFound
    case invalidResponse
    case invalidImage
    case noPhotos
    case photoDidNotAppear
    case timedOut
    case transport(String)
    case http(Int, String)

    var statusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    var isCanonCaptureInProgress: Bool {
        if case .timedOut = self { return true }
        guard case .http(503, let detail) = self else { return false }
        let value = detail.lowercased()
        return value.contains("during shooting") || value.contains("af ng") || value.contains("device busy")
    }

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "相机地址无效，请输入例如 192.168.1.2:8080"
        case .invalidCameraPath: return "相机返回了无效的 CCAPI 地址"
        case .cameraNotFound: return "未发现佳能 CCAPI，请确认 iPad 与相机在同一 Wi-Fi"
        case .invalidResponse: return "相机返回的数据无法识别"
        case .invalidImage: return "已拍摄，但无法读取相机里的照片数据"
        case .noPhotos: return "相机存储卡中没有可读取的照片"
        case .photoDidNotAppear: return "快门已触发，但等待 5 分钟后仍未在存储卡中发现新照片"
        case .timedOut: return "相机请求超时"
        case .transport(let detail): return "无法连接佳能相机：\(detail)"
        case .http(let code, let detail):
            if code == 401 { return "佳能 CCAPI 拒绝了账号或密码，请重新确认相机中的用户认证设置" }
            if code == 503 { return "相机正忙，请结束 Camera Connect 或等待写卡完成后重试" }
            return detail.isEmpty ? "佳能相机返回 HTTP \(code)" : "佳能相机返回 HTTP \(code)：\(detail)"
        }
    }
}

private extension ProcessInfo {
    func argumentValue(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private final class CanonCCAPISessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var host: String
    private var username: String
    private var password: String

    init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    func update(host: String, username: String, password: String) {
        lock.lock()
        self.host = host
        self.username = username
        self.password = password
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let values = credentials()
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == values.host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Canon's local HTTPS server uses its own certificate. Trust is scoped
        // to the exact configured LAN host rather than disabled globally.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let values = credentials()
        guard [NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodHTTPBasic].contains(method),
              challenge.protectionSpace.host == values.host,
              !values.username.isEmpty,
              challenge.previousFailureCount == 0 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(user: values.username, password: values.password, persistence: .forSession)
        )
    }

    private func credentials() -> (host: String, username: String, password: String) {
        lock.lock()
        defer { lock.unlock() }
        return (host, username, password)
    }
}

private enum CanonCredentialStore {
    private static let service = "app.snapbooth.canon-ccapi"

    static func save(password: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        guard !username.isEmpty, !password.isEmpty else { return }
        var value = query
        value[kSecAttrAccount as String] = username
        value[kSecValueData as String] = Data(password.utf8)
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(value as CFDictionary, nil)
    }

    static func password(username: String) -> String? {
        guard !username.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
