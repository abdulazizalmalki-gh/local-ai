#!/usr/bin/env bash
#
# Local AI — one command, any machine.
#
#   Boots a llama.cpp inference container + a userless Open WebUI on
#   Linux, Windows (WSL2) or macOS. At startup it discovers what it is
#   running on: OS, Docker availability, and GPU type — then picks the
#   best llama.cpp container image and flags for that machine.
#
#   NVIDIA GPU  -> ghcr.io/ggml-org/llama.cpp:server-cuda   (CUDA)
#   AMD/Intel   -> ghcr.io/ggml-org/llama.cpp:server-vulkan (Vulkan)
#   CPU only    -> ghcr.io/ggml-org/llama.cpp:server        (fallback)
#
#   If Docker is missing it installs it (apt / dnf / pacman / brew).
#   If a GPU profile fails at runtime it falls back to CPU automatically.
#   On Apple Silicon macOS it uses the native MLX backend (Metal) for max
#   performance instead of the Docker CPU container (LOCALAI_BACKEND=docker
#   forces the containerized path; Intel Macs always use Docker).
#
#   Usage:
#     ./local-ai.sh [command]
#
#   Commands:
#     start    (default) detect machine, ensure docker, fetch the model,
#              spin up llama.cpp + Open WebUI
#     stop     tear everything down (containers, network)
#     restart  stop + start
#     status   show what is running and healthy
#     logs     follow container logs
#     update   pull the latest container images
#     lan      toggle LAN access for Open WebUI (on | off | status)
#     detect   print the hardware/docker detection plan (no changes)
#     help     this message
#
#   Flags:
#     -y, --yes   auto-confirm every prompt (equivalent: LOCALAI_YES=1).
#                 When stdin is not a terminal, prompts auto-default anyway.
#
#   Configuration is read from environment variables or a .env file in
#   this directory. See README.md for the full table.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (env-overridable)
# ---------------------------------------------------------------------------
MODEL_REPO="${LOCALAI_MODEL_REPO:-mradermacher/Huihui-Qwen3.5-2B-abliterated-GGUF}"
MODEL_FILE="${LOCALAI_MODEL_FILE:-Huihui-Qwen3.5-2B-abliterated.Q4_K_M.gguf}"
MMPROJ_FILE="${LOCALAI_MMPROJ_FILE:-Huihui-Qwen3.5-2B-abliterated.mmproj-Q8_0.gguf}"
MODEL_DIR="${LOCALAI_MODEL_DIR:-$HOME/ai-models}"
LLAMA_PORT="${LOCALAI_LLAMA_PORT:-18080}"
WEBUI_PORT="${LOCALAI_WEBUI_PORT:-3000}"
CTX_GPU="${LOCALAI_CTX_GPU:-16384}"
CTX_CPU="${LOCALAI_CTX_CPU:-8192}"
API_KEY="${LOCALAI_API_KEY:-local-ai}"
FORCE_PROFILE="${LOCALAI_FORCE:-}"          # cpu | nvidia | vulkan
MMPROJ_ENABLED="${LOCALAI_MMPROJ:-1}"       # 1 = auto (on if file exists), 0 = off
# CUDA version required by the pinned server-cuda image (cuda.Dockerfile's
# ARG CUDA_VERSION). Bump this whenever the image tag's CUDA base is bumped.
# LOCALAI_LLAMA_IMAGE_TAG overrides the tag and bypasses this check.
REQUIRED_CUDA="${LOCALAI_REQUIRED_CUDA:-12.8}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yaml"
VISION_COMPOSE_FILE="$PROJECT_DIR/docker-compose.vision.yaml"
STATE_DIR="${LOCALAI_STATE_DIR:-$HOME/.local/share/local-ai}"

