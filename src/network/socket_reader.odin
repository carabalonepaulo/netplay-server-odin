package network

import "core:fmt"
import "core:io"
import "core:net"

Socket_Stream :: struct {
	socket: net.TCP_Socket,
}

init_socket_stream :: proc(socket: net.TCP_Socket) -> (Socket_Stream, io.Reader) {
	sr := Socket_Stream {
		socket = socket,
	}

	reader := io.Reader {
		data      = &sr,
		procedure = socket_stream_proc,
	}

	return sr, reader
}

@(private)
socket_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []u8,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	stream := (^Socket_Stream)(stream_data)

	if mode != .Read {
		return 0, io.Error.Unknown
	}

	read, recv_err := net.recv(stream.socket, p)

	#partial switch recv_err {
	case .Would_Block:
		return 0, .No_Progress
	case nil:
		if read == 0 {
			return 0, io.Error.EOF
		}
		return i64(read), nil
	case:
		return 0, io.Error.EOF
	}
}

