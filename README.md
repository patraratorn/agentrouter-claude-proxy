# agentrouter-claude-proxy

A small local proxy that sits between Claude Code and AgentRouter and fixes the
`API returned an empty or malformed response (HTTP 200)` error.

> **Disclaimer — unofficial community compatibility proxy.
> Not affiliated with AgentRouter, Anthropic, or OpenAI.**
> It is not endorsed by any of them, and it comes with no warranty. See
> [LICENSE](LICENSE).

---

## 1. What this project is

`agentrouter-claude-proxy` is a single-file Python proxy that speaks the
Anthropic Messages API on both sides. Claude Code talks to it on
`127.0.0.1:8787`; it talks to AgentRouter. In between, it repairs a narrow class
of *transport and stream-format* problems that would otherwise surface in Claude
Code as an unhelpful error.

It is a compatibility shim, nothing more. It does not change what the model
says, what you are allowed to ask, or what your account can access.

---

## 2. The problem it solves

When you point Claude Code at AgentRouter, it will sometimes fail with:

```
API returned an empty or malformed response (HTTP 200)
```

The upstream answered `200 OK`, so the HTTP layer thinks everything is fine —
but the body was not something Claude Code can use. In practice that turns out
to be one of a handful of concrete situations:

| What arrives | Why Claude Code fails |
|---|---|
| An empty body | Nothing to parse |
| The literal `null` | Not a message object |
| An SSE stream that opens and immediately closes | No events at all |
| A stream of nothing but `ping` keep-alives | No content ever arrives |
| Billing / quota / credit metadata frames only | Not Anthropic events |
| `data: null` or an OpenAI-style `data: [DONE]` mixed into the stream | Not valid Anthropic frames |
| A stream that dies before `message_stop` | Truncated message |
| A reply with `content` and `model` but no `usage` (a `billing` block instead) | Fails Claude Code's response validator |
| A stale `content-encoding: gzip` header on an already-decompressed body | Client tries to gunzip plain text |

Most of these are transient. Retrying the same request usually works. The
difficulty is that a naive proxy cannot retry safely once it has already handed
part of the answer to the client — replaying at that point would duplicate
assistant text or, much worse, duplicate tool calls.

This proxy solves that by **not committing anything to Claude Code until the
upstream has proven it is producing real content.** It buffers the head of the
response, checks it, and only then starts forwarding. If the check fails,
nothing has been sent yet, so the request can be retried cleanly.

---

## 3. Architecture

```
        Claude Code
             |
             |  ANTHROPIC_BASE_URL=http://127.0.0.1:8787
             v
      127.0.0.1:8787
             |
             |  local compatibility proxy (this project)
             |    - buffers the head of the response
             |    - validates before committing anything
             |    - retries transient failures
             |    - drops non-Anthropic junk frames
             v
      https://agentrouter.org
             |
             v
        upstream model
```

The proxy listens on loopback only. It is never reachable from your LAN or from
the internet.

---

## 4. Features

- **Anthropic Messages API compatible** — streaming and non-streaming.
- **Detects invalid HTTP 200 responses** — empty body, `null` body, empty SSE
  stream, keep-alive-only stream, metadata-only stream, missing or empty
  `content`.
- **Validates non-streaming replies the way Claude Code does** — a
  non-streaming `/v1/messages` reply is accepted only if `content` is an array,
  `model` is a string, and `usage` is present. Claude Code applies the same
  check and rejects anything else as `empty or malformed response (HTTP 200)`,
  so a reply that would fail there is retried here and reported as a 502
  instead. Nothing is fabricated to make a reply pass: a missing `usage` is
  never invented, and `billing` metadata is never converted into token counts.
- **Detects malformed responses** — unparseable JSON, a non-SSE body when a
  stream was requested, bodies that fail to decompress.
- **Retries with bounded exponential backoff** — three attempts, 500 ms then
  1000 ms, and only for failures that are genuinely transient.
