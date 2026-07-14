#!/usr/bin/env sh
set -eu

PROGRAM_NAME="${KUN_PROGRAM_NAME:-kun.sh}"

print_usage() {
  cat <<EOF
Usage:
  $PROGRAM_NAME           Open the interactive menu
  $PROGRAM_NAME -d        Install Docker Engine and Docker Compose plugin
  $PROGRAM_NAME -u        Install and configure UFW
  $PROGRAM_NAME -d -u     Run Docker installation, then UFW configuration
  $PROGRAM_NAME -h        Show this help

Options:
  -d  Install Docker from the official Docker apt repository.
  -u  Install UFW, deny public SSH, allow SSH on tailscale0, and allow Tailscale UDP 41641.
  -h  Show help.
EOF
}

print_menu() {
  cat <<'EOF'

+--------------------------------------------------+
|                 KUN Server Manager               |
+--------------------------------------------------+
|  1) Install Docker Engine and Compose plugin     |
|  2) Install UFW and configure Tailscale rules    |
|  3) List listening ports                         |
|  4) View Docker service and containers           |
|  5) View server overview                          |
|  6) View Tailscale status                         |
|  7) Manage public UFW ports                       |
|  8) Update system packages                        |
|  9) Manage SSH security                           |
|--------------------------------------------------|
|  0) Exit                                         |
+--------------------------------------------------+
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

setup_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi
}

require_ubuntu() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required. This script is intended for Ubuntu."
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release."

  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "This script is intended for Ubuntu. Detected: ${ID:-unknown}"
}

ubuntu_codename() {
  . /etc/os-release
  CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [ -n "$CODENAME" ] || die "Cannot determine Ubuntu codename from /etc/os-release."
  echo "$CODENAME"
}

detect_public_interface() {
  command -v ip >/dev/null 2>&1 || die "ip command is required to detect the network interface."

  INTERFACE="$(ip route show default 0.0.0.0/0 | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }
  ')"

  if [ -z "$INTERFACE" ]; then
    INTERFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i == "dev") {
            print $(i + 1)
            exit
          }
        }
      }
    ')"
  fi

  [ -n "$INTERFACE" ] || die "Cannot detect default public network interface."
  echo "$INTERFACE"
}

install_docker() {
  require_ubuntu

  CODENAME="$(ubuntu_codename)"
  ARCHITECTURE="$(dpkg --print-architecture)"

  log "Removing old or conflicting container packages"
  $SUDO apt-get remove -y \
    docker.io \
    docker-compose \
    docker-compose-v2 \
    docker-doc \
    podman-docker \
    containerd \
    runc

  log "Installing Docker prerequisites"
  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl

  log "Adding Docker official apt repository"
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc

  $SUDO tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $CODENAME
Components: stable
Architectures: $ARCHITECTURE
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  log "Installing Docker Engine and Compose plugin"
  $SUDO apt-get update
  $SUDO apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  log "Starting and enabling Docker"
  $SUDO systemctl enable --now docker
  $SUDO systemctl --no-pager status docker

  log "Verifying Docker"
  $SUDO docker run hello-world

  log "Verifying Docker Compose plugin"
  docker compose version

  log "Docker installation completed"
}

