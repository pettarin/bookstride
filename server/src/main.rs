#[macro_use]
extern crate rocket;

use std::{
    collections::HashMap,
    fs::File,
    io::{self, Cursor},
    num::NonZeroU32,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime},
};

use governor::{
    Jitter, Quota, RateLimiter,
    clock::DefaultClock,
    state::{InMemoryState, NotKeyed},
};
use reqwest::StatusCode;
use rocket::{
    Build, Config, Request, Rocket, State,
    fairing::{self, AdHoc},
    form::Form,
    fs::NamedFile,
    http::{RawStr, Status},
    request::{FromRequest, Outcome},
    response::{
        Redirect,
        status::{Accepted, Unauthorized},
    },
    serde::{Deserialize, Serialize, json::Json},
    tokio::time::sleep,
};
use rocket_db_pools::{Database, sqlx};

/// A keyless, in-memory (process-global) rate limiter, shared across every
/// request handler and the background download worker.
type DirectLimiter = RateLimiter<NotKeyed, InMemoryState, DefaultClock>;

/// Maximum attempts (initial try + retries) for a single upstream request.
const MAX_ATTEMPTS: u32 = 5;

/// Never wait longer than this for a server-supplied `Retry-After`, so a
/// hostile or buggy value can't wedge a request indefinitely.
const RETRY_AFTER_CAP: Duration = Duration::from_secs(120);

/// Default cap for the on-disk media cache (`MAX_MEDIA_SIZE` env var
/// overrides it). When the cache grows past this, the download worker
/// deletes the oldest media files before fetching new ones.
const DEFAULT_MAX_MEDIA_SIZE: u64 = 3 * 1024 * 1024 * 1024;

/// Directory (under the user's home) where downloaded `.mp3` parts are
/// cached. Created on startup if missing.
const MEDIA_CACHE_DIRNAME: &str = "bookstride-cache";

/// libro.fm API version used by the position endpoints
const LIBRO_API_VERSION: &str = "v12";

/// TTL for the per-token library-position cache backing
/// `GET /v0/position/<isbn>`; repeated app-open checks inside the window
/// reuse one library dump instead of re-paginating libro.fm.
const POSITION_CACHE_TTL: Duration = Duration::from_secs(10);

/// Shared HTTP client + rate limiter for talking to libro.fm. Cloning is cheap
/// (an `Arc` plus reqwest's internal `Arc`), so it lives in Rocket managed
/// state and a clone is also handed to the background download task.
#[derive(Clone)]
struct Upstream {
    http: reqwest::Client,
    limiter: Arc<DirectLimiter>,
}

/// GoatCounter server-side analytics (optional). Reads `GOATCOUNTER_API_KEY`
/// from the environment. When absent, no server-side hits are sent.
///
/// Each hit is fire-and-forget: we log a warning on failure and move on.
/// The GoatCounter backend API is rate-limited to 4 requests/second, which
/// is far more than this app will ever generate.
#[derive(Clone)]
struct GoatCounter {
    api_key: String,
    endpoint: String,
    http: reqwest::Client,
}

impl GoatCounter {
    /// Create a GoatCounter client if the env var is set; return `None`
    /// otherwise so the server works fine without any analytics config.
    fn from_env() -> Option<Self> {
        let api_key = std::env::var("GOATCOUNTER_API_KEY").ok()?;
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .build()
            .expect("failed to build GoatCounter HTTP client");
        info!("GoatCounter server-side analytics enabled");
        Some(Self {
            endpoint: "https://bookstride.goatcounter.com/api/v0/count".into(),
            api_key,
            http,
        })
    }

    /// Send a single event hit to GoatCounter. The `path` is used as-is
    /// (should be a generic label like `"server/login-success"`). Errors
    /// are logged as warnings but never propagated, so a transient network
    /// glitch can't break the request handler.
    async fn hit(&self, path: &str) {
        #[derive(Serialize)]
        #[serde(crate = "rocket::serde")]
        struct Hit<'a> {
            path: &'a str,
            #[serde(rename = "event")]
            is_event: bool,
        }
        #[derive(Serialize)]
        #[serde(crate = "rocket::serde")]
        struct Payload<'a> {
            #[serde(rename = "no_sessions")]
            no_sessions: bool,
            hits: &'a [Hit<'a>],
        }

        let payload = Payload {
            no_sessions: true,
            hits: &[Hit {
                path,
                is_event: true,
            }],
        };

        match self
            .http
            .post(&self.endpoint)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&payload)
            .send()
            .await
        {
            Ok(resp) => {
                if !resp.status().is_success() {
                    warn!("GoatCounter hit {} returned {}", path, resp.status());
                }
            }
            Err(e) => warn!("GoatCounter hit {} failed: {}", path, e),
        }
    }
}

/// Status codes worth retrying: request timeout, rate limit, and the transient
/// server errors. (501 Not Implemented is deliberately excluded.)
fn is_transient(status: StatusCode) -> bool {
    matches!(status.as_u16(), 408 | 429 | 500 | 502 | 503 | 504)
}

/// Exponential backoff (500ms, doubling, capped at 30s) with full jitter.
fn backoff_delay(attempt: u32) -> Duration {
    let capped = 500u64.saturating_mul(1u64 << (attempt - 1)).min(30_000);
    let half = capped / 2;
    let jitter = rand::random::<u64>() % (half + 1);
    Duration::from_millis(half + jitter)
}

/// Honor a numeric `Retry-After` header (in seconds), capped. The HTTP-date
/// form is not parsed; callers fall back to `backoff_delay` when this is None.
fn retry_after(resp: &reqwest::Response) -> Option<Duration> {
    let raw = resp
        .headers()
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?;
    let secs: u64 = raw.trim().parse().ok()?;
    Some(Duration::from_secs(secs).min(RETRY_AFTER_CAP))
}

impl Upstream {
    fn new() -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .read_timeout(Duration::from_secs(30))
            .build()
            .expect("failed to build reqwest client");
        // Global politeness limit for libro.fm's API: ~2 requests/second.
        let limiter = Arc::new(RateLimiter::direct(Quota::per_second(
            NonZeroU32::new(2).expect("2 is nonzero"),
        )));
        Self { http, limiter }
    }

    /// Send a request with optional rate limiting and retry-with-backoff for
    /// transient failures. `build` is invoked once per attempt so the request
    /// (and its body) is freshly constructed each time.
    ///
    /// Returns the final `Response` even if it still carries a transient status
    /// after the last attempt, so the caller can map the status code as it sees
    /// fit; returns `Err` only for a transport error that never produced a
    /// response. Transient failures are logged loudly along the way.
    async fn send(
        &self,
        label: &str,
        rate_limited: bool,
        build: impl Fn(&reqwest::Client) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, reqwest::Error> {
        for attempt in 1..=MAX_ATTEMPTS {
            if rate_limited {
                self.limiter
                    .until_ready_with_jitter(Jitter::up_to(Duration::from_millis(100)))
                    .await;
            }

            match build(&self.http).send().await {
                Ok(resp) => {
                    let status = resp.status();
                    if !is_transient(status) {
                        return Ok(resp);
                    }
                    if attempt == MAX_ATTEMPTS {
                        error!(
                            "[{}] upstream still {} after {} attempts; giving up",
                            label, status, MAX_ATTEMPTS
                        );
                        return Ok(resp);
                    }
                    let delay = retry_after(&resp).unwrap_or_else(|| backoff_delay(attempt));
                    warn!(
                        "[{}] upstream {} (attempt {}/{}); retrying in {:?}",
                        label, status, attempt, MAX_ATTEMPTS, delay
                    );
                    sleep(delay).await;
                }
                Err(e) => {
                    let transient = e.is_timeout() || e.is_connect();
                    if !transient || attempt == MAX_ATTEMPTS {
                        error!(
                            "[{}] request failed (attempt {}/{}): {}",
                            label, attempt, MAX_ATTEMPTS, e
                        );
                        return Err(e);
                    }
                    let delay = backoff_delay(attempt);
                    warn!(
                        "[{}] transient transport error (attempt {}/{}): {}; retrying in {:?}",
                        label, attempt, MAX_ATTEMPTS, e, delay
                    );
                    sleep(delay).await;
                }
            }
        }
        unreachable!("retry loop returns on the final attempt")
    }
}

