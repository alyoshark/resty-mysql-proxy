# OpenResty MySQL Proxy

**This is a work-in-progress**


This project has largely copied (then trimmed) chunks of code from [`lua-resty-mysql`](https://github.com/openresty/lua-resty-mysql/blob/master/lib/resty/mysql.lua).

The *sniffer proxy* holds:

- A socket to upstream MySQL connection
- A socket to downstream client connection

And it simply receives from one socket and sends the content to the other, with queries parsed and logged.


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


## TODO

- ~~MySQL commandline client login~~
- MySQL commandline client query
- Timeout handling