configure_ufw() {
  require_ubuntu

  log "Installing UFW and network detection tools"
  $SUDO apt-get update
  $SUDO apt-get install -y ufw iproute2

  PUBLIC_INTERFACE="$(detect_public_interface)"

  log "Detected public network interface: $PUBLIC_INTERFACE"

  log "Setting default UFW policies"
  $SUDO ufw default deny incoming
  $SUDO ufw default allow outgoing

  log "Allowing SSH on tailscale0"
  $SUDO ufw allow in on tailscale0 proto tcp from 0.0.0.0/0 to any port 22

  log "Denying SSH on $PUBLIC_INTERFACE"
  $SUDO ufw deny in on "$PUBLIC_INTERFACE" proto tcp from 0.0.0.0/0 to any port 22

  log "Allowing Tailscale UDP 41641 on $PUBLIC_INTERFACE"
  $SUDO ufw allow in on "$PUBLIC_INTERFACE" proto udp from 0.0.0.0/0 to any port 41641

  log "Enabling UFW"
  $SUDO ufw --force enable

  log "UFW status"
  $SUDO ufw status verbose

  log "Example UFW commands"
  cat <<EOF
ufw allow in on $PUBLIC_INTERFACE proto tcp from 0.0.0.0/0 to any port 80
ufw allow in on $PUBLIC_INTERFACE proto tcp from 0.0.0.0/0 to any port 443
ufw allow in on $PUBLIC_INTERFACE proto udp from 0.0.0.0/0 to any port 41641
ufw allow in on tailscale0 proto tcp from 0.0.0.0/0 to any port 22
EOF

  log "UFW configuration completed"
}

list_listening_ports() {
  if ! command -v ss >/dev/null 2>&1; then
    echo "ss command is unavailable. Install iproute2 to enable this view." >&2
    return 0
  fi

  log "Listening TCP and UDP ports"
  $SUDO ss -lntup
}

show_docker_status() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker is not installed"
    return 0
  fi

  log "Docker service state"
  printf 'Active: '
  $SUDO systemctl is-active docker 2>/dev/null || true
  printf 'Enabled: '
  $SUDO systemctl is-enabled docker 2>/dev/null || true

  log "Docker version"
  $SUDO docker version --format '{{.Server.Version}}' 2>/dev/null || true

  log "Docker containers"
  $SUDO docker ps -a || echo "Docker daemon is unavailable." >&2
}

show_server_overview() {
  log "Server overview"
  printf 'Hostname: '
  hostname
  printf 'OS: '
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-unknown}"
  else
    echo "unknown"
  fi
  printf 'Kernel: '
  uname -r
  printf 'Uptime: '
  uptime -p 2>/dev/null || uptime
  printf 'CPU cores: '
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN
  printf 'IP addresses: '
  hostname -I 2>/dev/null || echo "unavailable"

  log "Root filesystem"
  df -h /

  if command -v free >/dev/null 2>&1; then
    log "Memory"
    free -h
  fi
}

show_tailscale_status() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log "Tailscale is not installed"
    return 0
  fi

  log "Tailscale status"
  $SUDO tailscale status || echo "Tailscale is not connected." >&2

  log "Tailscale IP addresses"
  $SUDO tailscale ip || echo "Tailscale IP addresses are unavailable." >&2
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

manage_ufw_ports() {
  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW is not installed. Run menu option 2 first." >&2
    return 0
  fi

  PUBLIC_INTERFACE="$(detect_public_interface)"

  while :; do
    cat <<EOF

+--------------------------------------------------+
|              Public UFW Port Management          |
+--------------------------------------------------+
| Interface: $PUBLIC_INTERFACE
|  1) Open one TCP port                            |
|  2) Open one UDP port                            |
|  3) Close one TCP port                           |
|  4) Close one UDP port                           |
|  5) Show numbered UFW rules                      |
|--------------------------------------------------|
|  0) Return to main menu                          |
+--------------------------------------------------+
EOF
    printf 'Select an option [0-5]: '
    IFS= read -r UFW_CHOICE || return 0

    case "$UFW_CHOICE" in
      0)
        return 0
        ;;
      1)
        UFW_ACTION="allow"
        UFW_PROTOCOL="tcp"
        ;;
      2)
        UFW_ACTION="allow"
        UFW_PROTOCOL="udp"
        ;;
      3)
        UFW_ACTION="delete allow"
        UFW_PROTOCOL="tcp"
        ;;
      4)
        UFW_ACTION="delete allow"
        UFW_PROTOCOL="udp"
        ;;
      5)
        $SUDO ufw status numbered
        printf '\nPress Enter to continue...'
        IFS= read -r _ || return 0
        continue
        ;;
      *)
        echo "Invalid option. Enter a number from 0 to 5." >&2
        continue
        ;;
    esac

    printf 'Port [1-65535]: '
    IFS= read -r PORT || return 0
    if ! validate_port "$PORT"; then
      echo "Invalid port: $PORT" >&2
      continue
    fi

    if [ "$UFW_ACTION" = "delete allow" ]; then
      printf 'Close public %s port %s on %s? [y/N]: ' "$UFW_PROTOCOL" "$PORT" "$PUBLIC_INTERFACE"
      IFS= read -r CONFIRM || return 0
      case "$CONFIRM" in
        y|Y|yes|YES)
          $SUDO ufw --force delete allow in on "$PUBLIC_INTERFACE" proto "$UFW_PROTOCOL" to any port "$PORT"
          ;;
        *)
          echo "No changes made."
          ;;
      esac
    else
      $SUDO ufw allow in on "$PUBLIC_INTERFACE" proto "$UFW_PROTOCOL" to any port "$PORT"
    fi
  done
}

