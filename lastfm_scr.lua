--[[
mpv-lastfm-scrobbler
version 0.6
https://github.com/tsvtt/mpv-lastfm-scrobbler
]]

mp = require('mp')

local SCR_FORMATS = {
    mp3 = true,
    flac = true,
    m4a = true,
}
PLUGIN_NAME = 'lastfm_scr'
SCR_URL = 'http://ws.audioscrobbler.com/2.0/?format=json'
S = '1c62855d245db87aa72d97e04628dfa2'
K = '7c58d2ae379ba37916c438c88455ec03'
URL_K = SCR_URL .. '&api_key=' .. K
SCRIPTS_DIR = mp.find_config_file('scripts')
CONF_FILENAME = '.' .. PLUGIN_NAME .. '.conf'
TMP_FILEPATH = '/tmp/' .. PLUGIN_NAME .. '.temp'
CONF_FILEPATH = SCRIPTS_DIR .. '/'  .. CONF_FILENAME
local SCR_MIN = 20
local JSON_VALUE_RE = '":%s?"([^"]+)'
local uname, sk, timer
local is_paused = false

local IS_FILELOG_SCR = false
local FILELOG_SCR = IS_FILELOG_SCR and io.open(SCRIPTS_DIR .. '/' .. '.scr.log', 'a')

API_METHODS = {
    getSession = 'auth.getSession',
    getToken = 'auth.gettoken',
    scrobble = 'track.scrobble',
    nowPlaying = 'track.updateNowPlaying'
}

subpr_cmd_table = {
    name = "subprocess",
    args = nil,
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
}

logger = {
    _log = function(lvl, ...) mp.msg[lvl:lower()](os.date("%H:%M:%S") .. ' ' .. lvl .. ':', ...) end,
    error = function(...) logger._log('ERROR', ...) end,
    info = function(...) logger._log('INFO', ...) end,
    debug = function(...) logger._log('DEBUG', ...) end,
}

---@param md table
function filelog_scr(md, logfile)
    local f = logfile or FILELOG_SCR
    f:write(os.date("%d-%m %H:%M:%S") .. ' ' .. md.artist .. ' - ' .. md.album .. ' - ' .. md.title .. '\n')
    f:flush()
end

function trim(s)
    return s and s:match "^%s*(.*)":match "(.-)%s*$"
end

function empty(v)
    return not v or v:gsub('%s+', '') == ''
end

---@param res table
---@return table
function subpr_reporter(res)
    logger.debug('Subpr stdout:', res.stdout)
    if res.status ~= 0 then
        if not empty(res.stderr) then logger.error('Subpr stderr:', res.stderr) end
    end
    return res
end

---@param args table
---@return table
function run_subpr_sync(args)
    subpr_cmd_table.args = args
    local res = mp.command_native(subpr_cmd_table)
    return subpr_reporter(res)
end

---@param args table
---@param cb function?
---@return table
function run_subpr_async(args, cb)
    subpr_cmd_table.args = args
    local res = mp.command_native_async(subpr_cmd_table, cb)
    return subpr_reporter(res)
end

---@param url string
---@return table
function curl_get(url)
    return run_subpr_sync({ 'curl', url })
end

---@param url string
---@param kv_pairs string
---@return table
function curl_post(url, kv_pairs)
    return run_subpr_sync({ 'curl', '-d', kv_pairs, url })
end

function api_fetch_token()
    local resp_text = curl_get(URL_K .. '&method=' .. API_METHODS.getToken).stdout
    local token = resp_text and resp_text:match('token' .. JSON_VALUE_RE)
    logger.debug('Fetched token:', token)
    return token
end

function str_to_md5(str)
    local tmpfile = assert(io.open(TMP_FILEPATH, 'w'))
    tmpfile:write(str)
    tmpfile:close()
    return (run_subpr_sync(
        {
            'md5sum',
            TMP_FILEPATH,
        }
    ).stdout):match('^%S+')
end

function repl_api_broken_chars(str)
    --todo: guess it's not the only problematic character...
    if str:find('&') then
        str = str:gsub('&', ' ')
    end
    return str
end


