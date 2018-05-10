local tcp = ngx.socket.tcp
local concat = table.concat
local setmetatable = setmetatable
local error = error

local strchar = string.char
local strbyte = string.byte
local strfind = string.find
local strsub = string.sub

local bit = require "bit"
local bor = bit.bor
local band = bit.band
local bnot = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift

if not ngx.config
   or not ngx.config.ngx_lua_version
   or ngx.config.ngx_lua_version < 9011
then
    error("ngx_lua 0.9.11+ required")
end

local mysql_ip = os.getenv("MYSQL_PORT_3306_TCP_ADDR")


-- logger setup {{
local logger = require "resty.logger.socket"
local syslog_ip = os.getenv("SYSLOG_PORT_601_TCP_ADDR")

if not logger.initted() then
    local ok, err = logger.init{
        host = syslog_ip,
        port = 601,
        -- flush_limit = 1234,
        -- drop_limit = 5678,
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to initialize the logger: ", err)
        return
    end
end


local function logit(cli, logline, flush)
    local content = concat({cli.username, ' from ', cli.ip, ' ', logline})
    logger.log(content .. '\n')
    if flush then logger.flush() end
end
-- }} logger setup


-- constants
local COM_QUIT = 0x01
local COM_QUERY = 0x03
local SERVER_MORE_RESULTS_EXISTS = 8

local TYPE_OK = 0x00
local TYPE_ERR = 0xff
local TYPE_EOF = 0xfe

local CAP_CLIENT_COMPRESS = 0x0020
local CAP_CLIENT_SSH = 0x0800

-- 16MB - 1, the default max allowed packet size used by libmysqlclient
local FULL_PACKET_SIZE = 16777215


-- utils {{
local function send(wrapper, packet)
    return wrapper.sock:send(packet)
end


local function receive(wrapper, len)
    return wrapper.sock:receive(len)
end


local function _get_byte2(data, i)
    local a, b = strbyte(data, i, i + 1)
    return bor(a, lshift(b, 8)), i + 2
end


local function _get_byte3(data, i)
    local a, b, c = strbyte(data, i, i + 2)
    return bor(a, lshift(b, 8), lshift(c, 16)), i + 3
end


local function _set_byte2(n)
    return strchar(band(n, 0xff), band(rshift(n, 8), 0xff))
end


local function _from_cstring(data, i)
    local last = strfind(data, "\0", i, true)
    if not last then
        return nil, nil
    end
    return strsub(data, i, last - 1), last + 1
end
-- }} utils


-- svr {{
local svr_mt = { __index = {} }


local function from_svr(svr)
    -- return: header, data, typ, err

    local sock = svr.sock
    local header, data, err

    header, err = sock:receive(4) -- packet header
    if not header then
        return nil, nil, nil, "failed to receive packet header: " .. err
    end

    local len, pos = _get_byte3(header, 1)
    if len == 0 then
        return nil, nil, nil, "empty packet"
    end

    if len > svr._max_packet_size then
        return nil, nil, nil, "packet size too big: " .. len
    end

    local num = strbyte(header, pos)
    data, err = sock:receive(len)

    if not data then
        return nil, nil, nil, "failed to read packet content: " .. err
    end

    return header, data, strbyte(data, 1), nil
end


local function init_svr(svr)
    local sock = svr.sock
    if not sock then
        return nil, "svr not initialized"
    end

    svr._max_packet_size = 1024 * 1024 -- hardcode it to 1MB
    sock:connect(mysql_ip, 3306)

    local header, packet, typ, err = from_svr(svr)
    local server_version, pos = _from_cstring(packet, 2)
    local pos = pos + 4 + 9  -- server_version | thread_id | filler
    local precap = strsub(packet, 1, pos - 1)
    local cap, pos = _get_byte2(packet, pos)
    local postcap = strsub(packet, pos)

    cap = band(cap, bnot(CAP_CLIENT_COMPRESS))
    cap = band(cap, bnot(CAP_CLIENT_SSH))
    packet = precap .. _set_byte2(cap) .. postcap
    return header, packet
end


local function new_svr()
    local sock, err = tcp()
    if not sock then
        return nil, err
    end
    return setmetatable({ sock = sock }, svr_mt)
end
-- }} svr


-- cli {{
local cli_mt = { __index = {} }


local function from_cli(cli)
    local sock = cli.sock
    local header, data, err

    header, err = sock:receive(4) -- packet header (4th byte is seq)
    if not header then
        return nil, nil, "failed to receive packet header: " .. err
    end

    local len, pos = _get_byte3(header, 1)
    if len == 0 then
        return nil, nil, "empty packet"
    end

    if len > cli._max_packet_size then
        return nil, nil, "packet size too big: " .. len
    end

    data, err = sock:receive(len)
    if not data then
        return nil, nil, "failed to read packet content: " .. err
    end

    return header, data, nil
end


local function get_username(cli, packet)
    local lstripped = strsub(packet, 33)
    local pos = strfind(lstripped, "\0")
    cli.username = strsub(lstripped, 1, pos - 1)
end


local function new_cli(sock, ip)
    -- downstream socket
    return setmetatable({
        ip = ip,
        sock = sock,
        _max_packet_size = 1024 * 1024,
    }, cli_mt)
end
-- }} cli


-- proxy {{
local function init_proxy()
    local svr = new_svr()
    local dss = assert(ngx.req.socket(true)) -- downstream socket
    local cli = new_cli(dss, ngx.var.remote_addr)

    -- handshake and return svr, cli instances
    local header, packet, typ, err = init_svr(svr)
    send(cli, header .. packet)

    header, packet, err = from_cli(cli)
    get_username(cli, packet)
    send(svr, header .. packet)

    header, packet, typ, err = from_svr(svr)
    send(cli, header .. packet)
    return svr, cli
end


local function query(cli, svr)
    local header, packet, err = from_cli(cli)
    if err then return err end

    local qry = strsub(packet, 1, #packet)
    local com = strbyte(packet)
    if com == COM_QUIT then
        send(svr, header .. packet)
        cli.qry = nil
        return 'quit'
    end

    cli.qry = qry
    send(svr, header .. packet)
end


local function process_resp(cli, svr)
    local header, packet, typ, err = from_svr(svr)
    send(cli, header .. packet)

    if typ ~= TYPE_OK then
        repeat
            header, packet, typ, err = from_svr(svr)
            send(cli, header .. packet)
        until typ == TYPE_EOF

        repeat
            header, packet, typ, err = from_svr(svr)
            send(cli, header .. packet)
        until typ == TYPE_EOF
    end
end
-- }} proxy


local _M = { _VERSION = '0.01' }


function _M.peep()
    local svr, cli = init_proxy()
    logit(cli, "connected", true)
    local header, packet, typ, err, result

    while true do
        err = query(cli, svr)
        local qry = cli.qry
        if qry then
            logit(cli, "query: " .. cli.qry, true)
        end
        if err then break end
        process_resp(cli, svr)
    end
    logit(cli, "disconnected", true)
end


return _M
