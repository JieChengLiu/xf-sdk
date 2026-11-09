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
| 双屏互译（一台设备两块屏幕） | `client.dualScreenSession` |
| 按住说话 | `client.pushToTalkSession` |
| 只识别 / 只合成 / 只补全（流式） | `client.asrSession` / `ttsSession` / `llmSession` |
| 多模态 / 实时语音大模型 | `client.multimodalSession` / `voiceLiveSession` |
| 客户端工具（让大模型调用 App 本地能力） | `ClientTool` |
| 端侧降噪（16kHz PCM） | `NoiseSuppressor`（Android 在 `com.xfusion.sdk.audio` 包） |

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
    implementation("com.xfusion.sdk:xf-sdk-core:0.6.4")
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

版本选 `0.6.4` 或 Up to Next Minor，添加 `XfCore` 到你的 Target。用语音功能需要在 Info.plist 加 `NSMicrophoneUsageDescription`。

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

// 左右各录一人的通话录音：两个声道都转，按声道区分说话人（不能同时开说话人分离）
val call = TranscriptionRequest("通话", "zh-CN", "mp3", channels = listOf(0, 1))
```

`channels`（iOS 同名）用来选择要转录的声道，`0` 是左声道，`1` 是右声道。**不传默认只转左声道**，避免左右内容相同的立体声把同一段话转出两遍；单声道文件不受影响。人声只在右声道时传 `listOf(1)`；左右各录一人的通话录音传 `listOf(0, 1)`，此时不能开 `enableSpeakerDiarization`（说话人分离只支持单声道，同时传会被拒绝），说话人按声道区分。

```kotlin
// 每个分段带译文：segments[i] 同时有 speaker、startTime/endTime、text（原文）、translatedText（译文）
val bilingual = TranscriptionRequest("会议", "zh-CN", "m4a", enableSpeakerDiarization = true,
    translateLanguage = "en-US", translateSegments = true)

// 自定义总结模板 + 指定总结模型，结果在 summary 的 type = "custom" 一项里
val template = JSONObject("""{"sections":[{"title":"客户需求","format":"bullet"},{"title":"下一步计划","instruction":"写明负责人和时间"}]}""")
val custom = TranscriptionRequest("拜访", "zh-CN", "m4a", summaryTemplate = template, summaryModel = "gpt-6-luna")

// 逐词时间戳：segments[i].words 是 [{text, startTime, endTime}]，用于播放时逐词高亮、点词跳播
val karaoke = TranscriptionRequest("课堂", "zh-CN", "m4a", wordTimestamps = true)
result.segments.forEach { seg -> seg.words?.forEach { w -> println("${w.startTime}-${w.endTime} ${w.text}") } }
```

`wordTimestamps`（iOS 同名，SDK 0.6.1 起支持）默认不开，只能在建任务时决定，没开的任务不能事后补取词级时间：JSON 不包含 `words`，SDK 中为 null / nil。`words[].startTime / endTime` 单位为秒，相对整段音频开头，保留两位小数；时间缺失时可为 null。词跟 `text` 一致，带标点、数字写成阿拉伯数字：中文通常按单字切分、标点附在前一个字上（如 `好，`），直接拼接就是原文；英文等有空格的语言按词切分，用空格连接。只有原文有词级时间，`translatedText` 没有。转写完成回调的 `result.segments[].words` 与查询结果一致。长录音词数多，开启后结果体会明显增大，不需要就保持关闭。

```kotlin
// 文字整理：转写完成后由大模型按上下文整理断句、重复和明显错字，原始 text / segments 不变
val refined = TranscriptionRequest("访谈", "zh-CN", "m4a", refineTranscript = true)
client.transcription.result(taskId).execute().refinement?.let { r ->
    if (r.status == "completed") show(r.text)   // r.segments[i].sourceSegmentIndices 指向原始分段
}

// 自动选总结模板：模型从后台启用的模板里挑一个最匹配的
val auto = TranscriptionRequest("会议", "zh-CN", "m4a", needSummary = true, autoSelectTemplate = true)
val summary = client.transcription.summary(taskId).execute()
summary.title              // 智能标题，语种与总结一致
summary.templateSelection  // 选中了哪个模板、匹配分数

// 重新生成总结：不重新转写，可换类型 / 模板 / 模型 / 语种，不传的沿用原设置；异步，之后继续轮询 summary
client.transcription.regenerateSummary(taskId, SummaryRegenerateRequest(summaryTypes = listOf("meeting"))).execute()

