// Engine harness for the Dibdog DCG project.
//
// Wraps mrsflow_cli's DBISAM native client behind a small HTTP/JSON
// endpoint so Prolog (and anything else that speaks HTTP) can ask the
// live engine "do you accept this SQL?".
//
// Contract — POST /verdict {"sql":"..."} returns one of:
//   {"verdict":"accepted","bytes":N}
//   {"verdict":"rejected","detail":"<engine message>"}
//   {"verdict":"error","detail":"<infrastructure failure>"}
//
// The accept/reject/error split is the one specified in
// ARCHITECTURE.md's "Engine harness" section. "rejected" means the
// engine recognised the SQL and refused it (syntax error, unknown
// table, etc). "error" means an infrastructure failure (lost
// connection, decode failure, harness misconfiguration) — these are
// distinct because conflating them poisons differential triage.
//
// Configuration is via env vars:
//   DIBDOG_EM_HOST   target hostname or IP (e.g. "rivsem04")
//   DIBDOG_EM_USER   DBISAM login
//   DIBDOG_EM_PASS   DBISAM password
//   DIBDOG_HARNESS_BIND   bind address (default 127.0.0.1:38120)
//
// Credentials never appear in repo files. Pass via the shell.

use std::env;
use std::sync::Mutex;

use mrsflow_cli::exportmaster::{Client, ConnOpts};
use mrsflow_cli::exportmaster::wire::Walker;
use serde::{Deserialize, Serialize};
use tiny_http::{Header, Method, Response, Server};

#[derive(Deserialize)]
struct VerdictRequest {
    sql: String,
}

#[derive(Serialize)]
#[serde(tag = "verdict", rename_all = "lowercase")]
enum Verdict {
    Accepted {
        bytes: usize,
    },
    Rejected {
        // Wire reqcode from response body header (e.g. "0x2ead").
        reqcode: String,
        // 0x2b02 only: the offending table name.
        #[serde(skip_serializing_if = "Option::is_none")]
        table: Option<String>,
        // 0x2ead only: the database/catalog scope reported with the
        // error (always "NISAINT_CS" against the rivsem04 server).
        #[serde(skip_serializing_if = "Option::is_none")]
        catalog: Option<String>,
        // 0x2ead only: the human-readable error message string the
        // engine emits ("Expected ..." / "Missing FROM ..." etc.).
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        // 0x2ead only: two u32 codes near the end of the Pack stream.
        // Empirically these look like error-class + character position
        // but the mapping is not yet fully characterised — surface as
        // raw values for now and let triage decide.
        #[serde(skip_serializing_if = "Option::is_none")]
        code_a: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        code_b: Option<u32>,
    },
    Error {
        detail: String,
    },
}

struct Harness {
    opts: ConnOpts,
    client: Mutex<Option<Client>>,
}

impl Harness {
    fn from_env() -> Result<Self, String> {
        let host = env::var("DIBDOG_EM_HOST")
            .map_err(|_| "DIBDOG_EM_HOST not set".to_string())?;
        let user = env::var("DIBDOG_EM_USER")
            .map_err(|_| "DIBDOG_EM_USER not set".to_string())?;
        let pass = env::var("DIBDOG_EM_PASS")
            .map_err(|_| "DIBDOG_EM_PASS not set".to_string())?;
        let mut opts = ConnOpts::new(&host, &user, &pass);
        opts.encrypt_password = "elevatesoft".to_string();
        Ok(Self {
            opts,
            client: Mutex::new(None),
        })
    }

    fn verdict(&self, sql: &str) -> Verdict {
        let mut guard = self.client.lock().expect("client mutex poisoned");
        if guard.is_none() {
            match Client::connect_and_login(&self.opts) {
                Ok(c) => *guard = Some(c),
                Err(e) => {
                    return Verdict::Error {
                        detail: format!("connect+login: {e:?}"),
                    };
                }
            }
        }
        let client = guard.as_mut().expect("just populated");
        let result = match client.query_raw(sql) {
            Ok(bytes) => classify_response(&bytes),
            Err(e) => Verdict::Error {
                detail: format!("{e:?}"),
            },
        };
        // Drop the client unconditionally. Validated necessary in
        // task #8: with drop-on-rejection-only, the full UNION
        // query 0006 rejects in roughly 1 of 30 trials following an
        // unrelated SELECT; with unconditional drop, 30/30 accept.
        // The underlying mrsflow client doesn't drain whatever
        // cursor/statement-handle state the engine retains across
        // an Ok response — reconnecting forces a fresh server-side
        // session each time. Cost is ~50ms per query, fine for
        // harness use. A proper upstream fix in mrsflow would let
        // long-lived connections work, but isn't needed here.
        *guard = None;
        result
    }
}

