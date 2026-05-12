use anyhow::{anyhow, Result};
use lyrebird_core::{CoreConfig, LyrebirdCore};
use std::io::{self, Write};

fn prompt(msg: &str) -> Result<String> {
    print!("{msg}");
    io::stdout().flush()?;
    let mut buf = String::new();
    io::stdin().read_line(&mut buf)?;
    Ok(buf.trim().to_string())
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let core = LyrebirdCore::new(CoreConfig {
        data_dir: String::new(),
        device_name: "Lyrebird CLI".to_string(),
    })
    .map_err(|e| anyhow!("core init: {e}"))?;

    let server_url = std::env::var("JELLYFIN_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .map(Ok)
        .unwrap_or_else(|| prompt("Jellyfin server URL: "))?;

    let info = core
        .probe_server(server_url.clone())
        .map_err(|e| anyhow!("probe: {e}"))?;
    println!(
        "Connected to {} (version {})",
        info.name,
        info.version.as_deref().unwrap_or("?")
    );

    let username = std::env::var("JELLYFIN_USER")
        .ok()
        .filter(|s| !s.is_empty())
        .map(Ok)
        .unwrap_or_else(|| prompt("Username: "))?;
    let password = std::env::var("JELLYFIN_PASS")
        .ok()
        .filter(|s| !s.is_empty())
        .map(Ok)
        .unwrap_or_else(|| prompt("Password: "))?;

    let session = core
        .login(server_url, username, password)
        .map_err(|e| anyhow!("login: {e}"))?;
    println!("Logged in as {}", session.user.name);

    let page = core
        .list_albums(0, 20)
        .map_err(|e| anyhow!("list albums: {e}"))?;
    let albums = page.items;
    println!("\nAlbums ({} of {}):", albums.len(), page.total_count);
    for (i, a) in albums.iter().enumerate() {
        println!(
            "  [{}] {} — {} ({})",
            i,
            a.name,
            a.artist_name,
            a.year.map(|y| y.to_string()).unwrap_or_default()
        );
    }

    if albums.is_empty() {
        println!("No albums found.");
        return Ok(());
    }

    let choice = prompt("\nAlbum index (Enter for [0]): ")?;
    let idx: usize = if choice.is_empty() {
        0
    } else {
        choice.parse().map_err(|_| anyhow!("invalid index"))?
    };
    let album = albums.get(idx).ok_or_else(|| anyhow!("out of range"))?;

    let tracks = core
        .album_tracks(album.id.clone())
        .map_err(|e| anyhow!("album tracks: {e}"))?;
    println!("\nTracks on {}:", album.name);
    for (i, t) in tracks.iter().enumerate() {
        println!("  {:>2}. {} ({:.0}s)", i + 1, t.name, t.duration_seconds());
    }

    if let Some(first) = tracks.first() {
        let url = core
            .stream_url(first.id.clone(), None, None)
            .map_err(|e| anyhow!("stream_url: {e}"))?;
        println!("\nStream URL for {}:\n  {}", first.name, url);
    }
    Ok(())
}
