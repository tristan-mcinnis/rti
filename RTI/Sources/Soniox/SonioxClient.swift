import Foundation
import Starscream

final class SonioxClient: WebSocketDelegate {
    static let defaultURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    var onWords: (([SonioxWord]) -> Void)?

    private let apiKey: String
    private let url: URL
    private var socket: WebSocket?
    private var isConnected = false
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
        intentionalDisconnect = false
        retryCount = 0
        openSocket()
    }

    func disconnect() {
        intentionalDisconnect = true
        retryWorkItem?.cancel()
        retryWorkItem = nil
        socket?.disconnect()
        socket = nil
        isConnected = false
    }

    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        socket?.write(data: data)
    }

    /// Signal end-of-audio to Soniox so remaining interim tokens get finalized.
    /// The caller should wait briefly before calling disconnect() to let finals arrive.
    func finalize() {
        guard isConnected else { return }
        socket?.write(string: "")
    }

    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected:
            NSLog("[RTI] SonioxClient: connected, sending config")
            isConnected = true
            retryCount = 0
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
        isConnected = false
        NSLog("[RTI] SonioxClient: \(reason)")
        if !intentionalDisconnect {
            scheduleReconnect()
        }
    }

    private func openSocket() {
        let request = URLRequest(url: url)
        let ws = WebSocket(request: request)
        ws.delegate = self
        socket = ws
        ws.connect()
    }

    private func sendConfig() {
        do {
            let data = try JSONEncoder().encode(SonioxConfigMessage.default(apiKey: apiKey))
            if let string = String(data: data, encoding: .utf8) {
                socket?.write(string: string)
            }
        } catch {
            NSLog("[RTI] SonioxClient: config encode failed: \(error)")
        }
    }

    private func scheduleReconnect() {
        guard retryCount < Self.maxRetries else {
            NSLog("[RTI] SonioxClient: max retries reached")
            return
        }
        let delay = Self.retryDelays[min(retryCount, Self.retryDelays.count - 1)]
        retryCount += 1
        NSLog("[RTI] SonioxClient: reconnect attempt \(retryCount) in \(delay)s")

        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.intentionalDisconnect else { return }
            self.openSocket()
        }
        retryWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleMessage(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        do {
            let msg = try JSONDecoder().decode(SonioxTranscriptMessage.self, from: data)
            if let code = msg.error_code {
                NSLog("[RTI] SonioxClient server error: code=\(code) \(msg.error_message ?? "")")
                return
            }
            guard let raw = msg.tokens, !raw.isEmpty else { return }
            let words = raw.map { $0.toSonioxWord() }
            DispatchQueue.main.async { [weak self] in
                self?.onWords?(words)
            }
        } catch {
            NSLog("[RTI] SonioxClient: decode failed: \(error)")
        }
    }
}
