#!/usr/bin/env sh
set -eu

PROGRAM_NAME="${KUN_PROGRAM_NAME:-kun.sh}"

print_usage() {
  cat <<EOF
Usage:
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

main() {
  RUN_DOCKER=0
  RUN_UFW=0

  if [ "$#" -eq 0 ]; then
    print_usage >&2
    exit 1
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
