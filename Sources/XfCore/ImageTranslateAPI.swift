import Foundation

/// 拍照翻译，对应 /trans/v1/device/image-translate。
public final class ImageTranslateAPI {
    private let transport: RestTransport

    init(transport: RestTransport) {
        self.transport = transport
    }

    public func translate(_ request: ImageTranslateRequest) async throws -> ImageTranslateResult {
        var body: [String: Any] = [
            "image": request.image.base64EncodedString(),
            "targetLanguage": request.targetLanguage,
            "format": request.format.rawValue,
        ]
        body["sourceLanguage"] = request.sourceLanguage
        body["engine"] = request.engine?.rawValue
        body["provider"] = request.provider
        return ImageTranslateResult(try await transport.object(transport.jsonRequest("trans/v1/device/image-translate", body: body)))
    }
}

public struct ImageTranslateRequest {
    /// image 返回译文烧进图里的 JPEG；json 只返回每块文字的坐标和译文，下行小得多，适合客户端自己绘制
    public enum Format: String { case image, json }

    public enum Engine: String {
        /// 大模型翻译，可结合原图纠正 OCR 错误
        case llm
        /// 机器翻译，更快
        case mt
    }

    /// 图片原始字节（JPEG / PNG）
    public var image: Data
    public var targetLanguage: String
    /// 不传由服务端自动识别
    public var sourceLanguage: String?
    public var format: Format
    /// 不传用服务端默认
    public var engine: Engine?
    public var provider: String?

    public init(image: Data, targetLanguage: String = "en-US", sourceLanguage: String? = nil,
                format: Format = .image, engine: Engine? = nil, provider: String? = nil) {
        self.image = image
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.format = format
        self.engine = engine
        self.provider = provider
    }
}

public struct ImageTranslateResult {
    public struct Block: Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let text: String
        /// 译文，翻译失败时等于原文
        public let translation: String
        /// OCR 置信度 0~1
        public let score: Double
    }

    /// format=image 时的译后图片（JPEG），否则 nil
    public let image: Data?
    public let contentType: String?
    /// format=json 时原图尺寸
    public let width: Int?
    public let height: Int?
    /// format=json 时每块文字；format=image 时为空
    public let blocks: [Block]
    /// 图里是否有被翻译的文字
    public let modified: Bool
    public let costMs: Int64

    init(_ data: [String: Any]) {
        image = data.str("image").flatMap { Data(base64Encoded: $0) }
        contentType = data.str("contentType")
        width = data.int("width")
        height = data.int("height")
        blocks = data.objects("blocks").map {
            Block(x: $0.int("x") ?? 0, y: $0.int("y") ?? 0, width: $0.int("width") ?? 0, height: $0.int("height") ?? 0,
                  text: $0["text"] as? String ?? "", translation: $0["translation"] as? String ?? "",
                  score: $0.double("score") ?? 0)
        }
        modified = data.bool("modified") ?? false
        costMs = data.int64("costMs") ?? 0
    }
}
