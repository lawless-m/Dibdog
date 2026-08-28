# Deploying dibdog-mcp on miami

The checker runs at `https://miami.ram-int.uk/dibdog/`, behind lighttpd,
as a systemd service.

## What the host needs, and why it is not just a binary drop

The Rust server is one static binary, but the *checker* is Prolog. miami
therefore needs three things it did not have:

1. **A Rust toolchain** — to build both the server and Scryer.
2. **Scryer Prolog, pinned to `8dffd72d`** — the same commit the dev box
   runs. See "Why the pin" below; this is not optional.
3. **The grammar** — `grammar/{dcg,functions,function_sigs}.pl` and
   `tools/mcp/check.pl`, laid out so `check.pl`'s `use_module('../../grammar/dcg')`
   resolves.

## Host constraints that shaped the deployment

miami is a small rental (Debian 13, **1 core, 967 MiB RAM**, 484 MiB
tmpfs on `/tmp`) whose day job is static web serving. Three consequences,
each learned the hard way:

- **`/tmp` is a 484 MiB tmpfs.** `cargo install` scratch fills it and the
  build dies with "No space left on device". Build with
  `TMPDIR=$HOME/tmp` and `--target-dir $HOME/cargo-target`.
- **967 MiB will not link Scryer with LTO.** The final `rustc` gets
  OOM-killed (SIGKILL, visible in `dmesg`). Build with
  `CARGO_PROFILE_RELEASE_LTO=false` and `CARGO_PROFILE_RELEASE_DEBUG=0`.
  Neither matters for a grammar checker.
- **One core.** Scryer takes ~0.32s to boot and load the grammar there.
  Two warm workers cost single-digit MiB and are ample.

## Why the pin

**Not for I/O.** The server invokes `check.pl` one-shot with a file
argument, which behaves identically on every Scryer build tested. An
earlier design fed a warm process over piped stdin and *was* version
sensitive; that design is gone precisely so no install can silently break
it. See `README.md` §"Why a process per check".

The pin is for **grammar parity**. The corpus, the round-trip results and
every entry in `docs/DIVERGENCES.md` were established against
`8dffd72d`. Running the grammar on a different Prolog build is a
grammar-correctness change, not a plumbing detail — the project
`README.md` targets one engine and one truth.

This is verifiable, and was verified: the corpus was copied to
`~/Git/Dibdog/dbisam-dcg-project/corpus` on miami and run through
`harness/grammar/runner.pl` there, giving **115 `parsed_match`, 20
`failed`, 4 `parsed`, 0 drift** — byte-identical to the dev box. Repeat
that check after any Scryer change here:

```bash
cd ~/Git/Dibdog/dbisam-dcg-project
find corpus -mindepth 2 -name query.sql | sort > /tmp/paths.txt
~/.cargo/bin/scryer-prolog -g main harness/grammar/runner.pl < /tmp/paths.txt \
  | sort | uniq -c
```

## Install

```bash
# 1. Toolchain (once)
sudo apt-get install -y pkg-config libssl-dev build-essential
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
. "$HOME/.cargo/env"

mkdir -p ~/tmp ~/cargo-target
export TMPDIR=$HOME/tmp CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_DEBUG=0
cargo install --locked --git https://github.com/mthom/scryer-prolog \
      --rev 8dffd72d --target-dir "$HOME/cargo-target" -j 1 scryer-prolog

# 2. Grammar + server sources to ~/Git/Dibdog/dbisam-dcg-project/
#    (grammar/*.pl, tools/mcp/{check.pl,Cargo.toml,src/main.rs})

# 3. Build the server
cd ~/Git/Dibdog/dbisam-dcg-project/tools/mcp && cargo build --release -j 1

# 4. Token — never in a repo file
mkdir -p ~/.config/dibdog
openssl rand -hex 32 > ~/.config/dibdog/token
chmod 600 ~/.config/dibdog/token

# 5. Service
sudo cp deploy/dibdog-mcp.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now dibdog-mcp

# 6. Public route
sudo lighty-enable-mod proxy
sudo cp deploy/54-dibdog.conf /etc/lighttpd/conf-enabled/
sudo systemctl reload lighttpd
```

## Verify

```bash
curl -s https://miami.ram-int.uk/dibdog/                      # dibdog-mcp ok
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
     https://miami.ram-int.uk/dibdog/ -d '{}'                 # 401

TOKEN=$(sudo cat /home/matt/.config/dibdog/token)
curl -s -X POST https://miami.ram-int.uk/dibdog/ \
     -H "Authorization: Bearer $TOKEN" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Register with Claude Code

```bash
claude mcp add --transport http dibdog https://miami.ram-int.uk/dibdog/ \
       --header "Authorization: Bearer <token>"
```

Add at user scope to have `check_sql` available in every session,
whatever repo you are in.

## Operating

```bash
sudo systemctl status dibdog-mcp
sudo journalctl -u dibdog-mcp -f
```

Rotating the token: write a new value to `~/.config/dibdog/token`,
`sudo systemctl restart dibdog-mcp`, and update the client header. The
token is only read at startup.

Updating the grammar: copy the new `grammar/*.pl`. No restart is needed —
each check starts a fresh Scryer that loads the grammar from disk, so the
next request picks it up. Re-run the corpus parity check above afterwards.
