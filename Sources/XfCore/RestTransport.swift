import Foundation

/// REST 调用的公共部分：每次发送前现签，解析服务端统一包装 Result{code, message, data}。
/// 服务端业务失败时 HTTP 仍是 200，以 code != 200 表示失败。
final class RestTransport {
    let session: URLSession
    let baseURL: URL
    let credentials: DeviceCredentials?
    let clock: ServerClock

    private static let successCode = 200

    /// credentials 为 nil 时不签名（设备注册接口）
    init(session: URLSession, baseURL: URL, credentials: DeviceCredentials?, clock: ServerClock) {
        self.session = session
        self.baseURL = baseURL
        self.credentials = credentials
        self.clock = clock
    }

    // MARK: 请求构造

    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        let url = baseURL.appendingPathComponent(path)
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        guard !items.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = items
        return components.url ?? url
    }

    func jsonRequest(_ path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func getRequest(_ path: String, query: [String: String?] = [:]) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "GET"
        return request
    }

    func deleteRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = "DELETE"
        return request
    }

    func multipartRequest(_ path: String, form: MultipartForm) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.body()
        return request
    }

    func signed(_ request: URLRequest) throws -> URLRequest {
        guard let credentials = credentials else { return request }
        var request = request
        for (name, value) in try Signer.headers(credentials: credentials, clock: clock) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    // MARK: 发送

    /// 发送并解析 Result 信封，返回 Result.data（对象、数组、布尔或 nil）。
    /// 报"请求已过期"时时钟已按响应 Date 头校准，换新签名重发一次。
    func result(_ request: URLRequest) async throws -> Any? {
        do {
            return try await resultOnce(request)
        } catch let error as XfError where error.kind == .clockSkew {
            return try await resultOnce(request)
        }
    }

    func object(_ request: URLRequest) async throws -> [String: Any] {
        guard let object = try await result(request) as? [String: Any] else {
            throw XfError(kind: .protocol, message: "expected JSON object in Result.data")
        }
        return object
    }

    private func resultOnce(_ request: URLRequest) async throws -> Any? {
        let json = try await jsonObject(signed(request))
        let code = (json["code"] as? NSNumber)?.intValue
        guard code == Self.successCode else {
            throw XfError.fromServer(code: code, message: json["message"] as? String ?? "unknown error")
        }
        let data = json["data"]
        return data is NSNull ? nil : data
    }

    /// 发送已签名的请求，响应体按 JSON 对象解析（不看 Result 信封）
    func jsonObject(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await send(request)
        clock.observe(response: response)
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return json
        }
        let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XfError(kind: .serverError, message: "HTTP \(http.statusCode): \(text)", serverCode: http.statusCode)
        }
        throw XfError(kind: .protocol, message: "response is not a JSON object: \(text)")
    }

    // URLSession.data(for:) 要 iOS 15，这里自己包一层以支持 iOS 13
    func send(_ request: URLRequest, using session: URLSession? = nil) async throws -> (Data, URLResponse) {
        let session = session ?? self.session
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: XfError.network(error))
                    } else if let response = response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: XfError(kind: .protocol, message: "empty response"))
                    }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox {
        private let lock = NSLock()
        private var _task: URLSessionTask?
        var task: URLSessionTask? {
            get { lock.lock(); defer { lock.unlock() }; return _task }
            set { lock.lock(); _task = newValue; lock.unlock() }
        }
    }
}

/// multipart/form-data 构造。列表字段按 Spring 绑定规则重复同名字段。
struct MultipartForm {
    let boundary = "xf-\(UUID().uuidString)"
    private var parts: [(header: String, data: Data)] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(_ name: String, _ value: String) {
        parts.append(("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", Data(value.utf8)))
    }

    mutating func add(_ name: String, fileName: String, contentType: String, data: Data) {
        let header = "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: \(contentType)\r\n\r\n"
        parts.append((header, data))
    }

    func body() -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data(part.header.utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    static func audioContentType(_ fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "ogg", "opus": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}

// MARK: JSON 取值

extension Dictionary where Key == String, Value == Any {
    /// 缺失、NSNull、空串都返回 nil
    func str(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }

    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }

    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }

    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }

    func objects(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}
