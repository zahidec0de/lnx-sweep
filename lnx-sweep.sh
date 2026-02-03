#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="lnx-sweep"
readonly SCRIPT_VERSION="1.1"
readonly DISPLAY_NAME="Lnx-Sweep"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------- color handling ---------
USE_COLOR=true
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  USE_COLOR=false
fi

c_reset=""
c_red=""
c_green=""
c_yellow=""
c_blue=""
c_cyan=""
c_white=""
c_bold=""
c_dim=""
c_teal=""

if [[ "$USE_COLOR" == true ]]; then
  c_reset="\033[0m"
  c_red="\033[0;31m"
  c_green="\033[0;32m"
  c_yellow="\033[0;33m"
  c_blue="\033[0;34m"
  c_cyan="\033[0;36m"
  c_white="\033[1;37m"
  c_bold="\033[1m"
  c_dim="\033[2m"
  c_teal="\033[0;36m"
fi

# --------- global state ---------
LOG_FILE=""
ERROR_LOG_FILE=""
BACKUP_DIR=""
DRY_RUN=false
DRY_RUN_SUMMARY=false
FORCE_MODE=false
PLAN_ONLY=false
TOTAL_FREED=0
TOTAL_MOVED=0
TOTAL_ESTIMATED=0
START_TIME=$(date +%s)
CUSTOM_DELETE_MODE=false
CUSTOM_DELETE_CMD=""
CUSTOM_DELETE_PATHS=()
BACKUP_MODE=false
JSON_REPORT=false
JSON_REPORT_PATH=""
EXCLUDE_PATHS=()
INCLUDE_PATTERNS=()

readonly TMP_AGE_DAYS_DEFAULT=3
readonly LOG_AGE_DAYS_DEFAULT=30
readonly JOURNAL_MAX_SIZE_DEFAULT="500M"
readonly APT_CACHE_MIN_MB_DEFAULT=100
readonly USER_CACHE_MIN_MB_DEFAULT=50
readonly COREDUMP_MAX_AGE_DAYS_DEFAULT=7
readonly CRASH_MAX_AGE_DAYS_DEFAULT=7

TMP_AGE_DAYS="$TMP_AGE_DAYS_DEFAULT"
LOG_AGE_DAYS="$LOG_AGE_DAYS_DEFAULT"
JOURNAL_MAX_SIZE="$JOURNAL_MAX_SIZE_DEFAULT"
APT_CACHE_MIN_MB="$APT_CACHE_MIN_MB_DEFAULT"
USER_CACHE_MIN_MB="$USER_CACHE_MIN_MB_DEFAULT"
COREDUMP_MAX_AGE_DAYS="$COREDUMP_MAX_AGE_DAYS_DEFAULT"
CRASH_MAX_AGE_DAYS="$CRASH_MAX_AGE_DAYS_DEFAULT"

RUN_APT_CACHE=true
RUN_APT_LISTS=true
RUN_LOGS=true
RUN_TEMP=true
RUN_USER_CACHE=true
RUN_TRASH=true
RUN_SNAP=true
RUN_PENTEST=true
RUN_DOCKER=true
RUN_KERNELS=true
RUN_COREDUMPS=true
RUN_CRASH_REPORTS=true
readonly CRITICAL_PATHS=(
  "/" "/bin" "/boot" "/dev" "/etc" "/lib" "/lib64" "/proc" "/sys" "/usr"
  "/var/lib/dpkg" "/var/lib/apt" "/var/run" "/var/lock" "/home" "/root"
)

readonly CUSTOM_DELETE_PROTECTED_PATHS=(
  "/" "/bin" "/boot" "/dev" "/etc" "/lib" "/lib64" "/proc" "/sys" "/usr"
  "/var/lib/dpkg" "/var/lib/apt" "/var/run" "/var/lock"
)

# --------- output helpers ---------
log_to_file() {
  local level="$1" message="$2"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

msg_info()    { echo -e "${c_blue}[INFO]${c_reset} $1"; log_to_file "INFO" "$1"; }
msg_warn()    { echo -e "${c_yellow}[WARN]${c_reset} $1"; log_to_file "WARN" "$1"; }
msg_error()   { echo -e "${c_red}[ERROR]${c_reset} $1"; log_to_file "ERROR" "$1"; }
msg_success() { echo -e "${c_green}[OK]${c_reset} $1"; log_to_file "OK" "$1"; }

UI_WIDTH=90
ui_init() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 90)
  if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
    cols=90
  fi
  if (( cols < 80 )); then
    cols=80
  elif (( cols > 100 )); then
    cols=100
  fi
  UI_WIDTH="$cols"
}

repeat_char() {
  local char="$1" count="$2" out=""
  for ((i=0; i<count; i++)); do out+="$char"; done
  echo "$out"
}

center_text() {
  local text="$1"
  local width="$2"
  local len=${#text}
  local pad=$(( (width - len) / 2 ))
  if (( pad < 0 )); then pad=0; fi
  printf "%*s%s%*s" "$pad" "" "$text" "$((width - len - pad))" ""
}

source "${SCRIPT_DIR}/banner.sh"


print_section() {
  local title="$1"
  local rule
  rule=$(repeat_char "─" "$UI_WIDTH")
  echo -e "${c_teal}${rule}${c_reset}"
  echo -e "${c_white}${c_bold}◆ ${title}${c_reset}"
  echo -e "${c_teal}${rule}${c_reset}"
}

print_section_end() {
  echo
}

print_kv_table() {
  local pairs=("$@")
  local left_label left_value right_label right_value
  local content_width=$((UI_WIDTH))
  local left_width=$(( (content_width - 3) / 2 ))
  local right_width=$(( content_width - 3 - left_width ))
  for ((i=0; i<${#pairs[@]}; i+=2)); do
    IFS=':' read -r left_label left_value <<< "${pairs[i]}"
    IFS=':' read -r right_label right_value <<< "${pairs[i+1]}"
    echo -e "$(printf "%-*s %-*s" \
      "$left_width" "${c_teal}${left_label}:${c_reset} ${c_white}${left_value}${c_reset}" \
      "$right_width" "${c_teal}${right_label}:${c_reset} ${c_white}${right_value}${c_reset}")"
  done
}

print_menu() {
  local lines=("$@")
  local line
  for line in "${lines[@]}"; do
    printf "%b\n" " ${c_cyan}•${c_reset} ${c_white}${line}${c_reset}"
  done
}

print_menu_item() {
  local key="$1"
  local desc="$2"
  local color="$c_white"
  case "$key" in
    1) color="$c_green" ;;
    2) color="$c_cyan" ;;
    3) color="$c_red" ;;
    4) color="$c_yellow" ;;
    5) color="$c_blue" ;;
    6) color="$c_cyan" ;;
    7) color="$c_yellow" ;;
    h) color="$c_cyan" ;;
    q) color="$c_red" ;;
  esac
  printf "%b %b%s%b\n" "${c_teal}${key})${c_reset}" "${color}" "${desc}" "${c_reset}"
}

section() {
  echo -e "${c_teal}${c_bold}== ${c_white}${1}${c_teal} ==${c_reset}"
}

print_status_line() {
  local label="$1"
  local state="$2"
  if [[ "$state" == "OK" ]]; then
    echo -e "${c_cyan}[STATUS]${c_reset} ${c_white}${label}${c_reset}: ${c_green}${state}${c_reset}"
  else
    echo -e "${c_cyan}[STATUS]${c_reset} ${c_white}${label}${c_reset}: ${c_red}${state}${c_reset}"
  fi
}

make_usage_bar() {
  local percent="$1"
  local width=45
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local bar=""
  local bar_color="$c_green"
  if (( percent >= 80 )); then
    bar_color="$c_red"
  elif (( percent >= 60 )); then
    bar_color="$c_yellow"
  fi
  for ((i=0; i<filled; i++)); do bar+="#"; done
  for ((i=0; i<empty; i++)); do bar+="."; done
  echo "${bar_color}${bar}${c_reset}"
}