- **Prime-before-commit** — nothing reaches Claude Code until a
  `content_block_start` or `content_block_delta` proves the upstream is
  producing content. Buffered frames are then replayed in order, so nothing is
  lost.
- **Never replays after committing** — once a byte has been sent, a later
  failure is reported as a real Anthropic `error` event instead of being
  retried. This is what prevents duplicated output and duplicated tool calls.
- **SSE normalization** — junk frames (`data: null`, `data: [DONE]`, empty
  frames, billing/quota/credit metadata) are dropped whole. Valid Anthropic
  events are forwarded byte-for-byte.
- **`tool_use` IDs preserved exactly** — frames are forwarded or dropped whole
  and never rewritten, so an ID cannot be altered.
- **Compression-safe** — requests an identity encoding upstream and strips stale
  `content-encoding` / `content-length` headers from the response.
- **Clean client-disconnect handling** — when Claude Code goes away mid-stream
  the upstream connection is closed rather than leaked.
- **`/_health` and `/_stats` endpoints** for liveness and counters.
- **Single-instance protection** — starting it twice on the same port is a
  no-op, not a crash.
- **Loopback-only** — binds `127.0.0.1` and nothing else.
- **Bounded, rotating logs** with no credentials, prompts, or model output in
  them.
- **Windows auto-start** via Task Scheduler, with a supervisor that restarts the
  server if it dies.

---

## 5. Requirements

- Windows 10 or 11 (the PowerShell scripts are Windows-specific; `proxy.py`
  itself is portable)
- Python 3.10 or newer
- Claude Code
- An AgentRouter account

Python dependencies (pinned in `requirements.txt`):

```
fastapi==0.115.6
uvicorn==0.34.0
httpx==0.28.1
```

---

## 6. Installation on Windows

Clone the repository anywhere you like. Every script resolves its own paths, so
no particular location is required.

```powershell
git clone https://github.com/patraratorn/agentrouter-claude-proxy.git
cd agentrouter-claude-proxy
```

If PowerShell refuses to run the scripts, allow local scripts for your own
account:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

---

## 7. Create a virtual environment

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

The launcher finds `.venv` automatically on later runs, so you only have to
activate it manually if you want to work in it yourself.

---

## 8. Install dependencies

```powershell
python -m pip install -r requirements.txt
```

`start-proxy.ps1` also installs them for you if it finds them missing.

---

## 9. Start the proxy

```powershell
.\start-proxy.ps1
```

You should see:

```
[ ok  ] interpreter: Python 3.13.0
[ ok  ] all dependencies present
[ ok  ] port 8787 is free

  AgentRouter compatibility proxy
  upstream : https://agentrouter.org
  listen   : http://127.0.0.1:8787 (loopback only)
  stats    : http://127.0.0.1:8787/_stats
  health   : http://127.0.0.1:8787/_health
  stop     : Ctrl+C
```

Useful switches:

```powershell
.\start-proxy.ps1 -Port 8790     # different port
.\start-proxy.ps1 -Verbose_      # extra structural diagnostics
.\start-proxy.ps1 -Service       # supervised, logs to logs\proxy.log
```

Leave it running. Claude Code needs it up.

---

## 10. Point Claude Code at it

Add `ANTHROPIC_BASE_URL` to `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"
  }
}
```

Keep your existing settings — add this key alongside them rather than replacing
the file. Back it up first if you are unsure.

**About your API key:** you do not need to put one in this repository. Claude
Code already sends its own credential with every request, and the proxy forwards
it to AgentRouter untouched. Configuring a key here is only a fallback for
clients that send none, and even then it belongs in a local `.env` file, which
is gitignored.

Restart Claude Code after editing settings.

---

## 11. Test that it works

Start a new Claude Code session and send:

```
Reply only: OK
```

You should get `OK` back. In the proxy console you will see:

```
[proxy] POST /v1/messages -> https://agentrouter.org/v1/messages  stream=True
[proxy] upstream attempt 1
[proxy] HTTP 200
[proxy] valid Anthropic SSE detected
[proxy] forwarding stream
[proxy] stream complete: 8 frames in 0.3s, message_stop=yes
```

