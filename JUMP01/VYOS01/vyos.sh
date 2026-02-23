#!/bin/vbash
# vyos-dynamic-menu.sh
# Dynamic CRUD menu for Firewall (ipv4 rulesets) + NAT + Interfaces
# Scans live config each time (cached per screen). No hardcoded rules.
#
# SAFETY GOALS:
# - "ADD" must NOT overwrite existing items.
#   * Add DNAT: blocks rule number if it already exists.
#   * Add Firewall rule: blocks rule number if it already exists in that ruleset.
# - User is ALWAYS shown what exists + the next suggested free rule number.
# - Updates/changes to existing rules must be done via Update/Delete menus (not Add).
#
# USER FRIENDLY:
# - Every submenu repeats detected items.
# - Every prompt explains WHAT you are selecting.
# - If a list is empty, you get a clear error (no blind "Select:").
# - Uses grep -F (no regex from user input).
# - Preview before delete/update.
#
# IMPORTANT:
# - Requires read access to: show configuration commands

source /opt/vyatta/etc/functions/script-template

# -----------------------------
# Globals (config cache)
# -----------------------------
CFG_CACHE=""

# -----------------------------
# Helpers
# -----------------------------
pause() { echo; read -r -p "Press Enter to continue..." _; }

strip_quotes() {
  local s="$1"
  s="${s#\'}"
  s="${s%\'}"
  echo "$s"
}

