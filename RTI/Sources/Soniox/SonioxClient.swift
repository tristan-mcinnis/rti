import Foundation
import RTICore
import Starscream

final class SonioxClient: WebSocketDelegate, STTClient, @unchecked Sendable {
    static let defaultURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    var onWords: (([SonioxWord]) -> Void)?
    /// Fires on terminal failures the user should see: server-reported
    /// errors, non-retryable failures (auth / clientBug), or reaching
    /// `maxRetries` without reconnecting. `didOpen` indicates whether the
    /// WebSocket ever connected, so callers can render handshake failures
    /// ("check internet / proxy") differently from mid-session drops
    /// ("reconnecting…"). Always dispatched on main.
    var onError: ((SonioxFailure, _ didOpen: Bool) -> Void)?
    /// Connection-health transitions (connecting → live → reconnecting →
    /// failed). Always dispatched on main. Drives the UI's "is transcription
    /// flowing?" indicator.
    var onStatus: ((TranscriptionHealth) -> Void)?

    private func emitStatus(_ health: TranscriptionHealth) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(health) }
    }

    private let apiKey: String
    private let url: URL
    private let translationConfig: TranslationConfig?
    private let contextTerms: [String]
    private let lock = NSLock()
    private var socket: WebSocket?
    private var isConnected = false
    /// True once we have ever successfully connected this session — used
    /// by `onError` callbacks to distinguish handshake failures from
    /// mid-stream drops.
    private var didOpen = false
    /// Set to true when the user deliberately closes the connection,
    /// to suppress automatic reconnect. Protected by `lock`.
    private var intentionalDisconnect = false
    /// True once the config text frame has been written on the CURRENT
    /// socket. Audio must never be written before it: Starscream buffers
    /// pre-handshake writes and flushes them on upgrade, so PCM frames
    /// queued before `.connected` reach Soniox ahead of the config message
    /// and the server kills the stream with 400 "Start request must be a
    /// text message" — a non-retryable clientBug that stops the whole
    /// session seconds after it starts. Protected by `lock`.
    private var configSent = false
    private var retryCount = 0
    private var retryWorkItem: DispatchWorkItem?

    private static let maxRetries = 5
    private static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 8]

    init(apiKey: String, url: URL, translationConfig: TranslationConfig? = nil, contextTerms: [String] = []) {
        self.apiKey = apiKey
        self.url = url
        self.translationConfig = translationConfig
        self.contextTerms = contextTerms
    }

    func connect() {
        lock.lock()
        intentionalDisconnect = false
        retryCount = 0
        didOpen = false
        lock.unlock()
        emitStatus(.connecting)
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
        guard let socket = socket, configSent else {
            // Drop audio captured before the config frame is on the wire
            // (the WAV still keeps it) — see `configSent`.
            lock.unlock()
            let dropped = preConfigDropCount + 1
            preConfigDropCount = dropped
            if dropped == 1 || dropped % 500 == 0 {
                RTILog.log("sendAudio dropped pre-config frame #\(dropped) (\(data.count) bytes)", category: .soniox)
            }
            return
        }
        // Writing to an already-disconnected socket is handled gracefully
        // by Starscream: it triggers .cancelled, which handleDrop processes.
        socket.write(data: data)
        let sent = sentFrameCount + 1
        sentFrameCount = sent
        sentByteCount += data.count
        lock.unlock()
        if sent == 1 || sent % 500 == 0 {
            RTILog.log("sent audio frame #\(sent) (total \(sentByteCount) bytes)", category: .soniox)
        }
    }

    // Write-path diagnostics (2026-08-31): the system leg was observed
    // hitting Soniox's 20s no-data 408 while capture buffers appeared to
    // flow — these counters make "is anything actually written?" visible
    // in the log.
    private var preConfigDropCount = 0
    private var sentFrameCount = 0
    private var sentByteCount = 0

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
            didOpen = true
            retryCount = 0
            lock.unlock()
            RTILog.log("connected — sending config", category: .soniox)
            emitStatus(.live)
            sendConfig()

        case .text(let string):
            // NB: no per-frame logging here. Logging every inbound frame (tens
            // of thousands per long session) hopped to the main actor, mutated
            // the @Observable log buffer, and called NSLog on each — a real CPU
            // tax for zero diagnostic value. Final-token receipt is still logged
            // downstream in `handleMessage`. (Payload is live transcript content
            // and must never land in the user-copyable log buffer anyway.)
            handleMessage(string)

        case .disconnected(let reason, let code):
            handleDrop(SonioxFailure.fromTransport(reason: "disconnected code=\(code) reason=\(reason)"))

        case .error(let error):
            handleDrop(SonioxFailure.fromTransport(reason: "transport error \(String(describing: error))"))

        case .cancelled:
            handleDrop(SonioxFailure.fromTransport(reason: "cancelled"))

        default:
            break
        }
    }

    private func handleDrop(_ failure: SonioxFailure) {
        lock.lock()
        isConnected = false
        configSent = false
        let blocked = intentionalDisconnect
        let phaseDidOpen = didOpen
        lock.unlock()
        RTILog.log("dropped — \(failure)", category: .soniox)
        guard !blocked else { return }
        if failure.shouldRetry {
            scheduleReconnect(after: failure)
        } else {
            emitStatus(.failed)
            DispatchQueue.main.async { [weak self] in
                self?.onError?(failure, phaseDidOpen)
            }
        }
    }

    private func scheduleReconnect(after failure: SonioxFailure) {
        lock.lock()
        let phaseDidOpen = didOpen

        // One socket teardown emits several events (e.g. a server 408 is
        // followed by .disconnected(1000) and .cancelled), and each routes
        // through handleDrop. Scheduling a retry per event burned 2–3 of the
        // maxRetries budget per REAL drop, so a couple of genuine drops could
        // reach "max retries" and kill the session. If a retry is already
        // queued, this drop is part of the same teardown — keep the existing
        // attempt.
        guard retryWorkItem == nil else {
            lock.unlock()
            return
        }

        // Re-check intentionalDisconnect under the lock.  handleDrop releases
        // the lock between its check and this call, so `finalize` or
        // `disconnect` may have flipped the flag in that window.
        guard !intentionalDisconnect else {
            retryWorkItem = nil
            lock.unlock()
            return
        }
        guard retryCount < Self.maxRetries else {
            retryWorkItem = nil
            lock.unlock()
            RTILog.log("SonioxClient: max retries reached", category: .soniox)
            emitStatus(.failed)
            DispatchQueue.main.async { [weak self] in
                self?.onError?(failure, phaseDidOpen)
            }
            return
        }
        let delay = Self.retryDelays[min(retryCount, Self.retryDelays.count - 1)]
        retryCount += 1
        let attempt = retryCount

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.retryWorkItem = nil
            let blocked = self.intentionalDisconnect
            self.lock.unlock()
            guard !blocked else { return }
            self.openSocket()
        }
        retryWorkItem = item
        lock.unlock()

        RTILog.log("SonioxClient: reconnect attempt \(attempt) in \(delay)s", category: .soniox)
        emitStatus(.reconnecting)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func openSocket() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15 // WebSocket connect timeout
        let ws = WebSocket(request: request)
        ws.delegate = self
        lock.lock()
        socket = ws
        configSent = false
        lock.unlock()
        ws.connect()
    }

    private func sendConfig() {
        do {
            let config = SonioxConfigMessage.default(apiKey: apiKey, translation: translationConfig, contextTerms: contextTerms)
            let data = try JSONEncoder().encode(config)
            if let string = String(data: data, encoding: .utf8) {
                lock.lock()
                socket?.write(string: string)
                configSent = true
                lock.unlock()
                let hasTranslation = translationConfig != nil
                RTILog.log("sent config (translation=\(hasTranslation), contextTerms=\(contextTerms.count))", category: .soniox)
            }
        } catch {
            RTILog.log("SonioxClient: config encode failed: \(error)", category: .soniox)
        }
    }


    private func handleMessage(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        do {
            let msg = try JSONDecoder().decode(SonioxTranscriptMessage.self, from: data)
            if let code = msg.error_code {
                let detail = msg.error_message ?? "no detail"
                RTILog.log("server error code=\(code) \(detail)", category: .soniox)
                // Route server application errors through the same retry/fatal
                // gate as transport drops. A transient code (408 decode timeout,
                // 429, 5xx) must RECONNECT, not fire onError — otherwise a brief
                // gap of no decodable audio (other party silent, or a Bluetooth
                // mic blip) ends the whole session and auto-summarizes. Only
                // auth / clientBug (shouldRetry == false) escalate to onError.
                handleDrop(SonioxFailure.fromSonioxApplicationError(code: code, detail: detail))
                return
            }
            guard let raw = msg.tokens, !raw.isEmpty else { return }
            let words = raw.map { $0.toSonioxWord() }
            let finalCount = words.filter(\.isFinal).count
            if finalCount > 0 {
                RTILog.log("received \(words.count) tokens (\(finalCount) final)", category: .soniox)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onWords?(words)
            }
        } catch {
            RTILog.log("SonioxClient: decode failed: \(error)", category: .soniox)
        }
    }
}