confirm() {
  local prompt="$1" default_no="${2:-true}"
  if [[ "$FORCE_MODE" == true ]]; then
    return 0
  fi
  if [[ "$PLAN_ONLY" == true ]]; then
    msg_info "PLAN: auto-approve prompt: $prompt"
    return 0
  fi
  if [[ "$default_no" == true ]]; then
    echo -ne "${c_yellow}${prompt} [y/N]: ${c_reset}"
  else
    echo -ne "${c_yellow}${prompt} [Y/n]: ${c_reset}"
  fi
  local response
  read -r response
  if [[ "$default_no" == true ]]; then
    [[ "$response" =~ ^[Yy]$ ]]
  else
    [[ ! "$response" =~ ^[Nn]$ ]]
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true ]]; then
    msg_info "PREVIEW: $*"
    return 0
  fi
  "$@"
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_size_string() {
  [[ "$1" =~ ^[0-9]+[KMG]?$ ]]
}

safe_rm_rf() {
  local target="$1"
  if [[ -z "$target" ]]; then
    msg_warn "Refusing to remove empty path"
    return 1
  fi
  if [[ "$target" == "/" ]]; then
    msg_warn "Refusing to remove root path"
    return 1
  fi
  if is_critical_path "$target"; then
    msg_warn "Refusing to remove critical path: $target"
    return 1
  fi
  delete_path "$target"
}

