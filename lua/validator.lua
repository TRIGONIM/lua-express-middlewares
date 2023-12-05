-- Помогает упростить вот такие уродливые конструкции:
-- https://file.def.pm/o9LZgS3D.jpg
-- require("validator").validator(params, messages)

-- #todo Exclude all fields that do not have validation rules described
-- Учитывать, что могут быть переданы данные в несколько мбайт
-- Трункейтить строки, чтобы убирались пробелы в начале и конце
-- Проверять, что в строке нет непечатных символов
-- Отдельно правила трансформации (trim, tolower, tonumber, tostring, ...)
-- Убрать json_error (зависимость чисто gmd)
--

-- https://gist.github.com/Stepets/3b4dbaf5e6e6a60f3862
local utf8ok, utf8 = pcall(require, "utf8")

local rulesets = {}

rulesets["numeric"] = function(value)
	-- local numeric = tostring(value):match("^%-?%d+%.?%d*$") -- .1 123.1 123, -.0
	if tonumber(value) then
		return true, tonumber(value)
	else
		return false
	end
end

rulesets["integer"] = function(value)
	-- local integer = tostring(value):match("^%-?%d+$")

	-- съедает даже hex строку, возвращает число
	-- при длинной мантиссе "100.000000000000001" вернет все равно целое 100 (особенность lua?)
	local numeric = tonumber(value)
	if numeric and numeric % 1 == 0 then
		return true, numeric
	else
		return false
	end
end

-- rulesets["json"] = function(value)
-- 	local ok, res = pcall(json.decode, value)
-- 	if not ok then return false end
-- 	return true, res
-- end

-- для случаев, когда надо валидировать строго строку
rulesets["string"] = function(value)
	local typ = type(value)
	if typ == "string" then
		return true, value
	-- else
	-- 	return true, tostring(value)
	end
	return false
end

rulesets["match"] = function(value, patt)
	local matched = value:match(patt)
	if not matched then return false end
	return true, matched
end

rulesets["required"] = function(value)
	return value ~= nil and value ~= ""
end

rulesets["nullable"] = function(value)
	local nulled = value == nil
	if nulled then return "break" end
	return true -- пусть проверяет другие правила
end

-- rulesets["starts_with"] = function(value, ...)
-- 	for _, patt in ipairs({...}) do
-- 		if value:sub(1, patt:len()) == patt then return true end
-- 	end
-- 	return false
-- end

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
	return get_size(value) == tonumber(size)
end

rulesets["min"] = function(value, min)
	return get_size(value) >= tonumber(min)
	-- раньше было вот так: https://file.def.pm/kdIyHZ1b.jpg
	-- но тогда если note = "3", а правило min:5|max:80, то была ошибка, потому что 3 < 5, а не потому что длина меньше 5 символов
end

rulesets["max"] = function(value, max)
	return get_size(value) <= tonumber(max)
end

-- rulesets["in"] = function(value, ...)
-- 	for _, v in ipairs({...}) do
-- 		if value == v then return true end
-- 	end
-- 	return false
-- end

-- rulesets["not_in"] = function(value, ...)
-- 	for _, v in ipairs({...}) do
-- 		if value == v then return false end
-- 	end
-- 	return true
-- end

-- CUSTOM RULES --

local is_valid_ip = function(str)
	local parts = { str:match("(%d+)%.(%d+)%.(%d+)%.(%d+)") }
	if #parts ~= 4 then return false end
	for _, part in ipairs(parts) do
		if tonumber(part) > 255 then
			return false
		end
	end
	return true
end

rulesets["ip"] = function(value)
	return is_valid_ip(value)
end


