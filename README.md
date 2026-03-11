# port-not-responding

> Bash diagnostic script for Linux VMs where a container port isn't responding.  
> Auto-detects Docker/Podman (rootful & rootless), adapts to Ubuntu/Debian/RedHat/Photon,  
> checks firewall, iptables, conntrack, TCP handshake (SYN/SYN-ACK), rp_filter, backlog  
> and captures live traffic with tcpdump.

---

## The problem this solves

You have a VM running a container with a port mapped to the host (`-p 8080:80`).  
The container is up. The port should be open. And yet — nothing responds.

Before spending an hour grepping through logs, run this script. It collects everything relevant in one shot, prints a colour-coded summary of what's wrong, and writes a clean, ANSI-free log file ready to paste into an LLM or share with a colleague.

---

## Usage

```bash
sudo bash port-not-responding.sh [PORT] [CONTAINER]
```

| Argument    | Description                                    | Default       |
|-------------|------------------------------------------------|---------------|
| `PORT`      | Host port to test                              | `8000`        |
| `CONTAINER` | Container name or ID (auto-detected if omitted)| auto-detect   |

**Options**

| Flag          | Description                          |
|---------------|--------------------------------------|
| `--no-color`  | Disable ANSI colors (useful in CI)   |

**Examples**

```bash
# Test port 8080, auto-detect container
sudo bash port-not-responding.sh 8080

# Test port 443 on a specific container
sudo bash port-not-responding.sh 443 my-nginx

# Run in CI without color output
sudo bash port-not-responding.sh 8080 --no-color
```

**Output**

- **stdout** — colour-coded summary with detected issues and suggested actions  
- `port-not-responding_<timestamp>.log` — full extended log, ANSI-free, grep/LLM-ready

---

## What it checks

### Engine (auto-detected)

| Engine | Supported modes |
|--------|-----------------|
| Docker | rootful, `docker-proxy`, `docker0` bridge |
| Podman | rootful, rootless, Netavark, CNI, `pasta`, `slirp4netns` |

### Distro (auto-detected)

| Family | Distros | Firewall checked |
|--------|---------|------------------|
| Debian | Ubuntu, Debian, Pop!_OS, Mint | `ufw` |
| RedHat | RHEL, CentOS, Rocky, AlmaLinux, Fedora | `firewalld`, SELinux |
| Photon | VMware Photon OS | `firewalld` |
| Generic | Any other Linux | `iptables` / `nftables` |

### Checks performed

| # | Area | What is verified |
|---|------|-----------------|
| 1 | System | OS, kernel, uptime, memory, disk |
| 2 | Engine | daemon status, version, rootless specifics, user namespaces |
| 3 | Container | running state, crash loop, port mapping, inspect, logs |
| 4 | Networking | listening socket, bind address, `docker-proxy` / `pasta` / `slirp4netns` |
| 5 | Firewall | `ufw`, `firewalld`, SELinux, `iptables`, `ip6tables`, `nftables` |
| 6 | Daemon config | `daemon.json`, `containers.conf`, ip_forward, bridge-nf-call-iptables, Netavark/CNI |
| 7 | Connectivity | `curl` and `nc` against localhost |
| 8 | TCP handshake | `conntrack` table usage, SYN backlog, `somaxconn`, `tcp_syncookies`, `rp_filter`, live `tcpdump` |
| 9 | Logs | `journalctl`, `dmesg`, syslog / messages, SELinux audit log |
| 10 | Cloud | Security Group reminder, AWS/GCP/Azure instance metadata |

---

## Requirements

| Tool | Required | Notes |
|------|----------|-------|
| `bash` | ✅ >= 4.0 | |
| `ss` | ✅ | Part of `iproute2` |
| `ip` | ✅ | Part of `iproute2` |
| `iptables` | ✅ | |
| `docker` or `podman` | ✅ | At least one must be present |
| `curl` | ⚠️ recommended | Used for localhost connectivity test |
| `nc` | ⚠️ recommended | Used for port reachability test |
| `tcpdump` | ⚠️ recommended | Used for live SYN/SYN-ACK capture |
| `conntrack` | ⚠️ recommended | Used for conntrack table analysis |
| `nft` | optional | Used if nftables is active |

The script runs without the optional tools — it logs a warning and skips those checks.

---

## Common causes detected

**Generic**
1. Container not started or in crash loop
2. Missing or incorrect port binding (`-p host:container`)
3. Process inside container listening on `127.0.0.1` only
4. IP forwarding disabled (`net.ipv4.ip_forward=0`)
5. `ufw` active without a rule for the port *(Debian/Ubuntu)*
6. `firewalld` active without a rule for the port *(RedHat/Photon)*
7. SELinux in Enforcing mode blocking traffic *(RedHat)*
8. `iptables` DROP/REJECT rule overriding container rules
9. Cloud Security Group not opening the port externally
10. Port conflict — another process is using the same port
11. OOM killer terminated the container

**Docker-specific**
12. `docker-proxy` bound to `127.0.0.1` instead of `0.0.0.0`
13. `iptables: false` in `daemon.json` — Docker not managing NAT rules
14. `docker0` bridge missing or in DOWN state

**Podman-specific**
15. Port < `ip_unprivileged_port_start` in rootless mode
16. User namespaces disabled (`max_user_namespaces=0`)
17. `pasta` / `slirp4netns` not running *(rootless)*
18. No `iptables`/`nftables` NAT rule *(rootful)*
19. Corrupted or misconfigured CNI/Netavark network
20. `podman0` / `cni0` bridge missing or in DOWN state

**TCP handshake — SYN arrives but no SYN-ACK is sent**
21. `conntrack` table full (`nf_conntrack_max` reached)
22. `tcp_syncookies=0` under SYN flood
23. `tcp_max_syn_backlog` or `somaxconn` too low
24. `rp_filter=1` strict mode on interface with asymmetric routing
25. `Recv-Q > 0` — application slow to accept connections

---

## Code quality

- **ShellCheck clean** — zero warnings or errors (`shellcheck -S warning`)
- **ANSI-free log** — colors on stdout, plain text on file
- `--no-color` flag for CI/CD pipelines and non-interactive shells
- No system modifications — the script is purely read-only

---

## License

MIT
