local strbyte = string.byte
local strsub = string.sub
local concat = table.concat

local spawn = ngx.thread.spawn
local wait = ngx.thread.wait

local S = require("server")
local C = require("client")

local COM_QUIT = 0x01


local function init(ip, port, proxy_port)
    local svr = S.new(ip, port)
    local conn = concat({ip, port, proxy_port or "-"}, ":")
    local cli = C.new(ngx.req.socket(true), ngx.var.remote_addr, conn)
    svr:init(cli)
    cli:init(svr)

    local header, packet, typ, err = svr:read()
    cli:write(header .. packet)
    return svr, cli
end


local function cli2svr(cli, svr)
    while true do
        local header, packet, err = cli:read()
        if not header then return err end
        local com = strbyte(packet)
        if com == COM_QUIT then
            svr:write(header .. packet)
            return
        end
        local qry = strsub(packet, 1, #packet)
        cli:log("query|" .. qry, true)
        svr:write(header .. packet)
    end
end


local function svr2cli(svr, cli)
    while true do
        local header, packet, err = svr:read()
        if not header then return err end
        cli:write(header .. packet)
    end
end


local M = { _VERSION = "0.01" }


function M.loop(ip, port, proxy_port)
    local svr, cli = init(ip, tonumber(port), proxy_port)
    cli:log("connected", true)

    local c2s = spawn(cli2svr, cli, svr)
    local s2c = spawn(svr2cli, svr, cli)

    local ok, res
    ok, res = wait(c2s)
    ok, res = wait(c2s)
    cli:log("disconnected", true)
end


return M
