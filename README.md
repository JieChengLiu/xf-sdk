# XFusion 移动端 SDK

在 Android / iOS App 里接入 XFusion 的翻译、语音合成、语音识别 / 语音翻译、大模型对话等能力。

初始化一次 `XfClient` 后，所有接口都自动完成鉴权（设备签名或 API Key）、时钟校准和协议处理，你只需要调用方法、处理结果。

| | Android | iOS |
|---|---|---|
| 语言 | Kotlin（Java 可直接调用） | Swift，`async/await` |
| 最低系统 | Android 5.0（API 21） | iOS 13 |
| 依赖 | OkHttp 4（自动引入） | 只用系统框架 |

服务地址：REST `https://transcribe.azopenai.com`，WebSocket `wss://transcribe.azopenai.com`。

## 能力一览

| 能力 | 入口 |
|---|---|
| 设备注册 / 重置 | `DeviceRegistrar.register`、`client.device.reset` |
| 文本翻译 / 自动互译 | `client.translate.text`、`client.translate.mutual` |
| 语音合成（一次性） | `client.tts.synthesize` |
| 大模型对话（OpenAI 兼容，支持流式） | `client.chat.completions`、`client.chat.stream` |
| 拍照翻译 | `client.image.translate` |
| 长音频转写（含摘要） | `client.transcription.*` |
| 实时语音翻译 / 语音对话 | `client.voiceSession` |
| 按住说话 | `client.pushToTalkSession` |
| 只识别 / 只合成 / 只补全（流式） | `client.asrSession` / `ttsSession` / `llmSession` |
| 多模态 / 实时语音大模型 | `client.multimodalSession` / `voiceLiveSession` |
| 客户端工具（让大模型调用 App 本地能力） | `ClientTool` |

## 安装

### Android

`settings.gradle.kts`：

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://raw.githubusercontent.com/JieChengLiu/xf-sdk/main/android/maven/")
    }
}
```

`app/build.gradle.kts`：

```kotlin
dependencies {
    implementation("com.xfusion.sdk:xf-sdk-core:0.2.0")
}
```

`AndroidManifest.xml` 声明网络权限；用语音功能还需要录音权限（运行时申请）：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

SDK 没有用反射，开启 R8 / ProGuard 不需要额外的 keep 规则。

### iOS

Xcode → File → Add Package Dependencies，填：

```
https://github.com/JieChengLiu/xf-sdk
```

版本选 `0.2.0` 或 Up to Next Minor，添加 `XfCore` 到你的 Target。用语音功能需要在 Info.plist 加 `NSMicrophoneUsageDescription`。

## 快速开始

### 1. 获取设备凭证

我们会给你一个**产品 API Key**。App 首次启动时用它注册设备，拿到 `deviceId` 和 `deviceSecret`，保存在安全存储里（Android Keystore / iOS Keychain）。

注册是幂等的：同一个 `macId` 重复注册会拿回同一套凭证，凭证丢了重新注册即可。之前注册过的话把 `deviceId` 也传上，识别更准确。

```kotlin
// Android：execute() 是同步调用，不要在主线程执行
val reg = DeviceRegistrar("https://transcribe.azopenai.com")
    .register(productApiKey, macId)
    .execute()
secureStore.save(reg.deviceId, reg.deviceSecret)
```

```swift
// iOS
let reg = try await DeviceRegistrar(restBaseURL: URL(string: "https://transcribe.azopenai.com")!)
    .register(productApiKey: productApiKey, macId: macId)
try Keychain.save(reg.deviceId, reg.deviceSecret)
```

### 2. 创建 XfClient

全局创建一次并复用。`deviceSecret` 通过回调提供，SDK 每次签名时现取，不缓存、不写日志。

```kotlin
val client = XfClient.Builder()
    .restBaseUrl("https://transcribe.azopenai.com")
    .wsBaseUrl("wss://transcribe.azopenai.com")
    .device(deviceId, macId = macId) { secureStore.readSecret() }
    .callbackExecutor(ContextCompat.getMainExecutor(context))   // 回调切到主线程
    .build()
```

```swift
let client = XfClient(config: .init(
    restBaseURL: URL(string: "https://transcribe.azopenai.com")!,
    wsBaseURL: URL(string: "wss://transcribe.azopenai.com")!,
    credentials: DeviceCredentials(deviceId: deviceId, macId: macId) { try Keychain.readSecret() }
))
```

> **建议启动后先调一次任意 REST 接口**（比如一次翻译），再开语音会话。SDK 会用 REST 响应校准手机时钟；
> 手机时间偏差超过 5 分钟时，没校准过的语音会话握手会被拒绝（`SIGNATURE_INVALID`）。

### 另一种方式：API Key 接入

如果你开通的是公司级 **API Key**（`OAK-` 开头，按用量后付费），可以不注册设备，直接用 key 创建 `XfClient`，接口和用法完全一样：

```kotlin
val client = XfClient.Builder()
    .restBaseUrl("https://transcribe.azopenai.com")
    .wsBaseUrl("wss://transcribe.azopenai.com")
    .apiKey { myBackend.fetchXfApiKey() }   // 与 device(...) 二选一
    .build()
