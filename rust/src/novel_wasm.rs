//! Native host for imported, signed WebAssembly book sources.

mod engine;
mod package;

use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Instant,
};

use once_cell::sync::Lazy;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use engine::{Runtime, REQUEST_BUDGET};
use package::{read_package, valid_id, Package};

type SourceRuntime = Option<(PathBuf, Runtime)>;
type SourceSlot = Arc<Mutex<SourceRuntime>>;
static SOURCES: Lazy<Mutex<HashMap<PathBuf, SourceSlot>>> = Lazy::new(Mutex::default);

fn source_slot(root: &Path, id: &str) -> Result<SourceSlot, String> {
    let mut sources = SOURCES.lock().map_err(|_| "书源运行环境不可用")?;
    Ok(Arc::clone(sources.entry(root.join(id)).or_default()))
}

fn runtime_for<'a>(
    instance: &'a mut SourceRuntime,
    path: &Path,
    load_package: impl FnOnce() -> Result<Package, String>,
) -> Result<&'a mut Runtime, String> {
    if !matches!(instance, Some((current, _)) if current == path) {
        let runtime = Runtime::new(path.with_extension("data"), &load_package()?)?;
        *instance = Some((path.to_path_buf(), runtime));
    }
    instance
        .as_mut()
        .map(|(_, runtime)| runtime)
        .ok_or_else(|| "书源运行环境不可用".into())
}

