package keeper

import "base:builtin"
import "core:nbio"
import "core:strings"
import "core:time"

Cond :: proc(meta: []u8, ud: rawptr) -> bool

Get_Error :: enum {
	None,
	Open_Failed,
	Stat_Failed,
	Read_Failed,
	Check_Size_Failed,
	Condition_Failed,
	Wrong_Version,
	Out_Of_Memory,
	Corrupted,
	Expired,
	Timeout,
}

Get_Callback :: proc(err: Get_Error, buf: []u8, ud: rawptr)

@(private)
Get_State :: enum {
	Acquire_Permit,
	Acquire_Lock,
	Open,
	Check_Size,
	Reading_Header,
	Reading_Payload,
	Close,
	Done,
}

@(private)
Get_Data :: struct {
	err:       Get_Error,
	state:     Get_State,
	meta:      [META_SIZE]u8,
	cond_ud:   rawptr,
	cond:      Cond,
	cb_ud:     rawptr,
	cb:        Get_Callback,
	file_path: string,
	file:      nbio.Handle,
	file_size: uint,
	header:    Header,
	buf:       []u8,
}

@(private)
_get :: proc(task: ^Task) -> (done: bool) {
	data := &task.data.get_data
	switch data.state {
	case .Acquire_Permit:
		acquire(
			task,
			&data.state,
			Get_State.Acquire_Lock,
			Get_State.Done,
			&data.err,
			Get_Error.Timeout,
			acquire_permit,
		)
	case .Acquire_Lock:
		acquire(
			task,
			&data.state,
			Get_State.Open,
			Get_State.Done,
			&data.err,
			Get_Error.Timeout,
			acquire_id,
		)
	case .Open:
		_, expired := check_timeout(
			task,
			&data.state,
			Get_State.Done,
			&data.err,
			Get_Error.Timeout,
		)
		if expired do return false

		task.data.get_data.file_path = strings.clone(get_file_path(task))
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.get_data

			if op.open.err != nil {
				data.state = .Done
				data.err = .Open_Failed
				return
			}

			data.file = op.open.handle
			data.state = .Check_Size
		}
		op := nbio.open(task.data.get_data.file_path, cb, {.Read})
		op.user_data[0] = task
	case .Check_Size:
		_, expired := check_timeout(
			task,
			&data.state,
			Get_State.Close,
			&data.err,
			Get_Error.Timeout,
		)
		if expired do return false

		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.get_data

			if op.stat.err != nil {
				data.state = .Close
				data.err = .Stat_Failed
				return
			}

			if op.stat.size < size_of(Header) {
				data.state = .Close
				data.err = .Corrupted
				return
			}

			file_size := uint(op.stat.size)
			if task.keeper.used_memory + file_size > task.keeper.memory_budget {
				data.state = .Close
				data.err = .Check_Size_Failed
				return
			}

			data.file_size = file_size
			task.keeper.used_memory += data.file_size
			data.state = .Reading_Header
		}
		op := nbio.stat(data.file, cb)
		op.user_data[0] = task
	case .Reading_Header:
		timeout, expired := check_timeout(
			task,
			&data.state,
			Get_State.Close,
			&data.err,
			Get_Error.Timeout,
		)
		if expired do return false

		buf := ([^]u8)(&data.header)[:size_of(Header)]
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.get_data

			if op.read.err != nil {
				data.state = .Close
				data.err = op.read.err == .Timeout ? .Timeout : .Read_Failed
				return
			}

			if !is_valid_header(&data.header) {
				data.state = .Close
				data.err = .Wrong_Version
				return
			}

			if is_expired(data.header.expires_at) {
				data.state = .Close
				data.err = .Expired
				return
			}

			if task.kind == .Get_If && !data.cond(data.header.meta[:], data.cond_ud) {
				data.state = .Close
				data.err = .Condition_Failed
				return
			}

			data.state = .Reading_Payload
		}
		op := nbio.read(data.file, 0, buf, cb, true, timeout)
		op.user_data[0] = task
	case .Reading_Payload:
		timeout, expired := check_timeout(
			task,
			&data.state,
			Get_State.Close,
			&data.err,
			Get_Error.Timeout,
		)
		if expired do return false

		buf, err := make([]u8, data.file_size - size_of(Header))
		if err != nil {
			data.state = .Close
			data.err = .Out_Of_Memory
			reeschedule(task)
			return
		}

		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.get_data

			if op.read.err != nil {
				data.err = op.read.err == .Timeout ? .Timeout : .Read_Failed
				builtin.delete(op.read.buf)
			} else {
				data.buf = op.read.buf
			}
			data.state = .Close
		}
		op := nbio.read(data.file, size_of(Header), buf, cb, true, timeout)
		op.user_data[0] = task
	case .Close:
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			task.data.get_data.state = .Done
		}
		op := nbio.close(data.file, cb)
		op.user_data[0] = task
	case .Done:
		release_id(task)
		release_permit(task)
		data.cb(data.err, data.buf, data.cb_ud)

		builtin.delete(data.file_path)
		task.keeper.used_memory -= data.file_size
		return true
	}
	return false
}

