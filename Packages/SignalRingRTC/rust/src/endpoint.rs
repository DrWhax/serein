//! The call endpoint (electron.rs `CallEndpoint`): ringrtc's CallManager over the native
//! platform, its outgoing tracks and incoming sink, and the event queue the app drains.

use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc, LazyLock, Mutex,
        mpsc::{Receiver, Sender, channel},
    },
};

use ringrtc::{
    common::{CallId, DeviceId, Result},
    core::{
        call_manager::CallManager,
        group_call::{self, GroupId, SignalingMessageUrgency},
        signaling,
    },
    lite::{
        call_links::{CallLinkState, Empty},
        http,
        sfu::{DemuxId, UserId},
    },
    native::{CallState, CallStateHandler, GroupUpdate, GroupUpdateHandler, NativePlatform, PeerId, SignalingSender},
    webrtc::{
        media::{AudioTrack, VideoFrame, VideoSink, VideoSource, VideoTrack},
        peer_connection::AudioLevel,
        peer_connection_factory::{self as pcf, AudioDevice, AudioDeviceList, AudioDeviceObserver, PeerConnectionFactory},
        peer_connection_observer::NetworkRoute,
    },
};

/// Log messages, delivered with the next event batch (as upstream: logging while events are
/// processed must not schedule more processing).
pub struct LogMessage {
    pub level: i8,
    pub file: String,
    pub line: u32,
    pub message: String,
}

pub static LOG_MESSAGES: LazyLock<Mutex<Vec<LogMessage>>> = LazyLock::new(|| Mutex::new(Vec::new()));
pub static LOG_WAKE: LazyLock<Mutex<Option<Sender<Event>>>> = LazyLock::new(|| Mutex::new(None));

pub struct Log;
pub static LOG: Log = Log;

impl log::Log for Log {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Debug
    }
    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let message = LogMessage {
            level: record.level() as i8,
            file: record.file().unwrap_or("").to_string(),
            line: record.line().unwrap_or(0),
            message: record.args().to_string(),
        };
        if let Ok(mut m) = LOG_MESSAGES.lock() {
            // Bounded: a stalled reader must not grow this forever.
            if m.len() < 10_000 {
                m.push(message);
            }
        }
        if let Ok(w) = LOG_WAKE.lock()
            && let Some(s) = w.as_ref()
        {
            let _ = s.send(Event::Wake);
        }
    }
    fn flush(&self) {}
}

#[derive(Debug, Clone)]
pub struct AudioCallbackSettle {
    pub success: bool,
    pub audio_device: Option<AudioDevice>,
}

/// electron.rs `Event`, plus `Wake` (a log message arrived).
pub enum Event {
    Wake,
    SendSignaling(PeerId, Option<DeviceId>, CallId, signaling::Message),
    SendCallMessage { recipient_id: UserId, message: Vec<u8>, urgency: SignalingMessageUrgency },
    SendCallMessageToGroup { group_id: GroupId, message: Vec<u8>, urgency: SignalingMessageUrgency, recipients_override: Vec<UserId> },
    SendCallMessageToAdhocGroup { message: Vec<u8>, urgency: SignalingMessageUrgency, expiration: u64, recipients_to_endorsements: HashMap<UserId, Vec<u8>> },
    CallState(PeerId, CallId, CallState),
    RemoteAudioStateChange(PeerId, bool),
    RemoteVideoStateChange(PeerId, bool),
    RemoteSharingScreenChange(PeerId, bool),
    GroupUpdate(GroupUpdate),
    CallLinkResponse { request_id: u32, result: std::result::Result<CallLinkState, http::ResponseStatus> },
    EmptyResponse { request_id: u32, result: std::result::Result<Empty, http::ResponseStatus> },
    SendHttpRequest { request_id: u32, request: http::Request },
    NetworkRouteChange(PeerId, NetworkRoute),
    AudioLevels { peer_id: PeerId, captured_level: AudioLevel, received_level: AudioLevel },
    LowBandwidthForVideo { peer_id: PeerId, recovered: bool },
    OutputDeviceChanged(AudioDeviceList),
    InputDeviceChanged(AudioDeviceList),
    SettlePlaybackStart(AudioCallbackSettle),
    SettleAudioPromise { success: bool, audio_device: Option<AudioDevice>, request_id: u32 },
    SettleRecordingStart(AudioCallbackSettle),
}