pub(crate) fn operate(
    root: &Path,
    action: &str,
    args: &str,
    archive: &[u8],
) -> Result<Vec<u8>, String> {
    fs::create_dir_all(root).map_err(|_| "无法打开书源存储")?;
    let canonical = fs::canonicalize(root).map_err(|_| "无法定位书源存储")?;
    let root = canonical.as_path();
    let args: Value = serde_json::from_str(args).map_err(|_| "插件操作参数无效")?;
    if action == "list" {
        let mut output = Vec::new();
        for file in fs::read_dir(root)
            .map_err(|_| "无法读取已导入的书源")?
            .flatten()
        {
            let file = file.path();
            if file.extension().and_then(|ext| ext.to_str()) != Some("publisher") {
                continue;
            }
            let Some(id) = file
                .file_stem()
                .and_then(|name| name.to_str())
                .filter(|id| valid_id(id))
            else {
                continue;
            };
            let slot = source_slot(root, id)?;
            let Ok(mut instance) = slot.lock() else {
                continue;
            };
            let Ok(Some(publisher)) = pinned_publisher(root, id) else {
                continue;
            };
            if let Some(path) = installed_path(root, id, &publisher) {
                if let Ok(plugin) = load_pinned(&path, id, &publisher, true) {
                    let mut summary = plugin.manifest.summary();
                    if package::is_legacy(id, &publisher) {
                        summary["legacyPublisher"] = json!(true);
                    } else {
                        let full = plugin.manifest.fanqie_full_experience;
                        if let Ok(runtime) = runtime_for(&mut instance, &path, || Ok(plugin)) {
                            if let Ok(meta) = runtime.check_meta(id, full) {
                                extend_metadata(&mut summary, meta);
                            }
                        }
                    }
                    output.push(summary);
                }
            }
        }
        output.sort_by_key(|row| row["sourceId"].as_str().unwrap_or_default().to_owned());
        return encode(&json!({"value": output}));
    }
    if action == "inspect" {
        let candidate = read_package(archive, false)?;
        let mut summary = candidate.manifest.summary();
        let id = &candidate.manifest.source_id;
        let slot = source_slot(root, id)?;
        let _instance = slot.lock().map_err(|_| "书源运行环境不可用")?;
        if let Some(old) = pinned_publisher(root, id)? {
            if old != candidate.manifest.publisher {
                if !package::is_legacy(id, &old) {
                    return Err("书源发布者签名不匹配".into());
                }
                summary["resetPublisher"] = json!(old);
            }
        }
        summary["fingerprint"] = json!(hex::encode(Sha256::digest(archive)));
        return encode(&json!({"value": summary}));
    }
    if action == "install" {
        if args["fingerprint"].as_str() != Some(hex::encode(Sha256::digest(archive)).as_str()) {
            return Err("书源 ZIP 已变化，请重新选择".into());
        }
        let candidate = read_package(archive, false)?;
        let id = &candidate.manifest.source_id;
        let publisher = &candidate.manifest.publisher;
        let slot = source_slot(root, id)?;
        let mut instance = slot.lock().map_err(|_| "书源运行环境不可用")?;
        let pinned = pinned_publisher(root, id)?;
        let resetting = pinned.as_ref().is_some_and(|old| old != publisher);
        if resetting {
            let old = pinned.as_deref().unwrap_or_default();
            if !package::is_legacy(id, old) || args["resetPublisher"].as_str() != Some(old) {
                return Err("请先确认重置原书源发布者".into());
            }
        }
        let previous = pinned
            .as_ref()
            .and_then(|old| installed_path(root, id, old));
        if let Some(path) = &previous {
            if !resetting
                && candidate.manifest.revision()?
                    <= load_pinned(path, id, publisher, false)?
                        .manifest
                        .revision()?
            {
                return Err("插件更新需要更高版本".into());
            }
        }
        let current = if resetting {
            package_path(root, id, publisher)
        } else {
            previous
                .clone()
                .unwrap_or_else(|| package_path(root, id, publisher))
        };
        let mut runtime = Runtime::new(current.with_extension("data"), &candidate)?;
        let meta = runtime.check_meta(id, candidate.manifest.fanqie_full_experience)?;

        write_atomic(&current, archive)?;
        if pinned.as_ref() != Some(publisher) {
            // The pin is the activation pointer. A staged package is invisible
            // until it commits, even if this process exits during installation.
            write_atomic(&pin_path(root, id), publisher.as_bytes())?;
        }
        if resetting {
            if let Some(old_path) = previous {
                let _ = fs::remove_file(old_path.with_extension("data"));
                let _ = fs::remove_file(old_path);
            }
        }
        *instance = Some((current, runtime));
        let mut summary = candidate.manifest.summary();
        extend_metadata(&mut summary, meta);
        return encode(&json!({"value": summary}));
    }
    let id = args["sourceId"]
        .as_str()
        .filter(|id| valid_id(id))
        .ok_or("书源标识无效")?;
    // Wasmi stores and plugin-private files are mutable. Serialize operations
    // for this source while letting other plugins run and update independently.
    if !pin_path(root, id).is_file() {
        return Err("书源尚未安装".into());
    }
    let slot = source_slot(root, id)?;
    let waiting = Instant::now();
    let mut instance = slot.lock().map_err(|_| "书源运行环境不可用")?;
    if action == "request" && id == "fanqie" && args["path"] == "/api/v1/recommend/homepage" {
        log::info!(
            "novel bookstore stage=lock elapsed_ms={}",
            waiting.elapsed().as_millis()
        );
    }
    let publisher = pinned_publisher(root, id)?.ok_or("书源尚未安装")?;
    let path = installed_path(root, id, &publisher).ok_or("书源尚未安装")?;
    if action == "uninstall" {
        let data = path.with_extension("data");
        fs::remove_file(&path).map_err(|_| "移除书源文件失败")?;
        *instance = None;
        if let Err(error) = fs::remove_file(data) {
            if error.kind() != std::io::ErrorKind::NotFound {
                return Err("书源已移除，清理私有数据失败".into());
            }
        }
        return encode(&json!({"value": true}));
    }
    if action != "request" {
        return Err("不支持的书源操作".into());
    }
    if package::is_legacy(id, &publisher) {
        return Err("请重新导入新版书源 ZIP".into());
    }
    let expected = args["version"].as_str().ok_or("书源版本缺失")?;
    if args["publisher"].as_str() != Some(publisher.as_str()) {
        return Err("书源签名已变化，请重新打开".into());
    }
    let route = args["path"]
        .as_str()
        .filter(|path| path.starts_with('/') && path.len() <= 512 && !path.contains(".."))
        .ok_or("书源请求路径无效")?;
    let query = args["query"]
        .as_str()
        .filter(|query| query.len() <= 4096)
        .ok_or("书源请求参数无效")?;
    if waiting.elapsed() >= REQUEST_BUDGET {
        return Err("书源请求排队超时".into());
    }
    let runtime = runtime_for(&mut instance, &path, || {
        load_pinned(&path, id, &publisher, false)
    })?;
    if runtime.version() != expected {
        return Err("书源已更新，请重试".into());
    }
    let method = args["method"].as_str().unwrap_or("GET");
    let account = id == "fanqie"
        && method == "POST"
        && query.is_empty()
        && matches!(route, "/v1/account/history" | "/v1/account/library");
    if method != "GET"
        && !account
        && (id != "fanqie"
            || method != "POST"
            || !route.starts_with("/api/v1/comments/")
            || !route.ends_with("/replies"))
    {
        return Err("书源不支持此请求方法".into());
    }
    if (account && (archive.is_empty() || archive.len() > 16 * 1024))
        || (!account && !archive.is_empty())
    {
        return Err("书源请求正文无效".into());
    }
    let frame = if account {
        let meta = runtime.check_meta(id, true)?;
        if meta["capabilities"]["accountImport"].as_u64() != Some(1) {
            return Err("请更新番茄 ZIP 后使用在线导入".into());
        }
        runtime.request_with_body(method, route, query, archive)
    } else {
        runtime.request(method, route, query)
    };
    if frame.is_err() {
        *instance = None;
    }
    let (status, body) = frame?;
    let mut output = (status as i32).to_be_bytes().to_vec();
    output.extend(body);
    Ok(output)
}

