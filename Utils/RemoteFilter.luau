--[[
MIT License

Copyright (c) 2026 KocakZ

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local RemoteFilter = {}
local STATE_KEY = "__KocakZRemoteFilter_v1"
local pack, unpackValues = table.pack, table.unpack
local mainThread = {}

local function copyPatterns(patterns)
    if patterns == nil then
        return {}
    end
    assert(type(patterns) == "table", "must be a list of Lua patterns")
    local result = {}
    local count = 0
    for index, pattern in pairs(patterns) do
        assert(type(index) == "number" and index >= 1 and index % 1 == 0, "must be a list of Lua patterns")
        assert(type(pattern) == "string", "must contain Lua pattern strings")
        result[index] = pattern
        count = count + 1
    end
    assert(count == #result, "must not contain gaps")
    return result
end

local function install(state)
    assert(
        type(hookfunction) == "function"
            and type(hookmetamethod) == "function"
            and type(getnamecallmethod) == "function"
            and type(newcclosure) == "function",
        "Your executor does not support the required remote hooks."
    )

    local getFullName = game.GetFullName
    state.Active = state.Active or setmetatable({}, { __mode = "k" })
    local active = state.Active

    local function sameArguments(a, b)
        if a.n ~= b.n then
            return false
        end
        for index = 1, a.n do
            if not rawequal(a[index], b[index]) then
                return false
            end
        end
        return true
    end

    local function isRemoteCall(remote, method)
        if typeof(remote) ~= "Instance" then
            return false
        end
        local class = remote.ClassName
        return (
            (method == "FireServer" or method == "fireServer")
            and (class == "RemoteEvent" or class == "UnreliableRemoteEvent")
        )
            or ((method == "InvokeServer" or method == "invokeServer") and class == "RemoteFunction")
    end

    local function namefunc(path)
        for _, pattern in ipairs(state.Patterns) do
            if string.match(path, pattern) then
                return true
            end
        end
        return false
    end

    local function intercept(original, source, remote, method, ...)
        if #state.Patterns == 0 then
            return original(remote, ...)
        end

        local validOk, relevant = pcall(isRemoteCall, remote, method)
        if not validOk or not relevant then
            return original(remote, ...)
        end

        local thread = coroutine.running() or mainThread
        local previous = active[thread]
        local args = pack(...)
        if
            previous
            and previous.Source ~= source
            and rawequal(previous.Remote, remote)
            and previous.Method == method
            and sameArguments(previous.Args, args)
        then
            return original(remote, ...)
        end

        local pathOK, path = pcall(getFullName, remote)
        if pathOK then
            local filterOK, matched = pcall(namefunc, path)
            if filterOK and matched == true then
                return nil
            end
        end

        active[thread] = {
            Source = source,
            Remote = remote,
            Method = method,
            Args = args,
        }
        local result = pack(pcall(original, remote, ...))
        active[thread] = previous
        if not result[1] then
            error(result[2], 0)
        end
        return unpackValues(result, 2, result.n)
    end

    local methods = {}
    for _, spec in ipairs({
        { "RemoteEvent", "FireServer" },
        { "UnreliableRemoteEvent", "FireServer" },
        { "RemoteFunction", "InvokeServer" },
    }) do
        local id = spec[1] .. "." .. spec[2]
        if not state.Installed[id] then
            local temporary
            local ok, target = pcall(function()
                temporary = Instance.new(spec[1])
                return temporary[spec[2]]
            end)
            if temporary then
                temporary:Destroy()
            end
            if ok and type(target) == "function" then
                table.insert(methods, { target = target, method = spec[2], id = id })
            end
        end
    end
    for _, spec in ipairs(methods) do
        local target, id = spec.target, spec.id
        if not state.Targets[target] then
            local original
            local ok, result = pcall(function()
                return hookfunction(
                    target,
                    newcclosure(function(remote, ...)
                        assert(type(original) == "function", "Executor did not supply original function")
                        return intercept(original, "function", remote, spec.method, ...)
                    end)
                )
            end)
            if ok and type(result) == "function" then
                original = result
                state.Targets[target] = true
            end
        end
        if state.Targets[target] then
            state.Installed[id] = true
        end
    end
    if not state.Installed.Namecall then
        local original
        local ok, result = pcall(function()
            return hookmetamethod(
                game,
                "__namecall",
                newcclosure(function(remote, ...)
                    local method = getnamecallmethod()
                    if method == "fireServer" then
                        method = "FireServer"
                    elseif method == "invokeServer" then
                        method = "InvokeServer"
                    end
                    assert(type(original) == "function", "Executor did not supply original namecall")
                    return intercept(original, "namecall", remote, method, ...)
                end)
            )
        end)
        if ok and type(result) == "function" then
            original = result
            state.Installed.Namecall = true
        end
    end
    assert(next(state.Installed) ~= nil, "Executor failed to install any remote hooks")
end

function RemoteFilter.Start(patterns, env, onError)
    local state = env[STATE_KEY]
    if state then
        state.Patterns = {}
        state.Owner = nil
        state.OnError = nil
        if state.Version ~= 1 then
            return nil, "Older remote hooks are installed. Rejoin Roblox before using this loader."
        end
    end
    local valid, copied = pcall(copyPatterns, patterns)
    if not valid then
        return nil, tostring(copied)
    end
    if not state and #copied == 0 then
        return function() end, nil, false
    end
    if not state then
        state = { Version = 1, Patterns = {}, Installed = {}, Targets = {} }
        env[STATE_KEY] = state
    end
    if #copied > 0 then
        local ok, message = pcall(install, state)
        if not ok then
            return nil, "Unable to enable the game's remote filter: " .. tostring(message)
        end
    end
    local owner = {}
    state.Owner = owner
    state.Patterns = copied
    state.OnError = onError
    return function()
        if state.Owner == owner then
            state.Patterns = {}
            state.Owner = nil
            state.OnError = nil
        end
    end,
        nil,
        #copied > 0
end

return RemoteFilter
