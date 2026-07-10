# kun

Ubuntu server bootstrap utility for installing Docker and configuring a conservative UFW firewall policy for public and Tailscale access.

## Quick start

Run the current version directly from GitHub:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/zzhorc/kun/main/kun.sh) -d -u
```

The command downloads the script, installs Docker, then configures UFW. Review the script before running it on a production server.

## Usage

Run locally:

```sh
./kun.sh          # Open the interactive menu
./kun.sh -d       # Install Docker Engine and the Docker Compose plugin
./kun.sh -u       # Configure UFW for public and Tailscale access
./kun.sh -d -u    # Run both operations
./kun.sh -h       # Show help
```

Run a single operation directly from GitHub:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/zzhorc/kun/main/kun.sh) -d
bash <(curl -fsSL https://raw.githubusercontent.com/zzhorc/kun/main/kun.sh) -u
```

### Interactive menu

Running `./kun.sh` without options opens a numeric menu. It includes Docker installation, UFW/Tailscale firewall configuration, listening-port and Docker views, server and Tailscale status, public UFW port management, and Ubuntu package updates. Enter `0` to exit; after every operation, press Enter to return to the menu.

The UFW port-management submenu applies a single TCP or UDP rule to the detected public interface. Closing a port requires explicit confirmation. System updates run `apt-get update` followed by `apt-get upgrade -y`; they do not remove packages or reboot the server.

## What it changes

- Docker: uses Docker's official Ubuntu apt repository and installs Docker Engine, Buildx, and the Compose plugin.
- UFW: denies inbound traffic by default, permits outbound traffic, permits SSH only through `tailscale0`, blocks public SSH on the detected default network interface, and allows Tailscale UDP port `41641` on that interface.

The UFW operation detects the default public interface at runtime. It is intended for Ubuntu hosts and requires `sudo` when not run as root.

## Verify the script

```sh
./test_kun.sh
```
