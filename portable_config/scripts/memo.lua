-- memo.lua
--
-- Recent-files / directory menu for mpv.
--
-- Recommended mpv: 0.39+
-- Optional: uosc 5+
--
-- History format: JSON Lines.
-- If migrating from an older non-JSONL memo.lua, use a new history file.

local mp = mp
local utils = require "mp.utils"
local options_mod = require "mp.options"
local assdraw = require "mp.assdraw"
local msg = require "mp.msg"

local unpack = table.unpack or unpack
local script_name = mp.get_script_name()

local options = {
    -- Empty = in-memory only.
    history_path = "~~/memo-history.jsonl",

    entries = 10,
    pagination = true,

    hide_duplicates = true,
    hide_deleted = true,
    hide_same_dir = false,

    timestamp_format = "%Y-%m-%d %H:%M:%S",

    use_titles = true,
    truncate_titles = 60,

    enabled = true,

    up_binding = "UP WHEEL_UP",
    down_binding = "DOWN WHEEL_DOWN",
    select_binding = "RIGHT ENTER",
    append_binding = "Shift+RIGHT Shift+ENTER",
    close_binding = "LEFT ESC",

    -- 0 = read entire history file.
    max_scan_lines = 5000,

    path_prefixes = "pattern:.*",
}

local utf8_pattern = "[%z\1-\127\194-\244][\128-\191]*"

local accent_map = {}
do
    local groups = {
        A = "ÀÁÂÃÄÅĀĂĄ",
        AE = "Æ",
        C = "ÇĆĈĊČ",
        E = "ÈÉÊËĒĔĖĘĚ",
        I = "ÌÍÎÏĨĪĬĮİ",
        N = "ÑŃŅŇ",
        O = "ÒÓÔÕÖØŌŎŐ",
        OE = "Œ",
        U = "ÙÚÛÜŨŪŬŮŰŲ",
        Y = "ÝŸŶ",
        Z = "ŹŻŽ",

        a = "àáâãäåāăą",
        ae = "æ",
        c = "çćĉċč",
        e = "èéêëēĕėęě",
        i = "ìíîïĩīĭįı",
        n = "ñńņň",
        o = "òóôõöøōŏő",
        oe = "œ",
        u = "ùúûüũūŭůűų",
        y = "ýÿŷ",
        z = "źżž",
        ss = "ß",
    }

    for replacement, chars in pairs(groups) do
        for char in chars:gmatch(utf8_pattern) do
            accent_map[char] = replacement
        end
    end
end

local data_protocols = {
    edl = true,
    data = true,
    null = true,
    memory = true,
    hex = true,
    fd = true,
    fdclose = true,
    mf = true,
    lavf = true,
    av = true,
}

local parsed_path_prefixes = nil
local history_path = nil
local history_writer = nil
local memory_history = {}

local history_dirty = true
local cached_records = nil
local cached_history_key = nil

local normalize_cache = {}
local normalize_cache_size = 0
local normalize_cache_limit = 20000

local uosc_available = false
local using_uosc = false

local menu_open = false
local menu_data = nil
local current_page = 1
local selected_index = 1

local search_query = nil
local search_words = nil

local palette_mode = false
local dir_menu = false
local dir_prefixes = nil

local fallback_bound = false

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 2000
overlay.hidden = true

local close_menu
local render_menu
local fallback_open
local fallback_close
local uosc_update

local function clamp_number(value, default, min_value)
    local n = tonumber(value) or default

    if min_value and n < min_value then
        n = min_value
    end

    return math.floor(n)
end

local function semver_lt(a, b)
    local ai = tostring(a or ""):gmatch("%d+")
    local bi = tostring(b or ""):gmatch("%d+")

    while true do
        local av = ai()
        local bv = bi()

        if not bv then
            return false
        end

        if not av then
            return true
        end

        av = tonumber(av) or 0
        bv = tonumber(bv) or 0

        if av < bv then
            return true
        end

        if av > bv then
            return false
        end
    end
end

local function invalidate_path_cache()
    normalize_cache = {}
    normalize_cache_size = 0
end

