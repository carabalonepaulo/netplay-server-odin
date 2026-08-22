#+build windows
package pid_lock

import "core:strconv"
import win32 "core:sys/windows"

_acquire :: proc(file_path: string) -> (lock: Lock, ok: bool) {
	file_path_w := win32.utf8_to_wstring(file_path, context.temp_allocator)
	handle := win32.CreateFileW(
		file_path_w,
		win32.GENERIC_READ | win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_DELETE_ON_CLOSE,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE do return {}, false

	flags: win32.DWORD = win32.LOCKFILE_EXCLUSIVE_LOCK | win32.LOCKFILE_FAIL_IMMEDIATELY
	overlapped: win32.OVERLAPPED

	locked := win32.LockFileEx(handle, flags, 0, 1, 0, &overlapped)
	if !locked {
		win32.CloseHandle(handle)
		return {}, false
	}

	pid := win32.GetCurrentProcessId()
	win32.SetFilePointer(handle, 0, nil, win32.FILE_BEGIN)
	win32.SetEndOfFile(handle)

	pid_buf: [32]byte
	pid_str := strconv.write_int(pid_buf[:], i64(pid), 10)

	written: win32.DWORD
	win32.WriteFile(handle, raw_data(pid_str), win32.DWORD(len(pid_str)), &written, nil)

	return transmute(Lock)(handle), true
}

_release :: proc(lock: ^Lock) {
	handle := transmute(win32.HANDLE)(lock^)
	if handle != nil && handle != win32.INVALID_HANDLE_VALUE {
		overlapped: win32.OVERLAPPED
		win32.UnlockFileEx(handle, 0, 1, 0, &overlapped)
		win32.CloseHandle(handle)
	}
}

