import AVFoundation
@preconcurrency import WebRTC

/// Coordinate audio through WebRTC's lock and activation count. Configuring
/// AVAudioSession directly can race WebRTC while it starts its audio unit.
@MainActor final class VoiceAudioSession {
    private var activated = false

    func prepare() throws {
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        try audio.setConfiguration(configuration)
        try audio.setActive(true)
        activated = true
    }

    func enable() {
        guard activated else { return }
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    func stop() {
        guard activated else { return }
        let audio = RTCAudioSession.sharedInstance()
        audio.isAudioEnabled = false
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        try? audio.setActive(false)
        activated = false
    }
}
