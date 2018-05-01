FROM openresty/openresty:alpine

RUN apk add --no-cache --virtual .build-deps curl && \
    mkdir -p /usr/local/openresty/lualib/resty/logger && \
    curl -L -o /usr/local/openresty/lualib/resty/logger/socket.lua \
        https://raw.githubusercontent.com/cloudflare/lua-resty-logger-socket/master/lib/resty/logger/socket.lua && \
    apk del .build-deps