update_system_packages() {
  require_ubuntu

  log "Updating package index"
  $SUDO apt-get update

  log "Upgrading installed packages"
  $SUDO apt-get upgrade -y

  log "System package update completed"
}

print_ssh_menu() {
  cat <<'EOF'

+--------------------------------------------------+
|                SSH Security Management           |
+--------------------------------------------------+
|  1) Analyze SSH brute-force attempts              |
|  2) Inspect authorized SSH keys                   |
|  3) Disable SSH password login                    |
|--------------------------------------------------|
|  0) Return to main menu                           |
+--------------------------------------------------+
EOF
}

analyze_ssh_brute_force() {
  if ! command -v journalctl >/dev/null 2>&1; then
    echo "journalctl is required to analyze SSH authentication failures." >&2
    return 0
  fi

  log "Login-capable system users"
  getent passwd | awk -F ':' '$7 !~ /(nologin|false)$/ {printf "%-20s %s\n", $1, $6}'
  printf '\nTarget SSH username, or all [all]: '
  IFS= read -r SSH_TARGET_USER || return 0
  SSH_TARGET_USER="${SSH_TARGET_USER:-all}"
  case "$SSH_TARGET_USER" in
    *[!A-Za-z0-9._-]*|'')
      echo "Invalid username: $SSH_TARGET_USER" >&2
      return 0
      ;;
  esac

  cat <<'EOF'

