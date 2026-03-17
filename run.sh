#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="DiveInto Labs"
COMPOSE_REF="oci://spurin/diveintolabs-cloudshell"
PORTAL_CONTAINER="portal-diveinto-lab"
SSH_KEYS_CONTAINER="shared-ssh-keys-diveinto-lab"
IMAGES=(
  "spurin/ssh-client"
  "spurin/diveinto-lab:portal"
  "spurin/diveinto-lab:node"
  "spurin/diveinto-lab:labapi"
)

# ---------- styling ----------
if [[ -t 1 ]]; then
  BOLD="$(tput bold 2>/dev/null || true)"
  DIM="$(tput dim 2>/dev/null || true)"
  RED="$(tput setaf 1 2>/dev/null || true)"
  GREEN="$(tput setaf 2 2>/dev/null || true)"
  YELLOW="$(tput setaf 3 2>/dev/null || true)"
  BLUE="$(tput setaf 4 2>/dev/null || true)"
  MAGENTA="$(tput setaf 5 2>/dev/null || true)"
  CYAN="$(tput setaf 6 2>/dev/null || true)"
  RESET="$(tput sgr0 2>/dev/null || true)"
  HIDE_CURSOR="$(tput civis 2>/dev/null || true)"
  SHOW_CURSOR="$(tput cnorm 2>/dev/null || true)"
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" RESET=""
  HIDE_CURSOR="" SHOW_CURSOR=""
fi

SPINNER_FRAMES=( "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏" )

info()    { printf "%bℹ%b  %s\n" "$BLUE" "$RESET" "$*"; }
success() { printf "%b✔%b  %s\n" "$GREEN" "$RESET" "$*"; }
warn()    { printf "%b⚠%b  %s\n" "$YELLOW" "$RESET" "$*"; }
error()   { printf "%b✖%b  %s\n" "$RED" "$RESET" "$*" >&2; }

cleanup_screen() {
  printf "%b" "$SHOW_CURSOR"
}
trap cleanup_screen EXIT

on_error() {
  local line="${1:-unknown}"
  cleanup_screen
  error "Something went wrong on line ${line}."
  error "If Docker is still starting, wait a few seconds and run the script again."
}
trap 'on_error $LINENO' ERR

print_banner() {
  printf "\n%b" "$CYAN"
  cat <<'BANNER'
    ____  _            ____      __           __          __        
   / __ \(_)   _____  /  _/___  / /_____     / /   ____ _/ /_  _____
  / / / / / | / / _ \ / // __ \/ __/ __ \   / /   / __ `/ __ \/ ___/
 / /_/ / /| |/ /  __// // / / / /_/ /_/ /  / /___/ /_/ / /_/ (__  ) 
/_____/_/ |___/\___/___/_/ /_/\__/\____/  /_____/\__,_/_.___/____/  
                                                                     
BANNER
  printf "%b" "$RESET"
  printf "%b%s%b\n\n" "$BOLD" "Browser-based labs, one command away 🚀" "$RESET"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    error "Required command not found: $1"
    exit 1
  }
}

safe_name() {
  printf '%s' "$1" | tr '/:' '__'
}

progress_bar() {
  local current="$1" total="$2" width="${3:-12}"
  local filled=0 empty=0

  if (( total > 0 )); then
    filled=$(( current * width / total ))
  fi
  (( filled > width )) && filled="$width"
  empty=$(( width - filled ))

  printf "["
  printf "%${filled}s" "" | tr ' ' '='
  printf "%${empty}s" "" | tr ' ' ' '
  printf "]"
}

run_with_spinner() {
  local message="$1"
  shift
  local logfile
  logfile="$(mktemp)"

  "$@" >"$logfile" 2>&1 &
  local pid=$!
  local i=0

  printf "%b" "$HIDE_CURSOR"
  while kill -0 "$pid" >/dev/null 2>&1; do
    printf "\r%b%s%b  %s" "$MAGENTA" "${SPINNER_FRAMES[i]}" "$RESET" "$message"
    sleep 0.1
    i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
  done

  wait "$pid"
  local rc=$?
  printf "\r\033[K"
  printf "%b" "$SHOW_CURSOR"

  if (( rc == 0 )); then
    success "$message"
  else
    error "$message"
    [[ -s "$logfile" ]] && sed 's/^/    /' "$logfile" >&2
  fi

  rm -f "$logfile"
  return "$rc"
}

