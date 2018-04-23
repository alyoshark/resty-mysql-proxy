# OpenResty MySQL Proxy

**This is a work-in-progress**


### File structure

In the `lua` folder, `mysql.lua` is shamelessly copied from [`lua-resty-mysql`](https://github.com/openresty/lua-resty-mysql/blob/master/lib/resty/mysql.lua), for my ease of reference during implementation.

The code is _directly and largely copied_ into `sniffer.lua`, which supposedly holds:

- A socket to upstream MySQL connection
- A socket to downstream client connection

The intention is simply to receive from one socket and send the content to the other, with content parsed and logged.


### To test run the proxy in Docker Compose

- Start docker-compose in a terminal to see the logs:

```
$ docker-compose up
```

- I personally use python's pymysql to connect to the dockerized MySQL instance:

```
$ python
>>> import pymysql
>>> conn = pymysql.connect(
        host='0.0.0.0',
        port=3306,
        user='root',
        password='app',
        db='app',
    )
```

MySQL is currently reporting "Got an error reading communication packets" and I don't have a clue why this is the case