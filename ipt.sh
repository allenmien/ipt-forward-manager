#!/usr/bin/env bash

set -u

APP_NAME="ipt-forward-manager"
VERSION="2.3"
DEFAULT_COMMENT_PREFIX="xjj-forward"
BACKUP_DIR="/root/iptables-backup"
CONF_DIR="/root/iptables-forward-conf"
MANAGED_CONF="$CONF_DIR/managed-forwards.conf"
LOG_FILE="/var/log/ipt-forward-manager.log"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"
UFW_BEGIN="# BEGIN ipt-forward-manager managed rules"
UFW_END="# END ipt-forward-manager managed rules"

is_alpine() {
  [ -f /etc/alpine-release ]
}

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'
}

ufw_route_needed_by_other_forward() {
  local target_ip="$1" target_port="$2" proto="$3" comment="$4"
  local in_port target_host conf_target_port conf_proto conf_comment resolved count=0
  [ -f "$MANAGED_CONF" ] || return 1

  while read -r in_port target_host conf_target_port conf_proto conf_comment _rest; do
    [ "$conf_target_port" = "$target_port" ] || continue
    [ "$conf_proto" = "$proto" ] || continue
    [ "$conf_comment" = "$comment" ] || continue
    resolved="$(resolve_target "$target_host" 2>/dev/null || true)"
    if [ "$resolved" = "$target_ip" ]; then
      count=$((count + 1))
      [ "$count" -gt 1 ] && return 0
    fi
  done < "$MANAGED_CONF"
  return 1
}

sync_ufw_managed_rules() {
  ufw_is_active || return 0

  local rules_file="/etc/ufw/before.rules"
  local tmp line in_port target_host target_port proto comment target_ip
  [ -f "$rules_file" ] || return 1
  tmp="$(mktemp)"

  awk -v begin="$UFW_BEGIN" -v end="$UFW_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$rules_file" > "$tmp"

  {
    echo
    echo "$UFW_BEGIN"
    echo "*nat"
    if [ -f "$MANAGED_CONF" ]; then
      while read -r in_port target_host target_port proto comment _rest; do
        [ -n "${comment:-}" ] || continue
        target_ip="$(resolve_target "$target_host" 2>/dev/null || true)"
        [ -n "$target_ip" ] || continue
        echo "-A PREROUTING -p $proto --dport $in_port -m comment --comment $comment -j DNAT --to-destination $target_ip:$target_port"
        echo "-A POSTROUTING -p $proto -d $target_ip --dport $target_port -m comment --comment $comment -j MASQUERADE"
      done < "$MANAGED_CONF"
    fi
    echo "COMMIT"
    echo "$UFW_END"
  } >> "$tmp"

  mv "$tmp" "$rules_file"
  ufw reload >/dev/null
  log "UFW managed NAT rules synchronized"
}

remove_ufw_managed_rules() {
  local rules_file="/etc/ufw/before.rules" tmp
  command -v ufw >/dev/null 2>&1 || return 0
  [ -f "$rules_file" ] || return 0
  tmp="$(mktemp)"
  awk -v begin="$UFW_BEGIN" -v end="$UFW_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$rules_file" > "$tmp"
  mv "$tmp" "$rules_file"
  ufw_is_active && ufw reload >/dev/null
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行：sudo bash $0${RESET}"
    exit 1
  fi
}

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

pause() {
  echo
  read -rp "按 Enter 返回菜单..."
}

safe_mkdirs() {
  mkdir -p "$BACKUP_DIR" "$CONF_DIR"
}

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

backup_rules() {
  safe_mkdirs
  local file="$BACKUP_DIR/iptables-$(timestamp).rules"
  iptables-save > "$file"
  echo -e "${GREEN}已备份当前规则：$file${RESET}"
  log "backup created: $file"
}

save_rules() {
  echo -e "${BLUE}保存 iptables 规则...${RESET}"

  if ufw_is_active; then
    if sync_ufw_managed_rules; then
      echo -e "${GREEN}规则已写入 UFW 持久配置并重新加载。${RESET}"
      log "rules saved by UFW"
    else
      echo -e "${RED}UFW 规则保存失败。${RESET}"
      return 1
    fi
  elif command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    echo -e "${GREEN}规则已通过 netfilter-persistent 保存。${RESET}"
    log "rules saved by netfilter-persistent"
  elif is_alpine && command -v rc-service >/dev/null 2>&1; then
    rc-service iptables save >/dev/null 2>&1 || {
      mkdir -p /var/lib/iptables
      iptables-save > /var/lib/iptables/rules-save
    }
    rc-update add iptables default >/dev/null 2>&1 || true
    echo -e "${GREEN}规则已保存到 /var/lib/iptables/rules-save，并已启用 iptables OpenRC 服务。${RESET}"
    log "rules saved for Alpine OpenRC"
  else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo -e "${GREEN}规则已保存到 /etc/iptables/rules.v4${RESET}"
    echo -e "${YELLOW}注意：如果未安装 iptables-persistent，重启后不一定自动加载。${RESET}"
    log "rules saved to /etc/iptables/rules.v4"
  fi
}

check_iptables() {
  echo -e "${BLUE}检查 iptables...${RESET}"

  if command -v iptables >/dev/null 2>&1; then
    echo -e "${GREEN}iptables 已安装：$(iptables --version)${RESET}"
  else
    echo -e "${RED}iptables 未安装。${RESET}"
    read -rp "是否现在安装 iptables 及规则持久化组件？[y/N]: " yn
    case "$yn" in
      y|Y)
        if is_alpine; then
          apk add --no-cache bash iptables iptables-openrc
        elif command -v apt >/dev/null 2>&1; then
          apt update
          apt install -y iptables iptables-persistent netfilter-persistent
        else
          echo -e "${RED}未识别到受支持的包管理器，请手动安装 iptables。${RESET}"
        fi
        ;;
      *)
        echo "已取消安装。"
        ;;
    esac
  fi

  if command -v iptables-save >/dev/null 2>&1; then
    echo -e "${GREEN}iptables-save 可用。${RESET}"
  else
    echo -e "${RED}iptables-save 不可用，请检查 iptables 安装。${RESET}"
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    echo -e "${GREEN}netfilter-persistent 已安装。${RESET}"
  elif is_alpine && [ -x /etc/init.d/iptables ]; then
    echo -e "${GREEN}Alpine iptables OpenRC 持久化服务已安装。${RESET}"
  else
    if is_alpine; then
      echo -e "${YELLOW}iptables-openrc 未安装，建议执行：apk add iptables-openrc${RESET}"
    else
      echo -e "${YELLOW}netfilter-persistent 未安装，保存规则时会写入 /etc/iptables/rules.v4。${RESET}"
    fi
  fi
}

