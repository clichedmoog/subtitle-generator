import XCTest
@testable import SubtitleGenerator

final class TranscriptionEngineTests: XCTestCase {
    let engine = TranscriptionEngine()

    // MARK: - formatSrtTime

    func testFormatSrtTimeZero() {
        XCTAssertEqual(engine.formatSrtTime(0), "00:00:00,000")
    }

    func testFormatSrtTimeSeconds() {
        XCTAssertEqual(engine.formatSrtTime(1.5), "00:00:01,500")
    }

    func testFormatSrtTimeMinutes() {
        XCTAssertEqual(engine.formatSrtTime(65.123), "00:01:05,123")
    }

    func testFormatSrtTimeHours() {
        XCTAssertEqual(engine.formatSrtTime(3661.0), "01:01:01,000")
    }

    func testFormatSrtTimeNegativeClampsToZero() {
        XCTAssertEqual(engine.formatSrtTime(-5.0), "00:00:00,000")
    }

    func testFormatSrtTimeLargeValue() {
        XCTAssertEqual(engine.formatSrtTime(7200.5), "02:00:00,500")
    }

    func testFormatSrtTimeCommaNotDot() {
        let result = engine.formatSrtTime(1.234)
        XCTAssertTrue(result.contains(","))
        XCTAssertFalse(result.contains("."))
    }

    // MARK: - parseSrtTimestamp

    func testParseSrtTimestampBasic() {
        XCTAssertEqual(engine.parseSrtTimestamp("01:30.000"), 90.0)
    }

    func testParseSrtTimestampZeroMinutes() {
        XCTAssertEqual(engine.parseSrtTimestamp("00:05.500"), 5.5)
    }

    func testParseSrtTimestampInvalid() {
        XCTAssertEqual(engine.parseSrtTimestamp("invalid"), 0)
    }

    func testParseSrtTimestampEmpty() {
        XCTAssertEqual(engine.parseSrtTimestamp(""), 0)
    }

    func testParseSrtTimestampTooManyColons() {
        XCTAssertEqual(engine.parseSrtTimestamp("01:02:03"), 0)
    }

    // MARK: - langCode3

    func testLangCode3Japanese() {
        XCTAssertEqual(engine.langCode3("ja"), "jpn")
    }

    func testLangCode3Korean() {
        XCTAssertEqual(engine.langCode3("ko"), "kor")
    }

    func testLangCode3English() {
        XCTAssertEqual(engine.langCode3("en"), "eng")
    }

    func testLangCode3Chinese() {
        XCTAssertEqual(engine.langCode3("zh"), "zho")
    }

    func testLangCode3Unknown() {
        XCTAssertEqual(engine.langCode3("xyz"), "xyz")
    }

    func testLangCode3AllMapped() {
        let mapped = ["ja", "ko", "en", "zh", "fr", "de", "es", "it", "pt", "ru",
                      "ar", "hi", "th", "vi", "id", "ms", "tl", "tr", "pl", "nl",
                      "sv", "da", "no", "fi", "el", "he", "uk", "cs", "ro", "hu"]
        for code in mapped {
            let result = engine.langCode3(code)
            XCTAssertNotEqual(result, code, "langCode3 should map \(code) to 3-letter code")
            XCTAssertEqual(result.count, 3, "langCode3(\(code)) should return 3-letter code")
        }
    }

    // MARK: - isRepetitive

    func testIsRepetitiveSingleChar() {
        XCTAssertTrue(engine.isRepetitive("ああああああ"))
    }

    func testIsRepetitivePattern() {
        XCTAssertTrue(engine.isRepetitive("ダメダメダメダメ"))
    }

    func testIsRepetitiveLongPattern() {
        XCTAssertTrue(engine.isRepetitive("ダメダメダメダメダメダメダメダメダメダメダメダメダメダメダメダメダメダメダメダメダメ"))
    }

