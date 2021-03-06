#!/bin/bash
# Copyright (C) 2020 Private Internet Access, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This function allows you to check if the required tools have been installed.
function check_tool() {
  cmd=$1
  if ! command -v $cmd &>/dev/null
  then
    echo "$cmd could not be found"
    echo "Please install $cmd"
    exit 1
  fi
}
# Now we call the function to make sure we can use wg-quick, curl and jq.
check_tool wg-quick
check_tool curl
check_tool jq

# Check if terminal allows output, if yes, define colors for output
if test -t 1; then
  ncolors=$(tput colors)
  if test -n "$ncolors" && test $ncolors -ge 8; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    NC='\033[0m' # No Color
  else
    GREEN=''
    RED=''
    NC='' # No Color
  fi
fi

# PIA currently does not support IPv6. In order to be sure your VPN
# connection does not leak, it is best to disabled IPv6 altogether.
# IPv6 can also be disabled via kernel commandline param, so we must
# first check if this is the case.
if [[ -f /proc/net/if_inet6 ]] &&
  [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) -ne 1 ||
     $(sysctl -n net.ipv6.conf.default.disable_ipv6) -ne 1 ]]
then
  echo 'You should consider disabling IPv6 by running:'
  echo 'sysctl -w net.ipv6.conf.all.disable_ipv6=1'
  echo 'sysctl -w net.ipv6.conf.default.disable_ipv6=1'
fi

# Check if the mandatory environment variables are set.
if [[ ! $WG_SERVER_IP || ! $WG_HOSTNAME || ! $PIA_TOKEN ]]; then
  echo -e ${RED}This script requires 3 env vars:
  echo WG_SERVER_IP - IP that you want to connect to
  echo WG_HOSTNAME  - name of the server, required for ssl
  echo PIA_TOKEN    - your authentication token
  echo
  echo You can also specify optional env vars:
  echo "PIA_PF                - enable port forwarding"
  echo "PAYLOAD_AND_SIGNATURE - In case you already have a port."
  echo
  echo An easy solution is to just run get_region_and_token.sh
  echo as it will guide you through getting the best server and
  echo also a token. Detailed information can be found here:
  echo -e https://github.com/pia-foss/manual-connections${NC}
  exit 1
fi

# Create ephemeral wireguard keys, that we don't need to save to disk.
newPrivateKey="$(wg genkey)"
export newPrivateKey
pubKey="$( echo "$newPrivateKey" | wg pubkey)"
export pubKey

# Authenticate via the PIA WireGuard RESTful API.
# This will return a JSON with data required for authentication.
# The certificate is required to verify the identity of the VPN server.
# In case you didn't clone the entire repo, get the certificate from:
# https://github.com/pia-foss/manual-connections/blob/master/ca.rsa.4096.crt
# In case you want to troubleshoot the script, replace -s with -v.
echo Trying to connect to the PIA WireGuard API on $WG_SERVER_IP...
wireguard_json="$(curl -s -G \
  --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
  --cacert "ca.rsa.4096.crt" \
  --data-urlencode "pt=${PIA_TOKEN}" \
  --data-urlencode "pubkey=$pubKey" \
  "https://${WG_HOSTNAME}:1337/addKey" )"
export wireguard_json

# Check if the API returned OK and stop this script if it didn't.
if [ "$(echo "$wireguard_json" | jq -r '.status')" != "OK" ]; then
  >&2 echo -e "${RED}Server did not return OK. Stopping now.${NC}"
  exit 1
fi

# Multi-hop is out of the scope of this repo, but you should be able to
# get multi-hop running with both WireGuard and OpenVPN by playing with
# these scripts. Feel free to fork the project and test it out.
echo
echo Trying to disable a PIA WG connection in case it exists...
wg-quick down pia && echo -e "${GREEN}\nPIA WG connection disabled!${NC}"
echo

# Create the WireGuard config based on the JSON received from the API
# In case you want this section to also add the DNS setting, please
# start the script with PIA_DNS=true.
# This uses a PersistentKeepalive of 25 seconds to keep the NAT active
# on firewalls. You can remove that line if your network does not
# require it.
if [ "$PIA_DNS" == true ]; then
  newDNS="$(echo "$wireguard_json" | jq -r '.dns_servers[0]')"
  echo Trying to set up DNS to $newDNS. In case you do not have resolvconf,
  echo this operation will fail and you will not get a VPN. If you have issues,
  echo start this script without PIA_DNS.
  echo
  dnsSettingForVPN="DNS = $newDNS"
