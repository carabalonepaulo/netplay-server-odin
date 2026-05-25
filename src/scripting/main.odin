package scripting

import "../network"
import "base:runtime"
import "core:fmt"
import lua "vendor:lua/5.1"

Callbacks :: struct {
	on_init:                i32,
	on_deinit:              i32,
	on_client_connected:    i32,
	on_client_disconnected: i32,
	on_packet_received:     i32,
	on_update:              i32,
}

main_ctx: runtime.Context
state: ^lua.State
callbacks: Callbacks

init :: proc(listener: ^network.Listener) {
	main_ctx = context

	state = lua.L_newstate()
	lua.L_openlibs(state)

	register_listener(state, listener)

	if load_script(state) {
		call_void_callback(callbacks.on_init)
	}
}

deinit :: proc() {
	call_void_callback(callbacks.on_deinit)
	lua.close(state)
}

on_connected :: proc(id: int) {
	if callbacks.on_client_connected <= 0 do return
	lua.rawgeti(state, lua.REGISTRYINDEX, lua.Integer(callbacks.on_client_connected))
	lua.pushinteger(state, lua.Integer(id))

	if lua.pcall(state, 1, 0, 0) != i32(lua.OK) {
		fmt.eprintfln("failed to call on_client_connected: %s", lua.tostring(state, -1))
		lua.pop(state, 1)
	}
}

on_disconnected :: proc(id: int) {
	if callbacks.on_client_connected <= 0 do return
	lua.rawgeti(state, lua.REGISTRYINDEX, lua.Integer(callbacks.on_client_disconnected))
	lua.pushinteger(state, lua.Integer(id))

	if lua.pcall(state, 1, 0, 0) != i32(lua.OK) {
		fmt.eprintfln("failed to call on_client_disconnected: %s", lua.tostring(state, -1))
		lua.pop(state, 1)
	}
}

on_packet_received :: proc(id: int, packet: []u8) {
	if callbacks.on_packet_received <= 0 do return

	lua.rawgeti(state, lua.REGISTRYINDEX, lua.Integer(callbacks.on_packet_received))
	lua.pushinteger(state, lua.Integer(id))
	lua.pushlstring(state, cstring(raw_data(packet)), len(packet))

	if lua.pcall(state, 2, 0, 0) != i32(lua.OK) {
		fmt.eprintfln("failed to call on_packet_received: %s", lua.tostring(state, -1))
		lua.pop(state, 1)
	}
}

poll :: proc() {
	call_void_callback(callbacks.on_update)
}

@(private)
get_callback :: proc(L: ^lua.State, key: cstring) -> i32 {
	lua.getfield(L, -1, key)
	if lua.isfunction(L, -1) {
		return lua.L_ref(L, lua.REGISTRYINDEX)
	}

	lua.pop(L, 1)
	return -2
}

@(private)
load_script :: proc(L: ^lua.State) -> bool {
	if lua.L_dofile(L, "./scripts/main.lua") != i32(lua.OK) {
		fmt.eprintfln("failed to load script: %s", lua.tostring(L, -1))
		lua.pop(L, 1)
		return false
	}

	if !lua.istable(L, -1) {
		fmt.eprintfln("main must return a table with callbacks")
		lua.pop(L, 1)
		return false
	}

	callbacks.on_init = get_callback(L, "on_init")
	callbacks.on_deinit = get_callback(L, "on_deinit")
	callbacks.on_client_connected = get_callback(L, "on_client_connected")
	callbacks.on_client_disconnected = get_callback(L, "on_client_disconnected")
	callbacks.on_packet_received = get_callback(L, "on_packet_received")
	callbacks.on_update = get_callback(L, "on_update")

	lua.pop(L, 1)
	return true
}

@(private)
call_void_callback :: proc(ref: i32) {
	if ref <= 0 do return

	lua.rawgeti(state, lua.REGISTRYINDEX, lua.Integer(ref))

	if lua.pcall(state, 0, 0, 0) != i32(lua.OK) {
		fmt.eprintfln("failed to call function: %s", lua.tostring(state, -1))
		lua.pop(state, 1)
	}
}

