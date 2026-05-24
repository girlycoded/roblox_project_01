local extension_lookup = {
	Script = ".server.luau",
	LocalScript = ".client.luau",
	ModuleScript = ".luau"
}

local module = {}

function module.is_status_code_ok(code: number)
	return code >= 200 and code < 300
end

function module.get_file_extension(source: LuaSourceContainer)
	return source and extension_lookup[source.ClassName] or ""
end

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local LOOKUP = {}

for i = 1, #BASE64 do
	LOOKUP[BASE64:sub(i, i)] = i - 1
end

function module.from_base64(data)
	local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	data = string.gsub(data, '[^'..b..'=]', '')
	return (data:gsub('.', function(x)
		if (x == '=') then return '' end
		local r,f='',(b:find(x)-1)
		for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
		return r;
	end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
		if (#x ~= 8) then return '' end
		local c=0
		for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
		return string.char(c)
	end))
end

function module.hash_dict(dict: {string: any}): string
	local keys = {}
	for k in dict do
		table.insert(keys, k)
	end
	table.sort(keys)

	local parts = {}
	for _, k in keys do
		table.insert(parts, k .. "=" .. tostring(dict[k]))
	end

	return table.concat(parts, "|")
end

function module.num_keys(dict: {[any]: any})
	local count = 0
	for _ in dict do
		count += 1
	end
	return count
end

return module