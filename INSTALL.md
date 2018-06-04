# Installation Guide

## Install OpenResty

It is suggested to use OpenResty official build per described [here](https://openresty.org/en/linux-packages.html).
Which is essentially the following steps:

```bash
$ yum install yum-utils
$ yum-config-manager --add-repo https://openresty.org/package/centos/openresty.repo
$ yum install openresty
```

## Install syslog-ng

Syslog-ng official website has a pretty comprehensive [guide](https://syslog-ng.com/blog/installing-latest-syslog-ng-on-rhel-and-other-rpm-distributions/)
on installing the latest version of syslog-ng to CentOS.
Which is essentially the following steps:

```bash
$ curl https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm | rpm -Uvh -
$ cd /etc/yum.repos.d && curl -O https://copr.fedorainfracloud.org/coprs/czanik/syslog-ng314/repo/epel-7/czanik-syslog-ng314-epel-7.repo
$ yum install syslog-ng
```


## Install resty-logger-socket

Being a playful hipster, I use the code from master branch in this source;
but for stability concerns, a tagged version of lua code could be used instead.

```bash
$ curl -L -o /usr/local/openresty/lualib/resty/logger/socket.lua \
          https://raw.githubusercontent.com/cloudflare/lua-resty-logger-socket/master/lib/resty/logger/socket.lua
```

## Slot in OpenResty configuration

```bash
# Backup origin config
$ mv /usr/local/openresty/nginx/conf/nginx.conf{,.backup}
$ cp ./nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
$ cp -r ./lua /usr/local/openresty/nginx/
```

## Write a syslog-ng configuration

Put the following config into `/etc/syslog-ng/conf.d/mysql-proxy.conf`:

```
source s_mysql {
    network(
        ip(0.0.0.0)
        transport("tcp")
        port(601)
    );
};

destination d_mysql {
    file(
        "/var/log/mysql-proxy/access.log"
        template("${MESSAGE}\n")
    )
};

log {
    source(s_mysql);
    destination(d_mysql);
};
```

## Enable & Start syslog-ng

```bash
$ systemctl enable syslog-ng
$ systemctl start syslog-ng
```

## Config DB server and syslog-ng IP & ports

In `/usr/local/openresty/nginx/conf/nginx.conf`, line 25 & 26 config syslog-ng IP and port,
line 30 determines the proxy port to open, line 33 configs DB server IP and port.

A new proxy port could be added by adding a new server block.

## Enable & Start OpenResty

```bash
$ systemctl enable openresty
$ systemctl start openresty
```