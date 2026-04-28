-- thumbfast-modern.lua
--
-- Modern, fast, reliable on-the-fly thumbnailer for mpv 0.38+
--
-- Public API kept:
--   script-message-to thumbfast thumb <time> <x> <y> [script]
--   script-message-to thumbfast clear
--   broadcasts: script-message thumbfast-info <json>
--   optional renderer callback: script-message-to <script> thumbfast-render <json>

local utils = require "mp.utils"
local options = require "mp.options"

local o = {
    -- Base command path. Empty = temp directory.
    -- This is no longer a raw mpv IPC socket; it is an internal command-file base.
    socket = "",

    -- Thumbnail base path. Empty = temp directory.
    thumbnail = "",

    max_height = 200,
    max_width = 200,

    -- Requires mpv overlay scaling support.
    scale_factor = 1,

    -- auto, no, clip, linear, gamma, reinhard, hable, mobius
    tone_mapping = "auto",

    overlay_id = 42,

    spawn_first = false,
    quit_after_inactivity = 0,

    network = false,
    audio = false,
    hwdec = false,

    -- Kept for config compatibility. Ignored by this rewrite.
    direct_io = false,

    mpv_path = "mpv",

    -- Internal tuning.
    file_check_interval = 1 / 60,
    seek_interval = 1 / 30,
    exact_seek_delay = 0.12,
    child_poll_interval = 1 / 120,
}

options.read_options(o, "thumbfast")

local msg = mp.msg
local noop = function() end

local platform = mp.get_property_native("platform") or ""
local is_windows = platform:find("windows", 1, true) ~= nil or package.config:sub(1, 1) == "\\"
local is_macos = platform:find("darwin", 1, true) ~= nil or platform:find("mac", 1, true) ~= nil
local sep = is_windows and "\\" or "/"

local function path_join(a, b)
    if not a or a == "" then return b end
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then
        return a .. b
    end
    return a .. sep .. b
end

local tmpdir =
    os.getenv("TMPDIR") or
    os.getenv("TEMP") or
    os.getenv("TMP") or
    (is_windows and "." or "/tmp")

local pid = tostring(utils.getpid() or math.floor(mp.get_time() * 1000000))

if o.socket == "" then
    o.socket = path_join(tmpdir, "thumbfast-" .. pid)
else
    o.socket = o.socket .. pid
end

if o.thumbnail == "" then
    o.thumbnail = path_join(tmpdir, "thumbfast.out." .. pid)
else
    o.thumbnail = o.thumbnail .. pid
end

o.max_width = math.max(1, tonumber(o.max_width) or 200)
o.max_height = math.max(1, tonumber(o.max_height) or 200)
o.scale_factor = math.max(1, math.floor(tonumber(o.scale_factor) or 1))

local thumbnail_bgra = o.thumbnail .. ".bgra"

local mpv_path = o.mpv_path
if is_windows and mpv_path == "mpv" then
    mpv_path = mp.get_property_native("user-data/frontend/process-path") or mpv_path
end

local properties = {}

local disabled = true
local dirty = false

local effective_w = o.max_width
local effective_h = o.max_height
local real_w, real_h
local last_real_w, last_real_h

local x, y
local last_x, last_y
local script_name
local show_thumbnail = false

local has_vid = 0
local last_has_vid = 0

local last_seek_time
local allow_fast_seek = true
local pending_seek = false

local last_rotate = 0
local last_vf_reset = ""
local last_vf_runtime = ""
local last_par = ""
local last_crop = nil
local last_tone_mapping = nil

local par = ""

local generation = 0
local current = nil
local children = {}

local filters_reset = {
    ["lavfi-crop"] = true,
    ["crop"] = true,
}

local filters_runtime = {
    ["hflip"] = true,
    ["vflip"] = true,
}

local filters_all = {
    ["hflip"] = true,
    ["vflip"] = true,
    ["lavfi-crop"] = true,
    ["crop"] = true,
}

local tone_mappings = {
    ["none"] = true,
    ["clip"] = true,
    ["linear"] = true,
    ["gamma"] = true,
    ["reinhard"] = true,
    ["hable"] = true,
    ["mobius"] = true,
}

local function command_async(cmd)
    mp.command_native_async(cmd, noop)
end

