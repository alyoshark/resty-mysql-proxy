local logger = require "resty.logger.socket"
local syslog_ip = os.getenv("SYSLOG_PORT_601_TCP_ADDR")

local cjson = require("cjson.safe")
local json_encode = cjson.encode
local json_decode = cjson.decode

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

return logger