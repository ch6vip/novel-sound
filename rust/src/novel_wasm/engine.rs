//! Metered interpreter and the only capabilities available to a source module.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    net::{IpAddr, SocketAddr},
    path::PathBuf,
    time::{Duration, Instant},
};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use once_cell::sync::Lazy;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use wasmi::{
    Caller, Config, Engine, Linker, Memory, Module, Store, StoreLimits, StoreLimitsBuilder,
    TrapCode, TypedFunc,
};

use super::{encode, package::Package, write_atomic};

pub(super) const REQUEST_BUDGET: Duration = Duration::from_secs(18);
const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_STORAGE: usize = 512 * 1024;
const REQUEST_FUEL: u64 = 450_000_000;
const WASI: &str = "wasi_snapshot_preview1";
static ENGINE: Lazy<Engine> = Lazy::new(|| {
    let mut config = Config::default();
    config.consume_fuel(true);
    Engine::new(&config)
});
static IO: Lazy<Result<tokio::runtime::Runtime, std::io::Error>> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
});

struct Context {
    wasi: wasmi_wasi::WasiCtx,
    limits: StoreLimits,
    deadline: Instant,
    hosts: BTreeSet<String>,
    calls: usize,
    reply: Vec<u8>,
    storage: PathBuf,
    source_id: String,
    probing: bool,
    account_request: bool,
    trace_bookstore: bool,
}

pub(super) struct Runtime {
    store: Store<Context>,
    version: String,
    metadata: Option<Value>,
    memory: Memory,
    alloc: TypedFunc<i32, i32>,
    free: TypedFunc<(i32, i32), ()>,
    request: TypedFunc<(i32, i32), i64>,
}

impl Runtime {
    pub fn new(storage: PathBuf, plugin: &Package) -> Result<Self, String> {
        fn invalid<T>(_: T) -> String {
            "书源 WebAssembly 模块或接口无效".to_owned()
        }
        let module = Module::new(&ENGINE, &plugin.wasm).map_err(invalid)?;
        let context = Context {
            wasi: wasmi_wasi::WasiCtxBuilder::new().build(),
            limits: StoreLimitsBuilder::new()
                .memory_size(64 * 1024 * 1024)
                .table_elements(16_384)
                .instances(1)
                .memories(1)
                .tables(1)
                .build(),
            deadline: Instant::now() + REQUEST_BUDGET,
            hosts: plugin.manifest.https_hosts.iter().cloned().collect(),
            calls: 0,
            reply: Vec::new(),
            storage,
            source_id: plugin.manifest.source_id.clone(),
            probing: true,
            account_request: false,
            trace_bookstore: false,
        };
        let mut store = Store::new(&ENGINE, context);
        store.limiter(|context| &mut context.limits);
        store.set_fuel(REQUEST_FUEL).map_err(invalid)?;
        let mut linker = Linker::new(&ENGINE);
        wasmi_wasi::add_to_linker(&mut linker, |context: &mut Context| &mut context.wasi)
            .map_err(|_| "无法初始化书源运行环境")?;
        linker.allow_shadowing(true);
        linker
            .func_wrap(WASI, "poll_oneoff", poll_oneoff)
            .map_err(invalid)?;
        linker
            .func_wrap("fq_novel_v1", "invoke", invoke)
            .map_err(invalid)?;
        linker
            .func_wrap("fq_novel_v1", "receive", receive)
            .map_err(invalid)?;
        let instance = linker
            .instantiate_and_start(&mut store, &module)
            .map_err(invalid)?;
        let memory = instance
            .get_memory(&store, "memory")
            .ok_or("书源模块缺少内存")?;
        let alloc = instance
            .get_typed_func(&store, "novel_alloc")
            .map_err(invalid)?;
        let free = instance
            .get_typed_func(&store, "novel_free")
            .map_err(invalid)?;
        let request = instance
            .get_typed_func(&store, "novel_request")
            .map_err(invalid)?;
        store.data_mut().probing = false;
        Ok(Self {
            store,
            version: plugin.manifest.version.clone(),
            metadata: None,
            memory,
            alloc,
            free,
            request,
        })
    }

    pub fn version(&self) -> &str {
        &self.version
    }