```

```swift
let client = XfClient(config: .init(
    restBaseURL: URL(string: "https://transcribe.azopenai.com")!,
    wsBaseURL: URL(string: "wss://transcribe.azopenai.com")!,
    apiKey: { try MyBackend.xfApiKey() }
))
```

> ⚠️ **API Key 是整个公司账户的凭证，没有额度上限，产生的用量全部计入你的账单。**
> 写进 App 安装包的 key 一定能被反编译拿到，拿到的人可以无限制地以你的名义调用。所以：
>
> - **不要把 key 写死在 App 里。** 回调里从你自己的服务端取（登录后下发、只放内存），SDK 每个请求都会调一次回调，你可以在里面缓存和轮换。
> - 面向大量终端用户分发的 App，优先用上面的**设备凭证**方式：每台设备一个 secret，泄露只影响一台，并且有额度控制。
> - 发现 key 泄露立即在控制台禁用或轮换；禁用后最多 5 分钟内全部断开。

API Key 方式的差异：

- 没有设备身份：`client.credentials` 为 null / nil，`client.device.reset` 不可用（直接报错，不会发出请求）。
- 没有跨会话的设备身份：语音会话里的用户记忆（`syncMemories`）只在当前这条连接内有效，每次新建会话需要重新同步；个人声音不可用。
- key 失效、被禁用或过期时报 `API_KEY_INVALID`；语音会话握手被拒同样报 `SIGNATURE_INVALID`（服务端握手失败不区分原因）。

## REST 接口

Android 每个方法返回 `XfCall<T>`：`execute()` 同步（不要在主线程调用），`enqueue(callback)` 异步，`cancel()` 取消。iOS 全部是 `async throws`。

```kotlin
// 文本翻译
client.translate.text("你好", "zh-Hans", "en").enqueue(object : XfCallback<TranslateResult> {
    override fun onSuccess(result: TranslateResult) { show(result.text) }
    override fun onError(error: XfException) { showError(error) }
})

// 自动互译：识别文本属于哪种语言，翻成另一种
client.translate.mutual("Bonjour", "zh-CN", "fr-FR").execute().text

// 语音合成，返回完整音频（默认 mp3）
val audio = client.tts.synthesize(TtsRequest("你好", "zh-CN", "zh-CN-XiaoxiaoNeural")).execute().audio

// 拍照翻译
client.image.translate(ImageTranslateRequest(jpeg, "en-US", format = ImageTranslateRequest.Format.JSON)).execute().blocks

// 大模型流式对话：请求体是 OpenAI 格式
client.chat.stream(ChatApi.request("gpt-5.4-nano", listOf(ChatMessage.user("你好"))), object : ChatStreamListener {
    override fun onDelta(text: String) { append(text) }
    override fun onComplete() {}
    override fun onError(error: XfException) {}
})

// 长音频转写：大文件直传，轮询状态后取结果
val task = client.transcription.uploadAndCreate(TranscriptionRequest("会议", "zh-CN", "m4a", needSummary = true), file)
while (!client.transcription.status(task.taskId).execute().isCompleted) Thread.sleep(5000)
val result = client.transcription.result(task.taskId).execute()
```

```swift
let text = try await client.translate.text("你好", from: "zh-Hans", to: "en").text
let mutual = try await client.translate.mutual("Bonjour", languageA: "zh-CN", languageB: "fr-FR").text
let audio = try await client.tts.synthesize(TTSRequest(text: "你好", languageCode: "zh-CN", voiceName: "zh-CN-XiaoxiaoNeural")).audio

var answer = ""
for try await chunk in client.chat.stream(ChatAPI.request(model: "gpt-5.4-nano", messages: [.user("你好")])) {
    if let delta = chunk.delta { answer += delta }
}
```

## 语音会话

所有语音能力用法相同：选一个 `StreamConfig` 预设 → 创建会话 → `connect()` → 发音频、收事件。

`connect()` 之后可以立刻 `start()` 和发送音频，SDK 会在服务端就绪后按顺序发出，不用等回调。

### 实时语音翻译

```kotlin
val config = StreamConfig.voiceTranslation("zh-CN", "en-US")
    .tts("en-US-JennyNeural")          // 需要播报译文时加上