If AgentRouter hiccups, you will instead see the retry happen — and Claude Code
will still get a clean answer:

```
[proxy] upstream attempt 1
[proxy] HTTP 200
[proxy] invalid response: empty stream (upstream closed with zero SSE frames)
[proxy] retrying in 500ms
[proxy] upstream attempt 2
[proxy] HTTP 200
[proxy] valid Anthropic SSE detected
[proxy] recovered on attempt 2
```

---

## 12. Test tool use

Tool calls are the case where a careless proxy does real damage, so test them
explicitly. Send:

```
List the files in the current directory. Do not modify anything.
```

Claude Code should run its file-listing tool once and show you the result. What
matters is that the tool runs **exactly once**: `tool_use` IDs are forwarded
byte-for-byte, and the proxy never replays a stream after it has begun
forwarding, so a tool call cannot be duplicated.

---

## 13. Health check

```powershell
Invoke-RestMethod http://127.0.0.1:8787/_health
```

```json
{
  "status": "ok",
  "upstream": "https://agentrouter.org",
  "listen": "127.0.0.1:8787"
}
```

If this does not answer, the proxy is not running and Claude Code will not work.

---

## 14. Statistics

```powershell
Invoke-RestMethod http://127.0.0.1:8787/_stats
```

```json
{
  "total_requests": 42,
  "successful_requests": 41,
  "empty_200_responses": 3,
  "malformed_streams": 1,
  "retries": 4,
  "retries_successful": 4,
  "upstream_5xx": 0,
  "upstream_4xx": 1,
  "dropped_sse_frames": 12,
  "post_commit_failures": 0,
  "client_disconnects": 2,
  "failed_requests": 1,
  "uptime_seconds": 3600.5
}
```

| Counter | Meaning |
|---|---|
| `empty_200_responses` | Upstream said 200 but sent nothing usable |
| `malformed_streams` | Upstream sent something unparseable or truncated |
| `retries` / `retries_successful` | Retries issued, and how many then succeeded |
| `dropped_sse_frames` | Non-Anthropic junk frames removed from streams |
| `post_commit_failures` | Streams that broke *after* forwarding began (not retryable) |
| `client_disconnects` | Times Claude Code abandoned a stream |

`retries_successful` is the number that tells you whether the proxy is earning
its keep. `post_commit_failures` should be near zero.

---

## 15. Start automatically at logon (Windows)

```powershell
.\install-autostart.ps1
```

This registers a scheduled task named `AgentRouterProxy` that starts the proxy
8 seconds after you log in, hidden, running as your own account with no
elevation. The repository path is taken from the script's own location and the
account from your current session, so nothing is hardcoded.

Preview without changing anything:

```powershell
.\install-autostart.ps1 -WhatIf_
```

Options:

```powershell
.\install-autostart.ps1 -Port 8790 -TaskName MyProxy -DelaySeconds 15
```

**No credential is stored in the scheduled task**, and none is needed — Claude
Code sends its own with each request.

**This is logon autostart, not boot autostart.** The task uses an `Interactive`
principal with an at-logon trigger: the proxy starts a few seconds after you
log in, and nothing runs while you are logged off. That is intentional — the
proxy listens on loopback and only serves the Claude Code running in your own
session, so there is nothing for it to do when nobody is logged in. Starting
while logged off would require an `S4U` principal, which also needs an
elevated PowerShell to register (a non-elevated attempt fails with *Access is
denied*); it is deliberately not used. Installing needs no elevation: the task
runs as your own account with `RunLevel Limited`.

After registering, the installer reads the task back from Task Scheduler and
verifies the stored principal, action, and working directory actually match
what it requested. If Windows stored anything different, the installer reports
a failure listing the mismatches instead of printing a misleading success.

Under `-Service` the proxy writes to `logs\proxy.log`, rotating at 1024 KB and
keeping one previous generation, so disk use stays bounded at roughly 2 MB. If
the server process dies, a supervisor loop restarts it with 5→60 second
exponential backoff.

