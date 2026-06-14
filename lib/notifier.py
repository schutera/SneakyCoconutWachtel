#!/usr/bin/env python3
"""maschinenraum notifier — the whole 'observability stack'.

Polls vLLM's Prometheus /metrics (+ best-effort nvidia-smi) and posts to Discord:
  • a daily health ping (alive? GPU? tokens? KV-cache pressure?)
  • a weekly usage digest (token deltas vs. a saved snapshot)
Stdlib only, so it runs in a bare python:slim image.
"""
import json
import os
import subprocess
import time
import urllib.request
from datetime import datetime

VLLM_HOST = os.environ.get("MR_VLLM_HOST", "vllm")
PORT = os.environ.get("MR_PORT", "8000")
KEY = os.environ.get("MR_API_KEY", "")
MODEL = os.environ.get("MR_MODEL", "?")
WEBHOOK = os.environ.get("DISCORD_WEBHOOK_URL", "")
STATE = "/data/state/notifier_state.json"
BASE = f"http://{VLLM_HOST}:{PORT}"


def _get(path):
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {KEY}"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode()


def alive():
    try:
        _get("/health")
        return True
    except Exception:
        return False


def metrics():
    try:
        return _get("/metrics")
    except Exception:
        return ""


def _metric(body, name, reducer):
    vals = []
    for line in body.splitlines():
        if line.startswith("#") or not line:
            continue
        if line.split("{")[0].split(" ")[0] == name:
            try:
                vals.append(float(line.rsplit(" ", 1)[1]))
            except ValueError:
                pass
    return reducer(vals) if vals else 0.0


def metric_sum(body, name):
    return _metric(body, name, sum)


def metric_last(body, name):
    return _metric(body, name, lambda v: v[-1])


def gpu_line():
    try:
        out = subprocess.check_output(
            ["nvidia-smi",
             "--query-gpu=temperature.gpu,utilization.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits", "-i", "0"],
            timeout=5, stderr=subprocess.DEVNULL).decode().strip()
        t, u, mu, mt = (x.strip() for x in out.split(","))
        return f"{t}°C · {u}% util · {mu}/{mt} MiB"
    except Exception:
        return "n/a"


def send(msg):
    if not WEBHOOK:
        print("[notifier] no webhook set:", msg, flush=True)
        return
    data = json.dumps({"content": msg}).encode()
    req = urllib.request.Request(WEBHOOK, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print("[notifier] discord post failed:", e, flush=True)


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(s):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as f:
        json.dump(s, f)


def n(x):
    return f"{int(x):,}"


def health():
    if not alive():
        send("🔴 **maschinenraum** is DOWN — vLLM /health not answering.")
        return
    b = metrics()
    kv = metric_last(b, "vllm:gpu_cache_usage_perc") * 100
    send(
        "🟢 **maschinenraum** healthy\n"
        f"• GPU: {gpu_line()}\n"
        f"• KV-cache in use: {kv:.0f}%\n"
        f"• Tokens since boot: {n(metric_sum(b, 'vllm:prompt_tokens_total'))} in / "
        f"{n(metric_sum(b, 'vllm:generation_tokens_total'))} out\n"
        f"• Model: {MODEL}"
    )


def digest(state):
    b = metrics()
    p = metric_sum(b, "vllm:prompt_tokens_total")
    g = metric_sum(b, "vllm:generation_tokens_total")
    pp, pg = state.get("prev_prompt", p), state.get("prev_gen", g)
    dp = p - pp if p >= pp else p        # counters reset to 0 on restart
    dg = g - pg if g >= pg else g
    send(
        "📊 **maschinenraum — weekly digest**\n"
        f"• This week: {n(dp)} in / {n(dg)} out\n"
        f"• Lifetime: {n(p)} in / {n(g)} out\n"
        f"• GPU now: {gpu_line()}\n"
        f"• Model: {MODEL}"
    )
    state["prev_prompt"], state["prev_gen"] = p, g
    return state


def main():
    state = load_state()
    print("[notifier] started", flush=True)
    while True:
        now = datetime.now()
        today, week = now.strftime("%Y-%m-%d"), now.strftime("%Y-W%W")
        if now.hour >= 9 and state.get("last_health_day") != today:
            health()
            state["last_health_day"] = today
            save_state(state)
        if now.weekday() == 6 and now.hour >= 18 and state.get("last_digest_week") != week:
            state = digest(state)
            state["last_digest_week"] = week
            save_state(state)
        time.sleep(300)


if __name__ == "__main__":
    main()
