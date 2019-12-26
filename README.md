When systemd-nspawn create a container, it will not configure the host and container's network unless both are managed by systemd-networkd.

So you may often have to manually configure net configuration at both sides.

This script just take one parameter as container name, then 
- configure ip 10.8.8.x for both sides
- configure iptables at host side to allow the container can access whatever the host can access.
- print the result ip of the container

Usage:

Host side:
```
$ wget https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-1907.qcow2c -o centos76.qcow2c
$ qemu-img convert -O raw centos76.qcow2c centos76.dd
$ sudo systemd-nspawn --image centos76.dd bash -c '(echo root; echo root) | passwd'
$ sudo systemd-nspawn --image centos76.dd touch /etc/cloud/cloud-init.disabled
$ sudo systemd-nspawn --image centos76.dd --network-veth --boot
```

```
Press ^] three times within 1s to kill container.
...
[  OK  ] Started Postfix Mail Transport Agent.
[  OK  ] Started Dynamic System Tuning Daemon.
[  OK  ] Reached target Multi-User System.
         Starting Update UTMP about System Runlevel Changes...
[  OK  ] Started Update UTMP about System Runlevel Changes.

CentOS Linux 7 (Core)
Kernel 4.4.0-137-generic on an x86_64

localhost login: root
Password:
```

then you will find it the container has no ip.
```
[root@localhost ~]# ip -br a
lo               UNKNOWN        127.0.0.1/8 ::1/128
host0@if54       DOWN
```

then you can run this utility (on host side, not the container side):
note: no need to be able to access the centos76.dd file, `centos76.dd` is just choosen by systemd-nspawn as a name.
```
$ ./systemd-nspawn-ip centos76.dd
```
the output will be
```
10.8.8.2
```

then you can 
```
ssh 10.8.8.2
```
Of course you need enter the container to prepare ssh user and keys or sshd_config.

