--- @usage
--- local cookie_parser = require("cookie-parser")
--- app:use(cookie_parser())

--- @class ExpressRequest
--- @field cookies table | nil -- table of parsed cookies

return function(opts)
	-- todo? signed cookies

	return function(req, _, next)
		if req.cookies then return next() end

		local cookie = req.headers.cookie
		if not cookie then return next() end

		local cookies = {}
		for k, v in cookie:gmatch("([^=]+)=([^;]+)") do
			cookies[k] = v
		end
		req.cookies = cookies

		next()
	end
end
