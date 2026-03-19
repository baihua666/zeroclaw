use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Email channel configuration.
///
/// Keep the config type available even when the runtime email channel is not
/// compiled in, so config parsing and feature-gated warnings stay consistent.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct EmailConfig {
    /// IMAP server hostname
    pub imap_host: String,
    /// IMAP server port (default: 993 for TLS)
    #[serde(default = "default_imap_port")]
    pub imap_port: u16,
    /// IMAP folder to poll (default: INBOX)
    #[serde(default = "default_imap_folder")]
    pub imap_folder: String,
    /// SMTP server hostname
    pub smtp_host: String,
    /// SMTP server port (default: 465 for TLS)
    #[serde(default = "default_smtp_port")]
    pub smtp_port: u16,
    /// Use TLS for SMTP (default: true)
    #[serde(default = "default_true")]
    pub smtp_tls: bool,
    /// Email username for authentication
    pub username: String,
    /// Email password for authentication
    pub password: String,
    /// From address for outgoing emails
    pub from_address: String,
    /// IDLE timeout in seconds before re-establishing connection (default: 1740 = 29 minutes)
    /// RFC 2177 recommends clients restart IDLE every 29 minutes
    #[serde(default = "default_idle_timeout", alias = "poll_interval_secs")]
    pub idle_timeout_secs: u64,
    /// Allowed sender addresses/domains (empty = deny all, ["*"] = allow all)
    #[serde(default)]
    pub allowed_senders: Vec<String>,
    /// Default subject line for outgoing emails (default: "ZeroClaw Message")
    #[serde(default = "default_subject")]
    pub default_subject: String,
}

impl crate::config::traits::ChannelConfig for EmailConfig {
    fn name() -> &'static str {
        "Email"
    }

    fn desc() -> &'static str {
        "Email over IMAP/SMTP"
    }
}

pub(crate) fn default_imap_port() -> u16 {
    993
}

pub(crate) fn default_smtp_port() -> u16 {
    465
}

pub(crate) fn default_imap_folder() -> String {
    "INBOX".into()
}

pub(crate) fn default_idle_timeout() -> u64 {
    1740 // 29 minutes per RFC 2177
}

pub(crate) fn default_true() -> bool {
    true
}

pub(crate) fn default_subject() -> String {
    "ZeroClaw Message".into()
}

impl Default for EmailConfig {
    fn default() -> Self {
        Self {
            imap_host: String::new(),
            imap_port: default_imap_port(),
            imap_folder: default_imap_folder(),
            smtp_host: String::new(),
            smtp_port: default_smtp_port(),
            smtp_tls: true,
            username: String::new(),
            password: String::new(),
            from_address: String::new(),
            idle_timeout_secs: default_idle_timeout(),
            allowed_senders: Vec::new(),
            default_subject: default_subject(),
        }
    }
}
