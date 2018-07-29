local tcp = ngx.socket.tcp
local setmetatable = setmetatable

local U = require('utils')
local disable_ssl_and_compression = U.disable_ssl_and_compression

local M = {}


function M:init(cli, read_timeout)
    local sock = self.sock
    if not sock then
        return nil, "svr not initialized"
    end
    sock:connect(self.ip, self.port)
    read_timeout = read_timeout or 3600
    sock:settimeouts(10 * 1000, 60 * 1000, read_timeout * 1000)
    local header, packet, err = self:read()
    packet = disable_ssl_and_compression(packet)
    cli:write(header .. packet)
end


function M.new(ip, port)
    local sock, err = tcp()
    if not sock then
        return nil, err
    end
    return setmetatable({
        ip = ip, port = port, sock = sock,
        read = U.read,
        write = U.write,
    }, { __index = M })
end


return M