// 针对录音内容问答：服务端按 taskId 取转写原文作为上下文，SSE 流式返回
val history = listOf(ChatMessage.user("会议定了哪些待办？"))
client.transcription.chat(taskId, history, prompt = "用要点列出，注明负责人", listener = object : ChatStreamListener {
    override fun onDelta(text: String) { append(text) }
    override fun onComplete() {}
    override fun onError(error: XfException) { showError(error) }
})
```

`chat` 不保存对话历史：多轮时把之前的 `user` / `assistant` 消息按顺序全部带上，最后一条必须是 `user`；只接受这两种 role（最多 40 条），回答风格、角色、格式等要求放 `prompt`。回答以录音内容为依据，录音里没有的会说明未提及；模型由服务端决定。任务需已转写完成。`refineTranscript` 的整理和 `regenerateSummary` 都是异步的，额外产生模型用量。

`translateSegments` 需要同时传 `translateLanguage`，分段译文在转写完成后异步生成，刚完成时可能还没有，需要继续轮询。`summaryTemplate` 的字段（`sections[].title / instruction / maxLength / format`、顶层 `maxLength`）和限制见服务端接口文档「长音频转写 · 自定义总结模板」；iOS 传 `[String: Any]`。`summaryModel` 只能是 `gpt-5.4-nano` 或 `gpt-6-luna`，其他值创建任务会失败。

```swift
let text = try await client.translate.text("你好", from: "zh-Hans", to: "en").text
let mutual = try await client.translate.mutual("Bonjour", languageA: "zh-CN", languageB: "fr-FR").text
let audio = try await client.tts.synthesize(TTSRequest(text: "你好", languageCode: "zh-CN", voiceName: "zh-CN-XiaoxiaoNeural")).audio

var answer = ""
for try await chunk in client.chat.stream(ChatAPI.request(model: "gpt-5.4-nano", messages: [.user("你好")])) {
    if let delta = chunk.delta { answer += delta }
}

