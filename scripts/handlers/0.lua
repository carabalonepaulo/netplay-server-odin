local packet = require 'scripts.packet'
local server_name = 'NetPlay Server'

return function(sender_id)
    listener:send_to(sender_id, string.format("<0 %d>'e' n=%s</0>\n", sender_id, server_name))
end
