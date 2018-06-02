# Installation Guide

## Install OpenResty

It is suggested to use OpenResty official build per described [here](https://openresty.org/en/linux-packages.html)

## Install syslog-ng

Syslog-ng official website has a pretty comprehensive [guide](https://syslog-ng.com/blog/installing-latest-syslog-ng-on-rhel-and-other-rpm-distributions/)
on installing the latest version of syslog-ng to CentOS

## Install resty-logger-socket

```bash
$ curl -L -o /usr/local/openresty/lualib/resty/logger/socket.lua \
          https://raw.githubusercontent.com/cloudflare/lua-resty-logger-socket/master/lib/resty/logger/socket.lua
```

For stability concerns, a tagged version of lua code could be used instead of master branch

## Slot in OpenResty configuration

```bash
# Backup origin config
$ mv /usr/local/openresty/nginx/conf/nginx.conf{,.backup}
$ cp ./nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
```

## Slot in syslog-ng configuration

TODO (verify where syslog-ng default config is)
```bash
$ cp ./syslog-ng/syslog-ng.conf /etc/syslog-ng/  # To be confirmed
```

## Start syslog-ng

TODO

## Config DB server and syslog-ng IP & ports

In `/usr/local/openresty/nginx/conf/nginx.conf`, line 25 & 26 config syslog-ng IP and port,
line 30 determines the proxy port to open, line 33 configs DB server IP and port.

A new proxy port could be added by adding a new server block.

## Start OpenResty

```bash
$ openresty
```