#[get("/")]
async fn index() -> Option<NamedFile> {
    NamedFile::open("client/index.html").await.ok()
}

#[get("/success")]
async fn success() -> Option<NamedFile> {
    NamedFile::open("client/success.html").await.ok()
}

#[get("/output.css")]
async fn css() -> Option<NamedFile> {
    NamedFile::open("client/output.css").await.ok()
}

#[derive(FromForm)]
struct Auth<'r> {
    username: &'r str,
    password: &'r str,
}

#[derive(Deserialize, Debug)]
#[serde(crate = "rocket::serde")]
struct Token {
    access_token: String,
}

#[post("/auth", data = "<auth>")]
async fn auth(
    auth: Form<Auth<'_>>,
    up: &State<Upstream>,
    goatcounter: &State<Option<GoatCounter>>,
) -> Result<Redirect, Unauthorized<Option<NamedFile>>> {
    let mut map = HashMap::new();
    map.insert("grant_type", "password");
    map.insert("username", auth.username);
    map.insert("password", auth.password);

    let resp = up
        .send("auth", true, |c| {
            c.post("https://libro.fm/oauth/token")
                .header("User-Agent", "Bookstride <jocelyn@nettek.ca>")
                .header("X-LibroFm-AppVer", "7.34.8")
                .json(&map)
        })
        .await;

    match resp {
        Err(_e) => {
            return Err(Unauthorized(
                NamedFile::open("client/unauthorized.html").await.ok(),
            ));
        }
        Ok(resp) => {
            if resp.status() != StatusCode::OK {
                return Err(Unauthorized(
                    NamedFile::open("client/unauthorized.html").await.ok(),
                ));
            }

            match resp.json::<Token>().await {
                Err(_e) => {
                    return Err(Unauthorized(
                        NamedFile::open("client/unauthorized.html").await.ok(),
                    ));
                }
                Ok(resp) => {
                    if let Some(gc) = &**goatcounter {
                        gc.hit("server/login-success").await;
                    }
                    Ok(Redirect::to(format!(
                        "/success?token={}",
                        RawStr::new(&resp.access_token).percent_encode()
                    )))
                }
            }
        }
    }
}

#[derive(Serialize, Debug)]
#[serde(crate = "rocket::serde")]
struct MinimalBook {
    title: String,
    author1: String,
    isbn: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    track_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    track_seconds: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    changed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_touched_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    finished: Option<bool>,
}

#[derive(Deserialize, Debug, Clone, Default)]
#[serde(crate = "rocket::serde")]
struct LibroUserMetadata {
    #[serde(default)]
    changed_at: Option<String>,
    #[serde(default, rename = "last_touched_at")]
    last_touched_at: Option<String>,
    #[serde(default, rename = "track_index")]
    track_index: Option<i64>,
    #[serde(default, rename = "track_seconds")]
    track_seconds: Option<f64>,
    #[serde(default)]
    finished: Option<bool>,
    /// Parsed but unused for now; kept so the struct mirrors the API and
    /// the watch can request it later without a schema change.
    #[allow(dead_code)]
    #[serde(default)]
    hidden: Option<bool>,
}

#[derive(Deserialize, Debug)]
#[serde(crate = "rocket::serde")]
struct LibroBook {
    title: String,
    authors: Vec<String>,
    isbn: i64,
    #[serde(default)]
    user_metadata: Option<LibroUserMetadata>,
}

#[derive(Deserialize, Debug)]
#[serde(crate = "rocket::serde")]
struct LibroBooksResponse {
    audiobooks: Vec<LibroBook>,
    page: u32,
    total_pages: u32,
}

#[derive(Serialize, Debug)]
#[serde(crate = "rocket::serde")]
struct MinimalBooksResponse {
    res: Vec<MinimalBook>,
    more: bool,
}

/// Formats a `SystemTime` as UTC ISO-8601 with millisecond precision,
/// matching libro.fm's `ApiDateFormat`: `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`
/// (e.g. `2026-09-15T13:44:12.345Z`). Hand-rolled civil-date conversion
/// (Howard Hinnant's civil_from_days) to avoid a chrono dependency.
fn iso8601_millis(t: SystemTime) -> String {
    let millis = t
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as i64;
    let days = millis.div_euclid(86_400_000);
    let ms_of_day = millis.rem_euclid(86_400_000);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    let (hh, mm, ss, mmm) = (
        ms_of_day / 3_600_000,
        (ms_of_day / 60_000) % 60,
        (ms_of_day / 1000) % 60,
        ms_of_day % 1000,
    );
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}.{mmm:03}Z")
}

/// libro.fm API base URL for the position endpoints. Injectable so tests
/// can point at a mock server.
#[derive(Clone)]
struct LibroApi {
    base: Arc<String>,
}

impl Default for LibroApi {
    fn default() -> Self {
        Self::with_base("https://libro.fm")
    }
}

impl LibroApi {
    fn with_base(base: &str) -> Self {
        Self {
            base: Arc::new(base.to_string()),
        }
    }

    fn base(&self) -> &str {
        &self.base
    }
}

/// A book's server-side listening position, as stored in the
/// `user_metadata` of a library entry. All fields optional: books never
/// played anywhere have none.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(crate = "rocket::serde")]
struct BookPosition {
    isbn: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    track_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    track_seconds: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    changed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_touched_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    finished: Option<bool>,
}

impl BookPosition {
    fn from_book(book: LibroBook) -> Self {
        let m = book.user_metadata;
        Self {
            isbn: book.isbn,
            track_index: m.as_ref().and_then(|m| m.track_index),
            track_seconds: m.as_ref().and_then(|m| m.track_seconds),
            changed_at: m.as_ref().and_then(|m| m.changed_at.clone()),
            last_touched_at: m.as_ref().and_then(|m| m.last_touched_at.clone()),
            finished: m.as_ref().and_then(|m| m.finished),
        }
    }
}

