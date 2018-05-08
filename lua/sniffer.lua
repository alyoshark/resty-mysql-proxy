local bit = require "bit"
local sub = string.sub
local tcp = ngx.socket.tcp
local strbyte = string.byte
local strchar = string.char
local strfind = string.find
local strsub = string.sub
local format = string.format
local strrep = string.rep
local null = ngx.null
local band = bit.band
local bxor = bit.bxor
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local tohex = bit.tohex
local concat = table.concat
local setmetatable = setmetatable
local error = error
local tonumber = tonumber

if not ngx.config
   or not ngx.config.ngx_lua_version
   or ngx.config.ngx_lua_version < 9011
then
    error("ngx_lua 0.9.11+ required")
end

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
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

-- 16MB - 1, the default max allowed packet size used by libmysqlclient
local FULL_PACKET_SIZE = 16777215

-- mysql field value type converters
local converters = new_tab(0, 9)

for i = 0x01, 0x05 do
    -- tiny, short, long, float, double
    converters[i] = tonumber
end
converters[0x00] = tonumber  -- decimal
-- converters[0x08] = tonumber  -- long long
converters[0x09] = tonumber  -- int24
converters[0x0d] = tonumber  -- year
converters[0xf6] = tonumber  -- newdecimal


-- utils {{
local function send(wrapper, packet)
    return wrapper.sock:send(packet)
end


local function receive(wrapper, len)
    return wrapper.sock:receive(len)
end


local function keepalive(wrapper, ...)
    return wrapper.sock:setkeepalive(...)
end


local function _get_byte2(data, i)
    local a, b = strbyte(data, i, i + 1)
    return bor(a, lshift(b, 8)), i + 2
end


local function _get_byte3(data, i)
    local a, b, c = strbyte(data, i, i + 2)
    return bor(a, lshift(b, 8), lshift(c, 16)), i + 3
end


local function _get_byte4(data, i)
    local a, b, c, d = strbyte(data, i, i + 3)
    return bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24)), i + 4
end


local function _get_byte8(data, i)
    local a, b, c, d, e, f, g, h = strbyte(data, i, i + 7)

    -- XXX workaround for the lack of 64-bit support in bitop:
    local lo = bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24))
    local hi = bor(e, lshift(f, 8), lshift(g, 16), lshift(h, 24))
    return lo + hi * 4294967296, i + 8
end


local function _from_length_coded_bin(data, pos)
    local first = strbyte(data, pos)

    if not first then
        return nil, pos
    end

    if first >= 0 and first <= 250 then
        return first, pos + 1
    end

    if first == 251 then
        return null, pos + 1
    end

    if first == 252 then
        pos = pos + 1
        return _get_byte2(data, pos)
    end

    if first == 253 then
        pos = pos + 1
        return _get_byte3(data, pos)
    end

    if first == 254 then
        pos = pos + 1
        return _get_byte8(data, pos)
    end

    return nil, pos + 1
end


local function _from_length_coded_str(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if not len or len == null then
        return null, pos
    end
    return sub(data, pos, pos + len - 1), pos + len
end


local function _parse_ok_packet(packet)
    local res = new_tab(0, 5)
    local pos

    res.affected_rows, pos = _from_length_coded_bin(packet, 2)
    res.insert_id, pos = _from_length_coded_bin(packet, pos)
    res.server_status, pos = _get_byte2(packet, pos)
    res.warning_count, pos = _get_byte2(packet, pos)

    local message = _from_length_coded_str(packet, pos)
    if message and message ~= null then
        res.message = message
    end
    return res
end


local function _parse_result_set_header_packet(packet)
    local field_count, pos = _from_length_coded_bin(packet, 1)
    local extra = _from_length_coded_bin(packet, pos)
    return field_count, extra
end


local function _parse_field_packet(data)
    local col = new_tab(0, 2)
    local catalog, db, table, orig_table, orig_name, charsetnr, length
    local pos
    catalog, pos = _from_length_coded_str(data, 1)

    db, pos = _from_length_coded_str(data, pos)
    table, pos = _from_length_coded_str(data, pos)
    orig_table, pos = _from_length_coded_str(data, pos)
    col.name, pos = _from_length_coded_str(data, pos)

    orig_name, pos = _from_length_coded_str(data, pos)
    pos = pos + 1 -- ignore the filler
    charsetnr, pos = _get_byte2(data, pos)
    length, pos = _get_byte4(data, pos)
    col.type = strbyte(data, pos)
    return col
end


local function _parse_row_data_packet(data, cols)
    local pos = 1
    local ncols = #cols
    local row = new_tab(ncols, 0)

    for i = 1, ncols do
        local value
        value, pos = _from_length_coded_str(data, pos)
        local col = cols[i]
        local typ = col.type

        if value ~= null then
            local conv = converters[typ]
            if conv then
                value = conv(value)
            end
        end
        row[i] = value
    end

    return row
end
-- }} utils


-- svr {{
local _svr = { _VERSION = '0.01' }
local svr_mt = { __index = _svr }


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
local _cli = { _VERSION = '0.01' }
local cli_mt = { __index = _cli }


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


local function process_columns(cli, svr, packet)
    local field_count, extra = _parse_result_set_header_packet(packet)
    local cols = new_tab(field_count, 0)
    for i = 1, field_count do
        header, packet, typ, err = from_svr(svr)
        send(cli, header .. packet)
        local col, err, errno, sqlstate = _parse_field_packet(packet)
        cols[i] = col
    end
    return cols
end


local function process_rows(cli, svr, cols)
    local rows = new_tab(4, 0)
    local i = 0

    while true do
        header, packet, typ, err = from_svr(svr)
        send(cli, header .. packet)
        if typ == TYPE_EOF then break end

        local row = _parse_row_data_packet(packet, cols)
        i = i + 1
        rows[i] = row
    end
end


local function process_resp(cli, svr)
    local header, packet, typ, err = from_svr(svr)
    send(cli, header .. packet)

    if typ == TYPE_OK then
        local result = _parse_ok_packet(packet)
        -- log result?
    else
        local cols = process_columns(cli, svr, packet)

        -- An "EOF" packet to separate table header from body
        header, packet, typ, err = from_svr(svr)
        send(cli, header .. packet)

        local rows = process_rows(cli, svr, cols)
    end
end
-- }} proxy


local _M = {}


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
