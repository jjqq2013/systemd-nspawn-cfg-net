#!/bin/bash
set -e -o pipefail -x # exit on error, enable command trace

# this script configure ip and nat for the a systemd-nspawn container and print its ip.
# When the host and container are both using systemd-networkd, such as both Ubuntu Bionic,
# things become easier, there is no need to manually do things in this script.
# Otherwise we still need manually configure veth's ip and iptables

CONTAINER_NAME=${1:?require next argument as container name, usually the name of the image file or dir}; shift

# get container pid so can enter its net namespace later
CONTAINER_PID=$(machinectl show "${CONTAINER_NAME}" --property=Leader | grep -E --only-matching '[0-9]+')

# systemd-nspawn will use only the first 11 chars to build veth name
SHORT_NAME=$(cut --characters=1-11 <<< "$CONTAINER_NAME")

IP_PREFIX=10.8.8 # 10.x.x.x is a private ip range

# assign host side veth ip, result is ${IP_PREFIX}.$i
# ve-${SHORT_NAME} is the nic name of veth, created by systemd-nspawn
ip link set ve-${SHORT_NAME} up >&2
for i in {1..254}; do
  ip address delete ${IP_PREFIX}.$i/24 dev ve-${SHORT_NAME} >/dev/null 2>&1 || true
  if ip address add ${IP_PREFIX}.$i/24 dev ve-${SHORT_NAME} >&2; then
    break
  fi
done

# assign container side veth ip, result is ${IP_PREFIX}.$j
# host0 is the nic name of veth in the container, renamed by systemd-nspawn
j=$(nsenter --target=$CONTAINER_PID --net bash <<EOF
  set -e -o pipefail -x # exit on error, enable command trace

  ip link set host0 up >&2
  for j in {1..254}; do
    if [[ \$j != $i ]]; then
      ip address delete ${IP_PREFIX}.\$j/24 dev host0 >/dev/null 2>&1 || true
      if ip address add ${IP_PREFIX}.\$j/24 dev host0 >&2; then
        break
      fi
    fi
  done
  ip route add default via ${IP_PREFIX}.$i >&2

  # avoid same ip being assigned at both sides
  ip address delete ${IP_PREFIX}.$i/24 dev host0 >/dev/null 2>&1 || true

  echo \$j
EOF
)

# avoid same ip being assigned at both sides
ip address delete ${IP_PREFIX}.$j/24 dev ve-${SHORT_NAME} >/dev/null 2>&1 || true

# add iptable rule to allow the container access outer network by IP masquerade
if ! iptables --table=nat --check POSTROUTING --source=${IP_PREFIX}.0/24 --jump=MASQUERADE >/dev/null 2>&1; then
  iptables --table=nat --append POSTROUTING --source=${IP_PREFIX}.0/24 --jump=MASQUERADE >&2
fi

# allow ip_forward, otherwise package can not go out through real nic
echo 1 > /proc/sys/net/ipv4/ip_forward

# show the container's IP
echo ${IP_PREFIX}.$j
