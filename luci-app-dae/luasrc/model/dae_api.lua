local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local http = require "luci.http"

local M = {}

local FILES = {
    global = "/etc/dae/config.dae",
    dns = "/etc/dae/config.d/dns.dae",
    node = "/etc/dae/config.d/node.dae",
    routing = "/etc/dae/config.d/route.dae"
}

local FILE_ORDER = { "global", "dns", "node", "routing" }

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function read_file(path)
    return fs.readfile(path) or ""
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
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
    local address = item.link:match("@([^:/?]+)") or item.link:match("^[%w+.-]+://([^:/?]+)") or ""
    local fragment = item.link:match("#([^#]+)$")
    item.protocol = protocol:lower()
    item.address = address
    item.name = fragment and http.urldecode(fragment) or item.tag
    item.source = source
    return item
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
            policyParams = {},
            nodeIds = {},
            subscriptions = {},
            filters = {}
        }

        local policy = trim(entry.body:match("%f[%w]policy%s*:%s*([^\r\n#]+)") or "")
        if policy ~= "" then
            local policy_name, policy_args = policy:match("^([%w_]+)%s*%((.*)%)$")
            group.policy = policy_name or policy
            if policy_args and trim(policy_args) ~= "" then
                group.policyParams[#group.policyParams + 1] = { key = "value", val = trim(policy_args) }
            end
        end

        for line in entry.body:gmatch("[^\r\n]+") do
            local filter = trim(line:match("^%s*filter%s*:%s*(.-)%s*$"))
            if filter and filter ~= "" and not filter:match("^#") then
                group.filters[#group.filters + 1] = filter
                local name_args = filter:match("name%s*%((.-)%)")
                if name_args and not name_args:match("%f[%w_]regex%s*:") and not name_args:match("%f[%w_]keyword%s*:") then
                    for _, node_id in ipairs(split_csv(name_args)) do
                        group.nodeIds[#group.nodeIds + 1] = node_id
                    end
                end
                local subscription_id = trim(filter:match("subtag%s*%((.-)%)") or "")
                if subscription_id ~= "" then
                    subscription_id = subscription_id:gsub("^['\"]", ""):gsub("['\"]$", "")
                    local regex = filter:match("name%s*%(%s*regex%s*:%s*'(.-)'%s*%)") or
                        filter:match('name%s*%(%s*regex%s*:%s*"(.-)"%s*%)')
                    group.subscriptions[#group.subscriptions + 1] = {
                        id = subscription_id,
                        subscriptionId = subscription_id,
                        nameFilterRegex = regex
                    }
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

function M.get_state()
    local files = read_files()
    local nodes = parse_keyable_strings(files.node.content, "node")
    local subscriptions = parse_keyable_strings(files.node.content, "subscription")
    for _, node in ipairs(nodes) do
        link_metadata(node, "manual")
    end
    for _, subscription in ipairs(subscriptions) do
        link_metadata(subscription, "subscription")
        subscription.status = nil
        subscription.updatedAt = nil
        subscription.previewAvailable = false
        subscription.nodes = {}
    end

    return {
        ok = true,
        revision = current_revision(),
        service = service_state(),
        settings = settings_state(),
        files = files,
        resources = {
            global = parse_global(files.global.content),
            dns = parse_dns(files.dns.content),
            routing = parse_routing(files.routing.content),
            nodes = nodes,
            subscriptions = subscriptions,
            groups = parse_groups(files.node.content)
        },
        warnings = {
            "Subscription node previews are unavailable when reading plain dae configuration files."
        }
    }
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
    local timestamp = os.date("%Y%m%d-%H%M%S")
    local staged = {}
    local backups = {}

    for _, key in ipairs(FILE_ORDER) do
        local path = FILES[key]
        local temp_path = string.format("%s.luci-dae.%d.tmp", path, pid)
        if not fs.writefile(temp_path, contents[key]) then
            for _, item in pairs(staged) do fs.remove(item) end
            return nil, "Unable to stage " .. path
        end
        fs.chmod(temp_path, "0640")
        staged[key] = temp_path
    end

    for _, key in ipairs(FILE_ORDER) do
        local path = FILES[key]
        local backup = path .. ".bak." .. timestamp
        if fs.access(path) and not fs.copy(path, backup) then
            for _, item in pairs(staged) do fs.remove(item) end
            return nil, "Unable to back up " .. path
        end
        backups[key] = backup
    end

    local installed = {}
    for _, key in ipairs(FILE_ORDER) do
        if not fs.rename(staged[key], FILES[key]) then
            for _, installed_key in ipairs(installed) do
                fs.copy(backups[installed_key], FILES[installed_key])
            end
            for _, item in pairs(staged) do fs.remove(item) end
            return nil, "Unable to install " .. FILES[key]
        end
        installed[#installed + 1] = key
    end
    return backups
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

    local backups, write_error = write_snapshot(contents)
    if not backups then
        return { ok = false, error = { code = "WRITE_FAILED", message = write_error } }, 500
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
        backups = backups,
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
        if group.policyParam and group.policyParam ~= "" then
            policy = policy .. "(" .. group.policyParam .. ")"
        elseif group.policyParams and group.policyParams[1] and group.policyParams[1].val then
            policy = policy .. "(" .. group.policyParams[1].val .. ")"
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

    local contents = snapshot_contents({})
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
        local value = { id = id, tag = id, link = trim(payload.link) }
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
            group = { id = id, name = id, filters = {}, policy = "min_moving_avg", policyParams = {} }
            groups[#groups + 1] = group
        else
            group.id = id
            group.name = id
            groups[index] = group
        end
        if type(payload.policy) == "string" and payload.policy ~= "" then group.policy = payload.policy end
        group.policyParam = trim(payload.policyParam or "")
        group.policyParams = {}
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
            if filter_subscription_id(filter) ~= payload.subscriptionId then filters[#filters + 1] = filter end
        end
        if action == "group_add_subscription" then
            local filter = "subtag(" .. payload.subscriptionId .. ")"
            local regex = trim(payload.regex or "")
            if regex ~= "" then filter = filter .. " && name(regex: " .. quote_dae(regex) .. ")" end
            filters[#filters + 1] = filter
        end
        group.filters = filters
    else
        return mutation_error("UNKNOWN_ACTION", "Unsupported mutation action.")
    end

    contents.node = serialize_node_config(nodes, subscriptions, groups)
    local valid, output, code = validate_contents(contents)
    if not valid then
        return { ok = false, valid = false, output = output, exitCode = code }, 422
    end
    local backups, write_error = write_snapshot(contents)
    if not backups then
        return mutation_error("WRITE_FAILED", write_error, 500)
    end
    local state = M.get_state()
    state.dirty = true
    state.backups = backups
    return state, 200
end

return M
