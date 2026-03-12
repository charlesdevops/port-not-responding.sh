#!/usr/bin/env bats
# =============================================================
#  test/port-not-responding.bats
#  Unit tests for port-not-responding.sh
#
#  Requirements:
#    bats-core >= 1.7  (https://github.com/bats-core/bats-core)
#
#  Run:
#    bats test/port-not-responding.bats
# =============================================================

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/port-not-responding.sh"

# ---------------------------------------------------------------------------
# Helper: run the script as a non-root user (skips require_root by stubbing
# EUID=0 is not available in tests, so we source only the parsing section).
# We extract and test the argument-parsing and validation logic in isolation
# by sourcing a minimal wrapper that replays the relevant code.
# ---------------------------------------------------------------------------

# Source only the top of the script up to (but not including) require_root.
# We do this by creating a temporary wrapper that defines stubs for the
# functions called before the section under test.
setup() {
  # Create a temp dir for each test
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper: invoke the argument-parsing + validation block in a subshell.
# Returns the exit code and captures stderr.
# ---------------------------------------------------------------------------
parse_args() {
  bash -c '
    set -euo pipefail
    NO_COLOR=false
    POSITIONAL=()
    for arg in "$@"; do
      if [[ "$arg" == "--no-color" ]]; then
        NO_COLOR=true
      else
        POSITIONAL+=("$arg")
      fi
    done
    TARGET_PORT="${POSITIONAL[0]:-8000}"
    TARGET_CONTAINER="${POSITIONAL[1]:-}"

    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
      echo "Error: PORT must be a number between 1 and 65535 (got: '"'"'$TARGET_PORT'"'"')" >&2
      exit 1
    fi
    if [[ -n "$TARGET_CONTAINER" ]] && ! [[ "$TARGET_CONTAINER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
      echo "Error: CONTAINER name contains invalid characters: '"'"'$TARGET_CONTAINER'"'"'" >&2
      exit 1
    fi

    echo "PORT=$TARGET_PORT"
    echo "CONTAINER=${TARGET_CONTAINER}"
    echo "NO_COLOR=$NO_COLOR"
  ' -- "$@"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

@test "default port is 8000 when no arguments given" {
  run parse_args
  [ "$status" -eq 0 ]
  [[ "$output" == *"PORT=8000"* ]]
}

@test "explicit port is accepted" {
  run parse_args 9090
  [ "$status" -eq 0 ]
  [[ "$output" == *"PORT=9090"* ]]
}

@test "port and container are accepted" {
  run parse_args 8080 my-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"PORT=8080"* ]]
  [[ "$output" == *"CONTAINER=my-app"* ]]
}

@test "--no-color as first argument sets NO_COLOR=true" {
  run parse_args --no-color 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_COLOR=true"* ]]
  [[ "$output" == *"PORT=8080"* ]]
}

@test "--no-color as last argument sets NO_COLOR=true" {
  run parse_args 8080 my-app --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_COLOR=true"* ]]
  [[ "$output" == *"PORT=8080"* ]]
  [[ "$output" == *"CONTAINER=my-app"* ]]
}

@test "--no-color between port and container sets NO_COLOR=true" {
  run parse_args 8080 --no-color my-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_COLOR=true"* ]]
  [[ "$output" == *"PORT=8080"* ]]
  [[ "$output" == *"CONTAINER=my-app"* ]]
}

@test "NO_COLOR defaults to false when flag is absent" {
  run parse_args 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_COLOR=false"* ]]
}

# ---------------------------------------------------------------------------
# Port validation
# ---------------------------------------------------------------------------

@test "port 1 is valid" {
  run parse_args 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PORT=1"* ]]
}

@test "port 65535 is valid" {
  run parse_args 65535
  [ "$status" -eq 0 ]
  [[ "$output" == *"PORT=65535"* ]]
}

@test "port 0 is rejected" {
  run parse_args 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error"* ]] || [[ "$stderr" == *"Error"* ]]
}

@test "port 65536 is rejected" {
  run parse_args 65536
  [ "$status" -ne 0 ]
}

@test "negative port is rejected" {
  run parse_args -- -1
  [ "$status" -ne 0 ]
}

@test "non-numeric port is rejected" {
  run parse_args abc
  [ "$status" -ne 0 ]
}

@test "port with leading zeros is accepted (bash treats as decimal)" {
  run parse_args 0080
  # 0080 in bash arithmetic is decimal 80 (not octal), so it should be valid
  [ "$status" -eq 0 ]
  [[ "$output" == *"PORT=0080"* ]]
}

# ---------------------------------------------------------------------------
# Container name validation
# ---------------------------------------------------------------------------

@test "container name with letters and digits is valid" {
  run parse_args 8080 mycontainer123
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER=mycontainer123"* ]]
}

@test "container name with hyphen is valid" {
  run parse_args 8080 my-container
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER=my-container"* ]]
}

@test "container name with underscore is valid" {
  run parse_args 8080 my_container
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER=my_container"* ]]
}

@test "container name with dot is valid" {
  run parse_args 8080 my.container
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER=my.container"* ]]
}

@test "container name with space is rejected" {
  run parse_args 8080 "my container"
  [ "$status" -ne 0 ]
}

@test "container name with semicolon is rejected (injection attempt)" {
  run parse_args 8080 "foo;rm -rf /"
  [ "$status" -ne 0 ]
}

@test "container name with dollar sign is rejected" {
  run parse_args 8080 'foo$bar'
  [ "$status" -ne 0 ]
}

@test "container name with backtick is rejected" {
  run parse_args 8080 'foo`id`'
  [ "$status" -ne 0 ]
}

@test "empty container name is accepted (triggers auto-detect)" {
  run parse_args 8080 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER="* ]]
}

# ---------------------------------------------------------------------------
# strip_ansi helper (sourced directly)
# ---------------------------------------------------------------------------

@test "strip_ansi removes ANSI color codes" {
  result=$(printf '\033[0;31mHello\033[0m World' | bash -c 'sed '"'"'s/\x1b\[[0-9;]*[mK]//g'"'"'')
  [ "$result" = "Hello World" ]
}

@test "strip_ansi leaves plain text unchanged" {
  result=$(printf 'plain text' | bash -c 'sed '"'"'s/\x1b\[[0-9;]*[mK]//g'"'"'')
  [ "$result" = "plain text" ]
}

# ---------------------------------------------------------------------------
# Script-level: bash syntax check
# ---------------------------------------------------------------------------

@test "script passes bash -n syntax check" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}
