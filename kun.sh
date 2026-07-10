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

run_interactive_menu() {
  while :; do
    print_menu
    printf 'Select an option [0-8]: '
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
      *)
        echo "Invalid option. Enter a number from 0 to 8." >&2
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