/// Per-bearer cache of library position dumps (see `POSITION_CACHE_TTL`).
#[derive(Default)]
struct PositionCache(Mutex<HashMap<String, (Instant, Vec<BookPosition>)>>);

struct AuthHeader {
    header: String,
}

#[rocket::async_trait]
impl<'a> FromRequest<'a> for AuthHeader {
    type Error = ();

    async fn from_request(req: &'a Request<'_>) -> Outcome<Self, ()> {
        let header = req.headers().get_one("Authorization");
        match header {
            Some(header) => Outcome::Success(Self {
                header: header.to_string(),
            }),
            None => Outcome::Forward(Status::Unauthorized),
        }
    }
}

#[get("/v0/lib/<page>")]
async fn v0_lib(
    page: usize,
    auth: AuthHeader,
    up: &State<Upstream>,
    api: &State<LibroApi>,
    goatcounter: &State<Option<GoatCounter>>,
) -> Result<Json<MinimalBooksResponse>, Status> {
    let resp = up
        .send("library", true, |c| {
            c.get(format!(
                "{}/api/{}/library?page={}",
                api.base(),
                LIBRO_API_VERSION,
                page
            ))
            .header("Authorization", &auth.header)
        })
        .await;

    match resp {
        Err(_e) => Err(Status::InternalServerError),
        Ok(resp) => {
            if resp.status() != StatusCode::OK {
                return Err(
                    Status::from_code(resp.status().into()).unwrap_or(Status::InternalServerError)
                );
            }

            match resp.json::<LibroBooksResponse>().await {
                Err(_e) => {
                    eprintln!("unknown json {:?}", _e);
                    Err(Status::InternalServerError)
                }
                Ok(resp) => {
                    if let Some(gc) = &**goatcounter {
                        gc.hit("server/library-list").await;
                    }
                    Ok(Json(MinimalBooksResponse {
                        res: resp
                            .audiobooks
                            .into_iter()
                            .map(|book| {
                                let m = book.user_metadata;
                                MinimalBook {
                                    title: book.title,
                                    author1: book
                                        .authors
                                        .first()
                                        .map(|s| s as &str)
                                        .unwrap_or("(missing)")
                                        .to_string(),
                                    isbn: book.isbn,
                                    track_index: m.as_ref().and_then(|m| m.track_index),
                                    track_seconds: m.as_ref().and_then(|m| m.track_seconds),
                                    changed_at: m.as_ref().and_then(|m| m.changed_at.clone()),
                                    last_touched_at: m
                                        .as_ref()
                                        .and_then(|m| m.last_touched_at.clone()),
                                    finished: m.as_ref().and_then(|m| m.finished),
                                }
                            })
                            .collect(),
                        more: resp.total_pages > resp.page,
                    }))
                }
            }
        }
    }
}

/// Payload for `POST /v0/position`: the watch's latest position for one
/// book. `track_index` is zero-indexed and `track_seconds` is seconds
/// within that track, exactly as libro.fm stores them.
///
/// The watch (Connect IQ `Communications.makeWebRequest`) encodes a
/// dictionary body as `application/x-www-form-urlencoded` — it has no
/// JSON encoder for request bodies — so this must parse as a form, not
/// JSON.
#[derive(FromForm, Debug)]
struct PositionIn {
    isbn: i64,
    track_index: i64,
    track_seconds: f64,
}

/// One audiobook entry of libro.fm's `library/sync_library` request body.
/// Field names match the decompiled `SyncBookRequest`; `finished` is a
/// JSON string in sync requests (null here — the watch never marks books
/// finished), unlike the boolean in library responses.
#[derive(Serialize, Debug)]
#[serde(crate = "rocket::serde")]
struct SyncBookRequest {
    isbn: i64,
    hide: bool,
    finished: Option<String>,
    track_seconds: f64,
    track_index: i64,
    last_touched_at: String,
    changed_at: String,
}

#[derive(Serialize, Debug)]
#[serde(crate = "rocket::serde")]
struct SyncLibraryRequest {
    audiobooks: Vec<SyncBookRequest>,
}

#[derive(Deserialize, Debug, Default, Serialize, PartialEq)]
#[serde(crate = "rocket::serde")]
struct SyncLibraryResponse {
    #[serde(default, rename = "updated_isbns")]
    updated_isbns: Vec<i64>,
    /// The stamp this write put on the record, echoed back so the client
    /// can remember what the cloud looked like after its own push (libro.fm
    /// takes ~10 s to surface writes in reads, so the watch must not
    /// re-read to learn this).
    #[serde(
        default,
        rename = "changed_at",
        skip_serializing_if = "Option::is_none"
    )]
    changed_at: Option<String>,
}

/// Headers libro.fm's Android client sends on every API request
/// (rest/interceptors/AuthInterceptor). The server mirrors them so
/// position writes look like the app's own traffic.
fn libro_app_headers(builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    builder
        .header("X-LibroFm-Device", "Pixel 8")
        .header("X-LibroFm-OsVer", "Android 34")
        .header("X-LibroFm-AppVer", "7.38.2")
}

/// Push one book's position to libro.fm's `library/sync_library`, as the
/// Android app's CloudSyncHandler does on play-state changes. Both
/// timestamps are stamped server-side (`changed_at = last_touched_at =
/// now`) so the watch's clock can never poison the last-writer-wins
/// ordering. Any non-success status is surfaced as-is.
async fn sync_position(
    up: &Upstream,
    api: &LibroApi,
    auth: &str,
    isbn: i64,
    track_index: i64,
    track_seconds: f64,
) -> Result<SyncLibraryResponse, Status> {
    let stamp = iso8601_millis(SystemTime::now());
    let changed_at = stamp.clone();
    let req = SyncLibraryRequest {
        audiobooks: vec![SyncBookRequest {
            isbn,
            hide: false,
            finished: None,
            track_seconds,
            track_index,
            last_touched_at: stamp.clone(),
            changed_at: stamp,
        }],
    };

    let url = format!(
        "{}/api/{}/library/sync_library",
        api.base(),
        LIBRO_API_VERSION
    );
    let resp = up
        .send("sync-library", true, |c| {
            libro_app_headers(c.post(url.as_str()).header("Authorization", auth)).json(&req)
        })
        .await
        .map_err(|_| Status::InternalServerError)?;

    let status = resp.status();
    if status.is_success() {
        let mut parsed = resp.json::<SyncLibraryResponse>().await.unwrap_or_default();
        parsed.changed_at = Some(changed_at);
        return Ok(parsed);
    }
    Err(status_to_status(&status).unwrap_or(Status::InternalServerError))
}

fn status_to_status(code: &StatusCode) -> Option<Status> {
    Status::from_code(code.as_u16())
}

