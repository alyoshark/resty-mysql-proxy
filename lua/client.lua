local setmetatable = setmetatable
local concat = table.concat
local strfind = string.find
local strsub = string.sub
local strgsub = ngx.re.gsub

local U = require("utils")
local logger = require("logger")

local M = {}

function M:log(logline, flush)
    if strfind(logline, "\n") then
        logline = strgsub(logline, "\n", " ")
    end
    -- TODO: Why does syslog-ng discard the first word?!
    local content = "* " .. concat({self.username, self.ip, self.conn, logline}, "|")
    logger.log(content .. "\n")
    if flush then logger.flush() end
end


function M:set_username(packet)
    local lstripped = strsub(packet, 33)
    local pos = strfind(lstripped, "\0")
    self.username = strsub(lstripped, 1, pos - 1)
end


function M:init(svr, read_timeout)
    local header, packet, err = self:read()
    read_timeout = read_timeout or 3600
    self.sock:settimeouts(10 * 1000, 60 * 1000, read_timeout * 1000)
    self:set_username(packet)
    svr:write(header .. packet)
end


function M.new(sock, ip, conn)
    return setmetatable({
        ip = ip, conn = conn, sock = sock,
        read = U.read,
        write = U.write,
    }, { __index = M })
end


return M