# --- MLX backend (Apple Silicon) ---
BACKEND="${LOCALAI_BACKEND:-auto}"            # auto | mlx | docker
MLX_MODEL="${LOCALAI_MLX_MODEL:-Giniiki/Huihui-Qwen3.5-2B-abliterated-mlx-4bit}"
MLX_REASONING="${LOCALAI_MLX_REASONING:-off}" # off = disable thinking (enable_thinking=false)
MLX_VENV_DIR="${LOCALAI_MLX_VENV:-$STATE_DIR/mlx-venv}"
MLX_LOG="$STATE_DIR/mlx-server.log"
MLX_PID_FILE="$STATE_DIR/mlx-server.pid"
MLX_MODEL_PATH=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""
fi
info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}!! ${NC}$*" >&2; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# Ask a yes/no question. $1 = prompt, $2 = default (y|n). Returns 0 = yes.
# Never blocks: --yes/LOCALAI_YES=1 force the default; a non-TTY stdin also
# auto-answers with the default and prints what it assumed.
confirm() {
  local prompt="$1" default="${2:-y}" ans
  if [ "$YES_MODE" = "1" ]; then
    [ "$default" = "y" ] && return 0 || return 1
  fi
  if [ ! -t 0 ]; then
    echo "[non-interactive] $prompt -> assuming '$default'" >&2
    [ "$default" = "y" ] && return 0 || return 1
  fi
  local hint; [ "$default" = "y" ] && hint="Y/n" || hint="y/N"
  read -r -p "$prompt [$hint] " ans
  case "${ans:-$default}" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Machine detection
# ---------------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
WSL=0
if [ "$OS" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then WSL=1; fi

is_macos() { [ "$OS" = "Darwin" ]; }
is_linux() { [ "$OS" = "Linux" ]; }
is_wsl()   { [ "$WSL" = 1 ]; }

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Set/update a KEY=VALUE line in the project .env (portable, no sed -i).
set_env() {
  local key="$1" val="$2" f="$PROJECT_DIR/.env"
  touch "$f"
  grep -v "^${key}=" "$f" > "$f.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >> "$f.tmp"
  mv "$f.tmp" "$f"
}

current_webui_bind() {
  local v
  if [ -n "${LOCALAI_WEBUI_BIND:-}" ]; then
    v="$LOCALAI_WEBUI_BIND"   # shell env wins over .env, mirroring compose
  else
    v="$(grep '^LOCALAI_WEBUI_BIND=' "$PROJECT_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
  fi
  echo "${v:-127.0.0.1}"
}

# ---------------------------------------------------------------------------
# Docker discovery / installation
# ---------------------------------------------------------------------------
DOCKER_CMD=(docker)

docker_ok() { "${DOCKER_CMD[@]}" info >/dev/null 2>&1; }

wait_for_docker() {
  local deadline=$((SECONDS + 180))
  while [ $SECONDS -lt $deadline ]; do
    if docker_ok; then info "Docker daemon is up."; return 0; fi
    sleep 3
  done
  return 1
}

install_docker_linux() {
  if command -v apt-get >/dev/null 2>&1; then
    confirm "Docker not found. Install it with apt (docker.io + compose plugin)?" y || die "Aborted. Install Docker manually, then re-run."
    run_sudo apt-get update -y
    run_sudo apt-get install -y docker.io
    run_sudo apt-get install -y docker-compose-v2 2>/dev/null \
      || run_sudo apt-get install -y docker-compose-plugin 2>/dev/null \
      || warn "Compose v2 plugin not found in apt. Install Docker Compose v2 manually."
  elif command -v dnf >/dev/null 2>&1; then
    confirm "Docker not found. Install it with dnf (docker + compose plugin)?" y || die "Aborted. Install Docker manually, then re-run."
    run_sudo dnf install -y docker docker-compose-plugin
  elif command -v pacman >/dev/null 2>&1; then
    confirm "Docker not found. Install it with pacman (docker + compose)?" y || die "Aborted. Install Docker manually, then re-run."
    run_sudo pacman -S --noconfirm docker docker-compose
  else
    die "Unsupported package manager. Install Docker yourself (see README), then re-run."
  fi

  # Start the daemon (systemd where available, init script otherwise — WSL2
  # without systemd falls into the second branch).
  run_sudo systemctl enable --now docker 2>/dev/null \
    || run_sudo service docker start 2>/dev/null \
    || warn "Could not auto-start the Docker daemon — start it manually."

  # Let the current user talk to the daemon without sudo (effective next login).
  run_sudo usermod -aG docker "$USER" 2>/dev/null || true
}

install_docker_macos() {
  command -v brew >/dev/null 2>&1 \
    || die "Homebrew is required to install Docker on macOS: https://brew.sh"
  confirm "Docker not found. Install Docker Desktop via Homebrew?" y || die "Aborted. Install Docker Desktop manually, then re-run."
  brew install --cask docker
  open -a Docker
  info "Waiting for Docker Desktop to start..."
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if is_macos; then install_docker_macos; else install_docker_linux; fi
  fi

  if ! docker_ok; then
    if is_macos; then
      open -a Docker
      info "Waiting for Docker Desktop..."
    elif is_linux; then
      warn "Docker is installed but the daemon is not running — starting it."
      run_sudo systemctl start docker 2>/dev/null \
        || run_sudo service docker start 2>/dev/null \
        || true
    fi
    wait_for_docker || die "Cannot reach the Docker daemon. Start Docker and re-run."
  fi

  # User not in the docker group (e.g. freshly installed): fall back to sudo.
  if ! docker_ok; then
    if sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
      warn "Using 'sudo docker' for this run (your user is not in the docker group yet)."
      warn "Log out/in once, or run: newgrp docker"
    else
      die "Cannot talk to the Docker daemon (permission denied). Add yourself to the docker group: sudo usermod -aG docker \$USER"
    fi
  fi

  if ! "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
    ensure_compose
  fi
}

# ---------------------------------------------------------------------------
# Docker Compose v2 discovery / installation
# ---------------------------------------------------------------------------
# Docker pre-installed without the compose plugin is common (bare docker.io,
# custom installs). Install it the same way we install Docker itself: package
# manager first, official binary download as the cross-distro fallback.
ensure_compose() {
  info "Docker Compose v2 ('docker compose') is missing — installing it."
  local installed=0

  if is_macos; then
    if command -v brew >/dev/null 2>&1; then
      confirm "Install docker-compose via Homebrew?" y && brew install docker-compose && installed=1
    else
      warn "Docker Desktop bundles Compose v2; Homebrew is required for a standalone install."
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    if confirm "Install the Docker Compose plugin via apt?" y; then
      run_sudo apt-get install -y docker-compose-v2 2>/dev/null \
        || run_sudo apt-get install -y docker-compose-plugin 2>/dev/null \
        || true
      "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 && installed=1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    confirm "Install the Docker Compose plugin via dnf?" y && run_sudo dnf install -y docker-compose-plugin && installed=1
  elif command -v pacman >/dev/null 2>&1; then
    confirm "Install docker-compose via pacman?" y && run_sudo pacman -S --noconfirm docker-compose && installed=1
  fi

  if [ "$installed" != 1 ]; then
    confirm "Download the official docker compose binary from GitHub?" y && install_compose_binary && installed=1
  fi

  [ "$installed" = 1 ] \
    || die "Docker Compose v2 is required. Install it manually (see README), then re-run."
}

# Official static binary -> docker CLI plugin dir (works on any Linux distro).
install_compose_binary() {
  local arch
  case "$ARCH" in
    x86_64|amd64)          arch="x86_64" ;;
    aarch64|arm64)         arch="aarch64" ;;
    *) warn "No prebuilt compose binary for arch '$ARCH'."; return 1 ;;
  esac
  local url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
  local dest="/usr/local/lib/docker/cli-plugins/docker-compose"
  info "Downloading docker compose ($arch) to $dest ..."
  curl -fsSL --retry 3 --retry-delay 2 -o /tmp/docker-compose-bin "$url" || { warn "Download failed."; return 1; }
  run_sudo mkdir -p "$(dirname "$dest")"
  run_sudo mv /tmp/docker-compose-bin "$dest"
  run_sudo chmod +x "$dest"
  "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# GPU discovery -> compose profile
