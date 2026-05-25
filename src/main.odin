package main

import "core:bufio"
import "core:container/queue"
import "core:fmt"
import "core:net"
import "core:os"
import "core:sys/windows"
import "core:thread"
import "core:time"

import "network"
import "scripting"

should_run := true

ctrl_c_handler :: proc "stdcall" (ctrl_type: windows.DWORD) -> windows.BOOL {
	switch ctrl_type {
	case windows.CTRL_C_EVENT, windows.CTRL_CLOSE_EVENT:
		should_run = false
		windows.Sleep(1000)
		return windows.TRUE
	}
	return windows.FALSE
}

main :: proc() {
	windows.SetConsoleCtrlHandler(ctrl_c_handler, true)
	defer os.exit(1)

	listener, err := network.init("0.0.0.0:5009")
	if err != .None {
		fmt.println("failed to init listener")
		return
	}
	defer network.close(&listener)

	scripting.init(&listener)
	defer scripting.deinit()

	for should_run {
		network.poll(&listener)

		for queue.len(listener.evs) > 0 {
			ev := queue.pop_front(&listener.evs)

			switch e in ev {
			case network.Client_Connected_Event:
				scripting.on_connected(e.id)
			case network.Client_Disconnected_Event:
				scripting.on_disconnected(e.id)
			case network.Data_Received_Event:
				scripting.on_packet_received(e.id, e.buf)
			}

			network.destroy(&ev)
		}

		scripting.poll()
	}
}