// 长音频：重新生成总结、针对录音内容问答
_ = try await client.transcription.regenerateSummary(taskId, SummaryRegenerateRequest(summaryTypes: ["meeting"]))
var reply = ""
for try await chunk in client.transcription.chat(taskId, messages: [.user("会议定了哪些待办？")], prompt: "用要点列出") {
    if let delta = chunk.delta { reply += delta }
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

### 双屏互译

一台设备、两块屏幕的面对面互译：A、B 两侧走一条连接，每侧的翻译方向固定。连接后两侧自动开始收音，没有按键，也不用调 `start()`。

```kotlin
val config = DualScreenConfig("zh-CN", "en-US")
    .tts(voiceA = "zh-CN-XiaoxiaoNeural", voiceB = "en-US-JennyNeural")   // A、B 两侧听到的音色，可省略
    .outputFormat("pcm")
val session = client.dualScreenSession(config, object : StreamListener {
    override fun onEvent(event: StreamEvent) {
        if (event !is StreamEvent.DualScreen) return
        when (val inner = event.event) {
            is StreamEvent.AsrFinal -> screen(event.side).showOriginal(event.utteranceId, inner.text)
            is StreamEvent.Translation -> {
                screen(event.side).showOriginal(event.utteranceId, inner.original)
                screen(event.targetSide).showTranslation(event.utteranceId, inner.translated)
            }
            is StreamEvent.TtsAudio -> speaker(event.targetSide).enqueue(inner.audio)
            StreamEvent.AudioInterrupt -> speaker(event.targetSide).flush()
            else -> Unit
        }
    }
    override fun onFailure(error: XfException) { /* 会话已不可用，需要新建 */ }
})
session.connect()
recorderA.onPcm { session.sendPcm(DualScreenSide.A, it) }   // 两侧持续发送，包括没人说话的时候
recorderB.onPcm { session.sendPcm(DualScreenSide.B, it) }
```

```swift
var config = DualScreenConfig(languageA: "zh-CN", languageB: "en-US")
config.tts(voiceA: "zh-CN-XiaoxiaoNeural", voiceB: "en-US-JennyNeural")
config.outputFormat = "pcm"
let session = client.dualScreenSession(config)   // 由 App 持有强引用，被释放时连接会断开
session.connect()
recorderA.onPCM { session.sendPCM(side: .a, $0) }
recorderB.onPCM { session.sendPCM(side: .b, $0) }

for try await event in session.events {
    guard case .dualScreen(let side, let targetSide, let utteranceId, let inner) = event else { continue }
    switch inner {
    case .asrFinal(let text, _, _, _): screen(side).showOriginal(utteranceId, text)
    case .translation(let original, let translated, _, _):
        screen(side).showOriginal(utteranceId, original)
        screen(targetSide).showTranslation(utteranceId, translated)
    case .ttsAudio(_, _, let audio): speaker(targetSide).enqueue(audio)
    case .audioInterrupt: speaker(targetSide).flush()
    default: break
    }
}
```

- **事件归属**：属于某一侧的事件都包在 `DualScreen`（iOS：`.dualScreen`）里。`side` 是说话的一侧，`targetSide` 是译文显示和播放的一侧；同一句的原文、译文、音频 `utteranceId` 相同。`Ready` 和不带 side 的错误不包装。
- **静音**：某一侧静音超过约 55 秒（可用 `ext("noSpeechTimeoutSeconds", 秒数)` 调整）时，服务端会在内部重置这一侧的识别并自动恢复收音，不会下发 `Stopped` / `Started`，持续发音频即可。早于这一改动的服务端会下发 `Stopped(no_speech_timeout)` 和随后的 `Started`，同样不需要处理。
- **暂停**：屏幕熄灭等场景可以调 `stop(side)` 暂停，`start(side)` 恢复；不带 side 表示两侧。`interrupt(side)` 中断这一侧说话产生的译文播报。
- **切换语言**：新建会话。
- **回声和串音必须处理**：服务端不做回声消除，也不判断是谁在说话。麦克风拾到扬声器的译文会再被翻译一次，形成循环，所以要做回声消除；A 侧的话被 B 侧麦克风拾到会被当成 B 侧语言识别，所以要定向拾音或足够的物理隔离。
- **用量**：两侧常开相当于两路识别，时长和费用按两路计算。

### 音频格式

- **上行**：默认 PCM，16kHz / 16bit / 单声道 / 小端，建议每次发 20～100ms（20ms = 640 字节）。
  也可以发 Opus：config 设 `audioFormat(StreamConfig.AudioFormat.OPUS)`（iOS：`config.audioFormat = .opus`），每个 Opus 包调一次 `sendOpus`。
- **下行播报**：默认 mp3 分片。需要边收边播时，在 config 里设 `outputFormat("pcm")`（iOS：`config.outputFormat = "pcm"`），
  收到的是 16kHz / 16bit / 单声道 PCM，可以直接写进 AudioTrack / AVAudioPlayerNode。
  PCM 每秒约 32KB，网络慢时播报音频会把后面的识别、译文消息挤在后面；带宽紧张时用压缩格式：
  - `outputFormat("ogg")`：标准 Ogg Opus 流，每秒约 8KB，用常规 Ogg Opus 解码器即可。
  - `outputFormat("opus")`：Opus 裸流，每秒约 4KB。**一个音频分片里是多个 80 字节的 Opus 包首尾相接，没有长度前缀**，
    整块当一个包解码只会得到前 20ms。用 `RawOpusPacketSplitter` 切包后逐个解码（16kHz / 单声道），每路 TTS 流各用一个，
    双屏 A、B 各一个。
    - `framesPerPacket` 默认 1：每包 20ms，解码一次得到 320 个采样。
    - 解码调用有固定开销（例如通过 JNI 调 libopus）时，设 `framesPerPacket = 4`：SDK 把每 4 帧按 Opus 标准组装成一个 80ms 的包，
      解码一次得到 1280 个采样，调用次数降到 1/4。只重排帧不重新编码，声音与逐包解码完全一致。最大 6（120ms）。
      **解码输出缓冲至少要 `framesPerPacket × 320` 个采样**（4 帧 = 1280），按 320 分配会解码失败；不确定时按 Opus 上限 5760 分配。
    - 收到 `TtsComplete` 时调 `flush()` 取出句尾不足一组的帧；收到 `AudioInterrupt` 时调 `reset()`。
    - **Android 构造函数的第一个参数是 `packetBytes`，不是 `framesPerPacket`**。Kotlin 要写参数名；
      Java 用 `RawOpusPacketSplitter.withFramesPerPacket(4)`。`new RawOpusPacketSplitter(4)` 会切出 4 字节碎包，
      播放会乱、听起来像加速，从 0.6.3 起这样写会直接抛 `IllegalArgumentException`。
    - 解码器和播放器都用 16000Hz、单声道；采样率或声道对不上同样会变快。自查方法：一句话解出的采样数应等于 帧数 × 320。
    - 完整参考实现（Concentus 纯 Java 解码 → AudioTrack）：demo 里的 `OpusTtsDecoder.kt`，勾选「播报用 Opus 下发」即可试听。

    ```kotlin
    val splitter = RawOpusPacketSplitter(framesPerPacket = 4)
    is StreamEvent.TtsAudio -> splitter.feed(event.audio).forEach { packet -> player.playOpusPacket(packet) }
    is StreamEvent.TtsComplete -> splitter.flush().forEach { packet -> player.playOpusPacket(packet) }
    is StreamEvent.AudioInterrupt -> { splitter.reset(); player.flush() }
    ```

    ```java
    RawOpusPacketSplitter splitter = RawOpusPacketSplitter.withFramesPerPacket(4); // 不要写 new RawOpusPacketSplitter(4)
    short[] pcm = new short[5760];                                               // 按 Opus 上限分配
    int samples = decoder.decode(packet, 0, packet.length, pcm, 0, pcm.length, false);
    ```

    ```swift
    let splitter = RawOpusPacketSplitter(framesPerPacket: 4)
    case .ttsAudio(_, _, let audio): splitter.feed(audio).forEach { player.playOpusPacket($0) }
    case .ttsComplete: splitter.flush().forEach { player.playOpusPacket($0) }
    case .audioInterrupt: splitter.reset(); player.flush()
    ```

SDK 不包含录音和播放，由 App 用系统 API 实现（Android `AudioRecord` / `AudioTrack`，iOS `AVAudioEngine`）。

### 端侧降噪（可选）

`NoiseSuppressor` 对 16kHz / 16bit / 单声道 PCM 做降噪，纯 Kotlin / Swift 实现，不依赖模型和原生库。
可以用在发给 SDK 之前，也可以单独用于 App 自己的音频处理（本地 VAD、录音存档等）。

```kotlin
val suppressor = NoiseSuppressor()               // 一路音频一个实例
recorder.onPcm { pcm -> session.sendPcm(suppressor.process(pcm)) }
```

```swift
let suppressor = NoiseSuppressor()
recorder.onPCM { session.sendPCM(suppressor.process($0)) }
```

- **输入输出**：返回与输入等长的数据，样本或小端字节都可以（`ShortArray` / `ByteArray`，`[Int16]` / `Data`）。
  每次传多长都行，建议 20ms（320 个样本）。
- **延迟**：输出固定比输入晚 32ms（`LATENCY_SAMPLES` / `latencySamples` = 512 个样本），开头是 32ms 静音。
- **强度**：`NoiseSuppressor(maxAttenuationDb = 15.0)`（iOS：`NoiseSuppressor(maxAttenuationDb: 15)`），
  越大降噪越狠、越容易伤到语音，建议 10～25；0 表示不降噪。
- **适用场景**：风扇、空调、电流声、车内等稳态噪声；旁人说话、键盘、音乐这类非稳态噪声压不干净。
  噪声估计需要约 1 秒适应，刚开始的一小段效果偏弱。
- **线程与复用**：实例不是线程安全的，一个实例只处理一路连续音频；开始一段不相关的音频前调用 `reset()`。
- 服务端识别本身也会降噪，只为了识别效果不需要在端侧再开。

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

双屏互译单独用 `DualScreenConfig` 和 `dualScreenSession`，发音频和控制方法都要指定 side，见「双屏互译」。

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
| `RATE_LIMITED` | 服务端暂时限流（HTTP 429），请求没有被处理 | SDK 已按 `Retry-After` 自动重试最多 2 次；仍失败时等 `retryAfterSeconds` 秒再调。长音频转写里**不是任务失败**，继续用原 taskId 查询，不要重新建任务 |
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

当前版本 `0.6.4`。`0.x` 期间小版本可能有不兼容改动，升级前请查看更新说明。

### 0.6.4

- 长音频新增 `transcription.chat(taskId, messages, prompt)`（Android / iOS）：按任务的转写原文做多轮问答，SSE 流式返回，事件同 `chat.stream`。
- 新增 `transcription.regenerateSummary(taskId, SummaryRegenerateRequest)`：不重新转写，换类型 / 模板 / 模型 / 语种重出总结。
- `TranscriptionRequest` 新增可选的 `refineTranscript`（文字整理，结果在 `TranscriptionResult.refinement`）和 `autoSelectTemplate`（自动选总结模板）。
- `TranscriptionSummary` 新增 `title` / `translatedTitle`（智能标题）和 `templateSelection`（自动选模板的结果）。
- `StreamConfig` 的构造函数改为公开：除了用预设，也可以 `StreamConfig()` 从空配置自己填字段。
- 文档更正：`channels` 不传时服务端默认只转左声道（此前文档写的是两个声道都转）；左右各录一人的通话录音需传 `[0, 1]`，且不能同时开说话人分离。
- 都是新增的可选字段和方法，现有调用不用改。

### 0.6.3

- Android `RawOpusPacketSplitter` 防误用：构造函数第一个参数是 `packetBytes`，`new RawOpusPacketSplitter(4)`（本意每包 4 帧）以前会切成 4 字节碎包、播放错乱像加速，现在 `packetBytes < 8` 直接抛 `IllegalArgumentException` 并提示正确写法。
- 新增 `RawOpusPacketSplitter.withFramesPerPacket(n)`，供 Java 指定每包帧数。
- Android demo 新增 Opus 播报（`OpusTtsDecoder.kt`：切包 → Concentus 解码 → AudioTrack），勾选「播报用 Opus 下发」即可试听，日志会打出每句的解码时长用于核对。
- iOS 无改动（Swift 必须写参数名，不存在这个问题）。

### 0.6.2

- 新增 `RawOpusPacketSplitter`（Android / iOS 同名）：把 `outputFormat = "opus"` 的 TTS 裸流切成 Opus 包，用于逐包解码、边收边播。分片边界不是 80 的整数倍时会自动跨分片拼接。
- `framesPerPacket` 可把多帧组装成一包（如 4 帧 = 80ms），减少解码调用次数；配合 `flush()` 取出句尾余数。
- 纯新增工具类，现有事件和接口不变。

### 0.6.1

- `TranscriptionRequest` 新增可选的 `wordTimestamps`：开启后转写结果每个分段多一个 `words`（`TranscriptionResult.Segment.words`，元素为 `Word(text, startTime, endTime)`），用于逐词高亮、点词跳播。
- 新增的可选字段，不传时行为不变。

### 0.6.0

- `TranscriptionRequest` 新增可选的 `translateSegments`：配合 `translateLanguage`，转写结果的每个分段多一个 `translatedText`（`TranscriptionResult.Segment.translatedText`）。
- `TranscriptionRequest` 新增可选的 `summaryTemplate`（自定义总结模板，生成 `type=custom` 的总结）和 `summaryModel`（`gpt-5.4-nano` / `gpt-6-luna`）。
- 均为新增的可选字段，不传时行为不变。

### 0.5.0

- 服务端限流（HTTP 429）时，按 `Retry-After` 自动等待并重发，最多 2 次，单次最多等 10 秒；仍失败时抛 `RATE_LIMITED` / `.rateLimited`，并带上 `retryAfterSeconds`。主要影响长音频转写的状态和结果查询。
- Android 的 `XfCall.cancel()` 也会取消正在等待中的自动重发。
- **不兼容**：错误类型新增 `RATE_LIMITED`（iOS 为 `.rateLimited`）。Kotlin 里没写 `else` 的 `when` 表达式、Swift 里没写 `default` 的 `switch` 需要补上。

### 0.4.0

- 新增双屏互译 `dualScreenSession`（见「双屏互译」）。
- **不兼容（iOS）**：`StreamEvent` 新增 `.dualScreen`，没写 `default` 的 `switch` 需要补上。

### 0.3.1

- `TranscriptionRequest` 新增可选的 `channels`，用来选择长音频转写的声道。

### 0.3.0

- 新增端侧降噪 `NoiseSuppressor`（见「端侧降噪（可选）」），纯 Kotlin / Swift 实现，不增加依赖。

### 0.2.0

- 新增 API Key 接入（见「另一种方式：API Key 接入」）和错误类型 `API_KEY_INVALID` / `apiKeyInvalid`。
- **不兼容**：`client.credentials` 改为可空（API Key 方式下为 null / nil）。
- **不兼容（iOS）**：`XfClient.Config` 的 `credentials` 属性换成 `auth: XfAuth`；原来的 `init(restBaseURL:wsBaseURL:credentials:)` 照常可用。
- 修复（Android）：secret / key 回调抛异常时不再导致 App 崩溃，改为报 `NETWORK`。
