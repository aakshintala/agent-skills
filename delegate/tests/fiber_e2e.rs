//! Drives the real `delegate` binary as a process against a fake fiber
//! that replays `tests/fixtures/recorded/fiber/echo.jsonl`.

use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

const MODEL: &str = "fiber/opencode-go/muse-spark-1.3-contributor";
const REFERENCE: &str = "opencode-go/muse-spark-1.3-contributor";

const FAKE_FIBER: &str = r#"#!/bin/sh
# Replays a recorded `fiber ask` stream. Every invocation appends its
# argv, so assertions can read it.
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} >> "$(dirname "$0")/argv.txt"
cat "$DELEGATE_TEST_FIBER_FIXTURE"
exit "$DELEGATE_TEST_FIBER_EXIT"
"#;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str, fixture: &str, exit: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("cdm-fiber-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let agent = dir.join("fiber.sh");
        std::fs::write(&agent, FAKE_FIBER).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.join("fixture"), fixture).unwrap();
        std::fs::write(dir.join("exit"), exit).unwrap();
        Env { dir }
    }

    fn fixture_path(&self, name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(format!("tests/fixtures/recorded/fiber/{name}"))
    }

    /// Every recorded argv line across all invocations.
    fn argv(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("argv.txt"))
            .unwrap()
            .lines()
            .map(String::from)
            .collect()
    }

    fn delegate(&self, args: &[&str], stdin: Option<&str>, fixture: &str, exit: &str) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_delegate"));
        cmd.args(args)
            .current_dir(&self.dir)
            .env("TMPDIR", &self.dir)
            .env("FIBER_BIN", self.dir.join("fiber.sh"))
            .env("DELEGATE_TEST_FIBER_FIXTURE", self.fixture_path(fixture))
            .env("DELEGATE_TEST_FIBER_EXIT", exit)
            .env("DELEGATE_HEARTBEAT_MS", "100")
            .env("DELEGATE_RETRY_DELAYS_MS", "0")
            // Isolate from the developer machine's real host profile.
            .env(
                "DELEGATE_HOST_PROFILE",
                self.dir.join("nonexistent-profile.json"),
            );
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut si = child.stdin.take().unwrap();
        if let Some(s) = stdin {
            let _ = si.write_all(s.as_bytes());
        }
        drop(si);
        child.wait_with_output().unwrap()
    }

    fn run_write(&self, prompt: &str, fixture: &str, exit: &str) -> String {
        let out = self.delegate(&["run", "--model", MODEL], Some(prompt), fixture, exit);
        assert!(
            out.status.success(),
            "exit {:?}\nstderr: {}\nstdout: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn wait_terminal(&self, id: &str, fixture: &str, exit: &str) -> Value {
        let out = self.delegate(&["watch", id, "--timeout", "10"], None, fixture, exit);
        assert_eq!(out.status.code(), Some(0));
        serde_json::from_slice(&out.stdout).unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn fiber_run_finishes_with_fiber_reported_cost() {
    let e = Env::new("run", "echo.jsonl", "0");
    let id = e.run_write("Reply with the word DONE.", "echo.jsonl", "0");
    assert_eq!(id.len(), 36);
    let done = e.wait_terminal(&id, "echo.jsonl", "0");
    assert_eq!(done["status"], "DONE");
    assert_eq!(done["result"]["text"], "DONE");
    assert_eq!(done["result"]["backend"], "fiber");
    assert_eq!(done["result"]["model"], MODEL);
    // Cost is fiber's own reported sum, not a table estimate.
    let cost = done["result"]["costUsd"].as_f64().unwrap();
    assert!((cost - 0.000603378).abs() < 1e-12, "{cost}");
    assert_eq!(done["result"]["costEstimated"], false);

    // Fiber mints the session id; the stream's id is what the record carries.
    assert_eq!(done["resume"]["sessionId"], "s_36e63d22c39750e1");

    let argv = e.argv();
    assert!(argv.contains(&"ask".to_string()), "{argv:?}");
    assert!(
        argv.windows(2).any(|w| w == ["--model", REFERENCE]),
        "{argv:?}"
    );
    // The prompt goes after a `--` separator so a leading `-` never parses as a flag.
    let dash = argv.iter().position(|a| a == "--").expect("separator");
    assert!(
        argv[dash + 1..]
            .iter()
            .any(|a| a.contains("Reply with the word DONE.")),
        "{argv:?}"
    );
    assert!(!argv.iter().any(|a| a == "--resume"), "{argv:?}");
    assert!(!argv.iter().any(|a| a.starts_with("fiber/")), "{argv:?}");
}

#[test]
fn fiber_badmodel_is_an_error() {
    let e = Env::new("badmodel", "badmodel.jsonl", "1");
    let id = e.run_write("anything", "badmodel.jsonl", "1");
    let done = e.wait_terminal(&id, "badmodel.jsonl", "1");
    assert_eq!(done["status"], "ERROR");
    assert_eq!(done["result"]["backend"], "fiber");
    assert_eq!(done["result"]["model"], MODEL);
    let text = done["result"]["text"].as_str().unwrap_or("");
    assert!(text.contains("nope"), "{text}");
}
