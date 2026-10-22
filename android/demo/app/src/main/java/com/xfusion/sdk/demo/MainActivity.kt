package com.xfusion.sdk.demo

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import com.xfusion.sdk.ChatApi
import com.xfusion.sdk.ChatMessage
import com.xfusion.sdk.ChatStreamListener
import com.xfusion.sdk.DeviceRegistrar
import com.xfusion.sdk.DeviceRegistration
import com.xfusion.sdk.TranslateResult
import com.xfusion.sdk.TtsRequest
import com.xfusion.sdk.TtsResult
import com.xfusion.sdk.XfCallback
import com.xfusion.sdk.XfClient
import com.xfusion.sdk.XfException
import com.xfusion.sdk.stream.StreamConfig
import com.xfusion.sdk.stream.StreamEvent
import com.xfusion.sdk.stream.StreamListener
import com.xfusion.sdk.stream.VoiceSession
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executor

/**
 * SDK 联调用的最小 App：REST（注册、翻译、合成、Chat 流式）+ 语音翻译会话（按住说话）。
 * 凭证明文存在 SharedPreferences，只用于测试，正式 App 请放 Keystore。
 */
class MainActivity : Activity() {

    private val mainHandler = Handler(Looper.getMainLooper())
    // SDK 回调切回主线程（getMainExecutor 要 API 28，这里自己包一个）
    private val mainExecutor = Executor { mainHandler.post(it) }

    private lateinit var restUrl: EditText
    private lateinit var wsUrl: EditText
    private lateinit var deviceId: EditText
    private lateinit var macId: EditText
    private lateinit var secret: EditText
    private lateinit var productKey: EditText
    private lateinit var inputText: EditText
    private lateinit var fromLang: EditText
    private lateinit var toLang: EditText
    private lateinit var voiceName: EditText
    private lateinit var partial: TextView
    private lateinit var logView: TextView
    private lateinit var logScroll: ScrollView
    private lateinit var liveButton: Button
    /** 实时模式：开始后一直收音，服务端按停顿自动断句、逐句翻译，直到再点一次 */
    private var live = false

    private var client: XfClient? = null
    // 录音线程也会读
    @Volatile private var session: VoiceSession? = null
    private var mediaPlayer: MediaPlayer? = null
    private val player by lazy { PcmPlayer() }
    private lateinit var micLevel: TextView
    private val recorder = PcmRecorder { buffer, length ->
        session?.sendPcm(buffer, 0, length)
        showMicLevel(buffer, length)
    }

    /** 显示这 100ms 的峰值电平，用来判断麦克风是不是全静音（模拟器没接电脑麦克风时一直是 0） */
    private fun showMicLevel(buffer: ByteArray, length: Int) {
        var peak = 0
        var i = 0
        while (i + 1 < length) {
            val sample = (buffer[i].toInt() and 0xFF) or (buffer[i + 1].toInt() shl 8)
            peak = maxOf(peak, kotlin.math.abs(sample.toShort().toInt()))
            i += 2
        }
        val percent = peak * 100 / 32768
        mainHandler.post { micLevel.text = "麦克风电平：$percent%  " + "▮".repeat(percent / 5) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        restUrl = findViewById(R.id.restUrl)
        wsUrl = findViewById(R.id.wsUrl)
        deviceId = findViewById(R.id.deviceId)
        macId = findViewById(R.id.macId)
        secret = findViewById(R.id.secret)
        productKey = findViewById(R.id.productKey)
        inputText = findViewById(R.id.inputText)
        fromLang = findViewById(R.id.fromLang)
        toLang = findViewById(R.id.toLang)
        voiceName = findViewById(R.id.voiceName)
        partial = findViewById(R.id.partial)
        micLevel = findViewById(R.id.micLevel)
        logView = findViewById(R.id.log)
        logScroll = findViewById(R.id.logScroll)

        loadPrefs()
        findViewById<Button>(R.id.btnSave).setOnClickListener { savePrefs(); initClient() }
        findViewById<Button>(R.id.btnRegister).setOnClickListener { register() }
        findViewById<Button>(R.id.btnTranslate).setOnClickListener { translate() }
        findViewById<Button>(R.id.btnTts).setOnClickListener { synthesize() }
        findViewById<Button>(R.id.btnChat).setOnClickListener { chat() }
        findViewById<Button>(R.id.btnHangup).setOnClickListener { hangUp() }
        findViewById<Button>(R.id.btnClear).setOnClickListener { logView.text = "" }
        setupTalkButton(findViewById(R.id.btnTalk))
        liveButton = findViewById(R.id.btnLive)
        liveButton.setOnClickListener { toggleLive() }
        findViewById<Button>(R.id.btnFakeMic).setOnClickListener { testWithSynthesizedSpeech() }

        if (deviceId.text.isNotBlank() && secret.text.isNotBlank()) initClient()
    }

    override fun onDestroy() {
        hangUp()
        mediaPlayer?.release()
        player.release()
        client?.shutdown()
        super.onDestroy()
    }

    // ---- 配置 ----

    private fun loadPrefs() {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        restUrl.setText(prefs.getString("restUrl", DEFAULT_REST))
        wsUrl.setText(prefs.getString("wsUrl", DEFAULT_WS))
        deviceId.setText(prefs.getString("deviceId", ""))
        macId.setText(prefs.getString("macId", ""))
        secret.setText(prefs.getString("secret", ""))
        productKey.setText(prefs.getString("productKey", ""))
    }

    private fun savePrefs() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString("restUrl", restUrl.value())
            .putString("wsUrl", wsUrl.value())
            .putString("deviceId", deviceId.value())
            .putString("macId", macId.value())
            .putString("secret", secret.value())
            .putString("productKey", productKey.value())
            .apply()
    }

