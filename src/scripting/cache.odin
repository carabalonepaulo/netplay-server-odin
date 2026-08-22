package scripting

import "../network"
import "base:runtime"
import c "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
import "deps:keeper"
import lua "vendor:lua/5.1"

CACHE_METATABLE :: "Network.Cache"

@(private = "file")
Callback :: struct {
	L:   ^lua.State,
	ref: c.int,
}

register_cache :: proc(L: ^lua.State, cache: ^keeper.Keeper) {
	if lua.L_newmetatable(L, CACHE_METATABLE) != 0 {
		lua.pushvalue(L, -1)
		lua.setfield(L, -2, "__index")

		methods :: []lua.L_Reg {
			{"get", cache_get},
			{"set", cache_set},
			{"delete", cache_delete},
			{"has", cache_has},
			{"cleanup", cache_cleanup},
			{nil, nil},
		}
		lua.L_register(L, nil, raw_data(methods))
	}
	lua.pop(L, 1)

	udata_ptr := (^^keeper.Keeper)(lua.newuserdata(L, size_of(^keeper.Keeper)))
	udata_ptr^ = cache

	lua.L_getmetatable(L, CACHE_METATABLE)
	lua.setmetatable(L, -2)

	lua.getfield(L, lua.REGISTRYINDEX, "_LOADED")
	lua.pushvalue(L, -2)
	lua.setfield(L, -2, "cache")

	lua.pop(L, 2)
}

@(private = "file")
get_cache :: #force_inline proc(L: ^lua.State) -> ^keeper.Keeper {
	ptr := lua.L_checkudata(L, 1, CACHE_METATABLE)
	return (^^keeper.Keeper)(ptr)^
}

// cache:get(key_str, fun(err, buf))
cache_get :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	cache := get_cache(L)
	lua.L_checktype(L, 2, c.int(lua.Type.STRING))
	lua.L_checktype(L, 3, c.int(lua.Type.FUNCTION))

	key_cstr_len: c.size_t
	key_cstr := lua.L_checkstring(L, 2, &key_cstr_len)
	if key_cstr == nil || key_cstr_len == 0 do return 0

	lua.pushvalue(L, 3)
	cb_ref := lua.L_ref(L, lua.REGISTRYINDEX)

	payload := new(Callback)
	payload.L = L
	payload.ref = cb_ref

	key := transmute(string)(([^]u8)(key_cstr)[:key_cstr_len])
	id := keeper.id(key)

	cb :: proc(err: keeper.Get_Error, buf: []u8, payload: ^Callback) {
		L := payload.L
		defer {
			lua.L_unref(L, lua.REGISTRYINDEX, payload.ref)
			free(payload)
		}

		lua.rawgeti(L, lua.REGISTRYINDEX, auto_cast payload.ref)
		if err != nil {
			err_msg_cstr := fmt.ctprint(err)
			lua.pushstring(L, err_msg_cstr)
			lua.pushnil(L)
		} else {
			lua.pushnil(L)
			if len(buf) > 0 {
				lua.pushlstring(L, auto_cast raw_data(buf), len(buf))
			} else {
				lua.pushliteral(L, "")
			}
		}

		if lua.pcall(L, 2, 0, 0) != 0 {
			msg_cstr := lua.tostring(L, -1)
			log.errorf("[lua] failed to call lua callbackL %v", msg_cstr)
			lua.pop(L, 1)
		}
	}
	keeper.get(cache, id, payload, auto_cast cb)

	return 0
}

