local tcp = ngx.socket.tcp
local setmetatable = setmetatable

local U = require('utils')
local disable_ssl_and_compression = U.disable_ssl_and_compression

local M = {}


function M:init(cli)
    local sock = self.sock
    if not sock then
        return nil, "svr not initialized"
    end
    sock:connect(self.ip, 3306)
    local header, packet, err = self:read()
    packet = disable_ssl_and_compression(packet)
    cli:write(header .. packet)
end


function M.new(ip)
    local sock, err = tcp()
    if not sock then
        return nil, err
    end
    return setmetatable({
        ip = ip, sock = sock,
        read = U.read,
        write = U.write,
    }, { __index = M })
end


return M