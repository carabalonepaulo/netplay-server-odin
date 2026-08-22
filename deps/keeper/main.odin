package keeper

import "base:builtin"
import "core:fmt"
import "core:hash/xxhash"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import fm "flat_map"
import "pid_lock"

MAGIC :: [3]u8{'K', 'P', 'R'}
VERSION :: 1
META_SIZE :: #config(KEEPER_META_SIZE, 32)
TEMP_BUF_SIZE :: #config(KEEPER_TEMP_BUF_SIZE, 1 * mem.Kilobyte)
CLEANUP_BATCH_SIZE :: 8
SEP :: 0xff

Debug_Hook :: proc(
	kind: Task_Kind,
	state: int,
	id: Id,
	created_at: time.Time,
	timeout: time.Duration,
)

Id :: distinct u64

Options :: struct {
	debug_hook:       Debug_Hook,
	dir:              string,
	lock:             bool,
	cleanup_interval: time.Duration,
	max_permits:      int,
	max_ram:          int,
	max_tasks:        int,
}

Task_Kind :: enum {
	Available,
	Get,
	Get_If,
	Set,
	Get_TTL,
	Delete,
	Has,
	Cleanup,
}

@(private)
Wait_State :: enum {
	None,
	Waiting,
	Acquired,
}

@(private)
Task :: struct {
	keeper:       ^Keeper,
	created_at:   time.Time,
	timeout:      time.Duration,
	id:           Id,
	idx:          int,
	next:         int,
	//
	lock_state:   Wait_State,
	permit_state: Wait_State,
	kind:         Task_Kind,
	//
	data:         struct #raw_union {
		get_data:     Get_Data,
		set_data:     Set_Data,
		get_ttl_data: Get_TTL_Data,
		delete_data:  Delete_Data,
		has_data:     Has_Data,
		cleanup_data: Cleanup_Data,
	},
}

@(private)
Header :: struct #packed {
	magic:      [3]u8,
	version:    u16le,
	expires_at: i64le,
	meta:       [META_SIZE]u8,
}

Keeper :: struct {
	debug_hook:       Debug_Hook,
	lock:             pid_lock.Lock,
	dir_path:         string,
	tasks:            []Task,
	file_queue:       fm.Map(Intrusive_Queue),
	permit_queue:     Intrusive_Queue,
	ready_queue:      Intrusive_Queue,
	//
	cleanup_task:     int,
	last_cleanup:     time.Time,
	cleanup_internal: time.Duration,
	cleanup_iters:    ^[2]os.Read_Directory_Iterator,
	//
	active_permits:   int,
	max_permits:      int,
	count:            int,
	used_memory:      uint,
	memory_budget:    uint,
	//
	temp_buf:         []u8,
	temp_arena:       mem.Arena,
	temp_allocator:   mem.Allocator,
}

Init_Error :: enum {
	None,
	Invalid_Dir,
	Make_Dir_Failed,
	Missing_Max_Tasks,
	Out_Of_Memory,
	Locked,
}

init :: proc(self: ^Keeper, opts: Options) -> (err: Init_Error) {
	if opts.max_tasks == 0 do return .Missing_Max_Tasks

	if os.exists(opts.dir) {
		stat, err := os.stat(opts.dir, context.allocator)
		if err != nil do return .Out_Of_Memory
		defer os.file_info_delete(stat, context.allocator)
		if stat.type != .Directory do return .Invalid_Dir
	} else {
		err := os.make_directory_all(opts.dir)
		if err != nil do return .Make_Dir_Failed
	}

	lock_path, path_err := os.join_path({opts.dir, ".lock"}, context.allocator)
	if path_err != nil do return .Out_Of_Memory
	defer builtin.delete(lock_path)

	lock, ok := pid_lock.acquire(lock_path)
	if !ok do return .Locked

	tasks, tasks_err := make([]Task, opts.max_tasks)
	if tasks_err != nil do return .Out_Of_Memory
	defer if err != .None do builtin.delete(tasks)

	temp_buf, make_err := make([]u8, TEMP_BUF_SIZE)
	if make_err != nil do return .Out_Of_Memory
	defer if err != .None do builtin.delete(temp_buf)

	dir_path, clone_err := strings.clone(opts.dir)
	if clone_err != nil do return .Out_Of_Memory
	defer if err != .None do builtin.delete(dir_path)

	cleanup_iters, make_iter_err := new([2]os.Read_Directory_Iterator)
	if make_iter_err != nil do return .Out_Of_Memory
	defer if err != .None do free(cleanup_iters)

	fm_ok := fm.init(&self.file_queue, 1000)
	if !fm_ok do return .Out_Of_Memory
	defer if err != .None {
		fm.deinit(&self.file_queue)
		self.file_queue = {}
	}

	self.debug_hook = opts.debug_hook
	self.ready_queue = {-1, -1}
	self.tasks = tasks
	self.cleanup_task = -1
	self.last_cleanup = time.now()
	self.cleanup_internal = opts.cleanup_interval
	self.cleanup_iters = cleanup_iters

	self.permit_queue = {-1, -1}
	self.max_permits = opts.max_permits == 0 ? opts.max_tasks : opts.max_permits
	self.memory_budget = uint(opts.max_ram)
	self.dir_path = dir_path

	self.temp_buf = temp_buf
	mem.arena_init(&self.temp_arena, self.temp_buf)
	self.temp_allocator = mem.arena_allocator(&self.temp_arena)

	nbio.acquire_thread_event_loop()
	return .None
}

