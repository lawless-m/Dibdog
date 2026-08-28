// MCP server exposing the DBISAM DCG as a SQL checker.
//
// Speaks MCP over Streamable HTTP: a single endpoint that accepts a
// JSON-RPC request by POST and answers with a JSON-RPC response. No SSE
// stream is offered because this server never pushes anything to the
// client — every tool call is strictly request/response. That is the
// spec's `application/json` response mode.
//
// The grammar work happens in Scryer, not here: each check writes the
// SQL to a temp file and runs `scryer-prolog check.pl -- <file>` once,
// reading the result record from its stdout.
//
// A one-shot process per check costs ~0.3s where a warm long-lived
// process would cost ~10ms, and that is a deliberate trade. The warm
// design needs a framed protocol over the child's piped stdin, and
// Scryer's piped-stdin behaviour is not stable across versions: commit
// 8dffd72d reads pipes correctly, while main (e3df91e2) returns one
// character and then end_of_file, silently breaking the protocol. See
// mthom/scryer-prolog#1472 for the wider get_char/EOF trouble. Reading
// the SQL from a *file* works identically on both, uses the same
// phrase_from_file path as every other tool in this repo, and cannot be
// broken by a future Scryer upgrade. For an interactive checker, 0.3s is
// not worth a correctness bet that has to be re-won on every install.
//
// Contract — POST / with a JSON-RPC body. Supported methods:
//   initialize, notifications/initialized, ping, tools/list, tools/call
// The one tool is `check_sql`.
//
// Configuration is via env vars:
//   DIBDOG_MCP_BIND      bind address (default 127.0.0.1:8791)
//   DIBDOG_MCP_TOKEN     bearer token, or
//   DIBDOG_MCP_TOKEN_FILE  file to read the bearer token from
//   DIBDOG_CHECK_PL      path to check.pl
//   DIBDOG_SCRYER        scryer-prolog binary (default "scryer-prolog")
//   DIBDOG_MCP_WORKERS   request threads (default 2)
//   DIBDOG_MCP_ALLOWED_ORIGINS  comma-separated Origins to admit
//                        (default none: any request carrying an Origin
//                        header is refused, per the MCP spec's
//                        DNS-rebinding guidance)
//
// The token never appears in repo files. Pass it via the environment or
// a file referenced by DIBDOG_MCP_TOKEN_FILE.

use std::env;
use std::fs;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::thread;
use std::time::Duration;

use serde_json::{Value, json};
use tiny_http::{Header, Method, Request, Response, Server};

/// Longest SQL accepted. The largest real query in the corpus is 2785
/// chars; this leaves generous headroom while bounding the work a single
/// caller can ask for.
const MAX_SQL_CHARS: usize = 8192;

/// How long one check may take before the Scryer process is presumed
/// wedged and killed. Far above a normal check (~0.3s) and above the
/// gated diagnostic's worst case at check.pl's 2000-char limit.
const CHECK_TIMEOUT: Duration = Duration::from_secs(30);

const PROTOCOL_VERSION: &str = "2025-06-18";

static JOB_SEQ: AtomicU64 = AtomicU64::new(0);

// ============================================================
// Running the checker
// ============================================================

struct Checker {
    scryer: String,
    check_pl: String,
    tmp_dir: std::path::PathBuf,
}

impl Checker {
    fn new(scryer: String, check_pl: String) -> Self {
        Checker { scryer, check_pl, tmp_dir: env::temp_dir() }
    }

    fn check(&self, sql: &str) -> Result<Record, String> {
        // Unique per call: several request threads run concurrently, and
        // the pid alone would collide after wrap-around on a long-lived
        // process.
        let seq = JOB_SEQ.fetch_add(1, Ordering::Relaxed);
        let path = self.tmp_dir.join(format!("dibdog-{}-{}.sql", std::process::id(), seq));

        fs::write(&path, sql).map_err(|e| format!("could not write {}: {e}", path.display()))?;
        let result = self.run(&path);
        let _ = fs::remove_file(&path);
        result
    }

    fn run(&self, path: &std::path::Path) -> Result<Record, String> {
        let mut child = Command::new(&self.scryer)
            .arg("-g")
            .arg("main")
            .arg(&self.check_pl)
            .arg("--")
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("could not start {}: {e}", self.scryer))?;

        // Read stdout on another thread so a wedged Scryer surfaces as a
        // timeout here rather than blocking this thread forever.
        let mut stdout = child.stdout.take().expect("stdout was piped");
        let (tx, rx) = channel();
        thread::spawn(move || {
            let mut buf = String::new();
            let outcome = stdout.read_to_string(&mut buf).map(|_| buf);
            let _ = tx.send(outcome);
        });

