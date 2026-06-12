#!/usr/bin/env bash
#
# Start and configure a single-node dockerized Garage S3 service.
# Reads INPUT_* environment variables, writes step outputs to GITHUB_OUTPUT
# and (optionally) AWS_* variables to GITHUB_ENV.
set -euo pipefail

readonly GARAGE_IMAGE="dxflrs/garage"
readonly S3_CONTAINER_PORT=3900
readonly HEALTH_TIMEOUT_SECONDS=60

# GitHub sets RUNNER_DEBUG=1 when step debug logging is enabled
# (re-run with "Enable debug logging" or secret ACTIONS_STEP_DEBUG=true).
readonly DEBUG="${RUNNER_DEBUG:-0}"

# Use ANSI color only when attached to a terminal or running in Actions
# (which renders ANSI); keep captured/piped logs clean otherwise.
if [[ -t 1 || -n "${GITHUB_ACTIONS:-}" ]]; then
  readonly C_RESET=$'\033[0m' C_DIM=$'\033[2m'
else
  readonly C_RESET="" C_DIM=""
fi

log() { echo "${C_DIM}[setup-garage]${C_RESET} $*"; }

# Emitted as a workflow debug command: only shown when debug logging is on.
debug() { echo "::debug::$*"; }

# Surfaced as an Actions annotation (job summary), visible in non-debug runs.
notice() { echo "::notice::$*"; }

is_debug() { [[ "${DEBUG}" == "1" ]]; }

fail() {
  echo "::error::❌ $*" >&2
  exit 1
}

# In debug mode, trace every command (xtrace) for full verbosity.
if is_debug; then
  log "Debug logging enabled (RUNNER_DEBUG=1)"
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
fi

# --- Input validation -------------------------------------------------------

