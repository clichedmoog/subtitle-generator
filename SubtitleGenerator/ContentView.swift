import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var files: [FileItem] = []
    @State private var selectedModel: WhisperModel = .largev3
    @State private var outputMode: OutputMode = .embedInVideo
    @State private var language: Language = .auto
    @State private var sensitivity: Sensitivity = .normal
    @State private var selectedTranslations: Set<TranslationLanguage> = []
    @State private var authMethod: AuthMethod = .claudeCode
    @State private var translationModel: TranslationModel = .claudeSonnet
    @State private var claudeApiKey: String = ""
    @State private var openaiApiKey: String = ""
    @State private var isAuthVerified = false
    @State private var isVerifying = false
    @State private var subtitleDelay: SubtitleDelay = .normal
    @StateObject private var toolChecker = ToolChecker()
    @StateObject private var engine = TranscriptionEngine()

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            if !toolChecker.allInstalled {
                toolStatusSection
                Divider()
            }

            fileListSection

            Divider()

            optionsSection

            Divider()

            actionSection
        }
        .frame(width: 780, height: toolChecker.allInstalled ? 720 : 820)
        .onAppear {
            toolChecker.checkAll()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 28))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("자막 생성기")
                    .font(.title2.bold())
                Text("AI 음성인식으로 자막을 자동 생성합니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Tool Status

    private var toolStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                Text("필요한 도구")
                    .font(.headline)
            }

            ForEach(toolChecker.tools) { tool in
                ToolRowView(tool: tool) {
                    toolChecker.install(tool)
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.03))
    }

    // MARK: - File List

    private var fileListSection: some View {
        VStack(spacing: 0) {
            if files.isEmpty {
                dropZone
            } else {
                fileList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("영상 또는 음성 파일을 여기에 드롭하세요")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("MP4, MOV, MKV, M4V, M4A, WAV, MP3")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("파일 선택...") {
                openFilePicker()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                .foregroundStyle(.quaternary)
                .padding(16)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(files.count)개 파일")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    openFilePicker()
                } label: {
                    Label("추가", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(engine.isProcessing)

                Button {
                    files.removeAll()
                } label: {
                    Label("전체 삭제", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(engine.isProcessing)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            List {
                ForEach(files) { file in
                    FileRowView(file: file)
                }
                .onDelete { indexSet in
                    if !engine.isProcessing {
                        files.remove(atOffsets: indexSet)
                    }
                }
            }
            .listStyle(.inset)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        DisclosureGroup("옵션") {
            HStack(alignment: .top, spacing: 0) {
                // Left: 자막 생성 옵션
                VStack(alignment: .leading, spacing: 12) {
                    Text("자막 생성")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)

                    optionRow("모델") {
                        Picker("", selection: $selectedModel) {
                            ForEach(WhisperModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    optionRow("출력") {
                        Picker("", selection: $outputMode) {
                            ForEach(OutputMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    optionRow("언어") {
                        Picker("", selection: $language) {
                            ForEach(Language.allCases) { lang in
                                Text(lang.label).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    optionRow("감도") {
                        Picker("", selection: $sensitivity) {
                            ForEach(Sensitivity.allCases) { s in
                                Text(s.label).tag(s)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                    }

                    optionRow("딜레이") {
                        Picker("", selection: $subtitleDelay) {
                            ForEach(SubtitleDelay.allCases) { delay in
                                Text(delay.label).tag(delay)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .padding(.horizontal, 8)

                // Right: 번역 옵션
                VStack(alignment: .leading, spacing: 12) {
                    Text("번역")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)

                    optionRow("인증") {
                        Picker("", selection: $authMethod) {
                            ForEach(AuthMethod.allCases) { method in
                                Text(method.label).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: authMethod) { _, newValue in
                            isAuthVerified = false
                            selectedTranslations.removeAll()
                            let models = TranslationModel.models(for: newValue)
                            if !models.contains(translationModel) {
                                translationModel = models.first!
                            }
                        }
                    }

                    optionRow("모델") {
                        Picker("", selection: $translationModel) {
                            ForEach(TranslationModel.models(for: authMethod)) { model in
                                Text(model.label).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    optionRow("") {
                        VStack(alignment: .leading, spacing: 4) {
                            switch authMethod {
                            case .claudeCode:
                                Text("Claude Code 구독 인증을 사용합니다")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            case .claudeApiKey:
                                SecureField("sk-ant-...", text: $claudeApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: claudeApiKey) { _, _ in isAuthVerified = false }
                                Text("console.anthropic.com")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            case .openaiApiKey:
                                SecureField("sk-...", text: $openaiApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: openaiApiKey) { _, _ in isAuthVerified = false }
                                Text("platform.openai.com")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            HStack(spacing: 8) {
                                if isAuthVerified {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("인증됨")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else {
                                    Button {
                                        verifyAuth()
                                    } label: {
                                        if isVerifying {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text("인증 확인")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(currentAuthToken.isEmpty || isVerifying)
                                }
                            }
                        }
                    }

                    if isAuthVerified {
                        Divider()

                        optionRow("언어") {
                            FlowLayout(spacing: 8) {
                                ForEach(TranslationLanguage.allCases) { lang in
                                    Toggle(lang.label, isOn: Binding(
                                        get: { selectedTranslations.contains(lang) },
                                        set: { if $0 { selectedTranslations.insert(lang) } else { selectedTranslations.remove(lang) } }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .font(.body)
                                }
                            }
                        }

                        if !selectedTranslations.isEmpty {
                            Text("\(selectedTranslations.count)개 언어에 병렬 번역")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 62)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(engine.isProcessing)
            .padding(.top, 8)
        }
        .font(.headline)
        .padding()
    }

    private func optionRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
                .font(.body)
            content()
        }
    }

    // MARK: - Action

    private var actionSection: some View {
        HStack {
            if engine.isProcessing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: engine.fileProgress)

                    HStack {
                        Text(engine.currentStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        if !engine.eta.isEmpty {
                            Text(engine.eta)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Button("중단") {
                    engine.cancel()
                }
                .buttonStyle(.bordered)
            } else {
                if !toolChecker.allInstalled {
                    Text("필요한 도구를 먼저 설치해주세요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    startProcessing()
                } label: {
                    Label("자막 생성 시작", systemImage: "play.fill")
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(files.isEmpty || !toolChecker.allInstalled)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .mpeg4Movie, .quickTimeMovie, .movie, .audio,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "m4v") ?? .movie,
            UTType(filenameExtension: "m4a") ?? .audio,
        ]
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !files.contains(where: { $0.url == url }) {
                    files.append(FileItem(url: url))
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                let allowed = ["mp4", "mov", "mkv", "m4v", "m4a", "wav", "mp3"]
                if allowed.contains(ext) {
                    DispatchQueue.main.async {
                        if let existingIndex = files.firstIndex(where: { $0.url == url }) {
                            files[existingIndex].status = .pending
                        } else {
                            files.append(FileItem(url: url))
                        }
                    }
                }
            }
        }
    }

    private var currentAuthToken: String {
        switch authMethod {
        case .claudeCode: return "claude-cli"
        case .claudeApiKey: return claudeApiKey
        case .openaiApiKey: return openaiApiKey
        }
    }

    private func verifyAuth() {
        isVerifying = true
        DispatchQueue.global().async {
            let success = self.testAPICall()
            DispatchQueue.main.async {
                self.isAuthVerified = success
                self.isVerifying = false
            }
        }
    }

    private func testAPICall() -> Bool {
        let translator = TranslationEngine(
            authMethod: authMethod,
            translationModel: translationModel.rawValue,
            claudeApiKey: claudeApiKey,

            openaiApiKey: openaiApiKey
        )
        let result = translator.translateSrt(
            srtContent: "1\n00:00:00,000 --> 00:00:01,000\ntest\n",
            sourceLang: "en",
            targetLangs: [.ko]
        ) { _ in }
        return !result.isEmpty
    }

    private func startProcessing() {
        let options = TranscriptionEngine.Options(
            model: selectedModel.rawValue,
            embedSubtitle: outputMode == .embedInVideo,
            keepSrtFile: outputMode == .srtOnly,
            subtitleDelay: subtitleDelay.seconds,
            noSpeechThreshold: sensitivity.noSpeechThreshold,
            language: language.rawValue,
            translationTargets: selectedTranslations,
            authMethod: authMethod,
            translationModel: translationModel.rawValue,
            claudeApiKey: claudeApiKey,

            openaiApiKey: openaiApiKey
        )
        engine.process(files: files, options: options) { index, status in
            if index < files.count {
                files[index].status = status
            }
        }
    }
}

// MARK: - Tool Checker

class ToolChecker: ObservableObject {
    @Published var tools: [ToolInfo] = []

    var allInstalled: Bool {
        tools.allSatisfy { $0.status == .installed }
    }

    struct ToolInfo: Identifiable {
        let id: String
        let name: String
        let description: String
        let installCommand: String
        var status: ToolStatus = .checking
    }

    enum ToolStatus {
        case checking, installed, notInstalled, installing

        var icon: String {
            switch self {
            case .checking: return "questionmark.circle"
            case .installed: return "checkmark.circle.fill"
            case .notInstalled: return "xmark.circle.fill"
            case .installing: return "arrow.down.circle"
            }
        }

        var color: Color {
            switch self {
            case .checking: return .secondary
            case .installed: return .green
            case .notInstalled: return .red
            case .installing: return .blue
            }
        }
    }

    func checkAll() {
        tools = [
            ToolInfo(id: "mlx_whisper", name: "mlx-whisper", description: "AI 음성인식 (Apple Silicon)", installCommand: "pipx install mlx-whisper"),
            ToolInfo(id: "ffmpeg", name: "ffmpeg", description: "자막 트랙 내장 시 필요", installCommand: "brew install ffmpeg"),
        ]

        for i in tools.indices {
            let tool = tools[i]
            DispatchQueue.global().async {
                let installed = self.isInstalled(tool.id)
                DispatchQueue.main.async {
                    self.tools[i].status = installed ? .installed : .notInstalled
                }
            }
        }
    }

    private func isInstalled(_ id: String) -> Bool {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        let binName: String
        switch id {
        case "ffmpeg": binName = "ffmpeg"
        case "mlx_whisper": binName = "mlx_whisper"
        default: return false
        }
        for path in paths {
            if FileManager.default.fileExists(atPath: "\(path)/\(binName)") {
                return true
            }
        }
        return false
    }

    func install(_ tool: ToolInfo) {
        guard let index = tools.firstIndex(where: { $0.id == tool.id }) else { return }
        tools[index].status = .installing

        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH && \(tool.installCommand)"]
            process.environment = ProcessInfo.processInfo.environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try? process.run()
            process.waitUntilExit()

            let success = process.terminationStatus == 0

            DispatchQueue.main.async {
                self.tools[index].status = success ? .installed : .notInstalled
                if success {
                    self.objectWillChange.send()
                }
            }
        }
    }
}

// MARK: - Tool Row

struct ToolRowView: View {
    let tool: ToolChecker.ToolInfo
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.status.icon)
                .foregroundStyle(tool.status.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.body.bold())
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch tool.status {
            case .notInstalled:
                Button("설치") {
                    onInstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("설치 중...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .installed:
                Text("설치됨")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .checking:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - File Row

struct FileRowView: View {
    let file: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.status.icon)
                .foregroundStyle(file.status.color)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(file.size)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if case .completed(let lang) = file.status {
                        Text(lang.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    if case .skipped = file.status {
                        Text("이미 존재")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if case .failed(let error) = file.status {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            if case .processing = file.status {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
