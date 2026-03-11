# port-not-resonding.sh
Bash diagnostic script for Linux VMs where a container port isn't responding. Auto-detects Docker/Podman (rootful &amp; rootless), adapts to Ubuntu/Debian/RedHat/Photon, checks firewall, iptables, conntrack, TCP handshake (SYN/SYN-ACK), rp_filter, backlog and captures live traffic with tcpdump