// cache:set(key_str, val_str, fun(err))
cache_set :: proc "c" (L: ^lua.State) -> c.int {
	Payload :: struct {
		L:       ^lua.State,
		val_ref: c.int,
		cb_ref:  c.int,
	}

	context = main_ctx
	cache := get_cache(L)
	lua.L_checktype(L, 2, c.int(lua.Type.STRING))
	lua.L_checktype(L, 3, c.int(lua.Type.STRING))
	lua.L_checktype(L, 4, c.int(lua.Type.FUNCTION))

	key_cstr_len: c.size_t
	key_cstr := lua.L_checkstring(L, 2, &key_cstr_len)
	if key_cstr == nil || key_cstr_len == 0 do return 0

	val_cstr_len: c.size_t
	val_cstr := lua.L_checkstring(L, 3, &val_cstr_len)
	if val_cstr == nil || val_cstr_len == 0 do return 0

	lua.pushvalue(L, 3)
	val_ref := lua.L_ref(L, lua.REGISTRYINDEX)

	lua.pushvalue(L, 4)
	cb_ref := lua.L_ref(L, lua.REGISTRYINDEX)

	payload := new(Payload)
	payload.L = L
	payload.val_ref = val_ref
	payload.cb_ref = cb_ref

	key := transmute(string)(([^]u8)(key_cstr)[:key_cstr_len])
	val := ([^]u8)(val_cstr)[:val_cstr_len]
	id := keeper.id(key)

	cb :: proc(err: keeper.Set_Error, _: []u8, _: []u8, payload: ^Payload) {
		L := payload.L
		defer {
			lua.L_unref(L, lua.REGISTRYINDEX, payload.val_ref)
			lua.L_unref(L, lua.REGISTRYINDEX, payload.cb_ref)
			free(payload)
		}

		lua.rawgeti(L, lua.REGISTRYINDEX, auto_cast payload.cb_ref)
		if err != nil {
			err_msg_cstr := fmt.ctprint(err)
			lua.pushstring(L, err_msg_cstr)
		} else {
			lua.pushnil(L)
		}

		if lua.pcall(L, 1, 0, 0) != 0 {
			msg_cstr := lua.tostring(L, -1)
			log.errorf("[lua] failed to call lua callbackL %v", msg_cstr)
			lua.pop(L, 1)
		}
	}
	keeper.set(cache, id, val, payload, auto_cast cb)

	return 0
}

// cache:delete(str, fun(err))
cache_delete :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	cache := get_cache(L)
	lua.L_checktype(L, 2, c.int(lua.Type.STRING))
	lua.L_checktype(L, 3, c.int(lua.Type.FUNCTION))

	key_cstr_len: c.size_t
	key_cstr := lua.L_checkstring(L, 2, &key_cstr_len)
	if key_cstr == nil || key_cstr_len == 0 do return 0

	lua.pushvalue(L, 3)
	ref := lua.L_ref(L, lua.REGISTRYINDEX)

	payload := new(Callback)
	payload.L = L
	payload.ref = ref

	buf := transmute(string)(([^]u8)(key_cstr)[:key_cstr_len])
	id := keeper.id(buf)

	cb :: proc(err: keeper.Delete_Error, payload: ^Callback) {
		L := payload.L
		defer {
			lua.L_unref(L, lua.REGISTRYINDEX, payload.ref)
			free(payload)
		}

		lua.rawgeti(L, lua.REGISTRYINDEX, auto_cast payload.ref)
		if err != nil {
			err_msg_cstr := fmt.ctprint(err)
			lua.pushstring(L, err_msg_cstr)
		} else {
			lua.pushnil(L)
		}

		if lua.pcall(L, 1, 0, 0) != 0 {
			msg_cstr := lua.tostring(L, -1)
			log.errorf("[lua] failed to call lua callbackL %v", msg_cstr)
			lua.pop(L, 1)
		}
	}
	keeper.delete(cache, id, payload, auto_cast cb)

	return 0
}

