use thiserror::Error;

/// Canonical error type for the Jellify core. Structured so callers can
/// match on the concrete failure class without parsing error messages.
///
/// The coarse `Server { status, message }` that preceded this rework has
/// been split by HTTP status so Swift / Rust callers can act on meaningful
/// subclasses:
///
/// - [`Self::Auth`] — 401 from the server (bad / expired credentials).
/// - [`Self::Forbidden`] — 403 (user lacks permission for the item).
/// - [`Self::NotFound`] — 404 (item / user view does not exist).
/// - [`Self::RateLimit`] — 429 with an optional `Retry-After` hint.
/// - [`Self::Network`] — transport-level failure (DNS, TLS, timeout).
/// - [`Self::Server`] — any other HTTP failure (5xx or unclassified 4xx).
///
/// [`Self::is_retryable`] is the single source of truth for "should I
/// exponentially back off and try again?"; it returns `true` for 5xx
/// `Server`, `RateLimit`, and `Network`.
#[derive(Debug, Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum JellifyError {
    #[error("network error: {0}")]
    Network(String),

    /// The server presented a TLS certificate that could not be verified (e.g.
    /// self-signed or issued by an unknown CA). Separated from the generic
    /// [`JellifyError::Network`] variant so the UI can offer a "Trust this
    /// server" action instead of a generic error message.
    #[error("the server at '{host}' uses a certificate that could not be verified — it may be self-signed")]
    SelfSignedCertificate { host: String },

    #[error("authentication failed: {0}")]
    Auth(String),

    #[error("forbidden: {0}")]
    Forbidden(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("rate limited (retry after {retry_after:?}s)")]
    RateLimit { retry_after: Option<u64> },

    #[error("server returned an error: {status} {body}")]
    Server { status: u16, body: String },

    #[error("not logged in")]
    NotAuthenticated,

    #[error("no active session — call login or restore first")]
    NoSession,

    /// The current access token was rejected by the server (`401`) and a
    /// silent re-read from the keyring did not surface a fresh one. Surfaced
    /// so the UI can prompt the user to re-authenticate — see
    /// [`crate::JellifyCore::forget_token`] for the pre-fill affordance.
    #[error("authentication expired — please sign in again")]
    AuthExpired,

    #[error("decode error: {0}")]
    Decode(String),

    #[error("storage error: {0}")]
    Storage(String),

    #[error("credential store error: {0}")]
    Credentials(String),

    /// The OS keyring rejected a token write. Surfaced (rather than silenced)
    /// so the UI can warn the user that credentials will not survive a restart.
    #[error("keyring write failed: {reason}")]
    KeyringWrite { reason: String },

    #[error("audio error: {0}")]
    Audio(String),

    #[error("invalid input: {0}")]
    InvalidInput(String),

    #[error("queue index {index} is out of bounds (queue length: {len})")]
    InvalidIndex { index: usize, len: usize },

    /// Credentials were blank (or whitespace-only) after trimming.
    #[error("invalid credentials: username and password must not be empty")]
    InvalidCredentials,

    #[error("{0}")]
    Other(String),
}

impl JellifyError {
    /// Returns a human-readable, action-oriented message suitable for
    /// displaying directly to the user in the UI.  Unlike the `Display`
    /// implementation (which is verbose and intended for logs), this method
    /// never surfaces HTTP status codes, error prefixes, or internal details.
    ///
    /// `JellifyError` is declared `#[uniffi(flat_error)]` so UniFFI treats it
    /// as an opaque thrown-error type and cannot export methods on it directly.
    /// The Swift layer ([`JellifyErrorPresenter`]) currently mirrors this
    /// mapping by substring-matching the `Display` string; a follow-up PR can
    /// replace that with a proper call once the bindings layer adds support for
    /// error-type method dispatch.
    ///
    /// # Examples
    /// ```
    /// use jellify_core::JellifyError;
    /// let e = JellifyError::Auth("token expired".into());
    /// assert_eq!(e.user_message(), "Your session expired. Please sign in again.");
    /// ```
    pub fn user_message(&self) -> String {
        match self {
            // Authentication failures — user needs to re-login.
            JellifyError::Auth(_)
            | JellifyError::AuthExpired
            | JellifyError::NotAuthenticated
            | JellifyError::NoSession
            | JellifyError::InvalidCredentials => {
                "Your session expired. Please sign in again.".to_string()
            }

            // Permission denied — the user's account lacks access.
            JellifyError::Forbidden(_) => {
                "You don't have permission to access that.".to_string()
            }

            // Resource missing.
            JellifyError::NotFound(_) => {
                "We couldn't find what you were looking for.".to_string()
            }

            // Transport-level failures — connectivity problem.
            JellifyError::Network(_) => {
                "Couldn't reach the server. Check your connection and try again.".to_string()
            }

            // TLS / certificate issues — connectivity problem with extra context.
            JellifyError::SelfSignedCertificate { .. } => {
                "Couldn't reach the server. Check your connection and try again.".to_string()
            }

            // Rate-limiting — tell the user to wait.
            JellifyError::RateLimit { .. } => {
                "The server is busy. Please wait a moment and try again.".to_string()
            }

            // Server-side errors: 5xx get a generic "try again" message.
            JellifyError::Server { status, .. } if (500..600).contains(status) => {
                "The server ran into an error. Please try again.".to_string()
            }

            // Other server-side HTTP errors (4xx not already caught above).
            JellifyError::Server { .. } => {
                "The server didn't understand the request. Please report this if it keeps happening.".to_string()
            }

            // Credential store failures — OS Keychain issue.
            JellifyError::Credentials(_) | JellifyError::KeyringWrite { .. } => {
                "We couldn't save your credentials. You may need to sign in again after restarting.".to_string()
            }

            // Audio / playback failures.
            JellifyError::Audio(_) => {
                "Playback failed. The track may be in an unsupported format.".to_string()
            }

            // Invalid queue index — shouldn't surface to users under normal
            // operation, but map to a safe fallback.
            JellifyError::InvalidIndex { .. } | JellifyError::InvalidInput(_) => {
                "Something went wrong. Please try again.".to_string()
            }

            // Decode / storage are internal failures.
            JellifyError::Decode(_) | JellifyError::Storage(_) => {
                "Something went wrong. Please try again.".to_string()
            }

            // Catch-all.
            JellifyError::Other(_) => "Something went wrong. Please try again.".to_string(),
        }
    }

