package keeper

import "base:builtin"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

@(private)
Cleanup_State :: enum {
	Acquire_Permit,
	Open_Dir,
	Open_Next_Shard,
	Open_Next_File,
	Read_Meta,
	Close_File,
	Close_Shard,
	Close_Dir,
	Done,
}

@(private)
Cleanup_Data :: struct {
	state:         Cleanup_State,
	//
	dir:           ^os.File,
	dir_it:        ^os.Read_Directory_Iterator,
	shard:         ^os.File,
	shard_it:      ^os.Read_Directory_Iterator,
	shard_name:    string,
	//
	file_mod_time: time.Time,
	file_path:     string,
	file_id:       Id,
	file:          nbio.Handle,
	header:        Header,
	should_remove: bool,
}

@(private)
_cleanup :: proc(task: ^Task) -> (done: bool) {
	data := &task.data.cleanup_data
	switch data.state {
	case .Acquire_Permit:
		if !acquire_permit(task) do return false
		data.state = .Open_Dir
		reeschedule(task)
	case .Open_Dir:
		defer reeschedule(task)
		data := &task.data.cleanup_data

		dir, err := os.open(task.keeper.dir_path, {.Read})
		if err != nil {
			data.state = .Done
			return false
		}

		data.dir_it = &task.keeper.cleanup_iters[0]
		data.dir_it^ = os.read_directory_iterator_create(dir)

		data.dir = dir
		data.state = .Open_Next_Shard
	case .Open_Next_Shard:
		defer reeschedule(task)
		data := &task.data.cleanup_data

		info, _, ok := os.read_directory_iterator(data.dir_it)
		if !ok {
			data.state = .Close_Dir
			return false
		}

		_, iter_err := os.read_directory_iterator_error(data.dir_it)
		if iter_err != nil do return false

		shard, open_err := os.open(info.fullpath, {.Read})
		if open_err != nil do return false

		data.shard_it = &task.keeper.cleanup_iters[1]
		data.shard_it^ = os.read_directory_iterator_create(shard)

		data.shard = shard
		data.shard_name = strings.clone(info.name)
		data.state = .Open_Next_File
	case .Open_Next_File:
		data := &task.data.cleanup_data

		info, _, ok := os.read_directory_iterator(data.shard_it)
		if !ok {
			data.state = .Close_Shard
			reeschedule(task)
			return false
		}

		_, iter_err := os.read_directory_iterator_error(data.shard_it)
		if iter_err != nil {
			reeschedule(task)
			return false
		}

		if info.type != .Regular || strings.ends_with(info.fullpath, ".tmp") {
			reeschedule(task)
			return false
		}

		task.id, ok = get_id_from_strings(data.shard_name, info.name)
		if !(ok && try_acquire_id(task)) {
			reeschedule(task)
			return false
		}

		data.file_id = task.id
		data.file_mod_time = info.modification_time
		data.file_path = strings.clone(info.fullpath)
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.cleanup_data

			if op.open.err != nil {
				clear_file_state(task, data, .Open_Next_File)
				return
			}

			data.state = .Read_Meta
			data.file = op.open.handle
		}
		op := nbio.open(data.file_path, cb, {.Read})
		op.user_data[0] = task
	case .Read_Meta:
		data := &task.data.cleanup_data
		buf := ([^]u8)(&data.header)[:size_of(Header)]
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.cleanup_data
			data.should_remove =
				!is_valid_header(&data.header) || is_expired(data.header.expires_at)
			data.state = .Close_File
		}
		op := nbio.read(data.file, 0, buf, cb, true)
		op.user_data[0] = task
	case .Close_File:
		data := &task.data.cleanup_data
		cb :: proc(op: ^nbio.Operation) {
			task := (^Task)(op.user_data[0])
			defer reeschedule(task)
			data := &task.data.cleanup_data

			if data.should_remove {
				info, err := os.stat(data.file_path, context.temp_allocator)
				if err == nil && info.modification_time == data.file_mod_time {
					os.remove(data.file_path)
				}
			}

			clear_file_state(task, data, .Open_Next_File)
		}
		op := nbio.close(data.file, cb)
		op.user_data[0] = task
	case .Close_Shard:
		data := &task.data.cleanup_data
		os.read_directory_iterator_destroy(data.shard_it)
		os.close(data.shard)
		builtin.delete(data.shard_name)
		data.shard_it^ = {}
		data.shard_it = nil
		data.state = .Open_Next_Shard
		reeschedule(task)
	case .Close_Dir:
		data := &task.data.cleanup_data
		os.read_directory_iterator_destroy(data.dir_it)
		os.close(data.dir)
		data.dir_it^ = {}
		data.dir_it = nil
		fallthrough
	case .Done:
		release_permit(task)
		task.keeper.cleanup_task = -1
		task.keeper.last_cleanup = time.now()
		return true
	}
	return false
}

@(private = "file")
clear_file_state :: proc(task: ^Task, data: ^Cleanup_Data, next_state: Cleanup_State) {
	release_id(task)
	builtin.delete(data.file_path)
	data.should_remove = false
	data.file_path = ""
	data.file_mod_time = {}
	data.file_id = {}
	data.state = next_state
}