    pub fn check_meta(&mut self, id: &str, full: bool) -> Result<Value, String> {
        if let Some(meta) = &self.metadata {
            return Ok(meta.clone());
        }
        self.store.data_mut().probing = true;
        let result = self.request("GET", "/v1/meta", "");
        self.store.data_mut().probing = false;
        let (status, body) = result?;
        let meta: Value = serde_json::from_slice(&body).map_err(|_| "书源元数据无效")?;
        if status != 200
            || meta["sourceId"] != id
            || meta["apiVersion"] != 1
            || (full && meta["fanqieFullExperience"] != true)
        {
            return Err("模块与书源清单不匹配".into());
        }
        let mut summary = serde_json::Map::new();
        if let Some(capabilities) = meta["capabilities"].as_object() {
            let supported = capabilities
                .iter()
                .filter(|(name, value)| name.len() <= 48 && value.as_u64() == Some(1))
                .take(32)
                .map(|(name, version)| (name.clone(), version.clone()))
                .collect();
            summary.insert("capabilities".into(), Value::Object(supported));
        }
        if let Some(channels) = meta["channels"].as_array() {
            let channels = channels
                .iter()
                .take(32)
                .filter_map(|channel| {
                    let id = channel["id"].as_str()?;
                    let title = channel["title"].as_str()?;
                    let kind = channel["kind"].as_str().unwrap_or("book");
                    if id.is_empty() || id.len() > 128 || title.len() > 128 || kind.len() > 24 {
                        return None;
                    }
                    Some(json!({"id": id, "title": title, "kind": kind}))
                })
                .collect();
            summary.insert("channels".into(), Value::Array(channels));
        }
        if let Some(filters) = meta["searchFilters"].as_array() {
            if filters.len() <= 8
                && serde_json::to_vec(filters).is_ok_and(|bytes| bytes.len() <= 16 * 1024)
            {
                summary.insert("searchFilters".into(), Value::Array(filters.clone()));
            }
        }
        let summary = Value::Object(summary);
        self.metadata = Some(summary.clone());
        Ok(summary)
    }

    pub fn request(
        &mut self,
        method: &str,
        path: &str,
        query: &str,
    ) -> Result<(u16, Vec<u8>), String> {
        self.request_with_body(method, path, query, &[])
    }

    pub fn request_with_body(
        &mut self,
        method: &str,
        path: &str,
        query: &str,
        body: &[u8],
    ) -> Result<(u16, Vec<u8>), String> {
        self.store.data_mut().account_request = !body.is_empty();
        let trace = self.store.data().source_id == "fanqie" && path == "/api/v1/recommend/homepage";
        self.store.data_mut().trace_bookstore = trace;
        let started = Instant::now();
        let response = self.request_frame(method, path, query, body);
        if trace {
            let status = response.as_ref().map(|(status, _)| *status).unwrap_or(0);
            log::info!(
                "novel bookstore stage=guest status={status} calls={} elapsed_ms={}",
                self.store.data().calls,
                started.elapsed().as_millis()
            );
        }
        self.store.data_mut().account_request = false;
        self.store.data_mut().trace_bookstore = false;
        response
    }

    fn request_frame(
        &mut self,
        method: &str,
        path: &str,
        query: &str,
        body: &[u8],
    ) -> Result<(u16, Vec<u8>), String> {
        let failed = |error: wasmi::Error| match error.as_trap_code() {
            Some(TrapCode::OutOfFuel) => "插件执行超出 WebAssembly 指令预算".to_owned(),
            Some(trap) => format!("插件 WebAssembly 执行异常（{trap:?}）"),
            None => "插件 WebAssembly 执行失败".to_owned(),
        };
        let data = self.store.data_mut();
        data.reply.clear();
        data.calls = 0;
        data.deadline = Instant::now() + REQUEST_BUDGET;
        self.store.set_fuel(REQUEST_FUEL).map_err(failed)?;
        let input = if !body.is_empty() {
            let body: Value = serde_json::from_slice(body).map_err(|_| "书源请求正文无效")?;
            encode(&json!({"method": method, "path": path, "query": query, "body": body}))?
        } else if method == "GET" {
            encode(&json!({"path": path, "query": query}))?
        } else {
            encode(&json!({"method": method, "path": path, "query": query}))?
        };
        let length = input.len() as i32;
        let address = self.alloc.call(&mut self.store, length).map_err(failed)?;
        self.memory
            .write(&mut self.store, address as u32 as usize, &input)
            .map_err(|_| "插件返回了无效的请求缓冲区")?;
        let result = self
            .request
            .call(&mut self.store, (address, length))
            .map_err(failed)? as u64;
        self.free
            .call(&mut self.store, (address, length))
            .map_err(failed)?;
        let (output, length) = ((result >> 32) as i32, result as u32 as usize);
        if !(4..=MAX_BODY + 4).contains(&length) || self.store.data().deadline <= Instant::now() {
            return Err("插件响应超时或大小无效".into());
        }
        let mut bytes = vec![0; length];
        self.memory
            .read(&self.store, output as u32 as usize, &mut bytes)
            .map_err(|_| "插件返回了无效的响应缓冲区")?;
        self.free
            .call(&mut self.store, (output, length as i32))
            .map_err(failed)?;
        let status = i32::from_be_bytes(bytes[..4].try_into().unwrap());
        if !(100..=599).contains(&status) {
            return Err("插件响应状态无效".into());
        }
        Ok((status as u16, bytes.split_off(4)))
    }
}

