local keeper = require 'keeper'
local printf = require 'scripts.printf'
local router = require 'scripts.router'

return {
    on_init = function()
        print("[lua] init")
    end,

    on_deinit = function()
        print("[lua] deinit")
    end,

    on_client_connected = function(id)
        printf("[lua] client %d connected", id)
    end,

    on_client_disconnected = function(id)
        printf("[lua] client %d disconnected", id)
    end,

    on_packet_received = function(id, line)
        printf("[lua] packet received from client %d: %s", id, line:gsub('\n', ''))
        router(id, line)
    end,

    on_update = function()
    end
}
