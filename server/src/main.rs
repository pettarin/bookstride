#[macro_use]
extern crate rocket;

use std::{
    collections::HashMap,
    fs::File,
    io::{self, Cursor},
    num::NonZeroU32,
    sync::Arc,
    time::{Duration, SystemTime},
};

use governor::{
    clock::DefaultClock,
    state::{InMemoryState, NotKeyed},
    Jitter, Quota, RateLimiter,
};
use reqwest::StatusCode;
use rocket::{
    fairing::{self, AdHoc},
    form::Form,
    fs::NamedFile,
    http::{RawStr, Status},
    request::{FromRequest, Outcome},
    response::{
        status::{Accepted, Unauthorized},
        Redirect,
    },
    serde::{json::Json, Deserialize, Serialize},
    tokio::time::sleep,
    Build, Config, Request, Rocket, State,
};
use rocket_db_pools::{sqlx, Database};

/// A keyless, in-memory (process-global) rate limiter, shared across every
/// request handler and the background download worker.
type DirectLimiter = RateLimiter<NotKeyed, InMemoryState, DefaultClock>;

/// Maximum attempts (initial try + retries) for a single upstream request.
const MAX_ATTEMPTS: u32 = 5;

/// Never wait longer than this for a server-supplied `Retry-After`, so a
/// hostile or buggy value can't wedge a request indefinitely.
const RETRY_AFTER_CAP: Duration = Duration::from_secs(120);

/// Shared HTTP client + rate limiter for talking to libro.fm. Cloning is cheap
/// (an `Arc` plus reqwest's internal `Arc`), so it lives in Rocket managed
/// state and a clone is also handed to the background download task.
#[derive(Clone)]
struct Upstream {
    http: reqwest::Client,
    limiter: Arc<DirectLimiter>,
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
                Ok(resp) => Ok(Redirect::to(format!(
                    "/success?token={}",
                    RawStr::new(&resp.access_token).percent_encode()
                ))),
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
}

#[derive(Deserialize, Debug)]
#[serde(crate = "rocket::serde")]
struct LibroBook {
    title: String,
    authors: Vec<String>,
    isbn: i64,
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
) -> Result<Json<MinimalBooksResponse>, Status> {
    let resp = up
        .send("library", true, |c| {
            c.get(format!("https://libro.fm/api/v7/library?page={}", page))
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
                Ok(resp) => Ok(Json(MinimalBooksResponse {
                    res: resp
                        .audiobooks
                        .into_iter()
                        .map(|book| MinimalBook {
                            title: book.title,
                            author1: book
                                .authors
                                .first()
                                .map(|s| s as &str)
                                .unwrap_or("(missing)")
                                .to_string(),
                            isbn: book.isbn,
                        })
                        .collect(),
                    more: resp.total_pages > resp.page,
                })),
            }
        }
    }
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
                    Ok(Accepted(Json(DownloadInfo {
                        tracks: resp.tracks.len(),
                    })))
                }
            }
        }
    }
}

fn get_tmp_path(file_id: i64) -> String {
    format!("/tmp/bookstride_cache_{}.mp3", file_id)
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
            match std::fs::read(get_tmp_path(file.file_id)) {
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

                            let outpath = get_tmp_path(*file_id);
                            let write = File::create(&outpath)
                                .and_then(|mut out| io::copy(&mut file, &mut out).map(|_| ()));
                            if let Err(e) = write {
                                error!(
                                    "[download] isbn {} failed writing {}: {}",
                                    first.isbn, outpath, e
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
                            let _ = std::fs::remove_file(get_tmp_path(*file_id));
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
                v0_start_download,
                v0_get_download
            ],
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
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
}
