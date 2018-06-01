local logger = require "resty.logger.socket"

local cjson = require("cjson.safe")
local json_encode = cjson.encode
local json_decode = cjson.decode

if not logger.initted() then
    local ok, err = logger.init{
        host = SYSLOG_IP,
        port = SYSLOG_PORT,
        -- flush_limit = 1234,
        -- drop_limit = 5678,
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to initialize the logger: ", err)
        ngx.log(ngx.ERR, "fall back to nginx error log")
        logger = {
            log = function(...) return ngx.log(ngx.ERR, ...) end,
            flush = function() return end,
        }
    end
end

return logger