local sys = require "luci.sys"
local http = require "luci.http"
local nixio = require "nixio"
local jsonc = require "luci.jsonc"
local dae_api = require "luci.model.dae_api"

module("luci.controller.dae", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/dae") then
		return
	end

	-- Main page
	local page = entry({"admin", "services", "dae"}, firstchild(), _("DAE"), -1)
	page.dependent = true
	page.acl_depends = { "luci-app-dae" }

	-- Status entry
	entry({"admin", "services", "dae", "status"}, call("act_status")).leaf = true

	-- Visible pages
	entry({"admin", "services", "dae", "global"}, cbi("dae/global"), _("Global Settings"), 1)
	entry({"admin", "services", "dae", "dashboard"}, template("dae/dae_dashboard"), _("Dashboard"), 2)
	entry({"admin", "services", "dae", "log"}, cbi("dae/log"), _("Logs"), 3)

	-- Dashboard JSON API
	entry({"admin", "services", "dae", "api", "state"}, call("api_state")).leaf = true
	entry({"admin", "services", "dae", "api", "preview"}, call("api_preview")).leaf = true
	entry({"admin", "services", "dae", "api", "subscription", "resolve"}, call("api_subscription_resolve")).leaf = true
	entry({"admin", "services", "dae", "api", "validate"}, call("api_validate")).leaf = true
	entry({"admin", "services", "dae", "api", "save"}, call("api_save")).leaf = true
	entry({"admin", "services", "dae", "api", "apply"}, call("api_apply")).leaf = true
	entry({"admin", "services", "dae", "api", "reload"}, call("api_reload")).leaf = true
	entry({"admin", "services", "dae", "api", "mutate"}, call("api_mutate")).leaf = true

	entry({"admin", "services", "dae", "get_log"}, call("get_log"))
	entry({"admin", "services", "dae", "clear_log"}, call("clear_log"))
end

local function write_json(payload, status)
	if status then
		http.status(status)
	end
	http.header("Cache-Control", "no-store")
	http.prepare_content("application/json")
	http.write_json(payload)
end

local function read_json_body()
	local body = http.content() or ""
	if #body > 1048576 then
		return nil, "Request body is too large"
	end
	local payload = jsonc.parse(body)
	if type(payload) ~= "table" then
		return nil, "Invalid JSON request body"
	end
	return payload
end

local function require_post()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		write_json({ ok = false, error = { code = "METHOD_NOT_ALLOWED", message = "POST required" } }, 405)
		return false
	end
	return true
end

function api_state()
	write_json(dae_api.get_state(), 200)
end

function api_validate()
	if not require_post() then return end
	local payload, err = read_json_body()
	if not payload then
		write_json({ ok = false, error = { code = "INVALID_JSON", message = err } }, 400)
		return
	end
	local response, status = dae_api.validate(payload)
	write_json(response, status)
end

function api_preview()
	if not require_post() then return end
	local payload, err = read_json_body()
	if not payload then
		write_json({ ok = false, error = { code = "INVALID_JSON", message = err } }, 400)
		return
	end
	local response, status = dae_api.preview(payload)
	write_json(response, status)
end

function api_subscription_resolve()
	if not require_post() then return end
	local payload, err = read_json_body()
	if not payload then
		write_json({ ok = false, error = { code = "INVALID_JSON", message = err } }, 400)
		return
	end
	local response, status = dae_api.resolve_subscription(payload)
	write_json(response, status)
end

function api_mutate()
	if not require_post() then return end
	local payload, err = read_json_body()
	if not payload then
		write_json({ ok = false, error = { code = "INVALID_JSON", message = err } }, 400)
		return
	end
	local response, status = dae_api.mutate(payload)
	write_json(response, status)
end

function api_save()
	if not require_post() then return end
	local payload, err = read_json_body()
	if not payload then
		write_json({ ok = false, error = { code = "INVALID_JSON", message = err } }, 400)
		return
	end
	local response, status = dae_api.save(payload, false)
	write_json(response, status)
end

function api_apply()
	if not require_post() then return end
	local payload, err = read_json_body()
	if not payload then
		write_json({ ok = false, error = { code = "INVALID_JSON", message = err } }, 400)
		return
	end
	local response, status = dae_api.save(payload, true)
	write_json(response, status)
end

function api_reload()
	if not require_post() then return end
	local response, status = dae_api.reload()
	write_json(response, status)
end

function act_status()
	local sys  = require "luci.sys"
	local fs   = require "nixio.fs"
	local e = { }
	local pid = sys.exec("pidof dae | cut -d' ' -f1"):gsub("\n", "")
	e.running = (pid ~= "")
	if e.running then
		local status = fs.readfile("/proc/" .. pid .. "/status")
		if status then
			local rss = status:match("VmRSS:%s+(%d+)%s+kB")
			if rss then
				e.memory = string.format("%.1f MB", tonumber(rss) / 1024)
			end
		end
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function get_log()
	http.prepare_content("text/plain")
	http.write(sys.exec("tail -n 1000 /var/log/dae/dae.log 2>/dev/null"))
end

function clear_log()
	sys.call("true > /var/log/dae/dae.log")
	write_json({ ok = true }, 200)
end
