--//Plugin
local plugin

--// Services
local HttpService = game:GetService("HttpService")

--//Instances
local src = script.Parent
local utils = require(src.utils)

--// Variables

--//Consts
local OWNER = "girlycoded"
local REPO_NAME = "roblox_project_01"

local GITHUB_API_URL = "https://api.github.com/"

local root = "src"
local custom_index_names = {
	ServerScriptService = "server",
	StarterPlayerScripts = "client",
	ReplicatedStorage = "shared",
}

local module = {}

function module.repo_path()
	return `repos/{OWNER}/{REPO_NAME}`
end

function module.git_path()
	return `{module.repo_path()}/git`
end

function module.default_headers()
	return {
		["Authorization"] = "Bearer " .. module.ACCESS_TOKEN,
		["Accept"] = "application/vnd.github+json",
		["Content-Type"] = "application/json",
	}
end

function module.github_request(subdomain: string, method: "GET" | "POST", body: {}?): (boolean, string|{}?)
	local request_url = string.sub(subdomain, 0, 22) == "https://api.github.com" and subdomain or GITHUB_API_URL .. subdomain
	
	--print(`{method}-ING {request_url}`)
	local success, result = pcall(function()
		local request_options = {
			Url = request_url,
			Method = method,
			Headers = module.default_headers(),
			Body = body and HttpService:JSONEncode(body),
			--Timeout = 10,
		}
		local response = HttpService:RequestAsync(request_options)
		return response
	end)
	if not success or not utils.is_status_code_ok(result.StatusCode) then
		warn(result)
	end
	local was_request_sucessful = (success and utils.is_status_code_ok(result.StatusCode))
	
	local body_return_message = type(result) == "table" and HttpService:JSONDecode(result.Body or "{}").message or ""
	local return_message = type(result) == "table" and `{result.StatusCode} {body_return_message} {result.StatusMessage}` or result
	return was_request_sucessful, was_request_sucessful and HttpService:JSONDecode(result.Body) or return_message
end

function module.set_access_token(new_access_token: string, do_save: boolean?)
	module.ACCESS_TOKEN = new_access_token or ""
	if do_save then
		plugin:SetSetting("access_token", new_access_token)
	end
end

function module.init(plugin_reference: Plugin)
	plugin = plugin_reference
	module.ACCESS_TOKEN = plugin:GetSetting("access_token") or ""
end

return module