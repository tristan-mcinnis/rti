import XCTest

/// A child that writes more than a pipe buffer (64 KB) to stderr before it
/// writes stdout used to deadlock callers that read stdout to the end first:
/// the child blocks on the full stderr pipe and never closes stdout.
final class ProcessOutputCollectorTests: XCTestCase {
    func test_wait_collectsBothPipes_whenStderrPassesThePipeBuffer() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "head -c 200000 /dev/zero | tr '\\0' 'e' >&2; printf done"]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()

        let collector = ProcessOutputCollector(stdout: out, stderr: err)
        let finished = expectation(description: "both pipes reach end of file")
        nonisolated(unsafe) var result: (stdout: Data, stderr: Data)?
        DispatchQueue.global().async {
            result = collector.wait()
            finished.fulfill()
        }
        guard XCTWaiter.wait(for: [finished], timeout: 20) == .completed else {
            proc.terminate()
            return XCTFail("the collector deadlocked on a full pipe")
        }
        proc.waitUntilExit()

        let output = try XCTUnwrap(result)
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "done")
        XCTAssertEqual(output.stderr.count, 200_000)
        XCTAssertEqual(proc.terminationStatus, 0)
    }
}
