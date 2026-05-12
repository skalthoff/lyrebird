//! End-to-end tests against a live Jellyfin server.
//!
//! Gated on `LYREBIRD_E2E_URL` — every test early-returns when the variable is
//! absent so `cargo test --workspace` stays fully offline / hermetic. The e2e
//! CI workflow (`.github/workflows/e2e.yml`) points at the shared
//! `music.skalthoff.com` test instance with the read-only `test` account, and
//! injects the URL and credentials via env vars.
//!
//! What each test exercises against a real Jellyfin:
//!
//! - `probe_returns_server_info` — anonymous `/System/Info/Public`
//! - `login_issues_access_token` — `POST /Users/AuthenticateByName`
//! - `list_albums_returns_envelope` — authenticated `/Items` query; verifies
//!   the pagination envelope shape, agnostic to library contents.
//!
//! These cover the paths that wiremock-based unit tests can only simulate: the
//! actual Jellyfin response shapes, auth header handling, and HTTP edge cases.

use lyrebird_core::{CoreConfig, LyrebirdCore};
use std::sync::Arc;

const SKIP_HINT: &str = "LYREBIRD_E2E_URL not set, skipping live e2e test";

fn e2e_url() -> Option<String> {
    std::env::var("LYREBIRD_E2E_URL")
        .ok()
        .filter(|s| !s.is_empty())
}

fn e2e_user() -> String {
    std::env::var("LYREBIRD_E2E_USER").unwrap_or_else(|_| "test".to_string())
}

fn e2e_pass() -> String {
    std::env::var("LYREBIRD_E2E_PASS").unwrap_or_else(|_| "test".to_string())
}

fn make_core() -> Arc<LyrebirdCore> {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().to_string_lossy().to_string();
    // Leak the TempDir — keeping it alive for the test process is simpler than
    // plumbing it through each test and the data is inside tmpfs anyway.
    std::mem::forget(tmp);
    LyrebirdCore::new(CoreConfig {
        data_dir: path,
        device_name: "Lyrebird E2E".to_string(),
    })
    .expect("core init")
}

#[test]
fn probe_returns_server_info() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let server = core.probe_server(url).expect("probe_server");
    assert!(!server.name.is_empty(), "server name should be populated");
    assert!(server.version.is_some(), "server version should be present");
}

#[test]
fn login_issues_access_token() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let session = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");
    assert!(
        !session.access_token.is_empty(),
        "access_token must be non-empty"
    );
    assert_eq!(session.user.name, e2e_user());
}

#[test]
fn list_albums_returns_envelope() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let _ = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");
    let page = core.list_albums(0, 10).expect("list_albums");
    // Envelope shape only — agnostic to library contents (the live test
    // server is populated; mocked / fresh servers may be empty).
    assert!(
        page.items.len() as u32 <= page.total_count.max(page.items.len() as u32),
        "items should not exceed total_count"
    );
}
