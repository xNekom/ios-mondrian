#!/bin/sh
# Host side of the phone's USB Ethernet (kernel sweetusb=2, patches 0075-0077).
#   tools/ios-usbnet.sh [LOGFILE]
# Waits for the phone's CDC-ECM interface (host MAC 02:00:5e:77:ee:01),
# gives it 192.168.7.1/24 (the phone is 192.168.7.2), NATs that subnet through
# the host's uplink so the phone has Internet, then prints the live kernel
# console the phone streams to UDP port 5140 (and appends it to LOGFILE if
# given). Needs sudo for the address and the firewall.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	echo "Usage: $(basename "$0") [LOGFILE]"
	echo "Wait for the phone's USB Ethernet interface and stream the live kernel UDP console."
	exit 0
fi

mac=02:00:5e:77:ee:01
echo "waiting for the phone's USB Ethernet ($mac)..." >&2
until ip -o link | grep -qi "$mac"; do sleep 1; done
ifname=$(ip -o link | grep -i "$mac" | awk -F': ' '{print $2}' | cut -d@ -f1)
nmcli dev set "$ifname" managed no 2>/dev/null || true
sudo ip addr replace 192.168.7.1/24 dev "$ifname"
sudo ip link set "$ifname" up
echo "$ifname up: 192.168.7.1 <-> phone 192.168.7.2; live log on udp/5140" >&2

# NAT, so the phone has a network: its hook adds the default route to
# 192.168.7.1 (mondrian-ui-hook.m, "mondrian_net") and this masquerades that
# subnet through the host's default route. Without it the cable is a debug link
# with no Internet, which matters on a boot with no WiFi and no modem.
uplink=$(ip route show default | awk 'NR == 1 { print $5 }')
if [ -n "$uplink" ] && [ "$uplink" != "$ifname" ]; then
	sudo sysctl -q -w net.ipv4.ip_forward=1
	sudo iptables -t nat -C POSTROUTING -s 192.168.7.0/24 -o "$uplink" \
	    -j MASQUERADE 2>/dev/null ||
		sudo iptables -t nat -A POSTROUTING -s 192.168.7.0/24 \
		    -o "$uplink" -j MASQUERADE
	sudo iptables -C FORWARD -i "$ifname" -o "$uplink" -j ACCEPT 2>/dev/null ||
		sudo iptables -A FORWARD -i "$ifname" -o "$uplink" -j ACCEPT
	sudo iptables -C FORWARD -i "$uplink" -o "$ifname" -m conntrack \
	    --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
		sudo iptables -A FORWARD -i "$uplink" -o "$ifname" -m conntrack \
		    --ctstate RELATED,ESTABLISHED -j ACCEPT
	echo "NAT: 192.168.7.0/24 -> $uplink" >&2
fi

listen_udp() {
	port=5140
	if command -v socat >/dev/null 2>&1; then
		socat -u "udp-recv:$port,reuseaddr" -
	elif command -v ncat >/dev/null 2>&1; then
		ncat -l -u -k "$port"
	elif nc -h 2>&1 | grep -q -- '-k'; then
		nc -ukl "$port"
	else
		while true; do
			nc -u -l -p "$port" 2>/dev/null || nc -u -l "$port" 2>/dev/null || break
		done
	fi
}

if [ $# -ge 1 ]; then
	listen_udp | tee -a "$1"
else
	listen_udp
fi
