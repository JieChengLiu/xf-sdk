// swift-tools-version:5.7
import PackageDescription

// XfCore：签名入口 + REST + 语音 WebSocket 协议层，只依赖系统框架（Foundation、CryptoKit）。
// 后续的音频层（录音 / Opus / 播放）作为独立 product XfAudio 加在这里。
let package = Package(
    name: "XfSDK",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "XfCore", targets: ["XfCore"]),
    ],
    targets: [
        .target(name: "XfCore"),
        .testTarget(name: "XfCoreTests", dependencies: ["XfCore"]),
    ]
)
