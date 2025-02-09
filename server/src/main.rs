#[macro_use]
extern crate rocket;

use std::{
    collections::HashMap,
    fs::File,
    io::{self, Cursor},
    time::{Duration, SystemTime},
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
    Build, Config, Request, Rocket,
};
use rocket_db_pools::{sqlx, Database};

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
async fn auth(auth: Form<Auth<'_>>) -> Result<Redirect, Unauthorized<Option<NamedFile>>> {
    let client = reqwest::Client::new();
    let mut map = HashMap::new();
    map.insert("grant_type", "password");
    map.insert("username", auth.username);
    map.insert("password", auth.password);

    let resp = client
        .post("https://libro.fm/oauth/token")
        .header("User-Agent", "Bookstride <jocelyn@nettek.ca>")
        .json(&map)
        .send()
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
async fn v0_lib(page: usize, auth: AuthHeader) -> Result<Json<MinimalBooksResponse>, Status> {
    let client = reqwest::Client::new();
    let resp = client
        .get(format!("https://libro.fm/api/v7/library?page={}", page))
        .header("Authorization", auth.header)
        .send()
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
) -> Result<Accepted<Json<DownloadInfo>>, Status> {
    let client = reqwest::Client::new();
    let resp = client
        .get(format!(
            "https://libro.fm/api/v10/download-manifest?isbn={}",
            isbn
        ))
        .header("Authorization", &auth.header)
        .send()
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
                    let mut track_ids = sqlx::query!(
                        "SELECT file_id FROM track WHERE isbn = ? AND bearer = ? ORDER BY track",
                        first.isbn,
                        first.bearer,
                    )
                    .fetch_all(&pool)
                    .await
                    .unwrap()
                    .into_iter();

                    for res in &res {
                        if let (Some(path),) = (&res.path,) {
                            let client = reqwest::Client::new();
                            let resp = client.get(path).send().await;
                            match resp {
                                Ok(resp) => {
                                    if resp.status() != StatusCode::OK {
                                        eprintln!("Bad status code {}", resp.status());
                                    } else if let Ok(bytes) = resp.bytes().await {
                                        let seekable = Cursor::new(bytes);
                                        let mut archive = zip::ZipArchive::new(seekable).unwrap();
                                        for i in 0..archive.len() {
                                            let mut file = archive.by_index(i).unwrap();
                                            match file.enclosed_name() {
                                                Some(path) => {
                                                    if !path
                                                        .file_name()
                                                        .and_then(|path| path.to_str())
                                                        .map(|s| s.ends_with(".mp3"))
                                                        .unwrap_or(false)
                                                    {
                                                        continue;
                                                    }
                                                }
                                                None => continue,
                                            };

                                            if file.is_dir() {
                                                eprintln!("Found folder in zip");
                                            } else if let Some(id) = track_ids.next() {
                                                let outpath = get_tmp_path(id.file_id);
                                                let mut outfile = File::create(&outpath).unwrap();
                                                io::copy(&mut file, &mut outfile).unwrap();
                                                eprintln!("Extracted {} {}!", first.isbn, outpath)
                                            } else {
                                                eprintln!(
                                                    "Not enough track ids for {} {}",
                                                    first.isbn, first.bearer
                                                )
                                            }
                                        }
                                        eprintln!("ok");
                                    } else {
                                        eprintln!("Bad bytes");
                                    }
                                }
                                Err(err) => {
                                    eprintln!("err: {:?}", err);
                                }
                            }
                        }
                    }

                    if track_ids.next().is_some() {
                        eprintln!("Extra IDs for {}", first.isbn);
                    }

                    let mut tx = pool.begin().await.unwrap();

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

                    if let Err(e) = tx.commit().await {
                        eprintln!("err: {:?}", e);
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
