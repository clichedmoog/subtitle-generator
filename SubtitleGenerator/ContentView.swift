import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var files: [FileItem] = FileItem.loadSaved()
    @State private var selectedFileIDs: Set<UUID> = []
    @AppStorage("selectedModel") private var selectedModel: WhisperModel = .largev3turbo
    @AppStorage("outputMode") private var outputMode: OutputMode = .srtOnly
    @AppStorage("language") private var language: Language = .auto
    @AppStorage("sensitivity") private var sensitivity: Sensitivity = .normal
    @State private var selectedTranslations: Set<TranslationLanguage> = {
        guard let data = UserDefaults.standard.data(forKey: "selectedTranslations"),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(raw.compactMap { TranslationLanguage(rawValue: $0) })
    }()
    @AppStorage("authMethod") private var authMethod: AuthMethod = .claudeCode
    @AppStorage("translationModel") private var translationModel: TranslationModel = .claudeOpus1m
    @AppStorage("claudeApiKey") private var claudeApiKey: String = ""
    @AppStorage("openaiApiKey") private var openaiApiKey: String = ""
    @State private var isAuthVerified = false
    @State private var isVerifying = false
    @State private var isDownloadingModel = false
    @State private var isDropTargeted = false
    @AppStorage("optionsExpanded") private var optionsExpanded = true
    @AppStorage("subtitleDelay") private var subtitleDelay: SubtitleDelay = .normal
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
        .onChange(of: files) { _, newValue in
            FileItem.save(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .startProcessing)) { _ in
            if !engine.isProcessing && !files.isEmpty {
                startProcessing()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopProcessing)) { _ in
            if engine.isProcessing {
                engine.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFilesToQueue)) { notification in
            guard let urls = notification.userInfo?["urls"] as? [URL] else { return }
            for url in urls {
                if let existingIndex = files.firstIndex(where: { $0.url == url }) {
                    files[existingIndex].status = .pending
                } else {
                    files.append(FileItem(url: url))
                }
            }
        }
        .onChange(of: selectedTranslations) { _, newValue in
            let raw = newValue.map { $0.rawValue }
            if let data = try? JSONEncoder().encode(raw) {
                UserDefaults.standard.set(data, forKey: "selectedTranslations")
            }
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
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(.blue) : AnyShapeStyle(.quaternary))
                .padding(16)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.blue.opacity(0.05))
                    .padding(16)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
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
                    for i in files.indices {
                        if files[i].status != .processing {
                            files[i].status = .pending
                            files[i].elapsedTime = nil
                            files[i].translatedLangs = []
                        }
                    }
                } label: {
                    Label("모두 초기화", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(engine.isProcessing)

                Button {
                    files.removeAll { $0.status != .processing }
                } label: {
                    Label("전체 삭제", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selectedFileIDs) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    FileRowView(file: file)
                        .tag(file.id)
                        .contextMenu {
                            if selectedFileIDs.count > 1 && selectedFileIDs.contains(file.id) {
                                // Multi-selection context menu
                                Button {
                                    for id in selectedFileIDs {
                                        if let i = files.firstIndex(where: { $0.id == id }), files[i].status != .processing {
                                            files[i].status = .pending
                                            files[i].elapsedTime = nil
                                            files[i].translatedLangs = []
                                        }
                                    }
                                    selectedFileIDs.removeAll()
                                } label: {
                                    Label("선택 항목 초기화 (\(selectedFileIDs.count)개)", systemImage: "arrow.counterclockwise")
                                }

                                Button(role: .destructive) {
                                    files.removeAll { selectedFileIDs.contains($0.id) && $0.status != .processing }
                                    selectedFileIDs.removeAll()
                                } label: {
                                    Label("선택 항목 삭제 (\(selectedFileIDs.count)개)", systemImage: "trash")
                                }
                            } else {
                                // Single item context menu
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                } label: {
                                    Label("파인더에서 보기", systemImage: "folder")
                                }

                                Button {
                                    NSWorkspace.shared.open(file.url)
                                } label: {
                                    Label("기본 앱으로 열기", systemImage: "play.circle")
                                }

                                Divider()

                                Button {
                                    files[index].status = .pending
                                    files[index].elapsedTime = nil
                                    files[index].translatedLangs = []
                                } label: {
                                    Label("상태 초기화", systemImage: "arrow.counterclockwise")
                                }
                                .disabled(file.status == .processing)

                                Button(role: .destructive) {
                                    files.remove(at: index)
                                } label: {
                                    Label("목록에서 제거", systemImage: "trash")
                                }
                                .disabled(file.status == .processing)
                            }
                        }
                }
                .onDelete { indexSet in
                    files.remove(atOffsets: indexSet)
                }
                .onMove { from, to in
                    if !engine.isProcessing {
                        files.move(fromOffsets: from, toOffset: to)
                    }
                }
                .onInsert(of: [.fileURL]) { index, providers in
                    handleDrop(providers, at: index)
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
        DisclosureGroup("옵션", isExpanded: $optionsExpanded) {
            HStack {
                Spacer()
                Button("옵션 초기화") {
                    resetOptions()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
                .disabled(engine.isProcessing)
            }
            HStack(alignment: .top, spacing: 0) {
                // Left: 자막 생성 옵션
                VStack(alignment: .leading, spacing: 12) {
                    Text("자막 생성")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)

                    optionRow("모델") {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $selectedModel) {
                                ForEach(WhisperModel.allCases) { model in
                                    HStack {
                                        Text(model.displayName)
                                        if !model.isCached {
                                            Text("(\(model.sizeLabel))")
                                                .foregroundStyle(.tertiary)
                                        }
                                    }.tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()

                            if !selectedModel.isCached {
                                HStack(spacing: 4) {
                                    if isDownloadingModel {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("다운로드 중...")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                            .foregroundStyle(.orange)
                                            .font(.caption)
                                        Text("첫 사용 시 \(selectedModel.sizeLabel) 다운로드")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        Button("미리 다운로드") {
                                            downloadModel()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                        }
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
                    ProgressView(value: engine.overallProgress)

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

    private func handleDrop(_ providers: [NSItemProvider], at insertIndex: Int? = nil) {
        var insertAt = insertIndex ?? files.count
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                let allowed = ["mp4", "mov", "mkv", "m4v", "m4a", "wav", "mp3", "avi", "webm", "flv"]
                if allowed.contains(ext) {
                    DispatchQueue.main.async {
                        if let existingIndex = files.firstIndex(where: { $0.url == url }) {
                            files[existingIndex].status = .pending
                        } else {
                            let safeIndex = min(insertAt, files.count)
                            files.insert(FileItem(url: url), at: safeIndex)
                            insertAt += 1
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
        return translator.verifyAuth()
    }

    private func downloadModel() {
        isDownloadingModel = true
        let model = selectedModel.rawValue
        DispatchQueue.global().async {
            // Run mlx_whisper with a tiny clip to trigger model download
            let paths = ["/opt/homebrew/bin/mlx_whisper", "/usr/local/bin/mlx_whisper", "\(NSHomeDirectory())/.local/bin/mlx_whisper"]
            guard let mlx = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                DispatchQueue.main.async { self.isDownloadingModel = false }
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: mlx)
            // Use --help won't download; instead use a dummy run that will fail but download the model
            process.arguments = ["--model", model, "--help"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            // Actually just trigger the download by importing the model
            let downloadProcess = Process()
            downloadProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
            downloadProcess.arguments = ["-c", "export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH && python3 -c \"from huggingface_hub import snapshot_download; snapshot_download('\(model)')\""]
            downloadProcess.standardOutput = Pipe()
            downloadProcess.standardError = Pipe()
            try? downloadProcess.run()
            downloadProcess.waitUntilExit()

            DispatchQueue.main.async { self.isDownloadingModel = false }
        }
    }

    private func resetOptions() {
        selectedModel = .largev3
        outputMode = .srtOnly
        language = .auto
        sensitivity = .normal
        subtitleDelay = .normal
        selectedTranslations = []
        authMethod = .claudeCode
        translationModel = .claudeOpus1m
        claudeApiKey = ""
        openaiApiKey = ""
        isAuthVerified = false
    }

    private func startProcessing() {
        let options = TranscriptionEngine.Options(
            model: selectedModel.rawValue,
            embedSubtitle: outputMode == .embedInVideo,
            keepSrtFile: outputMode == .srtOnly,
            subtitleDelay: subtitleDelay.seconds,
            sensitivity: sensitivity,
            language: language.rawValue,
            translationTargets: selectedTranslations,
            authMethod: authMethod,
            translationModel: translationModel.rawValue,
            claudeApiKey: claudeApiKey,
            openaiApiKey: openaiApiKey
        )
        engine.onFileProgressUpdate = { index, progress in
            if index < files.count {
                files[index].progress = progress
            }
        }
        engine.process(getFiles: { self.files }, options: options, onFileUpdate: { index, status, elapsed in
            if index < files.count {
                files[index].status = status
                if let elapsed = elapsed {
                    files[index].elapsedTime = elapsed
                }
            }
        }, onFileProgress: { index, progress in
            if index < files.count {
                files[index].progress = progress
            }
        }, onTranslationComplete: { index, lang in
            if index < files.count {
                if !files[index].translatedLangs.contains(lang) {
                    files[index].translatedLangs.append(lang)
                }
            }
        })
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

                    ForEach(file.translatedLangs, id: \.self) { lang in
                        Text(lang.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    if case .translating(let lang) = file.status {
                        Text("번역 중 (\(lang.uppercased()))")
                            .font(.caption)
                            .foregroundStyle(.purple)
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
                            .help(error)
                    }

                    if let elapsed = file.elapsedTime {
                        Text(formatElapsed(elapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if case .processing = file.status {
                ProgressView(value: file.progress)
                    .frame(width: 60)
                    .tint(.blue)
            }
            if case .translating = file.status {
                ProgressView()
                    .controlSize(.small)
                    .tint(.purple)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return mins > 0 ? "\(mins)분 \(secs)초" : "\(secs)초"
    }
}
