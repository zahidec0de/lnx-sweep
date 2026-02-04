#!/usr/bin/env bash
set -euo pipefail

print_banner() {
  local subtitle="Safe Linux Cleanup Utility"
  local inner_width=$((UI_WIDTH - 2))
  local top_rule="┏$(repeat_char "━" "$inner_width")┓"
  local bottom_rule="┗$(repeat_char "━" "$inner_width")┛"

  print_box_line() {
    local text="$1" color="$2"
    local padded
    padded=$(center_text "$text" "$inner_width")
    padded="${padded/$text/${color}${text}${c_reset}}"
    printf "%b\n" "${c_cyan}┃${c_reset}${padded}${c_cyan}┃${c_reset}"
  }

  echo -e "${c_cyan}${c_bold}${top_rule}${c_reset}"
  print_box_line " " "$c_reset"
  print_box_line "             ██╗     ███╗   ██╗██╗  ██╗     ███████╗██╗    ██╗███████╗███████╗██████╗             " "$c_teal${c_bold}"
  print_box_line "             ██║     ████╗  ██║╚██╗██╔╝     ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗            " "$c_teal${c_bold}"
  print_box_line "             ██║     ██╔██╗ ██║ ╚███╔╝█████╗███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝            " "$c_teal${c_bold}"
  print_box_line "             ██║     ██║╚██╗██║ ██╔██╗╚════╝╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝             " "$c_teal${c_bold}"
  print_box_line "             ███████╗██║ ╚████║██╔╝ ██╗     ███████║╚███╔███╔╝███████╗███████╗██║                 " "$c_teal${c_bold}"
  print_box_line "             ╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝     ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝                 " "$c_teal${c_bold}"
  print_box_line " " "$c_reset"
  print_box_line "$subtitle" "$c_white"
  print_box_line " " "$c_reset"
  print_box_line "Version ${SCRIPT_VERSION}  •••  Dev-#: zahidec0de" "$c_dim"
  echo -e "${c_cyan}${c_bold}${bottom_rule}${c_reset}"
  echo
}

show_banner() {
  print_banner
}