    private fun initClient() {
        hangUp()
        client?.shutdown()
        client = null
        if (deviceId.value().isEmpty() || secret.value().isEmpty()) {
            log("请先填 deviceId 和 deviceSecret，或用产品 Key 注册")
            return
        }
        client = try {
            XfClient.Builder()
                .restBaseUrl(restUrl.value())
                .wsBaseUrl(wsUrl.value())
                // secret 每次签名时现取，SDK 不缓存
                .device(deviceId.value(), macId = macId.value()) { secret.value() }
                .callbackExecutor(mainExecutor)
                .build()
        } catch (e: IllegalArgumentException) {
            log("地址格式不对：${e.message}")
            return
        }
        log("已初始化 deviceId=${deviceId.value()} rest=${restUrl.value()} ws=${wsUrl.value()}")
    }

    private fun requireClient(): XfClient? = client ?: run {
        log("还没初始化，先点「保存并初始化」")
        null
    }

    // ---- REST ----

    private fun register() {
        val key = productKey.value()
        val mac = macId.value()
        if (key.isEmpty() || mac.isEmpty()) {
            log("注册需要产品 API Key 和 macId")
            return
        }
        val registrar = try {
            DeviceRegistrar(restUrl.value(), callbackExecutor = mainExecutor)
        } catch (e: IllegalArgumentException) {
            log("REST 地址格式不对：${e.message}")
            return
        }
        log("注册中 macId=$mac …")
        registrar.register(key, mac, deviceId.value().ifEmpty { null }).enqueue(object : XfCallback<DeviceRegistration> {
            override fun onSuccess(result: DeviceRegistration) {
                deviceId.setText(result.deviceId)
                secret.setText(result.deviceSecret)
                log("注册成功 $result")
                savePrefs()
                initClient()
            }

            override fun onError(error: XfException) = logError("注册", error)
        })
    }

    private fun translate() {
        val c = requireClient() ?: return
        val text = inputText.value()
        log("翻译 zh-Hans → en：$text")
        c.translate.text(text, "zh-Hans", "en").enqueue(object : XfCallback<TranslateResult> {
            override fun onSuccess(result: TranslateResult) = log("译文：${result.text}（计费 ${result.used} 字）")
            override fun onError(error: XfException) = logError("翻译", error)
        })
    }

    private fun synthesize() {
        val c = requireClient() ?: return
        val text = inputText.value()
        log("合成 zh-CN-XiaoxiaoNeural：$text")
        c.tts.synthesize(TtsRequest(text, "zh-CN", "zh-CN-XiaoxiaoNeural")).enqueue(object : XfCallback<TtsResult> {
            override fun onSuccess(result: TtsResult) {
                log("音频 ${result.audio.size} 字节，格式 ${result.audioFormat ?: result.contentType}")
                playFile(result.audio, result.fileExtension ?: "mp3")
            }

            override fun onError(error: XfException) = logError("合成", error)
        })
    }

    private fun playFile(audio: ByteArray, extension: String) {
        val file = File(cacheDir, "tts.$extension").apply { writeBytes(audio) }
        mediaPlayer?.release()
        mediaPlayer = MediaPlayer().apply {
            try {
                setDataSource(file.absolutePath)
                setOnCompletionListener { log("播放完毕") }
                prepare()
                start()
            } catch (e: Exception) {
                log("播放失败：$e")
            }
        }
    }