#[derive(Clone)]
pub struct EventReporter {
    sender: Sender<Event>,
}

impl EventReporter {
    pub fn send(&self, event: Event) -> Result<()> {
        self.sender.send(event)?;
        Ok(())
    }
}

impl SignalingSender for EventReporter {
    fn send_signaling(&self, recipient_id: &str, call_id: CallId, receiver_device_id: Option<DeviceId>, msg: signaling::Message) -> Result<()> {
        self.send(Event::SendSignaling(recipient_id.to_string(), receiver_device_id, call_id, msg))
    }
    fn send_call_message(&self, recipient_id: UserId, message: Vec<u8>, urgency: SignalingMessageUrgency) -> Result<()> {
        self.send(Event::SendCallMessage { recipient_id, message, urgency })
    }
    fn send_call_message_to_group(&self, group_id: GroupId, message: Vec<u8>, urgency: SignalingMessageUrgency, recipients_override: HashSet<UserId>) -> Result<()> {
        self.send(Event::SendCallMessageToGroup { group_id, message, urgency, recipients_override: recipients_override.into_iter().collect() })
    }
    fn send_call_message_to_adhoc_group(&self, message: Vec<u8>, urgency: SignalingMessageUrgency, expiration: u64, recipients_to_endorsements: HashMap<UserId, Vec<u8>>) -> Result<()> {
        self.send(Event::SendCallMessageToAdhocGroup { message, urgency, expiration, recipients_to_endorsements })
    }
}

impl CallStateHandler for EventReporter {
    fn handle_call_state(&self, remote_peer_id: &str, call_id: CallId, call_state: CallState) -> Result<()> {
        self.send(Event::CallState(remote_peer_id.to_string(), call_id, call_state))
    }
    fn handle_network_route(&self, remote_peer_id: &str, network_route: NetworkRoute) -> Result<()> {
        self.send(Event::NetworkRouteChange(remote_peer_id.to_string(), network_route))
    }
    fn handle_remote_audio_state(&self, remote_peer_id: &str, enabled: bool) -> Result<()> {
        self.send(Event::RemoteAudioStateChange(remote_peer_id.to_string(), enabled))
    }
    fn handle_remote_video_state(&self, remote_peer_id: &str, enabled: bool) -> Result<()> {
        self.send(Event::RemoteVideoStateChange(remote_peer_id.to_string(), enabled))
    }
    fn handle_remote_sharing_screen(&self, remote_peer_id: &str, enabled: bool) -> Result<()> {
        self.send(Event::RemoteSharingScreenChange(remote_peer_id.to_string(), enabled))
    }
    fn handle_audio_levels(&self, remote_peer_id: &str, captured_level: AudioLevel, received_level: AudioLevel) -> Result<()> {
        self.send(Event::AudioLevels { peer_id: remote_peer_id.to_string(), captured_level, received_level })
    }
    fn handle_low_bandwidth_for_video(&self, remote_peer_id: &str, recovered: bool) -> Result<()> {
        self.send(Event::LowBandwidthForVideo { peer_id: remote_peer_id.to_string(), recovered })
    }
}

impl http::Delegate for EventReporter {
    fn send_request(&self, request_id: u32, request: http::Request) {
        let _ = self.send(Event::SendHttpRequest { request_id, request });
    }
}

impl GroupUpdateHandler for EventReporter {
    fn handle_group_update(&self, update: GroupUpdate) -> Result<()> {
        self.send(Event::GroupUpdate(update))
    }
}

pub struct DeviceObserver {
    event_reporter: EventReporter,
}

impl std::fmt::Debug for DeviceObserver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DeviceObserver")
    }
}