// MARK: - STT provider abstraction

/// The runtime surface every speech-to-text provider exposes, so the audio
/// pipeline can drive Soniox, AssemblyAI, or a future/local engine
/// interchangeably. Construction is provider-specific (see `STTProviders`); this
/// protocol covers only the live streaming lifecycle. Words, failures, and
/// health stay shared value types (`SonioxWord` / `SonioxFailure` /
/// `TranscriptionHealth`) so every provider maps into one model and the rest of
/// the app is unchanged.
protocol STTClient: AnyObject, Sendable {
    var onWords: (([SonioxWord]) -> Void)? { get set }
    var onError: ((SonioxFailure, _ didOpen: Bool) -> Void)? { get set }
    var onStatus: ((TranscriptionHealth) -> Void)? { get set }
    func connect()
    func disconnect()
    func sendAudio(_ data: Data)
    func finalize()
}

/// One selectable speech-to-text backend. Mirrors `LLMProviderConfig`: a stable
/// id + display name + a factory that builds a live client. Kept as computed
/// literals (no stored shared state) so it stays `Sendable`.
struct STTProviderConfig: Sendable {
    let id: String
    let displayName: String
    let makeClient: @Sendable (_ translationConfig: TranslationConfig?, _ contextTerms: [String]) -> STTClient
}

