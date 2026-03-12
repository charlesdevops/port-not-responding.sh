# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] – 2026-03-12

### Fixed

- **`--no-color` flag** was positional (`$3`) and could not be passed without also providing
  `CONTAINER` as `$2`. Replaced with a pre-parse loop that strips `--no-color` from `"$@"`
  before positional extraction, so the flag can appear anywhere in the argument list.
- **`run()`** used `bash -c "$*"` — word-splitting on multi-word arguments. Changed to
  `bash -c "$1"` (single quoted argument, no splitting).
- **`log_raw()`** used `printf '%b\n'` which interprets backslash sequences (`\n`, `\t`, etc.)
  in data. Changed to `printf '%s\n'`.
- **ANSI codes in log file** — `log_raw()` was called with the already-coloured string, so
  escape sequences leaked into the log. Unified into a `strip_ansi()` pipeline; `log()` now
  always strips ANSI before writing to the file.
- **`_color()`** compared `"$NO_COLOR" == "false"` (string equality on a boolean variable).
  Changed to `[[ "$NO_COLOR" == false ]]`.
- **`require_root()`** used `echo -e` with raw ANSI variables before `NO_COLOR` was set.
  Replaced with a plain `echo ... >&2`.
- **Engine detection order** — `detect_engine()` preferred Podman over Docker when both were
  installed. Reversed: Docker is now checked first (it has a persistent daemon to inspect).
  Added `CONTAINER_ENGINE` environment variable override for explicit selection.
- **Double redirect** `&>/dev/null 2>&1` in `ip link show` calls. Removed the redundant `2>&1`.
- **`run()` log output** was not ANSI-stripped. Now uses `tee >(strip_ansi >> "$LOG_FILE")`
  process substitution.
- **`RESTART_COUNT` arithmetic on empty string** (Podman compat) would crash under `set -u`.
  Added `="${RESTART_COUNT:-0}"` default and a `=~ ^[0-9]+$` guard before the comparison.
- **Port mapping check** used `grep -q "HostPort"` — Podman JSON uses `host_port` (lowercase).
  Changed to `grep -qiE '"HostPort"|"host_port"'` for Docker + Podman compatibility.
- **`SYN_COUNT` / `SYNACK_COUNT` / `RST_COUNT`** used `|| echo "0"` after `grep -c` (which
  never fails with exit code 1 when there are zero matches). Removed the misleading fallback;
  added `="${VAR:-0}"` defaults.
- **`ENGINE_ROOTLESS`**, **`ENGINE_NET_BACKEND`** were never initialised when `ENGINE=="none"`,
  causing `set -u` to abort. Initialised to `""` in the `else` branch of `detect_engine()`.
- **`PRETTY_NAME`** was unbound if `/etc/os-release` was absent. Initialised to `"unknown"`
  before the `if` block in `detect_distro()`.
- **`TARGET_CONTAINER` regex** `[a-zA-Z0-9_.\-]` — unescaped `.` matches any character.
  Changed to `[a-zA-Z0-9_.-]+` (dot is literal inside `[]`).
- **SUMMARY box alignment** — `║` content line was shorter than the `╔`/`╚` border lines.
  Fixed padding to 60 characters.
- **`echo -e` in summary section** bypassed `log()` and was not written to the log file.
  Replaced with `log "$(_color ...)"`.
- **`cat <<'EOF'` checklist block** bypassed `log()` and was not written to the log file.
  Replaced with individual `log` calls.
- **Raw ANSI variables in `log()` arguments** (`${BOLD}`, `${RESET}`) leaked into the log file.
  Removed ANSI variables from all `log()` call sites.
- **README examples** — `sudo bash port-not-responding.sh 8080 --no-color` was incorrect:
  `--no-color` was parsed as `CONTAINER`. Updated all examples.

### Added

- `VERSION="1.0.0"` variable at the top of the script.
- `strip_ansi()` helper function (extracted from inline `sed` calls).
- `CONTAINER_ENGINE` environment variable to override engine auto-detection.
- `--no-color` documented in the script header comment under `Options:`.
- `CHANGELOG.md` (this file).
- `test/` directory with [bats](https://github.com/bats-core/bats-core) tests covering
  argument parsing and input validation.
- GitHub Actions workflow (`.github/workflows/ci.yml`) running `shellcheck` and `bash -n`
  on every push and pull request.
- GitLab CI pipeline (`.gitlab-ci.yml`) with equivalent checks.

---

## [0.0.9] – 2026-03-11

### Added

- Initial release.
- Full diagnostics for Docker and Podman (rootful & rootless).
- Auto-detection of distro family (Debian, RedHat, Photon, Generic).
- Sections: system info, engine status, container status, host networking, firewall,
  daemon config, local connectivity, TCP handshake analysis, journal/logs, cloud hints.
- ANSI-coloured stdout; ANSI-free log file.
