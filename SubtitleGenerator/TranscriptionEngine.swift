import Foundation

let appLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/SubtitleGenerator_debug.log")

func logDebug(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: appLog.path) {
            if let handle = try? FileHandle(forWritingTo: appLog) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: appLog)
        }
    }
}

class TranscriptionEngine: ObservableObject {
    @Published var isProcessing = false
    @Published var currentIndex = 0
    @Published var currentStatus = ""
    @Published var fileProgress: Double = 0  // 0.0 ~ 1.0 per file
    @Published var eta = ""
    private var shouldCancel = false
    private var currentProcess: Process?
    private var fileStartTime: Date = Date()
    private var totalFileCount = 0

    struct Options {
        var model: String
        var embedSubtitle: Bool
        var keepSrtFile: Bool
        var subtitleDelay: Double
        var noSpeechThreshold: Double
        var language: String  // empty = auto detect
        var translationTargets: Set<TranslationLanguage>
        var authMethod: AuthMethod
        var translationModel: String
        var claudeApiKey: String

        var openaiApiKey: String
    }

    private func findBinary(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func run(_ executable: String, arguments: [String], environment: [String: String]? = nil, onOutput: ((String) -> Void)? = nil) -> (output: String, exitCode: Int32) {
        let process = Process()
        currentProcess = process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env { processEnv[key] = value }
            process.environment = processEnv
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var allOutput = ""

        if let onOutput = onOutput {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                allOutput += line
                onOutput(line)
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("Error: \(error.localizedDescription)", 1)
        }

        pipe.fileHandleForReading.readabilityHandler = nil

        if onOutput == nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            allOutput = String(data: data, encoding: .utf8) ?? ""
        }

        currentProcess = nil
        return (allOutput, process.terminationStatus)
    }

    func cancel() {
        shouldCancel = true
        currentProcess?.terminate()
    }

    func process(files: [FileItem], options: Options, onFileUpdate: @escaping (Int, FileStatus) -> Void) {
        shouldCancel = false

        logDebug("Starting process with \(files.count) files, model: \(options.model)")
        guard let mlxWhisper = findBinary("mlx_whisper") else {
            logDebug("mlx_whisper not found")
            DispatchQueue.main.async {
                self.currentStatus = "mlx_whisper를 찾을 수 없습니다"
                self.isProcessing = false
            }
            return
        }

        let ffmpeg = findBinary("ffmpeg")
        subtitleDelay = options.subtitleDelay
        totalFileCount = files.count

        DispatchQueue.main.async {
            self.isProcessing = true
            self.currentIndex = 0
        }

        DispatchQueue.global(qos: .userInitiated).async {
            for (i, file) in files.enumerated() {
                if self.shouldCancel { break }

                // Skip already completed/skipped files
                switch file.status {
                case .completed, .skipped:
                    continue
                default:
                    break
                }

                DispatchQueue.main.async {
                    self.currentIndex = i
                    self.fileProgress = 0
                    self.eta = ""
                    self.fileStartTime = Date()
                    self.currentStatus = "\(i + 1)/\(self.totalFileCount) 자막 생성 중..."
                    onFileUpdate(i, .processing)
                }

                let result = self.transcribeFile(
                    file: file,
                    mlxWhisper: mlxWhisper,
                    ffmpeg: ffmpeg,
                    options: options
                )

                DispatchQueue.main.async {
                    onFileUpdate(i, result)
                }
            }

            DispatchQueue.main.async {
                self.currentIndex = self.totalFileCount
                self.currentStatus = self.shouldCancel ? "중단됨" : "완료"
                self.isProcessing = false
            }
        }
    }

    private func transcribeFile(file: FileItem, mlxWhisper: String, ffmpeg: String?, options: Options) -> FileStatus {
        let url = file.url
        let dir = url.deletingLastPathComponent().path
        let nameNoExt = url.deletingPathExtension().lastPathComponent

        // Check if srt already exists
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: dir) {
            let existing = contents.first { $0.hasPrefix(nameNoExt) && $0.hasSuffix(".srt") }
            if existing != nil {
                return .skipped
            }
        }

