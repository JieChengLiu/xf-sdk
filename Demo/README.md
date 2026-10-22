# iOS 测试 App

SDK 联调用的最小 App（SwiftUI，iOS 15+），功能和 Android 示例（`android/demo`）一致：

| 区域 | 测什么 | 对应 SDK |
|---|---|---|
| 注册设备 | 用产品 API Key + macId 拿 deviceId / secret | `DeviceRegistrar.register` |
| 翻译 | zh-Hans → en | `client.translate.text` |
| 合成播放 | 一次性 TTS，mp3 用 AVAudioPlayer 播 | `client.tts.synthesize` |
| Chat 流式 | SSE 增量显示 | `client.chat.stream` |
| 按住说话 | 语音翻译 + 播报，按下 `start`、松开 `stop` | `client.voiceSession` |

默认连 `https://transcribe.azopenai.com` / `wss://transcribe.azopenai.com`，界面上可以改。

## 运行

需要 macOS + Xcode 15 或更新版本。

1. 先确认 SDK 本身能编译、单测能过（在 `Package.swift` 所在的目录执行）：
   ```bash
   swift test
   ```
2. 生成 Xcode 工程（工程文件不进版本库，由 `project.yml` 生成）：
   ```bash
   brew install xcodegen
   cd Demo && xcodegen
   open XfDemo.xcodeproj
   ```
3. 选 Target `XfDemo` → Signing & Capabilities → Team 选自己的 Apple ID（免费账号即可）。
   报 Bundle ID 已被占用就把 `com.xfusion.sdk.demo` 改成别的。
4. 选模拟器或连接的 iPhone，Run。真机第一次运行要在 设置 → 通用 → VPN与设备管理 里信任开发者。
5. 填 deviceId / macId / deviceSecret 点「保存并初始化」；没有凭证就填产品 API Key + macId 点「注册设备」。
6. 建议先点一次「翻译」，让 SDK 用 REST 响应校准时钟，再测语音。

模拟器用 Mac 的麦克风和扬声器，语音也能测。

## 说明

- 凭证明文存在 UserDefaults，仅供测试。
- 语音会话 config 设了 `outputFormat = "pcm"`，`ttsAudio` 是 16kHz / 16bit / 单声道 PCM，`PcmPlayer` 用 AVAudioPlayerNode 边收边播；
  收到 `audioInterrupt` 立即清空。
- `PcmRecorder` 用 AVAudioEngine 采集，AVAudioConverter 重采样到 16kHz 后喂 `sendPCM`。
- App 持有 `VoiceSession` 的强引用；会话对象被释放时连接会断开。
