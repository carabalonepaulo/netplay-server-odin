local packet = require 'scripts.packet'
local handlers = {}

return function(sender_id, line)
    local tag, content = packet.parse(line)
    local clean_tag = tag:sub(2, #tag - 1)

    if not handlers[clean_tag] then
        local success, handler = pcall(require, 'scripts.handlers.' .. clean_tag)
        if success then
            handlers[clean_tag] = handler
        else
            handlers[clean_tag] = require 'scripts.handlers.default'
        end
    end

    handlers[clean_tag](sender_id, tag, content)
end
