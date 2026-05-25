local printf = require 'scripts.printf'

return function(sender_id, tag, content)
    printf('default handler for packet: %s', tag)
end