safe_clean_dir() {
  local dir="$1"
  if [[ -z "$dir" || "$dir" == "/" ]]; then
    msg_warn "Refusing to clean invalid directory"
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    msg_warn "Directory not found: $dir"
    return 1
  fi
  if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
    msg_info "PREVIEW: remove contents of $dir"
  fi
  local item
  while IFS= read -r -d '' item; do
    delete_path "$item"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

contains_glob_chars() {
  local path="$1"
  [[ "$path" == *"*"* || "$path" == *"?"* || "$path" == *"["* ]]
}

ensure_backup_dir() {
  if [[ "$BACKUP_MODE" != true ]]; then
    return 0
  fi
  if [[ -z "$BACKUP_DIR" ]]; then
    msg_error "Backup directory is not set"
    return 1
  fi
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
}

should_skip_path() {
  local path="$1"
  local ex
  for ex in "${EXCLUDE_PATHS[@]}"; do
    if [[ "$path" == "$ex" || "$path" == "$ex"/* ]]; then
      msg_info "Skipping excluded path: $path"
      return 0
    fi
  done
  if [[ ${#INCLUDE_PATTERNS[@]} -gt 0 ]]; then
    local match=false
    local pat
    for pat in "${INCLUDE_PATTERNS[@]}"; do
      if [[ "$path" == $pat ]]; then
        match=true
        break
      fi
    done
    if [[ "$match" == false ]]; then
      msg_info "Skipping non-matching path: $path"
      return 0
    fi
  fi
  return 1
}

delete_glob() {
  local pattern="$1"
  local matches=()
  shopt -s nullglob
  matches=($pattern)
  shopt -u nullglob
  local m
  for m in "${matches[@]}"; do
    delete_path "$m"
  done
}

delete_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if should_skip_path "$path"; then
    return 0
  fi

  if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
    if [[ "$DRY_RUN_SUMMARY" == true ]]; then
      local estimated
      estimated=$(get_path_size_bytes "$path")
      TOTAL_ESTIMATED=$((TOTAL_ESTIMATED + estimated))
    fi
    msg_info "PREVIEW: delete $path"
    return 0
  fi

  if [[ "$BACKUP_MODE" == true ]]; then
    ensure_backup_dir || return 1
    local size
    size=$(get_path_size_bytes "$path")
    local dest="${BACKUP_DIR}${path}"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    mv -- "$path" "$dest" 2>/dev/null || {
      msg_warn "Backup move failed for: $path"
      return 1
    }
    TOTAL_MOVED=$((TOTAL_MOVED + size))
    msg_success "Backed up: $path"
    return 0
  fi

  if [[ -d "$path" ]]; then
    rm -rf -- "$path" 2>/dev/null || true
  else
    rm -f -- "$path" 2>/dev/null || true
  fi
  return 0
}

is_custom_protected_path() {
  local path="$1"
  for critical in "${CUSTOM_DELETE_PROTECTED_PATHS[@]}"; do
    if [[ "$path" == "$critical" ]] || [[ "$path" == "$critical"/* ]]; then
      return 0
    fi
  done
  return 1
}

validate_custom_delete_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    msg_error "Custom delete path is empty"
    return 1
  fi
  if [[ "$path" == "/" || "$path" == "." || "$path" == ".." ]]; then
    msg_error "Refusing to delete unsafe path: $path"
    return 1
  fi
  if [[ "$path" != /* ]]; then
    msg_error "Custom delete path must be absolute: $path"
    return 1
  fi
  if contains_glob_chars "$path"; then
    msg_error "Glob patterns are not allowed in custom delete paths: $path"
    return 1
  fi
  if [[ ! -e "$path" ]]; then
    msg_error "Custom delete path not found: $path"
    return 1
  fi
  if is_custom_protected_path "$path"; then
    msg_error "Refusing to delete protected system path: $path"
    return 1
  fi
  if [[ "$path" == "/home" || "$path" == "/root" ]]; then
    msg_error "Refusing to delete top-level home directory: $path"
    return 1
  fi
  return 0
}

preview_custom_delete() {
  local path="$1"
  section "Safe Delete Preview"
  echo -e "  Target: ${c_cyan}${path}${c_reset}"
  if [[ -f "$path" || -L "$path" ]]; then
    echo -e "  Type: ${c_yellow}File${c_reset}"
    ls -lah -- "$path" 2>/dev/null || true
    echo
    return 0
  fi
  if [[ -d "$path" ]]; then
    echo -e "  Type: ${c_yellow}Directory${c_reset}"
    if command -v du >/dev/null 2>&1; then
      echo -e "  Total size: ${c_green}$(du -sh -- "$path" 2>/dev/null | awk '{print $1}')${c_reset}"
    fi
    echo -e "  Top items (depth 1):"
    du -h --max-depth=1 -- "$path" 2>/dev/null | sort -hr | head -n 20 || true
    echo
    echo -e "  Sample contents (depth 2, first 200):"
    find "$path" -maxdepth 2 -mindepth 1 -print 2>/dev/null | head -n 200 || true
    echo
    return 0
  fi
  msg_warn "Unknown file type for: $path"
}

delete_custom_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    run_cmd rm -rf -- "$path"
  else
    run_cmd rm -f -- "$path"
  fi
}

run_custom_delete() {
  local path="$1"
  if ! validate_custom_delete_path "$path"; then
    return 1
  fi
  preview_custom_delete "$path"
  if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true ]]; then
    msg_info "PREVIEW: would delete $path"
    return 0
  fi
  if ! confirm "Delete this path now?" true; then
    msg_info "Safe delete cancelled"
    return 0
  fi
  delete_custom_path "$path"
  msg_success "Deleted: $path"
}

parse_safe_rm_command() {
  local cmd="$1"
  local -a parts=()
  read -r -a parts <<< "$cmd"
  if [[ ${#parts[@]} -lt 2 ]]; then
    msg_error "Invalid rm command"
    return 1
  fi
  if [[ "${parts[0]}" != "rm" ]]; then
    msg_error "Only rm commands are allowed"
    return 1
  fi

  local -a allowed_flags=("-r" "-rf" "-fr" "-R")
  local path=""
  local i
  for ((i=1; i<${#parts[@]}; i++)); do
    local token="${parts[$i]}"
    if [[ "$token" == -* ]]; then
      local ok=false
      local flag
      for flag in "${allowed_flags[@]}"; do
        if [[ "$token" == "$flag" ]]; then
          ok=true
          break
        fi
      done
      if [[ "$ok" == false ]]; then
        msg_error "Disallowed rm flag: $token"
        return 1
      fi
    else
      if [[ -n "$path" ]]; then
        msg_error "Only one path is allowed for safe rm"
        return 1
      fi
      path="$token"
    fi
  done

  if [[ -z "$path" ]]; then
    msg_error "No path provided in rm command"
    return 1
  fi
  echo "$path"
}

# --------- system info ---------
setup_log_files() {
  local user_only_mode="$1"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  if [[ "$user_only_mode" == "true" ]]; then
    if [[ -w "$HOME" ]]; then
      LOG_FILE="$HOME/.cache/${SCRIPT_NAME}-${timestamp}.log"
      ERROR_LOG_FILE="$HOME/.cache/${SCRIPT_NAME}-errors-${timestamp}.log"
      BACKUP_DIR="$HOME/.cache/${SCRIPT_NAME}-backup-${timestamp}"
      mkdir -p "$HOME/.cache" 2>/dev/null || true
    else
      LOG_FILE="/tmp/${SCRIPT_NAME}-${timestamp}.log"
      ERROR_LOG_FILE="/tmp/${SCRIPT_NAME}-errors-${timestamp}.log"
      BACKUP_DIR="/tmp/${SCRIPT_NAME}-backup-${timestamp}"
    fi
  else
    LOG_FILE="/var/log/${SCRIPT_NAME}-${timestamp}.log"
    ERROR_LOG_FILE="/var/log/${SCRIPT_NAME}-errors-${timestamp}.log"
    BACKUP_DIR="/var/backups/${SCRIPT_NAME}-${timestamp}"
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Root privileges required for system cleanup."
    echo -e "${c_cyan}Tip:${c_reset} use: sudo $0 --user-only"
    exit 1
  fi
}

detect_distribution() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

system_profile() {
  local distro
  distro=$(detect_distribution)
  case "$distro" in
    kali|parrot) echo "pentesting" ;;
    ubuntu|linuxmint|mint) echo "desktop" ;;
    debian) echo "debian" ;;
    *) echo "debian-compatible" ;;
  esac
}

# --------- utilities ---------
check_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    msg_error "Missing required command: $cmd"
    return 1
  fi
}

get_disk_space() {
  df -h / | awk 'NR==2 {print $3, $4, $5}'
}

get_dir_size_bytes() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    if du -sb "$dir" >/dev/null 2>&1; then
      du -sb "$dir" 2>/dev/null | cut -f1
    else
      local kb
      kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
      echo $((kb * 1024))
    fi
  else
    echo 0
  fi
}

get_path_size_bytes() {
  local path="$1"
  if [[ -d "$path" ]]; then
    get_dir_size_bytes "$path"
  elif [[ -e "$path" ]]; then
    stat -c %s -- "$path" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

bytes_to_human() {
  local bytes="$1"
  if [[ $bytes -ge 1073741824 ]]; then
    printf '%d.%dGB' $((bytes / 1073741824)) $(((bytes % 1073741824) / 107374182))
  elif [[ $bytes -ge 1048576 ]]; then
    printf '%d.%dMB' $((bytes / 1048576)) $(((bytes % 1048576) / 104857))
  elif [[ $bytes -ge 1024 ]]; then
    printf '%dKB' $((bytes / 1024))
  else
    printf '%dB' "$bytes"
  fi
}

is_critical_path() {
  local path="$1"
  for critical in "${CRITICAL_PATHS[@]}"; do
    if [[ "$path" == "$critical" ]] || [[ "$path" == "$critical"/* ]]; then
      return 0
    fi
  done
  return 1
}

# --------- UI ---------
show_disk_summary() {
  local disk_info
  disk_info=($(get_disk_space))
  local used="${disk_info[0]}" free="${disk_info[1]}" usage="${disk_info[2]}"
  local usage_percent="${usage%?}"
  local bar
  bar=$(make_usage_bar "$usage_percent")
  local usage_color="$c_green"
  if (( usage_percent >= 80 )); then
    usage_color="$c_red"
  elif (( usage_percent >= 60 )); then
    usage_color="$c_yellow"
  fi
  print_section "Disk Usage"
  printf "%b\n" "Root FS : ${usage_color}${usage}${c_reset} used  |  Used: ${c_yellow}${used}${c_reset}  Free: ${c_green}${free}${c_reset}"
  printf "%b\n" "Usage Bar : [${bar}]"
  print_section_end
  echo
}

safe_delete_interactive() {
  section "Safe Delete"
  echo -e "  Enter an absolute path or an rm command (e.g., rm -r /path):"
  echo -ne "${c_yellow}Input: ${c_reset}"
  local input
  read -r input
  if [[ -z "$input" ]]; then
    msg_warn "No input provided"
    return 1
  fi

  local path="$input"
  if [[ "$input" == rm\ * ]]; then
    path=$(parse_safe_rm_command "$input") || return 1
  fi
  run_custom_delete "$path"
}

# --------- safety checks ---------
preflight_checks() {
  local required=(df du find awk sort head)

  for cmd in "${required[@]}"; do
    check_command "$cmd" || {
      exit 1
    }
  done

  local disk_info
  disk_info=($(get_disk_space))
  local usage_percent="${disk_info[2]%?}"
  if [[ "$usage_percent" -gt 95 ]]; then
    msg_warn "Disk usage is critically high (${usage_percent}%)"
  fi
}

# --------- cleanup actions ---------
cleanup_apt_cache() {
  if [[ "$RUN_APT_CACHE" != true ]]; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    msg_warn "APT not found; skipping APT cache cleanup"
    return 0
  fi

  section "APT Package Cache"
  local cache_size
  cache_size=$(get_dir_size_bytes "/var/cache/apt/archives")
  echo -e "  Current cache size: ${c_cyan}$(bytes_to_human "$cache_size")${c_reset}"

  local min_bytes=$((APT_CACHE_MIN_MB * 1024 * 1024))
  if [[ $cache_size -lt $min_bytes ]]; then
    msg_info "APT cache is already small"
    return 0
  fi

  if ! confirm "Clear APT cache and remove unused packages?" false; then
    msg_info "APT cache cleanup skipped"
    return 0
  fi

  run_cmd apt-get clean || msg_warn "apt-get clean failed"
  run_cmd apt-get autoremove -y || msg_warn "apt-get autoremove failed"
  run_cmd apt-get autoclean || msg_warn "apt-get autoclean failed"

  local cache_after
  cache_after=$(get_dir_size_bytes "/var/cache/apt/archives")
  local freed=$((cache_size - cache_after))
  TOTAL_FREED=$((TOTAL_FREED + freed))
  msg_success "APT cache cleaned ($(bytes_to_human "$freed") freed)"
}

cleanup_apt_lists() {
  if [[ "$RUN_APT_LISTS" != true ]]; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    msg_warn "APT not found; skipping APT list cleanup"
    return 0
  fi

  section "APT Package Lists"
  if [[ ! -d /var/lib/apt/lists ]]; then
    msg_info "APT lists directory not found"
    return 0
  fi

  local lists_size
  lists_size=$(get_dir_size_bytes "/var/lib/apt/lists")
  echo -e "  Current lists size: ${c_cyan}$(bytes_to_human "$lists_size")${c_reset}"
  echo -e "  Note: apt update will be required after removal"

  if ! confirm "Remove APT package lists? (requires apt update later)" true; then
    msg_info "APT list cleanup skipped"
    return 0
  fi

  safe_clean_dir "/var/lib/apt/lists"
  msg_success "APT package lists removed"
}

cleanup_system_logs() {
  if [[ "$RUN_LOGS" != true ]]; then
    return 0
  fi

  section "System Logs"

  if command -v journalctl >/dev/null 2>&1; then
    echo -e "  Journal vacuum: older than ${LOG_AGE_DAYS} days and size ${JOURNAL_MAX_SIZE}"
    if confirm "Vacuum journal logs now?" false; then
      run_cmd journalctl --vacuum-time="${LOG_AGE_DAYS}d" >/dev/null 2>&1 || true
      run_cmd journalctl --vacuum-size="${JOURNAL_MAX_SIZE}" >/dev/null 2>&1 || true
      msg_success "Journal logs cleaned"
    else
      msg_info "Journal cleanup skipped"
    fi
  fi

  local log_patterns=(
    "/var/log/*.log.1"
    "/var/log/*.log.*.gz"
    "/var/log/*/*.log.1"
    "/var/log/*/*.log.*.gz"
  )

  local deleted=0
  for pattern in "${log_patterns[@]}"; do
    if compgen -G "$pattern" > /dev/null; then
      delete_glob "$pattern"
      deleted=1
    fi
  done

  if [[ $deleted -eq 1 ]]; then
    msg_success "Old rotated logs cleaned"
  else
    msg_info "No rotated logs to clean"
  fi
}

cleanup_temp_files() {
  if [[ "$RUN_TEMP" != true ]]; then
    return 0
  fi

  section "Temporary Files"

  local temp_dirs=("/tmp" "/var/tmp")
  local preserve_patterns=("ssh-*" "VMware*" "*.sock" "*.pid" "*.lock" "config-*" "*.pcap" "*.cap")

  for temp_dir in "${temp_dirs[@]}"; do
    if [[ -d "$temp_dir" ]]; then
      echo -e "  Cleaning $temp_dir (files older than ${TMP_AGE_DAYS} days)"
      local size_before
      size_before=$(get_dir_size_bytes "$temp_dir")

      local find_args=("$temp_dir" -maxdepth 1 -type f -mtime +"${TMP_AGE_DAYS}")
      for pattern in "${preserve_patterns[@]}"; do
        find_args+=( ! -name "$pattern" )
      done

      if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
        find "${find_args[@]}" -print 2>/dev/null | head -n 20 | while read -r f; do
          msg_info "DRY RUN: would delete $f"
        done
      else
        while IFS= read -r -d '' f; do
          delete_path "$f"
        done < <(find "${find_args[@]}" -print0 2>/dev/null)
        while IFS= read -r -d '' d; do
          delete_path "$d"
        done < <(find "$temp_dir" -maxdepth 2 -type d -empty -print0 2>/dev/null)
      fi

      local size_after
      size_after=$(get_dir_size_bytes "$temp_dir")
      local freed=$((size_before - size_after))
      if [[ $freed -gt 0 ]]; then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        msg_success "$temp_dir cleaned ($(bytes_to_human "$freed") freed)"
      else
        msg_info "$temp_dir already clean"
      fi
    fi
  done
}

cleanup_user_caches() {
  if [[ "$RUN_USER_CACHE" != true ]]; then
    return 0
  fi

  section "User Caches"

  local cache_dir="$HOME/.cache"
  if [[ ! -d "$cache_dir" ]]; then
    msg_info "No user cache directory found"
    return 0
  fi

  local cache_size
  cache_size=$(get_dir_size_bytes "$cache_dir")
  echo -e "  Current user cache size: ${c_cyan}$(bytes_to_human "$cache_size")${c_reset}"

  local min_bytes=$((USER_CACHE_MIN_MB * 1024 * 1024))
  if [[ $cache_size -lt $min_bytes ]]; then
    msg_info "User cache is already small"
    return 0
  fi

  if ! confirm "Clean user application caches?" false; then
    msg_info "User cache cleanup skipped"
    return 0
  fi

  local total_cleaned=0

  local browser_cache_dirs=(
    "$HOME/.cache/mozilla/firefox"
    "$HOME/.cache/google-chrome"
    "$HOME/.cache/chromium"
  )

  for browser_dir in "${browser_cache_dirs[@]}"; do
    if [[ -d "$browser_dir" ]]; then
      local size_before
      size_before=$(get_dir_size_bytes "$browser_dir")
      if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
        msg_info "DRY RUN: would clean browser cache in $browser_dir"
      else
        while IFS= read -r -d '' cache_dir; do
          safe_clean_dir "$cache_dir"
        done < <(find "$browser_dir" -name "cache2" -type d -print0 2>/dev/null)
        while IFS= read -r -d '' cache_dir; do
          safe_clean_dir "$cache_dir"
        done < <(find "$browser_dir" -name "Cache" -type d -print0 2>/dev/null)
        while IFS= read -r -d '' cache_dir; do
          safe_clean_dir "$cache_dir"
        done < <(find "$browser_dir" -name "CachedData" -type d -print0 2>/dev/null)
      fi
      local size_after
      size_after=$(get_dir_size_bytes "$browser_dir")
      total_cleaned=$((total_cleaned + size_before - size_after))
    fi
  done

  if [[ -d "$HOME/.cache/thumbnails" ]]; then
    local size_before
    size_before=$(get_dir_size_bytes "$HOME/.cache/thumbnails")
    if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
      msg_info "DRY RUN: would clean thumbnails"
    else
      safe_clean_dir "$HOME/.cache/thumbnails"
    fi
    local size_after
    size_after=$(get_dir_size_bytes "$HOME/.cache/thumbnails")
    total_cleaned=$((total_cleaned + size_before - size_after))
  fi

  local safe_cache_dirs=(
    "$HOME/.cache/pip"
    "$HOME/.cache/yarn"
    "$HOME/.cache/npm"
    "$HOME/.cache/go-build"
    "$HOME/.cache/composer"
  )

  for cache in "${safe_cache_dirs[@]}"; do
    if [[ -d "$cache" ]]; then
      local size_before
      size_before=$(get_dir_size_bytes "$cache")
      if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
        msg_info "DRY RUN: would clean $cache"
      else
        safe_clean_dir "$cache"
      fi
      local size_after
      size_after=$(get_dir_size_bytes "$cache")
      total_cleaned=$((total_cleaned + size_before - size_after))
    fi
  done

  TOTAL_FREED=$((TOTAL_FREED + total_cleaned))
  if [[ $total_cleaned -gt 0 ]]; then
    msg_success "User caches cleaned ($(bytes_to_human "$total_cleaned") freed)"
  else
    msg_info "No user caches to clean"
  fi
}

cleanup_trash() {
  if [[ "$RUN_TRASH" != true ]]; then
    return 0
  fi

  section "User Trash"
  local trash_dir="$HOME/.local/share/Trash/files"
  if [[ ! -d "$trash_dir" ]]; then
    msg_info "Trash directory not found"
    return 0
  fi

  local trash_size
  trash_size=$(get_dir_size_bytes "$trash_dir")
  echo -e "  Trash size: ${c_cyan}$(bytes_to_human "$trash_size")${c_reset}"

  if ! confirm "Empty user Trash?" true; then
    msg_info "Trash cleanup skipped"
    return 0
  fi

  safe_clean_dir "$trash_dir"
  msg_success "Trash emptied"
}

cleanup_snap_packages() {
  if [[ "$RUN_SNAP" != true ]]; then
    return 0
  fi
  if ! command -v snap >/dev/null 2>&1; then
    return 0
  fi

  section "Snap Packages"
  if ! confirm "Remove old snap revisions (keep latest 2)?" false; then
    msg_info "Snap cleanup skipped"
    return 0
  fi

  if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true ]]; then
    msg_info "DRY RUN: would remove disabled snap revisions"
    return 0
  fi

  snap set system refresh.retain=2 2>/dev/null || true
  snap list --all | awk '/disabled/{print $1, $3}' |
    while read -r snapname revision; do
      snap remove "$snapname" --revision="$revision" 2>/dev/null || true
    done

  msg_success "Snap cleanup completed"
}