check_sysctl() {
  echo -e "${BLUE}检查 IPv4 转发配置...${RESET}"

  mkdir -p /etc

  if [ ! -f /etc/sysctl.conf ]; then
    echo -e "${YELLOW}/etc/sysctl.conf 不存在，正在创建...${RESET}"
    touch /etc/sysctl.conf
  fi

  local current_runtime
  current_runtime="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  echo "当前运行状态 /proc/sys/net/ipv4/ip_forward = $current_runtime"

  if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' /etc/sysctl.conf; then
    echo -e "${GREEN}/etc/sysctl.conf 已正确配置 net.ipv4.ip_forward=1${RESET}"
  else
    echo -e "${YELLOW}/etc/sysctl.conf 未正确配置，正在修复...${RESET}"

    if grep -qE '^[[:space:]]*#?[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' /etc/sysctl.conf; then
      sed -i 's/^[[:space:]]*#\?[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi

    echo -e "${GREEN}已写入 net.ipv4.ip_forward=1${RESET}"
  fi

  echo 1 > /proc/sys/net/ipv4/ip_forward

  if command -v sysctl >/dev/null 2>&1; then
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
  fi

  local after_runtime
  after_runtime="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"

  if [ "$after_runtime" = "1" ]; then
    echo -e "${GREEN}IPv4 转发已开启。${RESET}"
    log "ip_forward enabled"
  else
    echo -e "${RED}IPv4 转发可能未成功开启，请手动检查。${RESET}"
    log "ip_forward enable failed"
  fi
}

protocols_from_choice() {
  local choice="$1"
  case "$choice" in
    1|tcp|TCP) echo "tcp" ;;
    2|udp|UDP) echo "udp" ;;
    3|both|BOTH|all|ALL) echo "tcp udp" ;;
    *) echo "" ;;
  esac
}

ask_protocols() {
  echo >&2
  echo "请选择协议：" >&2
  echo "1) TCP" >&2
  echo "2) UDP" >&2
  echo "3) TCP + UDP" >&2
  read -rp "请选择 [默认 3]: " proto_choice >&2
  proto_choice="${proto_choice:-3}"

  local protocols
  protocols="$(protocols_from_choice "$proto_choice")"

  if [ -z "$protocols" ]; then
    echo -e "${RED}协议选择无效。${RESET}" >&2
    return 1
  fi

  echo "$protocols"
}

ask_protocols_for_delete() {
  echo >&2
  echo "请选择要删除的协议，未选择的协议会保留：" >&2
  echo "1) TCP" >&2
  echo "2) UDP" >&2
  echo "3) TCP + UDP" >&2
  read -rp "请选择 [默认 3]: " proto_choice >&2
  proto_choice="${proto_choice:-3}"

  local protocols
  protocols="$(protocols_from_choice "$proto_choice")"

  if [ -z "$protocols" ]; then
    echo -e "${RED}协议选择无效。${RESET}" >&2
    return 1
  fi

  echo "$protocols"
}

protocol_label() {
  local protocols="$1"

  if echo "$protocols" | grep -qw "tcp" && echo "$protocols" | grep -qw "udp"; then
    echo "tcp+udp"
  else
    echo "$protocols"
  fi
}

is_ipv4() {
  local value="$1"
  echo "$value" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

valid_port() {
  local port="$1"
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

valid_comment() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.:@+-]+$'
}

resolve_target() {
  local target="$1"
  local resolved=""

  if is_ipv4 "$target"; then
    echo "$target"
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahostsv4 "$target" | awk '{print $1; exit}')"
  fi

  if [ -z "$resolved" ] && command -v dig >/dev/null 2>&1; then
    resolved="$(dig +short A "$target" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1)"
  fi

  if [ -z "$resolved" ] && command -v host >/dev/null 2>&1; then
    resolved="$(host -t A "$target" | awk '/has address/ {print $4; exit}')"
  fi

  if [ -z "$resolved" ]; then
    return 1
  fi

  echo "$resolved"
}

register_forward_config() {
  local in_port="$1"
  local target_host="$2"
  local target_port="$3"
  local proto="$4"
  local comment="$5"
  local tmp

  safe_mkdirs
  touch "$MANAGED_CONF"
  tmp="$(mktemp)"

  awk -v in_port="$in_port" -v target_port="$target_port" -v proto="$proto" -v comment="$comment" '
    NF < 5 { next }
    !($1 == in_port && $3 == target_port && $4 == proto && $5 == comment) { print }
  ' "$MANAGED_CONF" > "$tmp"

  echo "$in_port $target_host $target_port $proto $comment" >> "$tmp"
  mv "$tmp" "$MANAGED_CONF"
  log "managed config updated: $in_port $target_host $target_port $proto $comment"
}

remove_managed_forward_config() {
  local in_port="$1"
  local target_port="$2"
  local proto="$3"
  local comment="$4"
  local tmp

  [ -f "$MANAGED_CONF" ] || return
  tmp="$(mktemp)"

  awk -v in_port="$in_port" -v target_port="$target_port" -v proto="$proto" -v comment="$comment" '
    NF < 5 { next }
    !($1 == in_port && $3 == target_port && $4 == proto && $5 == comment) { print }
  ' "$MANAGED_CONF" > "$tmp"

  mv "$tmp" "$MANAGED_CONF"
  log "managed config removed: in=$in_port target_port=$target_port proto=$proto comment=$comment"
}

remove_managed_by_comment() {
  local comment="$1"
  local tmp

  [ -f "$MANAGED_CONF" ] || return
  tmp="$(mktemp)"

  awk -v comment="$comment" 'NF < 5 { next } $5 != comment { print }' "$MANAGED_CONF" > "$tmp"
  mv "$tmp" "$MANAGED_CONF"
  log "managed config removed by comment: $comment"
}

managed_target_for_rule() {
  local in_port="$1"
  local target_port="$2"
  local proto="$3"
  local comment="$4"

  [ -f "$MANAGED_CONF" ] || return

  awk -v in_port="$in_port" -v target_port="$target_port" -v proto="$proto" -v comment="$comment" '
    $1 == in_port && $3 == target_port && $4 == proto && $5 == comment { print $2; exit }
  ' "$MANAGED_CONF"
}

