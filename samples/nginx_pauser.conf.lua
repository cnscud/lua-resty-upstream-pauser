
    --- 下面的内容需要放在 init_worker_by_lua_block  里面 (此处是为了语法提示, 所以使用了单独文件)
    local upstream = require "ngx.upstream"
    local sync = require "resty.upstream.upstreampauser"
    local get_upstreams = upstream.get_upstreams

    local hostnamebyupstream = { "web1"}

    -- local us = get_upstreams()
    -- for _, u in ipairs(us) do --遍历所有upstream
    for _, u in hostnamebyupstream do
        local ok, err = sync.spawn_sync{
            shm = "healthcheck",  -- defined by "lua_shared_dict"
            upstream = u, -- defined by "upstream"
            interval = 2000,  -- run the check cycle every 2 sec
        }

        if not ok then
            ngx.log(ngx.ERR, "failed to spawn pauser sync: ", err)
            return
        end
    end