cleanup_pentesting_tools() {
  if [[ "$RUN_PENTEST" != true ]]; then
    return 0
  fi
  section "Penetration Testing Tools"

  local total_cleaned=0
  local msf_dirs=("$HOME/.msf4/logs" "/root/.msf4/logs" "/opt/metasploit-framework/logs" "/var/log/metasploit")

  for msf_dir in "${msf_dirs[@]}"; do
    if [[ -d "$msf_dir" ]]; then
      local size_before
      size_before=$(get_dir_size_bytes "$msf_dir")
      if [[ $size_before -gt 1048576 ]]; then
        if confirm "Clean Metasploit logs in $msf_dir?" false; then
          if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
            msg_info "DRY RUN: would delete Metasploit log files"
          else
            while IFS= read -r -d '' f; do
              delete_path "$f"
            done < <(find "$msf_dir" -name "*.log" -type f -print0 2>/dev/null)
            while IFS= read -r -d '' f; do
              delete_path "$f"
            done < <(find "$msf_dir" -name "framework.log*" -type f -print0 2>/dev/null)
            while IFS= read -r -d '' f; do
              delete_path "$f"
            done < <(find "$msf_dir" -name "production.log*" -type f -print0 2>/dev/null)
          fi
          local size_after
          size_after=$(get_dir_size_bytes "$msf_dir")
          total_cleaned=$((total_cleaned + size_before - size_after))
        fi
      fi
    fi
  done

  local pg_dirs=("/var/log/postgresql" "/var/lib/postgresql")
  for pg_dir in "${pg_dirs[@]}"; do
    if [[ -d "$pg_dir" ]]; then
      if confirm "Clean PostgreSQL logs in $pg_dir (older than 7 days)?" false; then
        if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
          msg_info "DRY RUN: would remove old PostgreSQL logs"
        else
          while IFS= read -r -d '' f; do
            delete_path "$f"
          done < <(find "$pg_dir" -name "*.log" -type f -mtime +7 -print0 2>/dev/null)
          while IFS= read -r -d '' f; do
            delete_path "$f"
          done < <(find "$pg_dir" -name "postgresql-*.log" -type f -mtime +7 -print0 2>/dev/null)
        fi
      fi
    fi
  done

  local wireshark_patterns=("/tmp/wireshark_*.tmp" "/tmp/dumpcap_*.tmp" "$HOME/.cache/wireshark/*.tmp" "/root/.cache/wireshark/*.tmp")
  for pattern in "${wireshark_patterns[@]}"; do
    if compgen -G "$pattern" > /dev/null 2>&1; then
      if confirm "Clean Wireshark temporary files ($pattern)?" false; then
        if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
          msg_info "DRY RUN: would remove Wireshark temp files"
        else
          delete_glob "$pattern"
        fi
      fi
    fi
  done

  if [[ $total_cleaned -gt 0 ]]; then
    TOTAL_FREED=$((TOTAL_FREED + total_cleaned))
    msg_success "Pentesting caches cleaned ($(bytes_to_human "$total_cleaned") freed)"
  else
    msg_info "No pentesting caches to clean"
  fi
}

