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
- **Always on** — systemd autostart + auto-restart on crash or reboot.

## Requirements

- Linux with an NVIDIA GPU + recent driver (`nvidia-smi` must work)
- `curl`, `python3`, `sudo`
- (Optional) a Cloudflare account + domain for a stable hostname
- (Optional) a Discord webhook URL for notifications

## Quickstart

```bash
git clone <your-repo-url> maschinenraum
cd maschinenraum
./setup.sh
```

`setup.sh` is idempotent — re-run it any time. It will:

1. Verify the GPU and detect VRAM.
2. Create `.env`, generate a strong `MR_API_KEY`, and auto-pick a model for your VRAM.
3. Install vLLM into a local `uv` venv (+ Caddy if Whisper is enabled).
4. Install and start systemd services (core, Whisper, router, tunnel, timers).
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

**Remote access:** with a `CLOUDFLARE_TUNNEL_TOKEN` you get a stable hostname
(configured in the Cloudflare dashboard → point it at `127.0.0.1:MR_EDGE_PORT`).
Without one, a free `*.trycloudflare.com` URL is created on each start and posted
to Discord.

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

```bash
# logs
journalctl -u maschinenraum-core -f          # main model
tail -f data/logs/core.log                   # same, file
# control
sudo systemctl restart maschinenraum-core    # restart after a config change
sudo systemctl status 'maschinenraum-*'      # everything at a glance
# notifications on demand
./lib/metrics_digest.sh health               # send a health ping now
./lib/metrics_digest.sh digest               # send the weekly digest now
```

Switch model: edit `MR_MODEL` in `.env` → `sudo systemctl restart maschinenraum-core`.

## How it works

- `setup.sh` — installer/orchestrator (idempotent).
- `run.sh core|whisper` — launches a vLLM server; called by systemd.
- `lib/` — `detect_gpu`, `pick_model`, `cloudflare`, `notify`, `metrics_digest`.
- `systemd/` — unit + timer templates (`__MR_HOME__`/`__MR_USER__` filled at install).
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
