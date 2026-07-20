#!/usr/bin/env bash
#
# Shared helpers for the scripts in this directory. Sourced, never executed.

# Colours, but only when stdout is a terminal - otherwise CI logs fill up with
# escape sequences.
if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_RED=$'\033[0;31m'
  readonly C_GREEN=$'\033[0;32m'
  readonly C_YELLOW=$'\033[0;33m'
else
  readonly C_RESET="" C_RED="" C_GREEN="" C_YELLOW=""
fi

log_info() { printf '%s==>%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn() { printf '%s==>%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_error() { printf '%serror:%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# require_command <name> [install-hint]
require_command() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    if [[ -n "${hint}" ]]; then
      die "'${cmd}' is not installed. ${hint}"
    fi
    die "'${cmd}' is not installed or not on PATH."
  fi
}

ensure_docker_running() {
  if ! docker info >/dev/null 2>&1; then
    die "Docker does not appear to be running. Start Docker Desktop (or your engine of choice) and retry."
  fi
}

# confirm <prompt> - returns 0 on yes. Auto-confirms when ASSUME_YES=1 so the
# destructive scripts can be driven from CI or a Makefile.
confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}
