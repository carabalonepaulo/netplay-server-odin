package keeper

import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

Has_Callback :: proc(err: Has_Error, exists: bool, ud: rawptr)

@(private)
Has_State :: enum {
	Acquire_Permit,
	Acquire_Lock,
	Exists,
	Done,
}

Has_Error :: enum {
	None,
	Timeout,
}

@(private)
Has_Data :: struct {
	state:  Has_State,
	err:    Has_Error,
	cb_ud:  rawptr,
	cb:     Has_Callback,
	exists: bool,
}

@(private)
_has :: proc(task: ^Task) -> (done: bool) {
	data := &task.data.has_data
	switch data.state {
	case .Acquire_Permit:
		acquire(
			task,
			&data.state,
			Has_State.Acquire_Lock,
			Has_State.Done,
			&data.err,
			Has_Error.Timeout,
			acquire_permit,
		)
	case .Acquire_Lock:
		acquire(
			task,
			&data.state,
			Has_State.Exists,
			Has_State.Done,
			&data.err,
			Has_Error.Timeout,
			acquire_id,
		)
	case .Exists:
		file_path := get_file_path(task)
		data.exists = os.exists(file_path)
		data.state = .Done
		reeschedule(task)
	case .Done:
		release_id(task)
		release_permit(task)
		data.cb(data.err, data.exists, data.cb_ud)
		return true
	}
	return false
}