# ---------------------------------------------------------------------------
detect_profile() {
  if [ -n "$FORCE_PROFILE" ]; then
    case "$FORCE_PROFILE" in
      cpu|nvidia|vulkan) echo "$FORCE_PROFILE"; return ;;
      *) die "LOCALAI_FORCE must be one of: cpu, nvidia, vulkan (got '$FORCE_PROFILE')" ;;
    esac
  fi

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    echo "nvidia"; return
  fi

  if ls /dev/dri 2>/dev/null | grep -qE '^(card|renderD)' || [ -e /dev/kfd ]; then
    echo "vulkan"; return
  fi

  echo "cpu"
}

# NVIDIA GPUs need the nvidia-container-toolkit so Docker can hand the GPU to
# a container. Docker Desktop (macOS / WSL2) ships this; native Linux often
# does not — offer to install it, otherwise degrade to CPU.
ensure_nvidia_runtime() {
  if "${DOCKER_CMD[@]}" info --format '{{json .Runtimes}}' 2>/dev/null | grep -qi '"nvidia"'; then
    return 0
  fi
  if is_linux && command -v apt-get >/dev/null 2>&1; then
    if confirm "NVIDIA GPU found, but Docker cannot use it yet. Install nvidia-container-toolkit?" n; then
      info "Installing nvidia-container-toolkit (official NVIDIA repo)..."
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | run_sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
      curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | run_sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
      run_sudo apt-get update -y
      run_sudo apt-get install -y nvidia-container-toolkit
      run_sudo nvidia-ctk runtime configure --runtime=docker
      run_sudo systemctl restart docker 2>/dev/null || run_sudo service docker restart 2>/dev/null || true
      info "nvidia-container-toolkit installed. Re-checking the Docker runtime..."
      sleep 3
      "${DOCKER_CMD[@]}" info --format '{{json .Runtimes}}' 2>/dev/null | grep -qi '"nvidia"' && return 0
    fi
    warn "Falling back to the CPU profile (set LOCALAI_FORCE=nvidia to retry)."
  else
    warn "NVIDIA GPU detected but the Docker 'nvidia' runtime is not available on this host."
    warn "Falling back to the CPU profile."
  fi
  return 1
}

# Numeric dotted compare (portable awk): $1 >= $2
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    gsub(/[^0-9.]/,"",a); gsub(/[^0-9.]/,"",b);
    na=split(a,aa,"."); nb=split(b,bb,".");
    n=(na>nb?na:nb);
    for(i=1;i<=n;i++){
      va=(i<=na?aa[i]+0:0); vb=(i<=nb?bb[i]+0:0);
      if(va>vb) exit 0
      if(va<vb) exit 1
    }
    exit 0
  }'
}

# Fail fast — before any model download or image pull — when the NVIDIA
# driver is too old for the pinned server-cuda image. Skipped when the user
# pinned an image tag themselves (LOCALAI_LLAMA_IMAGE_TAG).
check_cuda_driver() {
  [ -n "${LOCALAI_LLAMA_IMAGE_TAG:-}" ] && return 0
  command -v nvidia-smi >/dev/null 2>&1 \
    || { warn "nvidia-smi not found; skipping the CUDA pre-flight check."; return 0; }
  local line driver cuda
  # The CUDA version is only present in the header block, and the label
  # differs between bare-metal ("CUDA Version:") and WSL2 ("CUDA UMD
  # Version:") — there is no queryable cuda_version field.
  line="$(nvidia-smi 2>/dev/null | grep -m1 -oE 'CUDA (UMD )?Version: [0-9]+\.[0-9]+' || true)"
  cuda="${line##*Version: }"
  if [ -z "$cuda" ]; then
    warn "Could not read the CUDA version from nvidia-smi; skipping the pre-flight check."
    return 0
  fi
  # driver version is still queryable; used only in the error message
  driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  if version_ge "$cuda" "$REQUIRED_CUDA"; then
    info "CUDA driver OK (CUDA $cuda >= required $REQUIRED_CUDA)."
    return 0
  fi
  error "NVIDIA driver too old for the pinned llama.cpp CUDA image."
  echo "    Required: CUDA >= $REQUIRED_CUDA  (ghcr.io/ggml-org/llama.cpp:server-cuda)"
  echo "    You have: CUDA $cuda  (driver ${driver:-n/a})"
  echo "    Remedies:"
  echo "      - update your NVIDIA driver to one supporting CUDA $REQUIRED_CUDA or newer, or"
  echo "      - pin an older compatible image:  LOCALAI_LLAMA_IMAGE_TAG=server-cuda-bXXXX ./local-ai.sh start"
  echo "      - or run on CPU:                  LOCALAI_FORCE=cpu ./local-ai.sh start"
  return 1
}

