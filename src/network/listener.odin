package server_network

import "base:runtime"
import "core:container/intrusive/list"
import "core:mem"
import "core:nbio"
import "core:net"

import "../config"
import cb "deps:circular_buffer"

INDEX_BITS :: 16
INDEX_MASK :: (1 << INDEX_BITS) - 1

Callbacks :: struct {
	client_connected:    proc(id: int),
	client_disconnected: proc(id: int),
	packet_received:     proc(id: int, buf: []u8),
}

Should_Close :: enum {
	No,
	Now,
	Later,
}

Client_Flag :: enum {
	Sending,
	Receiving,
	Close_Later,
	Close_Now,
}

Client_Flags :: bit_set[Client_Flag]

Client :: struct {
	id:       int,
	sock:     nbio.TCP_Socket,
	flags:    Client_Flags,
	node:     list.Node,
	send_buf: cb.Circular_Buffer,
	recv_buf: cb.Circular_Buffer,
}

Listener :: struct {
	sock:        nbio.TCP_Socket,
	used_list:   list.List,
	free_list:   list.List,
	temp:        []u8,
	clients_buf: []u8,
	clients:     []Client,
	callbacks:   Callbacks,
}

init :: proc(self: ^Listener, callbacks: Callbacks) -> (ok: bool) {
	assert(callbacks.client_connected != nil)
	assert(callbacks.client_disconnected != nil)
	assert(callbacks.packet_received != nil)

	n := &config.get().network

	ep := nbio.Endpoint{net.IP4_Any, n.port}
	sock, listen_err := nbio.listen_tcp(ep)
	if listen_err != nil do return false

	buf_size := n.max_packet_size * 2
	total_size := (n.max_clients * buf_size * 2) + n.max_packet_size

	clients_buf, buf_err := make([]u8, total_size)
	if buf_err != nil do return false
	defer if !ok do delete(clients_buf)

	clients, clients_err := make([]Client, n.max_clients)
	if clients_err != nil do return false
	defer if !ok do delete(clients)

	arena: mem.Arena
	mem.arena_init(&arena, clients_buf)
	arena_alloc := mem.arena_allocator(&arena)

	for &c, i in clients {
		c.id = pack_key(i, 1)
		c.send_buf = cb.create(make([]u8, buf_size, arena_alloc))
		c.recv_buf = cb.create(make([]u8, buf_size, arena_alloc))

		list.push_back(&self.free_list, &c.node)
	}

	self.callbacks = callbacks
	self.sock = sock
	self.clients = clients
	self.clients_buf = clients_buf
	self.temp = make([]u8, n.max_packet_size, arena_alloc)

	op := nbio.accept(self.sock, on_accept)
	op.user_data[0] = self

	return true
}

deinit :: proc(self: ^Listener) {
	delete(self.clients_buf)
	delete(self.clients)
}

poll :: proc(self: ^Listener) {
	curr := self.used_list.head
	for curr != nil {
		next := curr.next

		client := container_of(curr, Client, "node")

		no_io := (client.flags & {.Sending, .Receiving}) == {}
		is_force := .Close_Now in client.flags
		is_drain := .Close_Later in client.flags && client.send_buf.ra == 0

		if (is_force || is_drain) && no_io {
			nbio.close(client.sock)

			list.remove(&self.used_list, &client.node)
			list.push_back(&self.free_list, &client.node)

			old_id := client.id
			c_idx, c_gen := unpack_key(client.id)
			client.id = pack_key(c_idx, c_gen + 1)
			client.flags = {}
			cb.clear(&client.send_buf)
			cb.clear(&client.recv_buf)

			self.callbacks.client_disconnected(old_id)

			curr = next
			continue
		}

		if .Close_Now in client.flags {
			curr = next
			continue
		}

		if .Sending not_in client.flags {
			buf := cb.peek_read(&client.send_buf)
			if len(buf) > 0 {
				op := nbio.send(client.sock, {buf}, on_send)
				op.user_data[0] = self
				op.user_data[1] = transmute(rawptr)(client.id)
				client.flags += {.Sending}
			}
		}

		if client.flags & {.Close_Later, .Receiving} == {} {
			buf := cb.peek_write(&client.recv_buf)
			if len(buf) > 0 {
				client.flags += {.Receiving}
				op := nbio.recv(client.sock, {buf}, on_recv)
				op.user_data[0] = self
				op.user_data[1] = transmute(rawptr)(client.id)
			}
		}

		for {
			idx := cb.index_of(&client.recv_buf, '\n')
			if idx == -1 {
				if client.recv_buf.wa == 0 do client.flags += {.Close_Now}
				break
			}

			packet_len := idx + 1
			if packet_len > len(self.temp) {
				client.flags += {.Close_Now}
				break
			}

			dst := self.temp[:idx + 1]
			cb.read(&client.recv_buf, dst)

			self.callbacks.packet_received(client.id, dst)
		}

		curr = next
	}
}