val session = client.voiceSession(config, object : StreamListener {
    override fun onEvent(event: StreamEvent) {
        when (event) {
            is StreamEvent.AsrPartial -> showPartial(event.text)           // 识别中间结果
            is StreamEvent.Translation -> showResult(event.original, event.translated)
            is StreamEvent.TtsAudio -> player.enqueue(event.audio)        // 播报音频分片
            StreamEvent.AudioInterrupt -> player.flush()                  // 立即停止播放
            else -> Unit
        }
    }
    override fun onFailure(error: XfException) { /* 会话已不可用，需要新建 */ }
})
session.connect()
session.start()                         // 开始收音
recorder.onPcm { session.sendPcm(it) }  // 持续发送麦克风音频
// ……
session.stop()                          // 结束收音，服务端会把最后一句处理完
session.close()                         // 不再使用时关闭
```

```swift
var config = StreamConfig.voiceTranslation(from: "zh-CN", to: "en-US")
config.tts(voiceName: "en-US-JennyNeural")
let session = client.voiceSession(config)   // 由 App 持有强引用，被释放时连接会断开
session.connect()
session.start()
recorder.onPCM { session.sendPCM($0) }

for try await event in session.events {
    switch event {
    case .asrPartial(let text, _): showPartial(text)
    case .translation(let original, let translated, _, _): showResult(original, translated)
    case .ttsAudio(_, _, let audio): player.enqueue(audio)
    case .audioInterrupt: player.flush()
    default: break
    }
}
// events 正常结束表示会话关闭；抛出错误表示握手失败或连接异常
```

**两种收音方式：**
- **连续说话**：`start()` 后一直发音频，服务端按停顿自动断句，每句话依次返回识别结果和译文，直到 `stop()`。外放播报时建议用耳机或开启回声消除，避免播报被麦克风录回去。
- **按住说话**：按下时 `start()`，松开时 `stop()`；也可以用 `pushToTalkSession`。

### 音频格式

- **上行**：默认 PCM，16kHz / 16bit / 单声道 / 小端，建议每次发 20～100ms（20ms = 640 字节）。
  也可以发 Opus：config 设 `audioFormat(StreamConfig.AudioFormat.OPUS)`（iOS：`config.audioFormat = .opus`），每个 Opus 包调一次 `sendOpus`。
- **下行播报**：默认 mp3 分片。需要边收边播时，在 config 里设 `outputFormat("pcm")`（iOS：`config.outputFormat = "pcm"`），
  收到的是 16kHz / 16bit / 单声道 PCM，可以直接写进 AudioTrack / AVAudioPlayerNode。

SDK 不包含录音和播放，由 App 用系统 API 实现（Android `AudioRecord` / `AudioTrack`，iOS `AVAudioEngine`）。

### 会话类型

| 预设 | 会话 | 额外方法 |
|---|---|---|
| `voiceTranslation` / `voiceChat` | `voiceSession` | `interrupt`、`sendText`、`sendImage`、`switchLanguage`、`syncMemories` |
| `pushToTalk` | `pushToTalkSession` | `interrupt`、`sendText`、`sendImage` |
| `asrOnly` | `asrSession` | — |
| `ttsOnly` | `ttsSession` | `synthesize(text, voiceName, voiceSpeed, outputFormat)` |
| `llmOnly` | `llmSession` | `chat(messages)` / `chat(text)` |
| `multimodal` | `multimodalSession` | `interrupt`、`sendImage` |
| `voiceLive` | `voiceLiveSession` | `interrupt`、`syncMemories` |

带音频的会话都有 `start`、`stop`、`sendPcm`、`sendOpus`；所有会话都有 `stop`、`close`。

### 事件

| 事件 | 含义 |
|---|---|
| `Ready` / `Started` / `Stopped(reason)` | 会话就绪 / 开始收音 / 本轮结束 |
| `AsrPartial` / `AsrFinal` | 识别中间结果 / 一句话的最终结果（可带说话人、逐词时间戳） |
| `Translation` | 一句话的原文和译文 |
| `LlmDelta` / `LlmDone` | 大模型回复增量 / 本轮回复结束 |
| `AssistantTranscript(text, isFinal)` | 实时语音大模型的回复文字 |
| `TtsAudio` | 播报音频分片 |
| `TtsComplete` / `TtsEnd` | 一段回复的音频发完 / 本轮全部音频发完 |
| `AudioInterrupt` | 立即停止播放并清空队列（例如用户插话） |
| `UserSpeech(speaking)` | 检测到用户开始 / 停止说话 |
| `ToolCalls` | 大模型调用了客户端工具（已由 SDK 自动执行，仅供展示） |
| `ServerError` | 会话内的错误，连接不一定断开 |

iOS 的事件名是对应的小写形式（`.ready`、`.asrPartial` ……）。

## 客户端工具

让大模型在对话中调用 App 的本地能力（调音量、放音乐、发消息……）。在 config 里注册工具，SDK 会自动上报工具列表、执行你的 handler 并回传结果：

```kotlin
val volumeUp = ClientTool(
    name = "volume_up",
    description = "用户想把声音调大时调用",
    parameters = JSONObject("""{"type":"object","properties":{"delta":{"type":"integer"}},"required":[]}"""),
) { call, reply ->
    val delta = call.arguments.optInt("delta", 10)
    reply.success(mapOf("success" to true, "volume" to audio.raise(delta)))
}