    func testIsRepetitiveCommaSeparated() {
        XCTAssertTrue(engine.isRepetitive("うっ、うっ、うっ、うっ"))
    }

    func testIsRepetitiveCommaSeparatedMany() {
        XCTAssertTrue(engine.isRepetitive("うっ、うっ、うっ、うっ、うっ、うっ、うっ、うっ、うっ、うっ"))
    }

    func testIsRepetitiveShortTextNotRepetitive() {
        XCTAssertFalse(engine.isRepetitive("abc"))
    }

    func testIsRepetitiveNormalSentence() {
        XCTAssertFalse(engine.isRepetitive("ダメですよ"))
    }

    func testIsRepetitivePartialPatternNotFalsePositive() {
        XCTAssertFalse(engine.isRepetitive("abcabcx"))
    }

    func testIsRepetitiveNormalDialogue() {
        XCTAssertFalse(engine.isRepetitive("おはようございます"))
    }

    func testIsRepetitiveTwoCharsNotEnough() {
        XCTAssertFalse(engine.isRepetitive("ああ"))
    }

    func testIsRepetitiveThreeCharsNotEnough() {
        XCTAssertFalse(engine.isRepetitive("あああ"))
    }

    func testIsRepetitiveFourCharsSingleIsRepetitive() {
        XCTAssertTrue(engine.isRepetitive("ああああ"))
    }

    func testIsRepetitiveMixedNotRepetitive() {
        XCTAssertFalse(engine.isRepetitive("あいうえお"))
    }

    func testIsRepetitiveCommaOnlyTwoNotEnough() {
        XCTAssertFalse(engine.isRepetitive("うっ、うっ"))
    }

    // MARK: - generateSrt

    func testGenerateSrtBasic() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 2.0, "text": "안녕하세요"],
            ["start": 2.0, "end": 4.0, "text": "반갑습니다"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        XCTAssertTrue(srt.contains("안녕하세요"))
        XCTAssertTrue(srt.contains("반갑습니다"))
        XCTAssertTrue(srt.contains("-->"))
    }

    func testGenerateSrtSkipsEmpty() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 2.0, "text": "  "],
            ["start": 2.0, "end": 4.0, "text": "내용"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        let lines = srt.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
    }

    func testGenerateSrtEmpty() {
        let srt = engine.generateSrt(from: [], delay: 0)
        XCTAssertTrue(srt.isEmpty)
    }

    func testGenerateSrtFormat() {
        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 3.5, "text": "첫 번째"],
            ["start": 4.0, "end": 6.0, "text": "두 번째"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        let lines = srt.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "1")
        XCTAssertTrue(lines[1].contains(" --> "))
        XCTAssertTrue(lines[1].contains(","))
        XCTAssertFalse(lines[1].contains("."))
    }

    func testGenerateSrtWithDelay() {
        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 3.0, "text": "test"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0.5)
        XCTAssertTrue(srt.contains("00:00:01,500"))
        XCTAssertTrue(srt.contains("00:00:03,500"))
    }

    func testGenerateSrtWithNegativeDelayClampsToZero() {
        let segments: [[String: Any]] = [
            ["start": 0.1, "end": 1.0, "text": "test"],
        ]
        let srt = engine.generateSrt(from: segments, delay: -1.0)
        XCTAssertTrue(srt.contains("00:00:00,000"))
    }

    func testGenerateSrtMergesConsecutiveDuplicates() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "text": "はぁ…"],
            ["start": 1.0, "end": 2.0, "text": "はぁ…"],
            ["start": 2.0, "end": 3.0, "text": "はぁ…"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        let entries = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(srt.contains("00:00:03,000"))
    }

    func testGenerateSrtDoesNotMergeNonConsecutiveDuplicates() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "text": "はい"],
            ["start": 1.0, "end": 2.0, "text": "いいえ"],
            ["start": 2.0, "end": 3.0, "text": "はい"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        let entries = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(entries.count, 3)
    }

    func testGenerateSrtFiltersRepetitive() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 2.0, "text": "ああああああ"],
            ["start": 2.0, "end": 4.0, "text": "正常なテキスト"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        XCTAssertFalse(srt.contains("ああああああ"))
        XCTAssertTrue(srt.contains("正常なテキスト"))
    }

    func testGenerateSrtSequenceNumbersAreCorrectAfterFiltering() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "text": "ああああああ"],
            ["start": 1.0, "end": 2.0, "text": "first"],
            ["start": 2.0, "end": 3.0, "text": "  "],
            ["start": 3.0, "end": 4.0, "text": "second"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        let lines = srt.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "1")
        XCTAssertTrue(lines[2] == "first")
        XCTAssertEqual(lines[4], "2")
    }

    func testGenerateSrtSkipsMissingFields() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "text": "no end"],
            ["end": 2.0, "text": "no start"],
            ["start": 0.0, "end": 2.0],
            ["start": 2.0, "end": 4.0, "text": "valid"],
        ]
        let srt = engine.generateSrt(from: segments, delay: 0)
        let entries = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(srt.contains("valid"))
    }
}

