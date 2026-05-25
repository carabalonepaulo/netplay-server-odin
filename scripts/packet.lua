return {
    parse = function(line)
        local index = line:find('>')
        return line:sub(1, index), line:sub(index + 1, line:find('</', index) - 1)
    end,

    send_to = function(id, tag, content)
        local end_tag = tag:sub(1, 1) .. '/' .. tag:sub(2, tag:len())
        listener:send_to(id, string.format('%s%s%s\n', tag, content, end_tag))
    end,

    send_to_all = function(tag, content)
        local end_tag = tag:sub(1, 1) .. '/' .. tag:sub(2, tag:len())
        listener:send_to_all(string.format('%s%s%s\n', tag, content, end_tag))
    end,
}