// Classify a `query_raw` Ok response by parsing the body header.
// Layout per `mrsflow_cli::exportmaster::response`:
//   +0  u8        flag (always 0x00)
//   +1  u16 LE    reqcode  ← the discriminator we use
//   +3  u32 LE    body_len
//   +7  Pack stream begins
//
// reqcode 0x0000 means "OK / cursor response follows" (accepted).
// Non-zero values are engine rejections. The Pack stream after the
// header carries structured detail — different layouts per reqcode.
// See `docs/reqcodes.md` for the catalogue.
fn classify_response(bytes: &[u8]) -> Verdict {
    if bytes.len() < 7 {
        return Verdict::Error {
            detail: format!(
                "response body too short to read header: {} bytes",
                bytes.len()
            ),
        };
    }
    let reqcode_u16 = u16::from_le_bytes([bytes[1], bytes[2]]);
    if reqcode_u16 == 0 {
        return Verdict::Accepted { bytes: bytes.len() };
    }
    let reqcode = format!("0x{reqcode_u16:04x}");
    let units = read_pack_units(bytes);
    match reqcode_u16 {
        0x2b02 => decode_table_not_found(reqcode, &units),
        0x2ead => decode_parse_error(reqcode, &units),
        _ => Verdict::Rejected {
            reqcode,
            table: None,
            catalog: None,
            message: None,
            code_a: None,
            code_b: None,
        },
    }
}

// Walk every Pack unit (`<u32 LE len><payload>`) from offset 7 to
// end-of-buffer. Returns the payload slices as owned Vecs (cheap
// — typical response bodies are < 1 KB on the rejection path).
fn read_pack_units(bytes: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut w = Walker::new(bytes, 7);
    while let Ok(Some(unit)) = w.next_unit() {
        out.push(unit.to_vec());
    }
    out
}

// 0x2b02 layout — `select * from <missing-table>`:
//   unit[0] empty
//   unit[1] empty
//   unit[2] <offending table name>
//   (trailing empty / u32 units that don't seem to carry usable
//    detail yet)
fn decode_table_not_found(reqcode: String, units: &[Vec<u8>]) -> Verdict {
    let table = units.get(2).and_then(|u| string_or_none(u));
    Verdict::Rejected {
        reqcode,
        table,
        catalog: None,
        message: None,
        code_a: None,
        code_b: None,
    }
}

// 0x2ead layout — parse / syntax errors:
//   unit[0] empty
//   unit[1] <catalog name>          (e.g. "NISAINT_CS")
//   unit[2..=4] empty
//   unit[5] <human-readable error message>
//   unit[6..=7] empty
//   unit[8] u32 LE code_a           (likely error class)
//   unit[9] u32 LE code_b           (likely character position)
//   (trailing empties)
fn decode_parse_error(reqcode: String, units: &[Vec<u8>]) -> Verdict {
    let catalog = units.get(1).and_then(|u| string_or_none(u));
    let message = units.get(5).and_then(|u| string_or_none(u));
    let code_a = units.get(8).and_then(|u| u32_or_none(u));
    let code_b = units.get(9).and_then(|u| u32_or_none(u));
    Verdict::Rejected {
        reqcode,
        table: None,
        catalog,
        message,
        code_a,
        code_b,
    }
}

fn string_or_none(bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() {
        return None;
    }
    // DBISAM payloads are ASCII for the messages we've observed;
    // fall back to lossy UTF-8 if a non-ASCII byte ever shows up
    // so the harness never returns garbage HTTP.
    Some(String::from_utf8_lossy(bytes).into_owned())
}

fn u32_or_none(bytes: &[u8]) -> Option<u32> {
    if bytes.len() != 4 {
        return None;
    }
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn main() {
    let bind = env::var("DIBDOG_HARNESS_BIND")
        .unwrap_or_else(|_| "127.0.0.1:38120".to_string());
    let harness = match Harness::from_env() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("dibdog-engine-harness: env setup failed: {e}");
            std::process::exit(2);
        }
    };
    let server = match Server::http(&bind) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("dibdog-engine-harness: bind {bind} failed: {e}");
            std::process::exit(1);
        }
    };
    eprintln!(
        "dibdog-engine-harness listening on {bind} (DBISAM target {})",
        harness.opts.host
    );

    let json_header: Header = "Content-Type: application/json"
        .parse()
        .expect("static header parse");

    for mut request in server.incoming_requests() {
        let (status, body) = match (request.method(), request.url()) {
            (Method::Get, "/health") => (
                200u16,
                serde_json::json!({ "ok": true, "target": harness.opts.host }).to_string(),
            ),
            (Method::Post, "/verdict") => {
                let mut body = String::new();
                match request.as_reader().read_to_string(&mut body) {
                    Err(e) => (
                        400,
                        serde_json::json!({ "error": format!("read body: {e}") })
                            .to_string(),
                    ),
                    Ok(_) => match serde_json::from_str::<VerdictRequest>(&body) {
                        Err(e) => (
                            400,
                            serde_json::json!({ "error": format!("parse body: {e}") })
                                .to_string(),
                        ),
                        Ok(req) => {
                            let v = harness.verdict(&req.sql);
                            (200, serde_json::to_string(&v).expect("verdict serialize"))
                        }
                    },
                }
            }
            _ => (
                404,
                serde_json::json!({ "error": "not found" }).to_string(),
            ),
        };
        let response = Response::from_string(body)
            .with_status_code(status)
            .with_header(json_header.clone());
        if let Err(e) = request.respond(response) {
            eprintln!("dibdog-engine-harness: respond: {e}");
        }
    }
}
