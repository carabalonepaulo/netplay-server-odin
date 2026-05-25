local packet = require 'scripts.packet'

return function(sender_id, tag, content)
    packet.send_to(sender_id, tag, 'hello world')
end
