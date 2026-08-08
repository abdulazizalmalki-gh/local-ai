# AGENTS.md

Guidance for AI agents (and humans) working on this repository.

## What this project is

A self-hosted, fully-containerized local LLM stack: a llama.cpp inference
server (`llama-server`) plus a userless Open WebUI chat UI. The core idea is
**machine agnosticism** — the same `./local-ai.sh` bootstraps itself on Linux,
Windows (WSL2), and macOS, discovers Docker (installing it if needed) and the
GPU, and picks the best llama.cpp container image and flags for the hardware it
finds. GPU failures degrade to CPU automatically.

The default model is `mradermacher/Huihui-Qwen3.5-2B-abliterated-GGUF`
(abliterated Qwen3.5-2B, Q4_K_M + optional mmproj vision projector).

## File layout

| File | Role |
|------|------|
| `local-ai.sh` | **The entry point.** All detection, Docker install, model download, profile selection, and fallback logic. `start` is the default command. |
| `docker-compose.yaml` | The stack manifest. Three llama-server service variants (profiles `cpu`, `nvidia`, `vulkan`) + `open-webui`. One profile is active at a time; the script selects it. |
| `docker-compose.vision.yaml` | Optional override that adds `--mmproj` to llama-server by overriding its `entrypoint` (the base `command` is still appended by Docker — nothing is duplicated). |
| `README.md` | User-facing docs: quick start, platform matrix, env-var table, troubleshooting. |
| `.gitignore` | Ignores `.env` — machine-local settings (`lan on`, etc.) never get committed. |
| `LICENSE` | MIT. |

No `mac-setup.sh` — the old native-Metal macOS path was removed when the
project went fully container-based. `local-ai.sh` is the only entry point.

## Architecture & boot flow (`local-ai.sh start`)

1. **Detect** — `OS` (Linux/Darwin), WSL2 flag (`/proc/version` grep), arch.
2. **`ensure_docker`** — if the `docker` binary is missing: `apt`/`dnf`/`pacman`
   on Linux, Homebrew cask on macOS (prompts first). Starts the daemon
   (`systemctl` → `service` fallback). If the user lacks docker-group
   permissions, `DOCKER_CMD` becomes `sudo docker` for the whole run.
3. **`ensure_compose`** (inside `ensure_docker`) — if `docker compose` (v2) is
   missing, installs it the same way Docker itself is installed: package
   manager (`apt` docker-compose-v2/plugin, `dnf` docker-compose-plugin,
   `pacman` docker-compose, Homebrew formula), then the official static binary
   from github.com/docker/compose releases into the docker CLI plugins dir as
   the cross-distro fallback (`install_compose_binary`). Dies with manual
   instructions only if the user declines every install option.
4. **`detect_profile`** — `nvidia-smi -L` → `nvidia`; `/dev/dri` or `/dev/kfd`
   → `vulkan`; else `cpu`. `LOCALAI_FORCE` overrides.
   `ensure_nvidia_runtime` verifies the Docker `nvidia` runtime exists and can
   offer to install `nvidia-container-toolkit` (official NVIDIA repo) on apt
   systems; declines degrade to CPU.
5. **`check_cuda_driver`** (nvidia profile only) — reads the driver's CUDA
   version (`nvidia-smi --query-gpu=driver_version,cuda_version`) and fails
   fast with remedies when it's below `REQUIRED_CUDA` (constant at the top of
   the script — bump it whenever the `server-cuda` image tag's CUDA base is
   bumped; `LOCALAI_LLAMA_IMAGE_TAG` pins a tag and bypasses the check).
   **`check_wsl_memory`** — on WSL2, warns when the distro has < 5 GB RAM
   (OOM crash-loop risk) and prints the `.wslconfig` remedy.
6. **`ensure_model`** — curl-only download (no `hf` CLI, no `jq`): checks the
   remote file exists (HTTP 200), compares `Content-Length` against the local
   file, resumes with `curl -C -` when partial, re-downloads on mismatch.
   Also fetches the mmproj projector.
7. **Compose up** — exports `LOCALAI_MODEL_DIR`, `LOCALAI_MODEL_FILE`,
   `LOCALAI_CTX` (16384 GPU / 8192 CPU), `LOCALAI_API_KEY`, then
   `docker compose -f docker-compose.yaml -f [docker-compose.vision.yaml] --profile <p> up -d`.
   Vision override is added only when the mmproj file exists on disk and
   `LOCALAI_MMPROJ != 0`. Last profile is recorded in
   `$LOCALAI_STATE_DIR/profile` (default `~/.local/share/local-ai/`).