    /// Should the caller retry the request after an exponential backoff?
    ///
    /// Returns `true` for:
    /// - [`Self::RateLimit`] — the server asked us to slow down; the
    ///   `retry_after` (when set) is an upper bound on the wait.
    /// - [`Self::Server`] with a 5xx status — transient server-side issue.
    /// - [`Self::Network`] — transport fault (DNS, TLS, timeout); usually
    ///   resolves on its own.
    ///
    /// Returns `false` for `Auth`, `Forbidden`, `NotFound`, `Decode`,
    /// `InvalidInput`, `NotAuthenticated`, `NoSession`, `Storage`,
    /// `Credentials`, `Audio`, `Other` — those need user or code action, not
    /// a retry.
    pub fn is_retryable(&self) -> bool {
        match self {
            JellifyError::RateLimit { .. } => true,
            JellifyError::Network(_) => true,
            JellifyError::Server { status, .. } => (500..600).contains(status),
            _ => false,
        }
    }

    /// Build a JellifyError from an HTTP response's status code, body text,
    /// and optional `Retry-After` header. Dispatches to the narrowest
    /// variant that matches the status:
    ///
    /// - 401 → [`Self::Auth`]
    /// - 403 → [`Self::Forbidden`]
    /// - 404 → [`Self::NotFound`]
    /// - 429 → [`Self::RateLimit`]
    /// - else → [`Self::Server`]
    pub fn from_status(status: u16, body: String, retry_after: Option<u64>) -> Self {
        match status {
            401 => JellifyError::Auth(body),
            403 => JellifyError::Forbidden(body),
            404 => JellifyError::NotFound(body),
            429 => JellifyError::RateLimit { retry_after },
            _ => JellifyError::Server { status, body },
        }
    }
}

impl From<reqwest::Error> for JellifyError {
    fn from(e: reqwest::Error) -> Self {
        // Walk the error source chain looking for a rustls certificate-
        // validation failure. rustls 0.23 renders these as
        // "invalid peer certificate: …" in its `Display` impl.  We detect
        // the pattern here rather than taking a direct `rustls` dependency
        // so that the detection stays in sync with whatever rustls version
        // reqwest pulls in transitively.
        if is_cert_error(&e) {
            let host = e
                .url()
                .and_then(|u| u.host_str().map(str::to_string))
                .unwrap_or_else(|| "unknown".to_string());
            return JellifyError::SelfSignedCertificate { host };
        }
        JellifyError::Network(e.to_string())
    }
}

/// Returns `true` when the error chain contains a TLS certificate-validation
/// failure.  Compatible with both rustls 0.22 and 0.23.
pub(crate) fn is_cert_error(e: &reqwest::Error) -> bool {
    use std::error::Error as StdError;
    let mut source: Option<&(dyn StdError + 'static)> = Some(e);
    while let Some(err) = source {
        let msg = err.to_string();
        // rustls 0.23: "invalid peer certificate: …"
        // older rustls / webpki: "invalid certificate: …"
        if msg.contains("invalid peer certificate")
            || msg.contains("invalid certificate")
            || msg.contains("certificate verify failed")
            || msg.contains("UnknownIssuer")
            || msg.contains("self-signed certificate")
        {
            return true;
        }
        source = err.source();
    }
    false
}

impl From<serde_json::Error> for JellifyError {
    fn from(e: serde_json::Error) -> Self {
        JellifyError::Decode(e.to_string())
    }
}

impl From<rusqlite::Error> for JellifyError {
    fn from(e: rusqlite::Error) -> Self {
        JellifyError::Storage(e.to_string())
    }
}

impl From<keyring::Error> for JellifyError {
    fn from(e: keyring::Error) -> Self {
        JellifyError::Credentials(e.to_string())
    }
}

impl From<url::ParseError> for JellifyError {
    fn from(e: url::ParseError) -> Self {
        JellifyError::InvalidInput(format!("invalid url: {e}"))
    }
}

pub type Result<T, E = JellifyError> = std::result::Result<T, E>;