/// A separate provider lane for offline / post-hoc transcript upgrade. This is
/// intentionally distinct from `STTProviders`: the best provider for low-latency
/// live diarization is not necessarily the best provider for a slower, more
/// accurate async pass over the session-local retained audio legs.
struct AsyncTranscriptProviderOption: Identifiable, Sendable {
    struct CredentialField: Identifiable, Sendable {
        let account: String
        let label: String
        let placeholder: String

        var id: String { account }
    }

    let id: String
    let displayName: String
    let credentialFields: [CredentialField]
    let summary: String

    var hasKey: Bool {
        credentialFields.allSatisfy {
            !(CredentialStore.value(for: $0.account) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }
}

/// Registry + active-selection for real-time STT. RTI's live lane is Soniox
/// only; the separate async transcript-upgrade lane is modeled below.
enum STTProviders {
    static var soniox: STTProviderConfig {
        STTProviderConfig(id: "soniox", displayName: "Soniox") { tc, terms in
            SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL,
                         translationConfig: tc, contextTerms: terms)
        }
    }

    static var all: [STTProviderConfig] { [soniox] }

    static var activeId: String {
        get { UserDefaults.standard.string(forKey: STTSettingsDefaults.activeProviderIdKey) ?? soniox.id }
        set { UserDefaults.standard.set(soniox.id, forKey: STTSettingsDefaults.activeProviderIdKey) }
    }
    static var active: STTProviderConfig { all.first { $0.id == activeId } ?? soniox }

    static var activeHasKey: Bool {
        return !Secrets.sonioxAPIKey.isEmpty
    }

    static func makeActiveClient(translationConfig: TranslationConfig?, contextTerms: [String]) -> STTClient {
        soniox.makeClient(translationConfig, contextTerms)
    }
}

/// Provider selection for the "Upgrade Transcript" path: a slower async
/// pass over the archived session's retained `.m4a` legs that can replace the rough
/// live transcript and then regenerate the summary from the upgraded text.
///
/// This setting does not affect the live transcript today. It exists now so the
/// provider model and user-facing settings reflect the real architectural split:
/// live capture vs post-hoc upgrade are different jobs with different provider
/// tradeoffs.
enum AsyncTranscriptProviders {
    static let soniox = AsyncTranscriptProviderOption(
        id: "soniox_file",
        displayName: "Soniox",
        credentialFields: [
            .init(account: "soniox", label: "Soniox API key", placeholder: "soniox-...")
        ],
        summary: "Reuse Soniox for offline file transcription when you want consistency with the live lane."
    )

