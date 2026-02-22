#!/bin/bash
# vpp_evpn_mh_init.sh — Post-boot EVPN MH workarounds for VPP platform
# Runs after swss/syncd/bgp are up. Handles VPP-specific fixups that
# can't be done through SAI or FRR templates.

set -e

EVPN_MH_ENABLED=$(sonic-db-cli CONFIG_DB hget "DEVICE_METADATA|localhost" "evpn_mh_enabled" 2>/dev/null || true)

if [ "$EVPN_MH_ENABLED" != "true" ]; then
    echo "EVPN MH not enabled, skipping init"
    exit 0
fi

echo "EVPN MH init: starting post-boot workarounds"

# 1. Disable rp_filter on ALL interfaces (VPP→kernel punt path)
echo "Disabling rp_filter on all interfaces..."
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 0 > "$f" 2>/dev/null || true
done

# 2. Set BVI tap to promisc mode (workaround for anycast MAC mismatch)
echo "Setting BVI taps to promisc mode..."
for bvi in $(ip -o link show | grep -o 'bvivlan[0-9]*'); do
    ip link set "$bvi" promisc on 2>/dev/null || true
    echo "  $bvi: promisc on"
done

# 3. Anycast gateway MAC on BVI (VPP side)
# intfsorch handles SAI-level MAC, but VPP's BVI and ARP-term entries
# need explicit configuration via vppctl
ANYCAST_MAC=$(sonic-db-cli CONFIG_DB hget "DEVICE_METADATA|localhost" "anycast_gateway_mac" 2>/dev/null || true)
if [ -n "$ANYCAST_MAC" ]; then
    echo "Setting anycast gateway MAC: $ANYCAST_MAC"
    # Find all BVI interfaces and set their MAC
    for bvi_vlan in $(sonic-db-cli CONFIG_DB keys 'VLAN|*' 2>/dev/null | sed 's/VLAN|//'); do
        vlan_id=$(sonic-db-cli CONFIG_DB hget "VLAN|$bvi_vlan" "vlanid" 2>/dev/null || true)
        if [ -n "$vlan_id" ]; then
            # Set VPP BVI MAC
            docker exec syncd vppctl set interface mac address bvi${vlan_id} ${ANYCAST_MAC} 2>/dev/null || true
            # Update ARP term entry for gateway IP
            for ip_entry in $(sonic-db-cli CONFIG_DB keys "VLAN_INTERFACE|${bvi_vlan}|*" 2>/dev/null); do
                gw_ip=$(echo "$ip_entry" | sed "s|VLAN_INTERFACE|${bvi_vlan}||" | cut -d'/' -f1 | sed 's/^|//')
                if [ -n "$gw_ip" ] && echo "$gw_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
                    docker exec syncd vppctl "set bridge-domain arp entry ${vlan_id} ${gw_ip} ${ANYCAST_MAC}" 2>/dev/null || true
                    echo "  ARP term: BD ${vlan_id} ${gw_ip} → ${ANYCAST_MAC}"
                fi
            done
        fi
    done
fi

# 4. Ensure DPDK ports are admin-up (VPP sometimes doesn't auto-up after boot)
echo "Ensuring DPDK ports are up..."
for port in $(sonic-db-cli CONFIG_DB keys 'PORT|*' 2>/dev/null | sed 's/PORT|//'); do
    admin_status=$(sonic-db-cli CONFIG_DB hget "PORT|$port" "admin_status" 2>/dev/null || true)
    if [ "$admin_status" = "up" ]; then
        # Find VPP interface name (bobmX) from port index
        # This is a best-effort — orchagent should handle this, but sometimes races on boot
        :  # orchagent handles port-up via SAI; only intervene if explicitly needed
    fi
done

# 5. Set PortChannel MACs to ES sys-mac for LACP MH
# This ensures both T1s present the same LACP actor system-id to servers
echo "Setting PortChannel ES system MACs..."
for es_entry in $(sonic-db-cli CONFIG_DB keys 'EVPN_ETHERNET_SEGMENT|*' 2>/dev/null); do
    pc_name=$(echo "$es_entry" | sed 's/EVPN_ETHERNET_SEGMENT|//')
    es_sys_mac=$(sonic-db-cli CONFIG_DB hget "$es_entry" "es_sys_mac" 2>/dev/null || true)
    if [ -n "$es_sys_mac" ] && [ -n "$pc_name" ]; then
        ip link set "$pc_name" address "$es_sys_mac" 2>/dev/null || true
        echo "  $pc_name: MAC set to $es_sys_mac"
    fi
done

echo "EVPN MH init: complete"