+--------------------------------------------------+
|              SSH Failure Time Range               |
+--------------------------------------------------+
|  1) Last 1 day                                    |
|  2) Last 7 days                                   |
|  3) Last 15 days                                  |
|--------------------------------------------------|
|  0) Return                                        |
+--------------------------------------------------+
EOF
  printf 'Select a time range [0-3]: '
  IFS= read -r RANGE_CHOICE || return 0

  case "$RANGE_CHOICE" in
    0) return 0 ;;
    1) DAYS=1 ;;
    2) DAYS=7 ;;
    3) DAYS=15 ;;
    *)
      echo "Invalid option. Enter a number from 0 to 3." >&2
      return 0
      ;;
  esac

  RAW_LOG="$(mktemp)" || die "Cannot create a temporary file."
  FAILURE_LOG="$(mktemp)" || {
    rm -f "$RAW_LOG"
    die "Cannot create a temporary file."
  }

  log "Top SSH authentication sources for '$SSH_TARGET_USER' in the last $DAYS day(s)"
  if ! $SUDO journalctl _COMM=sshd --since "$DAYS days ago" --no-pager -o short-iso >"$RAW_LOG" 2>/dev/null; then
    echo "Cannot read the SSH journal. Run this operation with sudo privileges." >&2
    rm -f "$RAW_LOG" "$FAILURE_LOG"
    return 0
  fi

  awk -v target="$SSH_TARGET_USER" '
    /Failed (password|publickey|keyboard-interactive) for / {
      ip = ""
      user = "unknown"
      for (i = 1; i <= NF; i++) {
        if ($i == "for") {
          if ($(i + 1) == "invalid" && $(i + 2) == "user") {
            user = $(i + 3)
          } else {
            user = $(i + 1)
          }
        }
        if ($i == "from") {
          ip = $(i + 1)
          break
        }
      }
      if (ip != "" && (target == "all" || user == target)) {
        gsub(/^\[|\]$/, "", ip)
        printf "%s\t%s\t%s\n", substr($1, 1, 19), ip, user
      }
    }
  ' "$RAW_LOG" >"$FAILURE_LOG"

  if [ ! -s "$FAILURE_LOG" ]; then
    echo "No failed SSH authentication attempts were found."
    rm -f "$RAW_LOG" "$FAILURE_LOG"
    return 0
  fi

  printf '%s\n' '+-----+-----------------------------------------+----------+----------------------+---------------------+---------------------+'
  printf '| %-3s | %-39s | %8s | %-20s | %-19s | %-19s |\n' "No." "IP address" "Attempts" "Users" "First seen" "Last seen"
  printf '%s\n' '+-----+-----------------------------------------+----------+----------------------+---------------------+---------------------+'
  awk -F '\t' '
    {
      key = $2
      count[key]++
      if (first[key] == "" || $1 < first[key]) first[key] = $1
      if (last[key] == "" || $1 > last[key]) last[key] = $1
      marker = SUBSEP key SUBSEP $3 SUBSEP
      if (!seen[marker]++) {
        if (users[key] == "") users[key] = $3
        else users[key] = users[key] "," $3
      }
    }
    END {
      for (key in count) {
        printf "%d\t%s\t%s\t%s\t%s\n", count[key], key, users[key], first[key], last[key]
      }
    }
  ' "$FAILURE_LOG" | sort -k1,1nr | awk -F '\t' 'NR <= 10 {
    printf "| %3d | %-39s | %8d | %-20s | %-19s | %-19s |\n", NR, substr($2, 1, 39), $1, substr($3, 1, 20), $4, $5
  }'
  printf '%s\n' '+-----+-----------------------------------------+----------+----------------------+---------------------+---------------------+'
  printf 'Total failed authentications: '
  wc -l <"$FAILURE_LOG" | tr -d ' '

  rm -f "$RAW_LOG" "$FAILURE_LOG"
}

select_existing_ssh_user() {
  log "Login-capable system users"
  getent passwd | awk -F ':' '$7 !~ /(nologin|false)$/ {printf "%-20s %s\n", $1, $6}'

  DEFAULT_SSH_USER="${SUDO_USER:-$(id -un)}"
  printf '\nSSH username [%s]: ' "$DEFAULT_SSH_USER"
  IFS= read -r SSH_TARGET_USER || return 1
  SSH_TARGET_USER="${SSH_TARGET_USER:-$DEFAULT_SSH_USER}"

  case "$SSH_TARGET_USER" in
    *[!A-Za-z0-9._-]*|'')
      echo "Invalid username: $SSH_TARGET_USER" >&2
      return 1
      ;;
  esac

  SSH_PASSWD_ENTRY="$(getent passwd "$SSH_TARGET_USER" 2>/dev/null || true)"
  if [ -z "$SSH_PASSWD_ENTRY" ]; then
    echo "System user does not exist: $SSH_TARGET_USER" >&2
    return 1
  fi

  SSH_USER_HOME="$(printf '%s\n' "$SSH_PASSWD_ENTRY" | cut -d ':' -f 6)"
  if [ -z "$SSH_USER_HOME" ]; then
    echo "Cannot determine the home directory for $SSH_TARGET_USER." >&2
    return 1
  fi

  SSH_AUTHORIZED_KEYS="$SSH_USER_HOME/.ssh/authorized_keys"
  return 0
}

