#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="DiveInto Labs"
readonly STACK_REF="oci://spurin/diveintolabs-cloudshell"
readonly PORTAL_NAME="portal-diveinto-lab"
readonly PORTAL_PORT="8080"
readonly -a PREPULL_IMAGES=(
  "spurin/ssh-client"
  "spurin/diveinto-lab:portal"
  "spurin/diveinto-lab:node"
  "spurin/diveinto-lab:labapi"
)
readonly -a SPINNER=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

if [[ -t 1 ]]; then
  BOLD="$(tput bold 2>/dev/null || true)"
  DIM="$(tput dim 2>/dev/null || true)"
  RED="$(tput setaf 1 2>/dev/null || true)"
  GREEN="$(tput setaf 2 2>/dev/null || true)"
  YELLOW="$(tput setaf 3 2>/dev/null || true)"
  BLUE="$(tput setaf 4 2>/dev/null || true)"
  CYAN="$(tput setaf 6 2>/dev/null || true)"
  MAGENTA="$(tput setaf 5 2>/dev/null || true)"
  RESET="$(tput sgr0 2>/dev/null || true)"
  HIDE_CURSOR="$(tput civis 2>/dev/null || true)"
  SHOW_CURSOR="$(tput cnorm 2>/dev/null || true)"
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; RESET=""
  HIDE_CURSOR=""; SHOW_CURSOR=""
fi

note() { printf "%bℹ%b  %s\n" "$BLUE" "$RESET" "$*"; }
ok()   { printf "%b✔%b  %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b⚠%b  %s\n" "$YELLOW" "$RESET" "$*"; }
fail() { printf "%b✖%b  %s\n" "$RED" "$RESET" "$*" >&2; }

cleanup_terminal() {
  printf "%b" "$SHOW_CURSOR"
}
trap cleanup_terminal EXIT

trap 'fail "The script stopped unexpectedly near line ${LINENO}."' ERR

banner() {
  printf "\n%b%s%b\n\n" "$BOLD" "${APP_NAME} — Cloud Shell launcher" "$RESET"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Missing required command: $1"
    exit 1
  }
}

check_environment() {
  note "Checking Docker and Compose"
  need docker
  need curl

  docker compose version >/dev/null 2>&1 || {
    fail "The Docker Compose plugin is required via 'docker compose'."
    exit 1
  }

  docker info >/dev/null 2>&1 || {
    fail "Docker is not ready yet. In Cloud Shell, wait for Docker startup and re-run the script."
    exit 1
  }

  ok "Docker is ready"
}

sanitize_ref() {
  printf '%s' "$1" | tr '/:@' '___'
}

split_image_ref() {
  local ref="$1"
  local name tail tag

  name="${ref%%@*}"
  tail="${name##*/}"

  if [[ "$tail" == *:* ]]; then
    tag="${tail##*:}"
    name="${name%:*}"
  else
    tag="latest"
  fi

  printf '%s\n%s\n' "$name" "$tag"
}

