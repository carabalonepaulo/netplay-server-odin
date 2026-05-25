package config

import "core:os"
import "core:strconv"
import "core:strings"

Config :: struct {
	port:        int,
	max_clients: int,
	buffer_size: int,
}

config := Config {
	port        = 5009,
	max_clients = 256,
	buffer_size = 4096,
}

get :: #force_inline proc() -> ^Config {
	return &config
}

init :: proc() -> bool {
	data, read_err := os.read_entire_file_from_path("./config.ini", context.allocator)
	if read_err != nil do return false
	defer delete(data)

	content := string(data)
	current_section := ""

	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 ||
		   strings.has_prefix(trimmed, ";") ||
		   strings.has_prefix(trimmed, "#") {
			continue
		}

		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			current_section = trimmed[1:len(trimmed) - 1]
			continue
		}

		key_val := strings.split(trimmed, "=")
		if len(key_val) != 2 do continue

		key := strings.trim_space(key_val[0])
		value := strings.trim_space(key_val[1])

		switch current_section {
		case "listener":
			switch key {
			case "port":
				val, ok := strconv.parse_int(value)
				if ok {
					config.port = val
				}
			case "max_clients":
				val, ok := strconv.parse_int(value)
				if ok {
					config.max_clients = val
				}
			case "buffer_size":
				val, ok := strconv.parse_int(value)
				if ok {
					config.buffer_size = val
				}
			}
		}

		delete(key_val)
	}

	return true
}

