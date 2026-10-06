import Speech
import AVFoundation
import SwiftUI

@MainActor final class PromptSpeech: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var failure: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapped = false
    private var audioActive = false
    private var runID = UUID()
    private var interruption: NSObjectProtocol?

    init() {
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func start() async {
        guard !isStarting, !isRecording else { return }
        let id = UUID(); runID = id
        isStarting = true; failure = nil; transcript = ""
        defer { if runID == id { isStarting = false } }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard runID == id else { return }
        guard speech == .authorized else { failure = "Allow speech recognition in Settings to dictate. You can also type your prompt."; return }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard runID == id else { return }
        guard microphone else { failure = "Allow microphone access in Settings to dictate. You can also type your prompt."; return }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            failure = "Dictation is unavailable right now. Type your prompt or try again later."; return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            audioActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechFailure.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true
            engine.prepare()
            try engine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.runID == id else { return }
                    if let text { self.transcript = text }
                    if failed || finished {
                        if failed && self.transcript.isEmpty { self.failure = "Dictation couldn't finish. Type your prompt or try again." }
                        self.stop()
                    }
                }
            }
        } catch {
            stop()
            failure = "The microphone couldn't start. Type your prompt or try dictation again."
        }
    }

    func stop() {
        runID = UUID(); isStarting = false
        let hadAudio = audioActive
        audioActive = false
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); task?.cancel()
        request = nil; task = nil; isRecording = false
        if hadAudio { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }
    private enum SpeechFailure: Error { case noInput }
}