        match rx.recv_timeout(CHECK_TIMEOUT) {
            Ok(Ok(output)) => {
                let _ = child.wait();
                Ok(Record::parse(&output))
            }
            Ok(Err(e)) => {
                let _ = child.kill();
                let _ = child.wait();
                Err(format!("could not read checker output: {e}"))
            }
            Err(RecvTimeoutError::Timeout) => {
                let _ = child.kill();
                let _ = child.wait();
                Err(format!("check timed out after {}s", CHECK_TIMEOUT.as_secs()))
            }
            Err(RecvTimeoutError::Disconnected) => {
                let _ = child.kill();
                let _ = child.wait();
                Err("checker output channel closed unexpectedly".to_string())
            }
        }
    }
}

#[derive(Default)]
struct Record {
    fields: Vec<(String, String)>,
    warnings: Vec<(String, String)>,
    /// Lines that were not `key=value`. Scryer reports an uncaught goal
    /// error this way, so keeping them turns a blank result into a
    /// diagnosis.
    noise: Vec<String>,
}

impl Record {
    fn parse(output: &str) -> Record {
        let mut record = Record::default();
        for line in output.lines() {
            let line = line.trim_end_matches(['\r', '\n']);
            if line == "end" {
                break;
            }
            match line.split_once('=') {
                None => {
                    if !line.trim().is_empty() {
                        record.noise.push(line.to_string());
                    }
                }
                Some(("warn", value)) => {
                    let (code, message) = value.split_once('|').unwrap_or((value, ""));
                    record.warnings.push((code.to_string(), message.to_string()));
                }
                Some((key, value)) => {
                    record.fields.push((key.to_string(), value.to_string()));
                }
            }
        }
        record
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.fields.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}

// ============================================================
// Result rendering
// ============================================================

/// Map a 0-based char offset to (line, 1-based column, caret display).
fn position(sql: &str, offset: usize) -> (usize, usize, String) {
    let head: String = sql.chars().take(offset).collect();
    let line_no = head.matches('\n').count() + 1;
    let col = match head.rfind('\n') {
        Some(i) => head[i + 1..].chars().count(),
        None => head.chars().count(),
    };
    let line_text = sql.split('\n').nth(line_no - 1).unwrap_or("");
    let caret = format!("  {}\n  {}^", line_text, " ".repeat(col));
    (line_no, col + 1, caret)
}

fn render(sql: &str, record: &Record) -> String {
    let mut out: Vec<String> = Vec::new();
    match record.get("verdict") {
        Some("accepted") => {
            out.push(format!("VERDICT: accepted ({})", record.get("kind").unwrap_or("?")));
            match record.get("generated") {
                Some(canonical) => out.push(format!("CANONICAL: {canonical}")),
                None => out.push(format!(
                    "CANONICAL: <generator failed> - {}",
                    record.get("generated_error").unwrap_or("unknown")
                )),
            }
            out.push(format!("ROUNDTRIP: {}", record.get("roundtrip").unwrap_or("?")));
            out.push(format!("AST: {}", record.get("ast").unwrap_or("?")));
            out.push(String::new());
            if record.warnings.is_empty() {
                out.push("No known grammar-vs-engine divergences for this shape.".into());
                out.push(
                    "Note: table and column existence, and column-to-table belonging, are \
                     schema checks the grammar cannot make. The engine still enforces them."
                        .into(),
                );
            } else {
                out.push(format!(
                    "{} DIVERGENCE WARNING(S) - the grammar accepts this, but the live \
                     engine is documented to reject it:",
                    record.warnings.len()
                ));
                for (code, message) in &record.warnings {
                    out.push(format!("  [{code}] {message}"));
                }
            }
        }
        Some("rejected") => {
            out.push("VERDICT: rejected - not valid DBISAM SQL".into());
            match record.get("offset").and_then(|o| o.parse::<usize>().ok()) {
                Some(offset) => {
                    let (line_no, col, caret) = position(sql, offset);
                    out.push(format!(
                        "Parser reached line {line_no}, column {col} (offset {offset}):"
                    ));
                    out.push(String::new());
                    out.push(caret);
                    out.push(String::new());
                    out.push(
                        "This is the furthest point any parse branch reached before every \
                         alternative died. The actual mistake is at or before this position, \
                         commonly the token just after it."
                            .into(),
                    );
                }
                None => out.push(
                    "Position diagnostic skipped: the statement is too long to locate the \
                     failure cheaply. Shorten it to under 2000 characters for a caret."
                        .into(),
                ),
            }
        }
        _ => {
            let detail = record
                .get("message")
                .map(str::to_string)
                .or_else(|| {
                    if record.noise.is_empty() { None } else { Some(record.noise.join(" / ")) }
                })
                .unwrap_or_else(|| "checker produced no verdict".to_string());
            out.push(format!("VERDICT: error - {detail}"));
        }
    }
    out.join("\n")
}

// ============================================================
// MCP over Streamable HTTP
// ============================================================

fn tool_schema() -> Value {
    json!({
        "name": "check_sql",
        "title": "Check DBISAM SQL",
        "description":
            "Check a DBISAM SQL statement against the DBISAM DCG grammar. Use this for any \
             SQL destined for the DBISAM/Exportmaster engine (sem01/sem04) rather than \
             guessing whether the dialect allows a construct. DBISAM is SQL-89 shaped: no \
             CTEs, no window functions, subqueries only in `IN (SELECT ...)`, and one \
             statement per call. Reports whether the grammar accepts the statement, the AST \
             it parses to, the canonical form it regenerates, and any documented divergence \
             where the grammar accepts a shape the live engine rejects. On rejection it \
             reports how far the parser got.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sql": {
                    "type": "string",
                    "description": "One DBISAM SQL statement to check."
                }
            },
            "required": ["sql"]
        }
    })
}