count_authorized_keys() {
  AUTHORIZED_KEYS="$1"
  KEY_COUNT=0
  KEY_FILE="$(mktemp)" || die "Cannot create a temporary file."
  KEY_SOURCE="$(mktemp)" || {
    rm -f "$KEY_FILE"
    die "Cannot create a temporary file."
  }

  if $SUDO test -f "$AUTHORIZED_KEYS" && $SUDO cat "$AUTHORIZED_KEYS" >"$KEY_SOURCE" 2>/dev/null; then
    while IFS= read -r KEY_LINE || [ -n "$KEY_LINE" ]; do
      case "$KEY_LINE" in
        ''|'#'*) continue ;;
      esac
      printf '%s\n' "$KEY_LINE" >"$KEY_FILE"
      if ssh-keygen -lf "$KEY_FILE" -E sha256 >/dev/null 2>&1; then
        KEY_COUNT=$((KEY_COUNT + 1))
      fi
    done <"$KEY_SOURCE"
  fi

  rm -f "$KEY_FILE" "$KEY_SOURCE"
  printf '%s\n' "$KEY_COUNT"
}

inspect_authorized_keys() {
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ssh-keygen is required to inspect authorized keys." >&2
    return 0
  fi

  if ! select_existing_ssh_user; then
    return 0
  fi

  KEY_FILE="$(mktemp)" || die "Cannot create a temporary file."
  KEY_SOURCE="$(mktemp)" || {
    rm -f "$KEY_FILE"
    die "Cannot create a temporary file."
  }
  KEY_COUNT=0

  log "Authorized SSH login keys for '$SSH_TARGET_USER'"
  printf '%s\n' '+----------------+------+------------+-----------------------------------------------+------------------------+----------------------------------+'
  printf '| %-14s | %4s | %-10s | %-45s | %-22s | %-32s |\n' "User" "Bits" "Type" "SHA256 fingerprint" "Comment" "File:line"
  printf '%s\n' '+----------------+------+------------+-----------------------------------------------+------------------------+----------------------------------+'

  AUTHORIZED_KEYS="$SSH_AUTHORIZED_KEYS"
  if $SUDO test -f "$AUTHORIZED_KEYS" && $SUDO cat "$AUTHORIZED_KEYS" >"$KEY_SOURCE" 2>/dev/null; then
    KEY_USER="$SSH_TARGET_USER"
    LINE_NUMBER=0
    while IFS= read -r KEY_LINE || [ -n "$KEY_LINE" ]; do
      LINE_NUMBER=$((LINE_NUMBER + 1))
      case "$KEY_LINE" in
        ''|'#'*) continue ;;
      esac

      printf '%s\n' "$KEY_LINE" >"$KEY_FILE"
      KEY_INFO="$(ssh-keygen -lf "$KEY_FILE" -E sha256 2>/dev/null || true)"
      [ -n "$KEY_INFO" ] || continue

      BITS="$(printf '%s\n' "$KEY_INFO" | awk '{print $1}')"
      FINGERPRINT="$(printf '%s\n' "$KEY_INFO" | awk '{print $2}')"
      KEY_TYPE="$(printf '%s\n' "$KEY_INFO" | awk '{value=$NF; gsub(/^\(|\)$/, "", value); print value}')"
      KEY_COMMENT="$(printf '%s\n' "$KEY_INFO" | awk '{for (i=3; i<NF; i++) printf "%s%s", (i==3 ? "" : " "), $i; print ""}')"
      KEY_LOCATION="$AUTHORIZED_KEYS:$LINE_NUMBER"

      printf '| %-14s | %4s | %-10s | %-45s | %-22s | %-32s |\n' \
        "$(printf '%.14s' "$KEY_USER")" "$BITS" "$(printf '%.10s' "$KEY_TYPE")" \
        "$(printf '%.45s' "$FINGERPRINT")" "$(printf '%.22s' "$KEY_COMMENT")" "$(printf '%.32s' "$KEY_LOCATION")"
      KEY_COUNT=$((KEY_COUNT + 1))
    done <"$KEY_SOURCE"
  fi

  printf '%s\n' '+----------------+------+------------+-----------------------------------------------+------------------------+----------------------------------+'
  if [ "$KEY_COUNT" -eq 0 ]; then
    echo "No valid keys were found in $SSH_AUTHORIZED_KEYS."
  else
    echo "Valid authorized keys: $KEY_COUNT"
  fi

  rm -f "$KEY_FILE" "$KEY_SOURCE"
}

