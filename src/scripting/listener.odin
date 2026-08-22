package scripting

import "../network"
import c "core:c"
import lua "vendor:lua/5.1"

LISTENER_METATABLE :: "Network.Listener"

register_listener :: proc(L: ^lua.State, listener: ^network.Listener) {
	lua.L_newmetatable(L, LISTENER_METATABLE)

	lua.pushvalue(L, -1)
	lua.setfield(L, -2, "__index")

	lua.pushstring(L, "send_to")
	lua.pushcfunction(L, listener_send_to)
	lua.settable(L, -3)

	lua.pushstring(L, "send_to_many")
	lua.pushcfunction(L, listener_send_to_many)
	lua.settable(L, -3)

	lua.pushstring(L, "send_to_all")
	lua.pushcfunction(L, listener_send_to_all)
	lua.settable(L, -3)

	lua.pushstring(L, "kick")
	lua.pushcfunction(L, listener_kick)
	lua.settable(L, -3)

	lua.pushstring(L, "kick_many")
	lua.pushcfunction(L, listener_kick)
	lua.settable(L, -3)

	lua.pop(L, 1)

	udata_ptr := (^^network.Listener)(lua.newuserdata(L, size_of(^network.Listener)))
	udata_ptr^ = listener

	lua.L_getmetatable(L, LISTENER_METATABLE)
	lua.setmetatable(L, -2)

	lua.setglobal(L, "listener")
}

get_listener :: #force_inline proc(L: ^lua.State) -> ^network.Listener {
	ptr := lua.L_checkudata(L, 1, LISTENER_METATABLE)
	return (^^network.Listener)(ptr)^
}

listener_send_to :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	self := get_listener(L)
	id := int(lua.L_checknumber(L, 2))

	length: c.size_t
	str_ptr := lua.tolstring(L, 3, &length)

	if str_ptr != nil && length > 0 {
		buf := ([^]u8)(str_ptr)[:length]
		network.send_to(self, id, buf)
	}

	return 0
}

listener_send_to_many :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	self := get_listener(L)

	lua.L_checktype(L, 2, c.int(lua.Type.STRING))
	lua.L_checktype(L, 3, c.int(lua.Type.FUNCTION))

	str_len: c.size_t
	str_ptr := lua.tolstring(L, 2, &str_len)
	if str_ptr == nil || str_len == 0 do return 0

	buf := ([^]u8)(str_ptr)[:str_len]

	filter :: proc(id: int, L: ^lua.State) -> bool {
		lua.pushvalue(L, 3)
		lua.pushnumber(L, lua.Number(id))

		if lua.pcall(L, 1, 1, 0) != 0 {
			lua.pop(L, 1)
			return false
		}

		result := bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		return result
	}
	network.send_to_many(self, buf, L, auto_cast filter)

	return 0
}

listener_send_to_all :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	self := get_listener(L)

	length: c.size_t
	str_ptr := lua.tolstring(L, 2, &length)

	if str_ptr != nil && length > 0 {
		buf := ([^]u8)(str_ptr)[:length]
		network.send_to_all(self, buf)
	}

	return 0
}

listener_kick :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	self := get_listener(L)
	id := int(lua.L_checknumber(L, 2))

	network.kick(self, id)
	return 0
}

listener_kick_many :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	self := get_listener(L)
	lua.L_checktype(L, 2, c.int(lua.Type.FUNCTION))

	filter :: proc(id: int, L: ^lua.State) -> bool {
		lua.pushvalue(L, 2)
		lua.pushnumber(L, lua.Number(id))

		if lua.pcall(L, 1, 1, 0) != 0 {
			lua.pop(L, 1)
			return false
		}

		result := bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		return result
	}
	network.kick_many(self, L, auto_cast filter)

	return 0
}