    private fun chat() {
        val c = requireClient() ?: return
        val text = inputText.value()
        log("Chat：$text")
        val answer = StringBuilder()
        c.chat.stream(ChatApi.request(CHAT_MODEL, listOf(ChatMessage.user(text))), object : ChatStreamListener {
            override fun onDelta(text: String) {
                answer.append(text)
                partial.text = answer
            }

            override fun onComplete() = log("回答：$answer")
            override fun onError(error: XfException) = logError("Chat（已收到：$answer）", error)
        })
    }

    // ---- 语音翻译 ----

    @SuppressLint("ClickableViewAccessibility")
    private fun setupTalkButton(button: Button) {
        button.setOnTouchListener { _, event ->
            if (live) return@setOnTouchListener true
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    button.text = "松开结束"
                    startTalking()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    button.text = "按住说话"
                    stopTalking()
                }
            }
            true
        }
    }

    private fun startTalking() {
        if (!hasMicPermission()) {
            requestMicPermission()
            return
        }
        val s = ensureSession() ?: return
        player.flush()
        partial.text = ""
        // connect() 之后可以立刻 start / 发音频，SDK 会排队到 configOk
        s.start()
        if (!recorder.start()) log("麦克风打开失败（权限或被占用）")
    }

    private fun stopTalking() {
        recorder.stop()
        session?.stop()
    }

    private fun toggleLive() {
        if (live) {
            setLive(false)
            stopTalking()
            return
        }
        if (!hasMicPermission()) {
            requestMicPermission()
            return
        }
        if (client == null) {
            log("还没初始化，先点「保存并初始化」")
            return
        }
        setLive(true)
        log("实时模式开始：直接说，停顿后自动出句；外放时建议戴耳机，免得播报被麦克风录回去")
        startTalking()
    }

    /**
     * 不用麦克风测整条语音链路：先用 REST TTS 把输入框的中文合成 16kHz PCM，
     * 再按实时节奏（每 100ms 一片）当作麦克风输入喂给语音翻译会话。
     * 模拟器拿不到电脑麦克风时用这个。
     */
    private fun testWithSynthesizedSpeech() {
        val c = requireClient() ?: return
        if (live) {
            log("先停止实时模式")
            return
        }
        val text = inputText.value()
        log("合成测试语音（zh-CN，PCM）：$text")
        val request = TtsRequest(text, "zh-CN", "zh-CN-XiaoxiaoNeural", outputFormat = "raw-16khz-16bit-mono-pcm")
        c.tts.synthesize(request).enqueue(object : XfCallback<TtsResult> {
            override fun onSuccess(result: TtsResult) {
                val pcm = pcmPayload(result.audio)
                if (pcm == null) {
                    log("服务端返回的不是 PCM（${result.audioFormat ?: result.contentType}），没法当麦克风输入")
                    return
                }
                val s = ensureSession() ?: return
                log("测试语音 ${pcm.size / 32} ms，按实时节奏发送")
                player.flush()
                partial.text = ""
                s.start()
                Thread({ feed(s, pcm) }, "fake-mic").start()
            }

            override fun onError(error: XfException) = logError("合成测试语音", error)
        })
    }

    private fun feed(s: VoiceSession, pcm: ByteArray) {
        val chunk = PcmRecorder.CHUNK_BYTES
        var offset = 0
        while (offset < pcm.size && session === s) {
            val n = minOf(chunk, pcm.size - offset)
            s.sendPcm(pcm, offset, n)
            showMicLevel(pcm.copyOfRange(offset, offset + n), n)
            offset += n
            Thread.sleep(100)
        }
        // 补 1 秒静音让服务端判出句尾，再结束本轮
        val silence = ByteArray(chunk)
        repeat(10) {
            if (session !== s) return
            s.sendPcm(silence)
            Thread.sleep(100)
        }
        if (session === s) s.stop()
        mainHandler.post { log("测试语音发送完毕") }
    }

    /** 去掉 WAV 头；是 mp3 等压缩格式时返回 null */
    private fun pcmPayload(audio: ByteArray): ByteArray? {
        if (audio.size > 12 && String(audio, 0, 4, Charsets.US_ASCII) == "RIFF") {
            var pos = 12
            while (pos + 8 <= audio.size) {
                val id = String(audio, pos, 4, Charsets.US_ASCII)
                val size = (audio[pos + 4].toInt() and 0xFF) or ((audio[pos + 5].toInt() and 0xFF) shl 8) or
                    ((audio[pos + 6].toInt() and 0xFF) shl 16) or ((audio[pos + 7].toInt() and 0xFF) shl 24)
                if (id == "data") return audio.copyOfRange(pos + 8, minOf(audio.size, pos + 8 + size))
                pos += 8 + size
            }
            return null
        }
        val isMp3 = (audio.size > 3 && String(audio, 0, 3, Charsets.US_ASCII) == "ID3") ||
            (audio.size > 2 && audio[0] == 0xFF.toByte() && (audio[1].toInt() and 0xE0) == 0xE0)
        return if (isMp3) null else audio
    }

    private fun setLive(on: Boolean) {
        live = on
        liveButton.text = if (on) "实时：停止" else "实时：开始"
    }

    private fun ensureSession(): VoiceSession? {
        session?.let { return it }
        val c = requireClient() ?: return null
        val voice = voiceName.value()
        val config = StreamConfig.voiceTranslation(fromLang.value(), toLang.value()).apply {
            if (voice.isNotEmpty()) tts(voice)
            // 下发原始 PCM，PcmPlayer 直接播；默认是 mp3
            outputFormat("pcm")
        }
        log("连接语音翻译 ${fromLang.value()} → ${toLang.value()}，播报 ${voice.ifEmpty { "关" }}")
        val listener = VoiceListener()
        val s = c.voiceSession(config, listener)
        listener.owner = s
        session = s
        s.connect()
        return s
    }

    private fun hangUp() {
        if (::liveButton.isInitialized) setLive(false)
        recorder.stop()
        session?.close()
        session = null
    }

    private inner class VoiceListener : StreamListener {
        var owner: VoiceSession? = null
        private var ttsBytes = 0

        override fun onEvent(event: StreamEvent) {
            when (event) {
                is StreamEvent.AsrPartial -> partial.text = event.text
                is StreamEvent.AsrFinal -> log("识别：${event.text}")
                is StreamEvent.Translation -> log("译文：${event.translated}")
                is StreamEvent.TtsAudio -> {
                    ttsBytes += event.audio.size
                    player.enqueue(event.audio)
                }
                is StreamEvent.TtsComplete -> {
                    log("播报音频 ${ttsBytes / 32} ms（$ttsBytes 字节）")
                    ttsBytes = 0
                }
                StreamEvent.AudioInterrupt -> player.flush()
                StreamEvent.Ready -> log("会话就绪")
                is StreamEvent.ServerError -> log("服务端错误：${event.message} code=${event.code}")
                StreamEvent.TtsEnd -> Unit
                // object 事件没有自定义 toString，只打类名
                else -> log("事件：" + event.toString().let { if ('@' in it) event.javaClass.simpleName else it })
            }
        }

        override fun onClosed(code: Int, reason: String) {
            log("会话关闭 code=$code $reason")
            // 断开后马上重连时，旧会话晚到的回调不能清掉新会话
            if (session === owner) {
                session = null
                recorder.stop()
                setLive(false)
            }
        }

        override fun onFailure(error: XfException) {
            if (session !== owner) return
            recorder.stop()
            setLive(false)
            session = null
            logError("语音会话", error)
            if (error.kind == XfException.Kind.SIGNATURE_INVALID) {
                log("握手被拒：检查 deviceId / secret；手机时间不准时先点一次「翻译」等 REST 接口校准时钟")
            }
        }
    }

    // ---- 权限 ----

    private fun hasMicPermission() =
        Build.VERSION.SDK_INT < 23 || checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestMicPermission() {
        if (Build.VERSION.SDK_INT >= 23) requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MIC)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode == REQUEST_MIC) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            log(if (granted) "已获得麦克风权限，再按住说话" else "没有麦克风权限，无法测试语音")
        }
    }

    // ---- 日志 ----

    private fun log(message: String) {
        val time = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
        logView.append("$time  $message\n")
        logScroll.post { logScroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    private fun logError(what: String, error: XfException) =
        log("$what 失败：kind=${error.kind} serverCode=${error.serverCode} ${error.message}")

    private fun EditText.value() = text.toString().trim()

    private companion object {
        const val PREFS = "xf-demo"
        const val DEFAULT_REST = "https://transcribe.azopenai.com"
        const val DEFAULT_WS = "wss://transcribe.azopenai.com"
        const val CHAT_MODEL = "gpt-5.4-nano"
        const val REQUEST_MIC = 1
    }
}