client.voiceSession(StreamConfig.voiceChat("zh-CN").tts("zh-CN-XiaoxiaoNeural").tool(volumeUp), listener)
```

```swift
var config = StreamConfig.voiceChat(language: "zh-CN")
config.tts(voiceName: "zh-CN-XiaoxiaoNeural")
config.tools = [ClientTool(name: "volume_up", description: "用户想把声音调大时调用",
                           parameters: ["type": "object", "properties": ["delta": ["type": "integer"]], "required": []]) { call in
    .success(["success": true, "volume": audio.raise(call.arguments["delta"] as? Int ?? 10)])
}]
```

- 一个会话最多 8 个工具。
- 收到调用后默认 **2 秒内**必须回复，超时服务端会断开连接；执行慢的工具用 `toolTimeoutMs` 调长。
- `required` 里的参数模型没填时，服务端会让模型先追问用户，这一轮不会调用工具。
  可撤销的动作少设必填，不可撤销的动作（发消息、付款）保留必填并在执行前让用户确认。

工具怎么定义、结果怎么回，详见 [docs/client-tools.md](docs/client-tools.md)。

## 错误处理

所有错误都是 `XfException`（Android）/ `XfError`（iOS），按 `kind` 处理（iOS 的 kind 是小驼峰，如 `apiKeyInvalid`）：

| kind | 含义 | 建议处理 |
|---|---|---|
| `CLOCK_SKEW` | 手机时间偏差过大 | SDK 已自动校准重试一次；仍失败时提示用户检查系统时间 |
| `NONCE_REPLAY` | 请求被判定为重放 | 重试 |
| `SIGNATURE_INVALID` | 签名不对 / 握手被拒 | 检查 deviceId、secret 是否匹配；语音会话见上文"先调一次 REST" |
| `DEVICE_NOT_FOUND` / `MAC_MISMATCH` | 设备不存在 / MAC 不匹配 | 重新注册设备 |
| `DEVICE_INACTIVE` / `DEVICE_EXPIRED` / `PRODUCT_DISABLED` | 设备停用 / 过期 / 产品停用 | 联系我们 |
| `QUOTA_EXCEEDED` | 额度用完 | 提示用户或联系我们充值 |
| `API_KEY_INVALID` | API Key 无效 / 已禁用 / 已过期（仅 API Key 方式） | 从你的服务端重新获取 key；仍失败联系我们 |
| `INVALID_REQUEST` | 参数错误 | 检查参数 |
| `SERVER_ERROR` | 服务端异常 | 稍后重试 |
| `NETWORK` | 网络错误 | 检查网络后重试 |
| `PROTOCOL` | 响应格式异常、会话超时未就绪、流式回复被截断等 | 重试；流式对话已收到的文字会保留 |
| `CANCELED` | 调用被取消 | 无需处理 |

语音会话失败（`onFailure` / `events` 抛错）后不可再用，需要新建会话。

## 资源释放

- 会话不用时调用 `close()`。
- Android 退出时先关闭所有会话，再调用 `client.shutdown()`。如果通过 `okHttpClient(...)` 传入了 App 自己的 OkHttpClient，SDK 不会关闭它。

## 示例工程

SDK 附带最小示例 App，演示注册、翻译、合成、流式对话、按住说话和连续语音翻译，包括录音和边收边播的完整代码：

GitHub 仓库 https://github.com/JieChengLiu/xf-sdk 里：

- Android：`android/demo`（Android Studio 打开即可，SDK 从上面的 Maven 地址下载）
- iOS：`Demo`（按 `Demo/README.md` 用 XcodeGen 生成工程）

## 版本

当前版本 `0.2.0`。`0.x` 期间小版本可能有不兼容改动，升级前请查看更新说明。

### 0.2.0

- 新增 API Key 接入（见「另一种方式：API Key 接入」）和错误类型 `API_KEY_INVALID` / `apiKeyInvalid`。
- **不兼容**：`client.credentials` 改为可空（API Key 方式下为 null / nil）。
- **不兼容（iOS）**：`XfClient.Config` 的 `credentials` 属性换成 `auth: XfAuth`；原来的 `init(restBaseURL:wsBaseURL:credentials:)` 照常可用。
- 修复（Android）：secret / key 回调抛异常时不再导致 App 崩溃，改为报 `NETWORK`。