join_lines() { tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

# ---- DO NOT use stderr output for parsing ----
get_cfg_cmds_stdout_only() {
  # Keep ONLY real "set ..." lines so parsing is safe
  run show configuration commands 2>/dev/null | grep -E '^set ' || true
}

# ---- Raw output only for permission check (includes stderr) ----
get_cfg_cmds_raw_for_access_check() {
  run show configuration commands 2>&1 || true
}

refresh_cfg_cache() {
  CFG_CACHE="$(get_cfg_cmds_stdout_only)"
}

die_no_access_if_needed() {
  local out
  out="$(get_cfg_cmds_raw_for_access_check)"

  if echo "$out" | grep -qiE "not assigned to any operator group|permission denied|authorization|not authorized|internal error"; then
    echo
    echo "ERROR: This user does not have permission to read the live config."
    echo "The script needs: 'show configuration commands'."
    echo
    echo "Fix:"
    echo "  - Run as a VyOS admin user, OR"
    echo "  - Fix this user's operator/admin permissions."
    echo
    echo "What VyOS returned:"
    echo "----------------------------------------"
    echo "$out"
    echo "----------------------------------------"
    echo
    exit 1
  fi

  # If stdout-only output is empty, config could genuinely be empty.
  # That is OK; we handle empty lists with clear messages.
  return 0
}

# If a required list is empty, do NOT continue to a blind "Select:" prompt.
require_nonempty_list_or_return() {
  # usage: require_nonempty_list_or_return "What list is this?" "${arr[@]}" || return 1
  local label="$1"; shift
  local arr=("$@")
  if [ "${#arr[@]}" -eq 0 ]; then
    echo
    echo "ERROR: Nothing available for: $label"
    echo "Possible reasons:"
    echo "  - The config has none, OR"
    echo "  - Permission problem (cannot read config)."
    echo
    pause
    return 1
  fi
  return 0
}

show_detected_summary() {
  local ifs rulesets nd ns
  ifs="$(scan_eth_ifaces | join_lines)"
  rulesets="$(scan_firewall_rulesets | join_lines)"
  nd="$(scan_nat_dest_rules | join_lines)"
  ns="$(scan_nat_source_rules | join_lines)"

  echo "Detected right now:"
  echo "  Interfaces: ${ifs:-NONE}"
  echo "  FW rulesets: ${rulesets:-NONE}"
  echo "  NAT dest rules: ${nd:-NONE}"
  echo "  NAT source rules: ${ns:-NONE}"
  echo
}

# Print a numbered menu and return selected item in SELECTED
# IMPORTANT: This function ALWAYS prints options BEFORE prompting.
select_from_list() {
  local title="$1"; shift
  local arr=("$@")
  local i choice

  echo
  echo "=== $title ==="

  if [ "${#arr[@]}" -eq 0 ]; then
    echo "(none found)"
    return 1
  fi

  for i in "${!arr[@]}"; do
    printf "%2d) %s\n" "$((i+1))" "${arr[$i]}"
  done
  echo " 0) Cancel"
  echo

  read -r -p "Select option #: " choice
  if [ -z "$choice" ] || ! echo "$choice" | grep -Eq '^[0-9]+$'; then
    echo "Invalid."
    return 1
  fi
  if [ "$choice" -eq 0 ]; then
    return 1
  fi
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#arr[@]}" ]; then
    echo "Invalid."
    return 1
  fi

  SELECTED="${arr[$((choice-1))]}"
  return 0
}

ask() {
  local prompt="$1"
  local def="${2:-}"
  local val=""
  if [ -n "$def" ]; then
    read -r -p "$prompt [$def]: " val
    echo "${val:-$def}"
  else
    read -r -p "$prompt: " val
    echo "$val"
  fi
}

confirm_commit_save() {
  local yn
  read -r -p "Commit + Save now? (y/n) [y]: " yn
  yn="${yn:-y}"
  case "$yn" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
}

cfg_apply() {
  # Return to the menu after commit/save
  if confirm_commit_save; then
    commit
    save
    echo "DONE: committed + saved."
  else
    echo "Not committed. (No changes saved.)"
  fi
  pause
  return 0
}

# ---- SAFETY HELPERS ----
is_number_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

next_free_rule_number() {
  # next free integer >= 10 using increments of 10 (10,20,30...)
  local used=("$@")
  local n=10
  while is_number_in_list "$n" "${used[@]}"; do
    n=$((n+10))
  done
  echo "$n"
}

require_numeric() {
  local v="$1"
  echo "$v" | grep -Eq '^[0-9]+$'
}

# -----------------------------
# Scan functions (use cache!)
# -----------------------------
scan_firewall_rulesets() {
  printf "%s\n" "$CFG_CACHE" \
    | grep -F "set firewall ipv4 name " \
    | awk '{print $5}' \
    | sort -u \
    | while read -r n; do strip_quotes "$n"; done
}

scan_firewall_rule_numbers_quoted() {
  local rs="$1"
  printf "%s\n" "$CFG_CACHE" \
    | grep -F "set firewall ipv4 name '$rs' rule " \
    | awk '{print $7}' \
    | sort -u
}

scan_firewall_rule_numbers_unquoted() {
  local rs="$1"
  printf "%s\n" "$CFG_CACHE" \
    | grep -F "set firewall ipv4 name $rs rule " \
    | awk '{print $7}' \
    | sort -u
}

scan_firewall_rule_numbers() {
  local rs="$1"
  local a=() b=() merged=()
  mapfile -t a < <(scan_firewall_rule_numbers_quoted "$rs")
  mapfile -t b < <(scan_firewall_rule_numbers_unquoted "$rs")
  merged=("${a[@]}" "${b[@]}")
  if [ "${#merged[@]}" -gt 0 ]; then
    mapfile -t merged < <(printf "%s\n" "${merged[@]}" | sed '/^$/d' | sort -u)
  fi
  printf "%s\n" "${merged[@]}"
}

scan_nat_dest_rules() {
  printf "%s\n" "$CFG_CACHE" \
    | grep -F "set nat destination rule " \
    | awk '{print $5}' \
    | sort -u
}

scan_nat_source_rules() {
  printf "%s\n" "$CFG_CACHE" \
    | grep -F "set nat source rule " \
    | awk '{print $5}' \
    | sort -u
}

scan_eth_ifaces() {
  printf "%s\n" "$CFG_CACHE" \
    | grep -F "set interfaces ethernet " \
    | awk '{print $4}' \
    | sort -u
}

# -----------------------------
# Firewall CRUD
# -----------------------------
fw_choose_ruleset_existing_only() {
  local arr=()
  mapfile -t arr < <(scan_firewall_rulesets)

  echo
  echo "You are selecting a FIREWALL RULESET (existing)."
  echo "Examples: DMZ-to-LAN, WAN-to-DMZ, LAN-to-WAN"
  echo

  require_nonempty_list_or_return "Firewall rulesets" "${arr[@]}" || return 1

  if select_from_list "Select WHICH ruleset to use" "${arr[@]}"; then
    echo "$SELECTED"
    return 0
  fi
  return 1
}

fw_choose_ruleset_or_new() {
  local arr=()
  mapfile -t arr < <(scan_firewall_rulesets)

  echo
  echo "You are selecting a FIREWALL RULESET."
  echo "Examples: DMZ-to-LAN, WAN-to-DMZ, LAN-to-WAN"
  echo

  if [ "${#arr[@]}" -gt 0 ]; then
    if select_from_list "Select a ruleset to use" "${arr[@]}"; then
      echo "$SELECTED"
      return 0
    fi
  else
    echo "No rulesets detected."
  fi

  echo
  echo "No selection made. Type a ruleset name to create/use."
  local rs
  rs="$(ask "Ruleset name (example: DMZ-to-LAN)" "")"
  [ -z "$rs" ] && return 1
  echo "$rs"
}

fw_choose_rule_number_existing() {
  local rs="$1"
  local arr=()
  mapfile -t arr < <(scan_firewall_rule_numbers "$rs")

  echo
  echo "You are selecting an EXISTING RULE NUMBER in: $rs"
  echo

  require_nonempty_list_or_return "Firewall rules inside ruleset '$rs'" "${arr[@]}" || return 1

  if select_from_list "Select existing rule number" "${arr[@]}"; then
    echo "$SELECTED"
    return 0
  fi
  return 1
}

fw_choose_rule_number_new_only() {
  local rs="$1"
  local used=() suggested n
  mapfile -t used < <(scan_firewall_rule_numbers "$rs")

  echo
  echo "ADD MODE (SAFE): You are selecting a NEW RULE NUMBER in: $rs"
  echo "Add will NOT overwrite existing numbers."
  echo

  suggested="$(next_free_rule_number "${used[@]}")"
  echo "Existing rule numbers: ${used[*]:-(none)}"
  echo "Suggested next free rule number: $suggested"
  echo

  while true; do
    n="$(ask "Rule number (new only)" "$suggested")"
    [ -z "$n" ] && echo "Rule number required." && continue
    if ! require_numeric "$n"; then
      echo "ERROR: must be a number (example: 10)."
      continue
    fi
    if is_number_in_list "$n" "${used[@]}"; then
      echo "ERROR: rule $n already exists in $rs."
      echo "Use Update/Delete to change existing rules."
      continue
    fi
    break
  done
  echo "$n"
}

fw_preview_rule() {
  local rs="$1" n="$2"
  echo
  echo "Current config lines for: firewall ipv4 name '$rs' rule $n"
  echo "--------------------------------------------------------"
  printf "%s\n" "$CFG_CACHE" | grep -F "set firewall ipv4 name '$rs' rule $n " || true
  printf "%s\n" "$CFG_CACHE" | grep -F "set firewall ipv4 name $rs rule $n " || true
  echo "--------------------------------------------------------"
  echo
}

fw_list_ruleset() {
  local rs
  echo
  echo "You selected: List ruleset"
  echo "Next: choose WHICH ruleset to view."
  echo

  rs="$(fw_choose_ruleset_existing_only)" || return 0

  echo
  echo "Showing commands for ruleset: $rs"
  echo "--------------------------------------------------------"
  printf "%s\n" "$CFG_CACHE" | grep -F "set firewall ipv4 name '$rs' " || true
  printf "%s\n" "$CFG_CACHE" | grep -F "set firewall ipv4 name $rs " || true
  echo "--------------------------------------------------------"
  pause
}

fw_add_rule_guided_safe() {
  local rs n action proto desc saddr daddr sport dport state_est state_rel state_new

  echo
  echo "You selected: ADD rule (SAFE - new only)"
  echo "Next steps:"
  echo "  1) Select a ruleset"
  echo "  2) Select a NEW rule number (script suggests next free)"
  echo "  3) Enter fields"
  echo

  rs="$(fw_choose_ruleset_or_new)" || return 0
  n="$(fw_choose_rule_number_new_only "$rs")" || return 0

  echo
  echo "Now creating NEW rule: firewall ipv4 name '$rs' rule $n"
  echo "Leave optional fields blank to skip."
  echo

  action="$(ask "Action (accept/drop/reject)" "accept")"
  proto="$(ask "Protocol (tcp/udp/icmp/any)" "tcp")"
  desc="$(ask "Description (optional)" "")"
  saddr="$(ask "Source address (optional) (example: 172.16.50.0/29)" "")"
  daddr="$(ask "Destination address (optional) (example: 172.16.200.10)" "")"
  sport="$(ask "Source port (optional) (example: 443)" "")"
  dport="$(ask "Destination port (optional) (example: 22 or 1514-1515)" "")"
  state_est="$(ask "Match ESTABLISHED state? (y/n)" "n")"
  state_rel="$(ask "Match RELATED state? (y/n)" "n")"
  state_new="$(ask "Match NEW state? (y/n)" "n")"

  echo
  echo "SUMMARY:"
  echo "  ruleset: $rs"
  echo "  rule: $n"
  echo "  action: $action"
  [ -n "$proto" ] && echo "  protocol: $proto"
  [ -n "$saddr" ] && echo "  source address: $saddr"
  [ -n "$sport" ] && echo "  source port: $sport"
  [ -n "$daddr" ] && echo "  destination address: $daddr"
  [ -n "$dport" ] && echo "  destination port: $dport"
  [ -n "$desc" ] && echo "  description: $desc"
  echo
  pause

  configure
  set firewall ipv4 name "$rs" rule "$n" action "$action"
  [ -n "$desc" ] && set firewall ipv4 name "$rs" rule "$n" description "$desc"

  if [ -n "$proto" ] && [ "$proto" != "any" ]; then
    set firewall ipv4 name "$rs" rule "$n" protocol "$proto"
  fi

  [ -n "$saddr" ] && set firewall ipv4 name "$rs" rule "$n" source address "$saddr"
  [ -n "$daddr" ] && set firewall ipv4 name "$rs" rule "$n" destination address "$daddr"
  [ -n "$sport" ] && set firewall ipv4 name "$rs" rule "$n" source port "$sport"
  [ -n "$dport" ] && set firewall ipv4 name "$rs" rule "$n" destination port "$dport"

  [ "$state_est" = "y" ] || [ "$state_est" = "Y" ] && set firewall ipv4 name "$rs" rule "$n" state established
  [ "$state_rel" = "y" ] || [ "$state_rel" = "Y" ] && set firewall ipv4 name "$rs" rule "$n" state related
  [ "$state_new" = "y" ] || [ "$state_new" = "Y" ] && set firewall ipv4 name "$rs" rule "$n" state new

  cfg_apply
}

fw_update_single_field() {
  local rs n tail val

  echo
  echo "You selected: Update ONE field (existing rule)"
  echo "Next steps:"
  echo "  1) Select a ruleset"
  echo "  2) Select an EXISTING rule number"
  echo "  3) Enter the field path + new value"
  echo

  rs="$(fw_choose_ruleset_existing_only)" || return 0
  n="$(fw_choose_rule_number_existing "$rs")" || return 0

  fw_preview_rule "$rs" "$n"

  echo "Common field paths:"
  echo "  action"
  echo "  description"
  echo "  protocol"
  echo "  destination address"
  echo "  destination port"
  echo "  source address"
  echo "  source port"
  echo "  state established"
  echo

  tail="$(ask "Field path (words after: rule <N>)" "")"
  [ -z "$tail" ] && return 0
  val="$(ask "New value" "")"
  [ -z "$val" ] && return 0

  configure
  # shellcheck disable=SC2086
  set firewall ipv4 name "$rs" rule "$n" $tail "$val"
  cfg_apply
}

fw_delete_rule() {
  local rs n

  echo
  echo "You selected: Delete existing rule"
  echo "Next steps:"
  echo "  1) Select a ruleset"
  echo "  2) Select an EXISTING rule number to delete"
  echo

  rs="$(fw_choose_ruleset_existing_only)" || return 0
  n="$(fw_choose_rule_number_existing "$rs")" || return 0

  fw_preview_rule "$rs" "$n"

  configure
  delete firewall ipv4 name "$rs" rule "$n"
  cfg_apply
}

firewall_menu() {
  while true; do
    refresh_cfg_cache
    echo
    echo "========================"
    echo " Firewall Menu (Dynamic)"
    echo "========================"
    show_detected_summary
    echo "SAFE RULES:"
    echo "  - ADD will NOT overwrite existing rule numbers."
    echo "  - Update/Delete only work on EXISTING rules."
    echo
    echo "1) List ruleset (show commands)"
    echo "2) ADD rule (SAFE - new only)"
    echo "3) Update ONE field in an existing rule"
    echo "4) Delete existing rule"
    echo "5) Back"
    read -r -p "Select menu option #: " c
    case "$c" in
      1) fw_list_ruleset ;;
      2) fw_add_rule_guided_safe ;;
      3) fw_update_single_field ;;
      4) fw_delete_rule ;;
      5) return 0 ;;
      *) echo "Invalid." ;;
    esac
  done
}

