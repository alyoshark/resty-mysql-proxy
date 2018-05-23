local setmetatable = setmetatable
local concat = table.concat
local strfind = string.find
local strsub = string.sub

local U = require("utils")

-- 16MB - 1, the default max allowed packet size used by libmysqlclient
local FULL_PACKET_SIZE = 16777215


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


local _mt = { __index = {} }
local M = {}

local function log(cli, logline, flush)
    local content = concat({cli.username, ' from ', cli.ip, ' ', logline})
    logger.log(content .. '\n')
    if flush then logger.flush() end
end


local function set_username(cli, packet)
    local lstripped = strsub(packet, 33)
    local pos = strfind(lstripped, "\0")
    cli.username = strsub(lstripped, 1, pos - 1)
end


local function init(cli, svr)
    header, packet, err = cli:read()
    cli:set_username(packet)
    svr:write(header .. packet)
end


function M.new(sock, ip)
    -- downstream socket
    return setmetatable({
        ip = ip, sock = sock,
        _max_packet_size = FULL_PACKET_SIZE,
        init = init,
        log = log,
        set_username = set_username,
        read = U.read,
        write = U.write,
    }, _mt)
end


return M