Check on it:

```powershell
Get-ScheduledTask -TaskName AgentRouterProxy
Get-Content .\logs\proxy.log -Tail 40
```

---

## 16. Stop it or remove the task

```powershell
# Stop the current run, keep the task registered
Stop-ScheduledTask -TaskName AgentRouterProxy

# Keep it from starting at logon, without removing it
Disable-ScheduledTask -TaskName AgentRouterProxy
Enable-ScheduledTask  -TaskName AgentRouterProxy

# Remove the task entirely and stop the running proxy
.\uninstall-autostart.ps1

# Remove the task but leave the proxy running
.\uninstall-autostart.ps1 -KeepRunning
```

`uninstall-autostart.ps1` only stops a process on port 8787 after confirming via
`/_health` that it is this proxy. Anything else on that port is reported and
left alone.

If you started it interactively, `Ctrl+C` is enough.

When you stop using the proxy, remove `ANTHROPIC_BASE_URL` from
`~/.claude/settings.json` — otherwise Claude Code keeps trying to reach a proxy
that is no longer there.

---

## 17. Troubleshooting

### `API returned an empty or malformed response (HTTP 200)` — still

Check `/_stats`. If `empty_200_responses` or `malformed_streams` is climbing
while `retries_successful` stays at zero, AgentRouter is failing on every
attempt, not intermittently. That is an upstream problem; retrying harder will
not fix it. Try a different model, or wait.

Raising `PROXY_MAX_ATTEMPTS` in `.env` gives it more chances, at the cost of a
longer wait before the error surfaces.

### HTTP 401 — unauthorized

Your credential was rejected, or the client identity was. **The proxy does not
and will not bypass this.** Check that your AgentRouter key is valid, that it is
correctly set in `~/.claude/settings.json`, and that your account is permitted
to use the client you are connecting with. A 401 that persists across every
attempt is an account or credential matter, and it has to be solved with
AgentRouter — not in a proxy.

### HTTP 403 — forbidden

Your account is authenticated but not permitted to use that model or endpoint.
**Also not something the proxy bypasses.** Check your AgentRouter plan and model
permissions.

### HTTP 503, or "no available channel"

AgentRouter has no upstream capacity for the model you asked for. The proxy
retries — that is genuinely transient sometimes — and if every attempt fails it
reports the problem honestly:

```
AgentRouter upstream availability problem: no available channel/model for the
requested model. This is an upstream capacity/routing issue, not a client error.
```

There is no way to repair this locally. Pick another model or try later.

### Port 8787 already in use

```powershell
Get-NetTCPConnection -LocalPort 8787 -State Listen |
  Select-Object OwningProcess |
  ForEach-Object { Get-Process -Id $_.OwningProcess }
```

If it is this proxy, you are already running — `start-proxy.ps1` detects that
via `/_health` and exits successfully without starting a second copy. If it is
something else, the script reports it and **leaves it running**; it will never
kill a process it did not start. Use another port instead:

```powershell
.\start-proxy.ps1 -Port 8790
```

and update `ANTHROPIC_BASE_URL` to match.

### Claude Code cannot connect at all

The proxy is not running. Check:

```powershell
Invoke-RestMethod http://127.0.0.1:8787/_health
```

If that fails, start it with `.\start-proxy.ps1`, or check `logs\proxy.log` if
it is supposed to be running as a scheduled task. Also confirm
`ANTHROPIC_BASE_URL` in `~/.claude/settings.json` is exactly
`http://127.0.0.1:8787` — no trailing slash, no `/v1`.

---

## What this project does *not* do

This matters more than the feature list, so it is spelled out plainly.

- **It does not bypass authentication.** A 401 or 403 is forwarded to you as-is.
  There is no retry, no workaround, and no attempt to make a rejected credential
  look accepted.
- **It does not bypass content filters.** Prompts are forwarded unmodified. The
  proxy never rewrites, rephrases, or injects anything to change how a request
  is evaluated.