# WSL2 gives the distro ~50% of Windows RAM by default; a memory-starved
# distro OOM-crash-loops llama-server instead of failing cleanly.
check_wsl_memory() {
  [ "$WSL" = 1 ] || return 0
  local total_mb
  total_mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
  [ -n "$total_mb" ] || return 0
  local total_g=$((total_mb / 1024))
  if [ "$total_mb" -lt 5120 ]; then
    warn "WSL2 has only ${total_g} GB of RAM for this distro (default: ~50% of Windows RAM)."
    warn "The default model + context needs ~2-4 GB; OOM-crash-loops are likely."
    warn "Raise the limit in %UserProfile%\\.wslconfig:"
    warn "  [wsl2]"
    warn "  memory=6GB"
    warn "  swap=2GB"
    warn "then run: wsl --shutdown"
  else
    info "WSL2 memory: ${total_g} GB available."
  fi
}

# ---------------------------------------------------------------------------
# MLX backend (Apple Silicon only)
# ---------------------------------------------------------------------------
# Docker containers cannot reach the Metal GPU on macOS, so on Apple Silicon
# the script runs mlx-lm natively on the host (Metal via MLX) and keeps Open
# WebUI in Docker, pointed at the host server via host.docker.internal.
detect_backend() {
  if [ "$BACKEND" = "mlx" ] \
    || { [ "$BACKEND" = "auto" ] && is_macos && [ "$ARCH" = "arm64" ]; }; then
    echo "mlx"
  else
    echo "docker"
  fi
}

ensure_mlx_env() {
  if ! is_macos || [ "$ARCH" != "arm64" ]; then
    die "The MLX backend requires Apple Silicon (macOS arm64). Use LOCALAI_BACKEND=docker here, or run on an M-series Mac."
  fi
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required for the MLX backend (install via Homebrew or Xcode CLT)."
  if [ ! -x "$MLX_VENV_DIR/bin/mlx_lm.server" ]; then
    confirm "MLX backend needs a Python venv with mlx-lm (pip install mlx-lm). Set it up?" y \
      || die "Aborted. Set up mlx-lm manually, then re-run."
    info "Creating MLX venv at $MLX_VENV_DIR ..."
    python3 -m venv "$MLX_VENV_DIR"
    "$MLX_VENV_DIR/bin/pip" install -q --upgrade pip
    "$MLX_VENV_DIR/bin/pip" install -q mlx mlx-lm || die "pip install mlx-lm failed."
  fi
}

ensure_mlx_model() {
  # LOCALAI_MLX_MODEL may already be a local directory
  if [ -d "$MLX_MODEL" ]; then
    MLX_MODEL_PATH="$MLX_MODEL"
    return 0
  fi
  local dir_name="${MLX_MODEL##*/}"
  MLX_MODEL_PATH="$MODEL_DIR/mlx/$dir_name"
  if [ -f "$MLX_MODEL_PATH/config.json" ] && [ -f "$MLX_MODEL_PATH/model.safetensors.index.json" ]; then
    info "MLX model already present ($MLX_MODEL_PATH)."
    return 0
  fi
  info "Downloading MLX model '$MLX_MODEL' to $MLX_MODEL_PATH ..."
  mkdir -p "$MODEL_DIR/mlx"
  "$MLX_VENV_DIR/bin/python" - "$MLX_MODEL" "$MLX_MODEL_PATH" <<'PYEOF'
import sys
import huggingface_hub
huggingface_hub.snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])
PYEOF
  info "MLX model downloaded."
}