local function subprocess_async(args, callback)
    local ok, ret = pcall(mp.command_native_async, {
        name = "subprocess",
        playback_only = true,
        args = args,
    }, callback or noop)

    if not ok then
        msg.error("failed to start subprocess: " .. tostring(ret))
        return nil
    end

    return ret
end

local function atomic_write(path, data)
    local tmp = path .. ".tmp"

    local f, err = io.open(tmp, "wb")
    if not f then
        msg.warn("cannot open temporary command file: " .. tostring(err))
        return false
    end

    f:write(data)
    f:close()

    if is_windows then
        os.remove(path)
    end

    local ok, rename_err = os.rename(tmp, path)
    if ok then
        return true
    end

    -- Fallback for filesystems where rename-over-existing is awkward.
    local wf, write_err = io.open(path, "wb")
    if not wf then
        msg.warn("cannot write command file: " .. tostring(rename_err or write_err))
        os.remove(tmp)
        return false
    end

    wf:write(data)
    wf:close()
    os.remove(tmp)
    return true
end

local function move_file(from, to)
    if is_windows then
        os.remove(to)
    end
    return os.rename(from, to)
end

local function vo_tone_mapping()
    local passes = mp.get_property_native("vo-passes")
    if not passes or not passes.fresh then return nil end

    for _, pass in pairs(passes.fresh) do
        for k, v in pairs(pass) do
            if k == "desc" and v then
                local tm = tostring(v):match("([0-9a-zA-Z._-]+) tone map")
                if tm then return tm end
            end
        end
    end

    return nil
end

local function vf_string(filters, full)
    local vf = ""

    local crop = properties["video-crop"] or ""
    if crop ~= "" then
        vf = "lavfi-crop=" ..
            crop:gsub("(%d*)x?(%d*)%+(%d+)%+(%d+)", "w=%1:h=%2:x=%3:y=%4") ..
            ","

        local params = properties["video-out-params"]
        local width = params and params.dw
        local height = params and params.dh

        if width and height then
            vf = vf:gsub("w=:h=:", "w=" .. width .. ":h=" .. height .. ":")
        end
    end

    local vf_table = properties.vf
    if vf_table and #vf_table > 0 then
        for i = #vf_table, 1, -1 do
            local filter = vf_table[i]
            if filter and filters[filter.name] then
                local args = ""
                local params = filter.params or {}

                for key, value in pairs(params) do
                    if args ~= "" then args = args .. ":" end
                    args = args .. tostring(key) .. "=" .. tostring(value)
                end

                vf = vf .. tostring(filter.name) .. "=" .. args .. ","
            end
        end
    end

    if (full and o.tone_mapping ~= "no") or o.tone_mapping == "auto" then
        local vp = properties["video-params"]
        if vp and vp.primaries == "bt.2020" then
            local tm = o.tone_mapping

            if tm == "auto" then
                tm = last_tone_mapping or properties["tone-mapping"]

                if tm == "auto" and properties["current-vo"] == "gpu-next" then
                    tm = vo_tone_mapping()
                end
            end

            if not tone_mappings[tm] then
                tm = "hable"
            end

            last_tone_mapping = tm

            vf = vf ..
                "zscale=transfer=linear," ..
                "format=gbrpf32le," ..
                "tonemap=" .. tm .. "," ..
                "zscale=transfer=bt709,"
        end
    end

    if full then
        vf = vf ..
            "scale=w=" .. effective_w .. ":h=" .. effective_h .. par .. "," ..
            "pad=w=" .. effective_w .. ":h=" .. effective_h .. ":x=-1:y=-1," ..
            "format=bgra"
    end

    return vf
end

local function calc_dimensions()
    local params = properties["video-out-params"]
    local width = params and params.dw
    local height = params and params.dh

    if not width or not height or width <= 0 or height <= 0 then
        return false
    end

    local hidpi = tonumber(properties["display-hidpi-scale"]) or 1

    if width / height > o.max_width / o.max_height then
        effective_w = math.floor(o.max_width * hidpi + 0.5)
        effective_h = math.floor(height / width * effective_w + 0.5)
    else
        effective_h = math.floor(o.max_height * hidpi + 0.5)
        effective_w = math.floor(width / height * effective_h + 0.5)
    end

    local vpar = params.par or 1
    par = vpar == 1 and ":force_original_aspect_ratio=decrease" or ""

    effective_w = math.max(1, effective_w)
    effective_h = math.max(1, effective_h)

    return true
end

