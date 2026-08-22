package keeper

import "base:builtin"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

Set_Error :: enum {
	None,
	Open_Failed,
	Write_Failed,
	Rename_Failed,
	Timeout,
}

Set_Callback :: proc(err: Set_Error, payload_buf: []u8, meta_buf: []u8, ud: rawptr)

@(private)
Set_State :: enum {
	Acquire_Permit,
	Acquire_Lock,
	Check_Dir,
	Create_Dir,
	Open,
	Write_Header,
	Write_Payload,
	Rename,
	Close,
	Cleanup_Remove,
	Done,
}

@(private)
Set_Data :: struct {
	err:               Set_Error,
	state:             Set_State,
	cb_ud:             rawptr,
	cb:                Set_Callback,
	buf:               []u8,
	meta:              []u8,
	ttl:               time.Duration,
	dir_path:          string,
	file_path:         string,
	temp_file_path:    string,
	temp_file:         nbio.Handle,
	state_after_close: Set_State,
	header:            Header,
}

@(private)
_set :: proc(task: ^Task) -> (done: bool) {
	data := &task.data.set_data
	switch data.state {
	case .Acquire_Permit:
		acquire(
			task,
			&data.state,
			Set_State.Acquire_Lock,
			Set_State.Done,
			&data.err,
			Set_Error.Timeout,
			acquire_permit,
		)
	case .Acquire_Lock:
		acquire(
			task,
			&data.state,
			Set_State.Check_Dir,
			Set_State.Done,
			&data.err,
			Set_Error.Timeout,
			acquire_id,
		)
	case .Check_Dir:
		_, expired := check_timeout(
			task,
			&data.state,
			Set_State.Done,
			&data.err,
			Set_Error.Timeout,
		)
		if expired do return false

		data.dir_path = strings.clone(get_dir_path(task))
		data.file_path = strings.clone(get_file_path(task))
		data.temp_file_path = strings.clone(get_temp_file_path(task))
		data.state = os.exists(data.dir_path) ? .Open : .Create_Dir
		reeschedule(task)
	case .Create_Dir:
		_, expired := check_timeout(
			task,
			&data.state,
			Set_State.Done,
			&data.err,
			Set_Error.Timeout,
		)
		if expired do return false

		os.make_directory(data.dir_path)
		data.state = .Open
		reeschedule(task)
	case .Open:
		_, expired := check_timeout(
			task,
			&data.state,
			Set_State.Done,
			&data.err,
			Set_Error.Timeout,
		)
		if expired do return false

		temp_path := data.temp_file_path
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.set_data

			if op.open.err != nil {
				data.state = .Done
				data.err = .Open_Failed
				return
			}

			data.temp_file = op.open.handle
			data.state = .Write_Header
		}
		op := nbio.open(temp_path, cb, {.Create, .Write, .Trunc})
		op.user_data[0] = task
	case .Write_Header:
		data.state_after_close = .Cleanup_Remove

		timeout, expired := check_timeout(
			task,
			&data.state,
			Set_State.Close,
			&data.err,
			Set_Error.Timeout,
		)
		if expired do return false

		data.header = Header {
			magic      = MAGIC,
			version    = VERSION,
			expires_at = data.ttl == -1 ? -1 : time_to_i64le(time.time_add(time.now(), data.ttl)),
		}
		copy(data.header.meta[:], data.meta[:])

		buf := ([^]u8)(&data.header)[:size_of(Header)]
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.set_data

			if op.write.err != nil {
				data.err = .Write_Failed
				data.state = .Close
				return
			}

			data.state = .Write_Payload
		}
		op := nbio.write(data.temp_file, 0, buf, cb, timeout = timeout)
		op.user_data[0] = task
	case .Write_Payload:
		data.state_after_close = .Cleanup_Remove

		timeout, expired := check_timeout(
			task,
			&data.state,
			Set_State.Close,
			&data.err,
			Set_Error.Timeout,
		)
		if expired do return false

		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.set_data

			if op.write.err != nil {
				data.err = .Write_Failed
				data.state = .Close
				return
			}

			data.state_after_close = .Rename
			data.state = .Close
		}
		op := nbio.write(data.temp_file, size_of(Header), data.buf, cb, timeout = timeout)
		op.user_data[0] = task
	case .Rename:
		file_path := data.file_path
		temp_path := data.temp_file_path
		if os.rename(temp_path, file_path) != nil do data.err = .Rename_Failed
		data.state = .Done
		reeschedule(task)
	case .Close:
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			task.data.set_data.state = task.data.set_data.state_after_close
		}
		op := nbio.close(data.temp_file, cb)
		op.user_data[0] = task
	case .Cleanup_Remove:
		os.remove(data.temp_file_path)
		data.state = .Done
		reeschedule(task)
	case .Done:
		release_id(task)
		release_permit(task)
		data.cb(data.err, data.buf, data.meta, data.cb_ud)

		builtin.delete(data.dir_path)
		builtin.delete(data.file_path)
		builtin.delete(data.temp_file_path)
		return true
	}
	return false
}