// cache:has(key, fun(err, exists))
cache_has :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	cache := get_cache(L)
	lua.L_checktype(L, 2, c.int(lua.Type.STRING))
	lua.L_checktype(L, 3, c.int(lua.Type.FUNCTION))

	key_cstr_len: c.size_t
	key_cstr := lua.L_checkstring(L, 2, &key_cstr_len)
	if key_cstr == nil || key_cstr_len == 0 do return 0

	lua.pushvalue(L, 3)
	ref := lua.L_ref(L, lua.REGISTRYINDEX)

	payload := new(Callback)
	payload.L = L
	payload.ref = ref

	key := transmute(string)(([^]u8)(key_cstr)[:key_cstr_len])
	id := keeper.id(key)

	cb :: proc(err: keeper.Has_Error, exists: bool, payload: ^Callback) {
		L := payload.L
		defer {
			lua.L_unref(L, lua.REGISTRYINDEX, payload.ref)
			free(payload)
		}

		lua.rawgeti(L, lua.REGISTRYINDEX, auto_cast payload.ref)
		if err != nil {
			lua.pushboolean(L, false)
		} else {
			lua.pushboolean(L, auto_cast exists)
		}

		if lua.pcall(L, 1, 0, 0) != 0 {
			msg_cstr := lua.tostring(L, -1)
			log.errorf("[lua] failed to call lua callbackL %v", msg_cstr)
			lua.pop(L, 1)
		}
	}
	keeper.has(cache, id, payload, auto_cast cb)

	return 0
}

// cache:cleanup()
cache_cleanup :: proc "c" (L: ^lua.State) -> c.int {
	context = main_ctx
	cache := get_cache(L)
	keeper.cleanup(cache)
	return 0
}

// listener_send_to :: proc "c" (L: ^lua.State) -> c.int {
// 	context = main_ctx
// 	self := get_listener(L)
// 	id := int(lua.L_checknumber(L, 2))

// 	length: c.size_t
// 	str_ptr := lua.tolstring(L, 3, &length)

// 	if str_ptr != nil && length > 0 {
// 		buf := ([^]u8)(str_ptr)[:length]
// 		network.send_to(self, id, buf)
// 	}

// 	return 0
// }

// listener_send_to_many :: proc "c" (L: ^lua.State) -> c.int {
// 	context = main_ctx
// 	self := get_listener(L)

// 	lua.L_checktype(L, 2, c.int(lua.Type.STRING))
// 	lua.L_checktype(L, 3, c.int(lua.Type.FUNCTION))

// 	str_len: c.size_t
// 	str_ptr := lua.tolstring(L, 2, &str_len)
// 	if str_ptr == nil || str_len == 0 do return 0

// 	buf := ([^]u8)(str_ptr)[:str_len]

// 	filter :: proc(id: int, L: ^lua.State) -> bool {
// 		lua.pushvalue(L, 3)
// 		lua.pushnumber(L, lua.Number(id))

// 		if lua.pcall(L, 1, 1, 0) != 0 {
// 			lua.pop(L, 1)
// 			return false
// 		}

// 		result := bool(lua.toboolean(L, -1))
// 		lua.pop(L, 1)
// 		return result
// 	}
// 	network.send_to_many(self, buf, L, auto_cast filter)

// 	return 0
// }

// listener_send_to_all :: proc "c" (L: ^lua.State) -> c.int {
// 	context = main_ctx
// 	self := get_listener(L)

// 	length: c.size_t
// 	str_ptr := lua.tolstring(L, 2, &length)

// 	if str_ptr != nil && length > 0 {
// 		buf := ([^]u8)(str_ptr)[:length]
// 		network.send_to_all(self, buf)
// 	}

// 	return 0
// }

// listener_kick :: proc "c" (L: ^lua.State) -> c.int {
// 	context = main_ctx
// 	self := get_listener(L)
// 	id := int(lua.L_checknumber(L, 2))

// 	network.kick(self, id)
// 	return 0
// }

// listener_kick_many :: proc "c" (L: ^lua.State) -> c.int {
// 	context = main_ctx
// 	self := get_listener(L)
// 	lua.L_checktype(L, 2, c.int(lua.Type.FUNCTION))

// 	filter :: proc(id: int, L: ^lua.State) -> bool {
// 		lua.pushvalue(L, 2)
// 		lua.pushnumber(L, lua.Number(id))

// 		if lua.pcall(L, 1, 1, 0) != 0 {
// 			lua.pop(L, 1)
// 			return false
// 		}

// 		result := bool(lua.toboolean(L, -1))
// 		lua.pop(L, 1)
// 		return result
// 	}
// 	network.kick_many(self, L, auto_cast filter)

// 	return 0
// }