        // Create temp directory
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }

        // Get total duration for progress calculation
        let totalDuration = getMediaDuration(url: url)

        // Step 1: Generate json with mlx_whisper
        DispatchQueue.main.async {
            self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 음성 인식 중..."
            self.fileProgress = 0
        }

        var whisperArgs = [
            url.path,
            "--model", options.model,
            "--output-format", "json",
            "--output-dir", tmpDir,
            "--condition-on-previous-text", "False",
            "--word-timestamps", "True",
            "--max-line-width", "20",
            "--max-line-count", "1",
            "--hallucination-silence-threshold", "2.0",
            "--no-speech-threshold", String(options.noSpeechThreshold),
        ]
        if !options.language.isEmpty {
            whisperArgs += ["--language", options.language]
        }

        let (_, whisperExit) = run(mlxWhisper, arguments: whisperArgs, environment: ["PYTHONUNBUFFERED": "1"]) { line in
            // Parse whisper verbose output: [00:01.000 --> 00:03.000] text
            if let match = line.range(of: #"\d{2}:\d{2}\.\d{3} --> (\d{2}:\d{2}\.\d{3})"#, options: .regularExpression) {
                let endTimeStr = String(line[match]).components(separatedBy: " --> ").last ?? ""
                let endSeconds = self.parseSrtTimestamp(endTimeStr)
                let text = line.components(separatedBy: "] ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    if totalDuration > 0 {
                        self.fileProgress = min(endSeconds / totalDuration, 1.0)
                    }
                    let pct = totalDuration > 0 ? " \(Int(self.fileProgress * 100))%" : ""
                    self.eta = self.calculateEta()
                    self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) \(Int(self.fileProgress * 100))% \(text)"
                }
            } else if line.contains("Detected language:") {
                let lang = line.components(separatedBy: "Detected language:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 언어 감지: \(lang)"
                }
            }
        }

        logDebug("whisper exit: \(whisperExit)")
        guard whisperExit == 0 else {
            logDebug("whisper failed")
            return .failed(error: "음성 인식 실패")
        }

        let jsonPath = "\(tmpDir)/\(nameNoExt).json"
        logDebug("json path: \(jsonPath), exists: \(fm.fileExists(atPath: jsonPath))")
        guard fm.fileExists(atPath: jsonPath) else {
            return .failed(error: "JSON 파일 없음")
        }

        // Step 2: Parse json - extract language and generate srt
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let language = json["language"] as? String,
              let segments = json["segments"] as? [[String: Any]] else {
            return .failed(error: "JSON 파싱 실패")
        }

        let srtContent = generateSrt(from: segments)
        guard !srtContent.isEmpty else {
            return .failed(error: "자막 내용 없음")
        }

        let srtFilename = "\(nameNoExt).\(language).srt"
        let srtPath = "\(dir)/\(srtFilename)"

        do {
            try srtContent.write(toFile: srtPath, atomically: true, encoding: .utf8)
        } catch {
            return .failed(error: "srt 저장 실패")
        }

        // Step 3: Embed subtitle into video
        if options.embedSubtitle, let ffmpeg = ffmpeg {
            DispatchQueue.main.async {
                self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 자막 내장 중 (\(language))..."
            }

            let tmpOutput = "\(dir)/.\(nameNoExt)_sub.\(url.pathExtension)"
            let ffmpegArgs = [
                "-y", "-i", url.path,
                "-i", srtPath,
                "-map", "0:v", "-map", "0:a", "-map", "1:0",
                "-c", "copy", "-c:s", "mov_text",
                "-metadata:s:s:0", "language=\(langCode3(language))",
                tmpOutput,
            ]
            logDebug("ffmpeg args: \(ffmpegArgs.joined(separator: " "))")
            let (ffmpegOutput, ffmpegExit) = run(ffmpeg, arguments: ffmpegArgs)
            logDebug("ffmpeg exit: \(ffmpegExit), output: \(String(ffmpegOutput.suffix(500)))")

            if ffmpegExit == 0 {
                try? fm.removeItem(atPath: url.path)
                try? fm.moveItem(atPath: tmpOutput, toPath: url.path)
            } else {
                try? fm.removeItem(atPath: tmpOutput)
            }
        }

        // Step 4: Translate to other languages using Claude API
        let hasAuth: Bool
        switch options.authMethod {
        case .claudeCode: hasAuth = true
        case .claudeApiKey: hasAuth = !options.claudeApiKey.isEmpty
        case .openaiApiKey: hasAuth = !options.openaiApiKey.isEmpty
        }
        if !options.translationTargets.isEmpty && hasAuth {
            DispatchQueue.main.async {
                self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 번역 중 (\(options.translationTargets.count)개 언어)..."
            }

            let translator = TranslationEngine(authMethod: options.authMethod, translationModel: options.translationModel, claudeApiKey: options.claudeApiKey, openaiApiKey: options.openaiApiKey)
            let translations = translator.translateSrt(
                srtContent: srtContent,
                sourceLang: language,
                targetLangs: Array(options.translationTargets)
            ) { progress in
                DispatchQueue.main.async {
                    self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) \(progress)"
                }
            }

            for (lang, translatedSrt) in translations {
                let translatedPath = "\(dir)/\(nameNoExt).\(lang.rawValue).srt"
                try? translatedSrt.write(toFile: translatedPath, atomically: true, encoding: .utf8)
            }
        }

        // Step 5: Remove srt if not keeping
        if !options.keepSrtFile {
            try? fm.removeItem(atPath: srtPath)
        }

        return .completed(lang: language)
    }

    private func calculateEta() -> String {
        guard fileProgress > 0.05 else { return "" }  // wait until 5% for stable estimate
        let elapsed = Date().timeIntervalSince(fileStartTime)
        let totalEstimated = elapsed / fileProgress
        let remaining = totalEstimated - elapsed
        guard remaining > 0 else { return "" }

        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        if mins > 0 {
            return "약 \(mins)분 \(secs)초 남음"
        } else {
            return "약 \(secs)초 남음"
        }
    }

    private func getMediaDuration(url: URL) -> Double {
        guard let ffprobe = findBinary("ffprobe") else { return 0 }
        let (output, exitCode) = run(ffprobe, arguments: [
            "-v", "quiet",
            "-show_entries", "format=duration",
            "-of", "csv=p=0",
            url.path,
        ])
        guard exitCode == 0 else { return 0 }
        return Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func parseSrtTimestamp(_ str: String) -> Double {
        // Parse "MM:SS.mmm" format
        let parts = str.components(separatedBy: ":")
        guard parts.count == 2 else { return 0 }
        let minutes = Double(parts[0]) ?? 0
        let seconds = Double(parts[1]) ?? 0
        return minutes * 60 + seconds
    }

    private var subtitleDelay: Double = 0.3

    // ISO 639-1 (2-char) to ISO 639-2 (3-char) for MP4 container
    private let langMap: [String: String] = [
        "ja": "jpn", "ko": "kor", "en": "eng", "zh": "zho", "fr": "fra",
        "de": "deu", "es": "spa", "it": "ita", "pt": "por", "ru": "rus",
        "ar": "ara", "hi": "hin", "th": "tha", "vi": "vie", "id": "ind",
        "ms": "msa", "tl": "tgl", "tr": "tur", "pl": "pol", "nl": "nld",
        "sv": "swe", "da": "dan", "no": "nor", "fi": "fin", "el": "ell",
        "he": "heb", "uk": "ukr", "cs": "ces", "ro": "ron", "hu": "hun",
    ]

    func langCode3(_ code2: String) -> String {
        langMap[code2] ?? code2
    }

    func generateSrt(from segments: [[String: Any]]) -> String {
        var lines: [String] = []
        for (i, seg) in segments.enumerated() {
            guard let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double,
                  let text = seg["text"] as? String else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            lines.append("\(i + 1)")
            lines.append("\(formatSrtTime(start + subtitleDelay)) --> \(formatSrtTime(end + subtitleDelay))")
            lines.append(trimmed)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func formatSrtTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s).replacingOccurrences(of: ".", with: ",")
    }
}