send_to :: proc(self: ^Listener, id: int, buf: []u8) {
	client := get_client(self.clients, id)
	if client != nil do cb.write(&client.send_buf, buf)
}

send_to_many :: proc(
	self: ^Listener,
	buf: []u8,
	ud: rawptr,
	filter: proc(id: int, ud: rawptr) -> bool,
) {
	curr := self.used_list.head
	for curr != nil {
		client := container_of(curr, Client, "node")
		active := client.flags & {.Close_Now, .Close_Later} == {}
		if active && filter(client.id, ud) do cb.write(&client.send_buf, buf)
		curr = curr.next
	}
}

send_to_all :: proc(self: ^Listener, buf: []u8) {
	curr := self.used_list.head
	for curr != nil {
		client := container_of(curr, Client, "node")
		active := client.flags & {.Close_Now, .Close_Later} == {}
		if active do cb.write(&client.send_buf, buf)
		curr = curr.next
	}
}

kick :: proc(self: ^Listener, id: int) {
	client := get_client(self.clients, id)
	if client != nil do client.flags += {.Close_Later}
}

kick_many :: proc(self: ^Listener, ud: rawptr, filter: proc(id: int, ud: rawptr) -> bool) {
	curr := self.used_list.head
	for curr != nil {
		client := container_of(curr, Client, "node")
		if filter(client.id, ud) do client.flags += {.Close_Later}
		curr = curr.next
	}
}

@(private = "file")
on_accept :: proc(op: ^nbio.Operation) {
	self := (^Listener)(op.user_data[0])
	should_accept := true
	defer if should_accept {
		op := nbio.accept(self.sock, on_accept)
		op.user_data[0] = self
	}

	if op.accept.err != .None {
		should_accept = op.accept.err == .Aborted
		return
	}

	node := list.pop_front(&self.free_list)
	if node == nil {
		nbio.close(op.accept.socket)
		return
	}
	list.push_back(&self.used_list, node)

	client := container_of(node, Client, "node")
	client.sock = op.accept.client
	client.flags = {.Receiving}
	cb.clear(&client.send_buf)
	cb.clear(&client.recv_buf)

	op := nbio.recv(client.sock, {cb.peek_write(&client.recv_buf)}, on_recv)
	op.user_data[0] = self
	op.user_data[1] = transmute(rawptr)(client.id)

	self.callbacks.client_connected(client.id)
}

@(private = "file")
on_recv :: proc(op: ^nbio.Operation) {
	self := (^Listener)(op.user_data[0])
	id := transmute(int)(op.user_data[1])

	client := get_client(self.clients, id)
	if client == nil do return
	client.flags -= {.Receiving}

	if op.recv.err != nil || op.recv.received == 0 {
		client.flags += {.Close_Now}
		return
	}

	cb.commit_write(&client.recv_buf, op.recv.received)

	write_buf := cb.peek_write(&client.recv_buf)
	if len(write_buf) > 0 {
		client.flags += {.Receiving}
		op := nbio.recv(client.sock, {write_buf}, on_recv)
		op.user_data[0] = self
		op.user_data[1] = transmute(rawptr)(client.id)
	}
}

@(private = "file")
on_send :: proc(op: ^nbio.Operation) {
	self := (^Listener)(op.user_data[0])
	id := transmute(int)(op.user_data[1])

	client := get_client(self.clients, id)
	if client == nil do return
	client.flags -= {.Sending}

	if op.send.err != nil {
		client.flags += {.Close_Now}
		return
	}

	cb.commit_read(&client.send_buf, op.send.sent)
}

@(private)
pack_key :: #force_inline proc(idx: int, gen: int) -> int {
	return ((gen & INDEX_MASK) << INDEX_BITS) | (idx & INDEX_MASK)
}

@(private)
unpack_key :: #force_inline proc(key: int) -> (idx: int, gen: int) {
	return key & INDEX_MASK, (key >> INDEX_BITS) & INDEX_MASK
}

@(private)
get_client :: #force_inline proc(clients: []Client, id: int) -> (client: ^Client) {
	idx, gen := unpack_key(id)
	if idx < 0 || idx >= len(clients) do return nil

	#no_bounds_check {
		client = &clients[idx]
	}

	c_gen := (client.id >> INDEX_BITS) & INDEX_MASK
	if gen != c_gen do return nil

	return client
}

