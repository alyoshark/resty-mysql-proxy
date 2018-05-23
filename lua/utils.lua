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

-------------
-- private --
-------------
local CAP_CLIENT_COMPRESS = 0x0020
local CAP_CLIENT_SSH = 0x0800


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


------------
-- public --
------------
local M = {}


function M.write(conn, packet)
    return conn.sock:send(packet)
end


function M.read(conn)
    local sock = conn.sock
    local header, data, err

    header, err = sock:receive(4) -- packet header (4th byte is seq)
    if not header then
        return nil, nil, "failed to receive packet header: " .. err
    end

    local len, pos = _get_byte3(header, 1)
    if len == 0 then
        return nil, nil, "empty packet"
    end

    if len > conn._max_packet_size then
        return nil, nil, "packet size too big: " .. len
    end

    data, err = sock:receive(len)
    if not data then
        return nil, nil, "failed to read packet content: " .. err
    end

    return header, data, nil
end


function M.disable_ssl_and_compression(packet)
    local server_version, pos = _from_cstring(packet, 2)
    local pos = pos + 4 + 9  -- server_version | thread_id | filler
    local precap = strsub(packet, 1, pos - 1)
    local cap, pos = _get_byte2(packet, pos)
    local postcap = strsub(packet, pos)

    cap = band(cap, bnot(CAP_CLIENT_COMPRESS))
    cap = band(cap, bnot(CAP_CLIENT_SSH))
    return precap .. _set_byte2(cap) .. postcap
end


return M