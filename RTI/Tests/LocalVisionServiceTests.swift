@testable import RTICore
import XCTest

/// Intercepts the vision request so the wire shape can be asserted without a
/// live daemon. `nonisolated(unsafe)`: XCTest serializes these tests, and the
/// URL loading system reads the handler from its own thread.
final class VisionStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.drainBody(of: request)
        Self.lastBody = body
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request, body)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drainBody(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class LocalVisionServiceTests: XCTestCase {
    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VisionStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        VisionStubProtocol.handler = nil
        VisionStubProtocol.lastBody = nil
        super.tearDown()
    }

    // MARK: - Configuration parsing

    func testAbsentBlockDisablesTheLane() {
        let configuration = LocalVisionConfiguration.from([:])
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.endpoint, LocalVisionConfiguration.defaultEndpoint)
        XCTAssertNil(configuration.model)
        XCTAssertEqual(configuration.maxTokens, 400)
        XCTAssertTrue(configuration.saveFrames)
        XCTAssertFalse(configuration.ambientDescribe)
    }

    func testBlockParsingReadsEveryKey() {
        let configuration = LocalVisionConfiguration.from([
            "local_vision": [
                "enabled": true,
                "endpoint": "http://127.0.0.1:9999",
                "model": "qwen3-vl",
                "max_tokens": 200,
                "timeout_seconds": 30,
                "save_frames": false,
                "ambient_describe": true,
            ] as [String: Any],
        ])
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.endpoint.absoluteString, "http://127.0.0.1:9999")
        XCTAssertEqual(configuration.model, "qwen3-vl")
        XCTAssertEqual(configuration.maxTokens, 200)
        XCTAssertEqual(configuration.timeoutSeconds, 30)
        XCTAssertFalse(configuration.saveFrames)
        XCTAssertTrue(configuration.ambientDescribe)
    }

    // MARK: - Requests

    func testDisabledConfigurationThrowsBeforeAnyRequest() async {
        VisionStubProtocol.handler = { _, _ in
            XCTFail("a disabled lane must not touch the network")
            return (200, Data())
        }
        do {
            _ = try await LocalVisionService.describe(
                imageData: Data([0x01]),
                configuration: LocalVisionConfiguration(enabled: false),
                session: stubbedSession()
            )
            XCTFail("expected LocalVisionError.disabled")
        } catch let error as LocalVisionError {
            XCTAssertEqual(error, .disabled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRequestCarriesPromptImageModelAndMaxTokens() async throws {
        VisionStubProtocol.handler = { _, _ in
            (200, Data(#"{"model": "qwen3-vl", "text": "  A red square.  "}"#.utf8))
        }
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let configuration = LocalVisionConfiguration(
            enabled: true,
            model: "qwen3-vl",
            maxTokens: 123
        )
        let text = try await LocalVisionService.describe(
            imageData: image,
            prompt: "What is this?",
            configuration: configuration,
            session: stubbedSession()
        )
        XCTAssertEqual(text, "A red square.")

        let body = try XCTUnwrap(VisionStubProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["prompt"] as? String, "What is this?")
        XCTAssertEqual(object["image_b64"] as? String, image.base64EncodedString())
        XCTAssertEqual(object["max_tokens"] as? Int, 123)
        XCTAssertEqual(object["model"] as? String, "qwen3-vl")
    }

    func testServerErrorSurfacesStatusAndDetail() async {
        VisionStubProtocol.handler = { _, _ in
            (502, Data(#"{"error": "backend down"}"#.utf8))
        }
        do {
            _ = try await LocalVisionService.describe(
                imageData: Data([0x01]),
                configuration: LocalVisionConfiguration(enabled: true),
                session: stubbedSession()
            )
            XCTFail("expected LocalVisionError.badStatus")
        } catch let error as LocalVisionError {
            XCTAssertEqual(error, .badStatus(502, "backend down"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMissingTextFieldIsMalformed() async {
        VisionStubProtocol.handler = { _, _ in
            (200, Data(#"{"model": "qwen3-vl"}"#.utf8))
        }
        do {
            _ = try await LocalVisionService.describe(
                imageData: Data([0x01]),
                configuration: LocalVisionConfiguration(enabled: true),
                session: stubbedSession()
            )
            XCTFail("expected LocalVisionError.malformedResponse")
        } catch let error as LocalVisionError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