get_dockerhub_token() {
  local repo="$1"

  curl -fsSL \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

resolve_digest_ref() {
  local requested_ref="$1"
  local repo tag api_repo token digest
  local -a parts

  mapfile -t parts < <(split_image_ref "$requested_ref")
  repo="${parts[0]}"
  tag="${parts[1]}"

  api_repo="$repo"
  [[ "$api_repo" == */* ]] || api_repo="library/${api_repo}"

  token="$(get_dockerhub_token "$api_repo")"
  [[ -n "$token" ]] || return 1

  digest="$({
    curl -fsSL \
      -H "Authorization: Bearer ${token}" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      -D - \
      -o /dev/null \
      "https://registry-1.docker.io/v2/${api_repo}/manifests/${tag}"
  } | awk '
      BEGIN { IGNORECASE=1 }
      /^docker-content-digest:/ {
        sub(/^[^:]+:[[:space:]]*/, "")
        gsub("\r", "")
        print
        exit
      }')"

  [[ -n "$digest" ]] || return 1
  printf '%s@%s\n' "$repo" "$digest"
}

pull_and_pin() {
  local requested_ref="$1"
  local digest_ref image_id

  if digest_ref="$(resolve_digest_ref "$requested_ref")"; then
    printf 'resolved=%s\n' "$digest_ref"
    docker pull "$digest_ref"
    image_id="$(docker image inspect --format '{{.Id}}' "$digest_ref")"
    docker tag "$image_id" "$requested_ref"
  else
    printf 'resolved=tag-fallback\n'
    docker pull "$requested_ref"
  fi
}

summarize_pull() {
  local logfile="$1"

  awk '
    {
      raw=$0
      gsub(/\r/, "\n", raw)
      n=split(raw, row, /\n/)
      for (i=1; i<=n; i++) {
        if (row[i] ~ /^[^:]+: (Pulling fs layer|Waiting|Downloading|Verifying Checksum|Download complete|Extracting|Pull complete|Already exists)$/) {
          split(row[i], a, /: /)
          layer[a[1]]=a[2]
        } else if (row[i] ~ /^Status: /) {
          status=row[i]
          sub(/^Status: /, "", status)
          last=status
        } else if (row[i] ~ /^resolved=/) {
          resolved=row[i]
          sub(/^resolved=/, "", resolved)
        }
      }
    }
    END {
      total=0; done=0; downloading=0; extracting=0; queued=0
      for (id in layer) {
        total++
        state=layer[id]
        if (state == "Pull complete" || state == "Already exists" || state == "Download complete") done++
        else if (state == "Downloading") downloading++
        else if (state == "Extracting") extracting++
        else queued++
      }
      printf "%d|%d|%d|%d|%d|%s|%s\n", total, done, downloading, extracting, queued, last, resolved
    }
  ' "$logfile"
}

draw_progress_line() {
  local label="$1"
  local logfile="$2"
  local statusfile="$3"
  local spinner_index="$4"
  local spin="${SPINNER[spinner_index % ${#SPINNER[@]}]}"

  if [[ -f "$statusfile" ]]; then
    if [[ "$(<"$statusfile")" == "0" ]]; then
      printf "%b✔%b  %-30s ready" "$GREEN" "$RESET" "$label"
    else
      printf "%b✖%b  %-30s failed" "$RED" "$RESET" "$label"
    fi
    return
  fi

  local total done downloading extracting queued status resolved
  IFS='|' read -r total done downloading extracting queued status resolved < <(summarize_pull "$logfile")

  if (( total > 0 )); then
    printf "%b%s%b  %-30s done %2d/%-2d queued=%d" \
      "$MAGENTA" "$spin" "$RESET" "$label" "$done" "$total" "$queued"
  elif [[ -n "$resolved" && "$resolved" != "tag-fallback" ]]; then
    printf "%b%s%b  %-30s pinned to %s" "$MAGENTA" "$spin" "$RESET" "$label" "$resolved"
  elif [[ "$resolved" == "tag-fallback" ]]; then
    printf "%b%s%b  %-30s resolving failed; using tag" "$MAGENTA" "$spin" "$RESET" "$label"
  elif [[ -n "$status" ]]; then
    printf "%b%s%b  %-30s %s" "$MAGENTA" "$spin" "$RESET" "$label" "$status"
  else
    printf "%b%s%b  %-30s contacting registry" "$MAGENTA" "$spin" "$RESET" "$label"
  fi
}

prepull_images() {
  note "Pulling lab images"

  local tmpdir count tick failures
  local -a logs rcfiles pids

  tmpdir="$(mktemp -d)"
  count="${#PREPULL_IMAGES[@]}"
  tick=0
  failures=0

  for i in "${!PREPULL_IMAGES[@]}"; do
    logs[i]="${tmpdir}/$(sanitize_ref "${PREPULL_IMAGES[i]}").log"
    rcfiles[i]="${tmpdir}/$(sanitize_ref "${PREPULL_IMAGES[i]}").rc"

    (
      if pull_and_pin "${PREPULL_IMAGES[i]}" >"${logs[i]}" 2>&1; then
        printf '0' >"${rcfiles[i]}"
      else
        printf '1' >"${rcfiles[i]}"
      fi
    ) &
    pids[i]="$!"
  done

  printf "%b" "$HIDE_CURSOR"
  for ((i=0; i<count; i++)); do printf "\n"; done

  while :; do
    local all_done=1
    printf "\033[%dA" "$count"

    for i in "${!PREPULL_IMAGES[@]}"; do
      [[ -f "${rcfiles[i]}" ]] || all_done=0
      printf "\r\033[K%s\n" "$(draw_progress_line "${PREPULL_IMAGES[i]}" "${logs[i]}" "${rcfiles[i]}" $((tick + i)))"
    done

    (( all_done == 1 )) && break
    tick=$((tick + 1))
    sleep 0.15
  done

  printf "%b" "$SHOW_CURSOR"

  for i in "${!PREPULL_IMAGES[@]}"; do
    wait "${pids[i]}" || true
    if [[ ! -f "${rcfiles[i]}" || "$(<"${rcfiles[i]}")" != "0" ]]; then
      failures=$((failures + 1))
      [[ -s "${logs[i]}" ]] && sed 's/^/    /' "${logs[i]}" >&2
    fi
  done

  rm -rf "$tmpdir"

  if (( failures > 0 )); then
    fail "${failures} image pull(s) failed."
    exit 1
  fi

  ok "All required images are available locally"
}

run_with_spinner() {
  local message="$1"
  shift

  local log_file pid idx rc
  log_file="$(mktemp)"

  "$@" >"$log_file" 2>&1 &
  pid=$!
  idx=0

  printf "%b" "$HIDE_CURSOR"
  while kill -0 "$pid" >/dev/null 2>&1; do
    printf "\r%b%s%b  %s" "$MAGENTA" "${SPINNER[idx]}" "$RESET" "$message"
    idx=$(( (idx + 1) % ${#SPINNER[@]} ))
    sleep 0.1
  done

  wait "$pid"
  rc=$?
  printf "\r\033[K%b" "$SHOW_CURSOR"

  if (( rc == 0 )); then
    ok "$message"
  else
    fail "$message"
    [[ -s "$log_file" ]] && sed 's/^/    /' "$log_file" >&2
  fi

  rm -f "$log_file"
  return "$rc"
}

teardown_previous_stack() {
  note "Cleaning up any old lab instance"
  run_with_spinner "Stopping old containers" bash -lc 'docker compose -f "$0" down >/dev/null 2>&1 || true' "$STACK_REF"
  run_with_spinner "Removing stopped containers" bash -lc 'docker compose -f "$0" rm -f >/dev/null 2>&1 || true' "$STACK_REF"
}

wait_for_portal() {
  local idx=0
  printf "%b" "$HIDE_CURSOR"

  while :; do
    if docker ps --filter "name=^/${PORTAL_NAME}$" --filter status=running --format '{{.Names}}' | grep -qx "$PORTAL_NAME"; then
      printf "\r\033[K%b" "$SHOW_CURSOR"
      ok "Portal container is running"
      return
    fi

    local state
    state="$(docker ps -a --filter "name=^/${PORTAL_NAME}$" --format '{{.Status}}' | head -n1 || true)"
    if [[ "$state" == Exited* ]]; then
      printf "\r\033[K%b" "$SHOW_CURSOR"
      fail "Portal container exited unexpectedly. Recent logs:"
      docker compose -f "$STACK_REF" logs --no-color --tail=40 || true
      exit 1
    fi

    printf "\r%b%s%b  Waiting for portal" "$MAGENTA" "${SPINNER[idx]}" "$RESET"
    idx=$(( (idx + 1) % ${#SPINNER[@]} ))
    sleep 0.15
  done
}

show_next_steps() {
  printf "\n%bPortal access%b\n" "$BOLD" "$RESET"
  printf "  • In Cloud Shell, click %bWeb Preview%b and choose %bPreview on Port %s%b\n" "$CYAN" "$RESET" "$CYAN" "$PORTAL_PORT" "$RESET"
  printf "\n%bStopping the lab%b\n" "$BOLD" "$RESET"
  printf "  • %bdocker compose -f %s down%b\n\n" "$DIM" "$STACK_REF" "$RESET"
}

launch_stack() {
  note "Starting ${APP_NAME}"
  docker compose -f "$STACK_REF" up -d --pull never --no-build
  wait_for_portal
  show_next_steps
}

main() {
  banner
  check_environment
  prepull_images
  teardown_previous_stack
  launch_stack
}

main "$@"
