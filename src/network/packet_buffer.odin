package network

import "core:mem"

BUFFER_SIZE :: 4096

Packet_Buffer_Error :: enum {
	None = 0,
	Overflow,
	Underflow,
}

Packet_Buffer :: struct {
	buf: ^[BUFFER_SIZE]u8,
	pos: int,
}

Packet_Handler :: #type proc(packet: []u8, ud: rawptr)

packet_buffer_init :: proc(self: ^Packet_Buffer) {
	self.buf = new([BUFFER_SIZE]u8)
	self.pos = 0
}

packet_buffer_destroy :: proc(self: ^Packet_Buffer) {
	if self.buf != nil {
		free(self.buf)
		self.buf = nil
	}
}

packet_buffer_push :: proc(self: ^Packet_Buffer, buf: []u8) -> Packet_Buffer_Error {
	if len(buf) == 0 do return .None

	if self.pos + len(buf) > BUFFER_SIZE {
		return .Overflow
	}

	dest_slice := self.buf[self.pos:self.pos + len(buf)]
	mem.copy(raw_data(dest_slice), raw_data(buf), len(buf))

	self.pos += len(buf)
	return .None
}

packet_buffer_read :: proc(
	self: ^Packet_Buffer,
	handler: Packet_Handler,
	ud: rawptr = nil,
) -> bool {
	if self.pos == 0 {
		return false
	}

	newline_idx := -1
	for i := 0; i < self.pos; i += 1 {
		if self.buf[i] == '\n' {
			newline_idx = i
			break
		}
	}

	if newline_idx == -1 {
		return false
	}

	packet_size := newline_idx + 1
	src_slice := self.buf[0:packet_size]
	handler(src_slice, ud)

	remaining_bytes := self.pos - packet_size
	if remaining_bytes > 0 {
		src_remaining := raw_data(self.buf[packet_size:self.pos])
		dest_start := raw_data(self.buf[0:remaining_bytes])
		mem.copy(dest_start, src_remaining, remaining_bytes)
	}

	self.pos = remaining_bytes
	return true
}

