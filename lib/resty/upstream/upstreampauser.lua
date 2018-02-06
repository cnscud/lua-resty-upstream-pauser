-- lua module for pause peer in nginx upstream (can work together with health check)
--
-- @author: felix zhang
-- @since: 2018/2/2 17:33
--

local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO
local DEBUG = ngx.DEBUG
local sub = string.sub
local re_find = ngx.re.find
local new_timer = ngx.timer.at
local shared = ngx.shared
local debug_mode = ngx.config.debug
local tonumber = tonumber
local tostring = tostring
local pcall = pcall
local worker = ngx.worker

local _M = {
    _VERSION = '0.02'
}

if not ngx.config
   or not ngx.config.ngx_lua_version
   or ngx.config.ngx_lua_version < 9005
then
    error("ngx_lua 0.9.5+ required")
end

local ok, upstream = pcall(require, "ngx.upstream")
if not ok then
    error("ngx_upstream_lua module required")
end

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function (narr, nrec) return {} end
end

local set_peer_down = upstream.set_peer_down
local get_primary_peers = upstream.get_primary_peers
local get_backup_peers = upstream.get_backup_peers


local key_prefix_version = "pv:" --for version of upstream
local key_prefix_pause = "pd:" -- for pause sign of peer
local key_prefix_lock = "pl:" -- for locker of upstream

local upstream_pauser_statuses = {}

local function warn(...)
    log(WARN, "pauser: ", ...)
end

local function errlog(...)
    log(ERR, "pauser: ", ...)
end

local function debug(...)
    -- print("debug mode: ", debug_mode)
    if debug_mode then
        log(DEBUG, "pauser: ", ...)
    end
end

local function debugme(...)
    log(INFO, "pauser: ", ...)
end

local function gen_peer_key(prefix, u, is_backup, id)
    if is_backup then
        return prefix .. u .. ":b" .. id
    end
    return prefix .. u .. ":p" .. id
end

--由外部调用设置了dict内的key, 所以此处不需要设置了 (和healthcheck的区别)
local function set_peer_down_globally(ctx, is_backup, id, value)
    local u = ctx.upstream

    debug("set peer down when set_peer_down_globally to --> ", tostring(value) , " by worker ", worker.pid())
    local ok, err = set_peer_down(u, is_backup, id, value)
    if not ok then
        errlog("failed to set peer down: ", err)
    end

    if not ctx.new_version then
        ctx.new_version = true
    end
end


-- 检查peer是否被通知暂停服务, 如果是, 则设置down
local function check_peer_pause(ctx, id, peer, is_backup)
    local dict = ctx.dict
    local u = ctx.upstream

    local key_d = gen_peer_key(key_prefix_pause, u, is_backup, peer.id)
    local res, err = dict:get(key_d)

    local update = false --是否变化了

    local down = false
    if res == nil then
        if err then
            errlog("failed to get peer down state: ", err)
        end
        -- 没有值, 不需要动作
        return
    else
        if res <=1 then
            update = true
        end
        if res ==1 or res ==11 then
            down = true
        end
    end

    -- 独立判断version变化了, 即使被别的timer改变了状态 (例如healthcheck)
    -- 如果没有变化, 则忽略了 (有可能被别的模块修改了状态, 但是此处也忽略了)
    if not update then
        return
    end

    -- 不判断, 直接进行处理. (有可能缓存状态和实际状态不一致)
    if down then
        warn("peer ", peer.name, " is turned --> down for pause command on upstream " , u, " by worker ", worker.pid())
    else
        warn("peer ", peer.name, " is turned --> up for pause command on upstream " , u, " by worker ", worker.pid())
    end

    peer.down = down
    set_peer_down_globally(ctx, is_backup, id, down)

    -- 标记已经处理过了, 避免重复处理
    if res <=1 then
        local update_value = res + 10
        local ok, err = dict:set(key_d, update_value)
        if not ok then
            errlog("failed to set peer pause_state to  " .. update_value .. " ", err)
        end

        -- 为了版本同步
        if not ctx.new_version then
            ctx.new_version = true
        end
    end

end


-- real check peer by socket
local function check_peer(ctx, id, peer, is_backup)
    check_peer_pause(ctx, id, peer, is_backup)
end


