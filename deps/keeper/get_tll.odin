package keeper

import "base:builtin"
import "core:nbio"
import "core:strings"
import "core:time"

Get_TTL_Callback :: proc(err: Get_Error, ttl: time.Duration, ud: rawptr)

@(private)
Get_TTL_State :: enum {
	Acquire_Permit,
	Acquire_Lock,
	Open,
	Read_Header,
	Close,
	Done,
}

@(private)
Get_TTL_Data :: struct {
	err:       Get_Error,
	state:     Get_TTL_State,
	cb_ud:     rawptr,
	cb:        Get_TTL_Callback,
	file_path: string,
	file:      nbio.Handle,
	ttl:       time.Duration,
	header:    Header,
}

@(private)
_get_ttl :: proc(task: ^Task) -> (done: bool) {
	data := &task.data.get_ttl_data
	switch data.state {
	case .Acquire_Permit:
		acquire(
			task,
			&data.state,
			Get_TTL_State.Acquire_Lock,
			Get_TTL_State.Done,
			&data.err,
			Get_Error.Timeout,
			acquire_permit,
		)
	case .Acquire_Lock:
		acquire(
			task,
			&data.state,
			Get_TTL_State.Open,
			Get_TTL_State.Done,
			&data.err,
			Get_Error.Timeout,
			acquire_id,
		)
	case .Open:
		_, expired := check_timeout(
			task,
			&data.state,
			Get_TTL_State.Done,
			&data.err,
			Get_Error.Timeout,
		)
		if expired do return false

		task.data.get_ttl_data.file_path = strings.clone(get_file_path(task))
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.get_ttl_data

			if op.open.err != nil {
				data.state = .Done
				data.err = .Open_Failed
				return
			}

			data.file = op.open.handle
			data.state = .Read_Header
		}
		op := nbio.open(task.data.get_ttl_data.file_path, cb, {.Read})
		op.user_data[0] = task
	case .Read_Header:
		timeout, expired := check_timeout(
			task,
			&data.state,
			Get_TTL_State.Close,
			&data.err,
			Get_Error.Timeout,
		)
		if expired do return false

		buf := ([^]u8)(&data.header)[:size_of(Header)]
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.get_ttl_data
			data.state = .Close

			if op.read.err != nil {
				data.err = op.read.err == .Timeout ? .Timeout : .Read_Failed
				return
			}

			if !is_valid_header(&data.header) {
				data.err = .Wrong_Version
				return
			}

			if is_expired(data.header.expires_at) {
				data.err = .Expired
				return
			}

			expires_at := time_from_i64le(data.header.expires_at)
			data.ttl = time.diff(time.now(), expires_at)
		}
		op := nbio.read(data.file, 0, buf, cb, true, timeout)
		op.user_data[0] = task
	case .Close:
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			task.data.get_ttl_data.state = .Done
		}
		op := nbio.close(data.file, cb)
		op.user_data[0] = task
	case .Done:
		release_id(task)
		release_permit(task)
		data.cb(data.err, data.ttl, data.cb_ud)

		builtin.delete(data.file_path)
		return true
	}
	return false
}