preflight_checks() {
  info "Running preflight checks"
  require_cmd docker

  if ! docker compose version >/dev/null 2>&1; then
    error "Docker Compose plugin is required but not available via 'docker compose'."
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    error "Docker appears unavailable. In Cloud Shell, wait for Docker to finish starting and retry."
    exit 1
  fi

  success "Docker is ready"
}

summarise_pull_log() {
  local logfile="$1"

  awk '
    {
      line=$0
      gsub(/\r/, "\n", line)
      n=split(line, parts, /\n/)
      for (i=1; i<=n; i++) {
        if (parts[i] ~ /^[^:]+: (Pulling fs layer|Waiting|Downloading|Verifying Checksum|Download complete|Extracting|Pull complete|Already exists)$/) {
          split(parts[i], seg, /: /)
          state[seg[1]]=seg[2]
        }
        if (parts[i] ~ /^Status: /) {
          status=parts[i]
          sub(/^Status: /, "", status)
          last_status=status
        }
      }
    }
    END {
      total=0; done=0; downloading=0; extracting=0; waiting=0; verifying=0
      for (layer in state) {
        total++
        s=state[layer]
        if (s == "Pull complete" || s == "Already exists" || s == "Download complete") done++
        else if (s == "Downloading") downloading++
        else if (s == "Extracting") extracting++
        else if (s == "Waiting" || s == "Pulling fs layer") waiting++
        else if (s == "Verifying Checksum") verifying++
      }
      printf "%d|%d|%d|%d|%d|%d|%s\n", total, done, downloading, extracting, waiting, verifying, last_status
    }
  ' "$logfile"
}

render_pull_line() {
  local image="$1"
  local logfile="$2"
  local statusfile="$3"
  local frame_index="$4"

  if [[ -f "$statusfile" ]]; then
    local rc
    rc="$(cat "$statusfile")"
    if [[ "$rc" == "0" ]]; then
      printf "%b✔%b  %-30s ready" "$GREEN" "$RESET" "$image"
    else
      printf "%b✖%b  %-30s failed" "$RED" "$RESET" "$image"
    fi
    return
  fi

  local summary total_layers done_layers downloading_layers extracting_layers waiting_layers verifying_layers last_status
  summary="$(summarise_pull_log "$logfile")"
  IFS='|' read -r total_layers done_layers downloading_layers extracting_layers waiting_layers verifying_layers last_status <<< "$summary"

  local frame="${SPINNER_FRAMES[frame_index % ${#SPINNER_FRAMES[@]}]}"

  if (( total_layers > 0 )); then
    local bar extra
    bar="$(progress_bar "$done_layers" "$total_layers" 12)"
    extra=""
    (( downloading_layers > 0 )) && extra+=" ↓${downloading_layers}"
    (( extracting_layers > 0 )) && extra+=" ⇢${extracting_layers}"
    (( waiting_layers > 0 )) && extra+=" …${waiting_layers}"
    (( verifying_layers > 0 )) && extra+=" ✓${verifying_layers}"
    printf "%b%s%b  %-30s %s %2d/%-2d%s" \
      "$MAGENTA" "$frame" "$RESET" "$image" "$bar" "$done_layers" "$total_layers" "$extra"
  elif [[ -n "$last_status" ]]; then
    printf "%b%s%b  %-30s %s" "$MAGENTA" "$frame" "$RESET" "$image" "$last_status"
  else
    printf "%b%s%b  %-30s contacting registry" "$MAGENTA" "$frame" "$RESET" "$image"
  fi
}

