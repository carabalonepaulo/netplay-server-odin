package ctrl_c

@(private)
_should_quit := false

should_quit :: #force_inline proc() -> bool {
	return _should_quit
}

