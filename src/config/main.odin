package config

import "core:encoding/json"
import "core:os"

Network_Config :: struct {
	port:            int,
	max_clients:     int,
	max_packet_size: int,
}

Lua_Config :: struct {
	entry: string,
}

Config :: struct {
	network: Network_Config,
	lua:     Lua_Config,
}

_config := Config {
	network = {port = 5009, max_clients = 256, max_packet_size = 1024},
	lua = {entry = "scripts/main.lua"},
}

get :: #force_inline proc() -> ^Config {
	return &_config
}

load :: proc() -> (ok: bool) {
	buf, read_err := os.read_entire_file("config.json", context.allocator)
	if read_err != nil do return false
	defer delete(buf)

	json_err := json.unmarshal(buf, &_config)
	if json_err != nil do return false

	return true
}

unload :: proc() {
	delete(_config.lua.entry)
}

