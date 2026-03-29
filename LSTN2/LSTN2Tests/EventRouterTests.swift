import XCTest
@testable import LSTN2

final class EventRouterTests: XCTestCase {

    // MARK: - isLikelyEnglish

    func testEnglishTextPasses() {
        XCTAssertTrue(EventRouter.isLikelyEnglish("Hello world"))
        XCTAssertTrue(EventRouter.isLikelyEnglish("This is a test sentence."))
    }

    func testLatinWithNumbersPasses() {
        XCTAssertTrue(EventRouter.isLikelyEnglish("Version 2.0 released"))
        XCTAssertTrue(EventRouter.isLikelyEnglish("Order #12345"))
    }

    func testLatinWithPunctuationPasses() {
        XCTAssertTrue(EventRouter.isLikelyEnglish("Hello, world! How are you?"))
        XCTAssertTrue(EventRouter.isLikelyEnglish("foo-bar_baz"))
    }

    func testCyrillicFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish("Привет мир"))
    }

    func testCJKFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish("你好世界"))
    }

    func testArabicFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish("مرحبا بالعالم"))
    }

    func testHebrewFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish("שלום עולם"))
    }

    func testKoreanFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish("안녕하세요"))
    }

    func testJapaneseFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish("こんにちは世界"))
    }

    func testEmptyStringFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish(""))
    }

    func testWhitespaceOnlyFails() {
        XCTAssertFalse(EventRouter.isLikelyEnglish("   "))
    }

    func testMixedLatinAndNonLatinFails() {
        // Contains Cyrillic characters — should be rejected
        XCTAssertFalse(EventRouter.isLikelyEnglish("Hello Привет"))
    }

    func testSingleLatinWord() {
        XCTAssertTrue(EventRouter.isLikelyEnglish("hello"))
    }
}
