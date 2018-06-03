# OpenResty MySQL Proxy

**This is a work-in-progress**

Here is the [installation guide](https://github.com/xch91/resty-mysql-proxy/blob/master/INSTALL.md)

This project has largely copied (then trimmed) chunks of code from [`lua-resty-mysql`](https://github.com/openresty/lua-resty-mysql/blob/master/lib/resty/mysql.lua).

The *sniffer proxy* holds:

- A socket to upstream MySQL connection
- A socket to downstream client connection

And it simply receives from one socket and sends the content to the other, with queries parsed and logged.


### To test run the proxy in Docker Compose

- Start docker-compose in a terminal to see the logs:

```bash
$ docker-compose up
```

- Test connection

```bash
mysql -h0.0.0.0 -P6606 -uroot -papp app
```


## TODO

- ~~MySQL commandline client login~~
- ~~MySQL commandline client query~~
- Better timeout handling (it's now naively one hour)
- Better syslog-ng setup (I don't know if it rotates)