local function check_peers(ctx, peers, is_backup)
    local n = #peers
    if n == 0 then
        return
    end

    for i = 1, n do
        check_peer(ctx, i - 1, peers[i], is_backup)
    end
end

-- 发现版本变化时才执行, 所以不会每次执行的.
local function upgrade_peers_pause_version(ctx, peers, is_backup)
    local dict = ctx.dict
    local u = ctx.upstream
    local n = #peers
    for i = 1, n do
        local peer = peers[i]
        local id = i - 1
        local key = gen_peer_key(key_prefix_pause, u, is_backup, id)
        local down = false
        local res, err = dict:get(key)
        if not res then
            if err then
                errlog("failed to get peer down state: ", err)
            end
        else
            if res ==1 or res ==11 then
                down = true
            end

            -- 强制设置, 不判断当前状态
            warn("set peer down when upgrade pause version to --> ", tostring(down) , " on upstream ", u, " by worker ", worker.pid())
            local ok, err = set_peer_down(u, is_backup, id, down)
            if not ok then
                errlog("failed to set peer down: ", err)
            else
                -- update our cache too
                peer.down = down
            end
        end
    end
end

local function check_peers_updates(ctx)
    local dict = ctx.dict
    local u = ctx.upstream
    local key = key_prefix_version .. u
    local ver, err = dict:get(key)
    if not ver then
        if err then
            errlog("failed to get peers version: ", err)
            return
        end

        if ctx.version > 0 then
            ctx.new_version = true
        end

    elseif ctx.version < ver then -- 发现版本变化时才执行
        -- debug("upgrading peers pause version to ", ver)
        warn("upgrading peers pause version ", ctx.upstream, " version -> " , ver,  " by worker " , worker.pid() )
        upgrade_peers_pause_version(ctx, ctx.primary_peers, false);
        upgrade_peers_pause_version(ctx, ctx.backup_peers, true);
        ctx.version = ver
    end
end

local function get_lock(ctx)
    local dict = ctx.dict
    local key = key_prefix_lock .. ctx.upstream

    -- the lock is held for the whole interval to prevent multiple
    -- worker processes from sending the test request simultaneously.
    -- here we substract the lock expiration time by 1ms to prevent
    -- a race condition with the next timer event.
    local ok, err = dict:add(key, true, ctx.interval - 0.001)
    if not ok then
        if err == "exists" then
            return nil
        end
        errlog("failed to add key \"", key, "\": ", err)
        return nil
    end
    return true
end

local function do_check(ctx)
    debug("pauser: run a check cycle for upstream ", ctx.upstream, " version: " , ctx.version,  " by worker " , worker.pid() )

    check_peers_updates(ctx)

    if get_lock(ctx) then
        check_peers(ctx, ctx.primary_peers, false)
        check_peers(ctx, ctx.backup_peers, true)
    end

    if ctx.new_version then
        local key = key_prefix_version .. ctx.upstream
        local dict = ctx.dict

        if debug_mode then
            debug("publishing peers version ", ctx.version + 1)
        end

        dict:add(key, 0)
        local new_ver, err = dict:incr(key, 1)
        if not new_ver then
            errlog("failed to publish new peers version: ", err)
        end

        debug("set peers pause version ", ctx.upstream, " version -> " , new_ver,  " by worker " , worker.pid() )
        ctx.version = new_ver
        ctx.new_version = nil

    end
end

local function update_upstream_pauser_status(upstream, success)
    local cnt = upstream_pauser_statuses[upstream]
    if not cnt then
        cnt = 0
    end

    if success then
        cnt = cnt + 1
    else
        cnt = cnt - 1
    end

    upstream_pauser_statuses[upstream] = cnt
end


local check
check = function (premature, ctx)
    if premature then
        return
    end

    -- debug("here is check for upstream " , ctx.upstream, " version: " , ctx.version)

    local ok, err = pcall(do_check, ctx)
    if not ok then
        errlog("failed to run pause sync cycle: ", err)
    end

    local ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            errlog("failed to create timer: ", err)
        end

        update_upstream_pauser_status(ctx.upstream, false)
        return
    end
end

local function preprocess_peers(peers)
    local n = #peers
    for i = 1, n do
        local p = peers[i]
        local name = p.name

        if name then
            local from, to, err = re_find(name, [[^(.*):\d+$]], "jo", nil, 1)
            if from then
                p.host = sub(name, 1, to)
                p.port = tonumber(sub(name, to + 2))
            end
        end
    end
    return peers
