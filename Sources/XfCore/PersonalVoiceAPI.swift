import Foundation

/// 个人声音（Azure Personal Voice），对应 /trans/personal-voice/*。每台设备一个个人声音。
///
/// 流程：`createConsent` 上传本人朗读的授权声明录音 → `createSpeakerProfile` 上传声音样本 →
/// 拿到 speakerProfileId，在 TTS / 语音会话里通过 `StreamConfig.speakerProfileId` 使用。
///
/// 暂不对外提供声音克隆：模块保留但不公开。
final class PersonalVoiceAPI {
    private let transport: RestTransport

    init(transport: RestTransport) {
        self.transport = transport
    }

    /// - Parameter companyName: 必须与授权声明里念的公司名一致
    public func createConsent(voiceName: String, defaultLocale: String, companyName: String,
                              consentAudio: Data, fileName: String = "consent.wav") async throws -> PersonalVoice {
        let form = consentForm(voiceName, defaultLocale, companyName, consentAudio, fileName)
        return PersonalVoice(try await transport.object(transport.multipartRequest("trans/personal-voice/create-consent", form: form)))
    }

    public func createSpeakerProfile(voiceName: String, voiceSample: Data, fileName: String = "sample.wav") async throws -> PersonalVoice {
        var form = MultipartForm()
        form.add("voiceName", voiceName)
        form.add("voiceSample", fileName: fileName, contentType: MultipartForm.audioContentType(fileName), data: voiceSample)
        return PersonalVoice(try await transport.object(transport.multipartRequest("trans/personal-voice/create-speaker-profile", form: form)))
    }

    public func reuploadConsent(voiceId: Int64, voiceName: String, defaultLocale: String, companyName: String,
                                consentAudio: Data, fileName: String = "consent.wav") async throws -> PersonalVoice {
        let form = consentForm(voiceName, defaultLocale, companyName, consentAudio, fileName)
        return PersonalVoice(try await transport.object(transport.multipartRequest("trans/personal-voice/\(voiceId)/reupload-consent", form: form)))
    }

    public func list() async throws -> [PersonalVoice] {
        let data = try await transport.result(transport.getRequest("trans/personal-voice/list"))
        return (data as? [[String: Any]] ?? []).map(PersonalVoice.init)
    }

    /// 当前设备的个人声音，没有返回 nil
    public func detail() async throws -> PersonalVoice? {
        let data = try await transport.result(transport.getRequest("trans/personal-voice/detail"))
        return (data as? [String: Any]).map(PersonalVoice.init)
    }

    public func delete() async throws -> Bool {
        (try await transport.result(transport.deleteRequest("trans/personal-voice/delete")) as? NSNumber)?.boolValue ?? false
    }

    /// 授权录音是否已审核通过、可以创建声音档案
    public func checkConsent() async throws -> Bool {
        (try await transport.result(transport.getRequest("trans/personal-voice/check-consent")) as? NSNumber)?.boolValue ?? false
    }

    private func consentForm(_ voiceName: String, _ locale: String, _ company: String, _ audio: Data, _ fileName: String) -> MultipartForm {
        var form = MultipartForm()
        form.add("voiceName", voiceName)
        form.add("defaultLocale", locale)
        form.add("companyName", company)
        form.add("consentRecording", fileName: fileName, contentType: MultipartForm.audioContentType(fileName), data: audio)
        return form
    }
}

struct PersonalVoice: Equatable {
    public let voiceId: Int64?
    public let voiceName: String?
    /// TTS 时使用的档案 ID，档案创建成功后才有
    public let speakerProfileId: String?
    public let defaultLocale: String?
    public let status: Int?
    public let statusText: String?
    public let errorMessage: String?
    public let createTime: String?

    init(_ json: [String: Any]) {
        voiceId = json.int64("voiceId")
        voiceName = json.str("voiceName")
        speakerProfileId = json.str("speakerProfileId")
        defaultLocale = json.str("defaultLocale")
        status = json.int("status")
        statusText = json.str("statusText")
        errorMessage = json.str("errorMessage")
        createTime = json.str("createTime")
    }
}
