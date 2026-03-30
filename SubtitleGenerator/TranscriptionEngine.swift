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
        didSet { updateOverallProgress() }
    }
    @Published var overallProgress: Double = 0 {
        didSet { updateDockProgress() }
    }
    var onFileProgressUpdate: ((Int, Double) -> Void)?
    @Published var eta = ""
    private var shouldCancel = false
    private let processLock = NSLock()
    private var _currentProcess: Process?
    private var currentProcess: Process? {
        get { processLock.lock(); defer { processLock.unlock() }; return _currentProcess }
        set { processLock.lock(); defer { processLock.unlock() }; _currentProcess = newValue }
    }
    private var fileStartTime: Date = Date()
    private var totalStartTime: Date = Date()
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
                self.dockProgressView?.progress = self.overallProgress
                dockTile.display()
            } else {
                self.dockProgressView = nil
                dockTile.contentView = nil
                dockTile.badgeLabel = nil
                dockTile.display()
            }
        }
    }

    private func updateOverallProgress() {
        guard totalFileCount > 0 else { return }
        let completedFiles = Double(currentIndex)
        overallProgress = (completedFiles + fileProgress) / Double(totalFileCount)
        onFileProgressUpdate?(currentIndex, fileProgress)
    }

    private func bounceIcon() {
        DispatchQueue.main.async {
            NSApp.requestUserAttention(.criticalRequest)
            NSSound(named: .init("Glass"))?.play()
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
        onFileUpdate: @escaping (Int, FileStatus, TimeInterval?) -> Void,
        onFileProgress: @escaping (Int, Double) -> Void,
        onTranslationComplete: @escaping (Int, String) -> Void
    ) {
        shouldCancel = false

        logDebug("Starting process, model: \(options.model)")
        guard let whisperCli = findBinary("whisper-cli") else {
            logDebug("whisper-cli not found")
            DispatchQueue.main.async {
                self.currentStatus = "whisper-cli를 찾을 수 없습니다"
                self.isProcessing = false
            }
            return
        }
        guard let ffmpeg = findBinary("ffmpeg") else {
            logDebug("ffmpeg not found")
            DispatchQueue.main.async {
                self.currentStatus = "ffmpeg를 찾을 수 없습니다"
                self.isProcessing = false
            }
            return
        }
        let ffmpegPath: String? = ffmpeg  // for optional usage later

        DispatchQueue.main.async {
            self.isProcessing = true
            self.currentIndex = 0
            self.totalStartTime = Date()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var processedAny = true
            let translationGroup = DispatchGroup()

            while processedAny && !self.shouldCancel {
                processedAny = false

                var currentFiles: [FileItem] = []
                DispatchQueue.main.sync {
                    currentFiles = getFiles()
                    self.totalFileCount = currentFiles.count
                }
                let hasAuth: Bool = {
                    switch options.authMethod {
                    case .claudeCode: return true
                    case .claudeApiKey: return !options.claudeApiKey.isEmpty
                    case .openaiApiKey: return !options.openaiApiKey.isEmpty
                    }
                }()
                let needsTranslation = !options.translationTargets.isEmpty && hasAuth

                for (i, file) in currentFiles.enumerated() {
                    if self.shouldCancel { break }

                    switch file.status {
                    case .completed, .skipped, .failed, .processing, .translating:
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
                        whisperCli: whisperCli,
                        ffmpeg: ffmpegPath,
                        options: options
                    )
                    let elapsed = Date().timeIntervalSince(fileStart)

                    // Determine language for translation
                    var translationLang: String?
                    if case .completed(let lang) = result {
                        translationLang = lang
                    } else if result == .skipped {
                        // Find existing srt language for skipped files
                        translationLang = self.findExistingSrtLanguage(file: file)
                    }

                    // Launch translation in background
                    if needsTranslation, let lang = translationLang {
                        DispatchQueue.main.async {
                            if result == .skipped {
                                onFileUpdate(i, .translating(lang: lang), elapsed)
                            } else {
                                onFileUpdate(i, .translating(lang: lang), elapsed)
                            }
                        }

                        let fileForTranslation = file
                        let fileIndex = i
                        let finalStatus = result
                        translationGroup.enter()
                        DispatchQueue.global(qos: .utility).async {
                            self.translateFile(
                                file: fileForTranslation,
                                language: lang,
                                options: options,
                                onStatusUpdate: { progress in
                                    DispatchQueue.main.async {
                                        onFileUpdate(fileIndex, .translating(lang: progress), nil)
                                    }
                                },
                                onLangComplete: { completedLang in
                                    DispatchQueue.main.async {
                                        onTranslationComplete(fileIndex, completedLang)
                                    }
                                }
                            )
                            DispatchQueue.main.async {
                                if case .completed(let l) = finalStatus {
                                    onFileUpdate(fileIndex, .completed(lang: l), nil)
                                } else {
                                    onFileUpdate(fileIndex, .completed(lang: lang), nil)
                                }
                            }
                            translationGroup.leave()
                        }
                    } else {
                        DispatchQueue.main.async {
                            onFileUpdate(i, result, elapsed)
                        }
                    }
                }
            }

            // Wait for all background translations to finish
            translationGroup.wait()

            DispatchQueue.main.async {
                self.currentIndex = self.totalFileCount
                self.currentStatus = self.shouldCancel ? "중단됨" : "완료"
                self.isProcessing = false
                self.fileProgress = 0
                self.overallProgress = 0
                if !self.shouldCancel {
                    self.bounceIcon()
                    self.sendCompletionNotification(getFiles: getFiles)
                }
            }
        }
    }

    /// Translate a file's SRT in the background. Returns updated status.
    private func translateFile(
        file: FileItem,
        language: String,
        options: Options,
        onStatusUpdate: @escaping (String) -> Void,
        onLangComplete: @escaping (String) -> Void
    ) {
        let url = file.url
        let dir = url.deletingLastPathComponent().path
        let nameNoExt = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let ffmpeg = findBinary("ffmpeg")

        let srtPath = "\(dir)/\(nameNoExt).\(language).srt"
        guard let srtContent = try? String(contentsOfFile: srtPath, encoding: .utf8) else {
            logDebug("Translation: SRT file not found at \(srtPath)")
            return
        }

        // Check existing subtitle tracks + srt files
        let existingTracks = getExistingSubtitleLanguages(url: url)
        let existingSrts: Set<String> = {
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            return Set(files.filter { $0.hasPrefix(nameNoExt) && $0.hasSuffix(".srt") }
                .compactMap { name -> String? in
                    let parts = name.dropFirst(nameNoExt.count + 1).dropLast(4)  // remove "name." and ".srt"
                    return parts.isEmpty ? nil : String(parts)
                })
        }()

        let filteredTargets = Array(options.translationTargets.filter { target in
            let code2 = target.rawValue
            let code3 = langCode3(code2)
            if existingTracks.contains(code3) || existingSrts.contains(code2) {
                logDebug("Skipping translation to \(code2): already exists")
                return false
            }
            return true
        })

        guard !filteredTargets.isEmpty else {
            logDebug("All translation targets already exist")
            return
        }

        onStatusUpdate("번역 중 (\(filteredTargets.count)개 언어)...")

        let translator = TranslationEngine(authMethod: options.authMethod, translationModel: options.translationModel, claudeApiKey: options.claudeApiKey, openaiApiKey: options.openaiApiKey)
        let translations = translator.translateSrt(
            srtContent: srtContent,
            sourceLang: language,
            targetLangs: filteredTargets
        ) { progress in
            onStatusUpdate(progress)
        }

        for (lang, translatedSrt) in translations {
            let translatedPath = "\(dir)/\(nameNoExt).\(lang.rawValue).srt"
            try? translatedSrt.write(toFile: translatedPath, atomically: true, encoding: .utf8)

            // Embed into video if option is set
            if options.embedSubtitle, let ffmpeg = ffmpeg {
                let tmpOutput = "\(dir)/.\(nameNoExt)_trans_sub.\(url.pathExtension)"
                let args = [
                    "-y", "-i", url.path,
                    "-i", translatedPath,
                    "-map", "0", "-map", "1:0",
                    "-c", "copy", "-c:s", "mov_text",
                    "-metadata:s:s:\(self.countSubtitleTracks(url: url))", "language=\(langCode3(lang.rawValue))",
                    tmpOutput,
                ]
                logDebug("Translation embed ffmpeg: \(args.joined(separator: " "))")
                let (_, exitCode) = run(ffmpeg, arguments: args)
                if exitCode == 0 {
                    try? fm.removeItem(atPath: url.path)
                    try? fm.moveItem(atPath: tmpOutput, toPath: url.path)
                } else {
                    try? fm.removeItem(atPath: tmpOutput)
                }
            }

            // Clean up srt if not keeping
            if !options.keepSrtFile {
                try? fm.removeItem(atPath: translatedPath)
            }

            onLangComplete(lang.rawValue)
        }

        // Clean up source srt if not keeping
        if !options.keepSrtFile {
            try? fm.removeItem(atPath: srtPath)
        }
    }

    /// Find the language of an existing srt file or subtitle track for a file
    private func findExistingSrtLanguage(file: FileItem) -> String? {
        let url = file.url
        let dir = url.deletingLastPathComponent().path
        let nameNoExt = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        // Check srt files: "name.ja.srt" → "ja"
        if let contents = try? fm.contentsOfDirectory(atPath: dir) {
            for f in contents where f.hasPrefix(nameNoExt) && f.hasSuffix(".srt") {
                let middle = f.dropFirst(nameNoExt.count + 1).dropLast(4) // remove "name." and ".srt"
                if !middle.isEmpty && middle.count <= 3 {
                    return String(middle)
                }
            }
        }

        // Check video subtitle tracks
        let tracks = getExistingSubtitleLanguages(url: url)
        // Convert ISO 639-2 back to 639-1
        let reverseMap = langMap.reduce(into: [String: String]()) { $0[$1.value] = $1.key }
        for track in tracks {
            if let code2 = reverseMap[track] {
                return code2
            }
            return track // use as-is if no reverse mapping
        }

        return nil
    }

    private func countSubtitleTracks(url: URL) -> Int {
        guard let ffprobe = findBinary("ffprobe") else { return 0 }
        let (output, exitCode) = run(ffprobe, arguments: [
            "-v", "quiet",
            "-select_streams", "s",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            url.path,
        ])
        guard exitCode == 0 else { return 0 }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }.count
    }

    private func transcribeFile(file: FileItem, whisperCli: String, ffmpeg: String?, options: Options) -> FileStatus {
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

        // Step 0: Convert to wav (whisper-cli requires wav input)
        DispatchQueue.main.async {
            self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 오디오 변환 중..."
            self.fileProgress = 0
        }

        let wavPath = "\(tmpDir)/audio.wav"
        if let ffmpeg = ffmpeg {
            let (_, wavExit) = run(ffmpeg, arguments: [
                "-y", "-i", url.path,
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                wavPath,
            ])
            guard wavExit == 0 else {
                logDebug("wav conversion failed")
                return .failed(error: "오디오 변환 실패")
            }
        }

        // Step 1a: Detect language if auto
        let commonLangs: Set<String> = ["ja", "ko", "en", "zh", "fr", "de", "es", "it", "pt", "ru",
                                         "ar", "hi", "th", "vi", "id", "tr", "pl", "nl"]
        var detectedLang = options.language
        if detectedLang.isEmpty {
            DispatchQueue.main.async {
                self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 언어 감지 중..."
                self.fileProgress = 0
            }

            // Use whisper-cli --detect-language with clips
            let stages: [[Double]] = [
                [0.10, 0.50, 0.90],
                [0.30, 0.70],
                [0.20, 0.40, 0.60, 0.80],
                [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95],
            ]

            var attemptCount = 0
            var triedPoints = Set<Int>()

            for (stage, points) in stages.enumerated() {
                if commonLangs.contains(detectedLang) { break }

                for pct in points {
                    let pctInt = Int(pct * 100)
                    guard !triedPoints.contains(pctInt) else { continue }
                    triedPoints.insert(pctInt)

                    let startMs = Int(totalDuration * pct * 1000)
                    let durationMs = min(30000, Int((totalDuration - totalDuration * pct) * 1000))
                    guard durationMs >= 5000 else { continue }

                    attemptCount += 1
                    logDebug("Language detection stage \(stage + 1), attempt \(attemptCount): \(pctInt)%")

                    DispatchQueue.main.async {
                        self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 언어 감지 중... (\(pctInt)%)"
                    }

                    let (detectOutput, _) = run(whisperCli, arguments: [
                        "-m", options.model,
                        "-f", wavPath,
                        "--offset-t", String(startMs),
                        "--duration", String(durationMs),
                        "-dl",  // detect-language mode
                    ])

                    // Parse: "whisper_full: auto-detected language: ja (p = 0.95)"
                    if let match = detectOutput.range(of: #"auto-detected language: (\w+)"#, options: .regularExpression) {
                        let langStr = String(detectOutput[match]).components(separatedBy: ": ").last ?? ""
                        detectedLang = langStr
                        logDebug("  detected: \(langStr)")

                        if commonLangs.contains(langStr) {
                            DispatchQueue.main.async {
                                self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 언어 감지: \(langStr) (\(pctInt)%)"
                            }
                            break
                        }
                        logDebug("  uncommon language, continuing...")
                    }
                }
            }
            logDebug("Language detection finished after \(attemptCount) attempts")

            if !commonLangs.contains(detectedLang) {
                let systemLang = String(Locale.current.language.languageCode?.identifier.prefix(2) ?? "")
                if commonLangs.contains(systemLang) {
                    logDebug("Falling back to system language: \(systemLang)")
                    detectedLang = systemLang
                } else {
                    logDebug("All attempts returned uncommon language '\(detectedLang)', skipping")
                    return .failed(error: "감지 불가 - 언어를 지정해주세요")
                }
            }
            logDebug("Final detected language: \(detectedLang)")
        }

        // Step 1b: Transcribe with whisper-cli
        DispatchQueue.main.async {
            self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) 음성 인식 중..."
            self.fileProgress = 0
        }

        let sens = options.sensitivity
        let outputBase = "\(tmpDir)/output"
        var whisperArgs = [
            "-m", options.model,
            "-f", wavPath,
            "-l", detectedLang.isEmpty ? "auto" : detectedLang,
            "-t", "10",
            "--beam-size", String(sens.beamSize),
            "--best-of", String(sens.bestOf),
            "--no-speech-thold", String(sens.noSpeechThreshold),
            "--logprob-thold", String(sens.logprobThreshold),
            "--entropy-thold", String(sens.entropyThreshold),
            "--output-srt",
            "--output-json",
            "-of", outputBase,
        ]

        let (_, whisperExit) = run(whisperCli, arguments: whisperArgs) { line in
            // Parse whisper-cli output: [00:01:30.000 --> 00:01:35.000] text
            if let match = line.range(of: #"\[(\d{2}:\d{2}:\d{2}\.\d{3}) --> (\d{2}:\d{2}:\d{2}\.\d{3})\]"#, options: .regularExpression) {
                let timeStr = String(line[match])
                // Extract end time: HH:MM:SS.mmm
                if let endRange = timeStr.range(of: #"\d{2}:\d{2}:\d{2}\.\d{3}\]$"#, options: .regularExpression) {
                    let endStr = String(timeStr[endRange]).dropLast()  // remove ]
                    let parts = endStr.components(separatedBy: ":")
                    if parts.count == 3 {
                        let hours = Double(parts[0]) ?? 0
                        let mins = Double(parts[1]) ?? 0
                        let secs = Double(parts[2]) ?? 0
                        let endSeconds = hours * 3600 + mins * 60 + secs
                        let text = line.components(separatedBy: "]").last?.trimmingCharacters(in: .whitespaces) ?? ""

                        DispatchQueue.main.async {
                            if totalDuration > 0 {
                                self.fileProgress = min(endSeconds / totalDuration, 1.0)
                            }
                            self.eta = self.calculateOverallEta()
                            self.currentStatus = "\(self.currentIndex + 1)/\(self.totalFileCount) \(Int(self.fileProgress * 100))% \(text)"
                        }
                    }
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

        // Step 2: Read whisper-cli output and apply post-processing
        let language = detectedLang.isEmpty ? "und" : detectedLang
        logDebug("Using language: \(language)")

        let jsonPath = "\(outputBase).json"
        guard fm.fileExists(atPath: jsonPath) else {
            logDebug("json not found at \(jsonPath)")
            return .failed(error: "JSON 파일 없음")
        }

        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else {
            logDebug("Failed to read json file")
            return .failed(error: "JSON 읽기 실패")
        }

        logDebug("JSON data size: \(jsonData.count)")

        // whisper-cli JSON uses "transcription" array
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                logDebug("JSON is not a dictionary")
                return .failed(error: "JSON 형식 오류")
            }
            json = parsed
        } catch {
            let preview = String(data: jsonData.prefix(200), encoding: .utf8) ?? "nil"
            let tail = String(data: jsonData.suffix(100), encoding: .utf8) ?? "nil"
            logDebug("Failed to parse json: \(error.localizedDescription)")
            logDebug("Preview: \(preview)")
            logDebug("Tail: \(tail)")
            return .failed(error: "JSON 파싱 실패")
        }

        // whisper-cli JSON format: {"transcription": [{"timestamps": {"from": "...", "to": "..."}, "text": "..."}]}
        let segments: [[String: Any]]
        if let transcription = json["transcription"] as? [[String: Any]] {
            // Convert whisper-cli format to common format
            segments = transcription.compactMap { entry -> [String: Any]? in
                guard let timestamps = entry["timestamps"] as? [String: String],
                      let fromStr = timestamps["from"],
                      let toStr = timestamps["to"],
                      let text = entry["text"] as? String else { return nil }
                let start = parseTimestamp(fromStr)
                let end = parseTimestamp(toStr)
                return ["start": start, "end": end, "text": text,
                        "no_speech_prob": entry["no_speech_prob"] as? Double ?? 0]
            }
        } else if let segs = json["segments"] as? [[String: Any]] {
            segments = segs
        } else {
            logDebug("No segments/transcription in json")
            return .failed(error: "세그먼트 없음")
        }
        logDebug("Parsed \(segments.count) segments")

        let srtContent = generateSrt(from: segments, delay: options.subtitleDelay, totalDuration: totalDuration)
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

        // Step 4: Remove srt if not keeping (and no translation needed)
        let hasAuth: Bool = {
            switch options.authMethod {
            case .claudeCode: return true
            case .claudeApiKey: return !options.claudeApiKey.isEmpty
            case .openaiApiKey: return !options.openaiApiKey.isEmpty
            }
        }()
        let needsTranslation = !options.translationTargets.isEmpty && hasAuth
        if !options.keepSrtFile && !needsTranslation {
            try? fm.removeItem(atPath: srtPath)
        }

        return .completed(lang: language)
    }

    /// File-level ETA based on current file progress
    func calculateFileEta() -> String {
        guard fileProgress > 0.05 else { return "" }
        let elapsed = Date().timeIntervalSince(fileStartTime)
        let remaining = (elapsed / fileProgress) - elapsed
        guard remaining > 0 else { return "" }
        return formatEta(remaining)
    }

    /// Overall ETA based on total progress across all files
    func calculateOverallEta() -> String {
        guard overallProgress > 0.02 else { return "" }
        let elapsed = Date().timeIntervalSince(totalStartTime)
        let remaining = (elapsed / overallProgress) - elapsed
        guard remaining > 0 else { return "" }
        return formatEta(remaining)
    }

    private func formatEta(_ remaining: Double) -> String {
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        if mins > 0 {
            return "약 \(mins)분 \(secs)초"
        } else {
            return "약 \(secs)초"
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

    /// Parse "HH:MM:SS.mmm" timestamp from whisper-cli JSON
    private func parseTimestamp(_ str: String) -> Double {
        let parts = str.components(separatedBy: ":")
        guard parts.count == 3 else { return 0 }
        let hours = Double(parts[0]) ?? 0
        let mins = Double(parts[1]) ?? 0
        let secs = Double(parts[2]) ?? 0
        return hours * 3600 + mins * 60 + secs
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

    // MARK: - Post-processing filters

    /// Known whisper hallucination phrases
    private let hallucinationBlacklist: Set<String> = [
        // Japanese
        "ご視聴ありがとうございました", "ご視聴ありがとうございます",
        "チャンネル登録お願いします", "チャンネル登録よろしくお願いします",
        "高評価お願いします", "コメントお願いします",
        "次の動画でお会いしましょう", "また次の動画で",
        "おやすみなさい", "お疲れ様でした",
        "字幕は自動生成されています", "字幕の翻訳",
        // English
        "thank you for watching", "thanks for watching",
        "please subscribe", "please like and subscribe",
        "see you in the next video", "see you next time",
        "subtitles by", "subtitles created by",
        "translated by", "captions by",
        // Korean
        "시청해 주셔서 감사합니다", "구독과 좋아요 부탁드립니다",
    ]

    /// Detect repetitive text like "ああああ", "うっ、うっ、うっ", "ダメダメダメ", "はぁっはぁっはぁっ"
    func isRepetitive(_ text: String) -> Bool {
        let cleaned = text.replacingOccurrences(of: "、", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "「", with: "")
            .replacingOccurrences(of: "」", with: "")

        guard cleaned.count >= 4 else { return false }

        // Few unique chars in long text: うっうううう..., ああああ
        let uniqueChars = Set(cleaned)
        if uniqueChars.count == 1 { return true }
        if uniqueChars.count <= 4 && cleaned.count >= 12 { return true }

        // Short pattern repeat (1~10 chars): ダメダメダメ, はぁっはぁっはぁっ
        for len in 1...min(10, cleaned.count / 2) {
            let pattern = String(cleaned.prefix(len))
            let repeatCount = cleaned.count / len
            guard repeatCount >= 3 else { continue }
            // Exact match or nearly exact (allow partial trailing)
            let repeated = String(repeating: pattern, count: repeatCount)
            if cleaned.hasPrefix(repeated) {
                return true
            }
        }

        // Comma-separated repeats: うっ、うっ、うっ or 「あ、いけ、いけ、いけ
        let parts = text.components(separatedBy: "、").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            let nonEmpty = parts.filter { !$0.isEmpty }
            let unique = Set(nonEmpty)
            // Allow 1-2 unique tokens if majority is the same
            if unique.count <= 2 {
                let mostCommon = unique.max(by: { a, b in nonEmpty.filter { $0 == a }.count < nonEmpty.filter { $0 == b }.count })!
                let ratio = Double(nonEmpty.filter { $0 == mostCommon }.count) / Double(nonEmpty.count)
                if ratio >= 0.7 { return true }
            }
        }

        return false
    }

    /// Check if text is only punctuation/symbols with no meaningful content
    func isPunctuationOnly(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: "[\\p{P}\\p{S}\\s]", with: "", options: .regularExpression)
        return stripped.isEmpty
    }

    /// Check if text is a known hallucination phrase
    func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return hallucinationBlacklist.contains { lower.contains($0.lowercased()) }
    }

    /// Check if text density is suspiciously high (chars per second)
    func isOverDense(text: String, duration: Double) -> Bool {
        guard duration > 0 else { return true }
        let charsPerSecond = Double(text.count) / duration
        return charsPerSecond > 25  // ~25 chars/sec is extreme even for fast Japanese
    }

    func generateSrt(from segments: [[String: Any]], delay: Double = 0, totalDuration: Double = 0) -> String {
        struct SrtEntry {
            var start: Double
            var end: Double
            var text: String
        }

        let minDuration = 0.3  // minimum segment duration in seconds

        var entries: [SrtEntry] = []
        for seg in segments {
            guard let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double,
                  let text = seg["text"] as? String else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let duration = end - start

            // Filter 1: Too short segments (likely noise)
            if duration < minDuration { continue }

            // Filter 2: Repetitive text patterns
            if isRepetitive(trimmed) { continue }

            // Filter 3: Punctuation/symbols only
            if isPunctuationOnly(trimmed) { continue }

            // Filter 4: Known hallucination phrases
            if isHallucination(trimmed) { continue }

            // Filter 5: Suspiciously dense text (hallucination indicator)
            if isOverDense(text: trimmed, duration: duration) { continue }

            // Filter 6: End-of-video hallucination (last 30s, high no_speech_prob)
            if totalDuration > 0 && start > totalDuration - 30 {
                let noSpeechProb = seg["no_speech_prob"] as? Double ?? 0
                if noSpeechProb > 0.5 { continue }
            }

            // Merge consecutive duplicates
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
