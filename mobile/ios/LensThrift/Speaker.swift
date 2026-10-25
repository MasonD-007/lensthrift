import AVFoundation

/// Says the backend's line with the phone's built-in voice. No model, works offline.
@MainActor
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = Speaker.bestVoice()

    init() {
        // Playback, so it speaks with the silent switch on and through earbuds.
        // Ducks other audio instead of stopping it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    /// Speaks `line`, cutting off anything still being said so the newest find wins.
    func say(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Slightly brisk, like the web client's rate of 1.1.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        synthesizer.speak(utterance)
    }

    /// Prefers a premium or enhanced English voice if one is downloaded in Settings.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
