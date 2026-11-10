#!/usr/bin/env sh
set -eu

SCRIPT="./kun.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$SCRIPT" ] || fail "$SCRIPT does not exist"
[ -x "$SCRIPT" ] || fail "$SCRIPT is not executable"

sh -n "$SCRIPT"

HELP_OUTPUT="$("$SCRIPT" -h 2>&1)"
echo "$HELP_OUTPUT" | grep 'Usage:' >/dev/null || fail "help output misses Usage"
echo "$HELP_OUTPUT" | grep -- '-d' >/dev/null || fail "help output misses -d"
echo "$HELP_OUTPUT" | grep -- '-u' >/dev/null || fail "help output misses -u"

MENU_OUTPUT="$(printf '0\n' | "$SCRIPT" 2>&1)"
echo "$MENU_OUTPUT" | grep 'KUN 服务器管理' >/dev/null || fail "menu title is missing"
echo "$MENU_OUTPUT" | grep '| 查看 ' >/dev/null || fail "view menu group is missing"
echo "$MENU_OUTPUT" | grep '| 执行 / 管理 ' >/dev/null || fail "execution menu group is missing"
echo "$MENU_OUTPUT" | grep '1) 查看监听端口' >/dev/null || fail "port menu option is missing"
echo "$MENU_OUTPUT" | grep '2) 查看 Docker 服务及容器' >/dev/null || fail "Docker status menu option is missing"
echo "$MENU_OUTPUT" | grep '3) 查看服务器概况' >/dev/null || fail "server overview menu option is missing"
echo "$MENU_OUTPUT" | grep '4) 查看 Tailscale 状态' >/dev/null || fail "Tailscale menu option is missing"
echo "$MENU_OUTPUT" | grep '5) 查看 UFW 状态及规则' >/dev/null || fail "UFW status menu option is missing"
echo "$MENU_OUTPUT" | grep '6) 安装 Docker' >/dev/null || fail "Docker menu option is missing"
echo "$MENU_OUTPUT" | grep '7) 安装 UFW' >/dev/null || fail "UFW menu option is missing"
echo "$MENU_OUTPUT" | grep '8) 配置 Tailscale 的 UFW 22 端口规则' >/dev/null || fail "Tailscale UFW rule option is missing"
echo "$MENU_OUTPUT" | grep '9) 管理公网 UFW 端口' >/dev/null || fail "UFW port management menu option is missing"
echo "$MENU_OUTPUT" | grep '10) 更新系统软件包' >/dev/null || fail "system update menu option is missing"
echo "$MENU_OUTPUT" | grep '11) 管理 SSH 安全' >/dev/null || fail "SSH security menu option is missing"
echo "$MENU_OUTPUT" | grep '0) 退出' >/dev/null || fail "exit menu option is missing"

SSH_MENU_OUTPUT="$(printf '11\n0\n\n0\n' | "$SCRIPT" 2>&1)"
echo "$SSH_MENU_OUTPUT" | grep 'SSH 安全管理' >/dev/null || fail "SSH security submenu is missing"
echo "$SSH_MENU_OUTPUT" | grep '1) 分析 SSH 暴力破解尝试' >/dev/null || fail "SSH analysis option is missing"
echo "$SSH_MENU_OUTPUT" | grep '2) 检查已授权的 SSH 密钥' >/dev/null || fail "SSH key inspection option is missing"
echo "$SSH_MENU_OUTPUT" | grep '3) 禁用 SSH 密码登录' >/dev/null || fail "SSH hardening option is missing"

grep '公网 UFW 端口管理' "$SCRIPT" >/dev/null || fail "UFW submenu title is missing"
grep 'SSH 失败时间范围' "$SCRIPT" >/dev/null || fail "SSH time-range menu is missing"
grep '最近 15 天' "$SCRIPT" >/dev/null || fail "SSH time-range option is missing"

grep 'detect_public_interface' "$SCRIPT" >/dev/null || fail "UFW branch must detect the public interface"
grep 'iproute2' "$SCRIPT" >/dev/null || fail "UFW branch must install iproute2 before interface detection"
grep '^install_ufw()' "$SCRIPT" >/dev/null || fail "UFW installation must be a separate operation"
grep '^configure_tailscale_ufw_ssh()' "$SCRIPT" >/dev/null || fail "Tailscale SSH rules must be a separate operation"
grep 'tailscale0' "$SCRIPT" >/dev/null || fail "UFW branch must allow SSH on tailscale0"
grep 'install_and_configure_ufw' "$SCRIPT" >/dev/null || fail "-u must preserve combined UFW setup"
if grep 'to any port 41641' "$SCRIPT" >/dev/null; then
  fail "Tailscale SSH rule setup must only manage port 22"