/// Fetch the whole library with position metadata, paginating through
/// libro.fm's library dump (v12). An empty list means either an empty
/// library or a dump without `user_metadata`; the caller decides.
async fn fetch_library_positions(
    up: &Upstream,
    api: &LibroApi,
    auth: &str,
) -> Result<Vec<BookPosition>, Status> {
    let mut out: Vec<BookPosition> = Vec::new();
    let mut page = 1usize;
    let mut total_pages = 1u32;
    while page as u32 <= total_pages && page <= 100 {
        let url = format!(
            "{}/api/{}/library?page={}",
            api.base(),
            LIBRO_API_VERSION,
            page
        );
        let resp = up
            .send("library-positions", true, |c| {
                c.get(url.as_str()).header("Authorization", auth)
            })
            .await
            .map_err(|_| Status::InternalServerError)?;
        let status = resp.status();
        if status != StatusCode::OK {
            return Err(status_to_status(&status).unwrap_or(Status::InternalServerError));
        }
        let parsed: LibroBooksResponse =
            resp.json().await.map_err(|_| Status::InternalServerError)?;
        total_pages = parsed.total_pages.max(1);
        for book in parsed.audiobooks {
            out.push(BookPosition::from_book(book));
        }
        page += 1;
    }
    Ok(out)
}

/// Record the watch's latest position for one book with libro.fm. The
/// watch only sends isbn/track/seconds; the server stamps the timestamps
/// libro.fm's conflict resolution runs on. Returns the pass-through
/// `updated_isbns` list on success.
#[post("/v0/position", data = "<pos>")]
async fn v0_set_position(
    pos: Form<PositionIn>,
    auth: AuthHeader,
    up: &State<Upstream>,
    api: &State<LibroApi>,
    goatcounter: &State<Option<GoatCounter>>,
) -> Result<Json<SyncLibraryResponse>, Status> {
    let pos = pos.into_inner();
    if pos.track_index < 0 || !pos.track_seconds.is_finite() || pos.track_seconds < 0.0 {
        return Err(Status::BadRequest);
    }
    let updated = sync_position(
        up,
        api,
        &auth.header,
        pos.isbn,
        pos.track_index,
        pos.track_seconds,
    )
    .await?;
    if let Some(gc) = &**goatcounter {
        gc.hit("server/position-set").await;
    }
    Ok(Json(updated))
}

/// Read one book's server-side position. Sourced from a per-bearer,
/// short-TTL cache; 404 if the isbn is not in the library.
#[get("/v0/position/<isbn>")]
async fn v0_get_position(
    isbn: i64,
    auth: AuthHeader,
    up: &State<Upstream>,
    api: &State<LibroApi>,
    cache: &State<PositionCache>,
) -> Result<Json<BookPosition>, Status> {
    let key = auth.header.clone();
    {
        let map = cache.0.lock().expect("position cache lock");
        if let Some((at, list)) = map.get(&key) {
            if at.elapsed() < POSITION_CACHE_TTL {
                return list
                    .iter()
                    .find(|p| p.isbn == isbn)
                    .cloned()
                    .map(Json)
                    .ok_or(Status::NotFound);
            }
        }
    }
    let list = fetch_library_positions(up, api, &auth.header).await?;
    {
        let mut map = cache.0.lock().expect("position cache lock");
        if map.len() >= 16 {
            map.clear();
        }
        map.insert(key, (Instant::now(), list.clone()));
    }
    list.iter()
        .find(|p| p.isbn == isbn)
        .cloned()
        .map(Json)
        .ok_or(Status::NotFound)
}

#[derive(Database)]
#[database("sqlite")]
pub struct Db(sqlx::SqlitePool);

#[derive(Serialize, Debug)]
#[serde(crate = "rocket::serde")]
struct DownloadInfo {
    tracks: usize,
}

#[derive(Deserialize, Debug)]
#[serde(crate = "rocket::serde")]
struct LibroManifestPart {
    url: String,
}

#[derive(Deserialize, Debug)]
#[serde(crate = "rocket::serde")]
struct LibroTrack {}

#[derive(Deserialize, Debug)]
#[serde(crate = "rocket::serde")]
struct LibroManifestResponse {
    parts: Vec<LibroManifestPart>,
    tracks: Vec<LibroTrack>,
}

#[post("/v0/book/<isbn>/download")]
async fn v0_start_download(
    isbn: i64,
    auth: AuthHeader,
    db: &Db,
    up: &State<Upstream>,
    goatcounter: &State<Option<GoatCounter>>,
) -> Result<Accepted<Json<DownloadInfo>>, Status> {
    let resp = up
        .send("download-manifest", true, |c| {
            c.get(format!(
                "https://libro.fm/api/v10/download-manifest?isbn={}",
                isbn
            ))
            .header("Authorization", &auth.header)
        })
        .await;

    match resp {
        Err(_e) => Err(Status::InternalServerError),
        Ok(resp) => {
            if resp.status() != StatusCode::OK {
                return Err(
                    Status::from_code(resp.status().into()).unwrap_or(Status::InternalServerError)
                );
            }

            match resp.json::<LibroManifestResponse>().await {
                Err(_e) => {
                    eprintln!("unknown json {:?}", _e);
                    Err(Status::InternalServerError)
                }

                Ok(resp) => {
                    let token = &auth.header;
                    let mut tx = db.begin().await.map_err(|e| {
                        eprintln!("err: {:?}", e);
                        Status::InternalServerError
                    })?;

                    let time: i64 = SystemTime::now()
                        .duration_since(SystemTime::UNIX_EPOCH)
                        .unwrap()
                        .as_secs() as i64;

                    sqlx::query!(
                        "DELETE FROM track WHERE isbn = ? AND bearer = ?",
                        isbn,
                        token,
                    )
                    .execute(&mut *tx)
                    .await
                    .map_err(|_| Status::InternalServerError)?;

                    sqlx::query!(
                        "DELETE FROM track WHERE isbn = ? AND bearer = ?",
                        isbn,
                        token,
                    )
                    .execute(&mut *tx)
                    .await
                    .map_err(|_| Status::InternalServerError)?;

                    for (i, _) in resp.tracks.iter().enumerate() {
                        let i = i as i64;
                        let id = rand::random::<i64>();

                        sqlx::query!(
                            "INSERT INTO track (isbn, bearer, track, datetime, file_id, ready) VALUES (?, ?, ?, ?, ?, ?)",
                            isbn,
                            token,
                            i,
                            time,
                            id,
                            false
                        )
                        .execute(&mut *tx)
                        .await
                        .map_err(|_| Status::InternalServerError)?;
                    }
                    for (i, part) in resp.parts.iter().enumerate() {
                        let time_with_lies = time + (i as i64);
                        sqlx::query!(
                            "INSERT INTO download (isbn, bearer, datetime, path) VALUES (?, ?, ?, ?)",
                            isbn,
                            token,
                            time_with_lies,
                            part.url
                        ).execute(&mut *tx).await.map_err(|_| Status::InternalServerError)?;
                    }
                    if let Err(e) = tx.commit().await {
                        eprintln!("err: {:?}", e);
                        return Err(Status::InternalServerError);
                    }
                    if let Some(gc) = &**goatcounter {
                        gc.hit("server/download-start").await;
                    }
                    Ok(Accepted(Json(DownloadInfo {
                        tracks: resp.tracks.len(),
                    })))
                }
            }
        }
    }
}

