#!/bin/bash
export PS4='+# ' # set trace output prefix char to differ from normal trace prefix('+ ')
set -e -o pipefail -x # exit on error, enable command trace

# this script configure ip and nat for a systemd-nspawn container and print its ip.
# When the host and container are both using systemd-networkd, such as both Ubuntu Bionic,
# things become easier, there is no need to manually do things in this script.
# Otherwise we still need manually configure veth's ip and iptables
#
# args: <a container name>
# stdout: assigned ip of the container 

# note: do not use `export VAR=$(command)` because that will not exit on error

# 10.x.x.x is a private ip range. We will use this range to manage 64(256/4) containers
[[ $IP_PREFIX ]] || IP_PREFIX=10.8.8 # set default IP_PREFIX

if [[ $FLOCK_DONE != 1 ]]; then
  CTR_NAME=${1:?require next argument as a running container name, usually the name of the image file or dir}

  # check the container existence and get its pid so can enter its net namespace later.
  # Note: machinectl show ... --value option is not supported in Xenial.
  CTR_PID=$(machinectl show "$CTR_NAME" --property=Leader | grep -E --only-matching '[0-9]+')
  # systemd-nspawn will use only the first 11 chars to build veth name
  HOST_VETH_NAME=ve-${CTR_NAME:0:11}

  ################################################################################
  # run myself within an exclusive lock

  export HOST_VETH_NAME CTR_PID
  exec flock --exclusive /run/systemd-nspawn-cfg-net.lock bash <<__EOF_FLOCK_STDIN
    set -e -o pipefail -x # exit on error, enable command trace
    FLOCK_DONE=1 "$0" "$@"
__EOF_FLOCK_STDIN
  # will never not come here. The exec command will replace current process
fi

ip link set $HOST_VETH_NAME up
nsenter --target=$CTR_PID --net ip link set host0 up

################################################################################
# assign host side veth ip if not yet
if HOST_IP=$(ip -4 -oneline address show dev $HOST_VETH_NAME scope global | grep --perl-regexp --only-matching "(?<=inet )\Q$IP_PREFIX\E\.[0-9]+/[0-9]+(?= )"); then
  HOST_IP=${HOST_IP%/*}
  last_part=${HOST_IP##*.}
  CTR_IP=$IP_PREFIX.$((last_part+1))
else
  # get all ip related the ip range, both host and containers, encode them into a comma started and comma separated string,
  # e.g. ",10.8.8.1,10.8.8.2,"
  IP_LIST=,$({ ip -4 -oneline address show scope global | grep --perl-regexp --only-matching "(?<= )\Q$IP_PREFIX\E\.[0-9]+(?=/)" || true; } | tr '\n' ',')
  # if it has not been assigned an ip with specified range, then assign an unused ip
  FOUND=0
  for i in {0..63}; do
    HOST_IP=$IP_PREFIX.$((i*4+1))
    CTR_IP=$IP_PREFIX.$((i*4+2)) # for container
    # found if the ip is not included in the ip list
    if [[ $IP_LIST != *,$HOST_IP,* && $IP_LIST != *,$CTR_IP,* ]]; then
      FOUND=1
      break
    fi
  done
  if [[ $FOUND != 1 ]]; then
    echo "no free ip in $IP_PREFIX.*/30" >&2
    exit 1
  fi
  # it is very important that each veth pair use different broadcast ip, that is why here use /30
  ip address add $HOST_IP/30 broadcast + dev $HOST_VETH_NAME
fi

################################################################################
# assign container side veth ip if not yet.
# nsenter is used to enter the container's net namespace
nsenter --target=$CTR_PID --net bash <<EOF_CTR_BASH
  set -e -o pipefail -x # exit on error, enable command trace
  ip address change $CTR_IP/30 broadcast + dev host0
  if ! ip route show default | grep -E "^default via $HOST_IP " >&2; then
    ip route add default via $HOST_IP dev host0
  fi
EOF_CTR_BASH

################################################################################
# add iptable rule to allow the container access outer network by ip masquerading
if ! iptables --table=nat --check POSTROUTING --source=$IP_PREFIX.0/24 --jump=MASQUERADE >/dev/null 2>&1; then
  iptables --table=nat --append POSTROUTING --source=$IP_PREFIX.0/24 --jump=MASQUERADE
fi

# allow ip_forward, otherwise package can not go out through real nic
echo 1 > /proc/sys/net/ipv4/ip_forward

# copy host side resolv.conf to the container
if ! diff /etc/resolv.conf /proc/$CTR_PID/root/etc/resolv.conf >/dev/null; then
  rm -f /proc/$CTR_PID/root/etc/resolv.conf
  cp /etc/resolv.conf /proc/$CTR_PID/root/etc/resolv.conf
fi

echo $CTR_IP