pull_images_parallel() {
  info "Warming ${#IMAGES[@]} lab images in parallel"

  local temp_dir count failed tick
  temp_dir="$(mktemp -d)"
  count="${#IMAGES[@]}"
  failed=0
  tick=0

  local -a logs statuses pids

  for i in "${!IMAGES[@]}"; do
    local safe
    safe="$(safe_name "${IMAGES[i]}")"
    logs[i]="${temp_dir}/${safe}.log"
    statuses[i]="${temp_dir}/${safe}.status"

    (
      if docker pull "${IMAGES[i]}" >"${logs[i]}" 2>&1; then
        printf '0' >"${statuses[i]}"
      else
        printf '1' >"${statuses[i]}"
      fi
    ) &
    pids[i]="$!"
  done

  printf "%b" "$HIDE_CURSOR"
  for ((i=0; i<count; i++)); do
    printf "\n"
  done

  while :; do
    local all_done=1
    printf "\033[%dA" "$count"

    for i in "${!IMAGES[@]}"; do
      [[ -f "${statuses[i]}" ]] || all_done=0
      printf "\r\033[K%s\n" "$(render_pull_line "${IMAGES[i]}" "${logs[i]}" "${statuses[i]}" $((tick + i)))"
    done

    (( all_done == 1 )) && break
    tick=$((tick + 1))
    sleep 0.15
  done

  printf "%b" "$SHOW_CURSOR"

  for i in "${!IMAGES[@]}"; do
    wait "${pids[i]}" || true
    if [[ ! -f "${statuses[i]}" ]] || [[ "$(cat "${statuses[i]}")" != "0" ]]; then
      failed=$((failed + 1))
      [[ -s "${logs[i]}" ]] && sed 's/^/    /' "${logs[i]}" >&2
    fi
  done

  rm -rf "$temp_dir"

  if (( failed > 0 )); then
    error "${failed} image pull(s) failed."
    exit 1
  fi

  success "All images are ready"
}

cleanup_existing_lab() {
  info "Cleaning up any previous lab instance"

  run_with_spinner "Stopping previous containers" \
    bash -lc 'docker compose -f "$0" down >/dev/null 2>&1 || true' "$COMPOSE_REF"

  run_with_spinner "Removing previous containers" \
    bash -lc 'docker compose -f "$0" rm -f >/dev/null 2>&1 || true' "$COMPOSE_REF"
}

wait_for_portal() {
  local i=0
  printf "%b" "$HIDE_CURSOR"

  while :; do
    if docker ps --filter "name=^/${PORTAL_CONTAINER}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$PORTAL_CONTAINER"; then
      printf "\r\033[K"
      printf "%b" "$SHOW_CURSOR"
      success "Portal container is running"
      return
    fi

    local status
    status="$(docker ps -a --filter "name=^/${PORTAL_CONTAINER}$" --format '{{.Status}}' | head -n1 || true)"

    if [[ "$status" == Exited* ]]; then
      printf "\r\033[K"
      printf "%b" "$SHOW_CURSOR"
      error "Portal container exited unexpectedly. Recent logs:"
      docker compose -f "$COMPOSE_REF" logs --no-color --tail=40 || true
      exit 1
    fi

    printf "\r%b%s%b  Waiting for portal to be ready" "$MAGENTA" "${SPINNER_FRAMES[i]}" "$RESET"
    sleep 0.15
    i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
  done
}

show_access_details() {
  printf "\n%b%s%b\n" "$BOLD" "Portal access" "$RESET"
  printf "  • On the Cloud Shell toolbar, click the %bWeb Preview%b icon %b[<>]%b\n" "$CYAN" "$RESET" "$DIM" "$RESET"
  printf "  • Then choose %bPreview on Port 8080%b\n" "$CYAN" "$RESET"

  printf "\n%b%s%b\n" "$BOLD" "Stopping the lab" "$RESET"
  printf "  • Run %bdocker compose -f %s down%b when you are done\n\n" "$DIM" "$COMPOSE_REF" "$RESET"
}

launch_lab() {
  info "Starting ${APP_NAME} in the background"
  docker compose -f "$COMPOSE_REF" up -d --no-build
  wait_for_portal
  show_access_details
}

main() {
  print_banner
  preflight_checks
  pull_images_parallel
  cleanup_existing_lab
  launch_lab
}

main "$@"
