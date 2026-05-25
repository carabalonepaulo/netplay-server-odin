package network

import "core:bufio"
import "core:container/queue"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:strings"

import "../constants"

Init_Error :: enum {
	None,
	Invalid_Endpoint,
	Create_Socket_Failed,
}

Client :: struct {
	ep:         net.Endpoint,
	sock:       net.TCP_Socket,
	packet_buf: Packet_Buffer,
	send_buf:   Send_Buffer,
}

Client_Slot :: struct {
	active: bool,
	client: Client,
}

Listener :: struct {
	evs:     Events,
	ep:      net.Endpoint,
	sock:    net.TCP_Socket,
	clients: [constants.MAX_CLIENTS]Client_Slot,
	buf:     [BUFFER_SIZE]u8,
}

init :: proc(endpoint_str: string) -> (listener: Listener, err: Init_Error) {
	ep, ok := net.parse_endpoint(endpoint_str)
	if !ok {
		err = .Invalid_Endpoint
		return
	}

	sock, listen_err := net.listen_tcp(ep)
	if listen_err != nil {
		err = .Create_Socket_Failed
		return
	}
	net.set_blocking(sock, false)

	listener.ep = ep
	listener.sock = sock
	queue.init(&listener.evs)

	return
}

poll :: proc(self: ^Listener) {
	try_accept(self)

	for &slot, i in self.clients {
		if !slot.active {
			continue
		}

		try_recv(self, i, &slot.client)
		try_send(self, i, &slot.client)
	}
}


send_to :: proc(self: ^Listener, id: int, buf: []u8) {
	if id < 0 || id >= len(self.clients) || !self.clients[id].active {
		return
	}
	send_buffer_push(&self.clients[id].client.send_buf, buf)
}

send_to_all :: proc(self: ^Listener, buf: []u8) {
	for &slot, _ in self.clients {
		if !slot.active {
			continue
		}
		send_buffer_push(&slot.client.send_buf, buf)
	}
}

kick :: proc(self: ^Listener, id: int) {
	if self.clients[id].active {
		client := &self.clients[id].client
		send_buffer_destroy(&client.send_buf)
		packet_buffer_destroy(&client.packet_buf)
		net.close(client.sock)
		client^ = {}
		self.clients[id].active = false
		queue.push_back(&self.evs, Event(Client_Disconnected_Event{id = id}))
	}
}

close :: proc(self: ^Listener) {
	for _, i in self.clients {
		kick(self, i)
	}
	net.close(self.sock)
}

destroy :: proc(ev: ^Event) {
	#partial switch e in ev {
	case Data_Received_Event:
		delete(e.buf)
		return
	}
}

@(private)
try_accept :: proc(self: ^Listener) {
	client_sock, client_ep, accept_err := net.accept_tcp(self.sock)
	if accept_err == .None {
		idx := find_empty_slot(self.clients[:])
		if idx == -1 {
			fmt.println("can't accept clients, limit reached")
			net.close(client_sock)
			return
		}

		block_err := net.set_blocking(client_sock, false)
		if block_err != nil {
			fmt.println("[panic] failed to set socket as non blocking")
			net.close(client_sock)
			return
		}

		net.set_option(client_sock, .TCP_Nodelay, true)

		self.clients[idx].active = true
		client := &self.clients[idx].client

		client.ep = client_ep
		client.sock = client_sock

		packet_buffer_init(&client.packet_buf)
		send_buffer_init(&client.send_buf)

		queue.push_back(&self.evs, Event(Client_Connected_Event{id = idx}))
	}
}

PacketHandlerCtx :: struct {
	listener: ^Listener,
	id:       int,
}

@(private)
try_recv :: proc(self: ^Listener, id: int, client: ^Client) {
	n, recv_err := net.recv_tcp(client.sock, self.buf[:])

	#partial switch recv_err {
	case .Would_Block:
		return
	case nil:
		if n == 0 {
			kick(self, id)
		} else {
			packet_buffer_push(&client.packet_buf, self.buf[:n])
			handler :: proc(packet: []u8, ud: rawptr) {
				ctx := (^PacketHandlerCtx)(ud)
				temp := string(packet)
				cstr := strings.clone_to_cstring(temp)

				queue.push_back(
					&ctx.listener.evs,
					Event(Data_Received_Event{id = ctx.id, buf = cstr}),
				)
			}

			ctx := PacketHandlerCtx {
				listener = self,
				id       = id,
			}

			for packet_buffer_read(&client.packet_buf, handler, &ctx) {}
		}
	case:
		kick(self, id)
	}
}

@(private)
try_send :: proc(self: ^Listener, id: int, client: ^Client) {
	for {
		chunk := send_buffer_peek(&client.send_buf)
		if len(chunk) == 0 {
			break
		}

		n, send_err := net.send_tcp(client.sock, chunk)
		if n > 0 {
			send_buffer_roll(&client.send_buf, n)
		}

		if send_err == .Would_Block {
			break
		} else if send_err != nil {
			kick(self, id)
			break
		}

		if n < len(chunk) {
			break
		}
	}
}

@(private)
find_empty_slot :: proc(clients: []Client_Slot) -> int {
	for &client, i in clients {
		if !client.active {
			return i
		}
	}
	return -1
}

