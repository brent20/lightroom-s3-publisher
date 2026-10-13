-- S3Upload.lua
-- Thin S3 / Cloudflare R2 client built on the system curl (--aws-sigv4, needs curl >= 7.75).
--
-- Credentials and request details are written to a short-lived curl config file (-K) so the
-- secret key never appears on the command line / in the process list.

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrMD5 = import 'LrMD5'
local LrLogger = import 'LrLogger'

local logger = LrLogger('S3Upload')
logger:enable('logfile') -- ~/Documents/LrClassicLogs/S3Upload.log

local M = {}

local MAX_ATTEMPTS = 3

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function trim(s)
  s = tostring(s or '')
  s = s:gsub('^%s+', '')
  s = s:gsub('%s+$', '')
  return s
end

-- Quote a value for the shell command line.
local function shq(s)
  if WIN_ENV then
    return '"' .. s .. '"'
  end
  local escaped = s:gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

-- Quote a value for a curl config file (backslash and double quote are escapes there).
local function cq(s)
  local escaped = tostring(s):gsub('\\', '\\\\')
  escaped = escaped:gsub('"', '\\"')
  return '"' .. escaped .. '"'
end

local counter = 0
local function tempPath(ext)
  counter = counter + 1
  local seed = tostring(os.time()) .. tostring(os.clock()) .. counter .. tostring(math.random())
  local name = 's3up-' .. LrMD5.digest(seed) .. (ext or '')
  return LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), name)
end

local function writeFile(path, contents)
  local fh = io.open(path, 'wb')
  if not fh then return false end
  fh:write(contents)
  fh:close()
  return true
end

local function readFile(path)
  if not LrFileUtils.exists(path) then return '' end
  return LrFileUtils.readFile(path) or ''
end

local function removeFile(path)
  if path and LrFileUtils.exists(path) then
    LrFileUtils.delete(path)
  end
end