# Extract comment from iptables-save rule line, supports both quoted and unquoted
get_rule_comment() {
  local line="$1"
  echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="--comment") {print $(i+1); exit}}' | tr -d '"'
}

# Generate grep pattern for comment, supports --comment sunny-use and --comment "sunny-use"
comment_grep_pattern() {
  local comment="$1"
  local escaped
  escaped="$(printf '%s' "$comment" | sed 's/[][(){}.^$*+?|\\]/\\&/g')"
  printf '%s' "--comment \"?${escaped}\"?( |$)"
}

rule_exists_nat() {
  local chain="$1"
  shift
  iptables -t nat -C "$chain" "$@" >/dev/null 2>&1
}

rule_exists_filter() {
  local chain="$1"
  shift
  iptables -C "$chain" "$@" >/dev/null 2>&1
}

add_one_forward() {
  local in_port="$1"
  local target_host="$2"
  local target_port="$3"
  local proto="$4"
  local comment="$5"
  local target_ip

  if ! valid_port "$in_port" || ! valid_port "$target_port"; then
    echo -e "${RED}端口必须是 1-65535 的整数。${RESET}"
    return 1
  fi
  if [ "$proto" != "tcp" ] && [ "$proto" != "udp" ]; then
    echo -e "${RED}协议必须是 tcp 或 udp。${RESET}"
    return 1
  fi
  if ! valid_comment "$comment"; then
    echo -e "${RED}备注只能包含字母、数字及 _ . : @ + -，且不能含空格。${RESET}"
    return 1
  fi

  if ! target_ip="$(resolve_target "$target_host")"; then
    echo -e "${RED}目标解析失败：$target_host${RESET}"
    log "resolve failed target=$target_host proto=$proto in=$in_port target_port=$target_port comment=$comment"
    return 1
  fi

  if [ "$target_host" != "$target_ip" ]; then
    echo -e "${CYAN}域名解析：$target_host -> $target_ip${RESET}"
  fi

  if rule_exists_nat PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j DNAT --to-destination "$target_ip:$target_port"; then
    echo -e "${YELLOW}已存在：$proto PREROUTING $in_port -> $target_ip:$target_port${RESET}"
  else
    iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j DNAT --to-destination "$target_ip:$target_port" || return 1
    echo -e "${GREEN}已添加：$proto PREROUTING $in_port -> $target_ip:$target_port${RESET}"
  fi

  if rule_exists_nat POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j MASQUERADE; then
    echo -e "${YELLOW}已存在：$proto POSTROUTING MASQUERADE $target_ip:$target_port${RESET}"
  else
    iptables -t nat -A POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j MASQUERADE || return 1
    echo -e "${GREEN}已添加：$proto POSTROUTING MASQUERADE $target_ip:$target_port${RESET}"
  fi

  if ufw_is_active; then
    if ufw --force route allow proto "$proto" to "$target_ip" port "$target_port" comment "$comment" >/dev/null; then
      echo -e "${GREEN}已通过 UFW 放行转发：$proto -> $target_ip:$target_port${RESET}"
    else
      echo -e "${RED}UFW 转发放行失败：$proto -> $target_ip:$target_port${RESET}"
      return 1
    fi
  elif rule_exists_filter FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT; then
    echo -e "${YELLOW}已存在：$proto FORWARD ACCEPT $target_ip:$target_port${RESET}"
  else
    iptables -A FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT || return 1
    echo -e "${GREEN}已添加：$proto FORWARD ACCEPT $target_ip:$target_port${RESET}"
  fi

  register_forward_config "$in_port" "$target_host" "$target_port" "$proto" "$comment"
  log "add forward proto=$proto in=$in_port target=$target_host($target_ip):$target_port comment=$comment"
}

delete_one_forward_selected() {
  local in_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"
  local comment="$5"

  while rule_exists_nat PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j DNAT --to-destination "$target_ip:$target_port"; do
    iptables -t nat -D PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j DNAT --to-destination "$target_ip:$target_port"
  done

  while rule_exists_nat POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j MASQUERADE; do
    iptables -t nat -D POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j MASQUERADE
  done

  if command -v ufw >/dev/null 2>&1; then
    if ! ufw_route_needed_by_other_forward "$target_ip" "$target_port" "$proto" "$comment"; then
      ufw --force route delete allow proto "$proto" to "$target_ip" port "$target_port" comment "$comment" >/dev/null 2>&1 || true
    fi
  fi
  while rule_exists_filter FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT; do
    iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT
  done

  log "delete selected forward proto=$proto in=$in_port target=$target_ip:$target_port comment=$comment"
}

delete_saved_forward_rules() {
  local in_port="$1"
  local target_port="$2"
  local proto="$3"
  local comment="$4"
  local current_ip

  while current_ip="$(current_forward_target_ip "$in_port" "$target_port" "$proto" "$comment")"; [ -n "$current_ip" ]; do
    delete_one_forward_selected "$in_port" "$current_ip" "$target_port" "$proto" "$comment"
  done

  log "delete saved forward rules proto=$proto in=$in_port target_port=$target_port comment=$comment"
}

current_forward_target_ip() {
  local in_port="$1"
  local target_port="$2"
  local proto="$3"
  local comment="$4"
  local pattern
  pattern="$(comment_grep_pattern "$comment")"

  iptables-save -t nat | grep -E -- "$pattern" | grep "^-A PREROUTING" | grep -- "-p $proto " | grep -E -- "--dport $in_port( |$)" | grep -E -- "--to-destination [^ ]+:$target_port( |$)" | head -n 1 | grep -oE -- '--to-destination [^ ]+' | awk '{print $2}' | awk -F: '{print $1}'
}

