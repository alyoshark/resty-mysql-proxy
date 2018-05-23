local tcp = ngx.socket.tcp
local setmetatable = setmetatable

local U = require('utils')

-- 16MB - 1, the default max allowed packet size used by libmysqlclient
local FULL_PACKET_SIZE = 16777215

local _mt = { __index = {} }
local M = {}


local function init(svr, cli)
    local sock = svr.sock
    if not sock then
        return nil, "svr not initialized"
    end

    svr._max_packet_size = FULL_PACKET_SIZE
    sock:connect(svr.ip, 3306)
    local header, packet, err = svr:read()
    packet = U.disable_ssl_and_compression(packet)
    cli:write(header .. packet)
end


function M.new(ip)
    local sock, err = tcp()
    if not sock then
        return nil, err
    end
    return setmetatable({
        ip = ip, sock = sock,
        _max_packet_size = FULL_PACKET_SIZE,
        init = init,
        read = U.read,
        write = U.write,
    }, _mt)
end


return M