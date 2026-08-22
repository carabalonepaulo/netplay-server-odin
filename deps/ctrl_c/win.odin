#+build windows
package ctrl_c

import "core:sys/windows"

hook :: proc() {
	windows.SetConsoleCtrlHandler(ctrl_handler, true)
}

@(private)
ctrl_handler :: proc "stdcall" (ctrl_type: windows.DWORD) -> windows.BOOL {
	switch ctrl_type {
	case windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT, windows.CTRL_CLOSE_EVENT:
		_should_quit = true
		return true
	}
	return false
}

