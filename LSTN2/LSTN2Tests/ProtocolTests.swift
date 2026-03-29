import XCTest
@testable import LSTN2

final class ProtocolTests: XCTestCase {

    // MARK: - EventEnvelope Parsing

    func testParseConnectedEvent() {
        let json = #"{"type":"event.connected","version":"0.1.0"}"#
        let data = json.data(using: .utf8)!
        let envelope = EventEnvelope(jsonData: data)

        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .connected)
        XCTAssertEqual(envelope?.payload["version"] as? String, "0.1.0")
    }

    func testParseErrorEvent() {
        let json = #"{"type":"event.error","error_code":"TEST","message":"fail","component":"server","recoverable":true}"#
        let data = json.data(using: .utf8)!
        let envelope = EventEnvelope(jsonData: data)

        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .error)
        XCTAssertEqual(envelope?.payload["error_code"] as? String, "TEST")
        XCTAssertEqual(envelope?.payload["message"] as? String, "fail")
        XCTAssertEqual(envelope?.payload["component"] as? String, "server")
    }

    func testParseTranscriptDelta() {
        let json = #"{"type":"event.transcript.delta","turn_id":"t1","speaker":"me","delta_text":"hello","timestamp":1234.5}"#
        let data = json.data(using: .utf8)!
        let envelope = EventEnvelope(jsonData: data)

        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.event, .transcriptDelta)
        XCTAssertEqual(envelope?.payload["turn_id"] as? String, "t1")
        XCTAssertEqual(envelope?.payload["speaker"] as? String, "me")
        XCTAssertEqual(envelope?.payload["delta_text"] as? String, "hello")
    }

    func testRejectCommandPrefix() {
        let json = #"{"type":"command.start_recording"}"#
        let data = json.data(using: .utf8)!
        let envelope = EventEnvelope(jsonData: data)

        XCTAssertNil(envelope, "Commands should not parse as events")
    }

    func testRejectMalformedJSON() {
        let data = "not json".data(using: .utf8)!
        let envelope = EventEnvelope(jsonData: data)

        XCTAssertNil(envelope)
    }

    func testRejectUnknownEventType() {
        let json = #"{"type":"event.nonexistent_event"}"#
        let data = json.data(using: .utf8)!
        let envelope = EventEnvelope(jsonData: data)

        XCTAssertNil(envelope, "Unknown event types should return nil")
    }

    func testRejectMissingTypeField() {
        let json = #"{"message":"no type field"}"#
        let data = json.data(using: .utf8)!
        let envelope = EventEnvelope(jsonData: data)

        XCTAssertNil(envelope)
    }

    // MARK: - ClientCommand Serialization

    func testClientCommandSerialization() throws {
        let command = ClientCommand(command: .startRecording, payload: ["mic_device_id": 42])
        let data = try command.toJSON()
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "command.start_recording")
        XCTAssertEqual(dict["mic_device_id"] as? Int, 42)
    }

    func testClientCommandSerializationNoPayload() throws {
        let command = ClientCommand(command: .stopRecording, payload: nil)
        let data = try command.toJSON()
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "command.stop_recording")
        XCTAssertEqual(dict.count, 1, "Should only contain the type field")
    }

    func testClientCommandPing() throws {
        let command = ClientCommand(command: .ping, payload: nil)
        let data = try command.toJSON()
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "command.ping")
    }

    // MARK: - Protocol Version

    func testProtocolVersionConstant() {
        XCTAssertFalse(kProtocolVersion.isEmpty, "Protocol version should not be empty")
        // Version should be semver-like
        let parts = kProtocolVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "Version should have 3 parts (major.minor.patch)")
    }
}