/// Resolve the media cache directory (`$HOME/bookstride-cache`). Falls
/// back to a `bookstride-cache` directory in the current working
/// directory if `$HOME` is unset, which should only happen in unusual
/// test environments.
fn media_cache_dir() -> PathBuf {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() => PathBuf::from(home).join(MEDIA_CACHE_DIRNAME),
        _ => PathBuf::from(MEDIA_CACHE_DIRNAME),
    }
}

/// Create the media cache directory if it doesn't already exist. Logs a
/// warning on failure but does not panic, so a misconfigured home still
/// lets the server start (downloads will fail per-file instead).
fn ensure_media_cache_dir() {
    let dir = media_cache_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        warn!("could not create media cache dir {}: {}", dir.display(), e);
    }
}

/// Path for a single cached media part.
fn get_media_path(file_id: i64) -> PathBuf {
    media_cache_dir().join(format!("bookstride_cache_{}.mp3", file_id))
}

/// Parse the `MAX_MEDIA_SIZE` env var into a byte count. Accepts a bare
/// integer (bytes) or a number with a unit suffix: `K`/`KB`, `M`/`MB`,
/// `G`/`GB`, `T`/`TB` (case-insensitive). Uses binary multiples
/// (1G = 1024^3). Falls back to [`DEFAULT_MAX_MEDIA_SIZE`] on any parse
/// error or missing var.
fn max_media_size() -> u64 {
    let raw = match std::env::var("MAX_MEDIA_SIZE") {
        Ok(v) => v,
        Err(_) => return DEFAULT_MAX_MEDIA_SIZE,
    };
    parse_size(&raw).unwrap_or_else(|e| {
        warn!(
            "invalid MAX_MEDIA_SIZE {:?} ({}); using default {}",
            raw, e, DEFAULT_MAX_MEDIA_SIZE
        );
        DEFAULT_MAX_MEDIA_SIZE
    })
}

/// Parse a human-friendly size string into bytes. See [`max_media_size`].
fn parse_size(s: &str) -> Result<u64, String> {
    let trimmed = s.trim();
    let (digits, rest) = trimmed.split_at(
        trimmed
            .find(|c: char| !c.is_ascii_digit() && c != '.')
            .unwrap_or(trimmed.len()),
    );
    let num: f64 = digits
        .parse()
        .map_err(|_| format!("no leading number in {s:?}"))?;
    if num < 0.0 {
        return Err(format!("negative size in {s:?}"));
    }
    let unit = rest.trim().to_ascii_lowercase();
    let unit = unit.trim_end_matches('b');
    let mult: f64 = match unit {
        "" => 1.0,
        "k" => 1024.0,
        "m" => 1024.0 * 1024.0,
        "g" => 1024.0 * 1024.0 * 1024.0,
        "t" => 1024.0f64 * 1024.0 * 1024.0 * 1024.0,
        other => return Err(format!("unknown unit {:?} in {s:?}", other)),
    };
    Ok((num * mult) as u64)
}

/// If the media cache exceeds `max_bytes`, delete the oldest media files
/// (by modification time) to make room. At most 10 files are removed per
/// call, and only when the total is over the threshold — so this is safe
/// to invoke before every part fetch. Errors are logged and swallowed:
/// a cache prune failure must not abort a download.
fn prune_media_cache(max_bytes: u64) {
    let dir = media_cache_dir();
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(e) => {
            // ENOENT is harmless (nothing to prune); anything else is
            // worth a log line.
            if e.kind() != io::ErrorKind::NotFound {
                warn!("prune: cannot read {}: {}", dir.display(), e);
            }
            return;
        }
    };

    // Collect (path, size, mtime) for files matching our naming scheme.
    let mut files: Vec<(PathBuf, u64, SystemTime)> = Vec::new();
    let mut total: u64 = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n,
            None => continue,
        };
        if !name.starts_with("bookstride_cache_") || !name.ends_with(".mp3") {
            continue;
        }
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.is_file() {
            continue;
        }
        let size = meta.len();
        let mtime = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        total += size;
        files.push((path, size, mtime));
    }

    if total <= max_bytes {
        return;
    }

    // Oldest first (by mtime; ties broken by path for determinism).
    files.sort_by(|a, b| a.2.cmp(&b.2).then_with(|| a.0.cmp(&b.0)));

    let to_remove = files.len().min(10);
    info!(
        "media cache {} bytes > limit {} bytes; removing {} oldest file(s)",
        total, max_bytes, to_remove
    );
    for (path, _, _) in files.iter().take(to_remove) {
        if let Err(e) = std::fs::remove_file(path) {
            warn!("prune: could not remove {}: {}", path.display(), e);
        }
    }
}

#[get("/v0/book/<isbn>/<track>/track.mp3")]
async fn v0_get_download(
    isbn: i64,
    track: u32,
    auth: AuthHeader,
    db: &Db,
) -> Result<Vec<u8>, Status> {
    let file = sqlx::query!(
        "SELECT file_id, ready FROM track WHERE isbn = ? AND bearer = ? AND track = ?",
        isbn,
        auth.header,
        track
    );
    if let Ok(file) = file.fetch_one(&**db).await {
        if file.ready {
            match std::fs::read(get_media_path(file.file_id)) {
                Ok(data) => Ok(data),
                Err(_) => Err(Status::NotFound),
            }
        } else {
            Err(Status::TooManyRequests)
        }
    } else {
        Err(Status::NotFound)
    }
}

async fn run_migrations(rocket: Rocket<Build>) -> fairing::Result {
    match Db::fetch(&rocket) {
        Some(db) => match rocket_db_pools::sqlx::migrate!().run(&**db).await {
            Ok(_) => Ok(rocket),
            Err(e) => {
                error!("Failed to run database migrations: {}", e);
                Err(rocket)
            }
        },
        None => Err(rocket),
    }
}

