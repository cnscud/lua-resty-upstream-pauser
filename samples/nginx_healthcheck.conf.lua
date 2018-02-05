
    --- 下面的内容需要放在 init_worker_by_lua_block  里面 (此处是为了语法提示, 所以使用了单独文件)

    local hc = require "resty.upstream.healthcheck"

    local hostnamebyupstream = {
        ["web1"] = {"www.yourdomain.com"},
        ["img1"] = {"f1.yourdomain.cn", "/ping.txt"}
    }

    for k, v in pairs(hostnamebyupstream) do
        local myhost = v[1]
        local pingurl
        local reqstr

        if #v >1 then
            pingurl = v[2]
        else
            pingurl = "/ping/"
        end

        if myhost == nil then
            reqstr = "GET "..pingurl.." HTTP/1.0\r\n\r\n"
        else
            reqstr = "GET "..pingurl.." HTTP/1.0\r\nHost: "..myhost.."\r\n\r\n"
        end

        local ok, err = hc.spawn_checker{
            shm = "healthcheck",  -- defined by "lua_shared_dict"
            upstream = k, -- defined by "upstream"
            type = "http",
            http_req = reqstr,
            interval = 2000,  -- run the check cycle every 2 sec
            timeout = 1000,   -- 1 sec is the timeout for network operations
            fall = 3,  -- # of successive failures before turning a peer down
            rise = 2,  -- # of successive successes before turning a peer up
            valid_statuses = {    200, 302     },
            valid_response = "pong", -- check body
            concurrency = 10,  -- concurrency level for test requests
        }

        if not ok then
            ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
            return
        end
    end