# -----------------------------
# NAT CRUD
# -----------------------------
nat_choose_type() {
  echo
  echo "You are selecting a NAT TYPE:"
  echo "  destination = DNAT / port forwarding"
  echo "  source      = SNAT / masquerade"
  echo
  local t
  t="$(ask "NAT type (destination/source)" "destination")"
  case "$t" in
    destination|source) echo "$t" ;;
    *) echo "" ;;
  esac
}

nat_choose_rule_number_existing() {
  local type="$1"
  local arr=()

  if [ "$type" = "destination" ]; then
    mapfile -t arr < <(scan_nat_dest_rules)
  else
    mapfile -t arr < <(scan_nat_source_rules)
  fi

  echo
  echo "You are selecting an EXISTING NAT RULE NUMBER (type: $type)"
  echo

  require_nonempty_list_or_return "NAT $type rules" "${arr[@]}" || return 1

  if select_from_list "Select existing NAT rule number" "${arr[@]}"; then
    echo "$SELECTED"
    return 0
  fi
  return 1
}

nat_preview_rule() {
  local type="$1" n="$2"
  echo
  echo "Current config lines for: nat $type rule $n"
  echo "--------------------------------------------------------"
  printf "%s\n" "$CFG_CACHE" | grep -F "set nat $type rule $n " || true
  echo "--------------------------------------------------------"
  echo
}

