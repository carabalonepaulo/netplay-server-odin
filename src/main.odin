package server

import "core:math/bits"
import "core:mem"
import "core:nbio"
import "core:time"

import "config"
import "network"
import "scripting"

import "deps:ctrl_c"
import "deps:keeper"

main :: proc() {
	assert(config.load(), "failed to load config")
	defer config.unload()

	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	max_clients := config.get().network.max_clients
	assert(max_clients > 0 && max_clients <= bits.U16_MAX)

	ctrl_c.hook()

	c := &config.get().cache
	opts := keeper.Options {
		dir              = c.dir,
		cleanup_interval = time.Duration(c.cleanup_interval) * time.Minute,
		max_ram          = c.max_ram * mem.Megabyte,
		max_permits      = c.max_permits,
		max_tasks        = c.max_tasks,
	}
	cache: keeper.Keeper
	keeper.init(&cache, opts)
	defer keeper.deinit(&cache)

	callbacks := network.Callbacks {
		client_connected    = scripting.on_connected,
		client_disconnected = scripting.on_disconnected,
		packet_received     = scripting.on_packet_received,
	}

	listener: network.Listener
	assert(network.init(&listener, callbacks), "failed to init listener")
	defer network.deinit(&listener)

	scripting.init(&listener, &cache)
	defer scripting.deinit()

	for !ctrl_c.should_quit() {
		nbio.tick(0)
		network.poll(&listener)
		keeper.poll(&cache, 0)
		scripting.poll()
	}
}

