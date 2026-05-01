import Foundation
import Starscream

final class SonioxClient: WebSocketDelegate {
    static let defaultURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    var onWords: (([SonioxWord]) -> Void)?
    /// Fires on terminal failures the user should see: server-reported errors,
    /// or reaching `maxRetries` without reconnecting. Always dispatched on main.
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let url: URL
    private let lock = NSLock()
    private var socket: WebSocket?
    private var isConnected = false
    /// Set to true when the user deliberately closes the connection,
    /// to suppress automatic reconnect. Protected by `lock`.
    private var intentionalDisconnect = false
    private var retryCount = 0
    private var retryWorkItem: DispatchWorkItem?

    private static let maxRetries = 5
    private static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 8]

    init(apiKey: String, url: URL) {
        self.apiKey = apiKey
        self.url = url
    }

    func connect() {
        lock.lock()
        intentionalDisconnect = false
        retryCount = 0
        lock.unlock()
        openSocket()
    }

    func disconnect() {
        lock.lock()
        intentionalDisconnect = true
        retryWorkItem?.cancel()
        retryWorkItem = nil
        let ws = socket
        socket = nil
        isConnected = false
        lock.unlock()
        ws?.disconnect()
    }

    func sendAudio(_ data: Data) {
        lock.lock()
        guard let socket = socket else {
            lock.unlock()
            return
        }
        // Writing to an already-disconnected socket is handled gracefully
        // by Starscream: it triggers .cancelled, which handleDrop processes.
        socket.write(data: data)
        lock.unlock()
    }

    /// Signal end-of-audio to Soniox so remaining interim tokens get finalized.
    /// The caller should wait briefly before calling disconnect() to let finals arrive.
    /// Also marks the connection as intentionally winding down so the server's
    /// clean close (code=1000) during the wait window does not trigger a reconnect.
    func finalize() {
        lock.lock()
        guard let socket = socket, isConnected else {
            lock.unlock()
            return
        }
        intentionalDisconnect = true
        retryWorkItem?.cancel()
        retryWorkItem = nil
        socket.write(string: "")
        lock.unlock()
    }

    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected:
            lock.lock()
            isConnected = true
            retryCount = 0
            lock.unlock()
            NSLog("[RTI] SonioxClient: connected, sending config")
            RTILog.log("connected — sending config", category: "soniox")
            sendConfig()

        case .text(let string):
            NSLog("[RTI] SonioxClient: recv %@", string.prefix(400) as NSString)
            handleMessage(string)

        case .disconnected(let reason, let code):
            handleDrop("disconnected code=\(code) reason=\(reason)")

        case .error(let error):
            handleDrop("error \(String(describing: error))")

        case .cancelled:
            handleDrop("cancelled")

        default:
            break
        }
    }

    private func handleDrop(_ reason: String) {
        lock.lock()
        isConnected = false
        let reconnect = !intentionalDisconnect
        lock.unlock()
        NSLog("[RTI] SonioxClient: \(reason)")
        RTILog.log("dropped — \(reason)", category: "soniox")
        if reconnect {
            scheduleReconnect()
        }
    }

    private func openSocket() {
        let request = URLRequest(url: url)
        let ws = WebSocket(request: request)
        ws.delegate = self
        lock.lock()
        socket = ws
        lock.unlock()
        ws.connect()
    }

    private func sendConfig() {
        do {
            let data = try JSONEncoder().encode(SonioxConfigMessage.default(apiKey: apiKey))
            if let string = String(data: data, encoding: .utf8) {
                lock.lock()
                socket?.write(string: string)
                lock.unlock()
            }
        } catch {
            NSLog("[RTI] SonioxClient: config encode failed: \(error)")
        }
    }

    private func scheduleReconnect() {
        lock.lock()
        guard retryCount < Self.maxRetries else {
            lock.unlock()
            NSLog("[RTI] SonioxClient: max retries reached")
            DispatchQueue.main.async { [weak self] in
                self?.onError?("Soniox connection lost — transcription stopped after \(Self.maxRetries) reconnect attempts.")
            }
            return
        }
        let delay = Self.retryDelays[min(retryCount, Self.retryDelays.count - 1)]
        retryCount += 1
        let attempt = retryCount
        lock.unlock()

        NSLog("[RTI] SonioxClient: reconnect attempt \(attempt) in \(delay)s")

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let blocked = self.intentionalDisconnect
            self.lock.unlock()
            guard !blocked else { return }
            self.openSocket()
        }
        lock.lock()
        retryWorkItem = item
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleMessage(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        do {
            let msg = try JSONDecoder().decode(SonioxTranscriptMessage.self, from: data)
            if let code = msg.error_code {
                let detail = msg.error_message ?? "no detail"
                NSLog("[RTI] SonioxClient server error: code=\(code) \(detail)")
                RTILog.log("server error code=\(code) \(detail)", category: "soniox")
                DispatchQueue.main.async { [weak self] in
                    self?.onError?("Soniox error \(code): \(detail)")
                }
                return
            }
            guard let raw = msg.tokens, !raw.isEmpty else { return }
            let words = raw.map { $0.toSonioxWord() }
            let finalCount = words.filter(\.isFinal).count
            if finalCount > 0 {
                RTILog.log("received \(words.count) tokens (\(finalCount) final)", category: "soniox")
            }
            DispatchQueue.main.async { [weak self] in
                self?.onWords?(words)
            }
        } catch {
            NSLog("[RTI] SonioxClient: decode failed: \(error)")
        }
    }
}