refresh_managed_domain_forwards() {
  safe_mkdirs

  if [ ! -f "$MANAGED_CONF" ] || [ ! -s "$MANAGED_CONF" ]; then
    log "ddns refresh skipped: no managed config"
    return 0
  fi

  local tmp
  local changed=0
  tmp="$(mktemp)"
  cp "$MANAGED_CONF" "$tmp"

  while read -r in_port target_host target_port proto comment _rest; do
    [ -z "${in_port:-}" ] && continue
    echo "$in_port" | grep -q '^#' && continue
    if [ -z "${target_host:-}" ] || [ -z "${target_port:-}" ] || [ -z "${proto:-}" ] || [ -z "${comment:-}" ]; then
      log "ddns refresh skipped malformed line: $in_port ${target_host:-} ${target_port:-} ${proto:-} ${comment:-}"
      continue
    fi

    if is_ipv4 "$target_host"; then
      continue
    fi

    local resolved_ip
    if ! resolved_ip="$(resolve_target "$target_host")"; then
      echo -e "${YELLOW}域名解析失败，跳过：$target_host${RESET}"
      log "ddns refresh resolve failed target=$target_host proto=$proto in=$in_port target_port=$target_port comment=$comment"
      continue
    fi

    local current_ip
    current_ip="$(current_forward_target_ip "$in_port" "$target_port" "$proto" "$comment")"

    if [ "$current_ip" = "$resolved_ip" ]; then
      log "ddns refresh unchanged target=$target_host ip=$resolved_ip proto=$proto in=$in_port comment=$comment"
      continue
    fi

    echo -e "${CYAN}刷新域名转发：$target_host $current_ip -> $resolved_ip ($proto $in_port -> $target_port)${RESET}"
    delete_saved_forward_rules "$in_port" "$target_port" "$proto" "$comment"
    add_one_forward "$in_port" "$target_host" "$target_port" "$proto" "$comment"
    changed=1
  done < "$tmp"

  rm -f "$tmp"

  if [ "$changed" -eq 1 ]; then
    save_rules
    log "ddns refresh changed and saved"
  else
    echo -e "${GREEN}域名转发无需更新。${RESET}"
    log "ddns refresh no changes"
  fi
}

delete_by_comment_core() {
  local comment="$1"
  local tmp in_port target_host target_port proto conf_comment

  if [ ! -f "$MANAGED_CONF" ]; then
    echo -e "${YELLOW}没有找到脚本托管配置；为避免误删 UFW 或其他程序规则，未执行删除。${RESET}"
    return 1
  fi

  tmp="$(mktemp)"
  cp "$MANAGED_CONF" "$tmp"
  while read -r in_port target_host target_port proto conf_comment _rest; do
    [ "$conf_comment" = "$comment" ] || continue
    delete_saved_forward_rules "$in_port" "$target_port" "$proto" "$conf_comment"
    remove_managed_forward_config "$in_port" "$target_port" "$proto" "$conf_comment"
  done < "$tmp"
  rm -f "$tmp"

  remove_managed_by_comment "$comment"
  log "delete by comment: $comment"
}

collect_forward_configs() {
  local out_file="$1"
  local raw_file
  raw_file="$(mktemp)"

  iptables-save -t nat | grep "^-A PREROUTING" | grep "DNAT" | while read -r line; do
    proto="$(echo "$line" | grep -oE -- '-p (tcp|udp)' | awk '{print $2}')"
    in_port="$(echo "$line" | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | head -n 1)"
    target="$(echo "$line" | grep -oE -- '--to-destination [^ ]+' | awk '{print $2}')"
    target_ip="${target%:*}"
    target_port="${target##*:}"
    comment="$(get_rule_comment "$line")"

    [ -z "$comment" ] && continue
    [ -z "$proto" ] && continue
    [ -z "$in_port" ] && continue
    [ -z "$target_ip" ] && continue
    [ -z "$target_port" ] && continue

    echo "$comment|$in_port|$target_ip|$target_port|$proto" >> "$raw_file"
  done

  if [ ! -s "$raw_file" ]; then
    : > "$out_file"
    rm -f "$raw_file"
    return
  fi

  sort -t '|' -k1,1 -k2,2n -k3,3 -k4,4 -k5,5 "$raw_file" | awk -F'|' '
    {
      key=$1 FS $2 FS $3 FS $4
      if (!(key in seen)) {
        seen[key]=1
        keys[++count]=key
      }
      if ($5 == "tcp") {
        has_tcp[key]=1
      }
      if ($5 == "udp") {
        has_udp[key]=1
      }
    }
    END {
      for (i=1; i<=count; i++) {
        key=keys[i]
        protocols=""
        if (has_tcp[key]) {
          protocols="tcp"
        }
        if (has_udp[key]) {
          if (protocols == "") {
            protocols="udp"
          } else {
            protocols=protocols " udp"
          }
        }
        print key FS protocols
      }
    }
  ' > "$out_file"

  rm -f "$raw_file"
}

