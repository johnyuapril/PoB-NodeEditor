-- Tiny single-threaded HTTP server for the node editor (LuaSocket).
--   GET  /            -> webroot/index.html
--   GET  /<file>      -> webroot/<file>
--   POST /api         -> JSON request -> serve.lua dispatcher -> JSON response
return function(process, opt)
	local socket = require("socket")
	local dk = opt.dkjson
	local say = opt.realPrint or print
	local server = assert(socket.tcp())
	server:setoption("reuseaddr", true)
	-- after an update restart the old socket can take a moment to be released
	local bound, berr
	for _ = 1, 300 do
		bound, berr = server:bind("127.0.0.1", opt.port)
		if bound then break end
		socket.sleep(0.5)
	end
	assert(bound, berr)
	assert(server:listen(16))
	server:settimeout(nil)
	local TYPES = { html = "text/html; charset=utf-8", js = "application/javascript", json = "application/json", css = "text/css", svg = "image/svg+xml", png = "image/png" }

	local function readFile(p)
		local f = io.open(p, "rb")
		if not f then return nil end
		local s = f:read("*a") f:close() return s
	end

	local function send(c, status, ctype, body)
		c:send(("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"):format(status, ctype, #body))
		local i = 1
		while i <= #body do
			local last, err, partial = c:send(body, i)
			if not last then
				if err == "timeout" and partial then i = partial + 1 else break end
			else
				i = last + 1
			end
		end
	end

	say(("PoB node editor running: http://127.0.0.1:%d   (close this window to stop)"):format(opt.port))
	while true do
		local c = server:accept()
		if c then
			c:settimeout(30)
			local ok, err = pcall(function()
				local line = c:receive("*l")
				if not line then return end
				local method, path = line:match("^(%u+)%s+(%S+)")
				local len = 0
				while true do
					local h = c:receive("*l")
					if not h or h == "" then break end
					local k, v = h:match("^([^:]+):%s*(.*)$")
					if k and k:lower() == "content-length" then len = tonumber(v) or 0 end
				end
				local body = len > 0 and c:receive(len) or ""
				path = (path or "/"):gsub("%?.*$", "")
				if method == "OPTIONS" then
					c:send("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Methods: GET, POST\r\nConnection: close\r\n\r\n")
				elseif method == "POST" and path == "/api" then
					local req = dk.decode(body)
					local resp = process(req)
					send(c, "200 OK", TYPES.json, dk.encode(resp))
					if type(resp) == "table" and resp.restart then
						c:settimeout(1)
						pcall(c.receive, c, 1)
						c:close()
						server:close()
						say("Update applied. Restarting the editor...")
						os.exit(3)
					end
				elseif method == "GET" then
					if path == "/" then path = "/index.html" end
					if path:find("%.%.") then send(c, "403 Forbidden", "text/plain", "no") return end
					local data = readFile(opt.webroot .. path)
					if data then
						send(c, "200 OK", TYPES[path:match("%.(%w+)$") or ""] or "application/octet-stream", data)
					else
						send(c, "404 Not Found", "text/plain", "not found")
					end
				else
					send(c, "405 Method Not Allowed", "text/plain", "no")
				end
			end)
			if not ok then pcall(send, c, "500 Internal Server Error", "text/plain", tostring(err)) end
			-- let the browser close first, so the port is not left in TIME_WAIT on our side (fast restart after update)
			c:settimeout(0.3)
			pcall(c.receive, c, 1)
			c:close()
		end
	end
end
