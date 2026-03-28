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

    func testFormatSrtTimeDelay() {
        XCTAssertEqual(engine.formatSrtTime(0.3), "00:00:00,300")
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

    func testLangCode3Unknown() {
        XCTAssertEqual(engine.langCode3("xyz"), "xyz")
    }

    // MARK: - generateSrt

    func testGenerateSrtBasic() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 2.0, "text": "안녕하세요"],
            ["start": 2.0, "end": 4.0, "text": "반갑습니다"],
        ]
        let srt = engine.generateSrt(from: segments)
        XCTAssertTrue(srt.contains("안녕하세요"))
        XCTAssertTrue(srt.contains("반갑습니다"))
        XCTAssertTrue(srt.contains("-->"))
    }

    func testGenerateSrtSkipsEmpty() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 2.0, "text": "  "],
            ["start": 2.0, "end": 4.0, "text": "내용"],
        ]
        let srt = engine.generateSrt(from: segments)
        let lines = srt.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3) // "1", timestamp, "내용"
    }

    func testGenerateSrtEmpty() {
        let srt = engine.generateSrt(from: [])
        XCTAssertTrue(srt.isEmpty)
    }

    func testGenerateSrtFormat() {
        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 3.5, "text": "첫 번째"],
            ["start": 4.0, "end": 6.0, "text": "두 번째"],
        ]
        let srt = engine.generateSrt(from: segments)
        let lines = srt.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "1")
        XCTAssertTrue(lines[1].contains(" --> "))
        XCTAssertTrue(lines[1].contains(","))
        XCTAssertFalse(lines[1].contains("."))
    }
}

final class ModelTests: XCTestCase {

    // MARK: - Language

    func testLanguageAutoEmpty() {
        XCTAssertEqual(Language.auto.rawValue, "")
    }

    func testLanguageAllHaveLabels() {
        for lang in Language.allCases {
            XCTAssertFalse(lang.label.isEmpty)
        }
    }

    // MARK: - Sensitivity

    func testSensitivityOrder() {
        XCTAssertLessThan(Sensitivity.sensitive.noSpeechThreshold, Sensitivity.normal.noSpeechThreshold)
        XCTAssertLessThan(Sensitivity.normal.noSpeechThreshold, Sensitivity.accurate.noSpeechThreshold)
    }

    // MARK: - SubtitleDelay

    func testDelayOrder() {
        let values = SubtitleDelay.allCases.map { $0.seconds }
        XCTAssertEqual(values, values.sorted())
    }

    // MARK: - TranslationModel

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

    // MARK: - AuthMethod

    func testAuthMethodClaudeCodeNoKey() {
        XCTAssertFalse(AuthMethod.claudeCode.needsApiKey)
    }

    func testAuthMethodApiKeyNeeded() {
        XCTAssertTrue(AuthMethod.claudeApiKey.needsApiKey)
        XCTAssertTrue(AuthMethod.openaiApiKey.needsApiKey)
    }
}