-- return true, "formatted_value"
-- or return false, "failed_rule_name"
local function validate_value(value, ruleset)
	local rules = {}
	for rule in ruleset:gmatch("[^|]+") do
		local name, argsstr = rule:match("([^:]+):?(.*)")
		if not rulesets[name] then return false, name end -- unknown rule

		local args = {}
		for arg in argsstr:gmatch("[^,]+") do
			args[#args + 1] = arg
		end
		rules[#rules + 1] = {name, args}
	end

	for _, rule in ipairs(rules) do
		local res, newval = rulesets[rule[1]](value, unpack(rule[2]))
		if newval then value = newval end
		if not res then return false, rule[1] end
		if res == "break" then break end -- for nullable
	end

	return true, value -- formatted value
end

-- params_rules: {param_name = "required|starts_with:765|size:17", ...}
-- params_values: {param_name = param_value, ...}
local function validate_all_simple(params_rules, params_values)
	for param_name, ruleset in pairs(params_rules) do
		local ok, failed_rule_name = validate_value(params_values[param_name], ruleset)
		if not ok then
			return false, param_name, failed_rule_name
		else
			params_values[param_name] = failed_rule_name -- formatted value
		end
	end
	return true
end

-- messages variations:
--    {param_name.rule_name = "message", ...}
--    {param_name.* = "message", ...}
--    {* = "message", ...}
local function validate_all(params_rules, params_values, messages)
	messages = messages or {}

	local ok, param_name, failed_rule_name = validate_all_simple(params_rules, params_values)
	if not ok then
		local msg = messages[param_name .. "." .. failed_rule_name]
			or messages[param_name .. ".*"]
			or messages["*"]
			or "invalid_" .. param_name

		return false, param_name, msg
	end

	return true
end

-- Извлекает параметры из запроса в соответствии с правилами и проверяет их
-- Если указан messages, то в случае ошибки будет использовано сообщение из него
local function express_middleware(params_with_rules, messages) -- messages may be nil
	return function(req, res, next)
		local params_values = {}
		for param_name in pairs(params_with_rules) do
			params_values[param_name] = req:param(param_name)
		end

		local ok, param_name, msg = validate_all(params_with_rules, params_values, messages)
		if not ok then
			res:json_error(msg or ("invalid_" .. param_name), 400)
			return
		end

		if req.valid then
			print("validator: Какой-то из мидлверов уже создал поле req.valid. Конфликтная ситуация. Оверрайдим")
		end
		req.valid = params_values

		next()
	end
end

-- usage:
-- app:get("/path", validator({
-- 	sid = "required|starts_with:765|size:17",
-- 	s   = "required|numeric|min:0|max:255",
-- 	sum = "required|numeric|min:1|max:10000",
-- 	note = "max:80",
-- }, {
-- 	["sid.required"] = "SteamID64 is required",
-- 	["sid.*"] = "SteamID64 is invalid",
-- 	["*"] = "Something went wrong",
-- 	["note.*"] = "Note should be less than 80 characters",
-- }))

-- for _, test in ipairs({
-- 	{"32.5", "numeric", true, 32.5},
-- 	{"6.5", "numeric|min:5|max:6", false, "max"},
-- 	{nil, "nullable|integer", true, nil},
-- 	{"0xFF", "numeric", true, 255}, -- само конвертировало hex в dec
-- 	{5, "size:5", true, 5}, -- сравнивает как дано (числом)
-- 	{"5", "size:5", false, "size"}, -- сравнивает как дано (строкой)
-- 	{"5", "integer|size:5", true, 5}, -- сравнивает как число, конвертировав в него
-- 	{"5.0", "integer|size:5", true, 5}, -- оно снимет после запятой
-- 	{"100.000000000000001", "integer", true, 100}, -- тут мантисса довольно длинная и число возвращается целым
-- 	{"100.00000000000001", "integer", false, "integer"}, -- тут короткая, так что получаем float
-- 	{"qqqqqqqqq", "max:9", true, "qqqqqqqqq"}, -- длина строки
-- 	{"кириллица", "max:9", false, "max"}, -- кириллица имеет бОльшую длину для lua, чем латиница
-- }) do
-- 	local ok, val = validate_value(test[1], test[2])
-- 	-- print(ok, val, ok and type(val) or nil)
-- 	assert(ok == test[3] and val == test[4], "validate_value failed: " .. tostring(test[1]) .. " " .. test[2] ..
-- 		". Expected (" .. tostring(test[3]) .. ", " .. tostring(test[4]) ..
-- 		"), got (" .. tostring(ok) .. " " .. tostring(val) .. ")")
-- end

return {
	rulesets = rulesets,
	validate_value = validate_value,
	validate_all_simple = validate_all_simple,
	validate_all = validate_all,
	middleware = express_middleware,
}
