package network

import "core:mem"

SEND_BUFFER_SIZE :: BUFFER_SIZE * 2

Send_Buffer :: struct {
	buf:         ^[SEND_BUFFER_SIZE]u8,
	w:           int,
	r:           int,
	available_w: int,
	available_r: int,
}

send_buffer_init :: proc(self: ^Send_Buffer) {
	self.buf = new([SEND_BUFFER_SIZE]u8)
	self.w = 0
	self.r = 0
	self.available_r = 0
	self.available_w = SEND_BUFFER_SIZE
}

send_buffer_destroy :: proc(self: ^Send_Buffer) {
	if self.buf != nil {
		free(self.buf)
		self.buf = nil
	}
}

send_buffer_push :: proc(self: ^Send_Buffer, buf: []u8) -> bool {
	if self.available_w < len(buf) {
		return false
	}

	size := len(buf)
	bytes_to_end := SEND_BUFFER_SIZE - self.w

	if size <= bytes_to_end {
		mem.copy(&self.buf[self.w], raw_data(buf), size)
		self.w = (self.w + size) % SEND_BUFFER_SIZE
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

	bytes_to_end := SEND_BUFFER_SIZE - self.r
	chunk_size := min(self.available_r, bytes_to_end)
	return self.buf[self.r:self.r + chunk_size]
}

send_buffer_roll :: proc(self: ^Send_Buffer, n: int) {
	if n <= 0 do return

	self.r = (self.r + n) % SEND_BUFFER_SIZE
	self.available_r -= n
	self.available_w += n
}

