package server

import "core:math/bits"
import "core:nbio"

import "config"
import "network"
import "scripting"

import "deps:ctrl_c"

main :: proc() {
	assert(config.load(), "failed to load config")
	defer config.unload()

	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	max_clients := config.get().network.max_clients
	assert(max_clients > 0 && max_clients <= bits.U16_MAX)

	ctrl_c.hook()

	callbacks := network.Callbacks {
		client_connected    = scripting.on_connected,
		client_disconnected = scripting.on_disconnected,
		packet_received     = scripting.on_packet_received,
	}

	listener: network.Listener
	assert(network.init(&listener, callbacks), "failed to init listener")
	defer network.deinit(&listener)

	scripting.init(&listener)
	defer scripting.deinit()

	for !ctrl_c.should_quit() {
		nbio.tick(0)
		network.poll(&listener)
		scripting.poll()
	}
}