fn error_response(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

fn result_response(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

/// Handle one JSON-RPC message. `None` means the message was a
/// notification and carries no reply.
fn handle_rpc(msg: &Value, checker: &Checker) -> Option<Value> {
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");

    // A message with no id is a notification: act on it, answer nothing.
    let id = msg.get("id").cloned()?;

    match method {
        "initialize" => Some(result_response(
            id,
            json!({
                "protocolVersion": msg
                    .get("params")
                    .and_then(|p| p.get("protocolVersion"))
                    .and_then(Value::as_str)
                    .unwrap_or(PROTOCOL_VERSION),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "dibdog", "version": env!("CARGO_PKG_VERSION")}
            }),
        )),
        "ping" => Some(result_response(id, json!({}))),
        "tools/list" => Some(result_response(id, json!({"tools": [tool_schema()]}))),
        "tools/call" => {
            let params = msg.get("params").cloned().unwrap_or(json!({}));
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            if name != "check_sql" {
                return Some(error_response(id, -32602, &format!("unknown tool: {name}")));
            }
            let raw = params
                .get("arguments")
                .and_then(|a| a.get("sql"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let normalised = raw.replace("\r\n", "\n").replace('\r', "\n");
            let sql = normalised.trim();

            let text = if sql.is_empty() {
                "No SQL supplied.".to_string()
            } else if sql.chars().count() > MAX_SQL_CHARS {
                format!(
                    "SQL is {} characters, over the {MAX_SQL_CHARS} character limit. \
                     Check one statement at a time.",
                    sql.chars().count()
                )
            } else {
                match checker.check(sql) {
                    Ok(record) => render(sql, &record),
                    Err(e) => format!("VERDICT: error - {e}"),
                }
            };

            Some(result_response(id, json!({"content": [{"type": "text", "text": text}]})))
        }
        other => Some(error_response(id, -32601, &format!("method not found: {other}"))),
    }
}

fn json_response(body: Value, status: u16) -> Response<std::io::Cursor<Vec<u8>>> {
    let bytes = serde_json::to_vec(&body).unwrap_or_else(|_| b"{}".to_vec());
    Response::from_data(bytes).with_status_code(status).with_header(
        Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..])
            .expect("static header is valid"),
    )
}

fn text_response(body: &str, status: u16) -> Response<std::io::Cursor<Vec<u8>>> {
    Response::from_string(body).with_status_code(status).with_header(
        Header::from_bytes(&b"Content-Type"[..], &b"text/plain; charset=utf-8"[..])
            .expect("static header is valid"),
    )
}

/// Returns an owned value: tiny_http's `equiv` wants a `'static` name,
/// and holding a borrow of the request would block moving it into
/// `respond` later in the same function.
fn header_value(request: &Request, name: &str) -> Option<String> {
    request
        .headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str().to_string())
}

