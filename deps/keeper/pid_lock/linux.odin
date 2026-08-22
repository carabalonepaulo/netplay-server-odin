#+build linux
package pid_lock

import "core:os"
import "core:strconv"
import "core:sys/posix"

_acquire :: proc(file_path: string) -> (lock: Lock, ok: bool) {
	fd, err := os.open(file_path, os.O_RDWR | os.O_CREATE, 0o666)
	if err != nil do return 0, false

	int_fd := i32(fd)

	if posix.flock(int_fd, posix.LOCK_EX | posix.LOCK_NB) != 0 {
		os.close(fd)
		return 0, false
	}

	posix.ftruncate(int_fd, 0)
	posix.lseek(int_fd, 0, posix.SEEK_SET)

	pid_buf: [32]byte
	pid_str := strconv.write_int(pid_buf[:], i64(os.getpid()), 10)

	os.write(fd, raw_data(pid_str))

	return Lock(uintptr(fd)), true
}

_release :: proc(lock: ^Lock) {
	if lock == nil || lock^ == 0 do return

	fd := os.Handle(uintptr(lock^))
	posix.flock(int(fd), posix.LOCK_UN)
	os.close(fd)

	lock^ = 0
}

