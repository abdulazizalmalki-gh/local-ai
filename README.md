# Local AI

One command. Any machine. A private, uncensored LLM served from your own box —
llama.cpp inference + Open WebUI, fully containerized, no login, no cloud.

```bash
./local-ai.sh
```

That's it. The script discovers what it's running on (OS, Docker, GPU), installs
Docker if it's missing, downloads the model, and boots the best possible
configuration for that machine. Windows (WSL2), Linux and macOS are all first-
class citizens.

## What you get

| Service | Image | Purpose |
|---------|-------|---------|
| `local-ai-llama-server` | `ghcr.io/ggml-org/llama.cpp:server[-cuda\|-vulkan]` | OpenAI-compatible LLM API (`:18080/v1`) |
| `local-ai-open-webui` | `ghcr.io/open-webui/open-webui:latest` | Chat UI, userless session (`:3000`) |

Everything binds to **127.0.0.1** on the host by default — nothing is exposed
to your LAN unless you opt in (see Security).

**Default model:** `huihui-ai/Huihui-Qwen3.5-2B-abliterated` — an
abliterated (uncensored) Qwen3.5-2B, quantized to Q4_K_M (~1.3 GB) by
[mradermacher](https://huggingface.co/mradermacher/Huihui-Qwen3.5-2B-abliterated-GGUF).
It is multimodal: the vision projector (mmproj) is loaded automatically when
present, so you can drop images into the chat.

## Quick start

```bash
git clone https://github.com/abdulazizalmalki-gh/local-ai.git && cd local-ai
./local-ai.sh                 # start (detects everything)
```

First run downloads the model (~1.3 GB) and the container images, so give it a
few minutes. Then open **http://localhost:3000** — no sign-up, no password.

```bash
./local-ai.sh status          # what's running & healthy
./local-ai.sh logs            # follow container logs
./local-ai.sh lan on|off      # expose Open WebUI to the LAN (0.0.0.0) / back to localhost
./local-ai.sh stop            # tear everything down (models are kept)
./local-ai.sh update          # pull the latest container images
./local-ai.sh detect          # show the detection plan without changing anything
```

### Headless / CI

Prompts never block automation: when stdin is not a terminal they auto-answer
with their default (and print what they assumed), so `./local-ai.sh start
</dev/null` completes without hanging. For explicit control use the `--yes`
flag or `LOCALAI_YES=1`:

```bash
./local-ai.sh --yes start      # auto-confirm every install prompt
LOCALAI_YES=1 ./local-ai.sh start
yes | ./local-ai.sh start      # equivalent, pipe-style
```

## How it works

On every `start`, the script:

1. **Detects the machine** — OS (Linux / WSL2 / macOS), CPU arch, GPU type.
2. **Ensures Docker** — if missing, installs it (`apt` / `dnf` / `pacman` /
   Homebrew), starts the daemon, and works around the docker-group permission
   dance automatically.
3. **Picks a GPU profile:**

   | Machine | Profile | llama.cpp image | Flags |
   |---------|---------|-----------------|-------|
   | NVIDIA GPU | `nvidia` | `server-cuda` | all layers on GPU, flash-attn, quantized KV cache, 16k ctx |
   | AMD / Intel GPU | `vulkan` | `server-vulkan` | same, via Vulkan |
   | Anything else | `cpu` | `server` | auto-threaded, 8k ctx |

4. **Fetches the model** if not already in `~/ai-models` (resumable download,
   size-verified; also grabs the mmproj vision projector).
5. **Boots the stack** via `docker compose` — llama-server first, Open WebUI
   linked to it over the internal `llama-backend` network alias.
   Compose v2 is installed automatically too, if Docker is present without it
   (package manager first: `apt`/`dnf`/`pacman`/Homebrew; official static
   binary download as the cross-distro fallback).
6. **Degrades gracefully** — if a GPU profile fails to come up (e.g. a card
   without working Vulkan drivers), it tears down and restarts on CPU
   automatically, and tells you about it.

## Platform notes

| Platform | Docker install | GPU support |
|----------|----------------|-------------|
| Linux (any distro) | `apt` / `dnf` / `pacman` | CUDA (NVIDIA), Vulkan (AMD/Intel), CPU |
| Windows (WSL2) | Docker Desktop, or `apt` inside WSL | CUDA (NVIDIA, via WSL drivers), CPU |
| macOS (Intel & Apple Silicon) | Docker Desktop via Homebrew | CPU (Docker containers cannot reach the Metal GPU — Apple Silicon runs the arm64 CPU build; fast enough for a 2B model) |

### NVIDIA prerequisites

- **Docker Desktop (macOS / WSL2):** GPU support works out of the box.
- **Native Linux:** Docker must have the `nvidia` runtime. If it doesn't, the
  script offers to install `nvidia-container-toolkit` (official NVIDIA repo);
  decline and it falls back to CPU.
- **Driver CUDA version:** the pinned `server-cuda` image is built on CUDA
  12.8, so your driver must support CUDA ≥ 12.8. Check with:

  ```bash
  nvidia-smi | grep -oE 'CUDA (UMD )?Version: [0-9.]+'
  # bare-metal: CUDA Version: 12.6      WSL2: CUDA UMD Version: 13.3
  ```

  The script parses that header line (handling both label variants) and
  fails fast with remedies — before any model or image download — instead of
  pulling gigabytes and then dying. Driver too old? Update it, or pin an
  older compatible image:

  ```bash
  LOCALAI_LLAMA_IMAGE_TAG=server-cuda-bXXXX ./local-ai.sh start
  ```

### Apple Silicon

Docker Desktop on macOS runs Linux containers in a VM — there is no Metal
passthrough, so the container uses the CPU. If you want Metal acceleration,
run `llama-server` natively on the host and point Open WebUI at it:

```bash
LOCALAI_OPENAI_BASE=http://host.docker.internal:18080/v1 ./local-ai.sh start
```

(the compose file is otherwise identical).

### Running on WSL2

- **Memory:** WSL2 gives the distro only ~50% of Windows RAM by default. The
  default model + context needs ~2-4 GB; the script warns when it detects less
  than 5 GB (a memory-starved distro OOM-crash-loops llama-server instead of
  failing cleanly). Raise the limit in `%UserProfile%\.wslconfig`:

  ```ini
  [wsl2]
  memory=6GB
  swap=2GB
  ```

  then run `wsl --shutdown`.
- **Idle shutdown:** WSL2 can shut the VM down when idle, killing the stack.
  Disable it with `vmIdleTimeout=-1` in the same `[wsl2]` section, or keep a
  keepalive process running.
- **NVIDIA:** works via WSL2 CUDA passthrough — install the NVIDIA driver on
  Windows and `nvidia-smi` appears inside the distro; Docker Desktop handles
  the rest.

## Configuration

Everything is overridable via environment variables, or a `.env` file in this
directory (docker compose reads it automatically; exported env vars win).

| Variable | Default | Purpose |
|----------|---------|---------|
| `LOCALAI_MODEL_REPO` | `mradermacher/Huihui-Qwen3.5-2B-abliterated-GGUF` | HF repo hosting the GGUF |
| `LOCALAI_MODEL_FILE` | `Huihui-Qwen3.5-2B-abliterated.Q4_K_M.gguf` | GGUF to serve |
| `LOCALAI_MODEL_ALIAS` | `Qwen3.5-2B-Abliterated (Uncensored)` | Name shown in Open WebUI / the API (`llama-server --alias`) |
| `LOCALAI_MMPROJ_FILE` | `Huihui-Qwen3.5-2B-abliterated.mmproj-Q8_0.gguf` | Vision projector |
| `LOCALAI_MMPROJ` | `1` | Set `0` to disable vision |
| `LOCALAI_MODEL_DIR` | `~/ai-models` | Where models live (mounted read-only) |
| `LOCALAI_LLAMA_PORT` | `18080` | llama.cpp API port (127.0.0.1 only) |
| `LOCALAI_WEBUI_PORT` | `3000` | Open WebUI port |
| `LOCALAI_WEBUI_BIND` | `127.0.0.1` | Open WebUI bind address. `0.0.0.0` = LAN-accessible (see Security) |
| `LOCALAI_WEBUI_AUTH` | `false` | Set `true` to require login on Open WebUI (userless by default) |
| `LOCALAI_OPENAI_BASE` | `http://llama-backend:18080/v1` | OpenAI-compatible base URL Open WebUI talks to (point at a native host server with `http://host.docker.internal:PORT/v1`) |
| `LOCALAI_CTX_GPU` / `LOCALAI_CTX_CPU` | `16384` / `8192` | Context size per profile |
| `LOCALAI_REASONING` | `off` | llama.cpp `--reasoning` mode. `off` = direct answers (default; the 2B model's thinking phase is very long); `on`/`auto` re-enables reasoning |
| `LOCALAI_LLAMA_IMAGE_TAG` | *(pinned)* | Override the llama.cpp image tag for the NVIDIA profile (e.g. `server-cuda-b4726`) to match older drivers; bypasses the CUDA pre-flight |
| `LOCALAI_YES` | `0` | Set `1` to auto-confirm every prompt (same as `--yes`) |
| `LOCALAI_FORCE` | *(auto)* | `cpu` \| `nvidia` \| `vulkan` — skip detection |
| `LOCALAI_API_KEY` | `local-ai` | Dummy key sent to llama.cpp (not a secret) |
| `LOCALAI_STATE_DIR` | `~/.local/share/local-ai` | Script state (last profile) |

Example — serve a different model:

```bash
LOCALAI_MODEL_FILE=My-Custom-Q5_K_M.gguf LOCALAI_MODEL_REPO=you/your-GGUF ./local-ai.sh start
```

## Without the script

The compose files work standalone — the script is just the smart entry point:

```bash
# CPU
docker compose --profile cpu up -d
# NVIDIA
docker compose --profile nvidia up -d
# AMD / Intel (Vulkan)
docker compose --profile vulkan up -d
# + vision projector (multimodal)
docker compose -f docker-compose.yaml -f docker-compose.vision.yaml --profile cpu up -d
```

## Security

- Every published port binds to **127.0.0.1** by default — nothing is exposed
  to your LAN unless you opt in.
- **LAN access is opt-in:** `./local-ai.sh lan on` rebinds Open WebUI to
  `0.0.0.0` (persisted in the local `.env`, gitignored); `./local-ai.sh lan
  off` reverts it. The llama.cpp API port stays on 127.0.0.1 either way.
  ⚠ Open WebUI runs **userless** (`LOCALAI_WEBUI_AUTH=false`) — on a LAN bind,
  anyone who can reach the port can use the model. Fine on a trusted home/office
  network; don't expose it to the internet, or require login by setting
  `LOCALAI_WEBUI_AUTH=true` in `.env`.
- The `OPENAI_API_KEY` is a dummy non-secret placeholder llama.cpp ignores.
- Telemetry is off (`ANONYMIZED_TELEMETRY=false`), Ollama integration is off.
- Models are mounted **read-only**; containers run as their image defaults.
- Nothing is ever bound to `0.0.0.0` on the host side unless you run
  `lan on` (the `--host 0.0.0.0` inside the container is required and safe —
  it only listens on the container's private network, reachable via the
  published port).

## Troubleshooting

- **`permission denied while trying to connect to the Docker daemon socket`** —
  your user isn't in the `docker` group yet (or Docker was just installed).
  The script falls back to `sudo` for the session; log out/in (or
  `newgrp docker`) to make it permanent.
- **GPU profile fell back to CPU** — run `./local-ai.sh detect` and check the
  GPU line. For NVIDIA on native Linux, install the toolkit (the script offers
  to) or set `LOCALAI_FORCE=nvidia` to retry. For Vulkan, your card/driver may
  not expose a working device to the container — CPU is the safe fallback.
- **Slow first start** — the script downloads the model and images on first
  boot; subsequent starts are fast.
- **`503 "Loading model"` from llama-server** — normal for the first seconds
  after start while the model loads; the healthcheck allows a 30 s start
  period, and the webui simply shows the model as loading.
- **Disk space** — model ~1.3 GB (Q4_K_M) + ~0.4 GB mmproj + container images
  (~4 GB). Keep ~6 GB free.
- **WSL2 GPU** — you need NVIDIA drivers *on Windows* (they expose `nvidia-smi`
  inside WSL). Docker Desktop handles the rest.

## License

MIT — see [LICENSE](LICENSE).