fi
grep 'ss -lntup' "$SCRIPT" >/dev/null || fail "port listing must use ss"
grep 'docker ps -a' "$SCRIPT" >/dev/null || fail "Docker status must list containers"
grep 'tailscale status' "$SCRIPT" >/dev/null || fail "Tailscale status view is missing"
grep 'ufw status numbered' "$SCRIPT" >/dev/null || fail "numbered UFW rules view is missing"
grep 'apt-get upgrade -y' "$SCRIPT" >/dev/null || fail "system update action is missing"
grep '_COMM=sshd' "$SCRIPT" >/dev/null || fail "SSH analysis must read the sshd journal"
grep 'sort -k1,1nr' "$SCRIPT" >/dev/null || fail "SSH analysis must rank sources by failure count"
grep 'ssh-keygen -lf' "$SCRIPT" >/dev/null || fail "SSH key inspection must validate fingerprints"
grep 'AuthenticationMethods publickey' "$SCRIPT" >/dev/null || fail "SSH hardening must require public-key authentication"
grep 'Type y to disable SSH password login for' "$SCRIPT" >/dev/null || fail "SSH hardening must require explicit confirmation"
grep '00-kun-key-only-\$SSH_TARGET_USER.conf' "$SCRIPT" >/dev/null || fail "SSH hardening must use a per-user early sshd drop-in"
grep 'Match User' "$SCRIPT" >/dev/null || fail "SSH hardening must be scoped to one system user"
grep 'getent passwd' "$SCRIPT" >/dev/null || fail "SSH management must select system users"
grep 'count_authorized_keys "\$SSH_AUTHORIZED_KEYS"' "$SCRIPT" >/dev/null || fail "SSH hardening must check the selected user's keys"
grep '"$SSHD_BIN" -t' "$SCRIPT" >/dev/null || fail "SSH hardening must validate sshd configuration"

if grep 'deny in on eth0' "$SCRIPT" >/dev/null; then
  fail "UFW branch must not hardcode eth0 for SSH deny rule"
fi

# Run the interactive firewall flow with command stubs; never touch host rules.
run_ufw_menu() (
  eval "$(sed '/^main "\$@"$/d' "$SCRIPT")"
  SUDO=""
  detect_public_interface() { echo "test0"; }
  ufw() { printf 'UFW_CALL: %s\n' "$*"; }
  manage_ufw_ports
)

for ACTION_CHOICE in 1 2 3 4; do
  case "$ACTION_CHOICE" in
    1) EXPECT_ACTION="allow"; EXPECT_PROTOCOL="tcp" ;;
    2) EXPECT_ACTION="allow"; EXPECT_PROTOCOL="udp" ;;
    3) EXPECT_ACTION="--force delete allow"; EXPECT_PROTOCOL="tcp" ;;
    4) EXPECT_ACTION="--force delete allow"; EXPECT_PROTOCOL="udp" ;;
  esac
  for IP_CHOICE in 1 2 3; do
    case "$IP_CHOICE" in
      1) EXPECT_SOURCE="0.0.0.0/0"; EXPECT_LABEL="IPv4" ;;
      2) EXPECT_SOURCE="::/0"; EXPECT_LABEL="IPv6" ;;
      3) EXPECT_SOURCE="any"; EXPECT_LABEL="all（IPv4 和 IPv6）" ;;
    esac
    UFW_OUTPUT="$(printf '%s\n' "$ACTION_CHOICE" "$IP_CHOICE" 8080 y 0 | run_ufw_menu 2>&1)"
    echo "$UFW_OUTPUT" | grep -F "UFW_CALL: $EXPECT_ACTION in on test0 proto $EXPECT_PROTOCOL from $EXPECT_SOURCE to any port 8080" >/dev/null ||
      fail "wrong firewall command for action $ACTION_CHOICE, IP version $IP_CHOICE"
    if [ "$ACTION_CHOICE" -ge 3 ]; then
      echo "$UFW_OUTPUT" | grep -F "确认关闭 test0 上的公网 $EXPECT_LABEL $EXPECT_PROTOCOL 端口 8080" >/dev/null ||
        fail "close confirmation must include the IP version"
    fi
  done
done

for UFW_INPUT in '1\n0\n0\n' '1\n9\n0\n' '1\n1\n0\n0\n' '1\n2\n65536\n0\n' '3\n3\n8080\nn\n0\n' '1\n'; do
  UFW_OUTPUT="$(printf '%b' "$UFW_INPUT" | run_ufw_menu 2>&1)"
  if echo "$UFW_OUTPUT" | grep -F 'UFW_CALL:' >/dev/null; then
    fail "cancelled or invalid input must not change firewall rules"
  fi
done

echo "All kun.sh checks passed."
