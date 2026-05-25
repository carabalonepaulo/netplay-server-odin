local packet = require 'scripts.packet'
local state = require 'scripts.state'

return function(sender_id, tag, content)
    local player = state.players[sender_id]
    local name = player and player.name or ''
    packet.send_to_all("chat", string.format("Sad for us, %s left the game", name))
end