local function selected_video_track()
    return properties["current-tracks/video"]
end

local function video_available()
    local vid = properties.vid

    if vid == false or vid == "no" then
        return false
    end

    return has_vid ~= 0 or selected_video_track() ~= nil or properties["video-out-params"] ~= nil
end

local function publish_info(w, h)
    local track = selected_video_track()
    local image = track and track.image
    local albumart = image and track.albumart

    disabled =
        (w or 0) <= 0 or
        (h or 0) <= 0 or
        not video_available() or
        (properties["demuxer-via-network"] and not o.network) or
        (albumart and not o.audio) or
        (image and not albumart)

    local json = utils.format_json({
        width = (w or 0) * o.scale_factor,
        height = (h or 0) * o.scale_factor,
        scale_factor = o.scale_factor,
        disabled = disabled,
        available = true,
        socket = current and current.command_file or o.socket,
        thumbnail = o.thumbnail,
        overlay_id = o.overlay_id,
    })

    command_async({ "script-message", "thumbfast-info", json })
end

local function make_child_script(command_file, token)
    return
        "local utils = require 'mp.utils'\n" ..
        "local command_file = " .. string.format("%q", command_file) .. "\n" ..
        "local token = " .. string.format("%q", token) .. "\n" ..
        "local last_seq = -1\n" ..
        "local function read_all(path)\n" ..
        "    local f = io.open(path, 'rb')\n" ..
        "    if not f then return nil end\n" ..
        "    local s = f:read('*a')\n" ..
        "    f:close()\n" ..
        "    return s\n" ..
        "end\n" ..
        "local function apply(cmd)\n" ..
        "    if type(cmd) ~= 'table' then return end\n" ..
        "    if cmd.token ~= token then return end\n" ..
        "    if type(cmd.seq) ~= 'number' or cmd.seq == last_seq then return end\n" ..
        "    last_seq = cmd.seq\n" ..
        "    if cmd.cmd == 'seek' then\n" ..
        "        local mode = cmd.fast and 'absolute+keyframes' or 'absolute+exact'\n" ..
        "        mp.command_native_async({'seek', tonumber(cmd.time) or 0, mode}, function() end)\n" ..
        "    elseif cmd.cmd == 'set' and cmd.property then\n" ..
        "        pcall(mp.set_property_native, cmd.property, cmd.value)\n" ..
        "    elseif cmd.cmd == 'vf' then\n" ..
        "        mp.commandv('vf', 'set', cmd.value or '')\n" ..
        "    elseif cmd.cmd == 'quit' then\n" ..
        "        mp.commandv('quit')\n" ..
        "    end\n" ..
        "end\n" ..
        "mp.add_periodic_timer(" .. tostring(o.child_poll_interval) .. ", function()\n" ..
        "    local s = read_all(command_file)\n" ..
        "    if not s or s == '' then return end\n" ..
        "    local ok, cmd = pcall(utils.parse_json, s)\n" ..
        "    if ok then pcall(apply, cmd) end\n" ..
        "end)\n"
end

local function write_child_script(proc)
    local f, err = io.open(proc.script, "wb")
    if not f then
        msg.error("cannot write child script: " .. tostring(err))
        return false
    end

    f:write(make_child_script(proc.command_file, proc.token))
    f:close()
    return true
end

local function cleanup_proc(proc)
    if not proc then return end

    os.remove(proc.command_file)
    os.remove(proc.command_file .. ".tmp")
    os.remove(proc.script)
    os.remove(proc.output)
    os.remove(proc.output .. ".tmp")

    children[proc.generation] = nil
end

local function write_command(proc, cmd)
    if not proc then return false end

    proc.seq = (proc.seq or 0) + 1
    cmd.seq = proc.seq
    cmd.token = proc.token

    local json = utils.format_json(cmd)
    if not json then return false end

    return atomic_write(proc.command_file, json)
end

local activity_timer

local function bump_activity()
    if o.quit_after_inactivity <= 0 or not current then
        return
    end

    if activity_timer:is_enabled() then
        activity_timer:kill()
    end

    activity_timer:resume()
end

local function stop_child()
    if current then
        current.quitting = true
        write_command(current, { cmd = "quit" })
        current = nil
    end
end