    static let aliyun = AsyncTranscriptProviderOption(
        id: "aliyun_file",
        displayName: "Aliyun",
        credentialFields: [
            .init(account: "aliyun_access_key_id", label: "Aliyun Access Key ID", placeholder: "LTAI..."),
            .init(account: "aliyun_access_key_secret", label: "Aliyun Access Key Secret", placeholder: "secret..."),
            .init(account: "aliyun_nls_app_key", label: "Aliyun NLS App Key", placeholder: "appkey...")
        ],
        summary: "Preferred for Chinese-heavy async transcript upgrades."
    )

    static let all: [AsyncTranscriptProviderOption] = [soniox, aliyun]

    static var activeId: String {
        get { UserDefaults.standard.string(forKey: STTSettingsDefaults.asyncProviderIdKey) ?? soniox.id }
        set { UserDefaults.standard.set(newValue, forKey: STTSettingsDefaults.asyncProviderIdKey) }
    }

    static var active: AsyncTranscriptProviderOption {
        all.first { $0.id == activeId } ?? soniox
    }
}

// MARK: - AssemblyAI Universal-Streaming (v3) client

/// STT client for AssemblyAI's Universal-Streaming v3 API
/// (`wss://streaming.assemblyai.com/v3/ws`), an alternative to Soniox selectable
/// in Settings. Mirrors `SonioxClient`'s lifecycle and retry/drop semantics, and
/// maps AssemblyAI's `Turn` messages into the shared `SonioxWord` model so the
/// rest of the app is provider-agnostic.
///
/// Differences from Soniox: auth is the raw key in the `?token=` query param
/// (the v3 WS handshake takes no custom header); audio is sent as RAW BINARY
/// frames; results arrive as one `Turn` message type whose `end_of_turn` flag
/// distinguishes interim from final; end-of-stream is a `{"type":"Terminate"}`
/// TEXT frame (required — unterminated sessions bill for the full window).
/// Speaker diarization is requested live via `speaker_labels=true`.
final class AssemblyAIClient: WebSocketDelegate, STTClient, @unchecked Sendable {
    static let baseURL = "wss://streaming.assemblyai.com/v3/ws"

    var onWords: (([SonioxWord]) -> Void)?
    var onError: ((SonioxFailure, _ didOpen: Bool) -> Void)?
    var onStatus: ((TranscriptionHealth) -> Void)?

