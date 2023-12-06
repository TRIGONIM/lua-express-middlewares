# lua-express middlewares collection

It's for [lua-express](https://github.com/TRIGONIM/lua-express)

## Usage:

### body-parser

Adds the `req.body` (table) field

```lua
local bp = require("body-parser")
app:use(bp.json({type = "application/json"}))
app:use(bp.urlencoded({type = "*/*"}))

app:post("/", function(req, res)
	res:json(req.body)
end)
```

### cookie-parser

Adds the `req.cookies` (table with case-sensitive kvs) field

```lua
local cookieparser = require("cookie-parser")
-- https://github.com/TRIGONIM/lua-express/blob/main/examples/cookie.lua
```

### rate-limiter-simple

```lua
local rate_limiter = require("rate-limiter-simple")
app:use( rate_limiter{
	frame_time = 60,
	limit_amount = 120,
	limit_on = function(req) return req:ip() end,
	response = function(res, retry_after)
		res:set("Retry-After", retry_after)
		res:status(429)
		res:send("request limit of " .. opts.limit_amount .. "/" .. opts.frame_time .. "s exceeded")
	end,
} )
```

### validator

```lua
local validator = require("validator").middleware
app:get("/", validator({
	steamid = "required|string|starts_with:765|size:17",
	amount  = "required|integer|min:1|max:100",
	sum     = "optional|decimal|min:1.5|max:99.5",
}), function(req, res, next)
	assert(type(req.valid.amount) == "number")
	assert(type(req.valid.steamid) == "string")
	res:send(req.valid.sum or "sum not set")
end)
```

Full list of middlewares you can find here: [click](/lua).
