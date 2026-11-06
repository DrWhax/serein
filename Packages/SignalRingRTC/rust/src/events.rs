//! Events as JSON (electron.rs `processEvents`): one object per event, `"type"` named after
//! the observer method upstream calls, with the same arguments.

use std::time::Duration;

use serde_json::{Value, json};
use strum::IntoDiscriminant;

use ringrtc::{
    common::CallMediaType,
    core::{
        call_summary::{CallSummary, MediaQualityStats, QualityStats},
        group_call, signaling,
    },
    lite::{
        call_links::{CallLinkRestrictions, CallLinkState},
        http,
        sfu::PeekInfo,
    },
    native::{CallState, GroupUpdate, RejectReason},
    webrtc::peer_connection_factory::{AudioDevice, AudioDeviceList, DefaultAudioDevice},
};

use crate::{
    b64::encode as b64,
    endpoint::{CallEndpoint, Event, LOG_MESSAGES},
};

fn millis(t: std::time::SystemTime) -> u64 {
    t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

pub fn audio_device(d: &AudioDevice) -> Value {
    json!({ "name": d.name, "uniqueId": d.unique_id })
}

pub fn device_list(d: &AudioDeviceList) -> Value {
    let defaults = match &d.default {
        DefaultAudioDevice::Windows(win) => json!({
            "isWindows": true,
            "consoleDevice": win.console_device.as_ref().map(audio_device),
            "communicationsDevice": win.communications_device.as_ref().map(audio_device),
        }),
        DefaultAudioDevice::NonWindows(dev) => json!({ "isWindows": false, "device": dev.as_ref().map(audio_device) }),
    };
    json!({ "devices": d.list.iter().map(audio_device).collect::<Vec<_>>(), "defaults": defaults })
}

fn call_link_state(s: &CallLinkState) -> Value {
    json!({
        "name": s.name,
        "revoked": s.revoked,
        "rawRestrictions": match s.restrictions {
            CallLinkRestrictions::None => 0,
            CallLinkRestrictions::AdminApproval => 1,
            CallLinkRestrictions::Unknown => -1,
        },
        "expirationMillis": millis(s.expiration),
        "rootKey": b64(s.root_key.as_slice()),
    })
}

fn peek_info(p: &PeekInfo) -> Value {
    let pending: Vec<String> = p.unique_pending_users().iter().map(|u| b64(u)).collect();
    json!({
        "devices": p.devices.iter().map(|d| json!({ "demuxId": d.demux_id, "userId": d.user_id.as_ref().map(|u| b64(u)) })).collect::<Vec<_>>(),
        "creator": p.creator.as_ref().map(|c| b64(c)),
        "eraId": p.era_id,
        "maxDevices": p.max_devices,
        "deviceCountIncludingPendingDevices": p.device_count_including_pending_devices(),
        "deviceCountExcludingPendingDevices": p.devices.len(),
        "pendingUsers": pending,
        "callLinkState": p.call_link_state.as_ref().map(call_link_state),
    })
}

fn media_quality(m: &MediaQualityStats) -> Value {
    json!({
        "rttMedianMillis": m.rtt_median,
        "jitterMedianSendMillis": m.jitter_median_send,
        "jitterMedianRecvMillis": m.jitter_median_recv,
        "packetLossFractionSend": m.packet_loss_fraction_send,
        "packetLossFractionRecv": m.packet_loss_fraction_recv,
    })
}

fn quality(q: &QualityStats) -> Value {
    json!({ "rttMedianConnectionMillis": q.rtt_median_connection, "audioStats": media_quality(&q.audio_stats), "videoStats": media_quality(&q.video_stats) })
}

fn summary(s: &CallSummary) -> Value {
    json!({
        "callIdHash": s.call_id_hash.as_ref().map(|h| b64(h)),
        "startTime": u64::from(s.start_time.clone()),
        "endTime": u64::from(s.end_time.clone()),
        "qualityStats": quality(&s.quality_stats),
        "rawStats": s.raw_stats.as_ref().map(|r| b64(r)),
        "rawStatsText": s.raw_stats_text,
        "callEndReasonText": s.call_end_reason_text,
        "isSurveyCandidate": s.is_survey_candidate,
    })
}

/// The pending log messages and the given events, as JSON objects.
pub fn to_json(ep: &mut CallEndpoint, events: Vec<Event>) -> Vec<Value> {
    let mut out = Vec::new();
    for l in std::mem::take(&mut *LOG_MESSAGES.lock().expect("log messages")) {
        out.push(json!({ "type": "onLogMessage", "level": l.level, "file": l.file, "line": l.line, "message": l.message }));
    }
    for event in events {
        if let Some(v) = event_json(ep, event) {
            out.push(v);
        }
    }
    out
}

fn event_json(ep: &mut CallEndpoint, event: Event) -> Option<Value> {
    Some(match event {
        Event::Wake => return None,
        Event::SendSignaling(peer_id, device_id, call_id, message) => {
            let base = |t: &str| json!({
                "type": t, "remoteUserId": peer_id, "remoteDeviceId": device_id.unwrap_or(0),
                "callId": call_id.as_u64().to_string(), "broadcast": device_id.is_none(),
            });
            let mut v = match &message {
                signaling::Message::Offer(_) => base("onSendOffer"),
                signaling::Message::Answer(_) => base("onSendAnswer"),
                signaling::Message::Ice(_) => base("onSendIceCandidates"),
                signaling::Message::Hangup(_) => base("onSendHangup"),
                signaling::Message::Busy => base("onSendBusy"),
            };
            let o = v.as_object_mut().unwrap();
            match message {
                signaling::Message::Offer(offer) => {
                    o.insert("offerType".into(), json!(offer.call_media_type as i32));
                    o.insert("opaque".into(), json!(b64(&offer.opaque)));
                }
                signaling::Message::Answer(answer) => {
                    o.insert("opaque".into(), json!(b64(&answer.opaque)));
                }
                signaling::Message::Ice(ice) => {
                    o.insert("candidates".into(), json!(ice.candidates.iter().map(|c| b64(&c.opaque)).collect::<Vec<_>>()));
                }
                signaling::Message::Hangup(hangup) => {
                    let (t, d) = hangup.to_type_and_device_id();
                    o.insert("hangupType".into(), json!(t as i32));
                    o.insert("hangupDeviceId".into(), json!(d));
                }
                signaling::Message::Busy => {}
            }
            v
        }
        Event::CallState(peer_id, call_id, CallState::Incoming(media)) => {
            json!({ "type": "onStartIncomingCall", "remoteUserId": peer_id, "callId": call_id.as_u64().to_string(), "isVideoCall": media == CallMediaType::Video })
        }
        Event::CallState(peer_id, call_id, CallState::Outgoing(_)) => {
            json!({ "type": "onStartOutgoingCall", "remoteUserId": peer_id, "callId": call_id.as_u64().to_string() })
        }
        Event::CallState(peer_id, call_id, CallState::Rejected(reason)) => {
            let age = match reason {
                RejectReason::ReceivedOfferExpired { age } => age,
                _ => Duration::ZERO,
            };
            json!({ "type": "onCallRejected", "remoteUserId": peer_id, "callId": call_id.as_u64().to_string(), "reason": reason.discriminant() as i32, "ageSec": age.as_secs_f64() })
        }
        Event::CallState(peer_id, call_id, CallState::Ended(reason, s)) => {
            json!({ "type": "onCallEnded", "remoteUserId": peer_id, "callId": call_id.as_u64().to_string(), "reason": reason as i32, "summary": summary(&s) })
        }
        Event::CallState(peer_id, _call_id, state) => {
            let s = match state {
                CallState::Ringing => "ringing",
                CallState::Connected => "connected",
                CallState::Connecting => "connecting",
                CallState::Concluded => {
                    // The core sends nothing more for this call: a good time to clear frames.
                    ep.incoming_video_sink.clear();
                    return None;
                }
                CallState::Incoming(_) => "incoming",
                CallState::Outgoing(_) => "outgoing",
                CallState::Ended(..) => "ended",
                CallState::Rejected(_) => "rejected",
            };
            json!({ "type": "onCallState", "remoteUserId": peer_id, "state": s })
        }
        Event::NetworkRouteChange(peer_id, route) => {
            json!({ "type": "onNetworkRouteChanged", "remoteUserId": peer_id, "localNetworkAdapterType": route.local_adapter_type as i32 })
        }
        Event::RemoteAudioStateChange(peer_id, enabled) => json!({ "type": "onRemoteAudioEnabled", "remoteUserId": peer_id, "enabled": enabled }),
        Event::RemoteVideoStateChange(peer_id, enabled) => {
            if enabled {
                ep.incoming_video_sink.clear();
            }
            json!({ "type": "onRemoteVideoEnabled", "remoteUserId": peer_id, "enabled": enabled })
        }
        Event::RemoteSharingScreenChange(peer_id, enabled) => json!({ "type": "onRemoteSharingScreen", "remoteUserId": peer_id, "enabled": enabled }),
        Event::AudioLevels { peer_id, captured_level, received_level } => {
            json!({ "type": "onAudioLevels", "remoteUserId": peer_id, "capturedLevel": captured_level, "receivedLevel": received_level })
        }
        Event::LowBandwidthForVideo { peer_id, recovered } => json!({ "type": "onLowBandwidthForVideo", "remoteUserId": peer_id, "recovered": recovered }),
        Event::SendHttpRequest { request_id, request: http::Request { method, url, headers, body } } => {
            let headers: serde_json::Map<String, Value> = headers.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
            json!({ "type": "sendHttpRequest", "requestId": request_id, "url": url, "method": method as i32, "headers": headers, "body": body.as_ref().map(|b| b64(b)) })
        }
        Event::SendCallMessage { recipient_id, message, urgency } => {
            json!({ "type": "sendCallMessage", "recipientUuid": b64(&recipient_id), "message": b64(&message), "urgency": urgency as i32 })
        }
        Event::SendCallMessageToGroup { group_id, message, urgency, recipients_override } => json!({
            "type": "sendCallMessageToGroup", "groupId": b64(&group_id), "message": b64(&message), "urgency": urgency as i32,
            "overrideRecipients": recipients_override.iter().map(|r| b64(r)).collect::<Vec<_>>(),
        }),
        Event::SendCallMessageToAdhocGroup { message, urgency, expiration, recipients_to_endorsements } => json!({
            "type": "sendCallMessageToAdhocGroup", "message": b64(&message), "urgency": urgency as i32, "expirationMillis": 1000 * expiration,
            "recipientsToEndorsements": recipients_to_endorsements.iter().map(|(r, e)| json!({ "recipientId": b64(r), "endorsement": b64(e) })).collect::<Vec<_>>(),
        }),
        Event::CallLinkResponse { request_id, result } => match result {
            Ok(state) => json!({ "type": "handleCallLinkResponse", "requestId": request_id, "status": 200, "state": call_link_state(&state) }),
            Err(s) => json!({ "type": "handleCallLinkResponse", "requestId": request_id, "status": s.code }),
        },
        Event::EmptyResponse { request_id, result } => match result {
            Ok(_) => json!({ "type": "handleEmptyResponse", "requestId": request_id, "status": 200 }),
            Err(s) => json!({ "type": "handleEmptyResponse", "requestId": request_id, "status": s.code }),
        },
        Event::GroupUpdate(update) => group_update(ep, update),
        Event::OutputDeviceChanged(d) => json!({ "type": "onOutputDeviceChanged", "devices": device_list(&d) }),
        Event::InputDeviceChanged(d) => json!({ "type": "onInputDeviceChanged", "devices": device_list(&d) }),
        Event::SettlePlaybackStart(s) => json!({ "type": "onSettleStartPlayback", "success": s.success, "device": s.audio_device.as_ref().map(audio_device) }),
        Event::SettleRecordingStart(s) => json!({ "type": "onSettleStartRecording", "success": s.success, "device": s.audio_device.as_ref().map(audio_device) }),
        Event::SettleAudioPromise { success, audio_device: d, request_id } => {
            json!({ "type": "onSettleAudioPromise", "success": success, "device": d.as_ref().map(audio_device), "requestId": request_id })
        }
    })
}

fn group_update(ep: &mut CallEndpoint, update: GroupUpdate) -> Value {
    match update {
        GroupUpdate::RequestMembershipProof(client_id) => json!({ "type": "requestMembershipProof", "clientId": client_id }),
        GroupUpdate::RequestGroupMembers(client_id) => json!({ "type": "requestGroupMembers", "clientId": client_id }),
        GroupUpdate::ConnectionStateChanged(client_id, state) => json!({ "type": "handleConnectionStateChanged", "clientId": client_id, "connectionState": state.ordinal() }),
        GroupUpdate::NetworkRouteChanged(client_id, route) => {
            json!({ "type": "handleNetworkRouteChanged", "clientId": client_id, "localNetworkAdapterType": route.local_adapter_type as i32 })
        }
        GroupUpdate::JoinStateChanged(client_id, join_state) => {
            let demux = match join_state {
                group_call::JoinState::Pending(d) | group_call::JoinState::Joined(d) => Some(d),
                _ => None,
            };
            json!({ "type": "handleJoinStateChanged", "clientId": client_id, "joinState": join_state.ordinal(), "demuxId": demux })
        }
        GroupUpdate::RemoteDeviceStatesChanged(client_id, states) => json!({
            "type": "handleRemoteDevicesChanged", "clientId": client_id,
            "remoteDeviceStates": states.iter().map(|s| json!({
                "demuxId": s.demux_id,
                "userId": b64(&s.user_id),
                "mediaKeysReceived": s.media_keys_received,
                "audioMuted": s.heartbeat_state.audio_muted,
                "videoMuted": s.heartbeat_state.video_muted,
                "presenting": s.heartbeat_state.presenting,
                "sharingScreen": s.heartbeat_state.sharing_screen,
                "addedTime": s.added_time_as_unix_millis().to_string(),
                "speakerTime": s.speaker_time_as_unix_millis().to_string(),
                "forwardingVideo": s.forwarding_video,
                "isHigherResolutionPending": s.is_higher_resolution_pending,
            })).collect::<Vec<_>>(),
        }),
        GroupUpdate::PeekChanged { client_id, peek_info: p } => json!({ "type": "handlePeekChanged", "clientId": client_id, "info": peek_info(&p) }),
        GroupUpdate::PeekResult { request_id, peek_result } => match peek_result {
            Ok(p) => json!({ "type": "handlePeekResponse", "requestId": request_id, "status": 200, "info": peek_info(&p) }),
            Err(s) => json!({ "type": "handlePeekResponse", "requestId": request_id, "status": s.code }),
        },
        GroupUpdate::Ended(client_id, reason, s) => {
            ep.incoming_video_sink.clear();
            json!({ "type": "handleEnded", "clientId": client_id, "reason": reason as i32, "summary": summary(&s) })
        }
        GroupUpdate::Ring { group_id, ring_id, sender_id, update } => json!({
            "type": "groupCallRingUpdate", "groupId": b64(&group_id), "ringId": i64::from(ring_id).to_string(), "sender": b64(&sender_id), "update": update as i32,
        }),
        GroupUpdate::AudioLevels(client_id, captured, received) => json!({
            "type": "handleAudioLevels", "clientId": client_id, "capturedLevel": captured,
            "receivedLevels": received.iter().map(|r| json!({ "demuxId": r.demux_id, "level": r.level })).collect::<Vec<_>>(),
        }),
        GroupUpdate::LowBandwidthForVideo { group_id: client_id, recovered } => json!({ "type": "handleLowBandwidthForVideo", "clientId": client_id, "recovered": recovered }),
        GroupUpdate::Reactions(client_id, reactions) => json!({
            "type": "handleReactions", "clientId": client_id,
            "reactions": reactions.into_iter().map(|r| json!({ "demuxId": r.demux_id, "value": r.value })).collect::<Vec<_>>(),
        }),
        GroupUpdate::RaisedHands(client_id, hands) => json!({ "type": "handleRaisedHands", "clientId": client_id, "raisedHands": hands }),
        GroupUpdate::RtcStatsReportComplete { report_json } => json!({ "type": "handleRtcStatsReportComplete", "reportJson": report_json }),
        GroupUpdate::SpeechEvent(client_id, event) => json!({ "type": "handleSpeechEvent", "clientId": client_id, "event": event as i32 }),
        GroupUpdate::RemoteMute { client_id, mute_source } => json!({ "type": "onRemoteMute", "clientId": client_id, "demuxId": mute_source }),
        GroupUpdate::ObservedRemoteMute { client_id, mute_source, mute_target } => {
            json!({ "type": "onObservedRemoteMute", "clientId": client_id, "sourceDemuxId": mute_source, "targetDemuxId": mute_target })
        }
    }
}
