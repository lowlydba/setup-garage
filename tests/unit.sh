#!/usr/bin/env bash
#
# Unit tests for scripts/setup-garage.sh (no docker required).
# SC1090/SC1091: sourced path is dynamic by design; SC2030/SC2031: subshell
# isolation of GITHUB_* is intentional.
# shellcheck disable=SC1090,SC1091,SC2030,SC2031
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/../scripts/setup-garage.sh"

PASS=0
FAIL=0

# Baseline valid inputs; individual tests override single fields.
set_valid_inputs() {
  export INPUT_GARAGE_VERSION="v2.3.0"
  export INPUT_BUCKET="garage"
  export INPUT_ACCESS_KEY_ID=""
  export INPUT_SECRET_ACCESS_KEY=""
  export INPUT_REGION="garage-east-1"
  export INPUT_S3_PORT="3900"
  export INPUT_CONTAINER_NAME="garage"
  export INPUT_SET_AWS_ENV="true"
}

# run_validation <name=value>... -> runs validate_inputs in a subshell
run_validation() {
  (
    set_valid_inputs
    for override in "$@"; do
      export "${override?}"
    done
    # shellcheck source=../scripts/setup-garage.sh
    source "${SCRIPT_UNDER_TEST}"
    validate_inputs
  ) 2> /dev/null
}

assert_valid() {
  local desc=$1
  shift
  if run_validation "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: expected valid: ${desc}"
  fi
}

assert_invalid() {
  local desc=$1
  shift
  if run_validation "$@"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: expected invalid: ${desc}"
  else
    PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${desc}: expected '${expected}', got '${actual}'"
  fi
}