async fn run_audio_downloads(rocket: Rocket<Build>) -> fairing::Result {
    let pool = match Db::fetch(&rocket) {
        Some(pool) => pool.0.clone(), // clone the wrapped pool
        None => return Err(rocket),
    };
    let up = match rocket.state::<Upstream>() {
        Some(up) => up.clone(),
        None => return Err(rocket),
    };
    let gc: Option<GoatCounter> = rocket
        .state::<Option<GoatCounter>>()
        .and_then(|o| o.clone());
    let max_bytes = max_media_size();

    ensure_media_cache_dir();

    rocket::tokio::task::spawn(async move {
        loop {
            if let Ok(res) = sqlx::query!(
                r"WITH first AS (
                SELECT
                    isbn,
                    bearer
                FROM download
                WHERE isbn
                ORDER BY datetime
                LIMIT 1
            ) SELECT
                first.isbn AS isbn,
                first.bearer AS bearer,
                path 
            FROM first
            LEFT JOIN download
            ON download.isbn = first.isbn AND download.bearer = first.bearer"
            )
            .fetch_all(&pool)
            .await
            {
                if let Some(first) = res.first() {
                    // The track slots to fill, in order.
                    let track_file_ids: Vec<i64> = sqlx::query!(
                        "SELECT file_id FROM track WHERE isbn = ? AND bearer = ? ORDER BY track",
                        first.isbn,
                        first.bearer,
                    )
                    .fetch_all(&pool)
                    .await
                    .unwrap()
                    .into_iter()
                    .map(|r| r.file_id)
                    .collect();

                    let mut next_track = 0usize;
                    let mut failed = false;

                    // Download and extract every part; bail on the first hard
                    // failure so we never mark a half-downloaded book ready.
                    'parts: for part in &res {
                        let path = match &part.path {
                            Some(path) => path,
                            None => continue,
                        };

                        // Make room before fetching: if the cache is over
                        // its limit, drop the oldest media files first.
                        prune_media_cache(max_bytes);

                        let resp = match up.send("download", false, |c| c.get(path.as_str())).await
                        {
                            Ok(resp) if resp.status() == StatusCode::OK => resp,
                            Ok(resp) => {
                                error!(
                                    "[download] isbn {} part fetch returned {}",
                                    first.isbn,
                                    resp.status()
                                );
                                failed = true;
                                break 'parts;
                            }
                            Err(_) => {
                                // send() already logged the transport error.
                                failed = true;
                                break 'parts;
                            }
                        };

                        let bytes = match resp.bytes().await {
                            Ok(bytes) => bytes,
                            Err(e) => {
                                error!("[download] isbn {} body read failed: {}", first.isbn, e);
                                failed = true;
                                break 'parts;
                            }
                        };

                        let mut archive = match zip::ZipArchive::new(Cursor::new(bytes)) {
                            Ok(archive) => archive,
                            Err(e) => {
                                error!("[download] isbn {} bad zip archive: {}", first.isbn, e);
                                failed = true;
                                break 'parts;
                            }
                        };

                        for i in 0..archive.len() {
                            let mut file = archive.by_index(i).unwrap();
                            let is_mp3 = file
                                .enclosed_name()
                                .and_then(|p| {
                                    p.file_name()
                                        .and_then(|n| n.to_str())
                                        .map(|s| s.ends_with(".mp3"))
                                })
                                .unwrap_or(false);
                            if !is_mp3 || file.is_dir() {
                                continue;
                            }

                            let Some(file_id) = track_file_ids.get(next_track) else {
                                error!(
                                    "[download] isbn {} has more mp3s than expected tracks",
                                    first.isbn
                                );
                                failed = true;
                                break 'parts;
                            };

                            let outpath = get_media_path(*file_id);
                            let write = File::create(&outpath)
                                .and_then(|mut out| io::copy(&mut file, &mut out).map(|_| ()));
                            if let Err(e) = write {
                                error!(
                                    "[download] isbn {} failed writing {}: {}",
                                    first.isbn,
                                    outpath.display(),
                                    e
                                );
                                failed = true;
                                break 'parts;
                            }
                            next_track += 1;
                        }
                    }

                    let complete = !failed && next_track == track_file_ids.len();

                    let mut tx = pool.begin().await.unwrap();
                    if complete {
                        sqlx::query!(
                            "UPDATE track SET ready = 1 WHERE isbn = ? AND bearer = ?",
                            first.isbn,
                            first.bearer,
                        )
                        .execute(&mut *tx)
                        .await
                        .unwrap();

                        sqlx::query!(
                            "DELETE FROM download WHERE isbn = ? AND bearer = ?",
                            first.isbn,
                            first.bearer,
                        )
                        .execute(&mut *tx)
                        .await
                        .unwrap();

                        info!(
                            "[download] completed isbn {} ({} tracks)",
                            first.isbn,
                            track_file_ids.len()
                        );
                        if let Some(ref gc) = gc {
                            gc.hit("server/download-complete").await;
                        }
                    } else {
                        // Give up on this job rather than wedge the queue or
                        // leave phantom "ready" tracks. Drop its rows entirely;
                        // the watch then sees a 404 and surfaces the failure, and
                        // the user can re-trigger the download.
                        error!(
                            "[download] giving up on isbn {} ({}/{} tracks); dropping job",
                            first.isbn,
                            next_track,
                            track_file_ids.len()
                        );
                        for file_id in &track_file_ids {
                            let _ = std::fs::remove_file(get_media_path(*file_id));
                        }
                        sqlx::query!(
                            "DELETE FROM track WHERE isbn = ? AND bearer = ?",
                            first.isbn,
                            first.bearer,
                        )
                        .execute(&mut *tx)
                        .await
                        .unwrap();

                        sqlx::query!(
                            "DELETE FROM download WHERE isbn = ? AND bearer = ?",
                            first.isbn,
                            first.bearer,
                        )
                        .execute(&mut *tx)
                        .await
                        .unwrap();
                    }

                    if let Err(e) = tx.commit().await {
                        error!("[download] commit failed for isbn {}: {}", first.isbn, e);
                    }
                }
            }

            sleep(Duration::from_millis(100)).await;
        }
    });

    Ok(rocket)
}

