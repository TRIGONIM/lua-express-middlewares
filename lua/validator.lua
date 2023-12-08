-- Помогает упростить вот такие уродливые конструкции:
-- https://file.def.pm/o9LZgS3D.jpg
-- require("validator").validator(params, messages)

-- Inspired by laravel's validator and livr-spec.org


-- https://gist.github.com/Stepets/3b4dbaf5e6e6a60f3862
local utf8ok, utf8 = pcall(require, "utf8")

local rulesets = {}

-- NUMERIC --

rulesets["numeric"] = function(value)
	if type(value) == "number" then
		return value
	end
end

rulesets["decimal"] = tonumber

-- accepts even hex strings like "0xFF" (converted to 255)
rulesets["integer"] = function(value)
	local numeric = tonumber(value)
	if numeric and math.floor(numeric) == numeric then
		return numeric
	end
end

-- STRING --

-- rulesets["json"] -- (cjson.safe).decode

rulesets["string"] = function(value)
	if type(value) == "string" then
		return value
	end
end

rulesets["trim"] = function(value)
	return value:match("^%s*(.-)%s*$")
end

rulesets["match"] = function(value, patt)
	return ({value:match(patt)})[1] -- return only one value
end

-- rulesets["starts_with"]

-- COMMON --

rulesets["required"] = function(value)
	return (value ~= nil and value ~= "") and value or nil
end

rulesets["optional"] = function(value)
	if value == nil then return value, "break" end
	return value
end

-- SPECIAL --

local get_size = function(value)
	local typ = type(value)
	if typ == "number" then
		return value
	elseif typ == "string" then
		local string_len = utf8ok and utf8.len or string.len
		return string_len(value)
	elseif typ == "table" then
		return #value
	end
	return nil -- nil, boolean, function, thread, userdata...
end

rulesets["size"] = function(value, size)
	assert(size:match("^%d+$"), "size must be positive integer")
	return get_size(value) == tonumber(size) and value or nil
end

rulesets["min"] = function(value, min)
	return get_size(value) >= tonumber(min) and value or nil
end

rulesets["max"] = function(value, max)
	return get_size(value) <= tonumber(max) and value or nil
end

-- rulesets["in"]
-- rulesets["not_in"]

-- CUSTOM RULES --

rulesets["ip"] = function(str)
	local parts = { str:match("(%d+)%.(%d+)%.(%d+)%.(%d+)") }
	if #parts ~= 4 then return nil end
	for _, part in ipairs(parts) do
		if tonumber(part) > 255 then
			return nil
		end
	end
	return str
end


