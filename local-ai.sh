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

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yaml"
VISION_COMPOSE_FILE="$PROJECT_DIR/docker-compose.vision.yaml"
STATE_DIR="${LOCALAI_STATE_DIR:-$HOME/.local/share/local-ai}"

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
    read -r -p "Docker not found. Install it with apt (docker.io + compose plugin)? [Y/n] " ans
    [[ "${ans:-y}" =~ ^[Yy]$ ]] || die "Aborted. Install Docker manually, then re-run."
    run_sudo apt-get update -y
    run_sudo apt-get install -y docker.io
    run_sudo apt-get install -y docker-compose-v2 2>/dev/null \
      || run_sudo apt-get install -y docker-compose-plugin 2>/dev/null \
      || warn "Compose v2 plugin not found in apt. Install Docker Compose v2 manually."
  elif command -v dnf >/dev/null 2>&1; then
    read -r -p "Docker not found. Install it with dnf (docker + compose plugin)? [Y/n] " ans
    [[ "${ans:-y}" =~ ^[Yy]$ ]] || die "Aborted. Install Docker manually, then re-run."
    run_sudo dnf install -y docker docker-compose-plugin
  elif command -v pacman >/dev/null 2>&1; then
    read -r -p "Docker not found. Install it with pacman (docker + compose)? [Y/n] " ans
    [[ "${ans:-y}" =~ ^[Yy]$ ]] || die "Aborted. Install Docker manually, then re-run."
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
  read -r -p "Docker not found. Install Docker Desktop via Homebrew? [Y/n] " ans
  [[ "${ans:-y}" =~ ^[Yy]$ ]] || die "Aborted. Install Docker Desktop manually, then re-run."
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
      read -r -p "Install docker-compose via Homebrew? [Y/n] " ans
      if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
        brew install docker-compose && installed=1
      fi
    else
      warn "Docker Desktop bundles Compose v2; Homebrew is required for a standalone install."
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    read -r -p "Install the Docker Compose plugin via apt? [Y/n] " ans
    if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
      run_sudo apt-get install -y docker-compose-v2 2>/dev/null \
        || run_sudo apt-get install -y docker-compose-plugin 2>/dev/null \
        || true
      "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 && installed=1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    read -r -p "Install the Docker Compose plugin via dnf? [Y/n] " ans
    if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
      run_sudo dnf install -y docker-compose-plugin && installed=1
    fi
  elif command -v pacman >/dev/null 2>&1; then
    read -r -p "Install docker-compose via pacman? [Y/n] " ans
    if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
      run_sudo pacman -S --noconfirm docker-compose && installed=1
    fi
  fi

  if [ "$installed" != 1 ]; then
    read -r -p "Download the official docker compose binary from GitHub? [Y/n] " ans
    if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
      install_compose_binary && installed=1
    fi
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
    read -r -p "NVIDIA GPU found, but Docker cannot use it yet. Install nvidia-container-toolkit? [y/N] " ans
    if [[ "${ans:-n}" =~ ^[Yy]$ ]]; then
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

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_start() {
  ensure_docker

  local profile
  profile="$(detect_profile)"
  info "Detected: OS=$OS arch=$ARCH wsl=$WSL -> profile '$profile'"
  if [ "$profile" = "nvidia" ] && ! ensure_nvidia_runtime; then profile="cpu"; fi

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
  "${DOCKER_CMD[@]}" compose "${compose_args[@]}" up -d

  mkdir -p "$STATE_DIR"
  echo "$profile" > "$STATE_DIR/profile"
  echo "$vision" > "$STATE_DIR/vision"

  # If a GPU profile fails to come up — or comes up but llama.cpp finds no
  # usable GPU inside the container — degrade gracefully to CPU.
  if ! wait_for_llama "$profile"; then
    if [ "$profile" = "cpu" ]; then
      "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile cpu logs --tail=50 local-ai-llama-server
      die "llama-server failed to start. See logs above."
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
  if ! wait_for_llama cpu; then
    "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" --profile cpu logs --tail=50 local-ai-llama-server
    die "llama-server failed to start even on CPU. See logs above."
  fi
}

cmd_stop() {
  ensure_docker
  info "Stopping all local-ai containers..."
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" \
    --profile cpu --profile nvidia --profile vulkan down 2>/dev/null || true
  info "Stopped. Model files in $MODEL_DIR are kept."
}

cmd_restart() { cmd_stop; cmd_start; }

cmd_status() {
  ensure_docker
  local profile="?" vision="?"
  [ -f "$STATE_DIR/profile" ] && profile="$(cat "$STATE_DIR/profile")"
  [ -f "$STATE_DIR/vision" ] && vision="$(cat "$STATE_DIR/vision")"
  info "Last used profile: $profile  |  vision: $([ "$vision" = 1 ] && echo on || echo off)"

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
  "${DOCKER_CMD[@]}" compose -f "$COMPOSE_FILE" \
    --profile cpu --profile nvidia --profile vulkan logs -f --tail=100 2>/dev/null \
    || "${DOCKER_CMD[@]}" logs -f --tail=100 local-ai-llama-server local-ai-open-webui
}

cmd_update() {
  ensure_docker
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
  echo ""
  echo "Model     : $MODEL_FILE"
  echo "  repo    : $MODEL_REPO"
  if [ -f "$MODEL_DIR/$MODEL_FILE" ]; then
    echo "  on disk : yes ($(file_size "$MODEL_DIR/$MODEL_FILE") bytes in $MODEL_DIR)"
  else
    echo "  on disk : no (downloaded on 'start')"
  fi
  echo "mmproj    : $([ -f "$MODEL_DIR/$MMPROJ_FILE" ] && echo "present (vision on)" || echo "absent (vision off)")"
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
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
CMD="${1:-start}"
case "$CMD" in
  start|up)            cmd_start ;;
  stop|down)           cmd_stop ;;
  restart)             cmd_restart ;;
  status|ps)           cmd_status ;;
  logs)                cmd_logs ;;
  update)              cmd_update ;;
  lan)                 cmd_lan "${2:-}" ;;
  detect|doctor|info)  cmd_detect ;;
  help|-h|--help)      usage ;;
  *)                   usage; exit 1 ;;
esac