disable_ssh_password_login() {
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ssh-keygen is required before password login can be disabled." >&2
    return 0
  fi

  SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
  [ -n "$SSHD_BIN" ] || SSHD_BIN="/usr/sbin/sshd"
  if [ ! -x "$SSHD_BIN" ]; then
    echo "sshd is not installed or cannot be found." >&2
    return 0
  fi

  if ! select_existing_ssh_user; then
    return 0
  fi

  AUTHORIZED_KEY_COUNT="$(count_authorized_keys "$SSH_AUTHORIZED_KEYS")"
  if [ "$AUTHORIZED_KEY_COUNT" -eq 0 ]; then
    echo "Refusing to disable password login for '$SSH_TARGET_USER': no valid authorized SSH key was found." >&2
    echo "Add and test a key in $SSH_AUTHORIZED_KEYS first." >&2
    return 0
  fi

  cat <<EOF

This will require public-key authentication for SSH user: $SSH_TARGET_USER
Detected valid authorized keys for this user: $AUTHORIZED_KEY_COUNT

Keep this SSH session open and test a second key-based session after the change.
EOF
  printf "Type y to disable SSH password login for '%s' [y/N]: " "$SSH_TARGET_USER"
  IFS= read -r CONFIRM || return 0
  case "$CONFIRM" in
    y|Y) ;;
    *)
      echo "No changes made."
      return 0
      ;;
  esac

  DROPIN_DIR="/etc/ssh/sshd_config.d"
  DROPIN_FILE="$DROPIN_DIR/00-kun-key-only-$SSH_TARGET_USER.conf"
  CANDIDATE="$(mktemp)" || die "Cannot create a temporary file."
  BACKUP_FILE=""

  tee "$CANDIDATE" >/dev/null <<EOF
# Managed by kun.sh. Public-key authentication is required for this SSH user.
Match User $SSH_TARGET_USER
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
Match all
EOF

  $SUDO install -d -m 0755 "$DROPIN_DIR"
  if $SUDO test -f "$DROPIN_FILE"; then
    BACKUP_FILE="$DROPIN_FILE.kun-backup.$(date +%Y%m%d%H%M%S)"
    $SUDO cp -p "$DROPIN_FILE" "$BACKUP_FILE"
  fi
  $SUDO install -m 0644 "$CANDIDATE" "$DROPIN_FILE"
  rm -f "$CANDIDATE"

  if ! $SUDO "$SSHD_BIN" -t; then
    echo "The new SSH configuration is invalid; restoring the previous configuration." >&2
    if [ -n "$BACKUP_FILE" ]; then
      $SUDO cp -p "$BACKUP_FILE" "$DROPIN_FILE"
    else
      $SUDO rm -f "$DROPIN_FILE"
    fi
    return 0
  fi

  EFFECTIVE_CONFIG="$($SUDO "$SSHD_BIN" -T -C "user=$SSH_TARGET_USER,host=$(hostname),addr=127.0.0.1" 2>/dev/null || true)"
  if ! printf '%s\n' "$EFFECTIVE_CONFIG" | grep -q '^passwordauthentication no$' ||
     ! printf '%s\n' "$EFFECTIVE_CONFIG" | grep -q '^kbdinteractiveauthentication no$' ||
     ! printf '%s\n' "$EFFECTIVE_CONFIG" | grep -q '^pubkeyauthentication yes$' ||
     ! printf '%s\n' "$EFFECTIVE_CONFIG" | grep -q '^authenticationmethods publickey$'; then
    echo "The effective SSH settings are not key-only; restoring the previous configuration." >&2
    if [ -n "$BACKUP_FILE" ]; then
      $SUDO cp -p "$BACKUP_FILE" "$DROPIN_FILE"
    else
      $SUDO rm -f "$DROPIN_FILE"
    fi
    return 0
  fi

  if $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null; then
    log "SSH password login disabled successfully for '$SSH_TARGET_USER'"
    echo "Configuration: $DROPIN_FILE"
    [ -z "$BACKUP_FILE" ] || echo "Previous configuration backup: $BACKUP_FILE"
    echo "Test a new SSH connection with your key before closing this session."
  else
    echo "SSH reload failed; restoring the previous configuration." >&2
    if [ -n "$BACKUP_FILE" ]; then
      $SUDO cp -p "$BACKUP_FILE" "$DROPIN_FILE"
    else
      $SUDO rm -f "$DROPIN_FILE"
    fi
    $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null || true
  fi
}