impl AudioDeviceObserver for DeviceObserver {
    fn output_changed(&self, devices: AudioDeviceList) {
        let _ = self.event_reporter.send(Event::OutputDeviceChanged(devices));
    }
    fn input_changed(&self, devices: AudioDeviceList) {
        let _ = self.event_reporter.send(Event::InputDeviceChanged(devices));
    }
    fn settle_start_playback_via_callback(&self, success: bool, audio_device: Option<AudioDevice>) {
        let _ = self.event_reporter.send(Event::SettlePlaybackStart(AudioCallbackSettle { success, audio_device }));
    }
    fn settle_promise(&self, success: bool, audio_device: Option<AudioDevice>, request_id: u32) {
        let _ = self.event_reporter.send(Event::SettleAudioPromise { success, audio_device, request_id });
    }
    fn settle_start_recording_via_callback(&self, success: bool, audio_device: Option<AudioDevice>) {
        let _ = self.event_reporter.send(Event::SettleRecordingStart(AudioCallbackSettle { success, audio_device }));
    }
}

/// The most recent frame per remote demux id (electron.rs `LastFramesVideoSink`).
#[derive(Clone, Default)]
pub struct LastFramesVideoSink {
    last_frame_by_demux_id: Arc<Mutex<HashMap<u32, VideoFrame>>>,
}

impl VideoSink for LastFramesVideoSink {
    fn on_video_frame(&self, demux_id: DemuxId, frame: VideoFrame) {
        self.last_frame_by_demux_id.lock().unwrap().insert(demux_id, frame);
    }
    fn box_clone(&self) -> Box<dyn VideoSink> {
        Box::new(self.clone())
    }
}

impl LastFramesVideoSink {
    pub fn pop(&self, demux_id: u32) -> Option<VideoFrame> {
        self.last_frame_by_demux_id.lock().unwrap().remove(&demux_id)
    }
    pub fn clear(&self) {
        self.last_frame_by_demux_id.lock().unwrap().clear();
    }
}

pub struct CallEndpoint {
    pub call_manager: CallManager<NativePlatform>,
    pub event_reporter: EventReporter,
    pub outgoing_audio_track: AudioTrack,
    pub outgoing_video_source: VideoSource,
    pub outgoing_video_track: VideoTrack,
    pub incoming_video_sink: Box<LastFramesVideoSink>,
    pub peer_connection_factory: PeerConnectionFactory,
    pub most_recent_overlarge_frame_dimensions: (u32, u32),
}

impl CallEndpoint {
    pub fn new(field_trial_string: &str) -> Result<(Self, Receiver<Event>)> {
        let (events_sender, events_receiver) = channel::<Event>();
        let event_reporter = EventReporter { sender: events_sender.clone() };
        *LOG_WAKE.lock().expect("log wake") = Some(events_sender);

        let peer_connection_factory = PeerConnectionFactory::new(
            &pcf::AudioConfig::default(),
            false,
            field_trial_string,
            Some(Box::new(DeviceObserver { event_reporter: event_reporter.clone() })),
        )?;
        let outgoing_audio_track = peer_connection_factory.create_outgoing_audio_track()?;
        outgoing_audio_track.set_enabled(false);
        let outgoing_video_source = peer_connection_factory.create_outgoing_video_source()?;
        let outgoing_video_track = peer_connection_factory.create_outgoing_video_track(&outgoing_video_source)?;
        outgoing_video_track.set_enabled(false);
        let incoming_video_sink = Box::<LastFramesVideoSink>::default();
        log::info!("audio_device_module using cubeb backend {:?}", peer_connection_factory.audio_backend());

        let platform = NativePlatform::new(
            peer_connection_factory.clone(),
            Box::new(event_reporter.clone()),
            false, // use the app's async "message sent" notifications
            Box::new(event_reporter.clone()),
            Box::new(event_reporter.clone()),
        );
        let call_manager = CallManager::new(platform, http::DelegatingClient::new(event_reporter.clone()))?;
        Ok((
            Self {
                call_manager,
                event_reporter,
                outgoing_audio_track,
                outgoing_video_source,
                outgoing_video_track,
                incoming_video_sink,
                peer_connection_factory,
                most_recent_overlarge_frame_dimensions: (0, 0),
            },
            events_receiver,
        ))
    }
}

/// The client id ringrtc uses for "no client".
pub const INVALID_CLIENT_ID: group_call::ClientId = group_call::INVALID_CLIENT_ID;