local function spawn(time)
    if disabled then return false end

    local path = properties.path
    if not path or path == "" then return false end

    local open_filename = properties["stream-open-filename"]
    if open_filename and properties["demuxer-via-network"] and path ~= open_filename then
        path = open_filename
    end

    generation = generation + 1

    local proc = {
        generation = generation,
        token = pid .. ":" .. tostring(generation),
        command_file = o.socket .. ".cmd." .. tostring(generation),
        script = o.socket .. ".child." .. tostring(generation) .. ".lua",
        output = o.thumbnail .. ".raw." .. tostring(generation),
        seq = 0,
        quitting = false,
    }

    if not write_child_script(proc) then
        cleanup_proc(proc)
        return false
    end

    os.remove(proc.output)

    local vid = properties.vid
    if vid == false or vid == "no" or vid == nil then
        vid = "auto"
    end

    local rotate = properties["video-rotate"] or last_rotate or 0

    local args = {
        mpv_path,

        "--no-config",
        "--really-quiet",
        "--no-terminal",

        "--idle=yes",
        "--pause=yes",
        "--keep-open=always",

        "--load-scripts=no",
        "--scripts=" .. proc.script,

        "--osc=no",
        "--ytdl=no",
        "--no-sub",
        "--no-audio",

        "--edition=" .. tostring(properties.edition or "auto"),
        "--vid=" .. tostring(vid),

        "--start=" .. tostring(tonumber(time) or 0),
        allow_fast_seek and "--hr-seek=no" or "--hr-seek=yes",

        "--ytdl-format=worst",
        "--demuxer-readahead-secs=0",
        "--demuxer-max-bytes=512KiB",

        "--vd-lavc-skiploopfilter=all",
        "--vd-lavc-software-fallback=1",
        "--vd-lavc-fast",
        "--vd-lavc-threads=2",
        "--hwdec=" .. (o.hwdec and "auto" or "no"),

        "--vf=" .. vf_string(filters_all, true),
        "--sws-scaler=fast-bilinear",
        "--sws-allow-zimg=no",

        "--video-rotate=" .. tostring(rotate),

        "--ovc=rawvideo",
        "--of=image2",
        "--ofopts=update=1",
        "--o=" .. proc.output,
    }

    if mp.get_property_native("media-controls") ~= nil then
        table.insert(args, "--media-controls=no")
    end

    if is_macos and properties["macos-app-activation-policy"] then
        table.insert(args, "--macos-app-activation-policy=accessory")
    end

    table.insert(args, "--")
    table.insert(args, path)

    current = proc
    children[proc.generation] = proc

    local ret = subprocess_async(args, function(success, result)
        local status = result and result.status

        if current and current.generation == proc.generation then
            current = nil
        end

        cleanup_proc(proc)

        if success == false or (status and status ~= 0 and status ~= -2) then
            if not proc.quitting then
                msg.error("thumbnail mpv subprocess failed")
                mp.commandv("show-text", "thumbfast: thumbnail subprocess failed", 5000)
            end
        end
    end)

    if not ret then
        if current and current.generation == proc.generation then
            current = nil
        end
        cleanup_proc(proc)
        mp.commandv("show-text", "thumbfast: cannot create mpv subprocess", 5000)
        return false
    end

    bump_activity()
    publish_info(real_w or effective_w, real_h or effective_h)
    return true
end

local seek_timer
local exact_seek_timer

local function send_seek(fast)
    if current and last_seek_time ~= nil then
        write_command(current, {
            cmd = "seek",
            time = last_seek_time,
            fast = fast and true or false,
        })
    end
end

seek_timer = mp.add_timeout(o.seek_interval, function()
    if pending_seek then
        pending_seek = false
        send_seek(allow_fast_seek)
        seek_timer:resume()
    end
end)
seek_timer:kill()

exact_seek_timer = mp.add_timeout(o.exact_seek_delay, function()
    if allow_fast_seek then
        send_seek(false)
    end
end)
exact_seek_timer:kill()

local function request_seek()
    if not current then
        spawn(last_seek_time or mp.get_property_number("time-pos", 0))
    end

    if not current then return end

    if seek_timer:is_enabled() then
        pending_seek = true
    else
        pending_seek = false
        send_seek(allow_fast_seek)
        seek_timer:resume()
    end

    if allow_fast_seek then
        if exact_seek_timer:is_enabled() then
            exact_seek_timer:kill()
        end
        exact_seek_timer:resume()
    end
end

