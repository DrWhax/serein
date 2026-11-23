// Local-only fixture issuer following Signal Calling Service frontend/src/api/call_links.rs test vectors.
// SPDX-License-Identifier: AGPL-3.0-only
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::json;
use std::time::{SystemTime, UNIX_EPOCH};
use zkgroup::call_links::{
    CallLinkAuthCredentialResponse, CallLinkSecretParams, CreateCallLinkCredentialRequestContext,
};
use zkgroup::generic_server_params::{
    GenericServerSecretParams, GenericServerSecretParamsStandard,
};

fn main() {
    let room = hex::decode(std::env::args().nth(1).expect("room id")).unwrap();
    let root: Vec<u8> = (0..16).collect();
    let link = CallLinkSecretParams::derive_from_root_key(&root);
    let server: GenericServerSecretParams =
        GenericServerSecretParamsStandard::generate(rand::random()).into();
    let params = server.get_public_params();
    let today = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        / 86400
        * 86400;
    let date = zkgroup::Timestamp::from_epoch_seconds(today);
    let aci = libsignal_core::Aci::from_uuid_bytes([5; 16]);
    let context = CreateCallLinkCredentialRequestContext::new(&room, rand::random());
    let response = context
        .get_request()
        .issue(aci, date, &server, rand::random());
    let create = context.receive(response, aci, &params).unwrap().present(
        &room,
        aci,
        &params,
        &link,
        rand::random(),
    );
    let auth = CallLinkAuthCredentialResponse::issue_credential(aci, date, &server, rand::random())
        .receive(aci, date, &params)
        .unwrap()
        .present(aci, date, &params, &link, rand::random());
    println!(
        "{}",
        json!({
            "server": STANDARD.encode(zkgroup::serialize(&server)),
            "publicZkparams": STANDARD.encode(zkgroup::serialize(&link.get_public_params())),
            "createPresentation": STANDARD.encode(zkgroup::serialize(&create)),
            "authPresentation": STANDARD.encode(zkgroup::serialize(&auth)),
        })
    );
}