---@param method string
---@param params table
---@return string?
function gen_sig(method, params)
    local sig = ''
    --validate api method
    local valid_method = false
    for k,v in pairs(API_METHODS) do
        if method == v then
            logger.debug('Valid method:', method)
            valid_method = true
        end
    end
    if not valid_method then
        logger.error('Incorrect method:', method)
        return
    end
    --go through params in alpha sorted order and append to sig
    local ordered_params = table_alpha_sorted(params)
    for i,k in ipairs(ordered_params) do
        sig = sig .. k .. params[k]
        logger.debug(k, ": ", params[k])
    end
    sig = sig .. S
    logger.debug('Generated sig: ', sig)
    sig = trim(str_to_md5(sig))
    logger.debug('Hashed sig:', sig)
    return sig
end

function new_session_notify_user(token)
    local url = 'http://www.last.fm/api/auth/?api_key=' .. K .. '&token=' .. token
    print('\n*************************************************************\n')
    print('last.fm requires manual session confirmation. Open the link in a browser and confirm the session:')
    print(url)
    print('\n**************************************************************\n')
    run_subpr_async({ 'xdg-open', url })
end

function api_fetch_session(token)
    local url = URL_K .. '&method=' .. API_METHODS.getSession .. '&token=' .. token
    logger.debug('Requesting URL:', url)
    return curl_get(url).stdout
end

function table_to_urlencoded(t)
    local s = ''
    for k, v in pairs(t) do
        s = s .. k .. '=' .. v .. '&'
    end
    return s:sub(0, s:len() - 1)
end

function table_alpha_sorted(t)
    local i = 1
    local sorted_table = {}
    for k,v in pairs(t) do
        sorted_table[i] = k
        i = i + 1
    end
    table.sort(sorted_table)
    return sorted_table
end

function extract_playmetadata()
    return {
        artist = mp.get_property("metadata/by-key/artist") or '',
        title = mp.get_property("metadata/by-key/title") or '',
        album = mp.get_property("metadata/by-key/album") or '',
        albumArtist = mp.get_property("metadata/by-key/album_artist") or mp.get_property("metadata/by-key/album artist") or '',
    }
end

function filename() return mp.get_property('filename') end
function file_ext() return filename():match('%.(%w+)$') end

function now_playing()
    -- basically copied from scrobble function, updates nowPlaying
    local md = extract_playmetadata()
    local api_params = {
                ['album'] = repl_api_broken_chars(md.album),
                api_key = K,
                method = API_METHODS.nowPlaying,
                sk = sk,
                ['artist'] = repl_api_broken_chars(md.artist),
                ['track'] = repl_api_broken_chars(md.title),
                ['albumArtist'] = repl_api_broken_chars(md.albumArtist),
    }
    api_params.api_sig = gen_sig(API_METHODS.nowPlaying, api_params)
    if empty(api_params.api_sig) or empty(md.artist) or empty(md.title) then
        logger.error("Can't nowPlaying: empty value among required values:",
            'sig=', api_params.api_sig, ',artist=', md.artist, ',title=', md.title)
        return
    end
    local res = curl_post(SCR_URL, table_to_urlencoded(api_params))
    if IS_FILELOG_SCR and res.status == 0 then filelog_scr(md) end
end

---@param timeout number
function scrobble(timeout)
    local md = extract_playmetadata()
    local api_params = {
                ['album[0]'] = repl_api_broken_chars(md.album),
                api_key = K,
                method = API_METHODS.scrobble,
                sk = sk,
                ['artist[0]'] = repl_api_broken_chars(md.artist),
                ['timestamp[0]'] = os.time() - timeout,
                ['track[0]'] = repl_api_broken_chars(md.title),
                ['albumArtist[0]'] = repl_api_broken_chars(md.albumArtist),
    }
    api_params.api_sig = gen_sig(API_METHODS.scrobble, api_params)
    if empty(api_params.api_sig) or empty(md.artist) or empty(md.title) then
        logger.error("Can't scrobble: empty value among required values:",
            'sig=', api_params.api_sig, ',artist=', md.artist, ',title=', md.title)
        return
    end
    local res = curl_post(SCR_URL, table_to_urlencoded(api_params))
    if IS_FILELOG_SCR and res.status == 0 then filelog_scr(md) end
