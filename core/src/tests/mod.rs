//! Test suite for `lyrebird_core`.
//!
//! Split by domain so concurrent PRs append to a focused file instead
//! of colliding on a single multi-thousand-line EOF. Shared imports and
//! fixtures live here and reach each submodule via `use super::*`.

mod client;
mod discovery;
mod downloads;
mod errors_enums;
mod favorites;
mod library;
mod persistence;
mod playback;
mod playlists;
mod scrobble;
mod search;
mod session_auth;

pub(crate) use crate::client::JellyfinClient;
pub(crate) use crate::enums::ImageType;
pub(crate) use crate::error::LyrebirdError;
pub(crate) use crate::models::Paging;
pub(crate) use crate::player::RepeatMode;
pub(crate) use crate::storage::{CredentialStore, Database};
pub(crate) use crate::{CoreConfig, LyrebirdCore};
pub(crate) use serde_json::json;
pub(crate) use std::sync::Once;
pub(crate) use wiremock::matchers::{method, path, query_param};
pub(crate) use wiremock::{Mock, MockServer, Request, ResponseTemplate};

fn mock_client(base: &str) -> JellyfinClient {
    JellyfinClient::new(base, "test-device".into(), "Test Device".into()).unwrap()
}

/// Placeholder credentials for wiremock-backed tests. These are not real
/// secrets — the mock server accepts any value and returns a canned
/// `AccessToken` regardless.
fn test_credentials() -> (&'static str, &'static str) {
    ("mock-user", "mock-secret-for-wiremock")
}

/// Register a process-wide in-memory credential store as `keyring`'s default
/// the first time a test touches the credential layer. Without this, on macOS
/// the crate's `apple-native` feature would route every test into the real
/// user keychain — which both pollutes the login keychain across runs and
/// would flake in a headless CI environment.
///
/// `keyring`'s built-in `mock` builder hands out a brand-new `MockCredential`
/// on every `Entry::new`, so it can't round-trip `save → load` across two
/// `Entry` instances (which is exactly what `CredentialStore::save_token`
/// followed by `CredentialStore::load_token` does). Our shim keeps one
/// `HashMap` keyed on `(service, user)` so saves are visible to subsequent
/// loads, which is the behaviour we need to exercise `resume_session`.
///
/// Tests still need to pick distinct `(server_id, username)` pairs — the
/// harness intentionally does NOT clear the map between tests because tearing
/// it down is racy under `cargo test`'s default parallelism.
/// Username substring that makes the mock keyring's `set_secret` fail
/// deterministically (see `SharedMockCredential::set_secret`). Used by
/// `login_keyring_write_is_not_silenced` to exercise the `KeyringWrite` error
/// path without a process-global flag that would race parallel logins.
const KEYRING_FAIL_SENTINEL: &str = "KEYRING_FAIL_SENTINEL";

fn install_mock_keyring() {
    use keyring::credential::{
        Credential, CredentialApi, CredentialBuilder, CredentialBuilderApi, CredentialPersistence,
    };
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};

    type Store = Arc<Mutex<HashMap<(String, String), Vec<u8>>>>;

    fn store() -> Store {
        static STORE: OnceLock<Store> = OnceLock::new();
        STORE
            .get_or_init(|| Arc::new(Mutex::new(HashMap::new())))
            .clone()
    }

    struct SharedMockCredential {
        service: String,
        user: String,
        store: Store,
    }

    impl CredentialApi for SharedMockCredential {
        fn set_secret(&self, password: &[u8]) -> keyring::Result<()> {
            // Deterministic failure injection for the keyring-write-not-silenced
            // test: any entry whose key contains this sentinel fails the write,
            // without a process-global flag that would race parallel logins.
            // Only the test that logs in as a `KEYRING_FAIL_SENTINEL` user trips
            // it.
            if self.user.contains(KEYRING_FAIL_SENTINEL) {
                return Err(keyring::Error::Invalid(
                    "set_secret".into(),
                    "injected keyring write failure".into(),
                ));
            }
            self.store
                .lock()
                .unwrap()
                .insert((self.service.clone(), self.user.clone()), password.to_vec());
            Ok(())
        }

        fn get_secret(&self) -> keyring::Result<Vec<u8>> {
            self.store
                .lock()
                .unwrap()
                .get(&(self.service.clone(), self.user.clone()))
                .cloned()
                .ok_or(keyring::Error::NoEntry)
        }

        fn delete_credential(&self) -> keyring::Result<()> {
            self.store
                .lock()
                .unwrap()
                .remove(&(self.service.clone(), self.user.clone()))
                .map(|_| ())
                .ok_or(keyring::Error::NoEntry)
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }
    }

    struct SharedMockBuilder;

    impl CredentialBuilderApi for SharedMockBuilder {
        fn build(
            &self,
            _target: Option<&str>,
            service: &str,
            user: &str,
        ) -> keyring::Result<Box<Credential>> {
            Ok(Box::new(SharedMockCredential {
                service: service.to_string(),
                user: user.to_string(),
                store: store(),
            }))
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }

        fn persistence(&self) -> CredentialPersistence {
            CredentialPersistence::ProcessOnly
        }
    }

    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let builder: Box<CredentialBuilder> = Box::new(SharedMockBuilder);
        keyring::set_default_credential_builder(builder);
    });
}

/// Serialize the handful of tests that touch the *single, fixed* scrobble
/// keyring entry (`scrobble/listenbrainz`). Unlike the per-`(server,user)`
/// Jellyfin token entries, every scrobble test shares one key, so they'd race
/// on the shared mock store under `cargo test`'s parallelism. Hold this guard
/// for the duration of any scrobble-keyring test. Poisoning is ignored so one
/// failing test doesn't cascade.
fn scrobble_keyring_guard() -> std::sync::MutexGuard<'static, ()> {
    use std::sync::{Mutex, OnceLock};
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

// NOTE: `play_history_counts` was removed alongside `record_play` /
// `play_count` / the `play_history` table in the audit pass — local play
// history was write-only dead storage (the server owns PlayCount via
// /Sessions/Playing*). See storage.rs and lib.rs `mark_track_started`.

// ---------------------------------------------------------------------------
// Session auto-restore (resume_session / login persistence)
// ---------------------------------------------------------------------------

/// Build a temp-backed `LyrebirdCore` so each test gets its own `lyrebird.db`
/// without colliding with other tests or leaking into the user's real data
/// directory.
fn resume_test_core(tmp: &tempfile::TempDir) -> std::sync::Arc<LyrebirdCore> {
    install_mock_keyring();
    LyrebirdCore::new(CoreConfig {
        data_dir: tmp.path().to_string_lossy().into_owned(),
        device_name: "Test".into(),
    })
    .expect("core init")
}
