import SwiftUI

struct FileItem: Identifiable, Equatable {
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.status == rhs.status && lhs.elapsedTime == rhs.elapsedTime
    }

    let id = UUID()
    let url: URL
    var status: FileStatus = .pending
    var elapsedTime: TimeInterval?

    var name: String { url.lastPathComponent }
    var size: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func save(_ files: [FileItem]) {
        let paths = files.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: "savedFiles")
    }

    static func loadSaved() -> [FileItem] {
        guard let paths = UserDefaults.standard.stringArray(forKey: "savedFiles") else { return [] }
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return FileItem(url: url)
        }
    }
}

enum FileStatus: Equatable {
    case pending, processing, skipped, completed(lang: String), failed(error: String)

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .processing: return "progress.indicator"
        case .skipped: return "forward.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .processing: return .blue
        case .skipped: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case largev3 = "mlx-community/whisper-large-v3-mlx"
    case largev3turbo = "mlx-community/whisper-large-v3-turbo"
    case medium = "mlx-community/whisper-medium-mlx"
    case small = "mlx-community/whisper-small-mlx"
    case base = "mlx-community/whisper-base-mlx"
    case tiny = "mlx-community/whisper-tiny-mlx"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largev3: return "Large v3 (최고 품질, 추천)"
        case .largev3turbo: return "Large v3 Turbo (빠름, 좋은 품질)"
        case .medium: return "Medium (좋은 품질)"
        case .small: return "Small (균형)"
        case .base: return "Base (빠름)"
        case .tiny: return "Tiny (가장 빠름, 낮은 품질)"
        }
    }

    var cacheDir: String {
        let repo = rawValue.replacingOccurrences(of: "/", with: "--")
        return "\(NSHomeDirectory())/.cache/huggingface/hub/models--\(repo)"
    }

    var isCached: Bool {
        FileManager.default.fileExists(atPath: cacheDir)
    }

    var sizeLabel: String {
        switch self {
        case .largev3: return "~2.9GB"
        case .largev3turbo: return "~1.6GB"
        case .medium: return "~1.5GB"
        case .small: return "~950MB"
        case .base: return "~290MB"
        case .tiny: return "~150MB"
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case embedInVideo
    case srtOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedInVideo: return "영상에 자막 포함"
        case .srtOnly: return "srt 파일 생성"
        }
    }
}

enum Language: String, CaseIterable, Identifiable {
    case auto = ""
    case ko, ja, en, zh, fr, de, es, it, pt, ru
    case ar, hi, th, vi, id, ms, tl, tr, pl, nl
    case sv, da, no, fi, el, he, uk, cs, ro, hu

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "자동 감지"
        case .ja: return "일본어"
        case .ko: return "한국어"
        case .en: return "영어"
        case .zh: return "중국어"
        case .fr: return "프랑스어"
        case .de: return "독일어"
        case .es: return "스페인어"
        case .it: return "이탈리아어"
        case .pt: return "포르투갈어"
        case .ru: return "러시아어"
        case .ar: return "아랍어"
        case .hi: return "힌디어"
        case .th: return "태국어"
        case .vi: return "베트남어"
        case .id: return "인도네시아어"
        case .ms: return "말레이어"
        case .tl: return "타갈로그어"
        case .tr: return "터키어"
        case .pl: return "폴란드어"
        case .nl: return "네덜란드어"
        case .sv: return "스웨덴어"
        case .da: return "덴마크어"
        case .no: return "노르웨이어"
        case .fi: return "핀란드어"
        case .el: return "그리스어"
        case .he: return "히브리어"
        case .uk: return "우크라이나어"
        case .cs: return "체코어"
        case .ro: return "루마니아어"
        case .hu: return "헝가리어"
        }
    }
}

