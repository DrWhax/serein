//! Bytes as base64 strings in the JSON (what Swift's `Data` Codable uses by default).

use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Deserializer};

pub fn encode(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
    let s = String::deserialize(d)?;
    STANDARD.decode(s.as_bytes()).map_err(serde::de::Error::custom)
}

pub mod opt {
    use super::*;
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
        let s = Option::<String>::deserialize(d)?;
        s.map(|s| STANDARD.decode(s.as_bytes()).map_err(serde::de::Error::custom)).transpose()
    }
}

pub mod list {
    use super::*;
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<Vec<u8>>, D::Error> {
        let v = Vec::<String>::deserialize(d)?;
        v.into_iter().map(|s| STANDARD.decode(s.as_bytes()).map_err(serde::de::Error::custom)).collect()
    }
}

/// 64-bit ids as decimal strings (JSON numbers lose precision past 2^53 in many decoders).
pub mod id {
    use super::*;
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
        let s = String::deserialize(d)?;
        s.parse::<u64>().map_err(serde::de::Error::custom)
    }
}
