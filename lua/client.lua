local setmetatable = setmetatable
local concat = table.concat
local strfind = string.find
local strsub = string.sub
local strgsub = string.gsub

local U = require("utils")


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
-- }} logger setup


local M = {}

function M:log(logline, flush)
    if strfind(logline, "\n") then
        logline = strgsub(logline, "\n", " ")
    end
    local content = concat({self.username, " from ", self.ip, " ", logline})
    logger.log(content .. "\n")
    if flush then logger.flush() end
end


function M:set_username(packet)
    local lstripped = strsub(packet, 33)
    local pos = strfind(lstripped, "\0")
    self.username = strsub(lstripped, 1, pos - 1)
end


function M:init(svr)
    header, packet, err = self:read()
    self:set_username(packet)
    svr:write(header .. packet)
end


function M.new(sock, ip)
    return setmetatable({
        ip = ip, sock = sock,
        read = U.read,
        write = U.write,
    }, { __index = M })
end


return M