mlx_start() {
  ensure_docker          # Open WebUI still runs in Docker
  ensure_mlx_env
  ensure_mlx_model

  if [ -f "$MLX_PID_FILE" ] && kill -0 "$(cat "$MLX_PID_FILE")" 2>/dev/null; then
    warn "MLX server already running (PID $(cat "$MLX_PID_FILE"))."
  else
    info "Starting MLX server (Metal) with $MLX_MODEL on 127.0.0.1:$LLAMA_PORT ..."
    local kwargs="" args
    [ "$MLX_REASONING" = "off" ] && kwargs='{"enable_thinking": false}'
    args=("$MLX_VENV_DIR/bin/mlx_lm.server" --model "$MLX_MODEL_PATH" \
          --host 127.0.0.1 --port "$LLAMA_PORT")
    [ -n "$kwargs" ] && args+=(--chat-template-kwargs "$kwargs")
    nohup "${args[@]}" >"$MLX_LOG" 2>&1 &
    echo $! > "$MLX_PID_FILE"
  fi
  if ! wait_for_llama mlx; then
    tail -30 "$MLX_LOG" >&2 2>/dev/null || true
    die "MLX server failed to start. See $MLX_LOG"
  fi

  mkdir -p "$STATE_DIR"
  echo mlx > "$STATE_DIR/backend"
  echo webui > "$STATE_DIR/profile"
  echo 0 > "$STATE_DIR/vision"

  info "Starting Open WebUI (Docker) linked to the native MLX server..."
  export LOCALAI_OPENAI_BASE="http://host.docker.internal:$LLAMA_PORT/v1"
  export LOCALAI_MODEL_DIR LOCALAI_MODEL_FILE LOCALAI_API_KEY
  if ! "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile webui up -d; then
    "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile webui logs --tail=50 local-ai-open-webui 2>/dev/null || true
    die "Open WebUI failed to start."
  fi
  wait_for_webui || { dump_logs; die "Open WebUI failed to become healthy."; }
  print_urls
}

mlx_stop() {
  ensure_docker
  if [ -f "$MLX_PID_FILE" ] && kill -0 "$(cat "$MLX_PID_FILE")" 2>/dev/null; then
    kill "$(cat "$MLX_PID_FILE")" 2>/dev/null || true
    info "MLX server stopped."
  fi
  rm -f "$MLX_PID_FILE"
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile webui down 2>/dev/null || true
  info "Stopped. Model files in $MODEL_DIR are kept."
}

# ---------------------------------------------------------------------------
# Model management (curl-only, resumable, size-verified)
# ---------------------------------------------------------------------------
http_code() { curl -sL -o /dev/null -w '%{http_code}' --max-time 30 "$1"; }

file_size() {
  if is_macos; then stat -f%z "$1" 2>/dev/null; else stat -c%s "$1" 2>/dev/null; fi
}

remote_size() {
  curl -sIL --max-time 30 "$1" 2>/dev/null \
    | awk 'tolower($1)=="content-length:"{v=$2} END{gsub("\r","",v); print v}'
}

fetch_model() {  # $1 = repo, $2 = filename, $3 = target dir
  local repo="$1" file="$2" dir="$3"
  local url="https://huggingface.co/${repo}/resolve/main/${file}?download=true"
  local path="$dir/$file"
  [ -n "$file" ] || return 0

  local code; code="$(http_code "$url")"
  if [ "$code" != "200" ]; then
    warn "Skipping '$file' — not found on Hugging Face (HTTP $code)."
    return 1
  fi

  local expected; expected="$(remote_size "$url")"
  local local_size; local_size="$(file_size "$path")"

  if [ -n "$local_size" ] && [ "$local_size" = "$expected" ]; then
    info "Model '$file' already present ($(numfmt --to=iec "$local_size" 2>/dev/null || echo "$local_size bytes"))."
    return 0
  fi

  info "Downloading '$file' ($(numfmt --to=iec "$expected" 2>/dev/null || echo "$expected bytes"))..."
  if [ -n "$local_size" ]; then
    curl -L -C - --retry 3 --retry-delay 2 -o "$path" "$url" || { rm -f "$path"; die "Download of '$file' failed."; }
  else
    curl -L --retry 3 --retry-delay 2 -o "$path" "$url" || { rm -f "$path"; die "Download of '$file' failed."; }
  fi
  info "Downloaded '$file' to $dir."
}

ensure_model() {
  mkdir -p "$MODEL_DIR"
  fetch_model "$MODEL_REPO" "$MODEL_FILE" "$MODEL_DIR" \
    || die "Model '$MODEL_FILE' is not available in $MODEL_REPO. Set LOCALAI_MODEL_REPO / LOCALAI_MODEL_FILE."
  # Vision projector is a bonus — fetch when the repo has one, ignore when not.
  if [ "$MMPROJ_ENABLED" = "1" ]; then
    fetch_model "$MODEL_REPO" "$MMPROJ_FILE" "$MODEL_DIR" || true
  fi
}

# ---------------------------------------------------------------------------
# Compose helpers
# ---------------------------------------------------------------------------
llama_state() { "${DOCKER_CMD[@]}" inspect -f '{{.State.Status}}' local-ai-llama-server 2>/dev/null || echo missing; }

wait_for_llama() { # $1 = profile (for messaging), returns 0 healthy / 1 failed / 2 timeout
  local deadline=$((SECONDS + 300))
  local state
  info "Waiting for llama-server ($1) to become healthy..."
  while [ $SECONDS -lt $deadline ]; do
    if curl -fsS "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1; then
      info "llama-server is healthy."
      return 0
    fi
    state="$(llama_state)"
    if [ "$state" = "exited" ] || [ "$state" = "dead" ] || [ "$state" = "restarting" ]; then
      sleep 8   # don't misjudge a transient restart
      state="$(llama_state)"
      if [ "$state" = "exited" ] || [ "$state" = "dead" ] || [ "$state" = "restarting" ]; then
        warn "llama-server container is $state."
        return 1
      fi
    fi
    sleep 5
  done
  return 2
}