#[launch]
async fn rocket() -> _ {
    let migrations_fairing = AdHoc::try_on_ignite("SQLx Migrations", run_migrations);
    let downloads_fairing = AdHoc::try_on_ignite("Audio downloads", run_audio_downloads);

    let rocket = rocket::build();
    let figment = rocket
        .figment()
        .clone()
        .merge((Config::PORT, 8000))
        .merge(("databases.sqlite.url", "bookstride_srv.sqlite"));

    rocket
        .configure(figment)
        .manage(Upstream::new())
        .manage(LibroApi::default())
        .manage(PositionCache::default())
        .manage(GoatCounter::from_env())
        .attach(Db::init())
        .attach(migrations_fairing)
        .attach(downloads_fairing)
        .mount(
            "/",
            routes![
                index,
                css,
                auth,
                success,
                v0_lib,
                v0_set_position,
                v0_get_position,
                v0_start_download,
                v0_get_download
            ],
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{body_partial_json, header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    // An Upstream with an effectively-unlimited limiter, so tests exercise the
    // retry logic without waiting on rate limiting.
    fn test_upstream() -> Upstream {
        Upstream {
            http: reqwest::Client::new(),
            limiter: Arc::new(RateLimiter::direct(Quota::per_second(
                NonZeroU32::new(1000).unwrap(),
            ))),
        }
    }

    #[test]
    fn transient_classification() {
        for code in [408u16, 429, 500, 502, 503, 504] {
            assert!(
                is_transient(StatusCode::from_u16(code).unwrap()),
                "{code} should be transient"
            );
        }
        for code in [200u16, 301, 400, 401, 404, 501] {
            assert!(
                !is_transient(StatusCode::from_u16(code).unwrap()),
                "{code} should not be transient"
            );
        }
    }

    #[test]
    fn backoff_is_bounded() {
        for _ in 0..1000 {
            // attempt 1 => 250..=500ms with full jitter.
            let d1 = backoff_delay(1);
            assert!(
                d1 >= Duration::from_millis(250) && d1 <= Duration::from_millis(500),
                "attempt-1 backoff out of range: {d1:?}"
            );
            // A large attempt must saturate rather than overflow the shift, and
            // stay capped at 30s.
            assert!(backoff_delay(40) <= Duration::from_millis(30_000));
        }
    }

    #[tokio::test]
    async fn retries_transient_status_then_succeeds() {
        let server = MockServer::start().await;
        // First two requests get 503; the third (and beyond) gets 200.
        Mock::given(method("GET"))
            .and(path("/thing"))
            .respond_with(ResponseTemplate::new(503))
            .up_to_n_times(2)
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/thing"))
            .respond_with(ResponseTemplate::new(200))
            .with_priority(2)
            .mount(&server)
            .await;

        let up = test_upstream();
        let url = format!("{}/thing", server.uri());
        let resp = up
            .send("test", false, |c| c.get(url.as_str()))
            .await
            .expect("should return a response");
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn honors_retry_after_and_returns_final_status() {
        let server = MockServer::start().await;
        // Always 429; Retry-After: 0 keeps the test fast while still exercising
        // the header-parsing path.
        Mock::given(method("GET"))
            .and(path("/rl"))
            .respond_with(ResponseTemplate::new(429).insert_header("Retry-After", "0"))
            .mount(&server)
            .await;

        let up = test_upstream();
        let url = format!("{}/rl", server.uri());
        // After exhausting retries, send() returns the final transient response
        // rather than erroring, so the caller can map the status.
        let resp = up
            .send("test", false, |c| c.get(url.as_str()))
            .await
            .expect("should return the final response");
        assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
        // Confirm it actually retried MAX_ATTEMPTS times.
        let hits = server.received_requests().await.unwrap().len();
        assert_eq!(hits, MAX_ATTEMPTS as usize);
    }

    #[test]
    fn retry_after_parses_numeric_and_caps() {
        // Pure-value check on the cap constant and parsing intent.
        assert_eq!(RETRY_AFTER_CAP, Duration::from_secs(120));
    }

    // ------------------------------------------------------------------
    // GoatCounter analytics
    // ------------------------------------------------------------------

    #[test]
    fn goatcounter_from_env_absent() {
        // GOATCOUNTER_API_KEY is not set in the test environment.
        assert!(GoatCounter::from_env().is_none());
    }

    #[tokio::test]
    async fn goatcounter_hit_sends_correct_request() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/api/v0/count"))
            .and(header("Authorization", "Bearer test-api-key"))
            .and(body_partial_json(serde_json::json!({
                "no_sessions": true,
                "hits": [{
                    "path": "test/event",
                    "event": true
                }]
            })))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let gc = GoatCounter {
            api_key: "test-api-key".into(),
            endpoint: format!("{}/api/v0/count", server.uri()),
            http: reqwest::Client::new(),
        };

        gc.hit("test/event").await;

        // Verify the mock was hit exactly once.
        server.verify().await;
    }

    #[tokio::test]
    async fn goatcounter_hit_logs_non_200() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/api/v0/count"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let gc = GoatCounter {
            api_key: "test".into(),
            endpoint: format!("{}/api/v0/count", server.uri()),
            http: reqwest::Client::new(),
        };

        // Should not panic; hit() logs a warning internally.
        gc.hit("test/server-error").await;

        let hits = server.received_requests().await.unwrap().len();
        assert_eq!(hits, 1);
    }

    #[tokio::test]
    async fn goatcounter_hit_does_not_panic_on_transport_error() {
        // Point at an unused port — connection refused is fine.
        let gc = GoatCounter {
            api_key: "test".into(),
            endpoint: "http://127.0.0.1:1/api/v0/count".into(),
            http: reqwest::Client::new(),
        };

        // Should not panic; hit() logs a warning internally.
        gc.hit("test/transport-error").await;
    }

    #[test]
    fn parse_size_accepts_units() {
        assert_eq!(parse_size("0").unwrap(), 0);
        assert_eq!(parse_size("1024").unwrap(), 1024);
        assert_eq!(parse_size("1K").unwrap(), 1024);
        assert_eq!(parse_size("1KB").unwrap(), 1024);
        assert_eq!(parse_size("1M").unwrap(), 1024 * 1024);
        assert_eq!(parse_size("2GB").unwrap(), 2 * 1024 * 1024 * 1024);
        assert_eq!(parse_size("3G").unwrap(), 3 * 1024 * 1024 * 1024);
        assert_eq!(parse_size("1T").unwrap(), 1024u64 * 1024 * 1024 * 1024);
        // whitespace and case-insensitive
        assert_eq!(parse_size("  500 MB ").unwrap(), 500 * 1024 * 1024);
        assert_eq!(parse_size("3gb").unwrap(), 3 * 1024 * 1024 * 1024);
    }

    #[test]
    fn parse_size_rejects_garbage() {
        assert!(parse_size("abc").is_err());
        assert!(parse_size("-1").is_err());
        assert!(parse_size("1XB").is_err());
    }

    // ------------------------------------------------------------------
    // ISO-8601 stamping (libro.fm ApiDateFormat)
    // ------------------------------------------------------------------

    #[test]
    fn iso8601_epoch() {
        assert_eq!(
            iso8601_millis(SystemTime::UNIX_EPOCH),
            "1970-01-01T00:00:00.000Z"
        );
    }

    #[test]
    fn iso8601_known_timestamps() {
        // 2023-11-14T22:13:20.123Z
        let t = SystemTime::UNIX_EPOCH + Duration::from_millis(1_700_000_000_123);
        assert_eq!(iso8601_millis(t), "2023-11-14T22:13:20.123Z");
        // Leap-year day: 2024-02-29T23:59:59.999Z
        let t = SystemTime::UNIX_EPOCH + Duration::from_millis(1_709_251_199_999);
        assert_eq!(iso8601_millis(t), "2024-02-29T23:59:59.999Z");
        // Year rollover: 2025-01-01T00:00:00.000Z
        let t = SystemTime::UNIX_EPOCH + Duration::from_millis(1_735_689_600_000);
        assert_eq!(iso8601_millis(t), "2025-01-01T00:00:00.000Z");
    }

    // ------------------------------------------------------------------
    // Position sync (sync_library + library position dump)
    // ------------------------------------------------------------------

    #[tokio::test]
    async fn sync_position_sends_expected_payload() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/api/v12/library/sync_library"))
            .and(header("Authorization", "Bearer tok"))
            .and(body_partial_json(serde_json::json!({
                "audiobooks": [{
                    "isbn": 1234567,
                    "hide": false,
                    "finished": null,
                    "track_seconds": 12.5,
                    "track_index": 2
                }]
            })))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(serde_json::json!({ "updated_isbns": [1234567] })),
            )
            .mount(&server)
            .await;

        let up = test_upstream();
        let api = LibroApi::with_base(&server.uri());
        let out = sync_position(&up, &api, "Bearer tok", 1_234_567, 2, 12.5)
            .await
            .expect("sync should succeed");
        assert_eq!(out.updated_isbns, vec![1_234_567]);
        // The echo must carry the stamped changed_at.
        let resp_body = serde_json::to_string(&out).unwrap();
        assert!(resp_body.contains("changed_at"), "{resp_body}");
        // The stamp fields must be present and RFC3339-shaped.
        let requests = server.received_requests().await.unwrap();
        let body = String::from_utf8(requests[0].body.clone()).unwrap();
        assert!(body.contains("changed_at"), "body: {body}");
        assert!(body.contains("last_touched_at"), "body: {body}");
        // ISO-8601 UTC with millis, e.g. "2026-09-15T18:35:57.271Z".
        for field in ["\"changed_at\":\"", "\"last_touched_at\":\""] {
            let start = body.find(field).expect("field present") + field.len();
            let stamp = &body[start..start + 24];
            assert!(
                stamp.ends_with('Z') && stamp.as_bytes()[10] == b'T',
                "{stamp}"
            );
        }
        server.verify().await;
    }

    #[tokio::test]
    async fn sync_position_surfaces_404_without_fallback() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/api/v12/library/sync_library"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let up = test_upstream();
        let api = LibroApi::with_base(&server.uri());
        let err = sync_position(&up, &api, "Bearer tok", 99, 0, 1.0).await;
        assert_eq!(err, Err(Status::NotFound));
        // Exactly one attempt: there is no fallback to another version.
        let hits = server.received_requests().await.unwrap();
        assert_eq!(hits.len(), 1);
    }

    #[tokio::test]
    async fn sync_position_surfaces_auth_error() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/api/v12/library/sync_library"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server)
            .await;

        let up = test_upstream();
        let api = LibroApi::with_base(&server.uri());
        let err = sync_position(&up, &api, "Bearer tok", 99, 0, 1.0).await;
        assert_eq!(err, Err(Status::Unauthorized));
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn fetch_positions_paginates_and_parses_metadata() {
        let server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/api/v12/library"))
            .and(query_param("page", "1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "audiobooks": [{
                    "title": "Book One", "authors": ["A"], "isbn": 1,
                    "user_metadata": {
                        "track_index": 3, "track_seconds": 120.5,
                        "changed_at": "2026-09-15T00:00:00.000Z",
                        "last_touched_at": "2026-09-15T00:00:00.000Z",
                        "finished": false
                    }
                }],
                "page": 1, "total_pages": 2
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/api/v12/library"))
            .and(query_param("page", "2"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "audiobooks": [{
                    "title": "Book Two", "authors": ["B"], "isbn": 2
                }],
                "page": 2, "total_pages": 2
            })))
            .mount(&server)
            .await;

        let up = test_upstream();
        let api = LibroApi::with_base(&server.uri());
        let out = fetch_library_positions(&up, &api, "Bearer tok")
            .await
            .expect("dump should succeed");
        assert_eq!(out.len(), 2);
        let p1 = out.iter().find(|p| p.isbn == 1).unwrap();
        assert_eq!(p1.track_index, Some(3));
        assert_eq!(p1.track_seconds, Some(120.5));
        assert_eq!(p1.finished, Some(false));
        // Book Two has no metadata; fields must be None.
        let p2 = out.iter().find(|p| p.isbn == 2).unwrap();
        assert_eq!(p2.track_index, None);
        assert_eq!(p2.changed_at, None);
    }

    #[tokio::test]
    async fn fetch_positions_surfaces_auth_error() {
        let server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/api/v12/library"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server)
            .await;

        let up = test_upstream();
        let api = LibroApi::with_base(&server.uri());
        let err = fetch_library_positions(&up, &api, "Bearer tok").await;
        assert_eq!(err, Err(Status::Unauthorized));
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn fetch_positions_with_metadataless_dump_returns_none_fields() {
        let server = MockServer::start().await;

        // A schema (or account) without user_metadata: positions come back
        // empty rather than erroring; the GET handler then 404s per book.
        Mock::given(method("GET"))
            .and(path("/api/v12/library"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "audiobooks": [{"title": "X", "authors": ["A"], "isbn": 1}],
                "page": 1, "total_pages": 1
            })))
            .mount(&server)
            .await;

        let up = test_upstream();
        let api = LibroApi::with_base(&server.uri());
        let out = fetch_library_positions(&up, &api, "Bearer tok")
            .await
            .expect("metadataless dump should still read");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].track_index, None);
        assert_eq!(out[0].track_seconds, None);
    }

    #[test]
    fn max_media_size_defaults_when_unset() {
        // Make sure no override leaks in from the test runner env.
        std::env::remove_var("MAX_MEDIA_SIZE");
        assert_eq!(max_media_size(), DEFAULT_MAX_MEDIA_SIZE);
    }

    /// `prune_media_cache` against a throwaway temp directory: point HOME
    /// at it so `media_cache_dir()` resolves there, write a few files, and
    /// confirm only the oldest 10 get removed when over the limit.
    #[test]
    fn prune_removes_oldest_when_over_limit() {
        let tmp =
            std::env::temp_dir().join(format!("bookstride-prune-test-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let cache = tmp.join(MEDIA_CACHE_DIRNAME);
        std::fs::create_dir_all(&cache).unwrap();

        std::env::set_var("HOME", &tmp);
        assert_eq!(media_cache_dir(), cache);

        // Write 12 files of 100 bytes each = 1200 bytes total. Each gets
        // a distinct mtime so ordering is deterministic.
        for i in 0..12u64 {
            let p = cache.join(format!("bookstride_cache_{}.mp3", i));
            std::fs::write(&p, vec![0u8; 100]).unwrap();
            // Backdate older files so file 0 is the oldest.
            let secs = 1_700_000_000 + i;
            let _ =
                filetime::set_file_mtime(&p, filetime::FileTime::from_unix_time(secs as i64, 0));
        }
        // Also drop an unrelated file that must be ignored.
        std::fs::write(cache.join("notes.txt"), b"ignore me").unwrap();

        // Limit of 500 bytes: 1200 > 500, so oldest 10 removed.
        prune_media_cache(500);

        let remaining: Vec<String> = std::fs::read_dir(&cache)
            .unwrap()
            .flatten()
            .filter_map(|e| e.file_name().to_str().map(String::from))
            .filter(|n| n.starts_with("bookstride_cache_"))
            .collect();
        assert_eq!(
            remaining.len(),
            2,
            "expected 2 survivors, got {remaining:?}"
        );
        // Files 10 and 11 should survive (they had the newest mtimes).
        assert!(remaining.iter().any(|n| n.contains("_10.")));
        assert!(remaining.iter().any(|n| n.contains("_11.")));
        // The unrelated file is untouched.
        assert!(cache.join("notes.txt").exists());

        // Under the limit: no-op.
        prune_media_cache(10 * 1024);
        let still: Vec<_> = std::fs::read_dir(&cache)
            .unwrap()
            .flatten()
            .filter_map(|e| e.file_name().to_str().map(String::from))
            .filter(|n| n.starts_with("bookstride_cache_"))
            .collect();
        assert_eq!(still.len(), 2);

        std::env::remove_var("HOME");
        std::fs::remove_dir_all(&tmp).unwrap();
    }
}