enum Sensitivity: String, CaseIterable, Identifiable {
    case sensitive
    case normal
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sensitive: return "민감"
        case .normal: return "보통"
        case .accurate: return "정확 (느림)"
        }
    }

    var noSpeechThreshold: Double {
        switch self {
        case .sensitive: return 0.3
        case .normal: return 0.5
        case .accurate: return 0.7
        }
    }

    var logprobThreshold: Double {
        switch self {
        case .sensitive: return -2.0
        case .normal: return -1.0
        case .accurate: return -0.5
        }
    }

    var compressionRatioThreshold: Double {
        switch self {
        case .sensitive: return 2.8
        case .normal: return 2.4
        case .accurate: return 2.0
        }
    }

    var hallucinationSilenceThreshold: Double {
        switch self {
        case .sensitive: return 0     // disabled — catch everything
        case .normal: return 1.0
        case .accurate: return 0.5
        }
    }

    var conditionOnPreviousText: Bool {
        switch self {
        case .sensitive: return true
        case .normal: return true
        case .accurate: return false  // prevent error propagation
        }
    }

    var bestOf: Int {
        switch self {
        case .sensitive: return 7
        case .normal: return 5
        case .accurate: return 10
        }
    }
}

enum AuthMethod: String, CaseIterable, Identifiable {
    case claudeCode
    case claudeApiKey
    case openaiApiKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code (구독)"
        case .claudeApiKey: return "Claude API 키"
        case .openaiApiKey: return "OpenAI API 키"
        }
    }
}

enum TranslationModel: String, CaseIterable, Identifiable {
    // Claude
    case claudeOpus1m = "claude-opus-4-6[1m]"
    case claudeOpus = "claude-opus-4-20250514"
    case claudeSonnet = "claude-sonnet-4-20250514"
    case claudeHaiku = "claude-haiku-4-5-20251001"
    // OpenAI
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case gpt41 = "gpt-4.1"
    case gpt41Mini = "gpt-4.1-mini"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeOpus1m: return "Claude Opus 4.6 (1M)"
        case .claudeOpus: return "Claude Opus"
        case .claudeSonnet: return "Claude Sonnet"
        case .claudeHaiku: return "Claude Haiku"
        case .gpt4o: return "GPT-4o"
        case .gpt4oMini: return "GPT-4o mini"
        case .gpt41: return "GPT-4.1"
        case .gpt41Mini: return "GPT-4.1 mini"
        }
    }

    var isClaude: Bool {
        switch self {
        case .claudeOpus1m, .claudeOpus, .claudeSonnet, .claudeHaiku: return true
        default: return false
        }
    }

    var isOpenAI: Bool { !isClaude }

    static func models(for auth: AuthMethod) -> [TranslationModel] {
        switch auth {
        case .claudeCode, .claudeApiKey:
            return [.claudeOpus1m, .claudeOpus, .claudeSonnet, .claudeHaiku]
        case .openaiApiKey:
            return [.gpt4oMini, .gpt4o, .gpt41Mini, .gpt41]
        }
    }
}

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case ko, ja, en, zh, fr, de, es, pt, ru

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ko: return "한국어"
        case .ja: return "일본어"
        case .en: return "영어"
        case .zh: return "중국어"
        case .fr: return "프랑스어"
        case .de: return "독일어"
        case .es: return "스페인어"
        case .pt: return "포르투갈어"
        case .ru: return "러시아어"
        }
    }

    var langName: String {
        switch self {
        case .ko: return "Korean"
        case .ja: return "Japanese"
        case .en: return "English"
        case .zh: return "Chinese"
        case .fr: return "French"
        case .de: return "German"
        case .es: return "Spanish"
        case .pt: return "Portuguese"
        case .ru: return "Russian"
        }
    }
}

enum SubtitleDelay: String, CaseIterable, Identifiable {
    case immediate, quick, normal, slow, verySlow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .immediate: return "즉시"
        case .quick: return "바로 (0.3초)"
        case .normal: return "보통 (0.5초)"
        case .slow: return "늦게 (1.0초)"
        case .verySlow: return "아주 늦게 (1.5초)"
        }
    }

    var seconds: Double {
        switch self {
        case .immediate: return 0.0
        case .quick: return 0.3
        case .normal: return 0.5
        case .slow: return 1.0
        case .verySlow: return 1.5
        }
    }
}