end

-- 为啥一个一个设置哪: 灵活方便, 如果需要全部, 调用 upstream.get_upstreams() 遍历即可.
function _M.spawn_sync(opts)

    local interval = opts.interval
    if not interval then
        interval = 1
    else
        interval = interval / 1000
        if interval < 0.002 then  -- minimum 2ms
            interval = 0.002
        end
    end

    local shm = opts.shm
    if not shm then
        return nil, "\"shm\" option required"
    end

    local dict = shared[shm]
    if not dict then
        return nil, "shm \"" .. tostring(shm) .. "\" not found"
    end

    local u = opts.upstream
    if not u then
        return nil, "no upstream specified"
    end

    local ppeers, err = get_primary_peers(u)
    if not ppeers then
        return nil, "failed to get primary peers: " .. err
    end

    local bpeers, err = get_backup_peers(u)
    if not bpeers then
        return nil, "failed to get backup peers: " .. err
    end

    local ctx = {
        upstream = u,
        primary_peers = preprocess_peers(ppeers),
        backup_peers = preprocess_peers(bpeers),
        interval = interval,
        dict = dict,
        version = 0,
    }

    local ok, err = new_timer(0, check, ctx)
    if not ok then
        return nil, "failed to create timer: " .. err
    end

    ngx.log(ngx.INFO, "start pauser timer for " , u, " ...")

    update_upstream_pauser_status(u, true)
    return true
end


local function check_mark_peer_pause(dict, ckpeers, pausevalue, u, servername, is_backup)
    if ckpeers then
        local npeers = #ckpeers
        for i = 1, npeers do
            local peer = ckpeers[i]
            if peer.name == servername then
                local key_d = gen_peer_key(key_prefix_pause, u, is_backup, peer.id)
                local ok, err
                if pausevalue then
                    ok, err = dict:set(key_d, 1) -- 1 = init set , 11 = set and checked
                else
                    ok, err = dict:set(key_d, 0) -- 0 = normal peer, 10 = set and normal
                    -- ok, err = dict:delete(key_d) -- remove = normal peer
                end

                if not ok then
                    ngx.log(ngx.ERR, "failed set peer pause_status " .. peer.name .. " value: " .. tostring(pausevalue) .. " on upstream " .. u)
                    return -1, "failed on set peer pause_status"
                end

                ngx.log(ngx.ERR, "ok set peer pause_status " .. peer.name .. " value: " .. tostring(pausevalue) .. " on upstream " .. u)
                return 1, "ok on store peer pause_status"
            end
        end
    end
    -- not find the server, will find in next group (backup peers)
    return 0, ""
end

-- 命令: 调用此方法来使一个peer为暂停(down)的状态
function _M.pause(opts)

    local u = opts.upstream
    if not u then
        return nil, "\"upstream\" option required"
    end

    local server_ip = opts.ip
    if not server_ip then
        return nil, "\"ip\" option required"
    end

    local server_port = opts.port
    if not server_port then
        return nil, "\"port\" option required"
    end

    local tostatus = opts.pause

    local shm = opts.shm
    if not shm then
        return nil, "\"shm\" option required"
    end

    local dict = shared[shm]
    if not dict then
        return nil, "shm \"" .. tostring(shm) .. "\" not found"
    end

    local servername = server_ip .. ":" .. server_port
    local value = false
    if tostatus == "true" then
        value = true
    end

    -- 如果没有timer 则应该警告
    local ncheckers = upstream_pauser_statuses[u]
    if not ncheckers or ncheckers == 0 then
        return nil, "not find pauser time for the upstream " ..u
    end


    local ppeers, err = get_primary_peers(u)
    local ret, err = check_mark_peer_pause(dict, ppeers, value, u, servername, false)
    if ret ~=0 then
        if ret ==1 then
            return true
        else
            return nil, err
        end
    end

    local bpeers, err = get_backup_peers(u)
    local ret, err = check_mark_peer_pause(dict, bpeers, value, u, servername, true)
    if ret ~=0 then
        if ret ==1 then
            return true
        else
            return nil, err
        end
    end

    ngx.log(ngx.ERR, "not find your server" .. servername .. " on upstream " .. u)
    return nil, "not find your server to mark"
end


return _M
