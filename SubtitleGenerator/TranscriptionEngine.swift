import Foundation
import AppKit
import UserNotifications

#if DEBUG
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
#else
func logDebug(_ message: String) {}
#endif

class TranscriptionEngine: ObservableObject {
    @Published var isProcessing = false
    @Published var currentIndex = 0
    @Published var currentStatus = ""
    @Published var fileProgress: Double = 0 {
        didSet { updateDockProgress() }
    }
    @Published var eta = ""
    private var shouldCancel = false
    private let processLock = NSLock()
    private var _currentProcess: Process?
    private var currentProcess: Process? {
        get { processLock.lock(); defer { processLock.unlock() }; return _currentProcess }
        set { processLock.lock(); defer { processLock.unlock() }; _currentProcess = newValue }
    }
    private var fileStartTime: Date = Date()
    private var totalFileCount = 0
    private var dockProgressView: DockProgressView?

    struct Options {
        var model: String
        var embedSubtitle: Bool
        var keepSrtFile: Bool
        var subtitleDelay: Double
        var sensitivity: Sensitivity
        var language: String
        var translationTargets: Set<TranslationLanguage>
        var authMethod: AuthMethod
        var translationModel: String
        var claudeApiKey: String
        var openaiApiKey: String
    }

    private func updateDockProgress() {
        DispatchQueue.main.async {
            let dockTile = NSApp.dockTile
            if self.isProcessing {
                if self.dockProgressView == nil {
                    let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
                    self.dockProgressView = view
                    dockTile.contentView = view
                }
                self.dockProgressView?.progress = self.fileProgress
                dockTile.display()
            } else {
                self.dockProgressView = nil
                dockTile.contentView = nil
                dockTile.badgeLabel = nil
                dockTile.display()
            }
        }
    }