/// Constant-time-ish comparison so a wrong token leaks no length or
/// prefix information through timing.
fn token_matches(supplied: &str, expected: &str) -> bool {
    if supplied.len() != expected.len() {
        return false;
    }
    supplied.bytes().zip(expected.bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

fn serve(request: Request, checker: &Checker, token: &str, allowed_origins: &[String]) {
    // Health probe: no auth, reveals nothing beyond existence.
    if *request.method() == Method::Get {
        let _ = request.respond(text_response("dibdog-mcp ok\n", 200));
        return;
    }

    if *request.method() != Method::Post {
        let _ = request.respond(text_response("method not allowed\n", 405));
        return;
    }

    // DNS-rebinding guard per the MCP spec. Ordinary MCP clients are not
    // browsers and send no Origin at all, so the default is to refuse any
    // request that carries one. A browser-based client is the exception,
    // hence the allowlist.
    if let Some(origin) = header_value(&request, "Origin")
        && !allowed_origins.iter().any(|o| o == &origin)
    {
        let _ = request.respond(text_response(&format!("origin not allowed: {origin}\n"), 403));
        return;
    }

    let authorized = header_value(&request, "Authorization")
        .and_then(|v| v.strip_prefix("Bearer ").map(str::to_string))
        .map(|t| token_matches(t.trim(), token))
        .unwrap_or(false);
    if !authorized {
        let _ = request.respond(
            text_response("unauthorized\n", 401).with_header(
                Header::from_bytes(&b"WWW-Authenticate"[..], &b"Bearer"[..])
                    .expect("static header is valid"),
            ),
        );
        return;
    }

    let mut request = request;
    let mut body = String::new();
    if request.as_reader().take(1 << 20).read_to_string(&mut body).is_err() {
        let _ = request.respond(json_response(
            error_response(Value::Null, -32700, "could not read request body"),
            400,
        ));
        return;
    }

    let parsed: Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            let _ = request.respond(json_response(
                error_response(Value::Null, -32700, &format!("parse error: {e}")),
                400,
            ));
            return;
        }
    };

    // A batch is a JSON array; a single message is an object.
    let response = match &parsed {
        Value::Array(messages) => {
            let replies: Vec<Value> =
                messages.iter().filter_map(|m| handle_rpc(m, checker)).collect();
            if replies.is_empty() { None } else { Some(Value::Array(replies)) }
        }
        _ => handle_rpc(&parsed, checker),
    };

    let _ = match response {
        // Notifications only: acknowledge with 202 and no body, as the
        // Streamable HTTP transport requires.
        None => request.respond(text_response("", 202)),
        Some(body) => request.respond(json_response(body, 200)),
    };
}

fn load_token() -> String {
    match (env::var("DIBDOG_MCP_TOKEN"), env::var("DIBDOG_MCP_TOKEN_FILE")) {
        (Ok(t), _) if !t.trim().is_empty() => t.trim().to_string(),
        (_, Ok(path)) => match fs::read_to_string(&path) {
            Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
            Ok(_) => {
                eprintln!("dibdog-mcp: token file {path} is empty");
                std::process::exit(2);
            }
            Err(e) => {
                eprintln!("dibdog-mcp: cannot read token file {path}: {e}");
                std::process::exit(2);
            }
        },
        _ => {
            eprintln!(
                "dibdog-mcp: set DIBDOG_MCP_TOKEN or DIBDOG_MCP_TOKEN_FILE. \
                 Refusing to serve without a bearer token."
            );
            std::process::exit(2);
        }
    }
}

fn main() {
    let bind = env::var("DIBDOG_MCP_BIND").unwrap_or_else(|_| "127.0.0.1:8791".to_string());
    let scryer = env::var("DIBDOG_SCRYER").unwrap_or_else(|_| "scryer-prolog".to_string());
    let check_pl = env::var("DIBDOG_CHECK_PL").unwrap_or_else(|_| "check.pl".to_string());
    let workers: usize =
        env::var("DIBDOG_MCP_WORKERS").ok().and_then(|v| v.parse().ok()).unwrap_or(2);
    let allowed_origins: Vec<String> = env::var("DIBDOG_MCP_ALLOWED_ORIGINS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let token = load_token();

    if !std::path::Path::new(&check_pl).exists() {
        eprintln!("dibdog-mcp: check.pl not found at {check_pl} (set DIBDOG_CHECK_PL)");
        std::process::exit(2);
    }

    let server = match Server::http(&bind) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            eprintln!("dibdog-mcp: cannot bind {bind}: {e}");
            std::process::exit(2);
        }
    };
    eprintln!("dibdog-mcp: listening on {bind} with {workers} thread(s), check.pl at {check_pl}");

    let checker = Arc::new(Checker::new(scryer, check_pl));
    let allowed_origins = Arc::new(allowed_origins);
    let token = Arc::new(token);

    let mut handles = Vec::new();
    for _ in 0..workers.max(1) {
        let server = Arc::clone(&server);
        let checker = Arc::clone(&checker);
        let token = Arc::clone(&token);
        let allowed_origins = Arc::clone(&allowed_origins);
        handles.push(thread::spawn(move || {
            while let Ok(request) = server.recv() {
                serve(request, &checker, &token, &allowed_origins);
            }
        }));
    }
    for handle in handles {
        let _ = handle.join();
    }
}
