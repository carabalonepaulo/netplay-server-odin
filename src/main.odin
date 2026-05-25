package main

import "core:fmt"
import "core:os"
import "core:sys/windows"

import "config"
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
	init_ok := config.init()
	if !init_ok {
		fmt.eprintln("failed to load config")
		return
	}

	windows.SetConsoleCtrlHandler(ctrl_c_handler, true)
	defer os.exit(1)

	addr := fmt.aprintf("0.0.0.0:%d", config.get().port)
	defer delete(addr)

	listener, err := network.init(addr)
	if err != .None {
		fmt.println("failed to init listener")
		return
	}
	defer network.close(&listener)

	scripting.init(&listener)
	defer scripting.deinit()

	listener.on_connected_hook = scripting.on_connected
	listener.on_disconnected_hook = scripting.on_disconnected
	listener.on_packet_received = scripting.on_packet_received

	for should_run {
		network.poll(&listener)
		scripting.poll()
	}
}