    private func bounceIcon() {
        DispatchQueue.main.async {
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    private func sendCompletionNotification(getFiles: @escaping () -> [FileItem]) {
        let files = getFiles()
        let completed = files.filter { if case .completed = $0.status { return true }; return false }.count
        let failed = files.filter { if case .failed = $0.status { return true }; return false }.count
        let skipped = files.filter { $0.status == .skipped }.count

        let content = UNMutableNotificationContent()
        content.title = "자막 생성 완료"
        var body = "\(completed)개 완료"
        if skipped > 0 { body += ", \(skipped)개 건너뜀" }
        if failed > 0 { body += ", \(failed)개 실패" }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
        let outputLock = NSLock()

        if let onOutput = onOutput {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                outputLock.lock()
                allOutput += line
                outputLock.unlock()
                onOutput(line)
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            currentProcess = nil
            return ("Error: \(error.localizedDescription)", 1)
        }

        pipe.fileHandleForReading.readabilityHandler = nil

        // Drain remaining data
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty, let line = String(data: remaining, encoding: .utf8) {
            outputLock.lock()
            allOutput += line
            outputLock.unlock()
            onOutput?(line)
        }

        currentProcess = nil
        return (allOutput, process.terminationStatus)
    }

    func cancel() {
        shouldCancel = true
        currentProcess?.terminate()
    }

    func process(
        getFiles: @escaping () -> [FileItem],
        options: Options,
        onFileUpdate: @escaping (Int, FileStatus, TimeInterval?) -> Void
    ) {
        shouldCancel = false

        logDebug("Starting process, model: \(options.model)")
        guard let mlxWhisper = findBinary("mlx_whisper") else {
            logDebug("mlx_whisper not found")
            DispatchQueue.main.async {
                self.currentStatus = "mlx_whisper를 찾을 수 없습니다"
                self.isProcessing = false
            }
            return
        }

        let ffmpeg = findBinary("ffmpeg")

        DispatchQueue.main.async {
            self.isProcessing = true
            self.currentIndex = 0
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var processedAny = true

            while processedAny && !self.shouldCancel {
                processedAny = false

                var currentFiles: [FileItem] = []
                DispatchQueue.main.sync {
                    currentFiles = getFiles()
                    self.totalFileCount = currentFiles.count
                }

                for (i, file) in currentFiles.enumerated() {
                    if self.shouldCancel { break }

                    switch file.status {
                    case .completed, .skipped, .failed, .processing:
                        continue
                    case .pending:
                        break
                    }

                    processedAny = true

                    DispatchQueue.main.async {
                        self.currentIndex = i
                        self.fileProgress = 0
                        self.eta = ""
                        self.fileStartTime = Date()
                        self.currentStatus = "\(i + 1)/\(self.totalFileCount) 자막 생성 중..."
                        onFileUpdate(i, .processing, nil)
                    }

                    let fileStart = Date()
                    let result = self.transcribeFile(
                        file: file,
                        mlxWhisper: mlxWhisper,
                        ffmpeg: ffmpeg,
                        options: options
                    )
                    let elapsed = Date().timeIntervalSince(fileStart)

                    DispatchQueue.main.async {
                        onFileUpdate(i, result, elapsed)
                    }
                }
            }

            DispatchQueue.main.async {
                self.currentIndex = self.totalFileCount
                self.currentStatus = self.shouldCancel ? "중단됨" : "완료"
                self.isProcessing = false
                self.fileProgress = 0
                if !self.shouldCancel {
                    self.bounceIcon()
                    self.sendCompletionNotification(getFiles: getFiles)
                }
            }
        }
    }

    private func transcribeFile(file: FileItem, mlxWhisper: String, ffmpeg: String?, options: Options) -> FileStatus {
        let url = file.url
        let dir = url.deletingLastPathComponent().path
        let nameNoExt = url.deletingPathExtension().lastPathComponent

        let fm = FileManager.default

        let existingLangs = getExistingSubtitleLanguages(url: url)
        if !existingLangs.isEmpty {
            logDebug("Video already has subtitle tracks: \(existingLangs), skipping transcription")
            return .skipped
        }

        let hasSrtFile = (try? fm.contentsOfDirectory(atPath: dir))?
            .contains { $0.hasPrefix(nameNoExt) && $0.hasSuffix(".srt") } ?? false
        if hasSrtFile {
            return .skipped
        }

        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }

        let totalDuration = getMediaDuration(url: url)

        // Step 1a: Detect language if auto
        let commonLangs: Set<String> = ["ja", "ko", "en", "zh", "fr", "de", "es", "it", "pt", "ru",
                                         "ar", "hi", "th", "vi", "id", "tr", "pl", "nl"]
        var detectedLang = options.language
        if detectedLang.isEmpty {
            DispatchQueue.main.async {
                self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 언어 감지 중..."
                self.fileProgress = 0
            }

            // Progressive sampling: wide → narrow → fine
            let stages: [[Double]] = [
                [0.10, 0.50, 0.90],                        // Stage 1: wide (3)
                [0.30, 0.70],                               // Stage 2: mid (2)
                [0.20, 0.40, 0.60, 0.80],                  // Stage 3: fill (4)
                [0.05, 0.15, 0.25, 0.35, 0.45,             // Stage 4: fine (9)
                 0.55, 0.65, 0.75, 0.85, 0.95],
            ]

            var attemptCount = 0
            var triedPoints = Set<Int>()  // track tried percentages to avoid duplicates

            for (stage, points) in stages.enumerated() {
                if commonLangs.contains(detectedLang) { break }

                for pct in points {
                    let pctInt = Int(pct * 100)
                    guard !triedPoints.contains(pctInt) else { continue }
                    triedPoints.insert(pctInt)

                    let start = floor(totalDuration * pct)
                    let end = min(start + 30, totalDuration)
                    guard end - start >= 5 else { continue }

                    attemptCount += 1
                    clearJsonFiles(in: tmpDir)

                    let clipStr = "\(Int(start)),\(Int(end))"
                    logDebug("Language detection stage \(stage + 1), attempt \(attemptCount): \(clipStr) (\(pctInt)%)")

                    DispatchQueue.main.async {
                        self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 언어 감지 중... (\(pctInt)%)"
                    }

                    _ = run(mlxWhisper, arguments: [
                        url.path,
                        "--model", options.model,
                        "--output-format", "json",
                        "--output-dir", tmpDir,
                        "--clip-timestamps", clipStr,
                    ], environment: ["PYTHONUNBUFFERED": "1"]) { line in
                        if line.contains("Detected language:") {
                            let lang = line.components(separatedBy: "Detected language:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            DispatchQueue.main.async {
                                self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 언어 감지: \(lang) (\(pctInt)%)"
                            }
                        }
                    }

                    if let detectJsonPath = findJsonFile(in: tmpDir),
                       let jsonData = try? Data(contentsOf: URL(fileURLWithPath: detectJsonPath)),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let lang = json["language"] as? String {

                        let segs = json["segments"] as? [[String: Any]] ?? []
                        let avgNoSpeech = segs.compactMap { $0["no_speech_prob"] as? Double }
                            .reduce(0, +) / max(Double(segs.count), 1)

                        if avgNoSpeech > 0.7 {
                            logDebug("  no_speech_prob=\(String(format: "%.2f", avgNoSpeech)), skipping (no speech)")
                            continue
                        }

                        detectedLang = lang
                        logDebug("  detected: \(lang), no_speech=\(String(format: "%.2f", avgNoSpeech))")

                        if commonLangs.contains(lang) {
                            break
                        }
                        logDebug("  uncommon language, continuing...")
                    }
                }
            }
            logDebug("Language detection finished after \(attemptCount) attempts")

            if !commonLangs.contains(detectedLang) {
                // Retry with system language
                let systemLang = String(Locale.current.language.languageCode?.identifier.prefix(2) ?? "")
                if commonLangs.contains(systemLang) {
                    logDebug("Falling back to system language: \(systemLang)")
                    detectedLang = systemLang
                } else {
                    logDebug("All attempts returned uncommon language '\(detectedLang)', skipping")
                    return .failed(error: "감지 불가 - 언어를 지정해주세요")
                }
            }

            clearJsonFiles(in: tmpDir)
            logDebug("Final detected language: \(detectedLang)")
        }

        // Step 1b: Generate json with mlx_whisper (language locked)
        DispatchQueue.main.async {
            self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 음성 인식 중..."
            self.fileProgress = 0
        }

        let sens = options.sensitivity
        var whisperArgs = [
            url.path,
            "--model", options.model,
            "--output-format", "json",
            "--output-dir", tmpDir,
            "--condition-on-previous-text", sens.conditionOnPreviousText ? "True" : "False",
            "--word-timestamps", "True",
            "--max-line-width", "20",
            "--max-line-count", "1",
            "--logprob-threshold", String(sens.logprobThreshold),
            "--compression-ratio-threshold", String(sens.compressionRatioThreshold),
            "--suppress-tokens", "",
            "--no-speech-threshold", String(sens.noSpeechThreshold),
            "--best-of", String(sens.bestOf),
        ]
        if sens.hallucinationSilenceThreshold > 0 {
            whisperArgs += ["--hallucination-silence-threshold", String(sens.hallucinationSilenceThreshold)]
        }
        if !detectedLang.isEmpty {
            whisperArgs += ["--language", detectedLang]
        }

        let (_, whisperExit) = run(mlxWhisper, arguments: whisperArgs, environment: ["PYTHONUNBUFFERED": "1"]) { line in
            if let match = line.range(of: #"\d{2}:\d{2}\.\d{3} --> (\d{2}:\d{2}\.\d{3})"#, options: .regularExpression) {
                let endTimeStr = String(line[match]).components(separatedBy: " --> ").last ?? ""
                let endSeconds = self.parseSrtTimestamp(endTimeStr)
                let text = line.components(separatedBy: "] ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    if totalDuration > 0 {
                        self.fileProgress = min(endSeconds / totalDuration, 1.0)
                    }
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
            if shouldCancel || whisperExit == 15 {
                logDebug("whisper cancelled by user")
                return .pending
            }
            logDebug("whisper failed")
            return .failed(error: "음성 인식 실패 (exit: \(whisperExit))")
        }

        guard let jsonPath = findJsonFile(in: tmpDir) else {
            logDebug("json path not found")
            return .failed(error: "JSON 파일 없음")
        }
        logDebug("json path: \(jsonPath)")

        // Step 2: Parse json and generate srt
        let language = detectedLang.isEmpty ? "und" : detectedLang
        logDebug("Using language: \(language)")

        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else {
            logDebug("Failed to read json file")
            return .failed(error: "JSON 읽기 실패")
        }

        logDebug("JSON data size: \(jsonData.count)")

        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            let preview = String(data: jsonData.prefix(200), encoding: .utf8) ?? "nil"
            logDebug("Failed to parse json, preview: \(preview)")
            return .failed(error: "JSON 파싱 실패")
        }
        guard let segments = json["segments"] as? [[String: Any]] else {
            logDebug("No segments in json, keys: \(json.keys)")
            return .failed(error: "세그먼트 없음")
        }
        logDebug("Parsed \(segments.count) segments")

        let srtContent = generateSrt(from: segments, delay: options.subtitleDelay)
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

        // Step 4: Translate
        let hasAuth: Bool = {
            switch options.authMethod {
            case .claudeCode: return true
            case .claudeApiKey: return !options.claudeApiKey.isEmpty
            case .openaiApiKey: return !options.openaiApiKey.isEmpty
            }
        }()
        if !options.translationTargets.isEmpty && hasAuth {
            let currentLangs = getExistingSubtitleLanguages(url: url)
            let filteredTargets = Array(options.translationTargets.filter { target in
                let code3 = langCode3(target.rawValue)
                if currentLangs.contains(code3) {
                    logDebug("Skipping translation to \(target.rawValue): already exists as \(code3)")
                    return false
                }
                return true
            })

            if !filteredTargets.isEmpty {
                DispatchQueue.main.async {
                    self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 번역 중 (\(filteredTargets.count)개 언어)..."
                }

                let translator = TranslationEngine(authMethod: options.authMethod, translationModel: options.translationModel, claudeApiKey: options.claudeApiKey, openaiApiKey: options.openaiApiKey)
                let translations = translator.translateSrt(
                    srtContent: srtContent,
                    sourceLang: language,
                    targetLangs: filteredTargets
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
        }

        // Step 5: Remove srt if not keeping
        if !options.keepSrtFile {
            try? fm.removeItem(atPath: srtPath)
        }

        return .completed(lang: language)
    }

    private func calculateEta() -> String {
        guard fileProgress > 0.05 else { return "" }
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

    private func getExistingSubtitleLanguages(url: URL) -> Set<String> {
        guard let ffprobe = findBinary("ffprobe") else { return [] }
        let (output, exitCode) = run(ffprobe, arguments: [
            "-v", "quiet",
            "-select_streams", "s",
            "-show_entries", "stream_tags=language",
            "-of", "csv=p=0",
            url.path,
        ])
        guard exitCode == 0 else { return [] }
        let langs = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(langs)
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
        let parts = str.components(separatedBy: ":")
        guard parts.count == 2 else { return 0 }
        let minutes = Double(parts[0]) ?? 0
        let seconds = Double(parts[1]) ?? 0
        return minutes * 60 + seconds
    }

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

    /// Detect repetitive text like "ああああ", "うっ、うっ、うっ", "ダメダメダメ"
    func isRepetitive(_ text: String) -> Bool {
        let cleaned = text.replacingOccurrences(of: "、", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard cleaned.count >= 4 else { return false }

        // Check single character repeat: ああああ
        let uniqueChars = Set(cleaned)
        if uniqueChars.count == 1 { return true }

        // Check short pattern repeat: try patterns of length 1~6
        for len in 1...min(6, cleaned.count / 2) {
            let pattern = String(cleaned.prefix(len))
            let repeatCount = cleaned.count / len
            guard repeatCount >= 3 && cleaned.count % len == 0 else { continue }
            let repeated = String(repeating: pattern, count: repeatCount)
            if repeated == cleaned {
                return true
            }
        }

        // Check comma-separated repeats: うっ、うっ、うっ
        let parts = text.components(separatedBy: "、").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            let unique = Set(parts.filter { !$0.isEmpty })
            if unique.count == 1 { return true }
        }

        return false
    }

    func generateSrt(from segments: [[String: Any]], delay: Double = 0) -> String {
        struct SrtEntry {
            var start: Double
            var end: Double
            var text: String
        }

        var entries: [SrtEntry] = []
        for seg in segments {
            guard let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double,
                  let text = seg["text"] as? String else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if isRepetitive(trimmed) { continue }

            if let last = entries.last, last.text == trimmed {
                entries[entries.count - 1].end = end
            } else {
                entries.append(SrtEntry(start: start, end: end, text: trimmed))
            }
        }

        var lines: [String] = []
        for (i, entry) in entries.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(formatSrtTime(max(0, entry.start + delay))) --> \(formatSrtTime(max(0, entry.end + delay)))")
            lines.append(entry.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func findJsonFile(in directory: String) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory),
              let jsonFile = files.first(where: { $0.hasSuffix(".json") }) else { return nil }
        return "\(directory)/\(jsonFile)"
    }

    private func clearJsonFiles(in directory: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for file in files where file.hasSuffix(".json") {
            try? FileManager.default.removeItem(atPath: "\(directory)/\(file)")
        }
    }

    func formatSrtTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let h = Int(clamped) / 3600
        let m = (Int(clamped) % 3600) / 60
        let s = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s).replacingOccurrences(of: ".", with: ",")
    }
}