cleanup_docker() {
  if [[ "$RUN_DOCKER" != true ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  section "Docker Cleanup"
  echo -e "  This can remove unused containers, images, and build cache."
  if ! confirm "Run safe Docker cleanup (docker system prune)?" true; then
    msg_info "Docker cleanup skipped"
    return 0
  fi

  run_cmd docker system prune -f || msg_warn "Docker prune failed"

  if confirm "Also remove unused volumes? (more aggressive)" true; then
    run_cmd docker volume prune -f || msg_warn "Docker volume prune failed"
  fi

  msg_success "Docker cleanup completed"
}

cleanup_old_kernels() {
  if [[ "$RUN_KERNELS" != true ]]; then
    return 0
  fi
  section "Kernel Cleanup"

  local current_kernel
  current_kernel=$(uname -r)
  local installed_kernels
  if ! command -v dpkg >/dev/null 2>&1; then
    msg_warn "dpkg not found; skipping kernel cleanup"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    msg_warn "apt-get not found; skipping kernel cleanup"
    return 0
  fi
  installed_kernels=$(dpkg --list | grep linux-image | grep -v "$current_kernel" | wc -l)

  echo -e "  Current kernel: ${c_cyan}$current_kernel${c_reset}"
  echo -e "  Old kernels found: ${c_cyan}$installed_kernels${c_reset}"

  if [[ $installed_kernels -gt 1 ]]; then
    echo -e "  Note: keep at least 1-2 older kernels for recovery"
    if confirm "Remove old kernels (current preserved)?" true; then
      run_cmd apt-get autoremove --purge -y >/dev/null 2>&1 || msg_warn "Kernel cleanup failed"
      msg_success "Old kernels removed"
    else
      msg_info "Kernel cleanup skipped"
    fi
  else
    msg_info "No old kernels to remove"
  fi
}

cleanup_crash_reports() {
  if [[ "$RUN_CRASH_REPORTS" != true ]]; then
    return 0
  fi
  if [[ ! -d /var/crash ]]; then
    return 0
  fi

  section "Crash Reports"
  local crash_size
  crash_size=$(get_dir_size_bytes "/var/crash")
  echo -e "  Crash reports size: ${c_cyan}$(bytes_to_human "$crash_size")${c_reset}"
  echo -e "  Removing files older than ${CRASH_MAX_AGE_DAYS} days"

  if ! confirm "Clean old crash reports?" true; then
    msg_info "Crash report cleanup skipped"
    return 0
  fi

  if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
    msg_info "PREVIEW: would remove old crash reports in /var/crash"
  else
    while IFS= read -r -d '' f; do
      delete_path "$f"
    done < <(find /var/crash -type f -mtime +"${CRASH_MAX_AGE_DAYS}" -print0 2>/dev/null)
    while IFS= read -r -d '' d; do
      delete_path "$d"
    done < <(find /var/crash -type d -empty -print0 2>/dev/null)
  fi

  local after_size
  after_size=$(get_dir_size_bytes "/var/crash")
  local freed=$((crash_size - after_size))
  if [[ $freed -gt 0 ]]; then
    TOTAL_FREED=$((TOTAL_FREED + freed))
    msg_success "Crash reports cleaned ($(bytes_to_human "$freed") freed)"
  else
    msg_info "No crash reports removed"
  fi
}

cleanup_coredumps() {
  if [[ "$RUN_COREDUMPS" != true ]]; then
    return 0
  fi
  if [[ ! -d /var/lib/systemd/coredump ]]; then
    return 0
  fi

  section "Core Dumps"
  local core_size
  core_size=$(get_dir_size_bytes "/var/lib/systemd/coredump")
  echo -e "  Core dump size: ${c_cyan}$(bytes_to_human "$core_size")${c_reset}"
  echo -e "  Removing dumps older than ${COREDUMP_MAX_AGE_DAYS} days"

  if ! confirm "Clean old core dumps?" true; then
    msg_info "Core dump cleanup skipped"
    return 0
  fi

  if command -v coredumpctl >/dev/null 2>&1; then
    run_cmd coredumpctl --vacuum-time="${COREDUMP_MAX_AGE_DAYS}d" >/dev/null 2>&1 || true
  else
    if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
      msg_info "PREVIEW: would remove old core dumps in /var/lib/systemd/coredump"
    else
      while IFS= read -r -d '' f; do
        delete_path "$f"
      done < <(find /var/lib/systemd/coredump -type f -mtime +"${COREDUMP_MAX_AGE_DAYS}" -print0 2>/dev/null)
      while IFS= read -r -d '' d; do
        delete_path "$d"
      done < <(find /var/lib/systemd/coredump -type d -empty -print0 2>/dev/null)
    fi
  fi

  local after_size
  after_size=$(get_dir_size_bytes "/var/lib/systemd/coredump")
  local freed=$((core_size - after_size))
  if [[ $freed -gt 0 ]]; then
    TOTAL_FREED=$((TOTAL_FREED + freed))
    msg_success "Core dumps cleaned ($(bytes_to_human "$freed") freed)"
  else
    msg_info "No core dumps removed"
  fi
}

# --------- analysis ---------
show_disk_analysis() {
  section "Disk Analysis"
  echo -e "  Top 10 largest directories (depth 2):"
  du -h --max-depth=2 /var /home /usr /opt 2>/dev/null | sort -hr | head -10
  echo
}

show_orphaned_packages() {
  section "Orphaned Packages"
  if ! command -v apt-get >/dev/null 2>&1; then
    msg_warn "APT not found; orphan report not available"
    return 0
  fi
  if apt-get -s autoremove 2>/dev/null | grep -q '^Remv'; then
    apt-get -s autoremove | grep '^Remv' | head -20
    echo -e "  Note: run cleanup to remove these packages"
  else
    msg_info "No orphaned packages found"
  fi
}

# --------- report ---------
generate_report() {
  local end_time duration minutes seconds
  end_time=$(date +%s)
  duration=$((end_time - START_TIME))
  minutes=$((duration / 60))
  seconds=$((duration % 60))

  local time_display
  if [[ $minutes -gt 0 ]]; then
    time_display="${minutes}m ${seconds}s"
  else
    time_display="${seconds}s"
  fi

  section "Cleanup Summary"
  if [[ "$DRY_RUN_SUMMARY" == true ]]; then
    echo -e "  Estimated space to free: ${c_green}$(bytes_to_human "$TOTAL_ESTIMATED")${c_reset}"
  else
    echo -e "  Space freed: ${c_green}$(bytes_to_human "$TOTAL_FREED")${c_reset}"
  fi
  if [[ "$BACKUP_MODE" == true ]]; then
    echo -e "  Space moved to backup: ${c_cyan}$(bytes_to_human "$TOTAL_MOVED")${c_reset}"
    echo -e "  Backup dir: ${c_blue}${BACKUP_DIR}${c_reset}"
  fi
  echo -e "  Time taken: ${c_cyan}${time_display}${c_reset}"
  echo -e "  Log file:   ${c_blue}${LOG_FILE}${c_reset}"
  echo

  if [[ "$JSON_REPORT" == true ]]; then
    generate_json_report "$duration"
  fi
}

# --------- reporting (json) ---------
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf "%s" "$s"
}

generate_json_report() {
  local duration="$1"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local output
  output=$(
    printf '{'
    printf '"script_name":"%s",' "$(json_escape "$SCRIPT_NAME")"
    printf '"script_version":"%s",' "$(json_escape "$SCRIPT_VERSION")"
    printf '"timestamp_utc":"%s",' "$timestamp"
    printf '"duration_seconds":%d,' "$duration"
    printf '"dry_run":%s,' "$([[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]] && echo true || echo false)"
    printf '"backup_mode":%s,' "$([[ "$BACKUP_MODE" == true ]] && echo true || echo false)"
    printf '"freed_bytes":%d,' "$TOTAL_FREED"
    printf '"estimated_bytes":%d,' "$TOTAL_ESTIMATED"
    printf '"moved_bytes":%d,' "$TOTAL_MOVED"
    printf '"log_file":"%s",' "$(json_escape "$LOG_FILE")"
    printf '"backup_dir":"%s"' "$(json_escape "$BACKUP_DIR")"
    printf '}'
  )

  if [[ -n "$JSON_REPORT_PATH" ]]; then
    printf "%s\n" "$output" > "$JSON_REPORT_PATH" 2>/dev/null || {
      msg_warn "Failed to write JSON report to $JSON_REPORT_PATH"
      return 1
    }
    msg_success "JSON report written to $JSON_REPORT_PATH"
  else
    echo "$output"
  fi
}

# --------- user cleanup ---------
get_real_users() {
  awk -F: '$3 >= 1000 && $3 != 65534 && $7 !~ /nologin|false/ && $1 != "nobody" {print $1 ":" $3 ":" $6}' /etc/passwd | sort
}

show_user_selection() {
  section "Select User"

  local users
  IFS=$'\n' read -r -d '' -a users < <(get_real_users && printf '\0')
  local current_user
  current_user=$(whoami)

  if [[ ${#users[@]} -eq 0 ]]; then
    msg_error "No regular users found"
    return 1
  fi

  local i=1
  for user_info in "${users[@]}"; do
    IFS=':' read -r username uid homedir <<< "$user_info"
    local status=""
    if [[ "$username" == "$current_user" ]]; then
      status=" (current)"
    fi
    printf '  %d) %s%s\n' "$i" "$username" "$status"
    printf '     Home: %s\n' "$homedir"
    ((i++))
  done
  echo "  0) Cancel"
  echo -ne "${c_yellow}Select user [0-${#users[@]}]: ${c_reset}"

  local choice
  read -r choice

  if [[ "$choice" == "0" ]]; then
    msg_info "User cleanup cancelled"
    return 1
  fi
  if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [[ $choice -le ${#users[@]} ]]; then
    local selected_user_info="${users[$((choice-1))]}"
    IFS=':' read -r selected_username selected_uid selected_homedir <<< "$selected_user_info"
    cleanup_selected_user "$selected_username" "$selected_homedir"
    return 0
  fi

  msg_error "Invalid choice"
  return 1
}

cleanup_selected_user() {
  local username="$1" homedir="$2"

  section "User Cleanup: $username"

  if [[ ! -d "$homedir" ]]; then
    msg_error "Home directory not found: $homedir"
    return 1
  fi
  if [[ ! -r "$homedir" ]]; then
    msg_error "No permission to access: $homedir"
    msg_info "Tip: run with sudo for system-wide user cleanup"
    return 1
  fi

  local total_cleaned=0

  local browser_caches=(
    "$homedir/.cache/mozilla/firefox/*/cache2"
    "$homedir/.cache/google-chrome/Default/Cache"
    "$homedir/.cache/google-chrome/Default/Code Cache"
    "$homedir/.cache/chromium/Default/Cache"
    "$homedir/.cache/chromium/Default/Code Cache"
    "$homedir/.mozilla/firefox/*/cache2"
  )

  for cache_pattern in "${browser_caches[@]}"; do
    for cache_path in $cache_pattern; do
      if [[ -d "$cache_path" ]]; then
        local size_before
        size_before=$(get_dir_size_bytes "$cache_path")
        if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
          msg_info "DRY RUN: would clean $cache_path"
        else
          safe_clean_dir "$cache_path"
        fi
        local size_after
        size_after=$(get_dir_size_bytes "$cache_path")
        total_cleaned=$((total_cleaned + size_before - size_after))
      fi
    done
  done

  if [[ -d "$homedir/.cache/thumbnails" ]]; then
    local size_before
    size_before=$(get_dir_size_bytes "$homedir/.cache/thumbnails")
    if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
      msg_info "DRY RUN: would clean thumbnail cache"
    else
      safe_clean_dir "$homedir/.cache/thumbnails"
    fi
    local size_after
    size_after=$(get_dir_size_bytes "$homedir/.cache/thumbnails")
    total_cleaned=$((total_cleaned + size_before - size_after))
  fi

  local dev_caches=(
    "$homedir/.cache/pip"
    "$homedir/.cache/npm"
    "$homedir/.cache/yarn"
    "$homedir/.cache/go-build"
    "$homedir/.cache/composer"
  )

  for cache_dir in "${dev_caches[@]}"; do
    if [[ -d "$cache_dir" ]]; then
      local size_before
      size_before=$(get_dir_size_bytes "$cache_dir")
      if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
        msg_info "DRY RUN: would clean $cache_dir"
      else
        safe_clean_dir "$cache_dir"
      fi
      local size_after
      size_after=$(get_dir_size_bytes "$cache_dir")
      total_cleaned=$((total_cleaned + size_before - size_after))
    fi
  done

  local temp_patterns=(
    "$homedir/tmp"
    "$homedir/.tmp"
    "$homedir/Downloads/*.tmp"
    "$homedir/Downloads/*.temp"
  )

  for pattern in "${temp_patterns[@]}"; do
    for target in $pattern; do
      if [[ -e "$target" ]]; then
        local size_before
        size_before=$(get_dir_size_bytes "$target" 2>/dev/null || echo 0)
        if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
          msg_info "DRY RUN: would clean $target"
        else
          if [[ -d "$target" ]]; then
            safe_clean_dir "$target"
          else
            delete_path "$target"
          fi
        fi
        local size_after
        size_after=$(get_dir_size_bytes "$target" 2>/dev/null || echo 0)
        total_cleaned=$((total_cleaned + size_before - size_after))
      fi
    done
  done

  if [[ -d "$homedir/.local/share" ]]; then
    if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true || "$DRY_RUN_SUMMARY" == true ]]; then
      msg_info "DRY RUN: would remove old .log files in $homedir/.local/share"
    else
      while IFS= read -r -d '' f; do
        delete_path "$f"
      done < <(find "$homedir/.local/share" -name "*.log" -mtime +30 -print0 2>/dev/null)
    fi
  fi

  TOTAL_FREED=$((TOTAL_FREED + total_cleaned))
  msg_success "User cleanup complete ($(bytes_to_human "$total_cleaned") freed)"
}

user_only_cleanup() {
  show_user_selection || true
  generate_report
}

# --------- modes ---------
quick_cleanup() {
  msg_info "Starting quick cleanup (safe defaults)"
  FORCE_MODE=true

  cleanup_apt_cache
  cleanup_system_logs
  cleanup_temp_files
  cleanup_user_caches

  local distro
  distro=$(detect_distribution)
  if [[ "$distro" == "ubuntu" || "$distro" == "linuxmint" ]]; then
    cleanup_snap_packages
  fi
  if [[ "$distro" == "kali" || "$distro" == "parrot" ]]; then
    cleanup_pentesting_tools
  fi

  generate_report
  FORCE_MODE=false
}

standard_cleanup() {
  msg_info "Starting standard cleanup"

  cleanup_apt_cache
  cleanup_apt_lists
  cleanup_system_logs
  cleanup_crash_reports
  cleanup_coredumps
  cleanup_temp_files
  cleanup_user_caches
  cleanup_trash

  local distro
  distro=$(detect_distribution)
  if [[ "$distro" == "ubuntu" || "$distro" == "linuxmint" ]]; then
    cleanup_snap_packages
  fi
  if [[ "$distro" == "kali" || "$distro" == "parrot" ]]; then
    cleanup_pentesting_tools
  fi

  generate_report
}

advanced_cleanup() {
  msg_info "Starting advanced cleanup"

  cleanup_apt_cache
  cleanup_apt_lists
  cleanup_system_logs
  cleanup_crash_reports
  cleanup_coredumps
  cleanup_temp_files
  cleanup_user_caches
  cleanup_trash
  cleanup_snap_packages
  cleanup_pentesting_tools
  cleanup_docker
  cleanup_old_kernels

  generate_report
}

show_help() {
  show_banner
  section "Usage"
  echo -e "  sudo $0                         Interactive menu (safe prompts)"
  echo -e "  sudo $0 --quick                  Fast cleanup: caches + temp files"
  echo -e "  sudo $0 --standard               Balanced cleanup (recommended)"
  echo -e "  sudo $0 --advanced               Deep cleanup: Docker + kernels + crash/core"
  echo -e "  $0 --user-only                   Clean current user's caches (no root)"
  echo -e "  $0 --safe-delete PATH            Inspect + confirm deletion for one path"
  echo -e "  $0 --safe-rm \"rm -r /path\"       Parse rm command, then inspect + confirm"
  echo -e "  sudo $0 --dry-run                Preview actions only (no changes)"
  echo -e "  sudo $0 --dry-run-summary        Preview + estimated space to free"
  echo -e "  sudo $0 --backup                 Move deletions into a backup folder"
  echo -e "  $0 --json-report [PATH]          Print JSON summary (or write to PATH)"
  echo -e "  sudo $0 --plan                   Show actions + prompts, run nothing"
  echo -e "  sudo $0 --force                  Skip confirmations (use with caution)"
  echo -e "  sudo $0 --yes                    Alias for --force"
  echo -e "  $0 --no-color                    Disable colored output"
  echo

  section "Examples"
  echo -e "  sudo $0 --standard"
  echo -e "  sudo $0 --dry-run --advanced"
  echo -e "  sudo $0 --dry-run-summary --standard"
  echo -e "  sudo $0 --backup --standard"
  echo -e "  $0 --safe-delete /var/tmp"
  echo -e "  $0 --safe-rm \"rm -r /opt/old-app\""
  echo -e "  $0 --exclude /var/log --standard"
  echo -e "  $0 --include \"/home/*/.cache/*\" --standard"
  echo -e "  $0 --json-report /tmp/lnx-sweep.json --standard"
  echo

  section "Tuning options"
  echo -e "  --tmp-age DAYS            Temp files older than DAYS (default: ${TMP_AGE_DAYS_DEFAULT})"
  echo -e "  --log-age DAYS            Journal/logs older than DAYS (default: ${LOG_AGE_DAYS_DEFAULT})"
  echo -e "  --journal-max-size SIZE   Journal size limit (default: ${JOURNAL_MAX_SIZE_DEFAULT})"
  echo -e "  --apt-cache-min MB        Minimum APT cache size to clean (default: ${APT_CACHE_MIN_MB_DEFAULT})"
  echo -e "  --user-cache-min MB       Minimum user cache size to clean (default: ${USER_CACHE_MIN_MB_DEFAULT})"
  echo -e "  --coredump-age DAYS       Core dumps older than DAYS (default: ${COREDUMP_MAX_AGE_DAYS_DEFAULT})"
  echo -e "  --crash-age DAYS          Crash reports older than DAYS (default: ${CRASH_MAX_AGE_DAYS_DEFAULT})"
  echo

  section "Filters"
  echo -e "  --exclude PATH            Skip deleting any path under PATH"
  echo -e "  --include PATTERN         Only delete paths matching PATTERN"
  echo -e "                           Example: --include '/var/log/*'"
  echo

  section "Skip modules"
  echo -e "  --no-apt-cache            Skip APT cache cleanup"
  echo -e "  --no-apt-lists            Skip APT list cleanup"
  echo -e "  --no-logs                 Skip journal and log cleanup"
  echo -e "  --no-temp                 Skip temp file cleanup"
  echo -e "  --no-user-cache           Skip user cache cleanup"
  echo -e "  --no-trash                Skip user trash cleanup"
  echo -e "  --no-snap                 Skip snap cleanup"
  echo -e "  --no-pentest              Skip pentesting caches cleanup"
  echo -e "  --no-docker               Skip Docker cleanup"
  echo -e "  --no-kernels              Skip old kernel cleanup"
  echo -e "  --no-coredumps            Skip core dump cleanup"
  echo -e "  --no-crash                Skip crash report cleanup"
  echo

  section "What this cleans"
  echo "  - APT caches and unused packages"
  echo "  - APT package lists (optional)"
  echo "  - Rotated logs and old journal entries"
  echo "  - Crash reports and core dumps (optional)"
  echo "  - Temporary files older than ${TMP_AGE_DAYS} days"
  echo "  - User caches (browser, thumbnails, developer tools)"
  echo "  - User Trash (optional)"
  echo "  - Snap revisions (Ubuntu/Mint only)"
  echo "  - Pentesting tool logs and temp files (Kali/Parrot only)"
  echo "  - Docker unused data (optional)"
  echo "  - Old kernels (advanced mode)"
  echo

  section "Safety notes"
  echo "  - Critical system paths are protected"
  echo "  - Active files and evidence data are preserved"
  echo "  - Use --dry-run or --plan before changes"
  echo "  - Confirmations are required unless --force is used"
  echo "  - For paths with spaces, use --safe-delete instead of --safe-rm"
}

show_menu() {
  clear
  show_banner
  preflight_checks --quiet
  show_disk_summary

  while true; do
    print_section "Cleanup Options"
    print_menu_item "1" "Quick Sweep     - clean temp + basic caches with safe defaults"
    print_menu_item "2" "Standard Sweep  - clean logs, temp, caches, trash (recommended)"
    print_menu_item "3" "Deep Sweep      - standard + Docker, kernels, crash/core dumps"
    print_menu_item "4" "User Sweep      - pick one user and clean their caches"
    print_menu_item "5" "Disk Scan       - show top 10 largest directories"
    print_menu_item "6" "Orphan Report   - list packages that can be removed (no changes)"
    print_menu_item "7" "Dry Run         - show exactly what would be deleted (no changes)"
    print_menu_item "8" "Dry Run Summary - preview + estimated space to free (no changes)"
    print_menu_item "9" "Safe Delete     - preview a path, then confirm deletion"
    print_menu_item "h" "Help            - usage and safety notes"
    print_menu_item "q" "Quit            - exit without changes"
    print_section_end
    echo -ne "${c_bold}Select an option [1-9, h, q]: ${c_reset}"

    local choice
    read -r choice

    case "$choice" in
      1)
        quick_cleanup
        read -r -p "Press Enter to return to menu..."
        ;;
      2)
        standard_cleanup
        read -r -p "Press Enter to return to menu..."
        ;;
      3)
        advanced_cleanup
        read -r -p "Press Enter to return to menu..."
        ;;
      4)
        user_only_cleanup
        read -r -p "Press Enter to return to menu..."
        ;;
      5)
        show_disk_analysis
        read -r -p "Press Enter to return to menu..."
        ;;
      6)
        show_orphaned_packages
        read -r -p "Press Enter to return to menu..."
        ;;
      7)
        DRY_RUN=true
        standard_cleanup
        DRY_RUN=false
        read -r -p "Press Enter to return to menu..."
        ;;
      8)
        DRY_RUN_SUMMARY=true
        standard_cleanup
        DRY_RUN_SUMMARY=false
        read -r -p "Press Enter to return to menu..."
        ;;
      9)
        safe_delete_interactive
        read -r -p "Press Enter to return to menu..."
        ;;
      h|H)
        show_help
        read -r -p "Press Enter to return to menu..."
        ;;
      q|Q)
        msg_info "Goodbye"
        exit 0
        ;;
      *)
        msg_error "Invalid option"
        sleep 1
        ;;
    esac
  done
}

