# Android 测试 App

SDK 联调用的最小 App，只用系统控件（不依赖 androidx），minSdk 21。

| 区域 | 测什么 | 对应 SDK |
|---|---|---|
| 注册设备 | 用产品 API Key + macId 拿 deviceId / secret | `DeviceRegistrar.register` |
| 翻译 | zh-Hans → en | `client.translate.text` |
| 合成播放 | 一次性 TTS，mp3 用 MediaPlayer 播 | `client.tts.synthesize` |
| Chat 流式 | SSE 增量显示 | `client.chat.stream` |
| 按住说话 | 语音翻译 + 播报，按下 `start`、松开 `stop` | `client.voiceSession` |

默认连 `https://transcribe.azopenai.com` / `wss://transcribe.azopenai.com`，界面上可以改。

## 运行

1. Android Studio → Open → 选这个 demo 目录，等 Gradle 同步完（首次会下载 Gradle 8.14.3 和 AGP 8.11.1）。
   SDK 从 `settings.gradle.kts` 里的 Maven 地址下载；本地联调 SDK 时，在 `xf-sdk-core` 下 `mvn install -DskipTests` 后会优先用本地版本。
2. 也可以不用 IDE：在 demo 目录执行 `gradlew assembleDebug`，再 `adb install app/build/outputs/apk/debug/app-debug.apk`。
3. 选模拟器或 USB 连接的真机，Run。
4. 填 deviceId / macId / deviceSecret 点「保存并初始化」；没有凭证就填产品 API Key + macId 点「注册设备」。
5. 建议先点一次「翻译」，让 SDK 用 REST 响应校准时钟，再测语音。

## 模拟器测语音

模拟器默认不接电脑麦克风：Extended Controls（模拟器侧栏 `…`）→ Microphone → 打开
"Virtual microphone uses host audio input"。每次重启模拟器后要重新打开。

## 说明

- 凭证明文存在 SharedPreferences，仅供测试。
- 语音会话 config 设了 `outputFormat = "pcm"`，`TtsAudio` 是 16kHz / 16bit / 单声道 PCM，`PcmPlayer` 用 AudioTrack 边收边播；
  收到 `AudioInterrupt` 立即清空。
- 录音 `PcmRecorder` 每 100ms 喂一次 `sendPcm`。