deinit :: proc(self: ^Keeper) {
	drain(self)

	fm.deinit(&self.file_queue)
	free(self.cleanup_iters)
	builtin.delete(self.dir_path)
	builtin.delete(self.temp_buf)
	builtin.delete(self.tasks)

	nbio.release_thread_event_loop()
	pid_lock.release(&self.lock)
}

poll :: proc(self: ^Keeper, timeout: time.Duration) {
	context.temp_allocator = self.temp_allocator

	start := time.now()
	if self.cleanup_task == -1 && time.diff(self.last_cleanup, start) > self.cleanup_internal {
		cleanup(self)
	}

	for {
		task := queue_pop(&self.ready_queue, self.tasks)
		if task == nil do break
		if _task(task) {
			self.tasks[task.idx] = {
				kind = .Available,
			}
			self.count -= 1
		}
		mem.free_all(context.temp_allocator)
		if time.since(start) >= timeout do break
	}
}

drain :: proc(self: ^Keeper, sleep: time.Duration = 0) {
	for self.count > 0 {
		poll(self, 0)
		nbio.tick(0)
		if sleep > 0 && self.ready_queue.head == -1 && self.count > 0 do time.sleep(sleep)
	}
}

get_pending :: #force_inline proc(self: ^Keeper) -> int {
	return self.count
}

cleanup :: proc(self: ^Keeper) -> (ok: bool) {
	if self.cleanup_task != -1 do return false
	task := use_slot(self, id("internal", "cleanup"), .Cleanup) or_return
	reeschedule(task)
	self.cleanup_task = task.idx
	return true
}

get_if :: proc(
	self: ^Keeper,
	id: Id,
	cond_ud: rawptr,
	cond: Cond,
	cb_ud: rawptr,
	cb: Get_Callback,
	timeout: time.Duration = nbio.NO_TIMEOUT,
) -> (
	ok: bool,
) {
	task := use_slot(self, id, .Get, timeout) or_return
	task.data.get_data = Get_Data {
		cond_ud = cond_ud,
		cond    = cond,
		cb_ud   = cb_ud,
		cb      = cb,
	}
	reeschedule(task)
	return true
}

get :: proc(
	self: ^Keeper,
	id: Id,
	cb_ud: rawptr,
	cb: Get_Callback,
	timeout: time.Duration = nbio.NO_TIMEOUT,
) -> (
	ok: bool,
) {
	task := use_slot(self, id, .Get, timeout) or_return
	task.data.get_data = Get_Data {
		cb_ud = cb_ud,
		cb    = cb,
	}
	reeschedule(task)
	return true
}

set :: proc(
	self: ^Keeper,
	id: Id,
	buf: []u8,
	cb_ud: rawptr,
	cb: Set_Callback,
	meta: []u8 = nil,
	ttl: time.Duration = -1,
	timeout: time.Duration = nbio.NO_TIMEOUT,
) -> (
	ok: bool,
) {
	assert(len(meta) <= META_SIZE)
	task := use_slot(self, id, .Set, timeout) or_return
	task.data.set_data = Set_Data {
		cb_ud = cb_ud,
		cb    = cb,
		buf   = buf,
		meta  = meta,
		ttl   = ttl,
	}
	reeschedule(task)
	return true
}