nat_list() {
  refresh_cfg_cache
  echo
  echo "You selected: List NAT"
  echo "Showing NAT commands (current config):"
  echo
  printf "%s\n" "$CFG_CACHE" | grep -F "set nat " || true
  pause
}

nat_add_dnat_guided() {
  local n desc inif proto dport taddr tport
  local used=() suggested
  local ifs=()

  refresh_cfg_cache

  echo
  echo "You selected: Add DNAT rule (SAFE - new only)"
  echo "Next steps:"
  echo "  1) Choose a NEW rule number (script suggests next free)"
  echo "  2) Pick inbound interface"
  echo "  3) Enter ports + translation"
  echo

  mapfile -t used < <(scan_nat_dest_rules)

  suggested="$(next_free_rule_number "${used[@]}")"
  echo "Existing DNAT rule numbers: ${used[*]:-(none)}"
  echo "Suggested next free rule number: $suggested"
  echo

  while true; do
    n="$(ask "DNAT rule number (new only)" "$suggested")"
    [ -z "$n" ] && echo "Rule number required." && continue
    if ! require_numeric "$n"; then
      echo "ERROR: must be a number (example: 10)."
      continue
    fi
    if is_number_in_list "$n" "${used[@]}"; then
      echo "ERROR: rule $n already exists. Add mode will NOT overwrite."
      echo "Use Update/Delete to change existing rules."
      continue
    fi
    break
  done

  desc="$(ask "Description (example: HTTP -> DMZ)" "DNAT")"

  mapfile -t ifs < <(scan_eth_ifaces)
  require_nonempty_list_or_return "Ethernet interfaces (for inbound interface selection)" "${ifs[@]}" || return 0

  if select_from_list "Select inbound interface (usually WAN like eth0)" "${ifs[@]}"; then
    inif="$SELECTED"
  else
    return 0
  fi

  proto="$(ask "Protocol (tcp/udp)" "tcp")"
  dport="$(ask "Public port (example: 80)" "80")"
  taddr="$(ask "Inside IP (example: 172.16.50.3)" "172.16.50.3")"
  tport="$(ask "Inside port (example: 80)" "80")"

  echo
  echo "SUMMARY (DNAT rule $n):"
  echo "  description: $desc"
  echo "  inbound-interface: $inif"
  echo "  protocol: $proto"
  echo "  public port: $dport"
  echo "  translation: $taddr:$tport"
  echo
  pause

  configure
  set nat destination rule "$n" description "$desc"
  set nat destination rule "$n" inbound-interface name "$inif"
  set nat destination rule "$n" protocol "$proto"
  set nat destination rule "$n" destination port "$dport"
  set nat destination rule "$n" translation address "$taddr"
  set nat destination rule "$n" translation port "$tport"
  cfg_apply
}

