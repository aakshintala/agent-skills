use crate::backends::types::BackendResult;
use crate::types::{RUN_STATUSES, RunOutput, RunStatus};

pub fn derive_status(text: &str, raw_is_error: Option<bool>, clean_exit: bool) -> RunStatus {
    let lines: Vec<&str> = text
        .split('\n')
        .filter(|line| !line.trim().is_empty())
        .collect();
    let last = lines.last().copied().unwrap_or("");
    // JS split('\n') keeps `\r` on CRLF lines; match that, then the regex.
    let last = last.trim_end_matches('\r');
    if let Some(caps) = status_line(last)
        && RUN_STATUSES.contains(&caps)
        && let Some(s) = RunStatus::parse(caps)
    {
        return s;
    }
    if raw_is_error == Some(false) && clean_exit {
        return RunStatus::Done;
    }
    RunStatus::Error
}

fn is_decoration(c: char) -> bool {
    matches!(c, '*' | '`')
}

// The status token must end the line, whether it starts the line or follows
// prose on it (#247). Trailing whitespace and markdown decoration around the
// token are not part of it; a STATUS word with more text after it is ignored.
fn status_line(last: &str) -> Option<&str> {
    const KEY: &str = "STATUS:";
    let line = last.trim_end_matches(|c: char| c.is_whitespace() || is_decoration(c));
    let at = line.rfind(KEY)?;
    let before = &line[..at];
    if !before.is_empty() && !before.ends_with(|c: char| c.is_whitespace() || is_decoration(c)) {
        return None;
    }
    let token =
        line[at + KEY.len()..].trim_matches(|c: char| c == ' ' || c == '\t' || is_decoration(c));
    if !token.is_empty() && token.chars().all(|c| c.is_ascii_uppercase() || c == '_') {
        Some(token)
    } else {
        None
    }
}