fi
declare confDir=/etc/wireguard
mkdir -p "$confDir" || exit 1
declare confFile="$confDir/pia.conf"
echo -n "Trying to write $confFile..."
if [[ -f "$confFile" ]]; then
	declare -a newFile=()
	## keyKeeper=
	## linebuf=
	newAddress="$(jq -r '.peer_ip' <<< "$wireguard_json")"
	## newPrivateKey
	newPublicKey="$(jq -r '.server_key' <<< "$wireguard_json")"
	newEndPoint="${WG_SERVER_IP}:$(jq -r '.server_port' <<< "$wireguard_json")"
	## newDNS

	declare -a new=(newAddress newPrivateKey newPublicKey newEndPoint newDNS)
	declare -A match=(
		[newAddress]='^[[:space:]]*[Aa]ddress[[:space:]]*$'
		[newPrivateKey]='^[[:space:]]*[Pp]rivate[Kk]ey[[:space:]]*$'
		[newPublicKey]='^[[:space:]]*[Pp]ublic[Kk]ey[[:space:]]*$'
		[newEndPoint]='^[[:space:]]*[Ee]nd[Pp]oint[[:space:]]*$'
		[newDNS]='^[[:space:]]*[Dd][Nn][Ss][[:space:]]*$'
	)
	declare -A before=(
		[newAddress]='^[[:space:]]*\[Interface\]'
		[newPrivateKey]="${match[newAddress]%$}="
		[newPublicKey]='^[[:space:]]*\[Peer\]'
		[newEndPoint]="${match[newPublicKey]%$}="
		[newDNS]="${match[newPrivateKey]%$}="
	)

	while read -r line; do
		if [[ "$line" = *=* ]]; then
			keyKeeper="${line%%=*}"
			## Note: this only preserves the first instance of each key entry in the config file.
			for update in "${!match[@]}"; do
				if [[ ${!update} && $keyKeeper =~ ${match[$update]} ]]; then
					spaceSaver="${line#*=}" && spaceSaver="${spaceSaver/[^[:space:]]*/}"
					newFile+=("${keyKeeper}=${spaceSaver}${!update}")
					unset "$update"
					line=
					break
				fi
			done
			if [[ $line ]]; then
				newFile+=("$line")
			fi
		else newFile+=("$line")
		fi
	done < "$confFile"

	for still in "${new[@]}"; do
		if [[ "${!still}" ]]; then
			linebuf=
			for ((line=0; line < ${#newFile[@]}; line++)); do	## Iterating through array skips blank lines.
				if [[ $linebuf =~ ${before[$still]} ]]; then
					newFile=("${newFile[@]:0:$line}" "${still#new}${spaceSaver}=${spaceSaver}${!still}" "${newFile[@]:$line}")
					unset "$still"
					break
				else linebuf="${newFile[$line]}"
				fi
			done
		fi
		if [[ "${!still}" ]]; then
			echo -e "\nFailed to update wireguard config ($still). Deleting it and re-running this script should work."
			exit 1
		fi
	done

	printf "%s\n" "${newFile[@]}" > "$confFile" || {
		echo -e "${RED}FAILED.{NC}\n\tFailed writing to wireguard config."
		exit 1
	}
else
	echo "
	[Interface]
	Address = $(echo "$wireguard_json" | jq -r '.peer_ip')
	PrivateKey = $newPrivateKey
	$dnsSettingForVPN
	[Peer]
	PersistentKeepalive = 25
	PublicKey = $(echo "$wireguard_json" | jq -r '.server_key')
	AllowedIPs = 0.0.0.0/0
	Endpoint = ${WG_SERVER_IP}:$(echo "$wireguard_json" | jq -r '.server_port')
	" > "$confFile" || exit 1
fi
echo -e ${GREEN}OK!${NC}

# Start the WireGuard interface.
# If something failed, stop this script.
# If you get DNS errors because you miss some packages,
# just hardcode /etc/resolv.conf to "nameserver 10.0.0.242".
echo
echo Trying to create the wireguard interface...
wg-quick up pia || exit 1
echo
echo -e "${GREEN}The WireGuard interface got created.${NC}

At this point, internet should work via VPN.

To disconnect the VPN, run:

--> ${GREEN}wg-quick down pia${NC} <--
"

# This section will stop the script if PIA_PF is not set to "true".
if [ "$PIA_PF" != true ]; then
  echo If you want to also enable port forwarding, you can start the script:
  echo -e $ ${GREEN}PIA_TOKEN=$PIA_TOKEN \
    PF_GATEWAY=$WG_SERVER_IP \
    PF_HOSTNAME=$WG_HOSTNAME \
    ./port_forwarding.sh${NC}
  echo
  echo The location used must be port forwarding enabled, or this will fail.
  echo Calling the ./get_region script with PIA_PF=true will provide a filtered list.
  exit 1
fi

echo -ne "This script got started with ${GREEN}PIA_PF=true${NC}.

Starting port forwarding in "
for i in {5..1}; do
  echo -n "$i..."
  sleep 1
done
echo
echo

echo -e "Starting procedure to enable port forwarding by running the following command:
$ ${GREEN}PIA_TOKEN=$PIA_TOKEN \\
  PF_GATEWAY=$WG_SERVER_IP \\
  PF_HOSTNAME=$WG_HOSTNAME \\
  ./port_forwarding.sh${NC}"

PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY=$WG_SERVER_IP \
  PF_HOSTNAME=$WG_HOSTNAME \
  ./port_forwarding.sh
