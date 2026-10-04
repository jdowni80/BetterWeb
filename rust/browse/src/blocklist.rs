//! Ad / tracker blocking for subresource loads.
//!
//! Built-in domain list plus an optional hosts-format file
//! (`BETTERWEB_BLOCKLIST`, or `<profile>/blocklist.txt`). Matching is by
//! registrable-suffix: blocking `doubleclick.net` also blocks
//! `stats.g.doubleclick.net`. Main-frame navigations are never blocked.

use std::{collections::HashSet, path::Path};

const BUILTIN: &[&str] = &[
    // Google ads / analytics
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "google-analytics.com",
    "googletagmanager.com",
    "googletagservices.com",
    "adservice.google.com",
    "imasdk.googleapis.com",
    "pagead2.googlesyndication.com",
    // Meta / social trackers
    "connect.facebook.net",
    "pixel.facebook.com",
    "ads.linkedin.com",
    "px.ads.linkedin.com",
    "analytics.tiktok.com",
    "ads-twitter.com",
    "ads-api.twitter.com",
    "analytics.twitter.com",
    "bat.bing.com",
    "clarity.ms",
    "pinterest-ads.com",
    "ct.pinterest.com",
    "sc-static.net",
    "tr.snapchat.com",
    // Ad exchanges / SSPs / DSPs
    "adnxs.com",
    "amazon-adsystem.com",
    "rubiconproject.com",
    "pubmatic.com",
    "openx.net",
    "casalemedia.com",
    "criteo.com",
    "criteo.net",
    "adsrvr.org",
    "bidswitch.net",
    "3lift.com",
    "sharethrough.com",
    "teads.tv",
    "yieldmo.com",
    "smartadserver.com",
    "adform.net",
    "media.net",
    "contextweb.com",
    "indexww.com",
    "advertising.com",
    "adroll.com",
    "quantcount.com",
    "lijit.com",
    "sovrn.com",
    "gumgum.com",
    "33across.com",
    "spotxchange.com",
    "springserve.com",
    "zemanta.com",
    // Content-recommendation ad networks
    "taboola.com",
    "outbrain.com",
    "mgid.com",
    "revcontent.com",
    // Verification / measurement
    "moatads.com",
    "doubleverify.com",
    "adsafeprotected.com",
    "scorecardresearch.com",
    "quantserve.com",
    "imrworldwide.com",
    "chartbeat.com",
    "chartbeat.net",
    // Data brokers / identity graphs
    "demdex.net",
    "omtrdc.net",
    "everesttech.net",
    "krxd.net",
    "bluekai.com",
    "exelator.com",
    "rlcdn.com",
    "agkn.com",
    "crwdcntrl.net",
    "id5-sync.com",
    "liadm.com",
    "tapad.com",
    // Product analytics / session replay
    "hotjar.com",
    "hotjar.io",
    "fullstory.com",
    "mouseflow.com",
    "crazyegg.com",
    "luckyorange.com",
    "mixpanel.com",
    "amplitude.com",
    "heap.io",
    "heapanalytics.com",
    "segment.io",
    "cdn.segment.com",
    "api.segment.io",
    "nr-data.net",
    "branch.io",
    "app-measurement.com",
    "braze.com",
    "kissmetrics.com",
    "optimizely.com",
    // Consent-wall / fingerprinting vendors
    "fingerprintjs.com",
    "fpjs.io",
];

pub struct Blocklist {
    domains: HashSet<String>,
}

impl Blocklist {
    pub fn load(profile_dir: Option<&Path>) -> Self {
        let mut domains: HashSet<String> = BUILTIN.iter().map(|d| d.to_string()).collect();
        let extra = std::env::var_os("BETTERWEB_BLOCKLIST")
            .map(std::path::PathBuf::from)
            .or_else(|| profile_dir.map(|p| p.join("blocklist.txt")));
        if let Some(path) = extra {
            if let Ok(text) = std::fs::read_to_string(&path) {
                let before = domains.len();
                for line in text.lines() {
                    if let Some(host) = parse_hosts_line(line) {
                        domains.insert(host);
                    }
                }
                tracing::info!(
                    "blocklist: {} extra domains from {}",
                    domains.len() - before,
                    path.display()
                );
            }
        }
        Self { domains }
    }

    pub fn is_blocked(&self, host: &str) -> bool {
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        let mut candidate = host.as_str();
        loop {
            if self.domains.contains(candidate) {
                return true;
            }
            match candidate.find('.') {
                Some(i) if candidate[i + 1..].contains('.') => candidate = &candidate[i + 1..],
                _ => return false,
            }
        }
    }
}

/// Accepts `0.0.0.0 host`, `127.0.0.1 host`, bare `host`, and `||host^` lines.
fn parse_hosts_line(line: &str) -> Option<String> {
    let line = line.split('#').next()?.trim();
    if line.is_empty() || line.starts_with('!') {
        return None;
    }
    let token = if let Some(rest) = line.strip_prefix("||") {
        rest.trim_end_matches('^').to_string()
    } else {
        let mut parts = line.split_whitespace();
        let first = parts.next()?;
        match parts.next() {
            Some(host) if first.parse::<std::net::IpAddr>().is_ok() => host.to_string(),
            Some(_) => return None,
            None => first.to_string(),
        }
    };
    let token = token.to_ascii_lowercase();
    if token.contains('/') || token.contains('*') || !token.contains('.') || token == "localhost" {
        return None;
    }
    Some(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_matching() {
        let b = Blocklist::load(None);
        assert!(b.is_blocked("stats.g.doubleclick.net"));
        assert!(b.is_blocked("doubleclick.net"));
        assert!(!b.is_blocked("example.com"));
        assert!(!b.is_blocked("net"));
        assert!(!b.is_blocked("notdoubleclick.net"));
    }

    #[test]
    fn hosts_lines() {
        assert_eq!(parse_hosts_line("0.0.0.0 ads.example.com"), Some("ads.example.com".into()));
        assert_eq!(parse_hosts_line("||tracker.io^"), Some("tracker.io".into()));
        assert_eq!(parse_hosts_line("# comment"), None);
        assert_eq!(parse_hosts_line("127.0.0.1 localhost"), None);
    }
}
