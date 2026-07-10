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

if "$SCRIPT" >/tmp/kun-test-no-args.out 2>&1; then
  fail "script without arguments should fail"
fi
grep 'Usage:' /tmp/kun-test-no-args.out >/dev/null || fail "no-args output misses Usage"

grep 'detect_public_interface' "$SCRIPT" >/dev/null || fail "UFW branch must detect the public interface"
grep 'iproute2' "$SCRIPT" >/dev/null || fail "UFW branch must install iproute2 before interface detection"
grep 'tailscale0' "$SCRIPT" >/dev/null || fail "UFW branch must allow SSH on tailscale0"
grep 'to any port 41641' "$SCRIPT" >/dev/null || fail "UFW branch must allow Tailscale UDP 41641"
grep 'Example UFW commands' "$SCRIPT" >/dev/null || fail "UFW branch must print example rule commands"
grep 'ufw allow in on $PUBLIC_INTERFACE' "$SCRIPT" >/dev/null || fail "examples must use detected public interface"

if grep 'deny in on eth0' "$SCRIPT" >/dev/null; then
  fail "UFW branch must not hardcode eth0 for SSH deny rule"
fi

echo "All kun.sh checks passed."