# Open WebUI ships its own healthcheck; poll it the same way.
wait_for_webui() {
  local deadline=$((SECONDS + 240))
  local hs st
  info "Waiting for Open WebUI to become healthy..."
  while [ $SECONDS -lt $deadline ]; do
    hs="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Health.Status}}' local-ai-open-webui 2>/dev/null || echo missing)"
    if [ "$hs" = "healthy" ]; then
      info "Open WebUI is healthy."
      return 0
    fi
    st="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Status}}' local-ai-open-webui 2>/dev/null || echo missing)"
    if [ "$st" = "exited" ] || [ "$st" = "dead" ] || [ "$st" = "restarting" ]; then
      sleep 8   # don't misjudge a transient restart
      st="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Status}}' local-ai-open-webui 2>/dev/null || echo missing)"
      if [ "$st" = "exited" ] || [ "$st" = "dead" ] || [ "$st" = "restarting" ]; then
        warn "open-webui container is $st."
        return 1
      fi
    fi
    sleep 5
  done
  return 2
}

# The whole stack must be healthy, or the run is a failure (non-zero exit).
wait_for_stack() { # $1 = profile (for messaging)
  wait_for_llama "$1" || return 1
  wait_for_webui || return 1
}

dump_logs() {
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile cpu logs --tail=50 local-ai-llama-server 2>/dev/null || true
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile cpu logs --tail=50 local-ai-open-webui 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_start() {
  ensure_docker

  local backend; backend="$(detect_backend)"
  if [ "$backend" = "mlx" ]; then
    info "Detected: OS=$OS arch=$ARCH -> MLX backend (Apple Silicon, Metal)."
    mlx_start
    return 0
  fi

  local profile
  profile="$(detect_profile)"
  info "Detected: OS=$OS arch=$ARCH wsl=$WSL -> profile '$profile'"
  if [ "$profile" = "nvidia" ] && ! ensure_nvidia_runtime; then profile="cpu"; fi
  if [ "$profile" = "nvidia" ] && ! check_cuda_driver; then
    die "CUDA driver pre-flight failed — see the messages above."
  fi
  check_wsl_memory

  ensure_model

  # Optional vision projector: include the override file when the mmproj GGUF
  # exists on disk (multimodal model) and the user didn't disable it.
  local vision=0
  if [ "$MMPROJ_ENABLED" = "1" ] && [ -f "$MODEL_DIR/$MMPROJ_FILE" ]; then
    vision=1
    info "Vision enabled (mmproj projector found)."
  fi

  export LOCALAI_MODEL_DIR LOCALAI_MODEL_FILE LOCALAI_API_KEY
  export LOCALAI_CTX
  if [ "$profile" = "cpu" ]; then LOCALAI_CTX="$CTX_CPU"; else LOCALAI_CTX="$CTX_GPU"; fi

  local compose_args=(-f "$COMPOSE_FILE" --profile "$profile")
  [ "$vision" = 1 ] && compose_args+=(-f "$VISION_COMPOSE_FILE")

  info "Starting llama.cpp ($profile profile) + Open WebUI..."
  local up_out
  if ! up_out="$("${DOCKER_CMD[@]}" compose "${compose_args[@]}" up -d 2>&1)"; then
    # Stale containers from an older compose config can block recreation with
    # a name conflict (e.g. upgrading the script while the stack is running).
    # Reset the project and retry once.
    if grep -q "already in use" <<<"$up_out"; then
      warn "Container name conflict from a previous run (profile changed?) — resetting the project and retrying."
      # container_name is fixed across profiles, so a stale container created
      # under a different profile must be removed with a full-project down.
      "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" \
        --profile cpu --profile nvidia --profile vulkan down --remove-orphans 2>/dev/null || true
      "${DOCKER_CMD[@]}" compose "${compose_args[@]}" up -d
    else
      echo "$up_out" >&2
      die "docker compose up failed."
    fi
  fi

  mkdir -p "$STATE_DIR"
  echo "$profile" > "$STATE_DIR/profile"
  echo "$vision" > "$STATE_DIR/vision"

  # If a GPU profile fails to come up — or comes up but llama.cpp finds no
  # usable GPU inside the container — degrade gracefully to CPU. Either way
  # the final state must be fully healthy or the script exits non-zero.
  if ! wait_for_stack "$profile"; then
    if [ "$profile" = "cpu" ]; then
      dump_logs
      die "The stack failed to become healthy. See logs above."
    fi
    warn "The '$profile' profile failed. Falling back to the CPU profile..."
    fallback_to_cpu "$profile"
  elif [ "$profile" != "cpu" ]; then
    # llama-server logs to stderr, so capture both streams (and grep the
    # captured string rather than piping, to avoid SIGPIPE under pipefail).
    local llama_logs
    llama_logs="$("${DOCKER_CMD[@]}" logs local-ai-llama-server 2>&1 || true)"
    if grep -q "no usable GPU found" <<<"$llama_logs"; then
      warn "The '$profile' profile started, but llama.cpp found no usable GPU inside the container."
      warn "Falling back to the CPU profile..."
      fallback_to_cpu "$profile"
    fi
  fi

  print_urls
}

# Tear down a failed GPU attempt and bring the CPU profile up instead.
fallback_to_cpu() { # $1 = the failed profile
  local failed_profile="$1"
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile "$failed_profile" down --remove-orphans 2>/dev/null || true
  profile="cpu"
  export LOCALAI_CTX="$CTX_CPU"
  if [ "$MMPROJ_ENABLED" = "1" ] && [ -f "$MODEL_DIR/$MMPROJ_FILE" ]; then
    vision=1
    info "Vision stays enabled (mmproj projector found)."
  else
    vision=0
  fi
  local compose_args=(-f "$COMPOSE_FILE" --profile cpu)
  [ "$vision" = 1 ] && compose_args+=(-f "$VISION_COMPOSE_FILE")
  "${DOCKER_CMD[@]}" compose "${compose_args[@]}" up -d
  echo cpu > "$STATE_DIR/profile"; echo "$vision" > "$STATE_DIR/vision"
  if ! wait_for_stack cpu; then
    dump_logs
    die "The stack failed to become healthy even on CPU. See logs above."
  fi
}

cmd_stop() {
  ensure_docker
  local backend; backend="$(cat "$STATE_DIR/backend" 2>/dev/null || detect_backend)"
  if [ "$backend" = "mlx" ]; then
    mlx_stop
    return 0
  fi
  info "Stopping all local-ai containers..."
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" \
    --profile cpu --profile nvidia --profile vulkan down 2>/dev/null || true
  info "Stopped. Model files in $MODEL_DIR are kept."
}

cmd_restart() { cmd_stop; cmd_start; }

cmd_status() {
  ensure_docker
  local backend; backend="$(cat "$STATE_DIR/backend" 2>/dev/null || detect_backend)"
  local profile="?" vision="?"
  [ -f "$STATE_DIR/profile" ] && profile="$(cat "$STATE_DIR/profile")"
  [ -f "$STATE_DIR/vision" ] && vision="$(cat "$STATE_DIR/vision")"
  info "Backend: $backend | Last profile: $profile | vision: $([ "$vision" = 1 ] && echo on || echo off)"
  if [ "$backend" = "mlx" ]; then
    if [ -f "$MLX_PID_FILE" ] && kill -0 "$(cat "$MLX_PID_FILE")" 2>/dev/null; then
      echo "  MLX server   : running (PID $(cat "$MLX_PID_FILE"), log $MLX_LOG)"
    else
      echo "  MLX server   : not running"
    fi
  fi

  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" \
    --profile cpu --profile nvidia --profile vulkan ps 2>/dev/null \
    || "${DOCKER_CMD[@]}" ps --filter "name=local-ai-"

  local llama=0 webui=0
  curl -fsS "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1 && llama=1
  curl -fsS -o /dev/null "http://127.0.0.1:$WEBUI_PORT/" >/dev/null 2>&1 && webui=1
  echo ""
  echo "  llama.cpp API : http://127.0.0.1:$LLAMA_PORT  ($([ $llama = 1 ] && echo healthy || echo unreachable))"
  echo "  Open WebUI    : http://127.0.0.1:$WEBUI_PORT  ($([ $webui = 1 ] && echo up || echo unreachable))"
}

cmd_logs() {
  ensure_docker
  local backend; backend="$(cat "$STATE_DIR/backend" 2>/dev/null || detect_backend)"
  if [ "$backend" = "mlx" ]; then
    tail -f "$MLX_LOG" &
    local tail_pid=$!
    "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile webui logs -f --tail=100 2>/dev/null || true
    kill "$tail_pid" 2>/dev/null || true
    return 0
  fi
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" \
    --profile cpu --profile nvidia --profile vulkan logs -f --tail=100 2>/dev/null \
    || "${DOCKER_CMD[@]}" logs -f --tail=100 local-ai-llama-server local-ai-open-webui
}

cmd_update() {
  ensure_docker
  local backend; backend="$(cat "$STATE_DIR/backend" 2>/dev/null || detect_backend)"
  if [ "$backend" = "mlx" ]; then
    info "Updating mlx-lm in $MLX_VENV_DIR ..."
    "$MLX_VENV_DIR/bin/pip" install -q -U mlx-lm 2>/dev/null && info "mlx-lm updated."
    ensure_mlx_model
    info "Done. Restart with: ./local-ai.sh restart"
    return 0
  fi
  local profile; profile="$(cat "$STATE_DIR/profile" 2>/dev/null || detect_profile)"
  info "Pulling the latest container images ($profile profile)..."
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile "$profile" pull
  info "Done. Restart with: ./local-ai.sh restart"
}

cmd_detect() {
  echo "=== Local AI — machine detection ==="
  echo "OS        : $OS ($(uname -r))"
  echo "Arch      : $ARCH"
  echo "WSL2      : $([ $WSL = 1 ] && echo yes || echo no)"
  echo "CPU cores : $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
  [ "$WSL" = 1 ] && echo "Memory    : $(free -m 2>/dev/null | awk '/^Mem:/{printf "%d MB", $2}' || echo '?')"
  if command -v docker >/dev/null 2>&1; then
    echo "Docker    : $(docker --version 2>/dev/null || echo 'installed (needs sudo)')"
    docker_ok && echo "Daemon    : running" || echo "Daemon    : NOT running"
    "${DOCKER_CMD[@]}" compose version 2>/dev/null | sed 's/^/Compose   : /' || echo "Compose   : missing"
    echo "Runtimes  : $("${DOCKER_CMD[@]}" info --format '{{json .Runtimes}}' 2>/dev/null | grep -oE '"[a-zA-Z0-9._-]+":\{' | tr -d '":{' | grep -v '^status$' | paste -sd, || echo n/a)"
  else
    echo "Docker    : NOT installed (will be installed on 'start')"
  fi
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    echo "GPU       : NVIDIA — $(nvidia-smi -L | head -1)"
  elif ls /dev/dri 2>/dev/null | grep -qE '^(card|renderD)' || [ -e /dev/kfd ]; then
    echo "GPU       : non-NVIDIA GPU present (/dev/dri or /dev/kfd) — Vulkan profile"
  else
    echo "GPU       : none detected — CPU profile"
  fi
  echo "Profile   : $(detect_profile) (LOCALAI_FORCE can override)"
  echo "Backend   : $(detect_backend) (LOCALAI_BACKEND=mlx|docker; mlx = native Metal on Apple Silicon)"
  echo ""
  echo "Model     : $MODEL_FILE"
  echo "  repo    : $MODEL_REPO"
  if [ -f "$MODEL_DIR/$MODEL_FILE" ]; then
    echo "  on disk : yes ($(file_size "$MODEL_DIR/$MODEL_FILE") bytes in $MODEL_DIR)"
  else
    echo "  on disk : no (downloaded on 'start')"
  fi
  echo "mmproj    : $([ -f "$MODEL_DIR/$MMPROJ_FILE" ] && echo "present (vision on)" || echo "absent (vision off)")"
  if [ "$(detect_backend)" = "mlx" ]; then
    if [ -d "$MLX_MODEL" ]; then
      echo "MLX model : $MLX_MODEL (local dir)"
    elif [ -f "$MODEL_DIR/mlx/${MLX_MODEL##*/}/config.json" ]; then
      echo "MLX model : $MLX_MODEL (on disk: $MODEL_DIR/mlx/${MLX_MODEL##*/})"
    else
      echo "MLX model : $MLX_MODEL (not downloaded yet)"
    fi
  fi
  echo "Ports     : llama $LLAMA_PORT (127.0.0.1) | webui $WEBUI_PORT (127.0.0.1)"
}

cmd_lan() { # on | off | (status)
  ensure_docker
  local profile vision
  profile="$(cat "$STATE_DIR/profile" 2>/dev/null || detect_profile)"
  vision="$(cat "$STATE_DIR/vision" 2>/dev/null || echo 0)"
  local compose_args=(-f "$COMPOSE_FILE" --profile "$profile")
  [ "$vision" = 1 ] && compose_args+=(-f "$VISION_COMPOSE_FILE")

  case "${1:-}" in
    on)
      set_env LOCALAI_WEBUI_BIND 0.0.0.0
      info "LAN access ON — Open WebUI will listen on 0.0.0.0:${WEBUI_PORT}."
      warn "Open WebUI is userless (no login): anyone on your LAN can use the model."
      ;;
    off)
      set_env LOCALAI_WEBUI_BIND 127.0.0.1
      info "LAN access OFF — Open WebUI back to 127.0.0.1:${WEBUI_PORT}."
      ;;
    *)
      local cur; cur="$(current_webui_bind)"
      echo "Open WebUI bind: $cur"
      echo "LAN access     : $([ "$cur" = "0.0.0.0" ] && echo ON || echo off)  (toggle with: ./local-ai.sh lan on|off)"
      return 0
      ;;
  esac

  if [ "$(llama_state)" = "missing" ]; then
    info "Stack is not running — starting it with the new bind setting."
    cmd_start
    return 0
  fi

  # Recreate only the webui container (bind change); llama-server is untouched.
  "${DOCKER_CMD[@]}" compose "${compose_args[@]}" up -d
  local bind; bind="$(current_webui_bind)"
  echo ""
  info "Open WebUI bind: $bind:${WEBUI_PORT}"
  if [ "$bind" = "0.0.0.0" ]; then
    local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$ip" ]; then
      echo "   From other machines on this LAN: http://${ip}:${WEBUI_PORT}"
    else
      echo "   From other machines on this LAN: http://<this-host-ip>:${WEBUI_PORT}"
    fi
  fi
}

