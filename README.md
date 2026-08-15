# kun

Ubuntu server bootstrap utility for installing Docker and configuring a conservative UFW firewall policy for SSH through Tailscale.

## Quick start

Run the current version directly from GitHub:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/zzhorc/kun/main/kun.sh)
```

The command downloads the script and opens the interactive menu. Choose the required operation by number. Review the script before running it on a production server.

## Usage

Run locally:

```sh
./kun.sh          # Open the interactive menu
./kun.sh -d       # Install Docker Engine and the Docker Compose plugin
./kun.sh -u       # Install UFW and configure SSH through Tailscale
./kun.sh -d -u    # Run both operations
./kun.sh -h       # Show help
```

For non-interactive automation, run a specific operation directly from GitHub:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/zzhorc/kun/main/kun.sh) -d
bash <(curl -fsSL https://raw.githubusercontent.com/zzhorc/kun/main/kun.sh) -u
```

### Interactive menu

Running `./kun.sh` without options opens a numeric menu. It includes Docker installation, separate UFW installation and Tailscale SSH-rule configuration, listening-port and Docker views, server and Tailscale status, public UFW port management, Ubuntu package updates, and SSH security management. Enter `0` to exit; after every operation, press Enter to return to the menu.

The UFW port-management submenu applies a single TCP or UDP rule to the detected public interface. Closing a port requires explicit confirmation. System updates run `apt-get update` followed by `apt-get upgrade -y`; they do not remove packages or reboot the server.

The SSH security submenu is user-aware. Its analysis can rank the top 10 source IPs for all usernames or one target username during the last 1, 7, or 15 days. Key inspection selects one existing system user and lists valid entries from that user's `authorized_keys` file with SHA256 fingerprints. Key-only authentication is also applied to one selected user: it refuses to run unless that user has a valid authorized key, requires an explicit `y`, validates the effective sshd configuration for that user, and reloads SSH only after validation succeeds. Other SSH users are not changed.

## What it changes

- Docker: uses Docker's official Ubuntu apt repository and installs Docker Engine, Buildx, and the Compose plugin.
- UFW: installation and rule configuration are separate menu steps. The rule step denies inbound traffic by default, permits outbound traffic, permits SSH through `tailscale0`, and blocks public SSH on the detected default network interface.

The UFW operation detects the default public interface at runtime. It is intended for Ubuntu hosts and requires `sudo` when not run as root.

## Verify the script

```sh
./test_kun.sh
```
