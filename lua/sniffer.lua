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


-- constants

local COM_QUIT = 0x01
local COM_QUERY = 0x03
local CLIENT_SSL = 0x0800

local SERVER_MORE_RESULTS_EXISTS = 8


-- xch debugger:
local function print(...)
    ngx.log(ngx.ERR, ...)
end


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

    -- return bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24), lshift(e, 32),
               -- lshift(f, 40), lshift(g, 48), lshift(h, 56)), i + 8
end


local function _set_byte2(n)
    return strchar(band(n, 0xff), band(rshift(n, 8), 0xff))
end


local function _set_byte3(n)
    return strchar(band(n, 0xff),
                   band(rshift(n, 8), 0xff),
                   band(rshift(n, 16), 0xff))
end


local function _set_byte4(n)
    return strchar(band(n, 0xff),
                   band(rshift(n, 8), 0xff),
                   band(rshift(n, 16), 0xff),
                   band(rshift(n, 24), 0xff))
end


local function _from_cstring(data, i)
    local last = strfind(data, "\0", i, true)
    if not last then
        return nil, nil
    end

    return sub(data, i, last - 1), last + 1
end


local function _to_cstring(data)
    return data .. "\0"
end


local function _to_binary_coded_string(data)
    return strchar(#data) .. data
end


local function _dump(data)
    local len = #data
    local bytes = new_tab(len, 0)
    for i = 1, len do
        bytes[i] = format("%x", strbyte(data, i))
    end
    return concat(bytes, " ")
end


local function _dumphex(data)
    local len = #data
    local bytes = new_tab(len, 0)
    for i = 1, len do
        bytes[i] = tohex(strbyte(data, i), 2)
    end
    return concat(bytes, " ")
end


local function _from_length_coded_bin(data, pos)
    local first = strbyte(data, pos)

    --print("LCB: first: ", first)

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

    --print("affected rows: ", res.affected_rows, ", pos:", pos)

    res.insert_id, pos = _from_length_coded_bin(packet, pos)

    --print("insert id: ", res.insert_id, ", pos:", pos)

    res.server_status, pos = _get_byte2(packet, pos)

    --print("server status: ", res.server_status, ", pos:", pos)

    res.warning_count, pos = _get_byte2(packet, pos)

    --print("warning count: ", res.warning_count, ", pos: ", pos)

    local message = _from_length_coded_str(packet, pos)
    if message and message ~= null then
        res.message = message
    end

    --print("message: ", res.message, ", pos:", pos)

    return res
end


local function _parse_result_set_header_packet(packet)
    local field_count, pos = _from_length_coded_bin(packet, 1)

    local extra
    extra = _from_length_coded_bin(packet, pos)

    return field_count, extra
end


local function _parse_field_packet(data)
    local col = new_tab(0, 2)
    local catalog, db, table, orig_table, orig_name, charsetnr, length
    local pos
    catalog, pos = _from_length_coded_str(data, 1)

    --print("catalog: ", col.catalog, ", pos:", pos)

    db, pos = _from_length_coded_str(data, pos)
    table, pos = _from_length_coded_str(data, pos)
    orig_table, pos = _from_length_coded_str(data, pos)
    col.name, pos = _from_length_coded_str(data, pos)

    orig_name, pos = _from_length_coded_str(data, pos)

    pos = pos + 1 -- ignore the filler

    charsetnr, pos = _get_byte2(data, pos)

    length, pos = _get_byte4(data, pos)

    col.type = strbyte(data, pos)

    --[[
    pos = pos + 1
    col.flags, pos = _get_byte2(data, pos)
    col.decimals = strbyte(data, pos)
    pos = pos + 1
    local default = sub(data, pos + 2)
    if default and default ~= "" then
        col.default = default
    end
    --]]

    return col
end


local function _parse_row_data_packet(data, cols, compact)
    local pos = 1
    local ncols = #cols
    local row
    if compact then
        row = new_tab(ncols, 0)
    else
        row = new_tab(0, ncols)
    end
    for i = 1, ncols do
        local value
        value, pos = _from_length_coded_str(data, pos)
        local col = cols[i]
        local typ = col.type
        local name = col.name

        --print("row field value: ", value, ", type: ", typ)

        if value ~= null then
            local conv = converters[typ]
            if conv then
                value = conv(value)
            end
        end

        if compact then
            row[i] = value
        else
            row[name] = value
        end
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

    local field_count = strbyte(data, 1)
    local typ
    if field_count == 0x00 then
        typ = "OK"
    elseif field_count == 0xff then
        typ = "ERR"
    elseif field_count == 0xfe then
        typ = "EOF"
    else
        typ = "DATA"
    end

    return header, data, typ, nil
end


local function init_svr(svr)
    local sock = svr.sock
    if not sock then
        return nil, "svr not initialized"
    end

    svr._max_packet_size = 1024 * 1024 -- hardcode it to 1MB
    local mysql_ip = os.getenv("MYSQL_PORT_3306_TCP_ADDR")
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
    cli.username = strsub(lstripped, 1, pos)
end


local function new_cli(sock)
    -- downstream socket
    return setmetatable({ sock = sock, _max_packet_size = 1024 * 1024 }, cli_mt)
end
-- }} cli


-- proxy {{
local function init_proxy()
    local svr = new_svr()
    local dss = assert(ngx.req.socket(true)) -- downstream socket
    local cli = new_cli(dss)

    local header, packet, typ, err = init_svr(svr)
    send(cli, header .. packet)

    header, packet, typ, err = from_cli(cli)
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
        if typ == "EOF" then break end

        local row = _parse_row_data_packet(packet, cols)
        i = i + 1
        rows[i] = row
    end
end


local function process_resp(cli, svr)
    local header, packet, typ, err = from_svr(svr)
    send(cli, header .. packet)

    if typ == "OK" then
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
    local header, packet, typ, err, result

    while true do
        err = query(cli, svr)
        print("query: ", cli.qry)
        if err then break end
        process_resp(cli, svr)
    end
end


return _M