local function real_res(req_w, req_h, filesize)
    local count = filesize / 4
    local diff = req_w * req_h - count

    local rotate = properties["video-params"] and properties["video-params"].rotate or 0
    if rotate % 180 == 90 then
        req_w, req_h = req_h, req_w
    end

    if diff == 0 then
        return req_w, req_h
    end

    local threshold = 5
    local long_side, short_side = req_w, req_h

    if req_h > req_w then
        long_side, short_side = req_h, req_w
    end

    for a = short_side, short_side - threshold, -1 do
        if a > 0 and count % a == 0 then
            local b = count / a
            if long_side - b < threshold then
                if req_h < req_w then
                    return b, a
                else
                    return a, b
                end
            end
        end
    end

    return nil
end

local function draw(w, h, script)
    if not w or not h or not show_thumbnail then return end

    if x ~= nil and y ~= nil then
        local cmd = {
            "overlay-add",
            o.overlay_id,
            x,
            y,
            thumbnail_bgra,
            0,
            "bgra",
            w,
            h,
            4 * w,
        }

        if o.scale_factor ~= 1 then
            table.insert(cmd, w * o.scale_factor)
            table.insert(cmd, h * o.scale_factor)
        end

        command_async(cmd)
    elseif script then
        local json = utils.format_json({
            width = w,
            height = h,
            scale_factor = o.scale_factor,
            socket = current and current.command_file or o.socket,
            thumbnail = o.thumbnail,
            overlay_id = o.overlay_id,
        })

        mp.commandv("script-message-to", script, "thumbfast-render", json)
    end
end

local file_timer

local function check_new_thumb()
    local proc = current
    if not proc then return false end

    local tmp = proc.output .. ".tmp"

    if not move_file(proc.output, tmp) then
        return false
    end

    local finfo = utils.file_info(tmp)
    if not finfo or not finfo.is_file or finfo.size <= 0 then
        os.remove(tmp)
        return false
    end

    local w, h = real_res(effective_w, effective_h, finfo.size)

    if not w or not h then
        os.remove(tmp)
        return false
    end

    if not move_file(tmp, thumbnail_bgra) then
        os.remove(tmp)
        return false
    end

    real_w, real_h = w, h

    if real_w ~= last_real_w or real_h ~= last_real_h then
        last_real_w, last_real_h = real_w, real_h
        publish_info(real_w, real_h)
    end

    if not show_thumbnail then
        file_timer:kill()
    end

    return true
end

file_timer = mp.add_periodic_timer(o.file_check_interval, function()
    if check_new_thumb() then
        draw(real_w, real_h, script_name)
    end
end)
file_timer:kill()

local function clear(no_activity)
    file_timer:kill()
    seek_timer:kill()
    exact_seek_timer:kill()

    pending_seek = false
    last_seek_time = nil

    show_thumbnail = false
    last_x, last_y = nil, nil

    local used_external_renderer = script_name ~= nil and x == nil
    script_name = nil

    if not used_external_renderer then
        command_async({ "overlay-remove", o.overlay_id })
    end

    if not no_activity then
        bump_activity()
    end
end

activity_timer = mp.add_timeout(math.max(0.001, o.quit_after_inactivity), function()
    if show_thumbnail then
        bump_activity()
        return
    end

    stop_child()
    real_w, real_h = nil, nil
end)
activity_timer:kill()

local function thumb(time, r_x, r_y, script)
    if disabled then return end

    time = tonumber(time)
    if not time then return end

    local nx = tonumber(r_x)
    local ny = tonumber(r_y)

    if nx and ny then
        x = math.floor(nx + 0.5)
        y = math.floor(ny + 0.5)
    else
        x, y = nil, nil
    end

    script_name = script

    if last_x ~= x or last_y ~= y or not show_thumbnail then
        show_thumbnail = true
        last_x, last_y = x, y
        draw(real_w, real_h, script)
    end

    if time == last_seek_time then
        bump_activity()
        return
    end

    last_seek_time = time
    request_seek()

    if not file_timer:is_enabled() then
        file_timer:resume()
    end

    bump_activity()
end

local function update_property(name, value)
    properties[name] = value
end

local function update_property_dirty(name, value)
    properties[name] = value
    dirty = true

    if name == "tone-mapping" then
        last_tone_mapping = nil
    end
end