print_urls() {
  echo ""
  info "Local AI is running:"
  echo "   Open WebUI    -> http://127.0.0.1:$WEBUI_PORT   (no login required)"
  echo "   llama.cpp API -> http://127.0.0.1:$LLAMA_PORT/v1  (OpenAI-compatible)"
  echo ""
  echo "   Manage:  ./local-ai.sh status | logs | restart | stop"
}

usage() {
  sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
# Global flags (-y/--yes) may appear anywhere on the command line.
YES_MODE=0
ARGS=()
for _arg in "$@"; do
  case "$_arg" in
    -y|--yes) YES_MODE=1 ;;
    *) ARGS+=("$_arg") ;;
  esac
done
[ "${LOCALAI_YES:-0}" = "1" ] && YES_MODE=1

CMD="${ARGS[0]:-start}"
case "$CMD" in
  start|up)            cmd_start ;;
  stop|down)           cmd_stop ;;
  restart)             cmd_restart ;;
  status|ps)           cmd_status ;;
  logs)                cmd_logs ;;
  update)              cmd_update ;;
  lan)                 cmd_lan "${ARGS[1]:-}" ;;
  detect|doctor|info)  cmd_detect ;;
  help|-h|--help)      usage ;;
  *)                   usage; exit 1 ;;
esac