add_forward_interactive() {
  echo
  echo -e "${BLUE}添加单条端口转发。${RESET}"

  read -rp "入站端口，例如 8443: " in_port
  read -rp "目标 IP/域名，例如 1.1.1.1 或 home.example.com: " target_ip
  read -rp "目标端口，例如 443: " target_port

  protocols="$(ask_protocols)" || return

  read -rp "备注，例如 xjj-forward-8443，留空自动生成: " comment

  if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
    echo -e "${RED}入站端口、目标 IP/域名、目标端口不能为空。${RESET}"
    return
  fi

  if [ -z "$comment" ]; then
    comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"
  fi

  echo
  echo -e "${CYAN}即将添加：${RESET}"
  echo "入站端口: $in_port"
  echo "目标地址: $target_ip:$target_port"
  echo "协议: $protocols"
  echo "备注: $comment"
  echo

  read -rp "确认添加？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      check_sysctl
      for proto in $protocols; do
        add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
      done
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

batch_add_forward() {
  echo
  echo -e "${BLUE}批量添加转发。格式：入站端口 目标IP或域名 目标端口 协议 备注${RESET}"
  echo
  echo "协议支持：tcp / udp / both"
  echo
  echo "例如："
  echo "443 1.1.1.1 443 both xjj-forward-443"
  echo "8443 home.example.com 443 tcp xjj-forward-8443"
  echo
  echo "输入完成后，单独输入 END 结束。"
  echo

  local lines=()

  while true; do
    read -rp "> " line

    if [ "$line" = "END" ] || [ "$line" = "end" ]; then
      break
    fi

    [ -z "$line" ] && continue
    lines+=("$line")
  done

  if [ "${#lines[@]}" -eq 0 ]; then
    echo -e "${YELLOW}没有输入任何规则。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}解析到以下配置：${RESET}"
  printf "%-8s %-28s %-10s %-10s %-30s\n" "入站" "目标IP/域名" "目标端口" "协议" "备注"
  printf "%-8s %-28s %-10s %-10s %-30s\n" "----" "----------" "--------" "----" "----"

  for line in "${lines[@]}"; do
    in_port="$(echo "$line" | awk '{print $1}')"
    target_ip="$(echo "$line" | awk '{print $2}')"
    target_port="$(echo "$line" | awk '{print $3}')"
    proto_input="$(echo "$line" | awk '{print $4}')"
    comment="$(echo "$line" | awk '{print $5}')"

    [ -z "$proto_input" ] && proto_input="both"
    [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

    printf "%-8s %-28s %-10s %-10s %-30s\n" "$in_port" "$target_ip" "$target_port" "$proto_input" "$comment"
  done

  echo
  read -rp "确认批量添加？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      check_sysctl

      for line in "${lines[@]}"; do
        in_port="$(echo "$line" | awk '{print $1}')"
        target_ip="$(echo "$line" | awk '{print $2}')"
        target_port="$(echo "$line" | awk '{print $3}')"
        proto_input="$(echo "$line" | awk '{print $4}')"
        comment="$(echo "$line" | awk '{print $5}')"

        if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
          echo -e "${RED}跳过格式错误：$line${RESET}"
          continue
        fi

        [ -z "$proto_input" ] && proto_input="both"
        [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

        protocols="$(protocols_from_choice "$proto_input")"

        if [ -z "$protocols" ]; then
          echo -e "${RED}跳过协议错误：$line${RESET}"
          continue
        fi

        for proto in $protocols; do
          add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
        done
      done

      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

delete_by_comment() {
  echo
  echo -e "${BLUE}选择要删除的转发配置。${RESET}"

  local tmp
  tmp="$(mktemp)"
  collect_forward_configs "$tmp"

  if [ ! -s "$tmp" ]; then
    echo -e "${YELLOW}没有找到可删除的带备注 DNAT 转发规则。${RESET}"
    rm -f "$tmp"
    return
  fi

  echo
  echo -e "${CYAN}当前转发配置：${RESET}"
  printf "%-6s %-8s %-22s %-10s %-30s\n" "序号" "入站" "目标" "协议" "备注"
  printf "%-6s %-8s %-22s %-10s %-30s\n" "----" "----" "----" "----" "----"

  local configs=()
  local idx=0
  local comment in_port target_ip target_port existing_protocols

  while IFS='|' read -r comment in_port target_ip target_port existing_protocols; do
    idx=$((idx + 1))
    configs[$idx]="$comment|$in_port|$target_ip|$target_port|$existing_protocols"
    printf "%-6s %-8s %-22s %-10s %-30s\n" "$idx" "$in_port" "$target_ip:$target_port" "$(protocol_label "$existing_protocols")" "$comment"
  done < "$tmp"

  rm -f "$tmp"

  echo
  read -rp "请选择要删除的序号: " selected_index

  case "$selected_index" in
    ''|*[!0-9]*)
      echo -e "${RED}序号无效。${RESET}"
      return
      ;;
  esac

  if [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "$idx" ]; then
    echo -e "${RED}序号不存在。${RESET}"
    return
  fi

  IFS='|' read -r comment in_port target_ip target_port existing_protocols <<< "${configs[$selected_index]}"
  protocols="$(ask_protocols_for_delete)" || return

  echo
  echo -e "${CYAN}即将删除：${RESET}"
  echo "序号: $selected_index"
  echo "入站端口: $in_port"
  echo "目标地址: $target_ip:$target_port"
  echo "当前协议: $(protocol_label "$existing_protocols")"
  echo "删除协议: $(protocol_label "$protocols")"
  echo "备注: $comment"
  echo
  read -rp "确认删除？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      for proto in $protocols; do
        if echo "$existing_protocols" | grep -qw "$proto"; then
          delete_one_forward_selected "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
          remove_managed_forward_config "$in_port" "$target_port" "$proto" "$comment"
          echo -e "${GREEN}已删除：$proto $in_port -> $target_ip:$target_port${RESET}"
        else
          echo -e "${YELLOW}跳过：该配置不存在 $proto 规则。${RESET}"
        fi
      done
      echo -e "${GREEN}删除完成。${RESET}"
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

batch_delete_by_comment() {
  echo
  echo -e "${BLUE}批量按备注删除。每行输入一个 comment，输入 END 结束。${RESET}"
  echo

  local comments=()

  while true; do
    read -rp "> " comment

    if [ "$comment" = "END" ] || [ "$comment" = "end" ]; then
      break
    fi

    [ -z "$comment" ] && continue
    comments+=("$comment")
  done

  if [ "${#comments[@]}" -eq 0 ]; then
    echo -e "${YELLOW}没有输入任何备注。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}将删除以下备注对应规则：${RESET}"
  for c in "${comments[@]}"; do
    echo "---- $c ----"
    pattern="$(comment_grep_pattern "$c")"
    iptables-save | grep -E -- "$pattern" || echo "未找到"
  done

  echo
  read -rp "确认批量删除？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      for c in "${comments[@]}"; do
        delete_by_comment_core "$c"
        echo -e "${GREEN}已删除：$c${RESET}"
      done
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

search_rules() {
  echo
  read -rp "请输入要搜索的端口/IP/备注关键词，例如 8443 或 1.1.1.1: " keyword

  if [ -z "$keyword" ]; then
    echo -e "${RED}关键词不能为空。${RESET}"
    return
  fi

  echo -e "${BLUE}搜索结果：${RESET}"
  iptables-save | grep -E "$keyword" || echo "没有找到相关规则。"
}

show_all_rules() {
  echo -e "${BLUE}NAT 表规则：${RESET}"
  iptables -t nat -L -n -v --line-numbers

  echo
  echo -e "${BLUE}FORWARD 表规则：${RESET}"
  iptables -L FORWARD -n -v --line-numbers

  echo
  echo -e "${BLUE}iptables-save 中的备注规则：${RESET}"
  iptables-save | grep -- '--comment' || echo "没有找到带备注的规则。"
}

show_comment_rules() {
  echo -e "${BLUE}当前带备注的规则：${RESET}"
  iptables-save | grep -- '--comment' || echo "没有带备注的规则。"
}

show_summary() {
  echo -e "${BLUE}转发规则摘要：${RESET}"
  echo

  local tmp
  tmp="$(mktemp)"

  iptables-save -t nat | grep "^-A PREROUTING" | grep "DNAT" | while read -r line; do
    proto="$(echo "$line" | grep -oE -- '-p (tcp|udp)' | awk '{print $2}')"
    in_port="$(echo "$line" | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | head -n 1)"
    target="$(echo "$line" | grep -oE -- '--to-destination [^ ]+' | awk '{print $2}')"
    comment="$(get_rule_comment "$line")"
    [ -z "$comment" ] && comment="-"
    echo "$comment|$proto|$in_port|$target" >> "$tmp"
  done

  if [ ! -s "$tmp" ]; then
    echo "没有找到 DNAT 转发规则。"
    rm -f "$tmp"
    return
  fi

  printf "%-30s %-8s %-12s %-25s\n" "备注" "协议" "入站端口" "目标"
  printf "%-30s %-8s %-12s %-25s\n" "----" "----" "--------" "----"

  sort "$tmp" | while IFS='|' read -r comment proto in_port target; do
    printf "%-30s %-8s %-12s %-25s\n" "$comment" "$proto" "$in_port" "$target"
  done

  rm -f "$tmp"
}

export_conf() {
  safe_mkdirs

  local default_file="$CONF_DIR/forwards-$(timestamp).conf"
  read -rp "请输入导出文件路径 [默认 $default_file]: " out_file
  out_file="${out_file:-$default_file}"

  echo "# iptables forward config exported by $APP_NAME $VERSION" > "$out_file"
  echo "# format: in_port target_ip_or_domain target_port protocol comment" >> "$out_file"
  echo "# protocol: tcp / udp / both" >> "$out_file"
  echo >> "$out_file"

  local tmp
  tmp="$(mktemp)"

  iptables-save -t nat | grep "^-A PREROUTING" | grep "DNAT" | while read -r line; do
    proto="$(echo "$line" | grep -oE -- '-p (tcp|udp)' | awk '{print $2}')"
    in_port="$(echo "$line" | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | head -n 1)"
    target="$(echo "$line" | grep -oE -- '--to-destination [^ ]+' | awk '{print $2}')"
    target_ip="${target%:*}"
    target_port="${target##*:}"
    comment="$(get_rule_comment "$line")"
    [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"
    managed_target="$(managed_target_for_rule "$in_port" "$target_port" "$proto" "$comment")"
    [ -n "$managed_target" ] && target_ip="$managed_target"
    echo "$in_port $target_ip $target_port $proto $comment" >> "$tmp"
  done

  if [ ! -s "$tmp" ]; then
    echo -e "${YELLOW}没有可导出的 DNAT 转发规则。${RESET}"
    rm -f "$tmp"
    return
  fi

  # 简单导出，不强行合并 tcp/udp 为 both，避免误判。
  sort "$tmp" >> "$out_file"
  rm -f "$tmp"

  echo -e "${GREEN}已导出配置文件：$out_file${RESET}"
  log "config exported: $out_file"
}

parse_conf_preview() {
  local file="$1"
  local valid_count=0
  local invalid_count=0

  echo
  echo -e "${CYAN}解析到以下配置：${RESET}"
  printf "%-6s %-8s %-28s %-10s %-10s %-30s\n" "行号" "入站" "目标IP/域名" "目标端口" "协议" "备注"
  printf "%-6s %-8s %-28s %-10s %-10s %-30s\n" "----" "----" "----------" "--------" "----" "----"

  local line_no=0

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))

    line="$(echo "$line" | sed 's/#.*$//' | xargs)"
    [ -z "$line" ] && continue

    in_port="$(echo "$line" | awk '{print $1}')"
    target_ip="$(echo "$line" | awk '{print $2}')"
    target_port="$(echo "$line" | awk '{print $3}')"
    proto_input="$(echo "$line" | awk '{print $4}')"
    comment="$(echo "$line" | awk '{print $5}')"

    if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
      echo -e "${RED}第 $line_no 行格式错误：$line${RESET}"
      invalid_count=$((invalid_count + 1))
      continue
    fi

    [ -z "$proto_input" ] && proto_input="both"
    [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

    if [ -z "$(protocols_from_choice "$proto_input")" ]; then
      echo -e "${RED}第 $line_no 行协议错误：$line${RESET}"
      invalid_count=$((invalid_count + 1))
      continue
    fi

    printf "%-6s %-8s %-28s %-10s %-10s %-30s\n" "$line_no" "$in_port" "$target_ip" "$target_port" "$proto_input" "$comment"
    valid_count=$((valid_count + 1))
  done < "$file"

  echo
  echo "有效规则：$valid_count"
  echo "错误规则：$invalid_count"

  if [ "$valid_count" -eq 0 ]; then
    return 1
  fi

  return 0
}

import_conf() {
  echo
  read -rp "请输入 .conf 文件路径: " file

  if [ -z "$file" ]; then
    echo -e "${RED}文件路径不能为空。${RESET}"
    return
  fi

  if [ ! -f "$file" ]; then
    echo -e "${RED}文件不存在：$file${RESET}"
    return
  fi

  parse_conf_preview "$file" || {
    echo -e "${RED}没有可导入的有效规则。${RESET}"
    return
  }

  echo
  read -rp "确认导入以上规则？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      check_sysctl

      local line_no=0

      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))

        line="$(echo "$line" | sed 's/#.*$//' | xargs)"
        [ -z "$line" ] && continue

        in_port="$(echo "$line" | awk '{print $1}')"
        target_ip="$(echo "$line" | awk '{print $2}')"
        target_port="$(echo "$line" | awk '{print $3}')"
        proto_input="$(echo "$line" | awk '{print $4}')"
        comment="$(echo "$line" | awk '{print $5}')"

        if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
          echo -e "${RED}跳过第 $line_no 行：格式错误${RESET}"
          continue
        fi

        [ -z "$proto_input" ] && proto_input="both"
        [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

        protocols="$(protocols_from_choice "$proto_input")"

        if [ -z "$protocols" ]; then
          echo -e "${RED}跳过第 $line_no 行：协议错误${RESET}"
          continue
        fi

        for proto in $protocols; do
          add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
        done
      done < "$file"

      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

list_backups() {
  safe_mkdirs
  echo -e "${BLUE}备份文件列表：${RESET}"
  ls -lh "$BACKUP_DIR"/*.rules 2>/dev/null || echo "没有找到备份文件。"
}

restore_backup() {
  safe_mkdirs
  list_backups
  echo
  read -rp "请输入要回滚的备份文件完整路径: " file

  if [ -z "$file" ]; then
    echo -e "${RED}路径不能为空。${RESET}"
    return
  fi

  if [ ! -f "$file" ]; then
    echo -e "${RED}备份文件不存在：$file${RESET}"
    return
  fi

  echo
  echo -e "${YELLOW}警告：这会用备份覆盖当前 iptables 规则。${RESET}"
  read -rp "确认回滚？[y/N]: " yn

  case "$yn" in
    y|Y)
      backup_rules
      iptables-restore < "$file"
      save_rules
      echo -e "${GREEN}已回滚到：$file${RESET}"
      log "restore backup: $file"
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

test_target() {
  echo
  read -rp "目标 IP/域名，例如 1.1.1.1 或 home.example.com: " target_ip
  read -rp "目标端口，例如 443: " target_port

  if [ -z "$target_ip" ] || [ -z "$target_port" ]; then
    echo -e "${RED}目标 IP/域名和端口不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${BLUE}测试 TCP 连接：$target_ip:$target_port${RESET}"

  if command -v nc >/dev/null 2>&1; then
    nc -vz -w 3 "$target_ip" "$target_port"
  elif command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/$target_ip/$target_port" >/dev/null 2>&1 \
      && echo -e "${GREEN}TCP 可连接。${RESET}" \
      || echo -e "${RED}TCP 不可连接或超时。${RESET}"
  else
    if is_alpine; then
      echo -e "${YELLOW}没有 nc/timeout，无法测试。可以安装：apk add netcat-openbsd coreutils${RESET}"
    else
      echo -e "${YELLOW}没有 nc/timeout，无法测试。可以安装：apt install netcat-openbsd -y${RESET}"
    fi
  fi

  echo
  echo -e "${YELLOW}UDP 无法像 TCP 一样可靠判断是否打开；这里只能说明包是否能发出，不能证明服务可用。${RESET}"
}

test_forward_hit() {
  echo
  read -rp "请输入要查看命中的入站端口，例如 8443: " port

  if [ -z "$port" ]; then
    echo -e "${RED}端口不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${BLUE}NAT PREROUTING 命中情况：${RESET}"
  iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "dpt:$port|Chain|num" || echo "没有找到相关 PREROUTING 规则。"

  echo
  echo -e "${BLUE}FORWARD 命中情况：${RESET}"
  iptables -L FORWARD -n -v --line-numbers | grep -E "dpt:|Chain|num" || true

  echo
  echo -e "${YELLOW}提示：如果 packets/bytes 数字增加，说明流量命中了规则。${RESET}"
}

modify_rule() {
  echo
  echo -e "${BLUE}修改规则：建议通过旧备注删除，再添加新规则。${RESET}"
  echo

  read -rp "请输入旧规则备注 comment，例如 xjj-forward-8443: " old_comment

  if [ -z "$old_comment" ]; then
    echo -e "${RED}旧备注不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}旧规则：${RESET}"
  pattern="$(comment_grep_pattern "$old_comment")"
  iptables-save | grep -E -- "$pattern" || {
    echo -e "${RED}没有找到旧备注对应规则。${RESET}"
    return
  }

  echo
  read -rp "新入站端口: " in_port
  read -rp "新目标 IP/域名: " target_ip
  read -rp "新目标端口: " target_port
  protocols="$(ask_protocols)" || return
  read -rp "新备注，留空继续使用旧备注: " new_comment

  [ -z "$new_comment" ] && new_comment="$old_comment"

  if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
    echo -e "${RED}新入站端口、目标 IP/域名、目标端口不能为空。${RESET}"
    return
  fi
  if ! valid_port "$in_port" || ! valid_port "$target_port" || ! valid_comment "$new_comment"; then
    echo -e "${RED}端口或备注格式无效，未修改旧规则。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}即将执行修改：${RESET}"
  echo "删除旧备注：$old_comment"
  echo "添加新规则：$protocols $in_port -> $target_ip:$target_port comment=$new_comment"
  echo

  read -rp "确认修改？[y/N]: " yn

  case "$yn" in
    y|Y)
      backup_rules
      delete_by_comment_core "$old_comment"
      check_sysctl
      for proto in $protocols; do
        add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$new_comment"
      done
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

install_self_check_service() {
  echo
  echo -e "${BLUE}安装自检/DDNS 刷新服务...${RESET}"

  if [ ! -f "$SELF_PATH" ]; then
    echo -e "${RED}无法定位当前脚本路径：$SELF_PATH${RESET}"
    return
  fi

  if is_alpine; then
    if ! command -v rc-service >/dev/null 2>&1; then
      echo -e "${RED}未找到 OpenRC，请先安装 openrc。${RESET}"
      return
    fi

    if ! apk add --no-cache bash iptables iptables-openrc >/dev/null; then
      echo -e "${RED}Alpine 依赖安装失败。${RESET}"
      return
    fi
    cat > /etc/init.d/ipt-forward-selfcheck <<EOF
#!/sbin/openrc-run
description="iptables forward manager self check"
command="/bin/bash"
command_args="$SELF_PATH --self-check"

depend() {
  need net
  after firewall
}
EOF
    chmod +x /etc/init.d/ipt-forward-selfcheck
    rc-update add ipt-forward-selfcheck default >/dev/null 2>&1 || true

    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    sed -i '\|# ipt-forward-selfcheck$|d' /etc/crontabs/root
    echo "*/5 * * * * /bin/bash $SELF_PATH --self-check # ipt-forward-selfcheck" >> /etc/crontabs/root
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
    rc-service ipt-forward-selfcheck start >/dev/null 2>&1 || true

    echo -e "${GREEN}已安装并启用 OpenRC 自检服务及 crond 定时任务。${RESET}"
    echo "默认每 5 分钟刷新一次域名/DDNS 转发。"
    echo "查看日志：cat $LOG_FILE"
    log "self-check OpenRC service and cron installed"
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}当前系统既不是 Alpine/OpenRC，也未找到 systemd。${RESET}"
    return
  fi

  cat > /etc/systemd/system/ipt-forward-selfcheck.service <<EOF
[Unit]
Description=iptables forward manager self check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SELF_PATH --self-check
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/ipt-forward-selfcheck.timer <<EOF
[Unit]
Description=run iptables forward manager self check periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=ipt-forward-selfcheck.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable ipt-forward-selfcheck.service
  systemctl enable --now ipt-forward-selfcheck.timer

  echo -e "${GREEN}已安装并启用 ipt-forward-selfcheck.service / ipt-forward-selfcheck.timer${RESET}"
  echo "默认每 5 分钟刷新一次域名/DDNS 转发。"
  echo "查看日志：cat $LOG_FILE"
  log "self-check service and timer installed"
}

uninstall_self_check_service() {
  echo -e "${BLUE}卸载自检/DDNS 刷新服务...${RESET}"

  if is_alpine; then
    rc-update del ipt-forward-selfcheck default >/dev/null 2>&1 || true
    rc-service ipt-forward-selfcheck stop >/dev/null 2>&1 || true
    rm -f /etc/init.d/ipt-forward-selfcheck
    if [ -f /etc/crontabs/root ]; then
      sed -i '\|# ipt-forward-selfcheck$|d' /etc/crontabs/root
    fi
    rc-service crond restart >/dev/null 2>&1 || true
    echo -e "${GREEN}已卸载。${RESET}"
    log "self-check OpenRC service and cron uninstalled"
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}未找到 systemd，无法卸载对应服务。${RESET}"
    return
  fi

  systemctl disable --now ipt-forward-selfcheck.timer >/dev/null 2>&1 || true
  systemctl disable ipt-forward-selfcheck.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/ipt-forward-selfcheck.timer
  rm -f /etc/systemd/system/ipt-forward-selfcheck.service
  systemctl daemon-reload

  echo -e "${GREEN}已卸载。${RESET}"
  log "self-check service and timer uninstalled"
}

uninstall_all() {
  echo
  echo -e "${RED}这将删除本脚本托管的全部转发规则、服务、定时任务、配置、备份、日志和脚本文件。${RESET}"
  echo -e "${YELLOW}不会停止/禁用 crond，也不会卸载 iptables、UFW、OpenRC 等共享软件包。${RESET}"
  read -rp "确认彻底卸载？请输入 DELETE: " confirm
  [ "$confirm" = "DELETE" ] || { echo "已取消。"; return; }

  local tmp in_port target_host target_port proto comment target_ip
  if [ -f "$MANAGED_CONF" ]; then
    tmp="$(mktemp)"
    cp "$MANAGED_CONF" "$tmp"
    while read -r in_port target_host target_port proto comment _rest; do
      [ -n "${comment:-}" ] || continue
      delete_saved_forward_rules "$in_port" "$target_port" "$proto" "$comment"
      target_ip="$(resolve_target "$target_host" 2>/dev/null || true)"
      if [ -n "$target_ip" ]; then
        delete_one_forward_selected "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
      fi
      remove_managed_forward_config "$in_port" "$target_port" "$proto" "$comment"
    done < "$tmp"
    rm -f "$tmp"
  fi

  if command -v ufw >/dev/null 2>&1; then
    remove_ufw_managed_rules
  fi
  if ! ufw_is_active; then
    save_rules
  fi

  uninstall_self_check_service
  log "full uninstall completed"
  rm -rf "$CONF_DIR" "$BACKUP_DIR"
  rm -f "$LOG_FILE"
  if [ -f "$SELF_PATH" ]; then
    rm -f "$SELF_PATH"
  fi

  echo -e "${GREEN}已彻底卸载本脚本托管内容；crond 保持原状态。${RESET}"
  exit 0
}

self_check() {
  log "self-check start"

  if command -v iptables >/dev/null 2>&1; then
    log "iptables ok: $(iptables --version)"
  else
    log "iptables missing"
  fi

  local ipf
  ipf="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  log "runtime ip_forward=$ipf"

  if [ "$ipf" != "1" ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    log "attempted to enable runtime ip_forward"
  fi

  local count
  count="$(iptables-save -t nat 2>/dev/null | grep -c "DNAT" || echo 0)"
  log "dnat rule count=$count"

  refresh_managed_domain_forwards

  log "self-check end"
}

view_log() {
  echo -e "${BLUE}日志：$LOG_FILE${RESET}"
  if [ -f "$LOG_FILE" ]; then
    tail -n 100 "$LOG_FILE"
  else
    echo "暂无日志。"
  fi
}

menu() {
  clear
  echo "=================================================="
  echo " $APP_NAME v$VERSION"
  echo "=================================================="
  echo " 基础检查"
  echo "  1) 检查 iptables 是否安装"
  echo "  2) 检查/修复 IPv4 转发 sysctl"
  echo
  echo " 规则查看"
  echo "  3) 查看规则摘要表"
  echo "  4) 查看全部 NAT / FORWARD 规则"
  echo "  5) 搜索旧规则，包括端口/IP/备注"
  echo "  6) 只显示带备注的规则"
  echo "  7) 查看某端口规则命中次数"
  echo
  echo " 添加/删除/修改"
  echo "  8) 添加单条转发"
  echo "  9) 批量添加转发"
  echo " 10) 选择配置删除规则"
  echo " 11) 批量按备注删除规则"
  echo " 12) 修改已有规则"
  echo
  echo " 配置导入导出"
  echo " 13) 导出当前转发为 .conf"
  echo " 14) 从 .conf 导入转发，导入前预览"
  echo
  echo " 备份/回滚/测试"
  echo " 15) 备份当前 iptables 规则"
  echo " 16) 查看备份列表"
  echo " 17) 从备份回滚"
  echo " 18) 测试目标端口 TCP 可达性"
  echo " 19) 保存当前规则"
  echo
  echo " 自检/DDNS/日志"
  echo " 20) 安装自检/DDNS 刷新服务"
  echo " 21) 彻底卸载脚本及全部托管规则/配置"
  echo " 22) 查看脚本日志"
  echo " 23) 刷新域名/DDNS 转发"
  echo
  echo "  0) 退出"
  echo "=================================================="
}

main() {
  if [ "${1:-}" = "--self-check" ]; then
    self_check
    exit 0
  fi

  need_root
  safe_mkdirs

  while true; do
    menu
    read -rp "请选择: " choice

    case "$choice" in
      1) check_iptables; pause ;;
      2) check_sysctl; pause ;;
      3) show_summary; pause ;;
      4) show_all_rules; pause ;;
      5) search_rules; pause ;;
      6) show_comment_rules; pause ;;
      7) test_forward_hit; pause ;;
      8) add_forward_interactive; pause ;;
      9) batch_add_forward; pause ;;
      10) delete_by_comment; pause ;;
      11) batch_delete_by_comment; pause ;;
      12) modify_rule; pause ;;
      13) export_conf; pause ;;
      14) import_conf; pause ;;
      15) backup_rules; pause ;;
      16) list_backups; pause ;;
      17) restore_backup; pause ;;
      18) test_target; pause ;;
      19) save_rules; pause ;;
      20) install_self_check_service; pause ;;
      21) uninstall_all ;;
      22) view_log; pause ;;
      23) refresh_managed_domain_forwards; pause ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选择。${RESET}"; pause ;;
    esac
  done
}

main "$@"