validate_inputs() {
  [[ "${INPUT_GARAGE_VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail "Invalid garage-version '${INPUT_GARAGE_VERSION}': must be a valid image tag."

  [[ "${INPUT_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    fail "Invalid bucket '${INPUT_BUCKET}': must be 3-63 chars of lowercase letters, digits, dots or hyphens."

  if ! [[ "${INPUT_S3_PORT}" =~ ^[0-9]+$ ]] || ((INPUT_S3_PORT < 1 || INPUT_S3_PORT > 65535)); then
    fail "Invalid s3-port '${INPUT_S3_PORT}': must be a port number between 1 and 65535."
  fi

  [[ "${INPUT_CONTAINER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
    fail "Invalid container-name '${INPUT_CONTAINER_NAME}': must be a valid docker container name."

  [[ "${INPUT_REGION}" =~ ^[A-Za-z0-9-]+$ ]] ||
    fail "Invalid region '${INPUT_REGION}': must contain only letters, digits and hyphens."

  if [[ -n "${INPUT_ACCESS_KEY_ID}" ]]; then
    [[ "${INPUT_ACCESS_KEY_ID}" =~ ^GK[A-Za-z0-9]+$ ]] ||
      fail "Invalid access-key-id: must start with 'GK' followed by alphanumeric characters."
  fi

  if [[ -n "${INPUT_ACCESS_KEY_ID}" && -z "${INPUT_SECRET_ACCESS_KEY}" ]] ||
    [[ -z "${INPUT_ACCESS_KEY_ID}" && -n "${INPUT_SECRET_ACCESS_KEY}" ]]; then
    fail "access-key-id and secret-access-key must be provided together."
  fi

  [[ "${INPUT_SET_AWS_ENV}" == "true" || "${INPUT_SET_AWS_ENV}" == "false" ]] ||
    fail "Invalid set-aws-env '${INPUT_SET_AWS_ENV}': must be 'true' or 'false'."
}

# --- Credentials and configuration ------------------------------------------

resolve_credentials() {
  if [[ -n "${INPUT_ACCESS_KEY_ID}" ]]; then
    ACCESS_KEY_ID="${INPUT_ACCESS_KEY_ID}"
    SECRET_ACCESS_KEY="${INPUT_SECRET_ACCESS_KEY}"
  else
    ACCESS_KEY_ID="GK$(openssl rand -hex 16)"
    SECRET_ACCESS_KEY="$(openssl rand -hex 32)"
  fi
}

write_config() {
  local config_path=$1
  cat > "${config_path}" <<EOF
metadata_dir = "/tmp/meta"
data_dir = "/tmp/data"
db_engine = "sqlite"

replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$(openssl rand -hex 32)"

[s3_api]
s3_region = "${INPUT_REGION}"
api_bind_addr = "[::]:${S3_CONTAINER_PORT}"
root_domain = ".s3.garage.localhost"
EOF
  if is_debug; then
    echo "::group::Generated garage.toml"
    # rpc_secret is sensitive; redact it even in debug output.
    sed 's/^rpc_secret = .*/rpc_secret = "***"/' "${config_path}"
    echo "::endgroup::"
  fi
}

# --- Service lifecycle -------------------------------------------------------

start_container() {
  local config_path=$1
  local rust_log="info"
  is_debug && rust_log="debug"

  # A leftover container with the same name blocks `docker run`; surface a
  # clear, actionable error instead of Docker's generic name-conflict message.
  if docker ps -a --format '{{.Names}}' | grep -qx "${INPUT_CONTAINER_NAME}"; then
    fail "A container named '${INPUT_CONTAINER_NAME}' already exists. Remove it or set a different 'container-name'."
  fi

  log "🚗 Starting Garage ${INPUT_GARAGE_VERSION} (container '${INPUT_CONTAINER_NAME}', port ${INPUT_S3_PORT})"

  # Pull explicitly so `docker run` doesn't dump pull progress into the log.
  # In debug mode, let the full pull output through.
  local image="${GARAGE_IMAGE}:${INPUT_GARAGE_VERSION}"
  if is_debug; then
    docker pull "${image}"
  else
    docker pull --quiet "${image}" > /dev/null
  fi

  docker run -d \
    --name "${INPUT_CONTAINER_NAME}" \
    -p "${INPUT_S3_PORT}:${S3_CONTAINER_PORT}" \
    -v "${config_path}:/etc/garage.toml:ro" \
    -e GARAGE_DEFAULT_ACCESS_KEY="${ACCESS_KEY_ID}" \
    -e GARAGE_DEFAULT_SECRET_KEY="${SECRET_ACCESS_KEY}" \
    -e GARAGE_DEFAULT_BUCKET="${INPUT_BUCKET}" \
    -e RUST_LOG="garage=${rust_log}" \
    "${image}" \
    /garage server --single-node --default-bucket > /dev/null
}

dump_container_logs() {
  echo "::group::Garage container logs"
  docker logs "${INPUT_CONTAINER_NAME}" 2>&1 || true
  echo "::endgroup::"
}

wait_until_ready() {
  log "⏳ Waiting for Garage to become ready (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    if docker exec "${INPUT_CONTAINER_NAME}" /garage bucket list 2> /dev/null |
      grep -qw "${INPUT_BUCKET}"; then
      log "✅ Garage is ready, bucket '${INPUT_BUCKET}' exists"
      is_debug && dump_container_logs
      return 0
    fi
    debug "Garage not ready yet, retrying..."
    sleep 1
  done
  dump_container_logs
  fail "Garage did not become ready within ${HEALTH_TIMEOUT_SECONDS}s."
}

# --- Outputs ------------------------------------------------------------------

emit_outputs() {
  local endpoint="http://localhost:${INPUT_S3_PORT}"

  echo "::add-mask::${SECRET_ACCESS_KEY}"

  {
    echo "s3-endpoint=${endpoint}"
    echo "region=${INPUT_REGION}"
    echo "bucket=${INPUT_BUCKET}"
    echo "access-key-id=${ACCESS_KEY_ID}"
    echo "secret-access-key=${SECRET_ACCESS_KEY}"
  } >> "${GITHUB_OUTPUT}"

  if [[ "${INPUT_SET_AWS_ENV}" == "true" ]]; then
    log "🔑 Exporting AWS_* environment variables for later steps"
    {
      echo "AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
      echo "AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}"
      echo "AWS_ENDPOINT_URL=${endpoint}"
      echo "AWS_REGION=${INPUT_REGION}"
      echo "AWS_DEFAULT_REGION=${INPUT_REGION}"
    } >> "${GITHUB_ENV}"
  fi

  notice "🪣 Garage S3 ready at ${endpoint} (region '${INPUT_REGION}', bucket s3://${INPUT_BUCKET})"
}

main() {
  validate_inputs
  resolve_credentials
  local config_path="${RUNNER_TEMP:-/tmp}/garage-${INPUT_CONTAINER_NAME}.toml"
  write_config "${config_path}"
  start_container "${config_path}"
  wait_until_ready
  emit_outputs
}

# Allow sourcing for unit tests without executing main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