local function parse_path_prefixes(value)
    local prefixes = {}

    for raw in tostring(value or ""):gmatch("([^|]+)") do
        local prefix = raw:match("^%s*(.-)%s*$")

        if prefix ~= "" then
            if prefix:sub(1, 8) == "pattern:" then
                prefixes[#prefixes + 1] = {
                    pattern = prefix:sub(9),
                    plain = false,
                    warned = false,
                }
            else
                prefixes[#prefixes + 1] = {
                    pattern = prefix:gsub("\\", "/"),
                    plain = true,
                    warned = false,
                }
            end
        end
    end

    if #prefixes == 0 then
        prefixes[1] = {
            pattern = ".*",
            plain = false,
            warned = false,
        }
    end

    return prefixes
end

local function expand_history_path()
    local path = tostring(options.history_path or "")

    if path == "" then
        return nil
    end

    local ok, expanded = pcall(mp.command_native, { "expand-path", path })

    if ok and expanded and expanded ~= "" then
        return expanded
    end

    return path
end

local function close_history_writer()
    if not history_writer then
        return
    end

    pcall(function()
        history_writer:flush()
        history_writer:close()
    end)

    history_writer = nil
end

local function invalidate_history_cache()
    history_dirty = true
    cached_records = nil
    cached_history_key = nil
end

local function protocol_of(path)
    if type(path) ~= "string" then
        return nil
    end

    return path:match("^(%a[%w%.%+%-]*)://")
        or path:match("^(%a[%w%.%+%-]*):%?")
end

local function is_remote_path(path)
    local proto = protocol_of(path)
    return proto ~= nil and proto ~= "file"
end

local function url_decode(str)
    return tostring(str or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function normalize_path(path)
    if not path or path == "" then
        return path
    end

    if is_remote_path(path) then
        return path
    end

    local cached = normalize_cache[path]
    if cached then
        return cached
    end

    local normalized
    local ok, result = pcall(mp.command_native, { "normalize-path", path })

    if ok and result and result ~= "" then
        normalized = result
    elseif path:sub(1, 7) == "file://" then
        normalized = url_decode(path:sub(8))
    else
        normalized = path
    end

    if normalize_cache_size >= normalize_cache_limit then
        invalidate_path_cache()
    end

    normalize_cache[path] = normalized
    normalize_cache_size = normalize_cache_size + 1

    return normalized
end

local function current_path()
    local path = mp.get_property("path")

    if not path or path == "" or path == "-" or path == "/dev/stdin" then
        return nil
    end

    if not is_remote_path(path) then
        path = normalize_path(path)
    end

    return path
end

local function display_path(path)
    path = tostring(path or "")

    if path:sub(1, 7) == "file://" then
        return url_decode(path:sub(8))
    end

    if is_remote_path(path) then
        return url_decode(path)
    end

    return path
end

local function dirname_of(path)
    local dir = utils.split_path(path)
    return dir ~= "" and dir or "."
end

local function basename_of(path)
    local _, base = utils.split_path(path)
    return base ~= "" and base or path
end

local function fold(str)
    str = tostring(str or "")
    str = str:gsub(utf8_pattern, accent_map)
    str = str:gsub("[%z\1-\31\127]", "")
    str = str:gsub("\226\128[\139-\143]", "")
    str = str:gsub("\239\187\191", "")
    return str:lower()
end

local function utf8_codepoint(char)
    local b1, b2, b3, b4 = char:byte(1, 4)

    if not b1 then
        return nil
    end

    if b1 < 0x80 then
        return b1
    end

    if b1 < 0xE0 and b2 then
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80)
    end

    if b1 < 0xF0 and b2 and b3 then
        return (b1 - 0xE0) * 0x1000
            + (b2 - 0x80) * 0x40
            + (b3 - 0x80)
    end

    if b2 and b3 and b4 then
        return (b1 - 0xF0) * 0x40000
            + (b2 - 0x80) * 0x1000
            + (b3 - 0x80) * 0x40
            + (b4 - 0x80)
    end

    return nil
end

