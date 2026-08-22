package keeper

import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

Delete_Callback :: proc(err: Delete_Error, ud: rawptr)

@(private)
Delete_State :: enum {
	Acquire_Permit,
	Acquire_Lock,
	Delete,
	Done,
}

Delete_Error :: enum {
	None,
	Delete_Failed,
	Timeout,
}

@(private)
Delete_Data :: struct {
	state: Delete_State,
	err:   Delete_Error,
	cb_ud: rawptr,
	cb:    Delete_Callback,
}

@(private)
_delete :: proc(task: ^Task) -> (done: bool) {
	data := &task.data.delete_data
	switch data.state {
	case .Acquire_Permit:
		acquire(
			task,
			&data.state,
			Delete_State.Acquire_Lock,
			Delete_State.Done,
			&data.err,
			Delete_Error.Timeout,
			acquire_permit,
		)
	case .Acquire_Lock:
		acquire(
			task,
			&data.state,
			Delete_State.Delete,
			Delete_State.Done,
			&data.err,
			Delete_Error.Timeout,
			acquire_id,
		)
	case .Delete:
		file_path := get_file_path(task)
		err := os.remove(file_path)
		if err != nil do data.err = .Delete_Failed
		data.state = .Done
		reeschedule(task)
	case .Done:
		release_id(task)
		release_permit(task)
		data.cb(data.err, data.cb_ud)
		return true
	}
	return false
}

