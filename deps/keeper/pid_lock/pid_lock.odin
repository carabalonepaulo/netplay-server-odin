package pid_lock

Lock :: distinct uintptr

acquire :: proc(file_path: string) -> (Lock, bool) {
	return _acquire(file_path)
}

release :: proc(self: ^Lock) {
	_release(self)
}

