package flat_map

import "base:builtin"
import "core:math/bits"
import "core:testing"

Iterator :: struct($T: typeid) {
	self:       ^Map(T),
	bucket_idx: int,
	curr_idx:   int,
}

Entry :: struct($T: typeid) {
	id:    u64,
	next:  int,
	value: T,
}

Map :: struct($T: typeid) {
	buckets:   []int,
	entries:   []Entry(T),
	free_head: int,
	len:       int,
}

init :: proc(self: ^Map($T), cap: int, allocator := context.allocator) -> (ok: bool) {
	if cap == 0 do return false

	buckets, buckets_err := make([]int, pow2_floor(u64(cap)), allocator)
	if buckets_err != nil do return false
	defer if !ok do builtin.delete(buckets)

	entries, entries_err := make([]Entry(T), cap, allocator)
	if entries_err != nil do return false
	defer if !ok do builtin.delete(entries)

	self.buckets = buckets
	self.entries = entries
	self.free_head = 0
	self.len = 0

	for i in 0 ..< builtin.len(self.buckets) do self.buckets[i] = -1
	for i in 0 ..< (cap - 1) do self.entries[i].next = i + 1
	self.entries[cap - 1].next = -1

	return true
}

deinit :: proc(self: ^Map($T)) {
	builtin.delete(self.buckets)
	builtin.delete(self.entries)
	self^ = {}
}

contains :: proc(self: ^Map($T), id: u64) -> bool {
	bucket_idx := get_bucket_idx(self, id) or_return
	curr := self.buckets[bucket_idx]
	for curr != -1 {
		if self.entries[curr].id == id do return true
		curr = self.entries[curr].next
	}
	return false
}

get :: proc(self: ^Map($T), id: u64) -> ^T {
	bucket_idx, ok := get_bucket_idx(self, id)
	if !ok do return nil

	curr := self.buckets[bucket_idx]
	for curr != -1 {
		if self.entries[curr].id == id {
			return &self.entries[curr].value
		}
		curr = self.entries[curr].next
	}

	return nil
}

set :: proc(self: ^Map($T), id: u64, value: T) -> (ok: bool) {
	bucket_idx := get_bucket_idx(self, id) or_return
	curr := self.buckets[bucket_idx]
	for curr != -1 {
		if self.entries[curr].id == id {
			self.entries[curr].value = value
			return
		}
		curr = self.entries[curr].next
	}

	if self.free_head == -1 do return false

	idx := self.free_head
	self.free_head = self.entries[idx].next

	slot := &self.entries[idx]
	slot.id = id
	slot.value = value
	slot.next = self.buckets[bucket_idx]
	self.buckets[bucket_idx] = idx
	self.len += 1

	return true
}

delete :: proc(self: ^Map($T), id: u64) {
	bucket_idx, ok := get_bucket_idx(self, id)
	if !ok do return

	curr := self.buckets[bucket_idx]
	prev := -1
	for curr != -1 {
		if self.entries[curr].id == id {
			if prev == -1 do self.buckets[bucket_idx] = self.entries[curr].next
			else do self.entries[prev].next = self.entries[curr].next

			slot := &self.entries[curr]
			slot.id = 0
			slot.value = {}
			slot.next = self.free_head
			self.free_head = curr
			self.len -= 1

			return
		}

		prev = curr
		curr = self.entries[curr].next
	}

	return
}

len :: #force_inline proc(self: ^Map($T)) -> int {
	return self.len
}

clear :: proc(self: ^Map($T)) {
	cap := builtin.len(self.buckets)
	if cap == 0 do return

	for i in 0 ..< builtin.len(self.buckets) do self.buckets[i] = -1
	for i in 0 ..< (cap - 1) do self.entries[i] = {
		next = i + 1,
	}
	self.entries[cap - 1].next = -1
	self.free_head = 0
	self.len = 0
}

iter :: proc(self: ^Map($T)) -> Iterator(T) {
	return Iterator(T) {
		self = self,
		bucket_idx = 0,
		curr_idx = builtin.len(self.buckets) > 0 ? self.buckets[0] : -1,
	}
}

iterate :: proc(it: ^Iterator($T)) -> (id: u64, val: ^T, ok: bool) {
	self := it.self
	if self == nil || builtin.len(self.buckets) == 0 do return 0, nil, false

	for {
		if it.curr_idx != -1 {
			idx := it.curr_idx
			entry := &self.entries[idx]
			it.curr_idx = entry.next
			return entry.id, &entry.value, true
		}

		it.bucket_idx += 1
		if it.bucket_idx >= builtin.len(self.buckets) do break
		it.curr_idx = self.buckets[it.bucket_idx]
	}

	return 0, nil, false
}

@(private = "file")
get_bucket_idx :: #force_inline proc(self: ^Map($T), id: u64) -> (int, bool) {
	buckets := builtin.len(self.buckets)
	if buckets == 0 do return 0, false
	return int(id & u64(buckets - 1)), true
}

@(private = "file")
pow2_floor :: proc(n: u64) -> u64 {
	if n <= 0 do return 1
	return 1 << uint(63 - bits.leading_zeros(u64(n)))
}

@(test)
test_map :: proc(t: ^testing.T) {
	fm: Map(int)
	testing.expect(t, init(&fm, 2) == true)
	defer deinit(&fm)

	set(&fm, 0, 100)
	val_0 := get(&fm, 0)
	testing.expect(t, val_0 != nil && val_0^ == 100)

	set(&fm, 0, 200)
	val_0_updated := get(&fm, 0)
	testing.expect(t, val_0_updated != nil && val_0_updated^ == 200)

	set(&fm, 42, 999)
	val_42 := get(&fm, 42)
	testing.expect(t, val_42 != nil && val_42^ == 999)

	set(&fm, 10, 555)
	testing.expect(t, get(&fm, 10) == nil)

	delete(&fm, 0)
	testing.expect(t, get(&fm, 0) == nil)

	set(&fm, 10, 555)
	val_10 := get(&fm, 10)
	testing.expect(t, val_10 != nil && val_10^ == 555)

	clear(&fm)
	testing.expect(t, get(&fm, 10) == nil)
	testing.expect(t, get(&fm, 42) == nil)

	set(&fm, 100, 777)
	val_100 := get(&fm, 100)
	testing.expect(t, val_100 != nil && val_100^ == 777)
}

@(test)
test_map_iteration :: proc(t: ^testing.T) {
	fm: Map(int)
	testing.expect(t, init(&fm, 4) == true)
	defer deinit(&fm)

	set(&fm, 0, 100)
	set(&fm, 42, 200)
	set(&fm, 99, 300)

	count := 0
	sum_values := 0

	it := iter(&fm)
	for id, val in iterate(&it) {
		count += 1
		sum_values += val^
	}

	testing.expect(t, count == 3)
	testing.expect(t, sum_values == 600)
}

@(test)
test_map_len :: proc(t: ^testing.T) {
	fm: Map(int)
	testing.expect(t, init(&fm, 2) == true)
	defer deinit(&fm)

	testing.expect(t, len(&fm) == 0)

	set(&fm, 10, 100)
	testing.expect(t, len(&fm) == 1)

	set(&fm, 10, 200)
	testing.expect(t, len(&fm) == 1)

	set(&fm, 20, 300)
	testing.expect(t, len(&fm) == 2)

	delete(&fm, 10)
	testing.expect(t, len(&fm) == 1)

	clear(&fm)
	testing.expect(t, len(&fm) == 0)
}