local function codepoint_width(cp)
    if not cp then
        return 1
    end

    if cp == 0 then
        return 0
    end

    if cp < 32 or cp == 127 then
        return 0
    end

    if cp >= 0x80 and cp <= 0x9F then
        return 0
    end

    if (cp >= 0x0300 and cp <= 0x036F)
        or (cp >= 0x1AB0 and cp <= 0x1AFF)
        or (cp >= 0x1DC0 and cp <= 0x1DFF)
        or (cp >= 0x20D0 and cp <= 0x20FF)
        or (cp >= 0xFE20 and cp <= 0xFE2F) then
        return 0
    end

    if (cp >= 0x1100 and cp <= 0x115F)
        or cp == 0x2329
        or cp == 0x232A
        or (cp >= 0x2E80 and cp <= 0xA4CF and cp ~= 0x303F)
        or (cp >= 0xAC00 and cp <= 0xD7A3)
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE10 and cp <= 0xFE19)
        or (cp >= 0xFE30 and cp <= 0xFE6F)
        or (cp >= 0xFF00 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
        or (cp >= 0x1F300 and cp <= 0x1FAFF)
        or (cp >= 0x20000 and cp <= 0x3FFFD) then
        return 2
    end

    return 1
end

local function visual_width(str)
    local width = 0

    for char in tostring(str or ""):gmatch(utf8_pattern) do
        width = width + codepoint_width(utf8_codepoint(char))
    end

    return width
end

local function truncate_title(title, max_width)
    title = tostring(title or "")
    max_width = math.floor(tonumber(max_width) or 0)

    if max_width <= 0 or visual_width(title) <= max_width then
        return title
    end

    if max_width <= 3 then
        return string.rep(".", max_width)
    end

    local limit = max_width - 3
    local out = {}
    local width = 0

    for char in title:gmatch(utf8_pattern) do
        local cw = codepoint_width(utf8_codepoint(char))

        if width + cw > limit then
            break
        end

        out[#out + 1] = char
        width = width + cw
    end

    local shortened = table.concat(out):gsub("[%s%._%-%(%)%[%]]+$", "")

    if shortened == "" then
        shortened = table.concat(out)
    end

    return shortened .. "..."
end

local function ass_escape(str)
    str = tostring(str or "")
    str = str:gsub("\\", "\\\239\187\191")
    str = str:gsub("{", "\\{")
    str = str:gsub("}", "\\}")
    return str
end

local function parse_query_parts(query)
    local parts = {}
    query = tostring(query or "")

    local len = #query
    local pos = query:find("%S")

    while pos and pos <= len do
        local first = query:sub(pos, pos)
        local part
        local stop

        if first == '"' or first == "'" then
            stop = query:find(first, pos + 1, true)

            if stop then
                part = query:sub(pos + 1, stop - 1)
            else
                part = query:sub(pos + 1)
                stop = len
            end
        else
            stop = query:find("%s", pos) or (len + 1)
            part = query:sub(pos, stop - 1)
        end

        if part ~= "" then
            parts[#parts + 1] = part
        end

        pos = query:find("%S", stop + 1)
    end

    return parts
end

local function set_search(query)
    query = tostring(query or ""):match("^%s*(.-)%s*$")

    if query == "" then
        search_query = nil
        search_words = nil
        return
    end

    search_query = query
    search_words = parse_query_parts(fold(query))

    if #search_words == 0 then
        search_query = nil
        search_words = nil
    end
end

local function matches_words(text, words)
    if not words then
        return true
    end

    text = fold(text)

    for _, word in ipairs(words) do
        if not text:find(word, 1, true) then
            return false
        end
    end

    return true
end

local function ensure_history_writer()
    if not history_path then
        return nil
    end

    if history_writer then
        return history_writer
    end

    local file, err = io.open(history_path, "ab")

    if not file then
        msg.warn("cannot open history file: " .. tostring(err))
        return nil
    end

    history_writer = file
    return history_writer
end

local function append_history(record)
    if not history_path then
        memory_history[#memory_history + 1] = record
        invalidate_history_cache()
        return true
    end

    local json = utils.format_json(record)

    if not json then
        msg.warn("could not serialize history entry")
        return false
    end

    local file = ensure_history_writer()

    if not file then
        return false
    end

    local ok, result, err = pcall(file.write, file, json, "\n")

    if not ok or not result then
        msg.warn("failed to write history: " .. tostring(ok and err or result))
        close_history_writer()
        return false
    end

    ok, result, err = pcall(file.flush, file)

    if not ok or not result then
        msg.warn("failed to flush history: " .. tostring(ok and err or result))
        close_history_writer()
        return false
    end

    invalidate_history_cache()
    return true
end

local function current_title()
    local pos = mp.get_property_number("playlist-pos", -1)
    local title = ""

    if pos >= 0 then
        title = mp.get_property("playlist/" .. pos .. "/title", "") or ""
    end

    if title == "" then
        title = mp.get_property("media-title", "") or ""
    end

    return title:gsub("[\r\n]+", " ")
end

local function write_history(show_osd)
    local path = current_path()

    if not path then
        if show_osd then
            mp.osd_message("[memo] no path to log")
        end

        return
    end

    local proto = protocol_of(path)

    if proto and data_protocols[proto] then
        if show_osd then
            mp.osd_message("[memo] not logging " .. proto .. " entry")
        end

        return
    end

    local ok = append_history({
        v = 1,
        time = os.time(),
        title = current_title(),
        path = path,
    })

    if ok then
        msg.debug("logged: " .. path)

        if show_osd then
            mp.osd_message("[memo] logged current file")
        end
    elseif show_osd then
        mp.osd_message("[memo] failed to write history")
    end
end

local function count_newlines(str)
    local _, count = str:gsub("\n", "")
    return count
end

local function tail_lines(path, max_lines)
    if history_writer then
        pcall(function()
            history_writer:flush()
        end)
    end

    max_lines = clamp_number(max_lines, 5000, 0)

    local file = io.open(path, "rb")
    if not file then
        return {}
    end

    local size = file:seek("end") or 0
    local data

    if max_lines == 0 then
        file:seek("set", 0)
        data = file:read("*a") or ""
    else
        local pos = size
        local chunk_size = 65536
        local chunks = {}
        local lines_seen = 0

        while pos > 0 and lines_seen <= max_lines do
            local read_size = math.min(chunk_size, pos)
            pos = pos - read_size

            file:seek("set", pos)

            local chunk = file:read(read_size) or ""
            chunks[#chunks + 1] = chunk
            lines_seen = lines_seen + count_newlines(chunk)
        end

        local ordered = {}

        for i = #chunks, 1, -1 do
            ordered[#ordered + 1] = chunks[i]
        end

        data = table.concat(ordered)

        if pos > 0 then
            local first_newline = data:find("\n", 1, true)
            data = first_newline and data:sub(first_newline + 1) or ""
        end
    end

    file:close()

    if data == "" then
        return {}
    end

    if data:sub(-1) ~= "\n" then
        data = data .. "\n"
    end

    local lines = {}

    for line in data:gmatch("(.-)\n") do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end

    if max_lines > 0 and #lines > max_lines then
        local trimmed = {}
        local start = #lines - max_lines + 1

        for i = start, #lines do
            trimmed[#trimmed + 1] = lines[i]
        end

        lines = trimmed
    end

    return lines
end

local function history_stat_key()
    if not history_path then
        return "memory:" .. tostring(#memory_history)
    end

    if history_writer then
        pcall(function()
            history_writer:flush()
        end)
    end

    local info = utils.file_info(history_path)

    if not info then
        return "missing"
    end

    return tostring(info.size or 0) .. ":" .. tostring(info.mtime or 0)
end

local function load_history_records()
    if not history_path then
        return memory_history
    end

    local key = history_stat_key()

    if not history_dirty and cached_records and cached_history_key == key then
        return cached_records
    end

    local lines = tail_lines(history_path, options.max_scan_lines)
    local records = {}

    for _, line in ipairs(lines) do
        local ok, record = pcall(utils.parse_json, line)

        if ok
            and type(record) == "table"
            and type(record.path) == "string"
            and record.path ~= "" then
            records[#records + 1] = record
        end
    end

    cached_records = records
    cached_history_key = key
    history_dirty = false

    return records
end

local function history_iterator()
    local records = load_history_records()
    local i = #records + 1

    return function()
        i = i - 1
        return records[i]
    end
end

local function record_meta(record)
    local meta = record._memo_meta

    if meta then
        return meta
    end

    local path = record.path
    local remote = is_remote_path(path)
    local shown = display_path(path)
    local effective = remote and path or normalize_path(path)

    meta = {
        path = path,
        remote = remote,
        shown = shown,
        effective = effective,
        key = effective,
    }

    record._memo_meta = meta
    return meta
end

local function find_prefix(path, prefixes)
    for _, prefix in ipairs(prefixes or {}) do
        local ok, start_pos, end_pos = pcall(
            string.find,
            path,
            prefix.pattern,
            1,
            prefix.plain
        )

        if ok and start_pos then
            return start_pos, end_pos
        end

        if not ok and not prefix.warned then
            prefix.warned = true
            msg.warn("invalid path_prefix pattern: " .. tostring(prefix.pattern))
        end
    end

    return nil, nil
end

local function directory_menu_entry(path, prefixes)
    local dir = dirname_of(path)

    if dir == "." or dir == "" then
        return nil
    end

    local unix = dir:gsub("\\", "/")

    if unix:sub(-1) ~= "/" then
        unix = unix .. "/"
    end

    local parent = unix:sub(1, -2):match("^(.*)/") or ""
    local _, stop = find_prefix(parent, prefixes)

    if not stop then
        return nil
    end

    local rest = unix:sub(stop + 1):gsub("^/+", "")
    local name = rest:match("^([^/]+)")

    if not name or name == "" then
        return nil
    end

    local root = unix:sub(1, stop)

    if root ~= "" and root:sub(-1) ~= "/" then
        root = root .. "/"
    end

    local dir_key = root .. name

    return name, dir_key
end

local function file_exists(path, cache)
    local cached = cache[path]

    if cached ~= nil then
        return cached
    end

    local exists = utils.file_info(path) ~= nil
    cache[path] = exists

    return exists
end

local function make_context(overrides)
    overrides = overrides or {}

    local ctx = {
        hide_duplicates = overrides.hide_duplicates,
        hide_deleted = overrides.hide_deleted,
        hide_same_dir = overrides.hide_same_dir,
        use_titles = overrides.use_titles,
        truncate_titles = overrides.truncate_titles,
        dir_menu = overrides.dir_menu,
        dir_prefixes = overrides.dir_prefixes,
        search_words = overrides.search_words,
        known_files = {},
        known_dirs = {},
        exists_cache = {},
    }

    if ctx.hide_duplicates == nil then
        ctx.hide_duplicates = options.hide_duplicates
    end

    if ctx.hide_deleted == nil then
        ctx.hide_deleted = options.hide_deleted
    end

    if ctx.hide_same_dir == nil then
        ctx.hide_same_dir = options.hide_same_dir
    end

    if ctx.use_titles == nil then
        ctx.use_titles = options.use_titles
    end

    if ctx.truncate_titles == nil then
        ctx.truncate_titles = options.truncate_titles
    end

    if ctx.dir_menu == nil then
        ctx.dir_menu = dir_menu
    end

    if ctx.dir_prefixes == nil then
        ctx.dir_prefixes = dir_prefixes
    end

    if ctx.search_words == nil then
        ctx.search_words = search_words
    end

    return ctx
end

local function format_timestamp(timestamp)
    timestamp = tonumber(timestamp)

    if not timestamp then
        return ""
    end

    local ok, result = pcall(os.date, options.timestamp_format, timestamp)

    if ok and result then
        return result
    end

    return ""
end

local function make_item(record, ctx)
    local meta = record_meta(record)

    if ctx.hide_duplicates and ctx.known_files[meta.key] then
        return nil
    end

    local title
    local dir_key = nil
    local target_path = meta.path
    local exists_path = meta.effective
    local searchable

    if ctx.dir_menu then
        if meta.remote then
            return nil
        end

        title, dir_key = directory_menu_entry(meta.shown, ctx.dir_prefixes)

        if not title or not dir_key then
            return nil
        end

        if ctx.known_dirs[dir_key] then
            return nil
        end

        -- Directory menu groups entries by configured directory prefix, but
        -- selecting the item loads the latest matching file from that group.
        target_path = meta.path
        exists_path = meta.effective
        searchable = title .. " " .. dir_key
    else
        title = ctx.use_titles and tostring(record.title or "") or ""

        if title == "" then
            title = meta.remote and meta.shown or basename_of(meta.shown)
        end

        if ctx.hide_same_dir and not meta.remote then
            dir_key = dirname_of(meta.shown)

            if ctx.known_dirs[dir_key] then
                return nil
            end
        end

        searchable = ctx.use_titles and title or meta.shown
    end

    title = tostring(title or ""):gsub("[\r\n]+", " ")

    if not matches_words(searchable, ctx.search_words) then
        return nil
    end

    if ctx.hide_deleted and not meta.remote then
        if not file_exists(exists_path, ctx.exists_cache) then
            return nil
        end
    end

    if tonumber(ctx.truncate_titles) and tonumber(ctx.truncate_titles) > 0 then
        title = truncate_title(title, ctx.truncate_titles)
    end

    ctx.known_files[meta.key] = true

    if dir_key then
        ctx.known_dirs[dir_key] = true
    end

    return {
        title = title,
        hint = format_timestamp(record.time),
        value = { "loadfile", target_path, "replace" },
    }
end

local function build_matches(limit, overrides)
    local iter = history_iterator()
    local ctx = make_context(overrides)
    local items = {}

    while true do
        local record = iter()

        if not record then
            break
        end

        local item = make_item(record, ctx)

        if item then
            items[#items + 1] = item

            if limit and #items >= limit then
                break
            end
        end
    end

    return items
end

local function menu_title()
    local title

    if search_query then
        title = search_query
    elseif dir_menu then
        title = "Directories"
    else
        title = "History"
    end

    title = title .. " (memo)"

    if options.pagination or current_page ~= 1 then
        title = title .. " - Page " .. current_page
    end

    return title
end

local function build_page()
    local per_page = clamp_number(options.entries, 10, 1)
    local extra = options.pagination and 1 or 0
    local matches
    local first

    while true do
        local needed = current_page * per_page + extra
        matches = build_matches(needed)
        first = (current_page - 1) * per_page + 1

        if first <= #matches or current_page <= 1 then
            break
        end

        current_page = math.max(1, math.ceil(#matches / per_page))
    end

    local last = math.min(current_page * per_page, #matches)
    local items = {}

    for i = first, last do
        items[#items + 1] = matches[i]
    end

    if options.pagination then
        if #matches > current_page * per_page then
            items[#items + 1] = {
                title = "Older entries",
                hint = "",
                icon = "navigate_next",
                italic = true,
                muted = true,
                keep_open = true,
                value = { "script-binding", "memo-next" },
            }
        end

        if current_page > 1 then
            items[#items + 1] = {
                title = "Newer entries",
                hint = "",
                icon = "navigate_before",
                italic = true,
                muted = true,
                keep_open = true,
                value = { "script-binding", "memo-prev" },
            }
        end
    end

    return {
        type = "memo-history",
        title = menu_title(),
        items = items,
        on_search = { "script-message-to", script_name, "memo-search-uosc:" },
        on_close = { "script-message-to", script_name, "memo-clear" },
        palette = palette_mode,
        search_style = palette_mode and "palette" or nil,
    }
end

local function bind_keys(keys, name, fn, opts)
    if not keys or keys == "" then
        return
    end

    local i = 1

    for key in tostring(keys):gmatch("%S+") do
        local suffix = i == 1 and "" or tostring(i)
        mp.add_forced_key_binding(key, name .. suffix, fn, opts)
        i = i + 1
    end
end

local function unbind_keys(keys, name)
    if not keys or keys == "" then
        return
    end

    local i = 1

    for _ in tostring(keys):gmatch("%S+") do
        local suffix = i == 1 and "" or tostring(i)
        mp.remove_key_binding(name .. suffix)
        i = i + 1
    end
end

local function playlist_contains(path)
    local wanted = is_remote_path(path) and path or normalize_path(path)
    local playlist = mp.get_property_native("playlist", {})

    for _, item in ipairs(playlist) do
        local filename = item.filename

        if filename then
            local candidate = is_remote_path(filename) and filename or normalize_path(filename)

            if candidate == wanted then
                return true
            end
        end
    end

    return false
end

local function select_current(append)
    if not menu_data or not menu_data.items then
        return
    end

    local item = menu_data.items[selected_index]

    if not item or not item.value then
        return
    end

    local command = {}

    for i, value in ipairs(item.value) do
        command[i] = value
    end

    if append and command[1] == "loadfile" then
        if playlist_contains(command[2]) then
            mp.osd_message("[memo] file is already in playlist")
            return
        end

        command[3] = "append-play"
    end

    if not item.keep_open then
        close_menu()
    end

    mp.commandv(unpack(command))
end

local function draw_fallback()
    if not menu_open or not menu_data then
        return
    end

    local width, height = mp.get_osd_size()
    local font_size = mp.get_property_number("osd-font-size", 36)
    local line_height = font_size * 1.25
    local x = font_size * 0.6
    local y = font_size * 0.8

    local items = menu_data.items or {}

    if #items > 0 then
        selected_index = math.max(1, math.min(selected_index, #items))
    else
        selected_index = 0
    end

    local visible = math.max(1, math.floor((height - y - line_height * 2) / line_height))
    local first = 1

    if selected_index > 0 then
        first = math.max(1, selected_index - math.floor(visible / 2))
        first = math.min(first, math.max(1, #items - visible + 1))
    end

    local last = math.min(#items, first + visible - 1)
    local ass = assdraw.ass_new()

    ass.text = "{\\rDefault\\pos(0,0)\\an7\\1c&H000000&\\alpha&H80&}"
    ass:draw_start()
    ass:rect_cw(0, 0, width, height)
    ass:draw_stop()

    ass:new_event()
    ass:pos(x, y)
    ass:append("{\\rDefault\\an7\\fs" .. font_size .. "\\bord2\\b1}")
    ass:append(ass_escape(menu_data.title))
    ass:append("{\\b0}")

    if #items == 0 then
        ass:new_event()
        ass:pos(x, y + line_height * 1.5)
        ass:append("{\\rDefault\\an7\\fs" .. font_size .. "\\bord2}")
        ass:append("No entries")
    else
        for i = first, last do
            local item = items[i]
            local selected = i == selected_index
            local marker = selected and "●" or "○"
            local line = item.title or ""

            if item.hint and item.hint ~= "" then
                line = line .. "    " .. item.hint
            end

            ass:new_event()
            ass:pos(x, y + line_height * (i - first + 1.5))

            if selected then
                ass:append("{\\rDefault\\an7\\fs" .. font_size .. "\\bord2\\b1}")
            else
                ass:append("{\\rDefault\\an7\\fs" .. font_size .. "\\bord2}")
            end

            ass:append(ass_escape(marker .. " " .. line))
        end
    end

    overlay.res_x = width
    overlay.res_y = height
    overlay.hidden = false
    overlay.data = ass.text
    overlay:update()
end

fallback_open = function()
    using_uosc = false
    menu_open = true

    if fallback_bound then
        draw_fallback()
        return
    end

    fallback_bound = true

    bind_keys(options.up_binding, "memo-up", function()
        if not menu_data or not menu_data.items or #menu_data.items == 0 then
            return
        end

        selected_index = math.max(selected_index - 1, 1)
        draw_fallback()
    end, { repeatable = true })

    bind_keys(options.down_binding, "memo-down", function()
        if not menu_data or not menu_data.items or #menu_data.items == 0 then
            return
        end

        selected_index = math.min(selected_index + 1, #menu_data.items)
        draw_fallback()
    end, { repeatable = true })

    bind_keys(options.select_binding, "memo-select", function()
        select_current(false)
    end)

    bind_keys(options.append_binding, "memo-append", function()
        select_current(true)
    end)

    bind_keys(options.close_binding, "memo-close", function()
        close_menu()
    end)

    draw_fallback()
end

fallback_close = function()
    if fallback_bound then
        unbind_keys(options.up_binding, "memo-up")
        unbind_keys(options.down_binding, "memo-down")
        unbind_keys(options.select_binding, "memo-select")
        unbind_keys(options.append_binding, "memo-append")
        unbind_keys(options.close_binding, "memo-close")
        fallback_bound = false
    end

    overlay.hidden = true
    overlay.data = ""
    overlay:update()
end

uosc_update = function()
    if not menu_data then
        return
    end

    local json = utils.format_json(menu_data) or "{}"
    local command = using_uosc and "update-menu" or "open-menu"

    if fallback_bound then
        fallback_close()
    end

    local ok, err = pcall(mp.commandv, "script-message-to", "uosc", command, json)

    if not ok then
        msg.warn("uosc menu failed, using fallback: " .. tostring(err))
        uosc_available = false
        fallback_open()
        return
    end

    menu_open = true
    using_uosc = true
end

local function clear_menu_state()
    fallback_close()

    menu_open = false
    using_uosc = false
    menu_data = nil
    selected_index = 1
    palette_mode = false
end

close_menu = function()
    if using_uosc then
        pcall(mp.commandv, "script-message-to", "uosc", "close-menu", "memo-history")
    end

    clear_menu_state()
end

render_menu = function()
    menu_data = build_page()

    if #menu_data.items > 0 then
        selected_index = math.max(1, math.min(selected_index, #menu_data.items))
    else
        selected_index = 0
    end

    if uosc_available then
        uosc_update()
    else
        fallback_open()
    end
end

local function reset_menu_common()
    current_page = 1
    selected_index = 1
    search_query = nil
    search_words = nil
    palette_mode = false
end

local function open_history()
    reset_menu_common()
    dir_menu = false
    dir_prefixes = parsed_path_prefixes
    render_menu()
end

local function open_dirs(prefixes)
    reset_menu_common()
    dir_menu = true
    dir_prefixes = prefixes and parse_path_prefixes(prefixes) or parsed_path_prefixes
    render_menu()
end

local function next_page()
    current_page = current_page + 1
    selected_index = 1
    render_menu()
end

local function prev_page()
    current_page = math.max(1, current_page - 1)
    selected_index = 1
    render_menu()
end

local function path_key(path)
    if not path then
        return nil
    end

    return is_remote_path(path) and path or normalize_path(path)
end

local function open_last()
    local now_key = path_key(current_path())

    local matches = build_matches(5, {
        hide_duplicates = true,
        hide_deleted = true,
        hide_same_dir = false,
        dir_menu = false,
        search_words = nil,
    })

    for _, item in ipairs(matches) do
        local path = item.value and item.value[2]

        if path and path_key(path) ~= now_key then
            mp.commandv(unpack(item.value))
            return
        end
    end

    mp.osd_message("[memo] no recent files to open")
end

local function file_loaded()
    if options.enabled then
        write_history(false)
    end

    if menu_open and current_page == 1 then
        render_menu()
    end
end

local options_initialized = false

local function apply_option_changes(changed)
    if not options_initialized then
        return
    end

    changed = changed or {}

    local rebind_fallback = changed.up_binding
        or changed.down_binding
        or changed.select_binding
        or changed.append_binding
        or changed.close_binding

    local rerender = changed.entries
        or changed.pagination
        or changed.hide_duplicates
        or changed.hide_deleted
        or changed.hide_same_dir
        or changed.timestamp_format
        or changed.use_titles
        or changed.truncate_titles
        or changed.max_scan_lines
        or changed.path_prefixes

    if changed.history_path then
        close_history_writer()
        history_path = expand_history_path()
        invalidate_history_cache()
        rerender = true
    end

    if changed.max_scan_lines then
        invalidate_history_cache()
    end

    if changed.path_prefixes then
        parsed_path_prefixes = parse_path_prefixes(options.path_prefixes)

        if not dir_menu then
            dir_prefixes = parsed_path_prefixes
        end
    end

    if rebind_fallback and fallback_bound then
        fallback_close()

        if menu_open and not using_uosc then
            fallback_open()
        end
    end

    if rerender and menu_open then
        render_menu()
    end
end

options_mod.read_options(options, "memo", function(changed)
    apply_option_changes(changed)
end)

parsed_path_prefixes = parse_path_prefixes(options.path_prefixes)
dir_prefixes = parsed_path_prefixes
history_path = expand_history_path()
options_initialized = true

mp.register_script_message("uosc-version", function(version)
    local available = not semver_lt(version, "5.0.0")

    if available == uosc_available then
        return
    end

    uosc_available = available

    if menu_open and menu_data then
        if uosc_available then
            uosc_update()
        elseif using_uosc then
            using_uosc = false
            fallback_open()
        end
    end
end)

pcall(function()
    mp.commandv("script-message-to", "uosc", "get-version", script_name)
end)

mp.register_script_message("memo-clear", function()
    search_query = nil
    search_words = nil
    dir_menu = false
    clear_menu_state()
end)

mp.register_script_message("memo-search:", function(...)
    mp.commandv("keypress", "ESC")

    set_search(table.concat({ ... }, " "))

    current_page = 1
    selected_index = 1
    palette_mode = false

    render_menu()
end)

mp.register_script_message("memo-search-uosc:", function(query)
    set_search(query)

    current_page = 1
    selected_index = 1

    render_menu()
end)

mp.register_script_message("memo-dirs", function(prefixes)
    open_dirs(prefixes)
end)

mp.add_key_binding(nil, "memo-next", next_page)
mp.add_key_binding(nil, "memo-prev", prev_page)

mp.add_key_binding(nil, "memo-log", function()
    write_history(true)

    if menu_open and current_page == 1 then
        render_menu()
    end
end)

mp.add_key_binding(nil, "memo-last", open_last)

mp.add_key_binding(nil, "memo-search", function()
    if uosc_available then
        reset_menu_common()
        dir_menu = false
        dir_prefixes = parsed_path_prefixes
        palette_mode = true
        render_menu()
        return
    end

    if menu_open then
        close_menu()
    end

    mp.commandv("script-message-to", "console", "type", "script-message memo-search: ")
end)

mp.add_key_binding(nil, "memo-history", open_history)

mp.register_event("file-loaded", file_loaded)

mp.register_event("shutdown", function()
    close_history_writer()
    fallback_close()
end)
