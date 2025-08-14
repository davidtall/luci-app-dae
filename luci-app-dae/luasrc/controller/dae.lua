local sys  = require "luci.sys"
local http = require "luci.http"
local nixio = require "nixio"

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

	-- Configuration pages
	entry({"admin", "services", "dae", "global"}, cbi("dae/global"), _("Global Settings"), 1)
	entry({"admin", "services", "dae", "dns"}, cbi("dae/dns"), _("DNS Settings"), 2)
	entry({"admin", "services", "dae", "node"}, cbi("dae/node"), _("Node Settings"), 3)
	entry({"admin", "services", "dae", "route"}, cbi("dae/route"), _("Routing Settings"), 4)
end

function act_status()
	local e = {}
	e.running = sys.call("pgrep -x /usr/bin/dae >/dev/null") == 0
	http.prepare_content("application/json")
	http.write_json(e)
end
