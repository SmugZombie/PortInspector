#!/usr/bin/env bash

# macOS Port Inspector
# Lists listening and active network ports with process details.

set -euo pipefail

# -----------------------------
# Colors / styling
# -----------------------------
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

BLUE="\033[34m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
MAGENTA="\033[35m"
GRAY="\033[90m"

line() {
  printf "${GRAY}%s${RESET}\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────"
}

title() {
  clear
  line
  printf "${BOLD}${CYAN}%-100s${RESET}\n" " macOS Port Inspector"
  printf "${DIM} %-100s ${RESET}\n" " Listening ports, active connections, process owners, commands, and paths"
  line
}

usage() {
  cat <<EOF
Usage:
  ./ports.sh [option]

Options:
  --listening     Show only listening ports
  --active        Show only established/active connections
  --all           Show all network port usage, including listening and active connections
  --sudo          Re-run with sudo for more complete process details
  --help          Show this help

Examples:
  ./ports.sh
  ./ports.sh --listening
  ./ports.sh --active
  ./ports.sh --all
  ./ports.sh --sudo
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

get_process_details() {
  local pid="$1"

  if [[ -z "$pid" || "$pid" == "-" ]]; then
    printf "%-12s %-20s %-40s %-50s" "-" "-" "-" "-"
    return
  fi

  local user command started path

  user="$(ps -p "$pid" -o user= 2>/dev/null | awk '{$1=$1};1')"
  command="$(ps -p "$pid" -o comm= 2>/dev/null | awk '{$1=$1};1')"
  started="$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1};1')"
  path="$(lsof -p "$pid" 2>/dev/null | awk '$4 == "txt" {print $9; exit}')"

  [[ -z "$user" ]] && user="-"
  [[ -z "$command" ]] && command="-"
  [[ -z "$started" ]] && started="-"
  [[ -z "$path" ]] && path="-"

  printf "%-12s %-20s %-40s %-50s" "$user" "$command" "$started" "$path"
}

print_header() {
  printf "${BOLD}${BLUE}%-8s %-8s %-10s %-22s %-22s %-14s %-12s %-20s %-40s %-50s${RESET}\n" \
    "PROTO" "PORT" "STATE" "LOCAL" "REMOTE" "PID" "USER" "PROCESS" "STARTED" "PATH"

  printf "${GRAY}%-8s %-8s %-10s %-22s %-22s %-14s %-12s %-20s %-40s %-50s${RESET}\n" \
    "─────" "────" "─────" "─────" "──────" "───" "────" "───────" "───────" "────"
}

print_lsof_rows() {
  local mode="$1"

  local lsof_args=(-nP -iTCP -iUDP)

  case "$mode" in
    listening)
      lsof_args=(-nP -iTCP -sTCP:LISTEN)
      ;;
    active)
      lsof_args=(-nP -iTCP -sTCP:ESTABLISHED)
      ;;
    all)
      lsof_args=(-nP -iTCP -iUDP)
      ;;
  esac

  lsof "${lsof_args[@]}" 2>/dev/null | awk '
    NR > 1 {
      command=$1
      pid=$2
      user=$3
      proto=$8
      name=""

      for (i=9; i<=NF; i++) {
        name = name $i " "
      }

      state="-"
      if (name ~ /\(LISTEN\)/) state="LISTEN"
      else if (name ~ /\(ESTABLISHED\)/) state="ACTIVE"
      else if (name ~ /\(CLOSE_WAIT\)/) state="CLOSE_WAIT"
      else if (name ~ /\(SYN_SENT\)/) state="SYN_SENT"
      else if (name ~ /\(UDP\)/) state="UDP"

      gsub(/\([A-Z_]+\)/, "", name)
      gsub(/^ +| +$/, "", name)

      split(name, parts, "->")
      local=parts[1]
      remote="-"

      if (length(parts[2]) > 0) {
        remote=parts[2]
      }

      port="-"
      if (match(local, /:[0-9]+$/)) {
        port=substr(local, RSTART+1, RLENGTH-1)
      }

      print proto "|" port "|" state "|" local "|" remote "|" pid
    }
  ' | sort -t '|' -k2,2n -k1,1 | while IFS='|' read -r proto port state local remote pid; do

    local state_color="$RESET"

    case "$state" in
      LISTEN)
        state_color="$GREEN"
        ;;
      ACTIVE)
        state_color="$CYAN"
        ;;
      CLOSE_WAIT|SYN_SENT)
        state_color="$YELLOW"
        ;;
      *)
        state_color="$MAGENTA"
        ;;
    esac

    printf "%-8s %-8s ${state_color}%-10s${RESET} %-22s %-22s %-14s " \
      "$proto" "$port" "$state" "$local" "$remote" "$pid"

    get_process_details "$pid"
    printf "\n"
  done
}

summary() {
  echo
  line

  local listening active udp total

  listening="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $2}' | sort -u | wc -l | tr -d ' ')"
  active="$(lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | awk 'NR > 1 {print $2}' | sort -u | wc -l | tr -d ' ')"
  udp="$(lsof -nP -iUDP 2>/dev/null | awk 'NR > 1 {print $2}' | sort -u | wc -l | tr -d ' ')"
  total="$(lsof -nP -iTCP -iUDP 2>/dev/null | awk 'NR > 1 {print $2}' | sort -u | wc -l | tr -d ' ')"

  printf "${BOLD}${CYAN}Summary${RESET}\n"
  printf "  ${GREEN}Listening processes:${RESET} %s\n" "$listening"
  printf "  ${CYAN}Active TCP processes:${RESET} %s\n" "$active"
  printf "  ${MAGENTA}UDP processes:${RESET} %s\n" "$udp"
  printf "  ${YELLOW}Total unique network processes:${RESET} %s\n" "$total"

  echo
  printf "${DIM}Tip: run with ${BOLD}sudo ./ports.sh${RESET}${DIM} or ${BOLD}./ports.sh --sudo${RESET}${DIM} to reveal more process details.${RESET}\n"
}

main() {
  require_command lsof
  require_command ps
  require_command awk
  require_command sort

  local mode="all"

  case "${1:-}" in
    --listening)
      mode="listening"
      ;;
    --active)
      mode="active"
      ;;
    --all|"")
      mode="all"
      ;;
    --sudo)
      exec sudo "$0" --all
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo
      usage
      exit 1
      ;;
  esac

  title

  case "$mode" in
    listening)
      printf "${BOLD}${GREEN}Showing listening ports only${RESET}\n\n"
      ;;
    active)
      printf "${BOLD}${CYAN}Showing active TCP connections only${RESET}\n\n"
      ;;
    all)
      printf "${BOLD}${YELLOW}Showing all TCP/UDP network port usage${RESET}\n\n"
      ;;
  esac

  print_header
  print_lsof_rows "$mode"
  summary
}

main "$@"
