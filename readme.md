# maschinenraum

Self-hosted AI inference engine. One command turns a Linux + NVIDIA box into a
fast, authenticated, OpenAI-compatible API you can reach from anywhere — for
your terminal AI, your (separately hosted) chat UI, and your own apps.

```
clients (terminal CLI · chat UI · custom apps, from anywhere)
        │   Authorization: Bearer <MR_API_KEY>
        ▼
  Cloudflare Tunnel ──▶ Caddy router ──┬─▶ vLLM   text + vision   /v1/chat, /v1/embeddings
   (remote, HTTPS)      (one endpoint)  └─▶ Whisper STT            /v1/audio/transcriptions
```

- **vLLM** — high throughput via continuous batching + prefix caching. Multiple
  users hit it in parallel without each paying full latency.
- **One endpoint, one key** — a small Caddy router merges chat/vision and audio
  behind a single hostname so every client just sets a base URL + key.
- **Remote from day one** — Cloudflare Tunnel, no open ports.
- **Stays in the loop** — Discord daily health ping + weekly usage digest, sourced
  straight from vLLM's Prometheus `/metrics` (no Grafana to run or check).
- **Always on** — Docker `restart: unless-stopped` brings every service back on
  crash or reboot.

## Requirements

- Linux with an NVIDIA GPU + recent driver (`nvidia-smi` must work)
- `curl`, `python3`, `sudo`
- Docker + the NVIDIA container toolkit — **auto-installed by `setup.sh`** if missing
- (Optional) a Cloudflare account + domain for a stable hostname
- (Optional) a Discord webhook URL for notifications

## Quickstart

```bash
git clone <your-repo-url> maschinenraum
cd maschinenraum
./setup.sh
```

`setup.sh` is idempotent — re-run it any time. It will:

1. Verify the GPU; install Docker + the NVIDIA container toolkit if missing.
2. Create `.env`, generate a strong `MR_API_KEY`, and auto-pick a model for your VRAM.
3. Generate the Caddy router config and reconcile the GPU memory split.
4. `docker compose up -d` the stack (vLLM, Whisper, Caddy, tunnel, notifier).
5. Wait for the API, then print the endpoint and a `curl` test (and ping Discord).

Then add your secrets to `.env` (Cloudflare token, Discord webhook) and re-run
`./setup.sh`, or just restart the tunnel service.

## Configuration

Everything lives in `.env` (copied from `.env.example`, gitignored). Highlights:

| Key | Meaning |
|-----|---------|
| `MR_API_KEY` | Bearer token clients use (auto-generated) |
| `MR_MODEL` | Model id; blank = auto-pick from VRAM |
| `MR_GPU_MEMORY_UTILIZATION` | Fraction of VRAM for the main model (default `0.90`) |
| `MR_MAX_MODEL_LEN` / `MR_MAX_NUM_SEQS` | Context length / concurrency tuning |
| `MR_ENABLE_WHISPER` | `true` runs Whisper STT behind the router |
| `CLOUDFLARE_TUNNEL_TOKEN` | Named-tunnel token → stable hostname (blank = ephemeral URL) |
| `DISCORD_WEBHOOK_URL` | Notifications (blank disables them) |

