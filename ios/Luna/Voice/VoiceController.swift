import AVFoundation
import Foundation
import Observation
@preconcurrency import WebRTC

@MainActor @Observable final class VoiceController: NSObject {
    enum State: String { case idle = "Voice", connecting = "Connecting", listening = "Listening", muted = "Mic muted", failed = "Disconnected" }
    var state: State = .idle
    var voiceID: String?
    var sessionID: String?
    var agentID: String?
    var microphoneMuted = false
    var speakerMuted = false
    var failure: String?
    var isActive: Bool { state != .idle && state != .failed }
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var channel: RTCDataChannel?
    @ObservationIgnored private var localAudio: RTCAudioTrack?
    @ObservationIgnored private var remoteAudio: RTCAudioTrack?
    @ObservationIgnored private var live: OpenAILiveSession?
    @ObservationIgnored var onStopped: (() -> Void)?
    @ObservationIgnored private var audioSession: VoiceAudioSession?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    func start(key: String, sessionID: String, title: String, global: Bool = false, initialContext: JSONObject = [:], execute: @escaping (String, JSONObject, String) async throws -> JSONObject, transcript: @escaping (String, String) -> Void, switchSession: @escaping (String) -> Void) async throws {
        await stop()
        let current = UUID()
        epoch = current
        self.sessionID = sessionID
        state = .connecting
        failure = nil
        do {
            let permitted = await AVAudioApplication.requestRecordPermission()
            guard epoch == current else { throw CancellationError() }
            guard permitted else { throw ServiceError(message: "Microphone access is off. Enable it for Luna in Settings, or use text chat.") }
            let audio = VoiceAudioSession()
            audioSession = audio
            try audio.prepare()
            let configuration = RTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
                throw ServiceError(message: "The audio connection could not be created.")
            }
            peer = connection
            let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "luna-microphone")
            track.isEnabled = false
            localAudio = track
            connection.add(track, streamIds: ["luna-audio"])
            channel = connection.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
            channel?.delegate = self
            let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
                connection.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio":"true"], optionalConstraints: nil)) { sdp, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let sdp { continuation.resume(returning: sdp) }
                    else { continuation.resume(throwing: ServiceError(message: "Voice negotiation failed.")) }
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.setLocalDescription(offer) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            for _ in 0..<160 {
                guard epoch == current else { throw CancellationError() }
                if connection.iceGatheringState == .complete { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard connection.iceGatheringState == .complete, let sdp = connection.localDescription?.sdp else {
                throw ServiceError(message: "Voice couldn't find a network route. Try another network.")
            }
            let control = OpenAILiveSession(key: key, sessionID: sessionID, title: title, global: global, initialContext: initialContext, execute: execute)
            live = control
            control.onTranscript = transcript
            control.onSwitch = switchSession
            control.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.epoch == current else { return }
                    self.failure = message; await self.stop()
                }
            }
            control.onClosed = { [weak self] in
                Task { @MainActor in
                    guard let self, self.epoch == current else { return }
                    await self.stop()
                }
            }
            let answer = try await control.start(sdp: sdp)
            guard epoch == current else { await control.close(); throw CancellationError() }
            voiceID = answer.voice_id
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer.sdp)) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }

        } catch {
            if epoch == current { await stop() }
            throw error
        }
    }

    func finished(_ run: AgentRun, agentID: String? = nil, agentName: String? = nil) async {
        await live?.finished(run, agentID: agentID, agentName: agentName)
    }
    func updateDestination(_ address: SessionAddress?) async {
        var context = address.map { ["agent_id": JSONValue.string($0.agentID), "session_id": .string($0.sessionID)] } ?? [:]
        context["current_time"] = .number(Date().timeIntervalSince1970)
        context["time_zone"] = .string(TimeZone.current.identifier)
        await live?.updateDestination(context)
    }

    func toggleMicrophone() {
        setMicrophoneMuted(!microphoneMuted)
    }
    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
        localAudio?.isEnabled = !muted && isActive && state != .connecting
        if isActive && state != .connecting { state = muted ? .muted : .listening }
    }

    func toggleSpeaker() {
        speakerMuted.toggle()
        remoteAudio?.isEnabled = !speakerMuted
        if speakerMuted {
            send(["type":"session.instructions.append", "event_id":"quiet_" + UUID().uuidString,
                  "delegation_id": NSNull(), "content":"Stop speaking now. Wait for the user. Keep backend work running."])
        }
    }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        channel?.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func stop() async {
        epoch = UUID()
        localAudio?.isEnabled = false
        remoteAudio?.isEnabled = false
        audioSession?.stop()
        audioSession = nil
        let previousLive = live
        live = nil
        let previousPeer = peer
        let previousChannel = channel
        peer = nil; channel = nil; localAudio = nil; remoteAudio = nil
        voiceID = nil; sessionID = nil; agentID = nil
        state = .idle; microphoneMuted = false; speakerMuted = false
        // Microphone and speaker are already off while final usage is delivered.
        await previousLive?.close()
        previousChannel?.close(); previousPeer?.close()
        onStopped?()
    }
}

extension VoiceController: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            guard self.peer === peerConnection else { return }
            self.remoteAudio = stream.audioTracks.first
            self.remoteAudio?.isEnabled = !self.speakerMuted
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard self.peer === peerConnection else { return }
            if newState == .failed {
                self.failure = "Voice lost its network connection. Agent work continues."
                await self.stop()
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        Task { @MainActor in
            guard self.peer === peerConnection else { return }
            if let audio = transceiver.receiver.track as? RTCAudioTrack {
                self.remoteAudio = audio; audio.isEnabled = !self.speakerMuted
            }
        }
    }
}

extension VoiceController: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
              let type = event["type"] as? String else { return }
        Task { @MainActor in
            guard self.channel === dataChannel else { return }
            if type == "session.started" {
                self.audioSession?.enable()
                self.state = self.microphoneMuted ? .muted : .listening
                self.localAudio?.isEnabled = !self.microphoneMuted
            }
        }
    }
}
