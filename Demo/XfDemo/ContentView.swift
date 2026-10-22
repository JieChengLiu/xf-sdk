import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DemoModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text("服务地址")) {
                    plainField("REST 地址", text: $model.restURL)
                    plainField("WebSocket 地址", text: $model.wsURL)
                }

                Section(header: Text("设备凭证"),
                        footer: Text("已有凭证直接填；没有就填产品 API Key + macId 点注册")) {
                    plainField("deviceId", text: $model.deviceId)
                    plainField("macId（可空）", text: $model.macId)
                    SecureField("deviceSecret", text: $model.secret)
                    plainField("产品 API Key（仅注册时用）", text: $model.productKey)
                    HStack {
                        Button("保存并初始化") { model.saveAndInit() }
                        Spacer()
                        Button("注册设备") { model.register() }
                    }
                    .buttonStyle(.borderless)
                }

                Section(header: Text("REST")) {
                    TextField("输入文字", text: $model.inputText)
                    HStack {
                        Button("翻译") { model.translate() }
                        Spacer()
                        Button("合成播放") { model.synthesize() }
                        Spacer()
                        Button("Chat 流式") { model.chat() }
                    }
                    .buttonStyle(.borderless)
                }

                Section(header: Text("语音翻译（/ws/v1/voice）")) {
                    HStack {
                        plainField("源语言", text: $model.fromLang)
                        plainField("目标语言", text: $model.toLang)
                    }
                    plainField("播报音色（空则不播报）", text: $model.voiceName)
                    talkButton
                    Button("断开") { model.hangUp() }
                        .buttonStyle(.borderless)
                    Text(model.partial.isEmpty ? "实时识别结果" : model.partial)
                        .foregroundColor(.secondary)
                        .frame(minHeight: 40, alignment: .topLeading)
                }
            }

            logPanel
        }
    }

    /// 按下开始收音，松开结束本句
    private var talkButton: some View {
        Text(model.talking ? "松开结束" : "按住说话")
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(model.talking ? Color.red : Color.accentColor)
            .cornerRadius(10)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.talking { model.startTalking() } }
                    .onEnded { _ in model.stopTalking() }
            )
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("日志").font(.subheadline.bold())
                Spacer()
                Button("清空") { model.logLines.removeAll() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                }
                .onChange(of: model.logLines.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .padding(8)
        .frame(height: 200)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func plainField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
    }
}
