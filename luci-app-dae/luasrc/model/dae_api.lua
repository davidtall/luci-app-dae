local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local jsonc = require "luci.jsonc"

local M = {}

local FILES = {
    global = "/etc/dae/config.dae",
    dns = "/etc/dae/config.d/dns.dae",
    node = "/etc/dae/config.d/node.dae",
    routing = "/etc/dae/config.d/route.dae"
}

local FILE_ORDER = { "global", "dns", "node", "routing" }
local PERSIST_DIR = "/etc/dae/persist.d"
local SUBSCRIPTION_CACHE_DIR = "/tmp/luci-dae-subscriptions"
local VALID_POLICIES = {
    min_moving_avg = true,
    min_avg10 = true,
    min = true,
    random = true,
    fixed = true
}

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local DAE_VERSION = trim(sys.exec("dae --version 2>/dev/null | head -n 1"):match("version%s+(.+)$") or "unknown")

local function read_file(path)
    return fs.readfile(path) or ""
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_LOOKUP = {}
for index = 1, #BASE64_ALPHABET do
    BASE64_LOOKUP[BASE64_ALPHABET:sub(index, index)] = index - 1
end

local function base64_decode(value)
    local data = tostring(value or ""):gsub("%s+", ""):gsub("-", "+"):gsub("_", "/")
    if data == "" then return "" end
    local remainder = #data % 4
    if remainder == 1 then return nil end
    if remainder > 0 then data = data .. string.rep("=", 4 - remainder) end

    local output = {}
    for index = 1, #data, 4 do
        local a = BASE64_LOOKUP[data:sub(index, index)]
        local b = BASE64_LOOKUP[data:sub(index + 1, index + 1)]
        local cchar = data:sub(index + 2, index + 2)
        local dchar = data:sub(index + 3, index + 3)
        local c = cchar == "=" and 0 or BASE64_LOOKUP[cchar]
        local d = dchar == "=" and 0 or BASE64_LOOKUP[dchar]
        if a == nil or b == nil or c == nil or d == nil then return nil end
        local number = a * 262144 + b * 4096 + c * 64 + d
        output[#output + 1] = string.char(math.floor(number / 65536) % 256)
        if cchar ~= "=" then output[#output + 1] = string.char(math.floor(number / 256) % 256) end
        if dchar ~= "=" then output[#output + 1] = string.char(number % 256) end
    end
    return table.concat(output)
end

local function base64_url_encode(value)
    local data = tostring(value or "")
    local output = {}
    for index = 1, #data, 3 do
        local a = data:byte(index) or 0
        local b = data:byte(index + 1) or 0
        local c = data:byte(index + 2) or 0
        local number = a * 65536 + b * 256 + c
        output[#output + 1] = BASE64_ALPHABET:sub(math.floor(number / 262144) % 64 + 1, math.floor(number / 262144) % 64 + 1)
        output[#output + 1] = BASE64_ALPHABET:sub(math.floor(number / 4096) % 64 + 1, math.floor(number / 4096) % 64 + 1)
        output[#output + 1] = index + 1 <= #data and BASE64_ALPHABET:sub(math.floor(number / 64) % 64 + 1, math.floor(number / 64) % 64 + 1) or "="
        output[#output + 1] = index + 2 <= #data and BASE64_ALPHABET:sub(number % 64 + 1, number % 64 + 1) or "="
    end
    return table.concat(output):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
end

local function stable_hash(value)
    local first, second = 5381, 52711
    for index = 1, #value do
        local byte = value:byte(index)
        first = (first * 33 + byte) % 2147483647
        second = (second * 131 + byte) % 2147483647
    end
    return string.format("%08x%08x", math.floor(first), math.floor(second))
end

local function normalize_subscription_link(link)
    link = trim(link)
    if link:match("^https://") then return "https-file://" .. link:sub(9) end
    if link:match("^http://") then return "http-file://" .. link:sub(8) end
    return link
end

local function remote_subscription_link(link)
    if link:match("^https%-file://") then return "https://" .. link:sub(14) end
    if link:match("^http%-file://") then return "http://" .. link:sub(13) end
    if link:match("^https?://") then return link end
    return nil
end

local function is_persist_subscription_link(link)
    return link:match("^https%-file://") ~= nil or link:match("^http%-file://") ~= nil
end

local function subscription_cache_path(id, link)
    return SUBSCRIPTION_CACHE_DIR .. "/" .. stable_hash(id .. "\n" .. normalize_subscription_link(link)) .. ".sub"
end

local function subscription_persist_path(id)
    if type(id) ~= "string" or not id:match("^[%w_.%-]+$") then return nil end
    return PERSIST_DIR .. "/" .. id .. ".sub"
end

local function current_revision()
    local command = "sha256sum"
    for _, key in ipairs(FILE_ORDER) do
        command = command .. " " .. shell_quote(FILES[key])
    end
    command = command .. " 2>/dev/null | sha256sum | cut -d' ' -f1"
    return trim(sys.exec(command))
end

local function read_files()
    local result = {}
    for _, key in ipairs(FILE_ORDER) do
        result[key] = {
            path = FILES[key],
            content = read_file(FILES[key])
        }
    end
    return result
end

local function find_block(text, name, from)
    local start_at = from or 1
    local block_start, open_brace
    local pattern = "%f[%w_]" .. name:gsub("([^%w_])", "%%%1") .. "%s*{"
    block_start = text:find(pattern, start_at)
    if not block_start then
        return nil
    end
    open_brace = text:find("{", block_start, true)
    if not open_brace then
        return nil
    end

    local depth = 0
    local quote = nil
    local escaped = false
    for index = open_brace, #text do
        local char = text:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == "{" then
            depth = depth + 1
        elseif char == "}" then
            depth = depth - 1
            if depth == 0 then
                return text:sub(open_brace + 1, index - 1), block_start, index
            end
        end
    end
    return nil
end

local function parse_scalar(value)
    value = trim(value):gsub("%s+#.*$", "")
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end
    local quoted = value:match("^'(.*)'$") or value:match('^"(.*)"$')
    if quoted ~= nil then
        return quoted
    end
    return value
end

local function parse_global(content)
    local block = find_block(content, "global")
    local result = {}
    if not block then
        return result
    end
    for line in block:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*:%s*(.-)%s*$")
        if key and value and value ~= "" and not key:match("^#") then
            result[key] = parse_scalar(value)
        end
    end
    return result
end

local function parse_keyable_strings(content, block_name)
    local block = find_block(content, block_name)
    local result = {}
    if not block then
        return result
    end
    for line in block:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") then
            local key, value = line:match("^%s*([%w_.%-]+)%s*:%s*'(.*)'%s*$")
            if not key then
                key, value = line:match('^%s*([%w_.%-]+)%s*:%s*"(.*)"%s*$')
            end
            if key and value then
                result[#result + 1] = { id = key, tag = key, link = value }
            end
        end
    end
    return result
end

local function split_csv(value)
    local result = {}
    for part in (value or ""):gmatch("[^,]+") do
        local item = trim(part):gsub("^['\"]", ""):gsub("['\"]$", "")
        if item ~= "" then
            result[#result + 1] = item
        end
    end
    return result
end

local function link_metadata(item, source)
    local protocol = item.link:match("^([%w+.-]+)://") or "unknown"
    local address = item.link:match("@(%[[^%]]+%]:%d+)") or
        item.link:match("@([^/?#]+)") or
        item.link:match("^[%w+.-]+://(%[[^%]]+%]:%d+)") or
        item.link:match("^[%w+.-]+://([^/?#]+)") or ""
    local fragment = item.link:match("#([^#]+)$")

    if protocol:lower() == "vmess" then
        local decoded = base64_decode(item.link:match("^vmess://([^#]+)") or "")
        local config = decoded and jsonc.parse(decoded) or nil
        if type(config) == "table" then
            address = tostring(config.add or "")
            if config.port and tostring(config.port) ~= "" then address = address .. ":" .. tostring(config.port) end
            fragment = config.ps and http.urlencode(tostring(config.ps)) or fragment
        end
    elseif protocol:lower() == "ssr" then
        local decoded = base64_decode(item.link:match("^ssr://([^#]+)") or "") or ""
        local main, query = decoded:match("^(.-)/%?(.*)$")
        main = main or decoded
        local host, port = main:match("^([^:]+):([^:]+):")
        if host then address = host .. ":" .. tostring(port or "") end
        local remarks = query and query:match("remarks=([^&]+)")
        local decoded_remarks = remarks and base64_decode(http.urldecode(remarks)) or nil
        if decoded_remarks and decoded_remarks ~= "" then fragment = http.urlencode(decoded_remarks) end
    end

    item.protocol = protocol:lower()
    item.address = address
    item.name = fragment and http.urldecode(fragment) or item.tag
    item.source = source
    return item
end

local function quote_host(host)
    if host:find(":", 1, true) and not host:match("^%[.*%]$") then return "[" .. host .. "]" end
    return host
end

local function resolve_subscription_links(content)
    local sip = jsonc.parse(content)
    if type(sip) == "table" and tonumber(sip.version) == 1 and type(sip.servers) == "table" then
        local links = {}
        for _, server in ipairs(sip.servers) do
            if type(server) == "table" and server.server and server.server_port and server.method and server.password then
                local userinfo = base64_url_encode(tostring(server.method) .. ":" .. tostring(server.password))
                local link = "ss://" .. userinfo .. "@" .. quote_host(tostring(server.server)) .. ":" .. tostring(server.server_port)
                if server.plugin_opts and tostring(server.plugin_opts) ~= "" then
                    link = link .. "?plugin=" .. http.urlencode(tostring(server.plugin_opts))
                end
                if server.remarks and tostring(server.remarks) ~= "" then
                    link = link .. "#" .. http.urlencode(tostring(server.remarks))
                end
                links[#links + 1] = link
            end
        end
        if #links > 0 then return links end
    end

    local decoded = base64_decode(content)
    if not decoded then return nil, "订阅内容不是有效的 SIP008 或 Base64" end
    local links = {}
    for line in decoded:gmatch("[^\r\n]+") do
        line = trim(line)
        if line:match("^[%w+.-]+://.+") then links[#links + 1] = line end
    end
    if #links == 0 then return nil, "订阅中没有可识别的节点" end
    return links
end

local function subscription_preview(id, link, path, source)
    if not path or not fs.access(path) then
        return {
            id = id,
            tag = id,
            name = id,
            link = link,
            source = "subscription",
            previewAvailable = false,
            previewSource = "missing",
            status = "尚未拉取",
            nodes = {}
        }
    end

    local content = read_file(path)
    local links, resolve_error = resolve_subscription_links(content)
    local stat = fs.stat(path)
    local subscription = {
        id = id,
        tag = id,
        name = id,
        link = link,
        source = "subscription",
        previewAvailable = links ~= nil,
        previewSource = source,
        status = links and "已解析" or "解析失败",
        previewError = resolve_error,
        updatedAt = stat and stat.mtime or nil,
        nodes = {}
    }
    for index, node_link in ipairs(links or {}) do
        local node = link_metadata({
            id = id .. "::" .. stable_hash(node_link),
            tag = id .. "-" .. tostring(index),
            link = node_link,
            subscriptionId = id
        }, "subscription")
        subscription.nodes[#subscription.nodes + 1] = node
    end
    return subscription
end

local function attach_subscription_preview(subscription)
    local cache_path = subscription_cache_path(subscription.id, subscription.link)
    local persist_path = subscription_persist_path(subscription.id)
    local preview
    if fs.access(cache_path) then
        preview = subscription_preview(subscription.id, subscription.link, cache_path, "temporary")
    elseif persist_path and fs.access(persist_path) then
        preview = subscription_preview(subscription.id, subscription.link, persist_path, "persist")
    else
        preview = subscription_preview(subscription.id, subscription.link)
    end
    for key, value in pairs(preview) do subscription[key] = value end
    return subscription
end

local function exact_subscription_node_name(filter)
    if not filter:match("subtag%s*%(") then return nil end
    local _, open_end = filter:find("name%s*%(%s*")
    if not open_end then return nil end
    local remainder = filter:sub(open_end + 1)
    if remainder:match("^regex%s*:") or remainder:match("^keyword%s*:") then return nil end

    local quote = remainder:sub(1, 1)
    if quote == "'" or quote == '"' then
        local output = {}
        local escaped = false
        for index = 2, #remainder do
            local char = remainder:sub(index, index)
            if escaped then
                output[#output + 1] = char
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                if remainder:sub(index + 1):match("^%s*%)") then return table.concat(output) end
                return nil
            else
                output[#output + 1] = char
            end
        end
        return nil
    end

    local plain = trim(remainder:match("^([^,%)]+)%s*%)") or "")
    return plain ~= "" and plain or nil
end

local function parse_named_blocks(parent)
    local result = {}
    local cursor = 1
    while cursor <= #parent do
        local name_start, name_end, name = parent:find("([%w_.%-]+)%s*{", cursor)
        if not name_start then
            break
        end
        local body, _, block_end = find_block(parent, name, name_start)
        if body and block_end then
            result[#result + 1] = { name = name, body = body }
            cursor = block_end + 1
        else
            cursor = name_end + 1
        end
    end
    return result
end

local function parse_groups(content)
    local group_block = find_block(content, "group")
    local result = {}
    if not group_block then
        return result
    end

    for _, entry in ipairs(parse_named_blocks(group_block)) do
        local group = {
            id = entry.name,
            name = entry.name,
            policy = "min_moving_avg",
            fixedIndex = nil,
            nodeIds = {},
            subscriptions = {},
            subscriptionNodes = {},
            filters = {}
        }

        local policy = trim(entry.body:match("%f[%w]policy%s*:%s*([^\r\n#]+)") or "")
        if policy ~= "" then
            local policy_name, policy_args = policy:match("^([%w_]+)%s*%((.*)%)$")
            group.policy = policy_name or policy
            if group.policy == "fixed" then
                group.fixedIndex = tonumber(trim(policy_args or "")) or 0
            end
        end

        for line in entry.body:gmatch("[^\r\n]+") do
            local filter = trim(line:match("^%s*filter%s*:%s*(.-)%s*$"))
            if filter and filter ~= "" and not filter:match("^#") then
                group.filters[#group.filters + 1] = filter
                local subscription_id = trim(filter:match("subtag%s*%((.-)%)") or "")
                if subscription_id ~= "" then
                    subscription_id = subscription_id:gsub("^['\"]", ""):gsub("['\"]$", "")
                end
                local name_args = filter:match("^name%s*%((.-)%)$")
                if subscription_id == "" and name_args and not name_args:match("%f[%w_]regex%s*:") and not name_args:match("%f[%w_]keyword%s*:") then
                    for _, node_id in ipairs(split_csv(name_args)) do
                        group.nodeIds[#group.nodeIds + 1] = node_id
                    end
                end
                if subscription_id ~= "" then
                    local exact_name = exact_subscription_node_name(filter)
                    local regex = filter:match("name%s*%(%s*regex%s*:%s*'(.-)'%s*%)") or
                        filter:match('name%s*%(%s*regex%s*:%s*"(.-)"%s*%)')
                    if exact_name then
                        group.subscriptionNodes[#group.subscriptionNodes + 1] = {
                            id = filter,
                            filterId = filter,
                            subscriptionId = subscription_id,
                            nodeName = exact_name
                        }
                    else
                        group.subscriptions[#group.subscriptions + 1] = {
                            id = filter,
                            filterId = filter,
                            subscriptionId = subscription_id,
                            nameFilterRegex = regex
                        }
                    end
                end
            end
        end
        result[#result + 1] = group
    end
    return result
end

local function parse_dns(content)
    local dns_block = find_block(content, "dns") or ""
    local upstream_block = find_block(dns_block, "upstream") or ""
    local request_block = find_block(dns_block, "request") or ""
    local response_block = find_block(dns_block, "response") or ""
    local upstreams = parse_keyable_strings("upstream {" .. upstream_block .. "}", "upstream")
    local function rules(block)
        local result = {}
        for line in block:gmatch("[^\r\n]+") do
            local rule = trim(line)
            if rule ~= "" and not rule:match("^#") and (rule:find("%->") or rule:match("^fallback%s*:")) then
                result[#result + 1] = rule
            end
        end
        return result
    end
    return { upstreams = upstreams, requestRules = rules(request_block), responseRules = rules(response_block) }
end

local function parse_routing(content)
    local block = find_block(content, "routing") or ""
    local rules = {}
    local fallback = nil
    for line in block:gmatch("[^\r\n]+") do
        local rule = trim(line)
        if rule ~= "" and not rule:match("^#") then
            if rule:find("%->") or rule:match("^fallback%s*:") then
                rules[#rules + 1] = rule
            end
            local value = rule:match("^fallback%s*:%s*(.+)$")
            if value then
                fallback = trim(value)
            end
        end
    end
    return { rules = rules, fallback = fallback }
end

local function service_state()
    local pid = trim(sys.exec("pidof dae | cut -d' ' -f1"))
    local memory_kb = nil
    if pid ~= "" then
        local status = read_file("/proc/" .. pid .. "/status")
        memory_kb = tonumber(status:match("VmRSS:%s+(%d+)%s+kB"))
    end
    return {
        enabled = uci:get("dae", "config", "enabled") == "1",
        running = pid ~= "",
        pid = pid ~= "" and tonumber(pid) or nil,
        memoryKb = memory_kb,
        version = trim(sys.exec("dae --version 2>/dev/null | head -n 1"))
    }
end

local function settings_state()
    return {
        enabled = uci:get("dae", "config", "enabled") == "1",
        configFile = uci:get("dae", "config", "config_file") or FILES.global,
        logMaxBackups = uci:get("dae", "config", "log_maxbackups") or "10",
        logMaxSize = uci:get("dae", "config", "log_maxsize") or "10",
        subscribeAutoUpdate = uci:get("dae", "config", "subscribe_auto_update") == "1",
        subscribeUpdateWeekTime = uci:get("dae", "config", "subscribe_update_week_time") or "*",
        subscribeUpdateDayTime = uci:get("dae", "config", "subscribe_update_day_time") or "0"
    }
end

local function state_from_contents(contents, revision, dirty)
    local files = {}
    for _, key in ipairs(FILE_ORDER) do
        files[key] = {
            path = FILES[key],
            content = contents[key] or ""
        }
    end

    local nodes = parse_keyable_strings(contents.node, "node")
    local subscriptions = parse_keyable_strings(contents.node, "subscription")
    for _, node in ipairs(nodes) do
        link_metadata(node, "manual")
    end
    for _, subscription in ipairs(subscriptions) do
        link_metadata(subscription, "subscription")
        attach_subscription_preview(subscription)
    end

    return {
        ok = true,
        revision = revision,
        dirty = dirty == true,
        service = service_state(),
        settings = settings_state(),
        files = files,
        resources = {
            global = parse_global(contents.global),
            dns = parse_dns(contents.dns),
            routing = parse_routing(contents.routing),
            nodes = nodes,
            subscriptions = subscriptions,
            groups = parse_groups(contents.node)
        },
        warnings = {
            "Subscription node previews are unavailable when reading plain dae configuration files."
        }
    }
end

function M.get_state()
    local files = read_files()
    local contents = {}
    for _, key in ipairs(FILE_ORDER) do
        contents[key] = files[key].content
    end
    return state_from_contents(contents, current_revision(), false)
end

local function remove_tree(path)
    local stat = fs.stat(path)
    if not stat then
        return
    end
    if stat.type == "dir" then
        for name in fs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        fs.rmdir(path)
    else
        fs.remove(path)
    end
end

local function snapshot_contents(payload)
    local current = read_files()
    local result = {}
    payload = payload or {}
    local requested = payload.files or {}
    for _, key in ipairs(FILE_ORDER) do
        local value = requested[key]
        if type(value) == "table" then
            value = value.content
        end
        result[key] = type(value) == "string" and value:gsub("\r\n?", "\n") or current[key].content
    end
    return result
end

local function prepare_subscription_persist(node_content, target_root)
    local subscriptions = parse_keyable_strings(node_content, "subscription")
    local target_dir = target_root .. "/persist.d"
    local created = false
    for _, subscription in ipairs(subscriptions) do
        if is_persist_subscription_link(subscription.link) then
            local cache_path = subscription_cache_path(subscription.id, subscription.link)
            local persist_path = subscription_persist_path(subscription.id)
            local source_path = fs.access(cache_path) and cache_path or
                (persist_path and fs.access(persist_path) and persist_path or nil)
            if source_path then
                if not created then
                    if not fs.mkdir(target_dir) then return nil, "Unable to create validation subscription cache" end
                    fs.chmod(target_dir, "0700")
                    created = true
                end
                local target_path = target_dir .. "/" .. subscription.id .. ".sub"
                if not fs.copy(source_path, target_path) then return nil, "Unable to prepare subscription cache" end
                fs.chmod(target_path, "0600")
            end
        end
    end
    return true
end

local function validate_contents(contents)
    local temp_root = string.format("/tmp/luci-dae-api-%d-%d", nixio.getpid(), os.time())
    local output_path = temp_root .. "/validate.log"
    fs.mkdir(temp_root)
    fs.mkdir(temp_root .. "/config.d")
    local ok = fs.writefile(temp_root .. "/config.dae", contents.global) and
        fs.writefile(temp_root .. "/config.d/dns.dae", contents.dns) and
        fs.writefile(temp_root .. "/config.d/node.dae", contents.node) and
        fs.writefile(temp_root .. "/config.d/route.dae", contents.routing)
    if not ok then
        remove_tree(temp_root)
        return false, "Unable to create validation snapshot", 1
    end
    fs.chmod(temp_root .. "/config.dae", "0640")
    fs.chmod(temp_root .. "/config.d/dns.dae", "0640")
    fs.chmod(temp_root .. "/config.d/node.dae", "0640")
    fs.chmod(temp_root .. "/config.d/route.dae", "0640")
    local cache_ok, cache_error = prepare_subscription_persist(contents.node, temp_root)
    if not cache_ok then
        remove_tree(temp_root)
        return false, cache_error, 1
    end
    local command = "cd " .. shell_quote(temp_root) .. " && dae validate -c " ..
        shell_quote(temp_root .. "/config.dae") .. " >" .. shell_quote(output_path) .. " 2>&1"
    local code = sys.call(command)
    local output = read_file(output_path)
    remove_tree(temp_root)
    return code == 0, output, code
end

function M.validate(payload)
    local contents = snapshot_contents(payload)
    local valid, output, code = validate_contents(contents)
    return {
        ok = valid,
        valid = valid,
        output = output,
        exitCode = code
    }, valid and 200 or 422
end

function M.preview(payload)
    payload = payload or {}
    local revision = current_revision()
    if payload.revision and payload.revision ~= revision then
        return {
            ok = false,
            error = {
                code = "REVISION_CONFLICT",
                message = "Configuration changed outside the Dashboard. Reload before continuing."
            },
            revision = revision
        }, 409
    end

    local contents = snapshot_contents(payload)
    if payload.validate == false then
        return state_from_contents(contents, revision, true), 200
    end
    local valid, output, code = validate_contents(contents)
    if not valid then
        return { ok = false, valid = false, output = output, exitCode = code }, 422
    end
    return state_from_contents(contents, revision, true), 200
end

local function fetch_subscription_to_cache(id, link)
    local remote_link = remote_subscription_link(link)
    if not remote_link then return nil, "只支持 http、https、http-file 和 https-file 订阅" end

    if not fs.access(SUBSCRIPTION_CACHE_DIR) then
        if not fs.mkdir(SUBSCRIPTION_CACHE_DIR) then return nil, "无法创建订阅临时目录" end
        fs.chmod(SUBSCRIPTION_CACHE_DIR, "0700")
    end

    local cache_path = subscription_cache_path(id, link)
    local download_path = string.format("%s.download.%d", cache_path, nixio.getpid())
    local log_path = string.format("%s.log.%d", cache_path, nixio.getpid())
	local user_agent = string.format(
		"dae/%s (like v2rayA/1.0 WebRequestHelper) (like v2rayN/1.0 WebRequestHelper)",
		DAE_VERSION
	)
    local command = "curl --fail --location --silent --show-error" ..
        " --connect-timeout 10 --max-time 30 --max-filesize 10485760" ..
        " --proto " .. shell_quote("=http,https") ..
        " --user-agent " .. shell_quote(user_agent) ..
        " --output " .. shell_quote(download_path) ..
        " " .. shell_quote(remote_link) ..
        " >" .. shell_quote(log_path) .. " 2>&1"
    local code = sys.call(command)
    local output = trim(read_file(log_path))
    fs.remove(log_path)
    if code ~= 0 then
        fs.remove(download_path)
        return nil, output ~= "" and output or "curl 拉取订阅失败"
    end

    local stat = fs.stat(download_path)
    if not stat or stat.size == 0 then
        fs.remove(download_path)
        return nil, "订阅返回内容为空"
    end
    if stat.size > 10485760 then
        fs.remove(download_path)
        return nil, "订阅内容超过 10MB 限制"
    end
    fs.chmod(download_path, "0600")
    if not fs.rename(download_path, cache_path) then
        fs.remove(download_path)
        return nil, "无法安装订阅临时缓存"
    end
    return cache_path
end

function M.resolve_subscription(payload)
    payload = payload or {}
    local id = trim(payload.id)
    local link = normalize_subscription_link(payload.link)
    if not id:match("^[%w_.%-]+$") or link == "" then
        return { ok = false, error = { code = "INVALID_SUBSCRIPTION", message = "订阅标签和地址无效" } }, 400
    end

    local cache_path = subscription_cache_path(id, link)
    local persist_path = subscription_persist_path(id)
    local selected_path, source
    if payload.force ~= true and fs.access(cache_path) then
        selected_path, source = cache_path, "temporary"
    elseif payload.force ~= true and persist_path and fs.access(persist_path) then
        selected_path, source = persist_path, "persist"
    else
        local fetch_error
        selected_path, fetch_error = fetch_subscription_to_cache(id, link)
        if selected_path then
            source = "remote"
        elseif persist_path and fs.access(persist_path) then
            local fallback = subscription_preview(id, link, persist_path, "persist")
            fallback.status = "远程拉取失败，使用持久缓存"
            fallback.previewError = fetch_error
            return { ok = true, subscription = fallback }, 200
        else
            return { ok = false, error = { code = "SUBSCRIPTION_FETCH_FAILED", message = fetch_error } }, 502
        end
    end

    local subscription = subscription_preview(id, link, selected_path, source)
    if not subscription.previewAvailable then
        return { ok = false, error = { code = "SUBSCRIPTION_PARSE_FAILED", message = subscription.previewError } }, 422
    end
    return { ok = true, subscription = subscription }, 200
end

local function update_settings(settings)
    if type(settings) ~= "table" then
        return true
    end
    local values = {
        enabled = settings.enabled ~= nil and (settings.enabled and "1" or "0") or nil,
        config_file = settings.configFile,
        log_maxbackups = settings.logMaxBackups,
        log_maxsize = settings.logMaxSize,
        subscribe_auto_update = settings.subscribeAutoUpdate ~= nil and (settings.subscribeAutoUpdate and "1" or "0") or nil,
        subscribe_update_week_time = settings.subscribeUpdateWeekTime,
        subscribe_update_day_time = settings.subscribeUpdateDayTime
    }
    for key, value in pairs(values) do
        if value ~= nil then
            uci:set("dae", "config", key, tostring(value))
        end
    end
    return uci:commit("dae")
end

local function write_snapshot(contents)
    local pid = nixio.getpid()
    local staged = {}
    local rollback_root = string.format("/tmp/luci-dae-write-%d-%d", pid, os.time())
    local originals = {}

    fs.mkdir(rollback_root)

    for _, key in ipairs(FILE_ORDER) do
        local path = FILES[key]
        local temp_path = string.format("%s.luci-dae.%d.tmp", path, pid)
        if not fs.writefile(temp_path, contents[key]) then
            for _, item in pairs(staged) do fs.remove(item) end
            remove_tree(rollback_root)
            return nil, "Unable to stage " .. path
        end
        fs.chmod(temp_path, "0640")
        staged[key] = temp_path

        if fs.access(path) then
            local rollback_path = rollback_root .. "/" .. key
            if not fs.copy(path, rollback_path) then
                for _, item in pairs(staged) do fs.remove(item) end
                remove_tree(rollback_root)
                return nil, "Unable to prepare rollback for " .. path
            end
            originals[key] = rollback_path
        end
    end

    local installed = {}
    for _, key in ipairs(FILE_ORDER) do
        if not fs.rename(staged[key], FILES[key]) then
            for _, installed_key in ipairs(installed) do
                if originals[installed_key] then
                    fs.copy(originals[installed_key], FILES[installed_key])
                else
                    fs.remove(FILES[installed_key])
                end
            end
            for _, item in pairs(staged) do fs.remove(item) end
            remove_tree(rollback_root)
            return nil, "Unable to install " .. FILES[key]
        end
        installed[#installed + 1] = key
    end
    remove_tree(rollback_root)
    return true
end

local function promote_subscription_caches(node_content)
    local subscriptions = parse_keyable_strings(node_content, "subscription")
    local has_cache = false
    for _, subscription in ipairs(subscriptions) do
        if is_persist_subscription_link(subscription.link) and fs.access(subscription_cache_path(subscription.id, subscription.link)) then
            has_cache = true
            break
        end
    end
    if not has_cache then return true end

    if not fs.access(PERSIST_DIR) then
        if not fs.mkdir(PERSIST_DIR) then return nil, "无法创建 " .. PERSIST_DIR end
    end
    fs.chmod(PERSIST_DIR, "0700")

    for _, subscription in ipairs(subscriptions) do
        local cache_path = subscription_cache_path(subscription.id, subscription.link)
        local persist_path = subscription_persist_path(subscription.id)
        if persist_path and is_persist_subscription_link(subscription.link) and fs.access(cache_path) then
            local temp_path = string.format("%s.luci-dae.%d.tmp", persist_path, nixio.getpid())
            if not fs.copy(cache_path, temp_path) then return nil, "无法暂存订阅缓存 " .. subscription.id end
            fs.chmod(temp_path, "0600")
            if not fs.rename(temp_path, persist_path) then
                fs.remove(temp_path)
                return nil, "无法安装订阅缓存 " .. subscription.id
            end
            fs.remove(cache_path)
        end
    end
    return true
end

function M.save(payload, apply)
    payload = payload or {}
    local revision = current_revision()
    if payload.revision and payload.revision ~= revision then
        return {
            ok = false,
            error = {
                code = "REVISION_CONFLICT",
                message = "Configuration changed outside the Dashboard. Reload before saving."
            },
            revision = revision
        }, 409
    end

    local contents = snapshot_contents(payload)
    local valid, output, code = validate_contents(contents)
    if not valid then
        return { ok = false, valid = false, output = output, exitCode = code }, 422
    end

    local written, write_error = write_snapshot(contents)
    if not written then
        return { ok = false, error = { code = "WRITE_FAILED", message = write_error } }, 500
    end
    local promoted, promote_error = promote_subscription_caches(contents.node)
    if not promoted then
        return { ok = false, saved = true, error = { code = "SUBSCRIPTION_CACHE_FAILED", message = promote_error } }, 500
    end
    if not update_settings(payload.settings) then
        return { ok = false, saved = true, error = { code = "UCI_COMMIT_FAILED", message = "Files were saved but UCI settings could not be committed." } }, 500
    end

    local service = service_state()
    local action = "none"
    local service_output = ""
    local service_code = 0
    if apply then
        if service.enabled then
            if service.running then
                action = "reload"
                service_code = sys.call("/etc/init.d/dae hot_reload >/tmp/luci-dae-service.log 2>&1")
            else
                action = "start"
                service_code = sys.call("/etc/init.d/dae start >/tmp/luci-dae-service.log 2>&1")
            end
        else
            action = "stop"
            service_code = sys.call("/etc/init.d/dae stop >/tmp/luci-dae-service.log 2>&1")
        end
        service_output = read_file("/tmp/luci-dae-service.log")
        fs.remove("/tmp/luci-dae-service.log")
    end

    local response = {
        ok = service_code == 0,
        valid = true,
        saved = true,
        applied = apply and service_code == 0 or false,
        revision = current_revision(),
        validationOutput = output,
        service = service_state(),
        serviceAction = action,
        serviceOutput = service_output
    }
    if service_code ~= 0 then
        response.error = { code = "SERVICE_ACTION_FAILED", message = "Configuration was saved, but the service action failed." }
        return response, 500
    end
    return response, 200
end

function M.reload()
	local log_path = string.format("/tmp/luci-dae-reload.%d.log", nixio.getpid())
	local code = sys.call("/etc/init.d/dae hot_reload >" .. shell_quote(log_path) .. " 2>&1")
	local output = trim(read_file(log_path))
	fs.remove(log_path)
	return {
		ok = code == 0,
		serviceAction = "reload",
		requested = code == 0,
		serviceOutput = output
	}, code == 0 and 200 or 500
end

local function valid_identifier(value)
    return type(value) == "string" and value:match("^[%w_.%-]+$") ~= nil
end

local function quote_dae(value)
    return "'" .. tostring(value or ""):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

local function find_by_id(items, id)
    for index, item in ipairs(items) do
        if item.id == id then
            return item, index
        end
    end
end

local function filter_subscription_id(filter)
    local value = filter:match("subtag%s*%(%s*([^%)]+)%s*%)")
    if not value then
        return nil
    end
    return trim(value):gsub("^['\"]", ""):gsub("['\"]$", "")
end

local function plain_name_filter_ids(filter)
    local args = filter:match("^name%s*%((.*)%)$")
    if not args or args:match("%f[%w_]regex%s*:") or args:match("%f[%w_]keyword%s*:") then
        return nil
    end
    return split_csv(args)
end

local function replace_group_node_filters(group, node_ids)
    local filters = {}
    local inserted = false
    for _, filter in ipairs(group.filters or {}) do
        if plain_name_filter_ids(filter) then
            if not inserted and #node_ids > 0 then
                filters[#filters + 1] = "name(" .. table.concat(node_ids, ", ") .. ")"
                inserted = true
            end
        else
            filters[#filters + 1] = filter
        end
    end
    if not inserted and #node_ids > 0 then
        table.insert(filters, 1, "name(" .. table.concat(node_ids, ", ") .. ")")
    end
    group.filters = filters
    group.nodeIds = node_ids
end

local function group_node_ids(group)
    local ids = {}
    local seen = {}
    for _, filter in ipairs(group.filters or {}) do
        local values = plain_name_filter_ids(filter)
        if values then
            for _, id in ipairs(values) do
                if not seen[id] then
                    ids[#ids + 1] = id
                    seen[id] = true
                end
            end
        end
    end
    return ids
end

local function remove_value(items, value)
    local result = {}
    for _, item in ipairs(items) do
        if item ~= value then
            result[#result + 1] = item
        end
    end
    return result
end

local function serialize_node_config(nodes, subscriptions, groups)
    local lines = { "node {" }
    for _, node in ipairs(nodes) do
        lines[#lines + 1] = "    " .. node.id .. ": " .. quote_dae(node.link)
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "subscription {"
    for _, subscription in ipairs(subscriptions) do
        lines[#lines + 1] = "    " .. subscription.id .. ": " .. quote_dae(subscription.link)
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "group {"
    for _, group in ipairs(groups) do
        lines[#lines + 1] = "    " .. group.id .. " {"
        for _, filter in ipairs(group.filters or {}) do
            lines[#lines + 1] = "        filter: " .. filter
        end
        local policy = group.policy or "min_moving_avg"
        if policy == "fixed" then
            policy = "fixed(" .. tostring(group.fixedIndex or 0) .. ")"
        end
        lines[#lines + 1] = "        policy: " .. policy
        lines[#lines + 1] = "    }"
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function mutation_error(code, message, status)
    return { ok = false, error = { code = code, message = message } }, status or 400
end

function M.mutate(payload)
    payload = payload or {}
    local action = payload.action
    if type(action) ~= "string" then
        return mutation_error("INVALID_ACTION", "A mutation action is required.")
    end
    local revision = current_revision()
    if payload.revision and payload.revision ~= revision then
        return mutation_error("REVISION_CONFLICT", "Configuration changed outside the Dashboard. Reload before editing.", 409)
    end

    local contents = snapshot_contents(payload)
    local nodes = parse_keyable_strings(contents.node, "node")
    local subscriptions = parse_keyable_strings(contents.node, "subscription")
    local groups = parse_groups(contents.node)

    if action == "upsert_node" then
        local id = payload.id
        local previous_id = payload.previousId or id
        if not valid_identifier(id) or type(payload.link) ~= "string" or trim(payload.link) == "" then
            return mutation_error("INVALID_NODE", "Node tag and link are required; the tag may contain letters, numbers, dot, dash and underscore.")
        end
        local node, index = find_by_id(nodes, previous_id)
        if id ~= previous_id and find_by_id(nodes, id) then
            return mutation_error("DUPLICATE_NODE", "A node with this tag already exists.", 409)
        end
        local value = { id = id, tag = id, link = trim(payload.link) }
        if node then nodes[index] = value else nodes[#nodes + 1] = value end
        if id ~= previous_id then
            for _, group in ipairs(groups) do
                local ids = group_node_ids(group)
                for item_index, item_id in ipairs(ids) do
                    if item_id == previous_id then ids[item_index] = id end
                end
                replace_group_node_filters(group, ids)
            end
        end
    elseif action == "delete_node" then
        if not valid_identifier(payload.id) then return mutation_error("INVALID_NODE", "A valid node tag is required.") end
        local _, index = find_by_id(nodes, payload.id)
        if not index then return mutation_error("NODE_NOT_FOUND", "Node not found.", 404) end
        table.remove(nodes, index)
        for _, group in ipairs(groups) do
            replace_group_node_filters(group, remove_value(group_node_ids(group), payload.id))
        end
    elseif action == "upsert_subscription" then
        local id = payload.id
        local previous_id = payload.previousId or id
        if not valid_identifier(id) or type(payload.link) ~= "string" or trim(payload.link) == "" then
            return mutation_error("INVALID_SUBSCRIPTION", "Subscription tag and URL are required.")
        end
        local item, index = find_by_id(subscriptions, previous_id)
        if id ~= previous_id and find_by_id(subscriptions, id) then
            return mutation_error("DUPLICATE_SUBSCRIPTION", "A subscription with this tag already exists.", 409)
        end
        local value = { id = id, tag = id, link = normalize_subscription_link(payload.link) }
        if item then subscriptions[index] = value else subscriptions[#subscriptions + 1] = value end
        if id ~= previous_id then
            for _, group in ipairs(groups) do
                for filter_index, filter in ipairs(group.filters or {}) do
                    if filter_subscription_id(filter) == previous_id then
                        group.filters[filter_index] = filter:gsub("subtag%s*%(%s*['\"]?" .. previous_id:gsub("([^%w])", "%%%1") .. "['\"]?%s*%)", "subtag(" .. id .. ")", 1)
                    end
                end
            end
        end
    elseif action == "delete_subscription" then
        if not valid_identifier(payload.id) then return mutation_error("INVALID_SUBSCRIPTION", "A valid subscription tag is required.") end
        local _, index = find_by_id(subscriptions, payload.id)
        if not index then return mutation_error("SUBSCRIPTION_NOT_FOUND", "Subscription not found.", 404) end
        table.remove(subscriptions, index)
        for _, group in ipairs(groups) do
            local filters = {}
            for _, filter in ipairs(group.filters or {}) do
                if filter_subscription_id(filter) ~= payload.id then filters[#filters + 1] = filter end
            end
            group.filters = filters
        end
    elseif action == "upsert_group" then
        local id = payload.id
        local previous_id = payload.previousId or id
        if not valid_identifier(id) then return mutation_error("INVALID_GROUP", "A valid group name is required.") end
        local group, index = find_by_id(groups, previous_id)
        if id ~= previous_id and find_by_id(groups, id) then
            return mutation_error("DUPLICATE_GROUP", "A group with this name already exists.", 409)
        end
        if not group then
            group = { id = id, name = id, filters = {}, policy = "min_moving_avg", fixedIndex = nil }
            groups[#groups + 1] = group
        else
            group.id = id
            group.name = id
            groups[index] = group
        end
        if not VALID_POLICIES[payload.policy] then
            return mutation_error("INVALID_POLICY", "Unsupported group policy.")
        end
        group.policy = payload.policy
        group.fixedIndex = payload.policy == "fixed" and 0 or nil
    elseif action == "delete_group" then
        if not valid_identifier(payload.id) then return mutation_error("INVALID_GROUP", "A valid group name is required.") end
        local _, index = find_by_id(groups, payload.id)
        if not index then return mutation_error("GROUP_NOT_FOUND", "Group not found.", 404) end
        table.remove(groups, index)
    elseif action == "group_add_node" or action == "group_remove_node" then
        local group = find_by_id(groups, payload.groupId)
        if not group then return mutation_error("GROUP_NOT_FOUND", "Group not found.", 404) end
        if not find_by_id(nodes, payload.nodeId) then return mutation_error("NODE_NOT_FOUND", "Node not found.", 404) end
        local ids = group_node_ids(group)
        ids = remove_value(ids, payload.nodeId)
        if action == "group_add_node" then ids[#ids + 1] = payload.nodeId end
        replace_group_node_filters(group, ids)
    elseif action == "group_add_subscription" or action == "group_remove_subscription" then
        local group = find_by_id(groups, payload.groupId)
        if not group then return mutation_error("GROUP_NOT_FOUND", "Group not found.", 404) end
        if not find_by_id(subscriptions, payload.subscriptionId) then return mutation_error("SUBSCRIPTION_NOT_FOUND", "Subscription not found.", 404) end
        local filters = {}
        for _, filter in ipairs(group.filters or {}) do
            local same_subscription = filter_subscription_id(filter) == payload.subscriptionId
            local exact_node = exact_subscription_node_name(filter) ~= nil
            local remove_filter = action == "group_remove_subscription" and payload.filterId and filter == payload.filterId
            if not remove_filter and not (action == "group_add_subscription" and same_subscription and not exact_node) and
                not (action == "group_remove_subscription" and not payload.filterId and same_subscription and not exact_node) then
                filters[#filters + 1] = filter
            end
        end
        if action == "group_add_subscription" then
            local filter = "subtag(" .. payload.subscriptionId .. ")"
            local regex = trim(payload.regex or "")
            if regex ~= "" then filter = filter .. " && name(regex: " .. quote_dae(regex) .. ")" end
            filters[#filters + 1] = filter
        end
        group.filters = filters
    elseif action == "group_add_subscription_node" or action == "group_remove_subscription_node" then
        local group = find_by_id(groups, payload.groupId)
        if not group then return mutation_error("GROUP_NOT_FOUND", "Group not found.", 404) end
        if not find_by_id(subscriptions, payload.subscriptionId) then return mutation_error("SUBSCRIPTION_NOT_FOUND", "Subscription not found.", 404) end
        local node_name = trim(payload.nodeName or "")
        if node_name == "" then return mutation_error("INVALID_SUBSCRIPTION_NODE", "Subscription node name is required.") end
        local filters = {}
        local found = false
        for _, filter in ipairs(group.filters or {}) do
            local matches = filter_subscription_id(filter) == payload.subscriptionId and exact_subscription_node_name(filter) == node_name
            if matches then found = true end
            if action ~= "group_remove_subscription_node" or not matches then filters[#filters + 1] = filter end
        end
        if action == "group_add_subscription_node" and not found then
            filters[#filters + 1] = "subtag(" .. payload.subscriptionId .. ") && name(" .. quote_dae(node_name) .. ")"
        end
        group.filters = filters
    else
        return mutation_error("UNKNOWN_ACTION", "Unsupported mutation action.")
    end

    contents.node = serialize_node_config(nodes, subscriptions, groups)
    if payload.preview == true then
        return state_from_contents(contents, revision, true), 200
    end
    local valid, output, code = validate_contents(contents)
    if not valid then
        return { ok = false, valid = false, output = output, exitCode = code }, 422
    end
    local written, write_error = write_snapshot(contents)
    if not written then
        return mutation_error("WRITE_FAILED", write_error, 500)
    end
    local state = M.get_state()
    state.dirty = true
    return state, 200
end

return M