nat_update_single_field() {
  local type n tail val

  refresh_cfg_cache

  echo
  echo "You selected: Update ONE field in an existing NAT rule"
  echo "Next steps:"
  echo "  1) Choose NAT type"
  echo "  2) Choose EXISTING rule number"
  echo "  3) Enter field path + new value"
  echo

  type="$(nat_choose_type)"
  [ -z "$type" ] && return 0
  n="$(nat_choose_rule_number_existing "$type")" || return 0

  nat_preview_rule "$type" "$n"

  echo "Common field paths:"
  echo "  description"
  echo "  destination port"
  echo "  inbound-interface name"
  echo "  outbound-interface name"
  echo "  source address"
  echo "  protocol"
  echo "  translation address"
  echo "  translation port"
  echo

  tail="$(ask "Field path (words after: rule <N>)" "")"
  [ -z "$tail" ] && return 0
  val="$(ask "New value" "")"
  [ -z "$val" ] && return 0

  configure
  # shellcheck disable=SC2086
  set nat "$type" rule "$n" $tail "$val"
  cfg_apply
}

nat_delete_rule() {
  local type n

  refresh_cfg_cache

  echo
  echo "You selected: Delete existing NAT rule"
  echo "Next steps:"
  echo "  1) Choose NAT type"
  echo "  2) Choose EXISTING rule number to delete"
  echo

  type="$(nat_choose_type)"
  [ -z "$type" ] && return 0
  n="$(nat_choose_rule_number_existing "$type")" || return 0

  nat_preview_rule "$type" "$n"
  configure
  delete nat "$type" rule "$n"
  cfg_apply
}