local function update_tracklist(_, value)
    properties["current-tracks/video"] = nil
    has_vid = 0

    if type(value) == "table" then
        for _, track in ipairs(value) do
            if track.type == "video" and track.selected then
                properties["current-tracks/video"] = track
                has_vid = 1
                break
            end
        end
    end

    dirty = true
end

local function sync_property_to_child(prop, val)
    properties[prop] = val

    if prop == "vid" then
        if val == false or val == "no" then
            has_vid = 0
            last_has_vid = 0
            publish_info(effective_w, effective_h)
            clear()
            return
        else
            has_vid = 1
        end
    end

    if current then
        write_command(current, {
            cmd = "set",
            property = prop,
            value = val,
        })
    end

    dirty = true
end

local function watch_changes()
    if not dirty or not properties["video-out-params"] then
        return
    end

    dirty = false

    local old_w = effective_w
    local old_h = effective_h

    if not calc_dimensions() then
        publish_info(0, 0)
        return
    end

    local vf_reset = vf_string(filters_reset, false)
    local rotate = properties["video-rotate"] or 0

    local resized =
        old_w ~= effective_w or
        old_h ~= effective_h or
        last_vf_reset ~= vf_reset or
        last_rotate % 180 ~= rotate % 180 or
        par ~= last_par or
        last_crop ~= properties["video-crop"]

    if resized then
        publish_info(effective_w, effective_h)
    elseif last_has_vid ~= has_vid and has_vid ~= 0 then
        publish_info(effective_w, effective_h)
    end

    if current then
        if resized then
            local seek_time = last_seek_time or mp.get_property_number("time-pos", 0)

            stop_child()
            clear(true)

            real_w, real_h = nil, nil
            last_real_w, last_real_h = nil, nil

            spawn(seek_time)

            if show_thumbnail or o.spawn_first then
                file_timer:resume()
            end
        else
            if rotate ~= last_rotate then
                write_command(current, {
                    cmd = "set",
                    property = "video-rotate",
                    value = rotate,
                })
            end

            local vf_runtime = vf_string(filters_runtime, false)
            if vf_runtime ~= last_vf_runtime then
                write_command(current, {
                    cmd = "vf",
                    value = vf_string(filters_all, true),
                })

                last_vf_runtime = vf_runtime
            end
        end
    else
        last_vf_runtime = vf_string(filters_runtime, false)
    end

    last_vf_reset = vf_reset
    last_rotate = rotate
    last_par = par
    last_crop = properties["video-crop"]
    last_has_vid = has_vid

    if not current and not disabled and o.spawn_first and resized then
        spawn(mp.get_property_number("time-pos", 0))
        file_timer:resume()
    end
end

mp.add_periodic_timer(0.05, watch_changes)

local function remove_thumbnail_files()
    os.remove(o.thumbnail)
    os.remove(thumbnail_bgra)
    os.remove(o.thumbnail .. ".tmp")

    for _, proc in pairs(children) do
        cleanup_proc(proc)
    end
end

local function file_loaded()
    stop_child()
    clear(true)

    real_w, real_h = nil, nil
    last_real_w, last_real_h = nil, nil
    last_tone_mapping = nil
    last_seek_time = nil

    remove_thumbnail_files()

    calc_dimensions()
    publish_info(effective_w, effective_h)

    dirty = true
end

local function shutdown()
    stop_child()
    remove_thumbnail_files()

    os.remove(o.socket)
    os.remove(o.socket .. ".tmp")
end

local function on_duration(_, val)
    allow_fast_seek = (tonumber(val) or 30) >= 30
end

mp.observe_property("current-tracks/video", "native", update_property_dirty)
mp.observe_property("track-list", "native", update_tracklist)

mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-out-params", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("vf", "native", update_property_dirty)
mp.observe_property("tone-mapping", "native", update_property_dirty)

mp.observe_property("demuxer-via-network", "native", update_property)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("macos-app-activation-policy", "native", update_property)
mp.observe_property("current-vo", "native", update_property)
mp.observe_property("video-rotate", "native", update_property_dirty)
mp.observe_property("video-crop", "native", update_property_dirty)
mp.observe_property("path", "native", update_property)

mp.observe_property("vid", "native", sync_property_to_child)
mp.observe_property("edition", "native", sync_property_to_child)
mp.observe_property("duration", "native", on_duration)

mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)

mp.register_event("file-loaded", file_loaded)
mp.register_event("shutdown", shutdown)