end

---@return number
function calc_scr_timeout()
    local SCR_SEC = 90
    local dur = mp.get_property_number("duration")
    if dur >= SCR_MIN and dur <= SCR_SEC then
        return math.max(dur / 2, SCR_MIN)
    elseif dur >= SCR_MIN and dur < SCR_SEC * 2 then
        return dur / 2
    else
        return SCR_SEC
    end
end

function set_scrobble_timer()
    if SCR_FORMATS[file_ext()] then
        local timeout = calc_scr_timeout()
        timer = mp.add_timeout(timeout, function() scrobble(timeout) end)
        playing_timeout = mp.add_timeout(5, function() now_playing() end)
        if is_paused then
            timer:stop()
            playing_timeout:stop()
        end
    else
        logger.debug('Extension "' .. file_ext() .. '" is not set for scrobbling')
    end
end

function clear_timer()
    if timer then
        logger.debug('clearing the timer')
        timer:kill()
    end
end

function on_file_loaded(_ev)
    logger.debug('file loaded event')
    set_scrobble_timer()
end

function on_file_ended(ev)
    logger.debug('file ended event')
    if ev.reason ~= 'redirect' then
        -- todo: why redirect is sent when playing a file?
        clear_timer()
    end
end

function on_pause(_name, is_paused_ev)
    if is_paused_ev == true then
        is_paused = true
        if timer then timer:stop() end
    else
        is_paused = false
        if timer then timer:resume() end
    end
end

function init_mpv_handlers()
    logger.debug('init mpv handlers')
    mp.register_event("file-loaded", on_file_loaded)
    mp.register_event("end-file", on_file_ended)
    mp.observe_property("pause", "bool", on_pause)
end

function wait_session_approve(token)
    local times = 15

    function fetch_creds()
        local session_resp = api_fetch_session(token)
        if session_resp then
            uname = session_resp:match('name' .. JSON_VALUE_RE)
            sk = session_resp:match('key' .. JSON_VALUE_RE)
        end
    end

    function fetch_creds_loop(...)
        fetch_creds()
        if sk then
            logger.info('Session confirmed with uname=', uname, ' sk=', sk)
            complete_userdata()
        elseif times > 0 then
            logger.debug('Waiting for the user to confirm the session...')
            times = times - 1
            run_subpr_async({ 'sleep', '10' }, fetch_creds_loop)
        else
            logger.error("Can't proceed: API-session wasn't approved by the user")
        end
    end

    fetch_creds_loop()
end

function read_conffile()
    local f = io.open(CONF_FILEPATH, 'r')
    if not f then return; end
    local line = f:read()
    while line do
        uname = uname or line:match('^uname=(.+)')
        sk = sk or line:match('^sk=(.+)')
        line = f:read()
    end
    f:close()
    logger.debug('uname=', uname, ', sk=', sk)
end

function write_conffile()
    logger.debug('Writing conffile')
    local f = io.open(CONF_FILEPATH, 'w')
    if not f then
        logger.error("Can't open", CONF_FILEPATH, 'for_ writing')
        return
    end
    f:write('uname=' .. uname .. '\n')
    f:write('sk=' .. sk .. '\n')
    f:close()
    return true
end

function setup_userdata()
    logger.debug('init userdata')
    local token = api_fetch_token()
    if not token then
        logger.error('token is nil')
        return
    end
    new_session_notify_user(token)
    wait_session_approve(token)
    if not sk then
        logger.error('sk is nil')
        return
    end
    return true
end

function complete_userdata()
    _ = write_conffile() and init_mpv_handlers()
end

function find_curl()
    if run_subpr_sync({ 'which', 'curl' }).status == 0 then
        return true
    else
        logger.error('curl is not found. This plugin requires curl for network requests to last.fm.')
    end
end

function main()
    if not find_curl then return end
    read_conffile()
    if not sk then
        setup_userdata()
    else
        init_mpv_handlers()
    end
end

main()
