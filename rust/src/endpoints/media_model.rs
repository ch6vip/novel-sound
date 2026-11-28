//! Shared helpers used by video and audiobook playback.

use base64::Engine;
use serde_json::{Map, Value};

pub(crate) fn decode_video_model_str(s: &str) -> Option<Map<String, Value>> {
    if s.is_empty() {
        return None;
    }
    match serde_json::from_str::<Value>(s) {
        Ok(Value::Object(m)) => Some(m),
        _ => None,
    }
}

pub(crate) fn audio_b64_decode(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    let trimmed = s.trim();
    let pad = (4 - trimmed.len() % 4) % 4;
    let mut padded = trimmed.to_string();
    for _ in 0..pad {
        padded.push('=');
    }
    let cleaned: String = padded
        .chars()
        .filter(|c| *c != '\r' && *c != '\n')
        .collect();
    base64::engine::general_purpose::STANDARD.decode(cleaned)
}

pub(crate) fn derive_spade_content_key(value: &str) -> Vec<u8> {
    if value.is_empty() {
        return Vec::new();
    }
    let Ok(raw) = audio_b64_decode(value) else {
        return Vec::new();
    };
    if raw.len() < 3 {
        return Vec::new();
    }
    let out_len = raw.len() as i64 - (raw[0] ^ raw[1] ^ raw[2]) as i64 + 0x2F;
    if out_len < 33 || out_len + 1 > raw.len() as i64 {
        return Vec::new();
    }
    let out_len = out_len as usize;
    let mut buf = raw[1..1 + out_len].to_vec();
    let src = buf.clone();
    let mut prev_a: u8 = 0x55;
    let mut prev_b: u8 = 0xF6;
    for (i, &cur) in src.iter().enumerate() {
        let keep;
        if i & 1 == 1 {
            keep = cur;
        } else {
            keep = prev_a;
            prev_a = prev_b;
            prev_b = cur;
        }
        buf[i] = (((prev_a ^ cur) as i32 - bit_count(i as u32) - 0x15) & 0xFF) as u8;
        prev_a = keep;
    }
    let key_hex = String::from_utf8_lossy(&buf[1..33]);
    match hex::decode(key_hex.as_bytes()) {
        Ok(key) if key.len() == 16 => key,
        _ => Vec::new(),
    }
}

fn bit_count(n: u32) -> i32 {
    n.count_ones() as i32
}