8. **`wait_for_stack`** — waits for llama-server (`/health`, up to 300 s,
   watching for `exited|dead|restarting`) **and** Open WebUI (its own
   healthcheck, up to 240 s). A GPU-profile failure degrades to `cpu` and
   retries; only a fully healthy stack prints the "running" banner — otherwise
   `dump_logs` (tail of both containers) runs and the script exits non-zero.

## Conventions (keep these when editing)

- **Bash entry point only.** All machine logic lives in `local-ai.sh`; compose
  files stay declarative and env-driven (`${VAR:-default}` interpolation).
- **`127.0.0.1` binds are the default.** Published ports are loopback-only
  (`127.0.0.1:<port>:<container>`); the webui bind is configurable via
  `LOCALAI_WEBUI_BIND` and the `./local-ai.sh lan on|off` command (persisted
  in a gitignored `.env`). Never flip a default bind to `0.0.0.0` in the
  committed files — LAN exposure must stay an explicit, documented opt-in.
  The llama.cpp API port has no LAN toggle by design.
- **No secrets in the repo.** `OPENAI_API_KEY` is a documented dummy
  (`local-ai`); llama.cpp ignores it. Never add real credentials.
- **No new runtime deps.** The script is stdlib-only: `curl`, `grep`, `awk`,
  `sed`, `stat`, `numfmt` (with graceful fallback on macOS, which lacks
  `numfmt` and `nproc` — the detect command uses `sysctl -n hw.ncpu` there;
  `hostname` is used only for the best-effort LAN hint). Do not introduce
  `jq`, `yq`, or Python.
- **WebUI settings stay env-interpolated** (`LOCALAI_WEBUI_BIND`,
  `LOCALAI_WEBUI_PORT`, `LOCALAI_WEBUI_AUTH`, `LOCALAI_OPENAI_BASE`,
  `LOCALAI_API_KEY`) — the compose file's defaults are the secure/standard
  ones, and users override via env or `.env`. New webui settings must follow
  the same `${VAR:-default}` pattern, and every documented variable needs a
  README env-table row.
- **YAML command lists need quoted scalars.** In `command:` lists, `18080`,
  `1`, `999`, and `on` must stay quoted (`"18080"`) or compose rejects them
  as ints/bools. Any new flag value that looks numeric or boolean must be
  quoted.
- **All prompts go through `confirm()`.** Every interactive question routes
  through the `confirm` helper: it honors `-y`/`--yes`/`LOCALAI_YES=1` and,
  when stdin is not a TTY, auto-answers with the documented default and prints
  what it assumed. Never add a bare `read -r -p` — automation must never
  block. New prompts must pick a sensible default (install-style = `y`,
  risky/optional = `n`).
- **Sync `docker-compose.yaml` and `docker-compose.vision.yaml`.** The vision
  override references the exact service names (`llama-cpu`, `llama-nvidia`,
  `llama-vulkan`) and the image's entrypoint `/app/llama-server`, and now also
  passes `--image-min-tokens 1024` (Qwen-VL grounding fix). Adding a profile
  or changing service names without updating the override silently breaks
  vision.
- **Shared server flags** (`--model`, `--host`, `--port`, `--ctx-size`,
  `--alias`, `--reasoning`, `--parallel`) appear in every profile and stay in
  sync; `--alias` (env `LOCALAI_MODEL_ALIAS`) is what the API/Open WebUI
  display instead of the raw GGUF path.
- **GPU profile flags** (`--n-gpu-layers 999 --flash-attn on --cache-type-k
  q4_0 --cache-type-v q4_0 --ctx-size 16384`) belong to the GPU profiles;
  the CPU profile omits flash-attn and uses 8192 ctx. New tuning flags should
  follow the same split. `--reasoning off` is a deliberate default on all
  profiles: the 2B model's thinking phase burns thousands of tokens before any
  answer, which is a terrible chat UX — `LOCALAI_REASONING=on` restores it.
- **Container names are fixed** (`local-ai-llama-server`,
  `local-ai-open-webui`) so the script can `docker inspect` / stop them
  regardless of profile. Consequence: switching profiles while a stack from a
  different profile is running makes `up` hit a name conflict — cmd_start's
  retry handles it with a full-project `down` (all three profiles) before
  retrying.

## Verification checklist

Before claiming a change works:

