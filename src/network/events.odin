package network

import "core:container/queue"

Client_Connected_Event :: struct {
	id: int,
}

Data_Received_Event :: struct {
	id:  int,
	buf: cstring,
}

Client_Disconnected_Event :: struct {
	id: int,
}

Event :: union {
	Client_Connected_Event,
	Data_Received_Event,
	Client_Disconnected_Event,
}

Events :: queue.Queue(Event)

