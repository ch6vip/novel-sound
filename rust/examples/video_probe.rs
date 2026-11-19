//! Host probe: start the real core against the real upstream and dump the
//! short-drama stream resolution exactly as the app sees it.
//!
//! Usage: cargo run --release --example video_probe -- <runtime_dir> [video_id]

struct PrintLogger;
impl log::Log for PrintLogger {
    fn enabled(&self, _: &log::Metadata) -> bool {
        true
    }
    fn log(&self, record: &log::Record) {
        println!("LOG {} {}: {}", record.level(), record.target(), record.args());
    }
    fn flush(&self) {}
}
static LOGGER: PrintLogger = PrintLogger;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let runtime = args.next().expect("runtime dir");
    let video_id = args.next();

    log::set_logger(&LOGGER)?;
    log::set_max_level(log::LevelFilter::Debug);

    let init = fqapi_core::api::init(
        format!("{runtime}/config/config.json"),
        format!("{runtime}/config/device_pool.json"),
        format!("{runtime}/config/filter.json"),
        runtime.clone(),
        0,
        false,
        String::new(),
    )
    .await?;
    println!("init: {init}");

    let base = fqapi_core::api::base_url().await;
    let cap = fqapi_core::api::session_capability().await;
    println!("base: {base} cap: {}...", &cap[..8.min(cap.len())]);

    let http = reqwest::Client::new();
    let url = |path: &str| format!("{base}/_session/{cap}{path}");

    if let Some(spec) = video_id.clone() {
        if let Some(path) = spec.strip_prefix("path:") {
            let body = fetch_text(&http, &url(path)).await;
            println!("[{path}] {}", &body[..body.len().min(400000)]);
            return Ok(());
        }
    }

    if let Some(id) = video_id {
        fetch(&http, &url(&format!("/api/v1/videos/{id}?mode=stream")), "stream").await;
        fetch(&http, &url(&format!("/api/v1/videos/{id}")), "model").await;
        return Ok(());
    }

    // No id given: find one from the 短剧 search.
    let search = url("/api/v1/search?query=%E9%9C%B8%E6%80%BB&offset=0&count=10");
    let body = fetch_text(&http, &search).await;
    println!("search: {}", &body[..body.len().min(1200)]);
    Ok(())
}

async fn fetch(http: &reqwest::Client, url: &str, label: &str) {
    let started = std::time::Instant::now();
    match http.get(url).send().await {
        Ok(res) => {
            let status = res.status();
            let body = res.text().await.unwrap_or_default();
            println!(
                "[{label}] {status} {}ms {}",
                started.elapsed().as_millis(),
                &body[..body.len().min(800)]
            );
        }
        Err(e) => println!("[{label}] transport error after {:?}: {e}", started.elapsed()),
    }
}

async fn fetch_text(http: &reqwest::Client, url: &str) -> String {
    match http.get(url).send().await {
        Ok(res) => {
            let status = res.status();
            let body = res.text().await.unwrap_or_default();
            format!("{status} {body}")
        }
        Err(e) => format!("transport error: {e}"),
    }
}