-- return "formatted_value" (may be falsy)
-- or return nil, "failed_rule_name"
local function validate_value(value, ruleset)
	local rules = {}
	for rule in ruleset:gmatch("[^|]+") do
		local name, argsstr = rule:match("([^:]+):?(.*)")
		if not rulesets[name] then return nil, "unknown_" .. name end

		local args = {}
		for arg in argsstr:gmatch("[^,]+") do
			args[#args + 1] = arg
		end
		rules[#rules + 1] = {name, args}
	end

	for _, rule in ipairs(rules) do
		local val, instruction = rulesets[rule[1]](value, unpack(rule[2]))
		if instruction == "break" then break end -- for optional
		if not val then return nil, rule[1] end
		value = val
	end

	return value -- formatted value
end

-- params_rules: {param_name = "required|starts_with:765|size:17", ...}
-- params_values: {param_name = param_value, ...}
local function validate_all_simple(params_rules, params_values)
	local formatted_values, errors = {}, {}
	for param_name, ruleset in pairs(params_rules) do
		local formatted_value, failed_rule_name = validate_value(params_values[param_name], ruleset)
		if failed_rule_name ~= nil then
			errors[param_name] = failed_rule_name
			break
		else
			formatted_values[param_name] = formatted_value
		end
	end

	return formatted_values, next(errors) and errors or nil
end

-- messages variations:
--    {param_name.rule_name = "message", ...}
--    {param_name.* = "message", ...}
--    {* = "message", ...}
local function validate_all(params_rules, params_values, messages)
	messages = messages or {}

	local formatted_values, errors = validate_all_simple(params_rules, params_values)
	if errors then
		local param_name, failed_rule_name = next(errors)

		local msg = messages[param_name .. "." .. failed_rule_name]
			or messages[param_name .. ".*"] or messages["*"]

		errors[param_name] = msg or errors[param_name]
		return formatted_values, errors
	end

	return formatted_values, nil
end

-- Извлекает параметры из запроса в соответствии с правилами и проверяет их
-- Если указан messages, то в случае ошибки будет использовано сообщение из него
local function express_middleware(params_with_rules, messages) -- messages may be nil
	return function(req, _, next)
		local params_values = {}
		for param_name in pairs(params_with_rules) do
			params_values[param_name] = req:param(param_name)
		end

		local formatted_values, errors = validate_all(params_with_rules, params_values, messages)
		if errors then
			local param_name, msg = _G.next(errors)
			next({
				message = "Parameter validation failed. " .. param_name .. ": " .. msg,
				status  = 400,
				stack   = debug.traceback(),
				valid_parameters = formatted_values,
				input_parameters = params_values,
				error_parameters = errors, -- failed_parameters is better name, but looks not so nice in this place :)
			})
			return
		end

		if req.valid then print("validator: Some of middlewares already created the req.valid field. Override") end
		req.valid = formatted_values

		next()
	end
end

-- usage:
-- app:get("/path", validator({
-- 	sid = "required|starts_with:765|size:17",
-- 	s   = "required|integer|min:0|max:255",
-- 	sum = "required|decimal|min:1|max:10000",
-- 	note = "max:80",
-- }, {
-- 	["sid.required"] = "SteamID64 is required",
-- 	["sid.*"] = "SteamID64 is invalid",
-- 	["*"] = "Something went wrong",
-- 	["note.*"] = "Note should be less than 80 characters",
-- }))

-- local tests = {
-- 	{"32.5", "decimal", 32.5, nil},
-- 	{"6.5", "decimal|min:5|max:6", nil, "max"},
-- 	{nil, "optional|integer", nil, nil},
-- 	{"0xFF", "integer", 255, nil}, -- само конвертировало hex в dec
-- 	{5, "size:5", 5, nil}, -- сравнивает как дано (числом)
-- 	{"5", "size:5", nil, "size"}, -- сравнивает как дано (строкой)
-- 	{"5", "integer|size:5", 5, nil}, -- сравнивает как число, конвертировав в него
-- 	{"5.0", "integer|size:5", 5, nil}, -- оно снимет после запятой
-- 	{"100.000000000000001", "integer", 100, nil}, -- тут мантисса довольно длинная и число возвращается целым
-- 	{"100.00000000000001", "integer", nil, "integer"}, -- тут короткая, так что получаем float
-- 	{"qqqqqqqqq", "size:9", "qqqqqqqqq", nil}, -- длина строки
-- 	{"", "size:0", "", nil}, -- without required and optional
-- }

-- if utf8ok then
-- 	print("utf 8 lib exists. Expect that 'кириллица' has length 9")
-- 	tests[#tests + 1] = {"кириллица", "max:9", "кириллица", nil}
-- else
-- 	print("utf 8 lib does not exist. Expect that 'кириллица' has length 18")
-- 	tests[#tests + 1] = {"кириллица", "max:18", "кириллица", nil}
-- end

-- for _, test in ipairs(tests) do
-- 	local val, failed_rule_name = validate_value(test[1], test[2])
-- 	-- print(ok, val, ok and type(val) or nil)
-- 	assert(val == test[3] and failed_rule_name == test[4], "validate_value failed: " .. tostring(test[1]) .. " " .. test[2] ..
-- 		". Failed rule: " .. (failed_rule_name or "") ..
-- 		". Expected val (" .. tostring(test[3]) .. "), got (" .. tostring(val) .. ")" ..
-- 		". Expected failed rule (" .. tostring(test[4]) .. "), got (" .. tostring(failed_rule_name) .. ")")
-- end

return {
	rulesets = rulesets,
	validate_value = validate_value,
	validate_all_simple = validate_all_simple,
	validate_all = validate_all,
	middleware = express_middleware,
}