fn memory(caller: &Caller<'_, Context>) -> Option<Memory> {
    caller.get_export("memory")?.into_memory()
}

fn invoke(mut caller: Caller<'_, Context>, operation: i32, pointer: i32, size: i32) -> i32 {
    if caller.data().probing
        || !(0..=MAX_STORAGE as i32).contains(&size)
        || caller.data().deadline <= Instant::now()
    {
        return -1;
    }
    let Some(memory) = memory(&caller) else {
        return -1;
    };
    let mut input = vec![0; size as usize];
    if memory
        .read(&caller, pointer as u32 as usize, &mut input)
        .is_err()
    {
        return -1;
    }
    let state = caller.data_mut();
    state.reply.clear();
    state.calls += 1;
    if state.calls > 64 {
        return -1;
    }
    let result = match operation {
        0 => {
            let Ok(runtime) = IO.as_ref() else { return -1 };
            runtime.block_on(https(state, &input))
        }
        1..=3 => storage(state, operation, &input),
        _ => Err(-1),
    };
    match result {
        Ok(bytes) => {
            let len = bytes.len() as i32;
            state.reply = bytes;
            len
        }
        Err(code) => code,
    }
}

fn receive(mut caller: Caller<'_, Context>, pointer: i32, size: i32) -> i32 {
    let Some(memory) = memory(&caller) else {
        return -1;
    };
    let reply = std::mem::take(&mut caller.data_mut().reply);
    if size < 0
        || reply.len() != size as usize
        || memory
            .write(&mut caller, pointer as u32 as usize, &reply)
            .is_err()
    {
        return -1;
    }
    size
}

// Tokio's guest timer parks using a relative WASI clock subscription. Limit
// that wait to the request deadline and reject other polling capabilities.
fn poll_oneoff(
    mut caller: Caller<'_, Context>,
    input: i32,
    output: i32,
    count: i32,
    events: i32,
) -> i32 {
    const INVALID: i32 = 28;
    let Some(memory) = memory(&caller) else {
        return INVALID;
    };
    let mut subscription = [0; 48];
    if count != 1
        || memory
            .read(&caller, input as u32 as usize, &mut subscription)
            .is_err()
        || subscription[8] != 0
        || subscription[40..42] != [0, 0]
    {
        return INVALID;
    }
    let wait = Duration::from_nanos(u64::from_le_bytes(subscription[24..32].try_into().unwrap()));
    if wait
        > caller
            .data()
            .deadline
            .saturating_duration_since(Instant::now())
    {
        return INVALID;
    }
    std::thread::sleep(wait);
    let mut event = [0; 32];
    event[..8].copy_from_slice(&subscription[..8]);
    if memory
        .write(&mut caller, output as u32 as usize, &event)
        .is_err()
        || memory
            .write(&mut caller, events as u32 as usize, &1u32.to_le_bytes())
            .is_err()
    {
        return INVALID;
    }
    0
}