get_ttl :: proc(
	self: ^Keeper,
	id: Id,
	cb_ud: rawptr,
	cb: Get_TTL_Callback,
	timeout: time.Duration = nbio.NO_TIMEOUT,
) -> (
	ok: bool,
) {
	task := use_slot(self, id, .Get_TTL, timeout) or_return
	task.data.get_ttl_data = Get_TTL_Data {
		cb_ud = cb_ud,
		cb    = cb,
	}
	reeschedule(task)
	return true
}

delete :: proc(
	self: ^Keeper,
	id: Id,
	cb_ud: rawptr,
	cb: Delete_Callback,
	timeout: time.Duration = nbio.NO_TIMEOUT,
) -> (
	ok: bool,
) {
	task := use_slot(self, id, .Delete, timeout) or_return
	task.data.delete_data = Delete_Data {
		cb_ud = cb_ud,
		cb    = cb,
	}
	reeschedule(task)
	return true
}

has :: proc(
	self: ^Keeper,
	id: Id,
	cb_ud: rawptr,
	cb: Has_Callback,
	timeout: time.Duration = nbio.NO_TIMEOUT,
) -> (
	ok: bool,
) {
	task := use_slot(self, id, .Has, timeout) or_return
	task.data.has_data = Has_Data {
		cb_ud = cb_ud,
		cb    = cb,
	}
	reeschedule(task)
	return true
}

id :: proc(args: ..any) -> Id {
	state: xxhash.XXH64_state
	xxhash.XXH64_reset_state(&state, 0)

	sep_byte: u8 = SEP

	for arg in args {
		tid := arg.id
		xxhash.XXH64_update(&state, mem.any_to_bytes(tid))

		switch v in arg {
		case string:
			xxhash.XXH64_update(&state, transmute([]u8)v)
		case bool:
			b: u8 = v ? 1 : 0
			xxhash.XXH64_update(&state, mem.any_to_bytes(b))
		case:
			xxhash.XXH64_update(&state, mem.any_to_bytes(v))
		}

		xxhash.XXH64_update(&state, mem.any_to_bytes(sep_byte))
	}

	h := xxhash.XXH64_digest(&state)
	return Id(h)
}

@(private)
use_slot :: proc(
	self: ^Keeper,
	id: Id,
	kind: Task_Kind,
	timeout: time.Duration = nbio.NO_TIMEOUT,
) -> (
	task: ^Task,
	ok: bool,
) {
	self.count += 1
	idx := find_free_slot(self) or_return
	task = &self.tasks[idx]
	task.keeper = self
	task.kind = kind
	task.id = id
	task.idx = idx
	task.created_at = time.now()
	task.timeout = timeout
	return task, true
}

@(private)
find_free_slot :: proc(self: ^Keeper) -> (int, bool) {
	for task, i in self.tasks {
		if task.kind == .Available do return i, true
	}
	return 0, false
}

@(private)
reeschedule :: #force_inline proc(task: ^Task) {
	queue_push(&task.keeper.ready_queue, task.keeper.tasks, task)
}

@(private)
_task :: proc(task: ^Task) -> (done: bool) {
	#partial switch task.kind {
	case .Get, .Get_If:
		_hook(task, int(task.data.get_data.state))
		return _get(task)
	case .Set:
		_hook(task, int(task.data.set_data.state))
		return _set(task)
	case .Get_TTL:
		_hook(task, int(task.data.get_ttl_data.state))
		return _get_ttl(task)
	case .Delete:
		_hook(task, int(task.data.delete_data.state))
		return _delete(task)
	case .Has:
		_hook(task, int(task.data.has_data.state))
		return _has(task)
	case .Cleanup:
		_hook(task, int(task.data.cleanup_data.state))
		return _cleanup(task)
	}
	return false
}

@(private)
_hook :: #force_inline proc(task: ^Task, state: int) {
	if task.keeper.debug_hook == nil do return
	task.keeper.debug_hook(task.kind, state, task.id, task.created_at, task.timeout)
}

@(private)
time_from_i64le :: #force_inline proc(val: i64le) -> time.Time {
	return time.from_nanoseconds(i64(val))
}

@(private)
time_to_i64le :: #force_inline proc(val: time.Time) -> i64le {
	return i64le(time.to_unix_nanoseconds(val))
}

@(private)
get_dir_path :: proc(task: ^Task) -> string {
	dir_name := fmt.tprintf("%016x", u64(task.id))[:3]
	path, _ := os.join_path({task.keeper.dir_path, dir_name}, context.temp_allocator)
	return path
}