nat_menu() {
  while true; do
    refresh_cfg_cache
    echo
    echo "=================="
    echo " NAT Menu (Dynamic)"
    echo "=================="
    show_detected_summary
    echo "SAFE RULES:"
    echo "  - ADD DNAT will NOT overwrite existing rule numbers."
    echo "  - Update/Delete only work on EXISTING rules."
    echo
    echo "1) List NAT (show commands)"
    echo "2) Add DNAT rule (SAFE - new only)"
    echo "3) Update ONE field in an existing NAT rule"
    echo "4) Delete existing NAT rule"
    echo "5) Back"
    read -r -p "Select menu option #: " c
    case "$c" in
      1) nat_list ;;
      2) nat_add_dnat_guided ;;
      3) nat_update_single_field ;;
      4) nat_delete_rule ;;
      5) return 0 ;;
      *) echo "Invalid." ;;
    esac
  done
}

# -----------------------------
# Interfaces
# -----------------------------
iface_set_ip() {
  local ifs=() iface ip desc

  refresh_cfg_cache

  mapfile -t ifs < <(scan_eth_ifaces)

  echo
  echo "You selected: Set interface IP + description"
  echo "Next steps:"
  echo "  1) Choose an interface"
  echo "  2) Enter a CIDR address"
  echo "  3) Optional description"
  echo

  require_nonempty_list_or_return "Ethernet interfaces" "${ifs[@]}" || return 0

  if select_from_list "Select interface to configure" "${ifs[@]}"; then
    iface="$SELECTED"
  else
    return 0
  fi

  ip="$(ask "New address (CIDR) (example: 172.16.50.2/29)" "")"
  [ -z "$ip" ] && return 0
  desc="$(ask "Description (optional) (example: Hamed-DMZ)" "")"

  echo
  echo "SUMMARY:"
  echo "  interface: $iface"
  echo "  address: $ip"
  [ -n "$desc" ] && echo "  description: $desc"
  echo
  pause

  configure
  set interfaces ethernet "$iface" address "$ip"
  [ -n "$desc" ] && set interfaces ethernet "$iface" description "$desc"
  cfg_apply
}