fn storage(state: &Context, operation: i32, input: &[u8]) -> Result<Vec<u8>, i32> {
    let (name, value) = if operation == 2 {
        let split = input.iter().position(|byte| *byte == 0).ok_or(-1)?;
        (&input[..split], Some(&input[split + 1..]))
    } else {
        (input, None)
    };
    let name = std::str::from_utf8(name).map_err(|_| -1)?;
    if !(1..=48).contains(&name.len())
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(-1);
    }
    let main_key = crate::device::pool_crypto::pool_key().ok_or(-1)?;
    let key: [u8; 32] = Sha256::new()
        .chain_update(b"fq-novel-wasm-storage-v1")
        .chain_update(state.source_id.as_bytes())
        .chain_update(main_key)
        .finalize()
        .into();
    let mut entries: BTreeMap<String, Vec<u8>> = match fs::read(&state.storage) {
        Ok(bytes) if bytes.len() <= MAX_STORAGE + 128 => {
            let plain = crate::device::pool_crypto::decrypt_pool_file_with_key(&bytes, &key)
                .map_err(|_| -1)?;
            serde_json::from_slice(&plain).map_err(|_| -1)?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
        _ => return Err(-1),
    };
    if operation == 1 {
        return entries.remove(name).ok_or(-1);
    }
    if let Some(value) = value {
        entries.insert(name.to_owned(), value.to_vec());
    } else {
        entries.remove(name);
    }
    let encoded = serde_json::to_vec(&entries).map_err(|_| -1)?;
    if encoded.len() > MAX_STORAGE || entries.len() > 32 {
        return Err(-2);
    }
    let encrypted =
        crate::device::pool_crypto::encrypt_pool_file_with_key(&encoded, &key).map_err(|_| -1)?;
    write_atomic(&state.storage, &encrypted).map_err(|_| -1)?;
    Ok(Vec::new())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HttpRequest {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Option<String>,
    timeout_ms: u64,
    limit: usize,
}

async fn https(state: &Context, bytes: &[u8]) -> Result<Vec<u8>, i32> {
    let request: HttpRequest = serde_json::from_slice(bytes).map_err(|_| -1)?;
    let url = reqwest::Url::parse(&request.url).map_err(|_| -1)?;
    let host = url
        .domain()
        .filter(|host| state.hosts.contains(*host))
        .ok_or(-1)?;
    if url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || !matches!(request.method.as_str(), "GET" | "POST")
        || request.headers.len() > 64
        || request.url.len() > 8192
    {
        return Err(-1);
    }
    let budget = state
        .deadline
        .saturating_duration_since(Instant::now())
        .min(Duration::from_millis(request.timeout_ms.min(12_000)));
    let started = Instant::now();
    let mut stage = "dns";
    let task = match url.path() {
        "/service/2/device_register/" => "device_register",
        "/reading/bookapi/bookmall/tab/v" => "bookstore",
        _ => "other",
    };
    let result = tokio::time::timeout(budget, async {
        let addresses: Vec<_> = tokio::net::lookup_host((host, 443))
            .await
            .map_err(|_| -1)?
            .collect();
        if addresses.is_empty() || addresses.iter().any(|address| !is_public(*address)) {
            return Err(-1);
        }
        stage = "http_setup";
        let tls = crate::upstream::http::build_tls_config().map_err(|_| -1)?;
        let transport = reqwest::Client::builder()
            .tls_backend_preconfigured(tls)
            .https_only(true)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .resolve_to_addrs(host, &addresses)
            .build()
            .map_err(|_| -1)?;
        let method = reqwest::Method::from_bytes(request.method.as_bytes()).map_err(|_| -1)?;
        let mut outgoing = transport.request(method, url.clone());
        for (name, value) in request.headers {
            let name = name.to_ascii_lowercase();
            let limit = if state.account_request
                && state.source_id == "fanqie"
                && host == "api5-normal-sinfonlineb.fqnovel.com"
                && name == "cookie"
            {
                12 * 1024
            } else {
                8192
            };
            if matches!(
                name.as_str(),
                "host" | "content-length" | "connection" | "transfer-encoding"
            ) || name.starts_with("proxy-")
                || value.len() > limit
            {
                return Err(-1);
            }
            outgoing = outgoing.header(name, value);
        }
        if let Some(body) = request.body {
            let bytes = STANDARD.decode(body).map_err(|_| -1)?;
            if bytes.len() > 128 * 1024 {
                return Err(-2);
            }
            outgoing = outgoing.body(bytes);
        }
        stage = "connect_or_headers";
        let mut response = outgoing.send().await.map_err(|_| -1)?;
        let status = response.status().as_u16();
        stage = "response_body";
        let headers: Vec<_> = response
            .headers()
            .iter()
            .filter_map(|(name, value)| Some((name.as_str(), value.to_str().ok()?)))
            .collect();
        let headers = serde_json::to_value(headers).map_err(|_| -1)?;
        let limit = request.limit.min(MAX_BODY);
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| -1)? {
            if chunk.len() > limit.saturating_sub(body.len()) {
                return Err(-2);
            }
            body.extend_from_slice(&chunk);
        }
        encode(&json!({"status": status, "headers": headers, "body": STANDARD.encode(body)}))
            .map_err(|_| -1)
    })
    .await;
    if state.trace_bookstore {
        let outcome = match &result {
            Ok(Ok(_)) => "ok",
            Ok(Err(_)) => "error",
            Err(_) => "deadline",
        };
        log::info!(
            "novel bookstore task={task} stage={stage} outcome={outcome} elapsed_ms={}",
            started.elapsed().as_millis()
        );
    }
    result.map_err(|_| -1)?
}

fn is_public(address: SocketAddr) -> bool {
    match address.ip() {
        IpAddr::V4(ip) => public_v4(ip),
        IpAddr::V6(ip) => ip.to_ipv4_mapped().map_or_else(
            || {
                let [a, b, ..] = ip.segments();
                (a & 0xe000) == 0x2000
                    && (a, b) != (0x2001, 0x0db8)
                    && !(a == 0x2001 && b <= 0x01ff)
                    && a != 0x2002
                    && (a & 0xfff0) != 0x3ff0
            },
            public_v4,
        ),
    }
}

fn public_v4(ip: std::net::Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !matches!(
        (a, b, c),
        (0 | 10 | 127 | 224..=255, _, _)
            | (100, 64..=127, _)
            | (169, 254, _)
            | (172, 16..=31, _)
            | (192, 0, 0 | 2)
            | (192, 88, 99)
            | (192, 168, _)
            | (198, 18 | 19, _)
            | (198, 51, 100)
            | (203, 0, 113)
    )
}