@(private)
get_file_path :: proc(task: ^Task) -> string {
	hex := fmt.tprintf("%016x", u64(task.id))
	path, _ := os.join_path({task.keeper.dir_path, hex[:3], hex[3:]}, context.temp_allocator)
	return path
}

@(private)
get_temp_file_path :: proc(task: ^Task) -> string {
	hex := fmt.tprintf("%016x", u64(task.id))
	file_name, _ := os.join_filename(hex[3:], "tmp", context.temp_allocator)
	path, _ := os.join_path({task.keeper.dir_path, hex[:3], file_name}, context.temp_allocator)
	return path
}

@(private)
get_id_from_strings :: proc(dir_name: string, file_name: string) -> (id: Id, ok: bool) {
	full := fmt.tprintf("%s%s", dir_name, file_name)
	val := strconv.parse_u64(full, 16) or_return
	return (Id)(val), true
}

@(private)
is_valid_header :: #force_inline proc(header: ^Header) -> bool {
	return header.magic == MAGIC && header.version == VERSION
}

@(private)
is_expired :: #force_inline proc(expires_at: i64le) -> bool {
	if expires_at == -1 do return false
	ttl := time_from_i64le(expires_at)
	return time.diff(time.now(), ttl) <= 0
}

@(private)
get_remaining_timeout :: proc(task: ^Task) -> (remaining: time.Duration, expired: bool) {
	if task.timeout == nbio.NO_TIMEOUT do return nbio.NO_TIMEOUT, false

	elapsed := time.since(task.created_at)
	remaining = task.timeout - elapsed
	if remaining <= 0 do return 0, true

	return remaining, false
}

@(private)
check_timeout :: proc(
	task: ^Task,
	state: ^$S,
	done: S,
	err: ^$E,
	timeout_err: E,
) -> (
	timeout: time.Duration,
	expired: bool,
) {
	timeout, expired = get_remaining_timeout(task)
	if expired {
		state^ = done
		err^ = timeout_err
		reeschedule(task)
	}
	return timeout, expired
}

@(private)
acquire :: proc(
	task: ^Task,
	state: ^$S,
	ok_state: S,
	fail_state: S,
	err: ^$E,
	timeout_err: E,
	acquire_fn: proc(_: ^Task) -> bool,
) {
	_, expired := check_timeout(task, state, fail_state, err, timeout_err)
	if expired || !acquire_fn(task) do return
	state^ = ok_state
	reeschedule(task)
}

@(private)
try_acquire_id :: proc(task: ^Task) -> bool {
	if task.lock_state == .Acquired do return true
	if fm.contains(&task.keeper.file_queue, u64(task.id)) do return false

	assert(fm.set(&task.keeper.file_queue, u64(task.id), Intrusive_Queue{-1, -1}))
	task.lock_state = .Acquired
	return true
}

@(private)
acquire_id :: proc(task: ^Task) -> bool {
	if task.lock_state == .Acquired do return true
	self := task.keeper

	if wq := fm.get(&self.file_queue, u64(task.id)); wq != nil {
		task.lock_state = .Waiting
		queue_push(wq, self.tasks, task)
		return false
	}

	fm.set(&task.keeper.file_queue, u64(task.id), Intrusive_Queue{-1, -1})
	task.lock_state = .Acquired
	return true
}

@(private)
release_id :: proc(task: ^Task) {
	if task.lock_state != .Acquired do return
	task.lock_state = .None
	self := task.keeper

	if wq := fm.get(&self.file_queue, u64(task.id)); wq != nil {
		next_task := queue_pop(wq, self.tasks)
		if next_task != nil {
			next_task.lock_state = .Acquired
			reeschedule(next_task)
		} else {
			fm.delete(&self.file_queue, u64(task.id))
		}
	}
}

@(private)
acquire_permit :: proc(task: ^Task) -> bool {
	if task.permit_state == .Acquired do return true
	self := task.keeper

	if self.max_permits > 0 && self.active_permits >= self.max_permits {
		task.permit_state = .Waiting
		queue_push(&self.permit_queue, self.tasks, task)
		return false
	}

	self.active_permits += 1
	task.permit_state = .Acquired
	return true
}

@(private)
release_permit :: proc(task: ^Task) {
	if task.permit_state != .Acquired do return
	task.permit_state = .None

	self := task.keeper
	self.active_permits -= 1

	if next_task := queue_pop(&self.permit_queue, self.tasks); next_task != nil {
		self.active_permits += 1
		next_task.permit_state = .Acquired
		reeschedule(next_task)
	}
}