    private func emitStatus(_ health: TranscriptionHealth) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(health) }
    }

    private let apiKey: String
    private let lock = NSLock()
    private var socket: WebSocket?
    private var isConnected = false
    private var didOpen = false
    private var intentionalDisconnect = false
    private var retryCount = 0
    private var retryWorkItem: DispatchWorkItem?

    private static let maxRetries = 5
    private static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 8]

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private func makeURL() -> URL? {
        var comps = URLComponents(string: Self.baseURL)
        comps?.queryItems = [
            URLQueryItem(name: "speech_model", value: "u3-rt-pro"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: String(AudioFormat.sampleRateHz)),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speaker_labels", value: "true"),
            URLQueryItem(name: "token", value: apiKey)
        ]
        return comps?.url
    }

    func connect() {
        lock.lock()
        intentionalDisconnect = false
        retryCount = 0
        didOpen = false
        lock.unlock()
        emitStatus(.connecting)
        openSocket()
    }

    private func openSocket() {
        guard !apiKey.isEmpty, let url = makeURL() else {
            emitStatus(.failed)
            DispatchQueue.main.async { [weak self] in self?.onError?(.auth, false) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let ws = WebSocket(request: request)
        ws.delegate = self
        lock.lock()
        socket = ws
        lock.unlock()
        ws.connect()
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
        let s = socket
        lock.unlock()
        s?.write(data: data)  // raw binary PCM16 frame
    }

    func finalize() {
        lock.lock()
        guard let s = socket, isConnected else {
            lock.unlock()
            return
        }
        intentionalDisconnect = true
        retryWorkItem?.cancel()
        retryWorkItem = nil
        lock.unlock()
        // Required: cleanly end the session so AssemblyAI stops billing and
        // flushes the final Turn. The server replies with a Termination message.
        s.write(string: #"{"type":"Terminate"}"#)
    }

    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected:
            lock.lock()
            isConnected = true
            didOpen = true
            retryCount = 0
            lock.unlock()
            RTILog.log("assemblyai connected", category: .soniox)
            emitStatus(.live)

        case .text(let string):
            handleMessage(string)

        case .binary:
            break  // v3 sends results as text frames only

        case .disconnected(let reason, let code):
            handleDrop(SonioxFailure.fromTransport(reason: "disconnected code=\(code) reason=\(reason)"))

        case .error(let error):
            handleDrop(SonioxFailure.fromTransport(reason: "transport error \(String(describing: error))"))

        case .cancelled:
            handleDrop(SonioxFailure.fromTransport(reason: "cancelled"))

        default:
            break
        }
    }

    private func handleMessage(_ string: String) {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "Turn":
            let words = parseTurn(obj)
            guard !words.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onWords?(words) }
        case "Begin", "Termination", "SpeakerRevision":
            break
        default:
            break
        }
    }

    /// Map an AssemblyAI `Turn` (its word array) into shared `SonioxWord`s.
    /// `end_of_turn` marks the turn final; per-word `word_is_final` marks stable
    /// words within a growing partial turn. AssemblyAI word timestamps are
    /// already in milliseconds and words carry no trailing space, so we add one.
    private func parseTurn(_ obj: [String: Any]) -> [SonioxWord] {
        let endOfTurn = obj["end_of_turn"] as? Bool ?? false
        let turnSpeaker = obj["speaker_label"] as? String
        let language = obj["language_code"] as? String
        guard let rawWords = obj["words"] as? [[String: Any]], !rawWords.isEmpty else {
            return []
        }
        return rawWords.map { w in
            let raw = (w["text"] as? String) ?? ""
            return SonioxWord(
                text: raw.isEmpty ? "" : raw + " ",
                startMs: w["start"] as? Int ?? 0,
                endMs: w["end"] as? Int ?? 0,
                speaker: speakerIndex(w["speaker"] as? String ?? turnSpeaker),
                confidence: w["confidence"] as? Double ?? 1.0,
                isFinal: (w["word_is_final"] as? Bool ?? false) || endOfTurn,
                translationStatus: "none",
                language: language,
                sourceLanguage: nil
            )
        }
    }

    /// "A" → 0, "B" → 1, … Matches Soniox's integer speaker ids. Unknown/short
    /// turns ("UNKNOWN" / nil) collapse to 0.
    private func speakerIndex(_ label: String?) -> Int {
        guard let first = label?.uppercased().first,
              let ascii = first.asciiValue, first.isLetter else { return 0 }
        return Int(ascii) - Int(Character("A").asciiValue!)
    }

    // MARK: - Drop / reconnect (mirrors SonioxClient)

    private func handleDrop(_ failure: SonioxFailure) {
        lock.lock()
        isConnected = false
        let blocked = intentionalDisconnect
        let phaseDidOpen = didOpen
        lock.unlock()
        RTILog.log("assemblyai dropped — \(failure)", category: .soniox)
        guard !blocked else { return }
        if failure.shouldRetry {
            scheduleReconnect(after: failure)
        } else {
            emitStatus(.failed)
            DispatchQueue.main.async { [weak self] in self?.onError?(failure, phaseDidOpen) }
        }
    }

    private func scheduleReconnect(after failure: SonioxFailure) {
        lock.lock()
        let phaseDidOpen = didOpen
        retryWorkItem?.cancel()
        guard !intentionalDisconnect else {
            retryWorkItem = nil
            lock.unlock()
            return
        }
        guard retryCount < Self.maxRetries else {
            retryWorkItem = nil
            lock.unlock()
            RTILog.log("assemblyai: max retries reached", category: .soniox)
            emitStatus(.failed)
            DispatchQueue.main.async { [weak self] in self?.onError?(failure, phaseDidOpen) }
            return
        }
        let delay = Self.retryDelays[min(retryCount, Self.retryDelays.count - 1)]
        retryCount += 1
        let attempt = retryCount
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let blocked = self.intentionalDisconnect
            self.lock.unlock()
            guard !blocked else { return }
            self.openSocket()
        }
        retryWorkItem = item
        lock.unlock()
        RTILog.log("assemblyai: reconnect attempt \(attempt) in \(delay)s", category: .soniox)
        emitStatus(.reconnecting)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
