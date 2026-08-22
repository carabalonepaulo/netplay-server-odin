#+build linux
package ctrl_c

import "core:sys/linux"

hook :: proc() {
	act: linux.Sigaction
	act.sa_handler = sig_handler

	linux.sigaction(.SIGINT, &act, nil)
	linux.sigaction(.SIGTERM, &act, nil)
	linux.sigaction(.SIGHUP, &act, nil)
}

@(private)
sig_handler :: proc "c" (sig: linux.Signal) {
	#partial switch sig {
	case .SIGINT, .SIGTERM, .SIGHUP:
		_should_quit = true
	}
}

