use std::io::{Cursor, Read};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub const MAX_ARCHIVE: usize = 16 * 1024 * 1024;
const MAX_MODULE: usize = 12 * 1024 * 1024;
const MAX_MANIFEST: usize = 16 * 1024;

const DISTRIBUTION_PUBLISHER: &str = "ve2GSa0PYOh4nzUwG41jN3FQ58m0M8FQhRdgjlkrLRM=";
const PREVIOUS_DISTRIBUTION_PUBLISHER: &str = "aPz7tpmuIW+7bHFhqMxGGdDbiHpoh/rjwCs7nVkiT5o=";

fn official_publisher() -> &'static str {
    option_env!("FQ_NOVEL_WASM_PUBLISHER").unwrap_or(DISTRIBUTION_PUBLISHER)
}

fn previous_publisher() -> &'static str {
    option_env!("FQ_NOVEL_WASM_LEGACY_PUBLISHER").unwrap_or(PREVIOUS_DISTRIBUTION_PUBLISHER)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Manifest {
    manifest_version: u32,
    api_version: u32,
    pub source_id: String,
    name: String,
    pub version: String,
    protocol: String,
    #[serde(default)]
    bookstore_feed: bool,
    #[serde(default)]
    pub fanqie_full_experience: bool,
    pub https_hosts: Vec<String>,
    pub publisher: String,
    module_sha256: String,
}

impl Manifest {
    pub fn summary(&self) -> Value {
        json!({
            "sourceId": self.source_id, "name": self.name, "version": self.version,
            "protocol": self.protocol, "bookstoreFeed": self.bookstore_feed,
            "fanqieFullExperience": self.fanqie_full_experience,
            "httpsHosts": self.https_hosts, "publisher": self.publisher,
        })
    }

    pub fn revision(&self) -> Result<[u32; 3], String> {
        let chunks: Vec<_> = self.version.split('.').collect();
        if chunks.len() != 3
            || chunks.iter().any(|part| {
                part.is_empty()
                    || part.len() > 9
                    || !part.bytes().all(|byte| byte.is_ascii_digit())
                    || (part.len() > 1 && part.starts_with('0'))
            })
        {
            return Err("插件版本须为三个数字段".into());
        }
        Ok([
            chunks[0].parse().unwrap(),
            chunks[1].parse().unwrap(),
            chunks[2].parse().unwrap(),
        ])
    }
}

pub(super) struct Package {
    pub manifest: Manifest,
    pub wasm: Vec<u8>,
}

pub(super) fn read_package(data: &[u8], allow_legacy: bool) -> Result<Package, String> {
    if data.len() > MAX_ARCHIVE {
        return Err("书源 ZIP 过大".into());
    }
    let mut archive = zip::ZipArchive::new(Cursor::new(data)).map_err(|_| "无效的书源 ZIP")?;
    if archive.len() != 3 {
        return Err("书源 ZIP 必须包含清单、签名和一个 WebAssembly 模块".into());
    }
    let mut manifest = None;
    let mut signature = None;
    let mut module = None;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(|_| "无法读取书源 ZIP")?;
        if !entry.is_file() || entry.is_symlink() {
            return Err("书源 ZIP 含无效条目".into());
        }
        let (slot, limit) = match entry.name() {
            "manifest.json" => (&mut manifest, MAX_MANIFEST),
            "manifest.sig" => (&mut signature, 64),
            "source.wasm" => (&mut module, MAX_MODULE),
            _ => return Err("书源 ZIP 含未知条目".into()),
        };
        if slot.is_some() || entry.size() > limit as u64 {
            return Err("书源 ZIP 含重复或超限条目".into());
        }
        let mut bytes = Vec::new();
        entry
            .by_ref()
            .take(limit as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "书源 ZIP 内容已损坏")?;
        if bytes.len() > limit {
            return Err("书源 ZIP 含超限条目".into());
        }
        *slot = Some(bytes);
    }
    let (manifest, signature, wasm) = (
        manifest.ok_or("缺少插件清单")?,
        signature.ok_or("缺少插件签名")?,
        module.ok_or("缺少插件模块")?,
    );
    let fields: Manifest = serde_json::from_slice(&manifest).map_err(|_| "书源清单无效")?;
    if fields.manifest_version != 1
        || fields.api_version != 1
        || !valid_id(&fields.source_id)
        || fields.name.trim().is_empty()
        || fields.name.chars().count() > 80
        || fields.https_hosts.len() > 32
        || fields.https_hosts.iter().any(|host| !valid_host(host))
    {
        return Err("书源清单的版本、来源或网络权限无效".into());
    }
    fields.revision()?;
    let official = matches!(fields.source_id.as_str(), "fanqie" | "shuqi");
    if (official
        && (fields.protocol != "native-v1"
            || (official_publisher() != fields.publisher
                && !(allow_legacy && is_legacy(&fields.source_id, &fields.publisher)))))
        || (!official && fields.protocol != "json-v1")
        || (fields.fanqie_full_experience
            && (fields.source_id != "fanqie"
                || fields.protocol != "native-v1"
                || !fields.bookstore_feed))
        || (fields.bookstore_feed && fields.source_id == "shuqi")
    {
        return Err("插件发布者或接口类型不受支持".into());
    }
    let key = STANDARD
        .decode(&fields.publisher)
        .map_err(|_| "书源签名公钥无效")?;
    if STANDARD.encode(&key) != fields.publisher
        || key.len() != 32
        || ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
            .verify(&manifest, &signature)
            .is_err()
        || hex::encode(Sha256::digest(&wasm)) != fields.module_sha256
    {
        return Err("书源 ZIP 签名或模块校验失败".into());
    }
    Ok(Package {
        manifest: fields,
        wasm,
    })
}

pub(super) fn is_legacy(id: &str, publisher: &str) -> bool {
    matches!(id, "fanqie" | "shuqi")
        && previous_publisher() == publisher
        && official_publisher() != publisher
}

pub(super) fn valid_id(value: &str) -> bool {
    value.len() <= 32
        && value.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
        })
}

fn valid_host(value: &str) -> bool {
    value.len() <= 253
        && value.contains('.')
        && value.parse::<std::net::IpAddr>().is_err()
        && value.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        })
        && !value.ends_with(".local")
        && !value.ends_with(".localhost")
}