iface_show() {
  echo
  echo "You selected: Show interfaces"
  echo
  run show interfaces
  echo
  pause
}

iface_menu() {
  while true; do
    refresh_cfg_cache
    echo
    echo "========================"
    echo " Interfaces Menu (Dynamic)"
    echo "========================"
    show_detected_summary
    echo "1) Set interface IP + description"
    echo "2) Show interfaces"
    echo "3) Back"
    read -r -p "Select menu option #: " c
    case "$c" in
      1) iface_set_ip ;;
      2) iface_show ;;
      3) return 0 ;;
      *) echo "Invalid." ;;
    esac
  done
}

# -----------------------------
# Raw mode (edit ANY aspect)
# -----------------------------
raw_mode() {
  echo
  echo "RAW MODE WARNING:"
  echo "  Raw mode CAN overwrite or delete anything."
  echo "  Only use if you know exactly what you are doing."
  echo
  echo "Type ONE config command starting with: set ...  OR  delete ..."
  echo "Examples:"
  echo "  delete interfaces ethernet eth1 address 172.16.50.2/29"
  echo "  set firewall zone LAN from DMZ firewall name 'DMZ-to-LAN'"
  echo "Blank = cancel"
  echo
  local cmd yn
  read -r -p "> " cmd
  [ -z "$cmd" ] && return 0

  read -r -p "Are you sure you want to run that command? (y/n) [n]: " yn
  yn="${yn:-n}"
  case "$yn" in
    y|Y) ;;
    *) echo "Canceled."; pause; return 0 ;;
  esac

  configure
  eval "$cmd"
  cfg_apply
}

# -----------------------------
# Main
# -----------------------------
main_menu() {
  die_no_access_if_needed

  while true; do
    refresh_cfg_cache
    echo
    echo "=================================="
    echo " VyOS Dynamic Menu (Scan + CRUD)"
    echo "=================================="
    show_detected_summary
    echo "1) Interfaces submenu"
    echo "2) Firewall submenu"
    echo "3) NAT submenu"
    echo "4) Raw mode (set/delete anything)"
    echo "5) Show full config (commands)"
    echo "6) Exit"
    echo
    read -r -p "Select menu option #: " c
    case "$c" in
      1) iface_menu ;;
      2) firewall_menu ;;
      3) nat_menu ;;
      4) raw_mode ;;
      5) echo; printf "%s\n" "$CFG_CACHE"; echo; pause ;;
      6) exit 0 ;;
      *) echo "Invalid." ;;
    esac
  done
}

main_menu