pub fn to_run_output(
    res: &BackendResult,
    model: &str,
    backend: &str,
    cost_usd: Option<f64>,
    cost_estimated: bool,
) -> RunOutput {
    RunOutput {
        status: derive_status(&res.text, res.is_error, res.clean_exit),
        text: res.text.clone(),
        session_id: res.session_id.clone(),
        backend: backend.to_string(),
        model: model.to_string(),
        usage: res.usage.clone(),
        cost_usd,
        cost_estimated,
        duration_ms: res.duration_ms,
        job_id: None,
        stderr_tail: None,
        gate_result: None,
        change_set: None,
        concerns: None,
        permission_denials: res.permission_denials.clone(),
        retries: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backends::types::BackendResult;
    use crate::types::Retry;

    #[test]
    fn retries_serialize_camel_case_and_an_empty_list_is_omitted() {
        let res = BackendResult {
            text: "ok".into(),
            ..Default::default()
        };
        let mut out = to_run_output(&res, "m", "pi", None, true);
        assert!(serde_json::to_value(&out).unwrap().get("retries").is_none());
        out.retries.push(Retry {
            attempt: 1,
            provider_status: 503,
            error: "opencode-go API error (503): {\"error\":\"upstream unavailable\"}".into(),
            delay_ms: 10000,
            session_id: "a86b4f04-f9fe-4fe2-88f2-9c07c39dda68".into(),
        });
        let want: serde_json::Value = serde_json::from_str(
            r#"[{"attempt":1,"providerStatus":503,"error":"opencode-go API error (503): {\"error\":\"upstream unavailable\"}","delayMs":10000,"sessionId":"a86b4f04-f9fe-4fe2-88f2-9c07c39dda68"}]"#,
        )
        .unwrap();
        assert_eq!(serde_json::to_value(&out).unwrap()["retries"], want);
    }

    #[test]
    fn explicit_trailing_status_wins() {
        assert_eq!(
            derive_status("work\nSTATUS: BLOCKED", Some(false), true),
            RunStatus::Blocked
        );
        assert_eq!(
            derive_status("STATUS: NEEDS_CONTEXT\n", Some(false), true),
            RunStatus::NeedsContext
        );
    }

    #[test]
    fn only_final_status_line_wins() {
        assert_eq!(
            derive_status(
                "STATUS: NEEDS_CONTEXT\nmore work\nSTATUS: DONE",
                Some(false),
                true
            ),
            RunStatus::Done
        );
        assert_eq!(
            derive_status(
                "mentioned STATUS: NEEDS_CONTEXT in prose\nall good",
                Some(false),
                true
            ),
            RunStatus::Done
        );
    }

    #[test]
    fn inline_trailing_status_counts() {
        // see #247: the status shares its line with the sentence before it.
        assert_eq!(
            derive_status(
                "... and I did not commit. STATUS: BLOCKED",
                Some(false),
                true
            ),
            RunStatus::Blocked
        );
        assert_eq!(
            derive_status(
                "no new order test was needed. STATUS: DONE_WITH_CONCERNS",
                Some(false),
                true
            ),
            RunStatus::DoneWithConcerns
        );
    }

    #[test]
    fn decorated_inline_status_counts() {
        // see #247: markdown decoration and trailing whitespace around the token.
        assert_eq!(
            derive_status("done. **STATUS: DONE_WITH_CONCERNS**  ", Some(false), true),
            RunStatus::DoneWithConcerns
        );
        assert_eq!(
            derive_status("gave up. `STATUS: BLOCKED`\n", Some(false), true),
            RunStatus::Blocked
        );
        assert_eq!(
            derive_status("gave up. **STATUS:** BLOCKED", Some(false), true),
            RunStatus::Blocked
        );
    }

    #[test]
    fn mid_text_status_is_ignored() {
        // see #247: a STATUS word with more text after it does not end the text.
        assert_eq!(
            derive_status(
                "I will report STATUS: NEEDS_CONTEXT if it comes up, all done",
                Some(false),
                true
            ),
            RunStatus::Done
        );
        assert_eq!(
            derive_status(
                "work. STATUS: BLOCKED was my earlier guess. Final: fine",
                Some(false),
                true
            ),
            RunStatus::Done
        );
    }

    #[test]
    fn unknown_status_token_falls_through() {
        assert_eq!(
            derive_status("STATUS: WHATEVER", Some(false), true),
            RunStatus::Done
        );
    }

    #[test]
    fn clean_exit_no_error_is_done() {
        assert_eq!(derive_status("done", Some(false), true), RunStatus::Done);
    }

    #[test]
    fn error_or_non_clean_is_error() {
        assert_eq!(derive_status("oops", Some(true), true), RunStatus::Error);
        assert_eq!(derive_status("oops", Some(false), false), RunStatus::Error);
    }

    #[test]
    fn precedence_table() {
        for s in [
            "DONE",
            "DONE_WITH_CONCERNS",
            "BLOCKED",
            "NEEDS_CONTEXT",
            "ERROR",
        ] {
            assert_eq!(
                derive_status(&format!("work\nSTATUS: {s}"), Some(true), false).as_str(),
                s
            );
        }
    }

    #[test]
    fn explicit_status_wins_even_when_is_error() {
        assert_eq!(
            derive_status("partial\nSTATUS: DONE", Some(true), true),
            RunStatus::Done
        );
    }

    #[test]
    fn trailing_blank_and_crlf() {
        assert_eq!(
            derive_status("work\nSTATUS: BLOCKED\n\n  \n", Some(false), true),
            RunStatus::Blocked
        );
        assert_eq!(
            derive_status("work\r\nSTATUS: DONE\r\n", Some(false), true),
            RunStatus::Done
        );
    }

    #[test]
    fn registry_only_statuses_never_come_from_the_agent() {
        // CANCELLED/STALLED are set by the registry, never claimed by an agent line:
        // `RUN_STATUSES` gates `parse`, so these fall through to the exit-based default.
        assert_eq!(
            derive_status("work\nSTATUS: CANCELLED", Some(false), true),
            RunStatus::Done
        );
        assert_eq!(
            derive_status("work\nSTATUS: STALLED", Some(false), true),
            RunStatus::Done
        );
        assert!(RunStatus::parse("CANCELLED").is_none());
        assert!(RunStatus::parse("STALLED").is_none());
    }

    #[test]
    fn empty_text_falls_through() {
        assert_eq!(derive_status("", Some(false), true), RunStatus::Done);
        assert_eq!(derive_status("   \n  ", Some(false), true), RunStatus::Done);
        assert_eq!(derive_status("", Some(true), false), RunStatus::Error);
    }

    #[test]
    fn to_run_output_maps_raw() {
        let res = BackendResult {
            text: "hi\nSTATUS: DONE".into(),
            session_id: Some("s1".into()),
            duration_ms: Some(1234.0),
            clean_exit: true,
            stderr: String::new(),
            ..Default::default()
        };
        let out = to_run_output(&res, "composer-2.5", "cursor", None, true);
        assert_eq!(out.status, RunStatus::Done);
        assert_eq!(out.text, "hi\nSTATUS: DONE");
        assert_eq!(out.session_id.as_deref(), Some("s1"));
        assert_eq!(out.duration_ms, Some(1234.0));
        assert!(out.cost_estimated);
        assert_eq!(out.backend, "cursor");
    }
}
