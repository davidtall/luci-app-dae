local fs = require "nixio.fs"
local sys = require "luci.sys"
local m, s

m = Map("dae", translate("DAE"))
m.description = translate("A Linux high-performance transparent proxy solution based on eBPF.")

m:section(SimpleSection).template = "dae/dae_status"

-- Create directory structure if not exists
if not fs.stat("/etc/dae/config.d") then
    fs.mkdirr("/etc/dae/config.d")
end

-- Check if main config file exists, create if not
local main_file = "/etc/dae/config.dae"
if not fs.access(main_file) then
    fs.writefile(main_file, [[include {
    config.d/*.dae
}
global {
    tproxy_port: 12345

    log_level: warn

    tcp_check_url: 'http://cp.cloudflare.com'
    udp_check_dns: 'dns.google:53'
    check_interval: 600s
    check_tolerance: 50ms

    #lan_interface: eth0
    wan_interface: eth0
    allow_insecure: false

    dial_mode: domain
    disable_waiting_network: false
    enable_local_tcp_fast_redirect: false
    auto_config_kernel_parameter: true
    sniffing_timeout: 100ms
}]])
end

-- Check if config files exist, create if not
local config_files = {
    { path = "/etc/dae/config.d/dns.dae", content = [[dns {
    upstream {
        alidns: 'udp://dns.alidns.com:53'
        googledns: 'tcp+udp://dns.google:53'
    }

    routing {
        request {
            qname(geosite:category-ads) -> reject
            qname(geosite:category-ads-all) -> reject
            fallback: alidns
        }
        response {
            upstream(googledns) -> accept
            !qname(geosite:cn) && ip(geoip:private) -> googledns
            fallback: accept
        }
    }
}]]},
    { path = "/etc/dae/config.d/node.dae", content = [[node {
    node1: 'xxx'
    node2: 'xxx'
}

subscription {
    my_sub: 'https://www.example.com/subscription/link'
}

group {
    my_group {
        filter: subtag(my_sub) && !name(keyword: 'ExpireAt:')
        policy: min_moving_avg
    }

    local_group {
        filter: name(node1, node2)
        policy: fixed(0)
    }
}]]},
    { path = "/etc/dae/config.d/route.dae", content = [[routing {
    pname(NetworkManager) -> direct
    dip(224.0.0.0/3, 'ff00::/8') -> direct
    dip(geoip:private) -> direct

    dip(1.14.5.14) -> direct

    domain(geosite:openai) -> local_group
    dip(geoip:cn) -> direct
    domain(geosite:cn) -> direct
    domain(geosite:category-scholar-cn) -> direct
    domain(geosite:geolocation-cn) -> direct


    fallback: my_group
}]]}
}

for _, file_info in ipairs(config_files) do
    if not fs.access(file_info.path) then
        fs.writefile(file_info.path, file_info.content)
    end
end

-- Main configuration page with links to subpages
s = m:section(TypedSection, "dae")
s.addremove = false
s.anonymous = true

o = s:option(Flag, "enabled", translate("Enabled"))
o.rmempty = false

o = s:option(Button, "_reload", translate("Reload Service"), translate("Reload the service effective configuration file."))
o.write = function()
    sys.exec("/etc/init.d/dae hot_reload")
end

-- Links to subpages
o = s:option(DummyValue, "")
o.rawhtml = true
o.value = [[
<div style="margin: 10px 0;">
    <h3 style="margin-bottom: 10px;">]] .. translate("Configuration Sections") .. [[</h3>
    <ul style="list-style-type: none; padding-left: 0;">
        <li style="margin-bottom: 8px;">
            <a href="/cgi-bin/luci/admin/services/dae/global" class="btn btn-primary">]] .. translate("Global Settings") .. [[</a>
            <span style="margin-left: 10px;">]] .. translate("Configure global settings like ports and interfaces") .. [[</span>
        </li>
        <li style="margin-bottom: 8px;">
            <a href="/cgi-bin/luci/admin/services/dae/dns" class="btn btn-primary">]] .. translate("DNS Settings") .. [[</a>
            <span style="margin-left: 10px;">]] .. translate("Configure DNS upstreams and routing") .. [[</span>
        </li>
        <li style="margin-bottom: 8px;">
            <a href="/cgi-bin/luci/admin/services/dae/node" class="btn btn-primary">]] .. translate("Node Settings") .. [[</a>
            <span style="margin-left: 10px;">]] .. translate("Configure nodes and subscription groups") .. [[</span>
        </li>
        <li style="margin-bottom: 8px;">
            <a href="/cgi-bin/luci/admin/services/dae/route" class="btn btn-primary">]] .. translate("Routing Settings") .. [[</a>
            <span style="margin-left: 10px;">]] .. translate("Configure traffic routing rules") .. [[</span>
        </li>
    </ul>
</div>
]]

return m
