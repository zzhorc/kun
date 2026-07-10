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
echo "$MENU_OUTPUT" | grep 'KUN Server Manager' >/dev/null || fail "menu title is missing"
echo "$MENU_OUTPUT" | grep '1) Install Docker' >/dev/null || fail "Docker menu option is missing"
echo "$MENU_OUTPUT" | grep '2) Install UFW' >/dev/null || fail "UFW menu option is missing"
echo "$MENU_OUTPUT" | grep '3) List listening ports' >/dev/null || fail "port menu option is missing"
echo "$MENU_OUTPUT" | grep '4) View Docker service' >/dev/null || fail "Docker status menu option is missing"
echo "$MENU_OUTPUT" | grep '5) View server overview' >/dev/null || fail "server overview menu option is missing"
echo "$MENU_OUTPUT" | grep '6) View Tailscale status' >/dev/null || fail "Tailscale menu option is missing"
echo "$MENU_OUTPUT" | grep '7) Manage public UFW ports' >/dev/null || fail "UFW port management menu option is missing"
echo "$MENU_OUTPUT" | grep '8) Update system packages' >/dev/null || fail "system update menu option is missing"
echo "$MENU_OUTPUT" | grep '0) Exit' >/dev/null || fail "exit menu option is missing"

grep 'detect_public_interface' "$SCRIPT" >/dev/null || fail "UFW branch must detect the public interface"
grep 'iproute2' "$SCRIPT" >/dev/null || fail "UFW branch must install iproute2 before interface detection"
grep 'tailscale0' "$SCRIPT" >/dev/null || fail "UFW branch must allow SSH on tailscale0"
grep 'to any port 41641' "$SCRIPT" >/dev/null || fail "UFW branch must allow Tailscale UDP 41641"
grep 'Example UFW commands' "$SCRIPT" >/dev/null || fail "UFW branch must print example rule commands"
grep 'ufw allow in on $PUBLIC_INTERFACE' "$SCRIPT" >/dev/null || fail "examples must use detected public interface"
grep 'ss -lntup' "$SCRIPT" >/dev/null || fail "port listing must use ss"
grep 'docker ps -a' "$SCRIPT" >/dev/null || fail "Docker status must list containers"
grep 'tailscale status' "$SCRIPT" >/dev/null || fail "Tailscale status view is missing"
grep 'ufw status numbered' "$SCRIPT" >/dev/null || fail "numbered UFW rules view is missing"
grep 'apt-get upgrade -y' "$SCRIPT" >/dev/null || fail "system update action is missing"

if grep 'deny in on eth0' "$SCRIPT" >/dev/null; then
  fail "UFW branch must not hardcode eth0 for SSH deny rule"
fi

echo "All kun.sh checks passed."
