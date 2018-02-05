# lua-resty-upstream-pauser
可以暂停/恢复 Upstream里的server, 方便发布, 也可协同healthcheck工作

# 参考
此类库大量参考了 healthcheck, 为了协同, 也提供了一个升级版的 healthcheck, 否则无法协同工作.

# 如何配置pauser
1. 配置相应upstream的timer, 详见 nginx_pauser.conf.lua
```    
    lua_package_path "/opt/conf/nginx/scripts/?.lua;;";

    lua_shared_dict healthcheck 5m;

    lua_socket_log_errors off;

    # init_worker_by_lua_block {
    # 请按需复制.
    # 请复制 nginx_healthcheck.timer.conf.lua 的内容到这里.
    # 请复制 nginx_pauser.timer.conf.lua 的内容到这里.
    # }
```
2. 配置Nginx的调用URL, 详见 nginx.samples.conf.nginx
```
    # 参数: upstream名字  server=ip:port status=要切换的状态: true/false
    location /upstream_pause {
        default_type 'text/plain';

        content_by_lua_block {
                local u = ngx.var.arg_upstream
                local server_ip = ngx.var.arg_ip
                local server_port = ngx.var.arg_port
                local pausestatus = ngx.var.arg_pause

                ngx.log(ngx.WARN, "info ", u, server_ip, server_port, tostatus)

                local up = require "resty.upstream.upstreampause"

                local ok, err = up.pause{
                    ip = server_ip, port = server_port, upstream = u, pause = pausestatus,
                    shm = "healthcheck" -- should same with health check now
                }

                if not ok then
                    ngx.say("failed to call upstream pause: " .. err)
                    return
                else
                    ngx.say("ok")
                end
        }
    }

```
3. 手工调用 或者集成发布系统

调用方法:
```
curl "http://192.168.6.99/upstream_pause/?upstream=web1&ip=192.168.6.22&port=8001&pause=true"   
curl "http://192.168.6.99/upstream_pause/?upstream=web1&ip=192.168.6.22&port=8001&pause=false"
```   