assert_match() {
  local desc=$1 pattern=$2 actual=$3
  if [[ "${actual}" =~ ${pattern} ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${desc}: '${actual}' does not match '${pattern}'"
  fi
}

# --- validate_inputs ----------------------------------------------------------

assert_valid "default inputs"
assert_valid "custom bucket" INPUT_BUCKET="my-test.bucket-1"
assert_valid "custom port" INPUT_S3_PORT="9000"
assert_valid "provided credentials" \
  INPUT_ACCESS_KEY_ID="GK31c5f2dab2a46c2a3b2653f3" INPUT_SECRET_ACCESS_KEY="secret"
assert_valid "set-aws-env false" INPUT_SET_AWS_ENV="false"

assert_invalid "empty version" INPUT_GARAGE_VERSION=""
assert_invalid "version with shell metachars" INPUT_GARAGE_VERSION='v2.3.0;rm -rf /'
assert_invalid "bucket too short" INPUT_BUCKET="ab"
assert_invalid "bucket with uppercase" INPUT_BUCKET="MyBucket"
assert_invalid "bucket too long" INPUT_BUCKET="$(printf 'a%.0s' {1..64})"
assert_invalid "non-numeric port" INPUT_S3_PORT="abc"
assert_invalid "port zero" INPUT_S3_PORT="0"
assert_invalid "port too large" INPUT_S3_PORT="70000"
assert_invalid "bad container name" INPUT_CONTAINER_NAME="bad name!"
assert_invalid "empty region" INPUT_REGION=""
assert_invalid "region with spaces" INPUT_REGION="us east"
assert_invalid "access key without GK prefix" \
  INPUT_ACCESS_KEY_ID="AKIA123" INPUT_SECRET_ACCESS_KEY="secret"
assert_invalid "access key without secret" INPUT_ACCESS_KEY_ID="GK31c5f2dab2a46c2a3b2653f3"
assert_invalid "secret without access key" INPUT_SECRET_ACCESS_KEY="secret"
assert_invalid "bad set-aws-env" INPUT_SET_AWS_ENV="yes"

# --- resolve_credentials --------------------------------------------------------

creds_output=$(
  set_valid_inputs
  source "${SCRIPT_UNDER_TEST}"
  resolve_credentials
  echo "${ACCESS_KEY_ID}|${SECRET_ACCESS_KEY}"
)
assert_match "generated access key format" '^GK[0-9a-f]{32}\|[0-9a-f]{64}$' "${creds_output}"

creds_output=$(
  set_valid_inputs
  export INPUT_ACCESS_KEY_ID="GKtest123" INPUT_SECRET_ACCESS_KEY="mysecret"
  source "${SCRIPT_UNDER_TEST}"
  resolve_credentials
  echo "${ACCESS_KEY_ID}|${SECRET_ACCESS_KEY}"
)
assert_eq "provided credentials passthrough" "GKtest123|mysecret" "${creds_output}"

# --- write_config ---------------------------------------------------------------

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

(
  set_valid_inputs
  export INPUT_REGION="my-region"
  source "${SCRIPT_UNDER_TEST}"
  write_config "${tmpdir}/garage.toml"
)
assert_match "config sets region" 's3_region = "my-region"' "$(cat "${tmpdir}/garage.toml")"
assert_match "config sets rpc secret" 'rpc_secret = "[0-9a-f]{64}"' "$(cat "${tmpdir}/garage.toml")"
assert_match "config single replication" 'replication_factor = 1' "$(cat "${tmpdir}/garage.toml")"

# --- emit_outputs ----------------------------------------------------------------

(
  set_valid_inputs
  export GITHUB_OUTPUT="${tmpdir}/output" GITHUB_ENV="${tmpdir}/env"
  : > "${GITHUB_OUTPUT}"
  : > "${GITHUB_ENV}"
  source "${SCRIPT_UNDER_TEST}"
  ACCESS_KEY_ID="GKabc" SECRET_ACCESS_KEY="s3cret"
  emit_outputs > "${tmpdir}/emit-stdout"
)
assert_match "output endpoint" 's3-endpoint=http://localhost:3900' "$(cat "${tmpdir}/output")"
assert_match "output access key" 'access-key-id=GKabc' "$(cat "${tmpdir}/output")"
assert_match "output secret" 'secret-access-key=s3cret' "$(cat "${tmpdir}/output")"
assert_match "output bucket" 'bucket=garage' "$(cat "${tmpdir}/output")"
assert_match "env AWS access key" 'AWS_ACCESS_KEY_ID=GKabc' "$(cat "${tmpdir}/env")"
assert_match "env AWS endpoint" 'AWS_ENDPOINT_URL=http://localhost:3900' "$(cat "${tmpdir}/env")"
assert_match "env AWS region" 'AWS_DEFAULT_REGION=garage-east-1' "$(cat "${tmpdir}/env")"
assert_match "emits ready notice" '::notice::.*Garage S3 ready at http://localhost:3900' "$(cat "${tmpdir}/emit-stdout")"

(
  set_valid_inputs
  export INPUT_SET_AWS_ENV="false"
  export GITHUB_OUTPUT="${tmpdir}/output2" GITHUB_ENV="${tmpdir}/env2"
  : > "${GITHUB_OUTPUT}"
  : > "${GITHUB_ENV}"
  source "${SCRIPT_UNDER_TEST}"
  ACCESS_KEY_ID="GKabc" SECRET_ACCESS_KEY="s3cret"
  emit_outputs > /dev/null
)
assert_eq "set-aws-env=false leaves GITHUB_ENV empty" "" "$(cat "${tmpdir}/env2")"
assert_match "set-aws-env=false still emits outputs" 'access-key-id=GKabc' "$(cat "${tmpdir}/output2")"

# --- color gating ----------------------------------------------------------------

color_off=$(
  set_valid_inputs
  unset GITHUB_ACTIONS
  source "${SCRIPT_UNDER_TEST}"
  printf '%s' "${C_DIM}${C_RESET}"
)
assert_eq "no ANSI color when not a tty and not in Actions" "" "${color_off}"

color_on=$(
  set_valid_inputs
  export GITHUB_ACTIONS=true
  source "${SCRIPT_UNDER_TEST}"
  printf '%s' "${C_DIM}"
)
assert_eq "ANSI color set in Actions" $'\033[2m' "${color_on}"

# --- debug mode ------------------------------------------------------------------

# is_debug reflects RUNNER_DEBUG and write_config redacts rpc_secret when on.
debug_off=$(
  set_valid_inputs
  unset RUNNER_DEBUG
  source "${SCRIPT_UNDER_TEST}"
  is_debug && echo "on" || echo "off"
)
assert_eq "is_debug off without RUNNER_DEBUG" "off" "${debug_off}"

debug_on=$(
  set_valid_inputs
  export RUNNER_DEBUG=1
  source "${SCRIPT_UNDER_TEST}" > /dev/null 2>&1
  { is_debug && echo "on" || echo "off"; } 2> /dev/null
)
assert_eq "is_debug on with RUNNER_DEBUG=1" "on" "${debug_on}"

(
  set_valid_inputs
  export RUNNER_DEBUG=1
  source "${SCRIPT_UNDER_TEST}" > /dev/null 2>&1
  write_config "${tmpdir}/garage-debug.toml" > "${tmpdir}/debug-config-out" 2>&1
) 2> /dev/null
assert_match "debug dumps config group" '::group::Generated garage.toml' "$(cat "${tmpdir}/debug-config-out")"
assert_match "debug redacts rpc secret" 'rpc_secret = "\*\*\*"' "$(cat "${tmpdir}/debug-config-out")"

# --- summary ---------------------------------------------------------------------

echo
echo "Passed: ${PASS}, Failed: ${FAIL}"
((FAIL == 0)) || exit 1
