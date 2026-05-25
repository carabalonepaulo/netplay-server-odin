package network

import "../config"
import "core:mem"


Send_Buffer :: struct {
	buf:         []u8,
	w:           int,
	r:           int,
	available_w: int,
	available_r: int,
}

send_buffer_init :: proc(self: ^Send_Buffer) {
	send_buffer_size := config.get().buffer_size * 2
	self.buf = make([]u8, send_buffer_size)
	self.w = 0
	self.r = 0
	self.available_r = 0
	self.available_w = send_buffer_size
}

send_buffer_destroy :: proc(self: ^Send_Buffer) {
	if self.buf != nil {
		delete(self.buf)
		self.buf = nil
	}
}

send_buffer_push :: proc(self: ^Send_Buffer, buf: []u8) -> bool {
	if self.available_w < len(buf) {
		return false
	}

	send_buffer_size := len(self.buf)
	size := len(buf)
	bytes_to_end := send_buffer_size - self.w

	if size <= bytes_to_end {
		mem.copy(&self.buf[self.w], raw_data(buf), size)
		self.w = (self.w + size) % send_buffer_size
	} else {
		mem.copy(&self.buf[self.w], raw_data(buf), bytes_to_end)
		remaining := size - bytes_to_end
		mem.copy(&self.buf[0], &buf[bytes_to_end], remaining)
		self.w = remaining
	}

	self.available_w -= size
	self.available_r += size
	return true
}

send_buffer_peek :: proc(self: ^Send_Buffer) -> []u8 {
	if self.available_r == 0 {
		return nil
	}

	bytes_to_end := len(self.buf) - self.r
	chunk_size := min(self.available_r, bytes_to_end)
	return self.buf[self.r:self.r + chunk_size]
}

send_buffer_roll :: proc(self: ^Send_Buffer, n: int) {
	if n <= 0 do return

	self.r = (self.r + n) % len(self.buf)
	self.available_r -= n
	self.available_w += n
}

