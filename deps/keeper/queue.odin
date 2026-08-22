package keeper

@(private)
Intrusive_Queue :: struct {
	head: int,
	tail: int,
}

@(private)
queue_push :: proc(q: ^Intrusive_Queue, tasks: []Task, task: ^Task) {
	task.next = -1

	if q.head == -1 {
		q.head = task.idx
		q.tail = task.idx
	} else {
		prev_tail := &tasks[q.tail]
		prev_tail.next = task.idx
		q.tail = task.idx
	}
}

@(private)
queue_pop :: proc(q: ^Intrusive_Queue, tasks: []Task) -> ^Task {
	if q.head == -1 do return nil

	next_idx := q.head
	next_task := &tasks[next_idx]

	if q.head == q.tail {
		q.head = -1
		q.tail = -1
	} else {
		q.head = next_task.next
	}

	next_task.next = -1
	return next_task
}