final class ModelTests: XCTestCase {

    func testLanguageAutoEmpty() {
        XCTAssertEqual(Language.auto.rawValue, "")
    }

    func testLanguageAllHaveLabels() {
        for lang in Language.allCases {
            XCTAssertFalse(lang.label.isEmpty)
        }
    }

    func testLanguageKoreanFirst() {
        let nonAuto = Language.allCases.filter { $0 != .auto }
        XCTAssertEqual(nonAuto.first, .ko)
    }

    func testSensitivityOrder() {
        XCTAssertLessThan(Sensitivity.sensitive.noSpeechThreshold, Sensitivity.normal.noSpeechThreshold)
        XCTAssertLessThan(Sensitivity.normal.noSpeechThreshold, Sensitivity.accurate.noSpeechThreshold)
    }

    func testDelayOrder() {
        let values = SubtitleDelay.allCases.map { $0.seconds }
        XCTAssertEqual(values, values.sorted())
    }

    func testDelayImmediateIsZero() {
        XCTAssertEqual(SubtitleDelay.immediate.seconds, 0.0)
    }

    func testTranslationModelClaudeFilter() {
        let models = TranslationModel.models(for: .claudeApiKey)
        XCTAssertTrue(models.allSatisfy { $0.isClaude })
    }

    func testTranslationModelOpenAIFilter() {
        let models = TranslationModel.models(for: .openaiApiKey)
        XCTAssertTrue(models.allSatisfy { $0.isOpenAI })
    }

    func testTranslationModelClaudeCode() {
        let models = TranslationModel.models(for: .claudeCode)
        XCTAssertTrue(models.allSatisfy { $0.isClaude })
    }

    func testTranslationModelClaudeCodeFirstIsOpus1m() {
        let models = TranslationModel.models(for: .claudeCode)
        XCTAssertEqual(models.first, .claudeOpus1m)
    }

    func testWhisperModelCacheDir() {
        let model = WhisperModel.largev3
        XCTAssertTrue(model.cacheDir.contains("mlx-community--whisper-large-v3-mlx"))
    }

    func testWhisperModelSizeLabel() {
        for model in WhisperModel.allCases {
            XCTAssertFalse(model.sizeLabel.isEmpty)
        }
    }

    func testOutputModeLabels() {
        for mode in OutputMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
        }
    }

    func testFileItemSaveLoad() {
        let url = URL(fileURLWithPath: "/tmp/test_save_load.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let items = [FileItem(url: url)]
        FileItem.save(items)
        let loaded = FileItem.loadSaved()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.url, url)
    }

    func testFileItemLoadSkipsMissing() {
        UserDefaults.standard.set(["/nonexistent/file.mp4"], forKey: "savedFiles")
        let loaded = FileItem.loadSaved()
        XCTAssertTrue(loaded.isEmpty)
    }
}