pub(crate) fn installed_request(
    root: &Path,
    id: &str,
    path: &str,
    query: &str,
    method: &str,
    body: &[u8],
) -> Result<(u16, Vec<u8>), String> {
    let publisher = pinned_publisher(root, id)?.ok_or("请先导入对应的书源 ZIP")?;
    let package_path = installed_path(root, id, &publisher).ok_or("请先导入对应的书源 ZIP")?;
    let package = load_pinned(&package_path, id, &publisher, false)?;
    let args = json!({
        "sourceId": id,
        "publisher": publisher,
        "version": package.manifest.version,
        "path": path,
        "query": query,
        "method": method,
    });
    let response = operate(root, "request", &args.to_string(), body)?;
    let code = response
        .get(..4)
        .and_then(|value| value.try_into().ok())
        .map(i32::from_be_bytes)
        .and_then(|value| u16::try_from(value).ok())
        .ok_or("书源未返回有效响应")?;
    Ok((code, response[4..].to_vec()))
}

fn extend_metadata(summary: &mut Value, meta: Value) {
    if let (Some(summary), Value::Object(meta)) = (summary.as_object_mut(), meta) {
        summary.extend(meta);
    }
}

fn load(path: &Path, allow_legacy: bool) -> Result<Package, String> {
    let size = fs::metadata(path).map_err(|_| "书源尚未安装")?.len();
    if size > package::MAX_ARCHIVE as u64 {
        return Err("书源 ZIP 过大".into());
    }
    read_package(
        &fs::read(path).map_err(|_| "无法读取书源 ZIP")?,
        allow_legacy,
    )
}

fn load_pinned(
    path: &Path,
    id: &str,
    publisher: &str,
    allow_legacy: bool,
) -> Result<Package, String> {
    let package = load(path, allow_legacy)?;
    if package.manifest.source_id != id || package.manifest.publisher != publisher {
        return Err("书源与安装记录不匹配".into());
    }
    Ok(package)
}

fn pin_path(root: &Path, id: &str) -> PathBuf {
    root.join(format!("{id}.publisher"))
}

fn pinned_publisher(root: &Path, id: &str) -> Result<Option<String>, String> {
    match fs::read_to_string(pin_path(root, id)) {
        Ok(publisher) if publisher.len() == 44 => Ok(Some(publisher)),
        Ok(_) => Err("书源发布者记录无效".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("无法读取书源发布者记录".into()),
    }
}

fn package_path(root: &Path, id: &str, publisher: &str) -> PathBuf {
    let key = hex::encode(Sha256::digest(publisher.as_bytes()));
    root.join(format!("{id}-{key}.zip"))
}

fn installed_path(root: &Path, id: &str, publisher: &str) -> Option<PathBuf> {
    let current = package_path(root, id, publisher);
    if current.is_file() {
        return Some(current);
    }
    let legacy = root.join(format!("{id}.zip"));
    load(&legacy, true)
        .ok()
        .filter(|plugin| plugin.manifest.source_id == id && plugin.manifest.publisher == publisher)
        .map(|_| legacy)
}

fn encode(value: &Value) -> Result<Vec<u8>, String> {
    serde_json::to_vec(value).map_err(|_| "无法编码书源信息".into())
}

fn write_atomic(target: &Path, data: &[u8]) -> Result<(), String> {
    use std::io::Write;

    let temporary = target.with_extension(format!(
        "{}.tmp",
        target
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or_default(),
    ));
    let write = || -> std::io::Result<()> {
        let mut file = fs::File::create(&temporary)?;
        file.write_all(data)?;
        file.sync_all()?;
        fs::rename(&temporary, target)
    };
    write().map_err(|_| {
        let _ = fs::remove_file(&temporary);
        "保存书源文件失败".into()
    })
}
