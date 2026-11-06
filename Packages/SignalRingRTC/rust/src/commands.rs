//! The commands (electron.rs `cm_*` and the static helpers), as JSON: `{"cmd": name, ...}`.
//! Each returns a JSON value (null when upstream returns undefined).

use std::{convert::TryFrom, sync::Arc, time::Duration};

use rand::rand_core::UnwrapErr;
use serde::Deserialize;
use serde_json::{Value, json};

use ringrtc::{
    common::{CallConfig, CallId, CallMediaType, DataMode, DeviceId},
    core::{
        assets::AssetHandle,
        call_manager::{CreateCallLinkCallParams, CreateGroupCallParams, SvcConfig},
        group_call, signaling,
    },
    lite::{
        call_links::{self, CallLinkDeleteRequest, CallLinkRestrictions, CallLinkRootKey, CallLinkUpdateRequest},
        sfu::{self, GroupMember, PeekArgs},
    },
    native::{GroupUpdate, NativeCallContext},
    webrtc::{
        media::{VideoFrame, VideoPixelFormat},
        peer_connection_factory::{IceServer, SetAudioWarmup},
    },
};

use crate::{b64, endpoint::{CallEndpoint, Event, INVALID_CLIENT_ID}, events};

// electron.rs limits on (non-screenshare) video that gets sent.
const MAX_VIDEO_WIDTH: u16 = 960;
const MAX_VIDEO_HEIGHT: u16 = 720;
const MAX_VIDEO_FPS: u8 = 30;
const GROUP_CALL_MAX_VIDEO_WIDTH: u16 = 640;
const GROUP_CALL_MAX_VIDEO_HEIGHT: u16 = 480;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IceServerArg {
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    hostname: String,
    urls: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CallConfigArg {
    data_mode: i32,
    dred_duration: u8,
    enable_vp9_encode: bool,
    enable_vp9_decode: bool,
    stats_interval_secs: Option<u16>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SvcConfigArg {
    mode: String,
    mode_for_screenshare: String,
    max_bitrate_bps: Option<i32>,
}

impl From<SvcConfigArg> for SvcConfig {
    fn from(a: SvcConfigArg) -> Self {
        SvcConfig { mode: a.mode, mode_for_screenshare: a.mode_for_screenshare, max_bitrate_bps: a.max_bitrate_bps }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemberArg {
    #[serde(with = "b64")]
    user_id: Vec<u8>,
    #[serde(with = "b64")]
    user_id_cipher_text: Vec<u8>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoRequestArg {
    demux_id: u32,
    width: u16,
    height: u16,
    framerate: Option<u16>,
}

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Command {
    // Static (no endpoint needed).
    CallIdFromEra { era: String },
    CallLinkRootKeyParse { string: String },
    CallLinkRootKeyValidate { #[serde(with = "b64")] bytes: Vec<u8> },
    CallLinkRootKeyGenerate,
    CallLinkRootKeyGenerateAdminPasskey,
    CallLinkRootKeyDeriveRoomId { #[serde(with = "b64")] bytes: Vec<u8> },
    CallLinkRootKeyToFormattedString { #[serde(with = "b64")] bytes: Vec<u8> },
    CallLinkRootKeyToRedactedString { #[serde(with = "b64")] bytes: Vec<u8> },

    SetSelfUuid { #[serde(with = "b64")] uuid: Vec<u8> },
    AddAsset { asset_group: String, file_path: Option<String>, #[serde(default, deserialize_with = "b64::opt::deserialize")] content: Option<Vec<u8>> },
    CreateOutgoingCall { peer_id: String, video_enabled: bool, local_device_id: DeviceId },
    CancelGroupRing { #[serde(with = "b64")] group_id: Vec<u8>, ring_id: String, reason: Option<i32> },
    Proceed { #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64, ice_servers: Vec<IceServerArg>, hide_ip: bool, call_config: CallConfigArg, audio_levels_interval_millis: u64 },
    Accept { #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64 },
    Ignore { #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64 },
    Hangup,
    SignalingMessageSent { #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64 },
    SignalingMessageSendFailed { #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64 },
    UpdateDataMode { data_mode: i32 },
    ReceivedOffer {
        peer_id: String, sender_device_id: DeviceId, receiver_device_id: DeviceId, age_sec: u64,
        #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64, offer_type: i32,
        #[serde(with = "b64")] opaque: Vec<u8>, #[serde(with = "b64")] sender_identity_key: Vec<u8>, #[serde(with = "b64")] receiver_identity_key: Vec<u8>,
    },
    ReceivedAnswer {
        peer_id: String, sender_device_id: DeviceId, #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64,
        #[serde(with = "b64")] opaque: Vec<u8>, #[serde(with = "b64")] sender_identity_key: Vec<u8>, #[serde(with = "b64")] receiver_identity_key: Vec<u8>,
    },
    ReceivedIceCandidates { peer_id: String, sender_device_id: DeviceId, #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64, #[serde(deserialize_with = "b64::list::deserialize")] candidates: Vec<Vec<u8>> },
    ReceivedHangup { peer_id: String, sender_device_id: DeviceId, #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64, hangup_type: i32, hangup_device_id: Option<DeviceId> },
    ReceivedBusy { peer_id: String, sender_device_id: DeviceId, #[serde(deserialize_with = "b64::id::deserialize")] call_id: u64 },
    ReceivedCallMessage { #[serde(with = "b64")] remote_user_id: Vec<u8>, remote_device_id: DeviceId, local_device_id: DeviceId, #[serde(with = "b64")] data: Vec<u8>, message_age_sec: u64 },
    ReceivedHttpResponse { request_id: u32, status_code: u16, #[serde(with = "b64")] body: Vec<u8> },
    HttpRequestFailed { request_id: u32, debug_info: Option<String> },
    SetOutgoingAudioEnabled { enabled: bool },
    SetMicrophoneWarmupEnabled { enabled: bool, request_id: u32 },
    SetOutgoingVideoEnabled { enabled: bool },
    SetOutgoingVideoIsScreenShare { is_screenshare: bool },
    CreateGroupCallClient { #[serde(with = "b64")] group_id: Vec<u8>, sfu_url: String, #[serde(with = "b64")] hkdf_extra_info: Vec<u8>, audio_levels_interval_millis: u64, dred_duration: u8, svc_config: Option<SvcConfigArg> },
    CreateCallLinkCallClient {
        sfu_url: String, #[serde(with = "b64")] endorsement_public_key: Vec<u8>, #[serde(with = "b64")] auth_presentation: Vec<u8>, #[serde(with = "b64")] root_key: Vec<u8>,
        #[serde(default, deserialize_with = "b64::opt::deserialize")] admin_passkey: Option<Vec<u8>>, #[serde(with = "b64")] hkdf_extra_info: Vec<u8>,
        audio_levels_interval_millis: u64, dred_duration: u8, svc_config: Option<SvcConfigArg>,
    },
    DeleteGroupCallClient { client_id: group_call::ClientId },
    Connect { client_id: group_call::ClientId },
    Join { client_id: group_call::ClientId },
    Leave { client_id: group_call::ClientId },
    Disconnect { client_id: group_call::ClientId },
    SetOutgoingAudioMuted { client_id: group_call::ClientId, muted: bool },
    SetOutgoingAudioMutedRemotely { client_id: group_call::ClientId, mute_source: u32 },
    SendRemoteMuteRequest { client_id: group_call::ClientId, mute_target: u32 },
    SetOutgoingVideoMuted { client_id: group_call::ClientId, muted: bool },
    SetPresenting { client_id: group_call::ClientId, presenting: bool },
    SetOutgoingGroupCallVideoIsScreenShare { client_id: group_call::ClientId, is_screenshare: bool },
    GroupRing { client_id: group_call::ClientId, #[serde(default, deserialize_with = "b64::opt::deserialize")] recipient: Option<Vec<u8>> },
    GroupReact { client_id: group_call::ClientId, reaction: String },
    GroupRaiseHand { client_id: group_call::ClientId, raise: bool },
    ResendMediaKeys { client_id: group_call::ClientId },
    SetDataMode { client_id: group_call::ClientId, data_mode: i32 },
    RequestVideo { client_id: group_call::ClientId, resolutions: Vec<VideoRequestArg>, active_speaker_height: u16 },
    ApproveUser { client_id: group_call::ClientId, #[serde(with = "b64")] other_user_id: Vec<u8> },
    DenyUser { client_id: group_call::ClientId, #[serde(with = "b64")] other_user_id: Vec<u8> },
    RemoveClient { client_id: group_call::ClientId, other_demux_id: u32 },
    BlockClient { client_id: group_call::ClientId, other_demux_id: u32 },
    SetGroupMembers { client_id: group_call::ClientId, members: Vec<MemberArg> },
    SetMembershipProof { client_id: group_call::ClientId, #[serde(with = "b64")] proof: Vec<u8> },
    PeekGroupCall { request_id: u32, sfu_url: String, #[serde(with = "b64")] membership_proof: Vec<u8>, members: Vec<MemberArg> },
    PeekCallLinkCall { request_id: u32, sfu_url: String, #[serde(with = "b64")] auth_presentation: Vec<u8>, #[serde(with = "b64")] root_key: Vec<u8> },
    ReadCallLink { request_id: u32, sfu_url: String, #[serde(with = "b64")] auth_presentation: Vec<u8>, #[serde(with = "b64")] root_key: Vec<u8> },
    CreateCallLink {
        request_id: u32, sfu_url: String, #[serde(with = "b64")] create_presentation: Vec<u8>, #[serde(with = "b64")] root_key: Vec<u8>,
        #[serde(with = "b64")] admin_passkey: Vec<u8>, #[serde(with = "b64")] public_zkparams: Vec<u8>, restrictions: Option<i8>,
    },
    UpdateCallLink {
        request_id: u32, sfu_url: String, #[serde(with = "b64")] auth_presentation: Vec<u8>, #[serde(with = "b64")] root_key: Vec<u8>,
        #[serde(with = "b64")] admin_passkey: Vec<u8>, new_name: Option<String>, new_restrictions: Option<i8>, new_revoked: Option<bool>,
    },
    DeleteCallLink { request_id: u32, sfu_url: String, #[serde(with = "b64")] auth_presentation: Vec<u8>, #[serde(with = "b64")] root_key: Vec<u8>, #[serde(with = "b64")] admin_passkey: Vec<u8> },
    GetAudioInputs,
    SetAudioInputById { id: String, request_id: u32 },
    GetAudioOutputs,
    SetAudioOutputById { id: String, request_id: u32 },
    SetVoiceProcessingEnabled { enabled: bool, request_id: u32 },
    SetRtcStatsInterval { client_id: group_call::ClientId, interval_millis: u64 },
}

impl Command {
    pub fn is_static(&self) -> bool {
        matches!(
            self,
            Command::CallIdFromEra { .. }
                | Command::CallLinkRootKeyParse { .. }
                | Command::CallLinkRootKeyValidate { .. }
                | Command::CallLinkRootKeyGenerate
                | Command::CallLinkRootKeyGenerateAdminPasskey
                | Command::CallLinkRootKeyDeriveRoomId { .. }
                | Command::CallLinkRootKeyToFormattedString { .. }
                | Command::CallLinkRootKeyToRedactedString { .. }
        )
    }
}

fn root_key(bytes: &[u8]) -> anyhow::Result<CallLinkRootKey> {
    CallLinkRootKey::try_from(bytes).map_err(|e| anyhow::anyhow!("{e}"))
}

fn restrictions(raw: Option<i8>) -> Option<CallLinkRestrictions> {
    match raw {
        Some(0) => Some(CallLinkRestrictions::None),
        Some(1) => Some(CallLinkRestrictions::AdminApproval),
        _ => None,
    }
}

fn interval(ms: u64) -> Option<Duration> {
    if ms == 0 { None } else { Some(Duration::from_millis(ms)) }
}

fn members(m: Vec<MemberArg>) -> Vec<GroupMember> {
    m.into_iter().map(|m| GroupMember { user_id: m.user_id, member_id: m.user_id_cipher_text }).collect()
}

pub fn run_static(cmd: Command) -> anyhow::Result<Value> {
    Ok(match cmd {
        Command::CallIdFromEra { era } => json!((i64::from(group_call::RingId::from_era_id(&era)) as u64).to_string()),
        Command::CallLinkRootKeyParse { string } => json!(b64::encode(root_key_from_str(&string)?.as_slice())),
        Command::CallLinkRootKeyValidate { bytes } => {
            root_key(&bytes)?;
            Value::Null
        }
        Command::CallLinkRootKeyGenerate => json!(b64::encode(CallLinkRootKey::generate(UnwrapErr(rand::rngs::SysRng)).as_slice())),
        Command::CallLinkRootKeyGenerateAdminPasskey => json!(b64::encode(&CallLinkRootKey::generate_admin_passkey(UnwrapErr(rand::rngs::SysRng)))),
        Command::CallLinkRootKeyDeriveRoomId { bytes } => json!(b64::encode(&root_key(&bytes)?.derive_room_id())),
        Command::CallLinkRootKeyToFormattedString { bytes } => json!(root_key(&bytes)?.to_formatted_string()),
        Command::CallLinkRootKeyToRedactedString { bytes } => json!(root_key(&bytes)?.to_redacted_string()),
        _ => anyhow::bail!("not a static command"),
    })
}

fn root_key_from_str(s: &str) -> anyhow::Result<CallLinkRootKey> {
    CallLinkRootKey::try_from(s).map_err(|e| anyhow::anyhow!("{e}"))
}

pub fn run(ep: &mut CallEndpoint, cmd: Command) -> anyhow::Result<Value> {
    Ok(match cmd {
        c if c.is_static() => return run_static(c),
        Command::SetSelfUuid { uuid } => {
            ep.call_manager.set_self_uuid(uuid)?;
            Value::Null
        }
        Command::AddAsset { asset_group, file_path, content } => {
            let handle = match (file_path, content) {
                (_, Some(bytes)) => AssetHandle::Content(bytes),
                (Some(path), _) => AssetHandle::FilePath(path),
                _ => anyhow::bail!("addAsset requires either a filePath or content"),
            };
            ep.call_manager.add_asset(&asset_group, handle)?;
            Value::Null
        }
        Command::CreateOutgoingCall { peer_id, video_enabled, local_device_id } => {
            let media_type = if video_enabled { CallMediaType::Video } else { CallMediaType::Audio };
            let call_id = CallId::random();
            ep.call_manager.create_outgoing_call(peer_id, call_id, media_type, local_device_id);
            json!(call_id.as_u64().to_string())
        }
        Command::CancelGroupRing { group_id, ring_id, reason } => {
            let ring_id: i64 = ring_id.parse().map_err(|_| anyhow::anyhow!("invalid serial number"))?;
            let reason = reason.map(group_call::RingCancelReason::try_from).transpose().map_err(|e| anyhow::anyhow!("{e}"))?;
            ep.call_manager.cancel_group_ring(group_id, ring_id.into(), reason)?;
            Value::Null
        }
        Command::Proceed { call_id, ice_servers, hide_ip, call_config, audio_levels_interval_millis } => {
            let call_id = CallId::new(call_id);
            let ice_servers = ice_servers.into_iter().map(|s| IceServer::new(s.username, s.password, s.hostname, s.urls)).collect();
            let call_context = NativeCallContext::new(
                hide_ip,
                ice_servers,
                ep.outgoing_audio_track.clone(),
                ep.outgoing_video_track.clone(),
                ep.incoming_video_sink.clone(),
            );
            ep.outgoing_video_track.set_content_hint(false);
            ep.incoming_video_sink.clear();
            ep.outgoing_video_source.adapt_output_format(MAX_VIDEO_WIDTH, MAX_VIDEO_HEIGHT, MAX_VIDEO_FPS);
            let mut config = CallConfig::default()
                .with_data_mode(DataMode::from_i32(call_config.data_mode))
                .with_dred_duration(call_config.dred_duration)
                .with_enable_vp9_encode(call_config.enable_vp9_encode)
                .with_enable_vp9_decode(call_config.enable_vp9_decode);
            if let Some(secs) = call_config.stats_interval_secs {
                config = config.with_stats_interval_secs(secs);
            }
            ep.call_manager.proceed(call_id, call_context, config, interval(audio_levels_interval_millis));
            Value::Null
        }
        Command::Accept { call_id } => {
            ep.call_manager.accept_call(CallId::new(call_id));
            Value::Null
        }
        Command::Ignore { call_id } => {
            ep.call_manager.drop_call(CallId::new(call_id));
            Value::Null
        }
        Command::Hangup => {
            ep.call_manager.hangup();
            Value::Null
        }
        Command::SignalingMessageSent { call_id } => {
            ep.call_manager.message_sent(CallId::new(call_id));
            Value::Null
        }
        Command::SignalingMessageSendFailed { call_id } => {
            ep.call_manager.message_send_failure(CallId::new(call_id));
            Value::Null
        }
        Command::UpdateDataMode { data_mode } => {
            if let Ok(c) = ep.call_manager.active_connection() {
                c.update_data_mode(DataMode::from_i32(data_mode))?;
            }
            Value::Null
        }
        Command::ReceivedOffer { peer_id, sender_device_id, receiver_device_id, age_sec, call_id, offer_type, opaque, sender_identity_key, receiver_identity_key } => {
            let media = if offer_type == 1 { CallMediaType::Video } else { CallMediaType::Audio };
            let offer = signaling::Offer::new(media, opaque)?;
            ep.call_manager.received_offer(
                peer_id,
                CallId::new(call_id),
                signaling::ReceivedOffer { offer, age: Duration::from_secs(age_sec), sender_device_id, receiver_device_id, sender_identity_key, receiver_identity_key },
            );
            Value::Null
        }
        Command::ReceivedAnswer { peer_id, sender_device_id, call_id, opaque, sender_identity_key, receiver_identity_key } => {
            let answer = signaling::Answer::new(opaque)?;
            ep.call_manager.received_answer(
                peer_id,
                CallId::new(call_id),
                signaling::ReceivedAnswer { answer, sender_device_id, sender_identity_key, receiver_identity_key },
            );
            Value::Null
        }
        Command::ReceivedIceCandidates { peer_id, sender_device_id, call_id, candidates } => {
            let candidates = candidates.into_iter().map(signaling::IceCandidate::new).collect();
            ep.call_manager.received_ice(peer_id, CallId::new(call_id), signaling::ReceivedIce { ice: signaling::Ice { candidates }, sender_device_id });
            Value::Null
        }
        Command::ReceivedHangup { peer_id, sender_device_id, call_id, hangup_type, hangup_device_id } => {
            let hangup_type = signaling::HangupType::from_i32(hangup_type).unwrap_or(signaling::HangupType::Normal);
            // As upstream: a missing device id is 0 (from_type_and_device_id assumes it).
            let hangup = signaling::Hangup::from_type_and_device_id(hangup_type, hangup_device_id.unwrap_or(0));
            ep.call_manager.received_hangup(peer_id, CallId::new(call_id), signaling::ReceivedHangup { hangup, sender_device_id });
            Value::Null
        }
        Command::ReceivedBusy { peer_id, sender_device_id, call_id } => {
            ep.call_manager.received_busy(peer_id, CallId::new(call_id), signaling::ReceivedBusy { sender_device_id });
            Value::Null
        }
        Command::ReceivedCallMessage { remote_user_id, remote_device_id, local_device_id, data, message_age_sec } => {
            ep.call_manager.received_call_message(remote_user_id, remote_device_id, local_device_id, data, Duration::from_secs(message_age_sec));
            Value::Null
        }
        Command::ReceivedHttpResponse { request_id, status_code, body } => {
            ep.call_manager.received_http_response(request_id, Some(ringrtc::lite::http::Response { status: status_code.into(), body }));
            Value::Null
        }
        Command::HttpRequestFailed { request_id, debug_info } => {
            log::error!("HTTP request {} failed: {}", request_id, debug_info.unwrap_or_else(|| "<no debug info>".into()));
            ep.call_manager.received_http_response(request_id, None);
            Value::Null
        }
        Command::SetOutgoingAudioEnabled { enabled } => {
            ep.outgoing_audio_track.set_enabled(enabled);
            if let Ok(mut c) = ep.call_manager.active_connection() {
                c.update_sender_status(signaling::SenderStatus { audio_enabled: Some(enabled), ..Default::default() })?;
            }
            Value::Null
        }
        Command::SetMicrophoneWarmupEnabled { enabled, request_id } => {
            ep.peer_connection_factory.set_audio_warmup(if enabled { SetAudioWarmup::Enable(request_id) } else { SetAudioWarmup::Disable })?;
            Value::Null
        }
        Command::SetOutgoingVideoEnabled { enabled } => {
            ep.outgoing_video_track.set_enabled(enabled);
            if let Ok(mut c) = ep.call_manager.active_connection() {
                c.update_sender_status(signaling::SenderStatus { video_enabled: Some(enabled), ..Default::default() })?;
            }
            Value::Null
        }
        Command::SetOutgoingVideoIsScreenShare { is_screenshare } => {
            ep.outgoing_video_track.set_content_hint(is_screenshare);
            let (w, h, fps) = if is_screenshare { (0, 0, 0) } else { (MAX_VIDEO_WIDTH, MAX_VIDEO_HEIGHT, MAX_VIDEO_FPS) };
            ep.outgoing_video_source.adapt_output_format(w, h, fps);
            if let Ok(mut c) = ep.call_manager.active_connection() {
                c.send_is_screenshare_update(is_screenshare)?;
            }
            Value::Null
        }
        Command::CreateGroupCallClient { group_id, sfu_url, hkdf_extra_info, audio_levels_interval_millis, dred_duration, svc_config } => {
            ep.outgoing_video_source.adapt_output_format(GROUP_CALL_MAX_VIDEO_WIDTH, GROUP_CALL_MAX_VIDEO_HEIGHT, MAX_VIDEO_FPS);
            let client_id = ep
                .call_manager
                .create_group_call_client(CreateGroupCallParams {
                    group_id,
                    sfu_url,
                    hkdf_extra_info,
                    audio_levels_interval: interval(audio_levels_interval_millis),
                    dred_duration,
                    svc_config: svc_config.map(Into::into),
                    peer_connection_factory: Some(ep.peer_connection_factory.clone()),
                    outgoing_audio_track: ep.outgoing_audio_track.clone(),
                    outgoing_video_track: ep.outgoing_video_track.clone(),
                    incoming_video_sink: Some(ep.incoming_video_sink.clone()),
                })
                .unwrap_or(INVALID_CLIENT_ID);
            json!(client_id)
        }
        Command::CreateCallLinkCallClient { sfu_url, endorsement_public_key, auth_presentation, root_key: rk, admin_passkey, hkdf_extra_info, audio_levels_interval_millis, dred_duration, svc_config } => {
            let root_key = root_key(&rk)?;
            let client_id = ep
                .call_manager
                .create_call_link_call_client(CreateCallLinkCallParams {
                    sfu_url,
                    endorsement_public_key: &endorsement_public_key,
                    auth_presentation: &auth_presentation,
                    root_key,
                    admin_passkey,
                    hkdf_extra_info,
                    audio_levels_interval: interval(audio_levels_interval_millis),
                    dred_duration,
                    svc_config: svc_config.map(Into::into),
                    peer_connection_factory: Some(ep.peer_connection_factory.clone()),
                    outgoing_audio_track: ep.outgoing_audio_track.clone(),
                    outgoing_video_track: ep.outgoing_video_track.clone(),
                    incoming_video_sink: Some(ep.incoming_video_sink.clone()),
                })
                .unwrap_or(INVALID_CLIENT_ID);
            json!(client_id)
        }
        Command::DeleteGroupCallClient { client_id } => {
            ep.call_manager.delete_group_call_client(client_id);
            Value::Null
        }
        Command::Connect { client_id } => {
            ep.call_manager.connect(client_id);
            Value::Null
        }
        Command::Join { client_id } => {
            ep.outgoing_video_track.set_content_hint(false);
            ep.call_manager.join(client_id);
            Value::Null
        }
        Command::Leave { client_id } => {
            ep.outgoing_audio_track.set_enabled(false);
            ep.outgoing_video_track.set_enabled(false);
            ep.outgoing_video_track.set_content_hint(false);
            ep.call_manager.leave(client_id);
            Value::Null
        }
        Command::Disconnect { client_id } => {
            ep.outgoing_audio_track.set_enabled(false);
            ep.outgoing_video_track.set_enabled(false);
            ep.outgoing_video_track.set_content_hint(false);
            ep.call_manager.disconnect(client_id);
            Value::Null
        }
        Command::SetOutgoingAudioMuted { client_id, muted } => {
            ep.outgoing_audio_track.set_enabled(!muted);
            ep.call_manager.set_outgoing_audio_muted(client_id, muted);
            Value::Null
        }
        Command::SetOutgoingAudioMutedRemotely { client_id, mute_source } => {
            ep.outgoing_audio_track.set_enabled(false);
            ep.call_manager.set_outgoing_audio_muted_remotely(client_id, mute_source);
            Value::Null
        }
        Command::SendRemoteMuteRequest { client_id, mute_target } => {
            ep.call_manager.send_remote_mute_request(client_id, mute_target);
            Value::Null
        }
        Command::SetOutgoingVideoMuted { client_id, muted } => {
            ep.outgoing_video_track.set_enabled(!muted);
            ep.call_manager.set_outgoing_video_muted(client_id, muted);
            Value::Null
        }
        Command::SetPresenting { client_id, presenting } => {
            ep.call_manager.set_presenting(client_id, presenting);
            Value::Null
        }
        Command::SetOutgoingGroupCallVideoIsScreenShare { client_id, is_screenshare } => {
            let track = ep.outgoing_video_track.clone();
            ep.call_manager.reconfigure_video_encoder_for_screenshare(client_id, track, is_screenshare);
            let (w, h, fps) = if is_screenshare { (0, 0, 0) } else { (GROUP_CALL_MAX_VIDEO_WIDTH, GROUP_CALL_MAX_VIDEO_HEIGHT, MAX_VIDEO_FPS) };
            ep.outgoing_video_source.adapt_output_format(w, h, fps);
            ep.call_manager.set_sharing_screen(client_id, is_screenshare);
            Value::Null
        }
        Command::GroupRing { client_id, recipient } => {
            ep.call_manager.group_ring(client_id, recipient);
            Value::Null
        }
        Command::GroupReact { client_id, reaction } => {
            ep.call_manager.react(client_id, reaction);
            Value::Null
        }
        Command::GroupRaiseHand { client_id, raise } => {
            ep.call_manager.raise_hand(client_id, raise);
            Value::Null
        }
        Command::ResendMediaKeys { client_id } => {
            ep.call_manager.resend_media_keys(client_id);
            Value::Null
        }
        Command::SetDataMode { client_id, data_mode } => {
            ep.call_manager.set_data_mode(client_id, DataMode::from_i32(data_mode));
            Value::Null
        }
        Command::RequestVideo { client_id, resolutions, active_speaker_height } => {
            let r = resolutions.into_iter().map(|r| group_call::VideoRequest { demux_id: r.demux_id, width: r.width, height: r.height, framerate: r.framerate }).collect();
            ep.call_manager.request_video(client_id, r, active_speaker_height);
            Value::Null
        }
        Command::ApproveUser { client_id, other_user_id } => {
            ep.call_manager.approve_user(client_id, other_user_id);
            Value::Null
        }
        Command::DenyUser { client_id, other_user_id } => {
            ep.call_manager.deny_user(client_id, other_user_id);
            Value::Null
        }
        Command::RemoveClient { client_id, other_demux_id } => {
            ep.call_manager.remove_client(client_id, other_demux_id);
            Value::Null
        }
        Command::BlockClient { client_id, other_demux_id } => {
            ep.call_manager.block_client(client_id, other_demux_id);
            Value::Null
        }
        Command::SetGroupMembers { client_id, members: m } => {
            ep.call_manager.set_group_members(client_id, members(m));
            Value::Null
        }
        Command::SetMembershipProof { client_id, proof } => {
            ep.call_manager.set_membership_proof(client_id, proof);
            Value::Null
        }
        Command::PeekGroupCall { request_id, sfu_url, membership_proof, members: m } => {
            ep.call_manager.peek_group_call(request_id, sfu_url, membership_proof, members(m));
            Value::Null
        }
        Command::PeekCallLinkCall { request_id, sfu_url, auth_presentation, root_key: rk } => {
            let root_key = root_key(&rk)?;
            let reporter = ep.event_reporter.clone();
            sfu::peek(
                ep.call_manager.http_client(),
                &sfu_url,
                PeekArgs {
                    room_id_header: None,
                    auth_header: call_links::auth_header_from_auth_credential(&auth_presentation),
                    member_resolver: Arc::new(call_links::CallLinkMemberResolver::from(&root_key)),
                    call_link_root_key: Some(root_key),
                },
                Box::new(move |peek_result| {
                    let _ = reporter.send(Event::GroupUpdate(GroupUpdate::PeekResult { request_id, peek_result }));
                }),
            );
            Value::Null
        }
        Command::ReadCallLink { request_id, sfu_url, auth_presentation, root_key: rk } => {
            let reporter = ep.event_reporter.clone();
            call_links::read_call_link(ep.call_manager.http_client(), &sfu_url, root_key(&rk)?, &auth_presentation, Box::new(move |result| {
                let _ = reporter.send(Event::CallLinkResponse { request_id, result });
            }));
            Value::Null
        }
        Command::CreateCallLink { request_id, sfu_url, create_presentation, root_key: rk, admin_passkey, public_zkparams, restrictions: r } => {
            let reporter = ep.event_reporter.clone();
            call_links::create_call_link(
                ep.call_manager.http_client(),
                &sfu_url,
                root_key(&rk)?,
                &create_presentation,
                &admin_passkey,
                &public_zkparams,
                restrictions(r),
                Box::new(move |result| {
                    let _ = reporter.send(Event::CallLinkResponse { request_id, result });
                }),
            );
            Value::Null
        }
        Command::UpdateCallLink { request_id, sfu_url, auth_presentation, root_key: rk, admin_passkey, new_name, new_restrictions, new_revoked } => {
            let root_key = root_key(&rk)?;
            let encrypted_name = new_name.map(|name| if name.is_empty() { vec![] } else { root_key.encrypt(name.as_bytes(), UnwrapErr(rand::rngs::SysRng)) });
            let reporter = ep.event_reporter.clone();
            call_links::update_call_link(
                ep.call_manager.http_client(),
                &sfu_url,
                root_key,
                &auth_presentation,
                &CallLinkUpdateRequest { admin_passkey: &admin_passkey, encrypted_name: encrypted_name.as_deref(), restrictions: restrictions(new_restrictions), revoked: new_revoked },
                Box::new(move |result| {
                    let _ = reporter.send(Event::CallLinkResponse { request_id, result });
                }),
            );
            Value::Null
        }
        Command::DeleteCallLink { request_id, sfu_url, auth_presentation, root_key: rk, admin_passkey } => {
            let reporter = ep.event_reporter.clone();
            call_links::delete_call_link(
                ep.call_manager.http_client(),
                &sfu_url,
                root_key(&rk)?,
                &auth_presentation,
                &CallLinkDeleteRequest { admin_passkey: &admin_passkey },
                Box::new(move |result| {
                    let _ = reporter.send(Event::EmptyResponse { request_id, result });
                }),
            );
            Value::Null
        }
        Command::GetAudioInputs => match ep.peer_connection_factory.get_audio_recording_devices() {
            Ok(d) => events::device_list(&d),
            Err(_) => Value::Null,
        },
        Command::SetAudioInputById { id, request_id } => {
            ep.peer_connection_factory.set_audio_recording_device_by_id(&id, request_id)?;
            Value::Null
        }
        Command::GetAudioOutputs => match ep.peer_connection_factory.get_audio_playout_devices() {
            Ok(d) => events::device_list(&d),
            Err(_) => Value::Null,
        },
        Command::SetAudioOutputById { id, request_id } => {
            ep.peer_connection_factory.set_audio_playout_device_by_id(&id, request_id)?;
            Value::Null
        }
        Command::SetVoiceProcessingEnabled { enabled, request_id } => {
            ep.peer_connection_factory.set_input_voice_processing_enabled(enabled, request_id)?;
            Value::Null
        }
        Command::SetRtcStatsInterval { client_id, interval_millis } => {
            ep.call_manager.set_rtc_stats_interval(client_id, Duration::from_millis(interval_millis));
            Value::Null
        }
        _ => unreachable!("static commands handled above"),
    })
}

/// `sendVideoFrame`.
pub fn send_video_frame(ep: &mut CallEndpoint, width: u32, height: u32, pixel_format: i32, data: &[u8]) -> anyhow::Result<()> {
    let format = VideoPixelFormat::from_i32(pixel_format).ok_or_else(|| anyhow::anyhow!("Invalid pixel format"))?;
    // WebRTC copies exactly the frame's size from `data` (no length is passed down), so the
    // slice must hold the whole frame.
    let needed = frame_size(width, height, format).ok_or_else(|| anyhow::anyhow!("Invalid frame size {}x{}", width, height))?;
    if data.len() != needed {
        anyhow::bail!("Frame buffer is {} bytes, {}x{} needs {}", data.len(), width, height, needed);
    }
    ep.outgoing_video_source.push_frame(VideoFrame::copy_from_slice(width, height, format, data));
    Ok(())
}

/// The byte size of a packed frame; None for empty or oversized dimensions.
pub fn frame_size(width: u32, height: u32, format: VideoPixelFormat) -> Option<usize> {
    if width == 0 || height == 0 || width > 8192 || height > 8192 {
        return None;
    }
    let (w, h) = (width as usize, height as usize);
    Some(match format {
        VideoPixelFormat::I420 | VideoPixelFormat::Nv12 => w * h + 2 * w.div_ceil(2) * h.div_ceil(2),
        VideoPixelFormat::Rgba => w * h * 4,
    })
}

/// `receive_video_frame`: the latest frame of `demux_id` (0 for a 1:1 call), rotated, as RGBA
/// into `rgba`; (width, height), or None (no new frame, too large, or not I420).
pub fn receive_video_frame(ep: &mut CallEndpoint, demux_id: u32, max_width: u32, max_height: u32, rgba: &mut [u8]) -> Option<(u32, u32)> {
    let frame = ep.incoming_video_sink.pop(demux_id)?;
    let (fs, fl) = ringrtc::core::util::minmax(frame.width(), frame.height());
    let (ms, ml) = ringrtc::core::util::minmax(max_width, max_height);
    if fs > ms || fl > ml {
        if ep.most_recent_overlarge_frame_dimensions != (fs, fl) {
            log::warn!("dropping overlarge frames {}x{} ({}); this is likely a problem on the send side", frame.width(), frame.height(), demux_id);
            ep.most_recent_overlarge_frame_dimensions = (fs, fl);
        }
        return None;
    }
    let frame = frame.apply_rotation();
    let needed = frame.width() as usize * frame.height() as usize * 4;
    if rgba.len() < needed || !frame.to_rgba(&mut rgba[..needed]) {
        return None;
    }
    Some((frame.width(), frame.height()))
}