```bash
bash -n local-ai.sh                          # syntax
./local-ai.sh detect                         # detection path on this machine
./local-ai.sh --yes detect                   # flag parsing works
./local-ai.sh detect </dev/null              # non-interactive: no hang

# compose validity for every profile (+ vision merge + tag override):
for p in cpu nvidia vulkan; do
  docker compose -f docker-compose.yaml --profile "$p" config --quiet
done
docker compose -f docker-compose.yaml -f docker-compose.vision.yaml --profile cpu config --quiet
LOCALAI_LLAMA_IMAGE_TAG=server-cuda-b4726 docker compose -f docker-compose.yaml --profile nvidia config --quiet

# version_ge sanity (the CUDA pre-flight comparator):
version_ge() { awk -v a="$1" -v b="$2" 'BEGIN{gsub(/[^0-9.]/,"",a);gsub(/[^0-9.]/,"",b);na=split(a,aa,".");nb=split(b,bb,".");n=(na>nb?na:nb);for(i=1;i<=n;i++){va=(i<=na?aa[i]+0:0);vb=(i<=nb?bb[i]+0:0);if(va>vb)exit 0;if(va<vb)exit 1}exit 0}'; }
version_ge 12.8 12.8 && echo "12.8>=12.8 ok"; version_ge 12.6 12.8 && echo "BAD" || echo "12.6<12.8 ok"; version_ge 13.0 12.8 && echo "13.0>=12.8 ok"

# end-to-end (CPU machine: exercises the GPU→CPU fallback path):
./local-ai.sh start
./local-ai.sh status
curl http://127.0.0.1:18080/health           # {"status":"ok",...}
curl http://127.0.0.1:18080/v1/models        # expect name/model = "Qwen3.5-2B-Abliterated (Uncensored)"
docker logs local-ai-llama-server 2>&1 | grep -c "image-min-tokens\|Qwen-VL"  # vision warning gone
./local-ai.sh lan on                         # webui on 0.0.0.0:3000 (llama stays 127.0.0.1)
docker port local-ai-open-webui              # expect 0.0.0.0:3000
./local-ai.sh lan off                        # back to loopback
./local-ai.sh stop
```

The exit code of `start` is the health verdict: 0 only when both containers
came up healthy; any failure dumps logs and exits non-zero.

Force-test individual profiles with `LOCALAI_FORCE=nvidia|vulkan|cpu`
(`detect` prints the profile it would choose). On a machine with a working
NVIDIA setup, `LOCALAI_FORCE=nvidia ./local-ai.sh start` must come up healthy
with `nvidia-smi` visible inside the container
(`docker exec local-ai-llama-server nvidia-smi -L`).

**Never exercise host-mutating paths on a real machine** — the Docker install,
compose auto-install, and nvidia-toolkit prompts run real package-manager
transactions (apt can pull unrelated upgrades as dependencies, as happened with
docker-ce once). Test those in a disposable VM/container; on the host, only the
already-installed happy path is safe to run.

## Platform gotchas baked into the code

- macOS: `stat -f%z` (BSD) vs `stat -c%s` (GNU); `numfmt` missing → fallback.
- WSL2: no `systemd` by default → `service docker start` fallback; `nvidia-smi`
  present only when NVIDIA Windows drivers are installed. Distro RAM defaults
  to ~50% of Windows RAM → `check_wsl_memory` warns below 5 GB
  (OOM-crash-loops; remedy is `.wslconfig`).
- **NVIDIA driver vs image CUDA mismatch**: `server-cuda` is built on CUDA
  12.8.1 (cuda.Dockerfile `ARG CUDA_VERSION`); an older driver makes the
  container die at start with `nvidia-container-cli: ... cuda>=12.8 ...`
  AFTER gigabytes of downloads — hence `check_cuda_driver` failing fast, and
  `LOCALAI_LLAMA_IMAGE_TAG` for pinning an older image.
- Open WebUI's image ships its own healthcheck (`curl /health | jq`), which
  `wait_for_webui` polls — the webui container takes 30-90 s to become
  healthy on first boot.
- Docker Desktop (macOS/WSL2) ships the `nvidia` runtime; native Linux often
  needs `nvidia-container-toolkit` — hence the prompt in
  `ensure_nvidia_runtime`.
- Apple Silicon: containers cannot reach Metal; the arm64 CPU build is the
  ceiling for the containerized path. Documented, not "fixed".
- **`group_add: [video, render]` is forbidden** — hosts without a `render`
  group (verified in the wild) fail container start with "unable to find group
  render". The llama.cpp images run as root, so group_add is unnecessary;
  pass `devices: [/dev/dri]` only.
- **llama-server logs to stderr**, and `docker logs` maps container stderr to
  the CLI's stderr. When grepping container logs (e.g. the `no usable GPU
  found` fallback probe), capture with `2>&1`; also grep a captured variable
  rather than piping `grep -q` (early-exit SIGPIPE trips `pipefail`).
- **A GPU profile can be "healthy" without a usable GPU**: llama-server prints
  `warning: no usable GPU found` and silently runs on CPU. The boot flow must
  grep the logs for that string after the health check, not just check
  container state, or the machine ends up on a fake GPU profile.
- The default model is a thinking model; without `--reasoning off` it spends
  1000+ tokens in `reasoning_content` before any answer (and Open WebUI shows
  an empty reply). This is why `--reasoning off` is baked into every profile.