- **It does not impersonate any client.** Your own `User-Agent` is passed
  through unchanged. There is no browser-header spoofing and no pretending to be
  a different application.
- **It never fabricates model output.** There are no mocked endpoints, no fake
  `/v1/models` response, no invented token counts, and no synthetic
  `message_stop`. If the upstream produced nothing, you are told it produced
  nothing.
- **It cannot fix upstream outages.** A 503 with no available channel is an
  AgentRouter capacity problem. The proxy reports it accurately; it cannot
  conjure capacity.
- **It does not turn failures into fake successes.** An invalid HTTP 200 is
  never passed through as a 200 — that is the exact bug this project exists to
  fix. After all retries are exhausted it returns a real error.
- **It will not replay a stream after output has been committed.** Once bytes
  have reached Claude Code, retrying could duplicate assistant text or run a
  tool twice. The failure is reported instead. This is a deliberate trade: a
  visible error is better than a silently duplicated tool call.
- **It never logs credentials, prompts, or model output.** Logs contain event
  types, frame counts, drop reasons, and status codes. Where a credential must
  be mentioned at all, only its length is printed.

In short: this handles transport and stream-format compatibility, plus transient
malformed responses. Everything else is passed through honestly.

---

## Security notes

- The listener binds `127.0.0.1` and this is not configurable by environment
  variable. The proxy forwards whatever credential the client presents, so a
  LAN-reachable listener would let any host on your network spend your API
  quota. Do not change it.
- No API key is required in this repository. `.env` is gitignored;
  `.env.example` contains placeholders only.
- `~/.claude/settings.json` contains your token. It is gitignored here and
  should never be committed to any repository.
- Logs are bounded and rotate. They contain no sensitive content.

---

## Configuration

All settings are environment variables, read from the environment or from a
local `.env`. Copy `.env.example` to `.env` to change any of them.

| Variable | Default | Purpose |
|---|---|---|
| `AGENTROUTER_UPSTREAM` | `https://agentrouter.org` | Upstream endpoint |
| `PROXY_PORT` | `8787` | Local port (host is always `127.0.0.1`) |
| `PROXY_MAX_ATTEMPTS` | `3` | Attempts before reporting failure |
| `PROXY_BACKOFF_BASE_MS` | `500` | First backoff; doubles each retry |
| `PROXY_PRIME_TIMEOUT_S` | `120` | Wait for first content event; raise for slow reasoning models |
| `PROXY_CONNECT_TIMEOUT_S` | `15` | Upstream connect timeout |
| `PROXY_READ_TIMEOUT_S` | `600` | Upstream read timeout |
| `PROXY_VERBOSE` | `0` | Extra structural diagnostics |
| `AGENTROUTER_API_KEY` | *(unset)* | Fallback credential, only if the client sends none |

---

## Running the tests

The suite runs against a mock upstream that reproduces every failure mode listed
above. It never contacts AgentRouter and never uses a real credential.

```powershell
.\tests\run-tests.ps1
```

It starts a mock upstream on `127.0.0.1:8788` and a throwaway proxy on
`127.0.0.1:8789`, so an already-running proxy on 8787 is left undisturbed. Both
are stopped when the run ends. Use `-MockPort` / `-ProxyPort` if those are busy.

---

## Attribution

The compatibility problem this project addresses has been discussed in community
channels, and workaround proxies circulate informally. The code here is written
for this repository. Where a general approach is shared — retrying transient
failures, filtering hop-by-hop headers, splitting an SSE byte stream on blank
lines — those are standard techniques rather than anyone's original expression.

Some behaviours found in circulating workarounds were considered and
deliberately excluded: browser `User-Agent` impersonation, mocked `/v1/models`
and `count_tokens` endpoints with fabricated values, and passing an invalid
HTTP 200 straight through to the client. They are unsafe, dishonest to the
client, or both.

If you believe any part of this repository derives from code you hold rights to,
please open an issue and it will be addressed.

---

## License

MIT — see [LICENSE](LICENSE).