manage_ssh_security() {
  while :; do
    print_ssh_menu
    printf 'Select an option [0-3]: '
    IFS= read -r SSH_CHOICE || return 0

    case "$SSH_CHOICE" in
      0) return 0 ;;
      1)
        setup_sudo
        analyze_ssh_brute_force
        ;;
      2)
        setup_sudo
        inspect_authorized_keys
        ;;
      3)
        setup_sudo
        disable_ssh_password_login
        ;;
      *)
        echo "Invalid option. Enter a number from 0 to 3." >&2
        continue
        ;;
    esac

    printf '\nPress Enter to return to SSH management...'
    IFS= read -r _ || return 0
  done
}

run_interactive_menu() {
  while :; do
    print_menu
    printf 'Select an option [0-9]: '
    IFS= read -r CHOICE || {
      printf '\n'
      return 0
    }

    case "$CHOICE" in
      0)
        log "Goodbye"
        return 0
        ;;
      1)
        setup_sudo
        install_docker
        ;;
      2)
        setup_sudo
        configure_ufw
        ;;
      3)
        setup_sudo
        list_listening_ports
        ;;
      4)
        setup_sudo
        show_docker_status
        ;;
      5)
        show_server_overview
        ;;
      6)
        setup_sudo
        show_tailscale_status
        ;;
      7)
        setup_sudo
        manage_ufw_ports
        ;;
      8)
        setup_sudo
        update_system_packages
        ;;
      9)
        manage_ssh_security
        ;;
      *)
        echo "Invalid option. Enter a number from 0 to 9." >&2
        ;;
    esac

    printf '\nPress Enter to return to the menu...'
    IFS= read -r _ || return 0
  done
}

main() {
  RUN_DOCKER=0
  RUN_UFW=0

  if [ "$#" -eq 0 ]; then
    run_interactive_menu
    exit 0
  fi

  while getopts ":duh" OPT; do
    case "$OPT" in
      d)
        RUN_DOCKER=1
        ;;
      u)
        RUN_UFW=1
        ;;
      h)
        print_usage
        exit 0
        ;;
      \?)
        print_usage >&2
        die "Unknown option: -$OPTARG"
        ;;
    esac
  done

  if [ "$OPTIND" -le "$#" ]; then
    print_usage >&2
    die "Unexpected argument: $(eval "printf '%s' \"\${$OPTIND}\"")"
  fi

  if [ "$RUN_DOCKER" -eq 0 ] && [ "$RUN_UFW" -eq 0 ]; then
    print_usage >&2
    exit 1
  fi

  setup_sudo

  if [ "$RUN_DOCKER" -eq 1 ]; then
    install_docker
  fi

  if [ "$RUN_UFW" -eq 1 ]; then
    configure_ufw
  fi
}

main "$@"