-- Percent-encode an object key, keeping "/" separators.
local function encodeKey(key)
  return (key:gsub('[^%w%-%._~/]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

local CONTENT_TYPES = {
  jpg = 'image/jpeg', jpeg = 'image/jpeg', png = 'image/png',
  tif = 'image/tiff', tiff = 'image/tiff', dng = 'image/x-adobe-dng',
  gif = 'image/gif', webp = 'image/webp', json = 'application/json',
}

function M.contentTypeFor(path)
  local ext = (LrPathUtils.extension(path) or ''):lower()
  return CONTENT_TYPES[ext] or 'application/octet-stream'
end

---------------------------------------------------------------------------
-- keys and URLs
---------------------------------------------------------------------------

-- "" or a prefix with no leading slash and exactly one trailing slash.
function M.normalizePrefix(prefix)
  prefix = trim(prefix)
  prefix = prefix:gsub('^/+', '')
  prefix = prefix:gsub('/+$', '')
  if prefix == '' then return '' end
  return prefix .. '/'
end

-- Thumbnail key that goes with a full-size key: <dir>/thumbs/<basename>.jpg
function M.thumbKey(key)
  local dir, leaf = key:match('^(.*/)([^/]+)$')
  if not dir then
    dir, leaf = '', key
  end
  local base = leaf:gsub('%.[^%.]*$', '')
  return dir .. 'thumbs/' .. base .. '.jpg'
end

function M.objectUrl(settings, key)
  local enc = encodeKey(key)
  local endpoint = trim(settings.endpoint)
  if endpoint ~= '' then
    if not endpoint:match('^https?://') then
      endpoint = 'https://' .. endpoint
    end
    endpoint = endpoint:gsub('/+$', '')
    return endpoint .. '/' .. trim(settings.bucket) .. '/' .. enc
  end
  return string.format('https://%s.s3.%s.amazonaws.com/%s',
    trim(settings.bucket), trim(settings.region), enc)
end

-- Public URL for a key if the user configured a public base URL (R2 custom domain etc).
function M.publicUrl(settings, key)
  local base = trim(settings.publicBaseUrl)
  if base == '' then return nil end
  base = base:gsub('/+$', '')
  return base .. '/' .. encodeKey(key)
end

---------------------------------------------------------------------------
-- curl request
---------------------------------------------------------------------------

-- method: 'PUT' (needs opts.file) or 'DELETE'. Returns ok (bool), message (string).
local function request(settings, method, key, opts)
  opts = opts or {}
  local url = M.objectUrl(settings, key)
  local region = trim(settings.region)
  if region == '' then region = 'auto' end

  local lastMessage = 'unknown error'

  for attempt = 1, MAX_ATTEMPTS do
    local cfg, out, codeFile, errFile = tempPath('.cfg'), tempPath('.out'), tempPath('.code'), tempPath('.err')

    local lines = {
      'silent',
      'show-error',
      'connect-timeout = 30',
      'url = ' .. cq(url),
      'user = ' .. cq(trim(settings.accessKey) .. ':' .. trim(settings.secretKey)),
      'aws-sigv4 = ' .. cq('aws:amz:' .. region .. ':s3'),
      'header = ' .. cq('x-amz-content-sha256: UNSIGNED-PAYLOAD'),
      'output = ' .. cq(out),
      'write-out = ' .. cq('%{http_code}'),
    }
    if method == 'PUT' then
      lines[#lines + 1] = 'header = ' .. cq('Content-Type: ' .. (opts.contentType or M.contentTypeFor(opts.file)))
      lines[#lines + 1] = 'upload-file = ' .. cq(opts.file)
    else
      lines[#lines + 1] = 'request = ' .. cq(method)
    end
    if settings.insecureTls then
      lines[#lines + 1] = 'insecure'
    end

    local ok, message = false, nil

    if not writeFile(cfg, table.concat(lines, '\n') .. '\n') then
      return false, 'could not write temporary curl config'
    end
    if not WIN_ENV then
      LrTasks.execute('/bin/chmod 600 ' .. shq(cfg))
    end

    local curl = WIN_ENV and 'curl' or '/usr/bin/curl'
    local cmd = curl .. ' -K ' .. shq(cfg) .. ' > ' .. shq(codeFile) .. ' 2> ' .. shq(errFile)
    if WIN_ENV then
      cmd = '"' .. cmd .. '"'
    end

    local rc = LrTasks.execute(cmd)
    local code = trim(readFile(codeFile))
    local body = trim(readFile(out))
    local err = trim(readFile(errFile))

    removeFile(cfg); removeFile(out); removeFile(codeFile); removeFile(errFile)

    if rc == 0 and code:match('^2%d%d$') then
      ok = true
    else
      message = string.format('%s %s failed (curl exit %s, HTTP %s)', method, key, tostring(rc), code ~= '' and code or 'n/a')
      if err ~= '' then message = message .. ': ' .. err:sub(1, 300) end
      if body ~= '' then message = message .. ' | ' .. body:sub(1, 300) end
      lastMessage = message
      logger:warn(message)
    end

    if ok then
      logger:info(string.format('%s %s OK (HTTP %s)', method, key, code))
      return true, 'OK'
    end

    -- Retry only transient failures (network error or 5xx / throttling).
    local transient = (rc ~= 0) or code:match('^5%d%d$') or code == '429' or code == '000'
    if not transient or attempt == MAX_ATTEMPTS then
      break
    end
    LrTasks.sleep(attempt)
  end

  return false, lastMessage
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

function M.put(settings, filePath, key, contentType)
  return request(settings, 'PUT', key, { file = filePath, contentType = contentType })
end

function M.putString(settings, text, key, contentType)
  local tmp = tempPath('.tmp')
  if not writeFile(tmp, text) then
    return false, 'could not write temporary file'
  end
  local ok, msg = request(settings, 'PUT', key, { file = tmp, contentType = contentType or 'application/octet-stream' })
  removeFile(tmp)
  return ok, msg
end

function M.delete(settings, key)
  return request(settings, 'DELETE', key)
end

-- Creates a resized JPEG copy of srcPath in the temp folder. Returns its path, or nil.
function M.makeThumb(settings, srcPath)
  local size = tonumber(settings.thumbSize) or 800
  local out = tempPath('.jpg')
  local cmd
  if WIN_ENV then
    -- Needs ImageMagick on PATH; without it thumbnails are skipped.
    cmd = '"magick ' .. shq(srcPath) .. ' -resize ' .. size .. 'x' .. size .. ' ' .. shq(out) .. '"'
  else
    cmd = '/usr/bin/sips -s format jpeg -Z ' .. size .. ' ' .. shq(srcPath) .. ' --out ' .. shq(out) .. ' > /dev/null 2>&1'
  end
  LrTasks.execute(cmd)
  if LrFileUtils.exists(out) then
    return out
  end
  logger:warn('thumbnail creation failed for ' .. srcPath)
  return nil
end

function M.removeTemp(path)
  removeFile(path)
end

return M