cleanup_on_exit() {
  msg_warn "Cleanup interrupted. Exiting safely."
  exit 130
}
trap cleanup_on_exit SIGINT SIGTERM

main() {
  ui_init
  local mode=""
  local show_help_flag=false
  local args_count=$#

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quick) mode="quick"; shift ;;
      --standard) mode="standard"; shift ;;
      --advanced) mode="advanced"; shift ;;
      --user-only) mode="user-only"; shift ;;
      --backup)
        BACKUP_MODE=true
        shift
        ;;
      --exclude)
        if [[ -z "${2:-}" ]]; then
          msg_error "Missing path for --exclude"
          exit 1
        fi
        EXCLUDE_PATHS+=("$2")
        shift 2
        ;;
      --include)
        if [[ -z "${2:-}" ]]; then
          msg_error "Missing pattern for --include"
          exit 1
        fi
        INCLUDE_PATTERNS+=("$2")
        shift 2
        ;;
      --json-report)
        JSON_REPORT=true
        if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
          JSON_REPORT_PATH="$2"
          shift 2
        else
          shift
        fi
        ;;
      --dry-run-summary)
        DRY_RUN_SUMMARY=true
        DRY_RUN=true
        shift
        ;;
      --safe-delete)
        if [[ -z "${2:-}" ]]; then
          msg_error "Missing path for --safe-delete"
          exit 1
        fi
        CUSTOM_DELETE_MODE=true
        CUSTOM_DELETE_PATHS+=("$2")
        if [[ -n "$mode" && "$mode" != "safe-delete" ]]; then
          msg_error "--safe-delete cannot be combined with other modes"
          exit 1
        fi
        mode="safe-delete"
        shift 2
        ;;
      --safe-rm)
        if [[ -z "${2:-}" ]]; then
          msg_error "Missing command for --safe-rm"
          exit 1
        fi
        CUSTOM_DELETE_MODE=true
        CUSTOM_DELETE_CMD="$2"
        if [[ -n "$mode" && "$mode" != "safe-delete" ]]; then
          msg_error "--safe-rm cannot be combined with other modes"
          exit 1
        fi
        mode="safe-delete"
        shift 2
        ;;
      --dry-run) DRY_RUN=true; shift ;;
      --plan) PLAN_ONLY=true; shift ;;
      --force|--yes|-y) FORCE_MODE=true; shift ;;
      --no-color)
        USE_COLOR=false
        c_reset=""; c_red=""; c_green=""; c_yellow=""; c_blue=""; c_cyan=""; c_white=""; c_bold=""; c_dim=""; c_teal=""
        shift
        ;;
      --tmp-age)
        if ! is_positive_int "${2:-}"; then
          msg_error "Invalid --tmp-age value (expected positive integer)"
          exit 1
        fi
        TMP_AGE_DAYS="$2"
        shift 2
        ;;
      --log-age)
        if ! is_positive_int "${2:-}"; then
          msg_error "Invalid --log-age value (expected positive integer)"
          exit 1
        fi
        LOG_AGE_DAYS="$2"
        shift 2
        ;;
      --journal-max-size)
        if ! is_size_string "${2:-}"; then
          msg_error "Invalid --journal-max-size value (e.g., 200M, 1G)"
          exit 1
        fi
        JOURNAL_MAX_SIZE="$2"
        shift 2
        ;;
      --apt-cache-min)
        if ! is_positive_int "${2:-}"; then
          msg_error "Invalid --apt-cache-min value (expected MB integer)"
          exit 1
        fi
        APT_CACHE_MIN_MB="$2"
        shift 2
        ;;
      --user-cache-min)
        if ! is_positive_int "${2:-}"; then
          msg_error "Invalid --user-cache-min value (expected MB integer)"
          exit 1
        fi
        USER_CACHE_MIN_MB="$2"
        shift 2
        ;;
      --coredump-age)
        if ! is_positive_int "${2:-}"; then
          msg_error "Invalid --coredump-age value (expected days integer)"
          exit 1
        fi
        COREDUMP_MAX_AGE_DAYS="$2"
        shift 2
        ;;
      --crash-age)
        if ! is_positive_int "${2:-}"; then
          msg_error "Invalid --crash-age value (expected days integer)"
          exit 1
        fi
        CRASH_MAX_AGE_DAYS="$2"
        shift 2
        ;;
      --no-apt-cache) RUN_APT_CACHE=false; shift ;;
      --no-apt-lists) RUN_APT_LISTS=false; shift ;;
      --no-logs) RUN_LOGS=false; shift ;;
      --no-temp) RUN_TEMP=false; shift ;;
      --no-user-cache) RUN_USER_CACHE=false; shift ;;
      --no-trash) RUN_TRASH=false; shift ;;
      --no-snap) RUN_SNAP=false; shift ;;
      --no-pentest) RUN_PENTEST=false; shift ;;
      --no-docker) RUN_DOCKER=false; shift ;;
      --no-kernels) RUN_KERNELS=false; shift ;;
      --no-coredumps) RUN_COREDUMPS=false; shift ;;
      --no-crash) RUN_CRASH_REPORTS=false; shift ;;
      --help|-h) show_help_flag=true; shift ;;
      *)
        msg_error "Unknown option: $1"
        echo -e "Use '$0 --help' for usage information"
        exit 1
        ;;
    esac
  done

  if [[ "$show_help_flag" == true ]]; then
    show_help
    exit 0
  fi

  if [[ -z "$mode" ]]; then
    if [[ "$DRY_RUN" == true || "$PLAN_ONLY" == true ]]; then
      mode="standard"
    elif [[ $args_count -eq 0 ]]; then
      mode="menu"
    else
      mode="menu"
    fi
  fi

  case "$mode" in
    menu)
      require_root
      setup_log_files "false"
      show_menu
      ;;
    safe-delete)
      setup_log_files "true"
      if [[ "$BACKUP_MODE" == true ]]; then
        ensure_backup_dir || true
      fi
      show_banner
      preflight_checks
      show_disk_summary
      if [[ -n "$CUSTOM_DELETE_CMD" ]]; then
        local parsed_path
        parsed_path=$(parse_safe_rm_command "$CUSTOM_DELETE_CMD") || exit 1
        run_custom_delete "$parsed_path"
      elif [[ ${#CUSTOM_DELETE_PATHS[@]} -gt 0 ]]; then
        local p
        for p in "${CUSTOM_DELETE_PATHS[@]}"; do
          run_custom_delete "$p" || true
        done
      else
        safe_delete_interactive
      fi
      ;;
    quick)
      require_root
      setup_log_files "false"
      if [[ "$BACKUP_MODE" == true ]]; then
        ensure_backup_dir || true
      fi
      show_banner
      preflight_checks
      show_disk_summary
      quick_cleanup
      ;;
    standard)
      require_root
      setup_log_files "false"
      if [[ "$BACKUP_MODE" == true ]]; then
        ensure_backup_dir || true
      fi
      show_banner
      preflight_checks
      show_disk_summary
      standard_cleanup
      ;;
    advanced)
      require_root
      setup_log_files "false"
      if [[ "$BACKUP_MODE" == true ]]; then
        ensure_backup_dir || true
      fi
      show_banner
      preflight_checks
      show_disk_summary
      advanced_cleanup
      ;;
    user-only)
      setup_log_files "true"
      if [[ "$BACKUP_MODE" == true ]]; then
        ensure_backup_dir || true
      fi
      show_banner
      preflight_checks --user-only
      show_disk_summary
      user_only_cleanup
      ;;
    *)
      msg_error "Unknown mode: $mode"
      exit 1
      ;;
  esac
}

main "$@"