**Remote access:** see the full [Cloudflare Tunnel setup](#cloudflare-tunnel-setup)
section below — it's the fiddliest part, so it's written out click-by-click.

## Cloudflare Tunnel setup

This is what exposes the box to the internet without opening any ports on your
router. There are two paths — pick one.

### No domain? Use the quick tunnel (zero setup)

Leave `CLOUDFLARE_TUNNEL_TOKEN` **blank** in `.env`. On every start, `cloudflared`
creates a throwaway `https://<random>.trycloudflare.com` URL and posts it to your
Discord webhook. Nothing to configure. The catch: **the URL changes on every
restart**, so it's good for testing, not for handing a stable address to your wife
or an app. If you want a fixed hostname, do the named tunnel below.

### Stable hostname: named tunnel (recommended)

You need a domain whose nameservers are managed by Cloudflare (adding a site to
Cloudflare walks you through pointing your registrar's nameservers at it — this
propagates in minutes to a few hours).

**1. Open Zero Trust.** In the [Cloudflare dashboard](https://dash.cloudflare.com),
left sidebar → **Zero Trust**. The first time, it asks you to pick a team name and
a plan — choose **Free** (it may ask for a card but won't charge for this).

**2. Create the tunnel.** Zero Trust → **Networks → Tunnels → Create a tunnel** →
choose **Cloudflared** → name it (e.g. `maschinenraum`) → **Save**.

**3. Grab the token.** The next screen shows install commands containing a long
token (the string after `--token`, starts with `eyJ...`). You don't need to run
their command — our setup already installs `cloudflared`. Just **copy that token**.

**4. Put it in `.env`:**

```bash
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi... (the long token)
MR_PUBLIC_HOSTNAME=ai.yourdomain.com   # for docs/printing only
```

**5. Add the public hostname.** Still in the tunnel's setup wizard (or later via
the tunnel's **Public Hostname** tab → **Add a public hostname**):

| Field | Value |
|-------|-------|
| Subdomain | `ai` (or whatever you like) |
| Domain | `yourdomain.com` (pick from the dropdown) |
| Path | *(leave empty)* |
| Type | **HTTP** |
| URL | `caddy:8080` |

> ⚠️ The **URL** is `caddy:8080`, not `localhost:8080` — `cloudflared` runs as a
> container on the same Docker network, so it reaches the router by its compose
> **service name** (`caddy`). It must be **HTTP** (TLS is terminated at Cloudflare's
> edge), and the port must match `MR_EDGE_PORT` (`8080` with Whisper on; set it to
> `vllm:8000` if you run `MR_ENABLE_WHISPER=false`). This mismatch is the #1 cause
> of `502`s.

Cloudflare auto-creates the DNS record for `ai.yourdomain.com` — you don't add one
manually.

**6. Apply it.** Re-run `./setup.sh` (or just
`sudo systemctl restart maschinenraum-tunnel`). Then from anywhere:

```bash
curl https://ai.yourdomain.com/v1/models -H "Authorization: Bearer $MR_API_KEY"
```

### When it doesn't work

| Symptom | Usual cause |
|---------|-------------|
| **502 Bad Gateway** | Service URL isn't `caddy:8080`, or vLLM isn't up yet. Check `docker compose ps` and `docker compose logs vllm`. |
| **Error 1033 / "tunnel not found"** | `cloudflared` isn't connected. `docker compose logs cloudflared-token`; verify the token in `.env`. |
| **DNS won't resolve** | Domain's nameservers aren't on Cloudflare yet, or the hostname wasn't added in step 5. The record's proxy (orange cloud) must be **on**. |
| **521/523** | Service URL set to `https://...` instead of `http://...`. |
| **Works locally, not remotely** | You restarted `vllm`/`caddy` but not the tunnel: `docker compose restart cloudflared-token`. |

> **Optional — lock it to just you two.** Since you're sharing with your wife, you
> can add **Zero Trust → Access → Applications** in front of the hostname with an
> email allowlist, so only your two logins can even reach the API (on top of the
> API key). Not required, but a nice second lock.

## Using it

All clients point at the same base URL with the same key. Locally that's
`http://localhost:8000/v1`; remotely it's your Cloudflare hostname.

**Terminal AI (e.g. [`llm`](https://llm.datasette.io) / `aichat`):** set an
OpenAI-compatible provider with `base_url = https://<host>/v1`, `api_key = <MR_API_KEY>`,
`model = maschinenraum`.

**Your chat UI (separate repo):** configure an OpenAI endpoint with the same
base URL + key. The model name is `maschinenraum`.

**Custom apps (OpenAI SDK):**

```python
from openai import OpenAI
client = OpenAI(base_url="https://<host>/v1", api_key="<MR_API_KEY>")
client.chat.completions.create(model="maschinenraum",
    messages=[{"role": "user", "content": "hello"}])
```

**Vision** (same chat endpoint, image input):

```bash
curl https://<host>/v1/chat/completions -H "Authorization: Bearer $MR_API_KEY" \
  -H "Content-Type: application/json" -d '{"model":"maschinenraum","messages":[
   {"role":"user","content":[{"type":"text","text":"what is this?"},
    {"type":"image_url","image_url":{"url":"https://example.com/cat.jpg"}}]}]}'
```

**Audio transcription** (Whisper, routed automatically):

```bash
curl https://<host>/v1/audio/transcriptions -H "Authorization: Bearer $MR_API_KEY" \
  -F file=@clip.mp3 -F model=openai/whisper-large-v3-turbo
```

## Operations

All services run under Docker Compose and auto-restart (`restart: unless-stopped`),
so the stack comes back after a crash or reboot.

```bash
docker compose ps                  # everything at a glance
docker compose logs -f vllm        # main model logs
docker compose restart vllm        # restart after a config change
docker compose down                # stop the stack
./setup.sh                         # re-run any time (idempotent) to apply changes
```

Switch model: edit `MR_MODEL` in `.env` → `docker compose up -d vllm`.
Health/digest pings come from the `notifier` service automatically; trigger a
manual run by restarting it: `docker compose restart notifier`.

## How it works

- `setup.sh` — installer/orchestrator: installs Docker + the NVIDIA toolkit,
  writes `.env`/`Caddyfile`, picks profiles, brings the stack up (idempotent).
- `docker-compose.yml` — services: `vllm`, `whisper` (profile), `caddy`,
  `cloudflared-token`/`-quick` (profiles), `notifier`.
- `lib/` — `detect_gpu`, `pick_model`, `notify` (host helpers) and `notifier.py`
  (the in-container Discord health/digest loop).
- `Caddyfile` — generated router; one hostname for chat + audio.

## Potential next steps

The roadmap below is intentionally **not** built yet — iteration 1 is the
smallest thing that's useable day-to-day. Each layers on without breaking clients
(the endpoint and key contract stay the same).

- **Per-user API keys & per-user logs → personalization.** Add a
  [LiteLLM](https://github.com/BerriAI/litellm) proxy in front of vLLM to issue a
  separate key per person/app, with budgets and rate limits. Because every request
  is then tagged with a user, we get **per-user usage logs** and the foundation to
  **personalize experiences** (per-user default system prompts, model, settings).
  Drop-in: clients only swap their key; the base URL is unchanged.
- **Discord control bot** — slash commands (`/status`, `/usage`, `/upgrade`,
  `/restart`, `/key add`) to run the box from your phone.
- **Model auto-upgrade loop** — a weekly timer that checks whether a better model
  fits your VRAM and asks (via Discord) before installing.
- **Auto-benchmark on setup** (`mr bench`) — report tokens/s at a given concurrency.
- **TTS + image generation** — additional model servers (`/v1/audio/speech`,
  `/v1/images/generations`) routed behind the same endpoint.
- **Grafana/Prometheus dashboard** — only if you scale to many users and need to
  right-size concurrency or chase latency over time; otherwise the Discord digest
  covers it.
- **Backups & teardown helpers**, and a unified `mr` CLI wrapping the above.
