-- ExportServiceProvider.lua
-- Export + Publish Service provider for Amazon S3 / Cloudflare R2.
--
-- As an export service: File > Export (or right-click > Export) uploads the rendered photos.
-- As a publish service: appears under Library > Publish Services. Drag photos into a
-- collection and click Publish. Edited photos show up under "Modified Photos to Re-Publish";
-- re-publishing overwrites the object in the bucket. Removing a photo from the collection
-- (then publishing) deletes it from the bucket.

local LrView = import 'LrView'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'

local S3Upload = require 'S3Upload'

local bind = LrView.bind
local share = LrView.share

local logger = LrLogger('S3Upload')
logger:enable('logfile')

local provider = {}

---------------------------------------------------------------------------
-- provider configuration
---------------------------------------------------------------------------

provider.supportsIncrementalPublish = true -- true = usable from Export AND Publish Services
provider.canExportVideo = false
provider.hideSections = { 'exportLocation' }
provider.hidePrintResolution = true

provider.exportPresetFields = {
  { key = 'accessKey', default = '' },
  { key = 'secretKey', default = '' },
  { key = 'bucket', default = '' },
  { key = 'region', default = 'auto' },
  { key = 'endpoint', default = '' },
  { key = 'keyPrefix', default = '' },
  { key = 'publicBaseUrl', default = '' },
  { key = 'useCollectionPrefix', default = false },
  { key = 'uploadThumb', default = false },
  { key = 'thumbSize', default = 800 },
  { key = 'insecureTls', default = not WIN_ENV }, -- macOS LibreSSL curl workaround for R2
  { key = 'title', default = '' },
  { key = 'client', default = '' },
  { key = 'year', default = '' },
}

-- Strings shown in the Publish Services pane.
provider.titleForPublishedCollection = 'Folder'
provider.titleForPublishedCollection_standalone = 'Folder'

function provider.getCollectionBehaviorInfo(publishSettings)
  return {
    defaultCollectionName = 'Published',
    defaultCollectionCanBeDeleted = true,
    canAddCollection = true,
  }
end

---------------------------------------------------------------------------
-- dialog
---------------------------------------------------------------------------

local REQUIRED = {
  { 'accessKey', 'Enter the access key ID.' },
  { 'secretKey', 'Enter the secret access key.' },
  { 'bucket', 'Enter the bucket name.' },
  { 'region', 'Enter the region (use "auto" for Cloudflare R2).' },
}

local function validate(props)
  local message = nil
  for _, req in ipairs(REQUIRED) do
    local value = props[req[1]]
    if value == nil or tostring(value):match('^%s*$') then
      message = req[2]
      break
    end
  end
  props.LR_cantExportBecause = message
end

function provider.startDialog(props)
  for _, req in ipairs(REQUIRED) do
    props:addObserver(req[1], function() validate(props) end)
  end
  validate(props)
end

function provider.sectionsForTopOfDialog(f, props)
  local function row(label, control)
    return f:row {
      f:static_text { title = label, alignment = 'right', width = share 'labelWidth' },
      control,
    }
  end

  return {
    {
      title = 'Amazon S3 / Cloudflare R2',
      synopsis = bind { key = 'bucket', object = props },
      bind_to_object = props,

      row('Access key ID', f:edit_field { value = bind 'accessKey', width_in_chars = 34 }),
      row('Secret access key', f:password_field { value = bind 'secretKey', width_in_chars = 34 }),
      row('Bucket', f:edit_field { value = bind 'bucket', width_in_chars = 34 }),
      row('Region', f:edit_field { value = bind 'region', width_in_chars = 14 }),
      row('Custom endpoint', f:edit_field { value = bind 'endpoint', width_in_chars = 34 }),
      row('', f:static_text {
        title = 'R2: https://<ACCOUNT_ID>.r2.cloudflarestorage.com (region "auto"). Leave empty for AWS S3.',
        font = '<system/small>',
      }),
      row('', f:checkbox {
        title = 'Skip TLS certificate verification (macOS curl/LibreSSL workaround for R2)',
        value = bind 'insecureTls',
      }),
    },

    {
      title = 'Object keys',
      synopsis = bind { key = 'keyPrefix', object = props },
      bind_to_object = props,

      row('Key prefix', f:edit_field { value = bind 'keyPrefix', width_in_chars = 34 }),
      row('', f:checkbox {
        title = 'Publish: put each collection in its own sub-folder (collection name)',
        value = bind 'useCollectionPrefix',
      }),
      row('Public base URL', f:edit_field { value = bind 'publicBaseUrl', width_in_chars = 34 }),
      row('', f:static_text {
        title = 'Optional, e.g. https://img.example.com - lets Lightroom link to the published photo.',
        font = '<system/small>',
      }),
    },

    {
      title = 'Thumbnails and metadata',
      synopsis = bind { key = 'uploadThumb', object = props },
      bind_to_object = props,

      row('', f:checkbox { title = 'Also upload a thumbnail (thumbs/ sub-folder)', value = bind 'uploadThumb' }),
      row('Thumbnail size (px)', f:edit_field { value = bind 'thumbSize', width_in_chars = 6, immediate = true }),
      row('Title', f:edit_field { value = bind 'title', width_in_chars = 34 }),
      row('Client', f:edit_field { value = bind 'client', width_in_chars = 34 }),
      row('Year', f:edit_field { value = bind 'year', width_in_chars = 8 }),
      row('', f:static_text {
        title = 'If a title is set, a meta.json file is uploaded next to the photos.',
        font = '<system/small>',
      }),
    },
  }
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function jsonString(s)
  s = tostring(s or '')
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local function slug(name)
  local s = tostring(name or '')
  s = s:gsub('[^%w%-_%.]+', '-')
  s = s:gsub('^%-+', ''):gsub('%-+$', '')
  if s == '' then s = 'collection' end
  return s
end

local function buildPrefix(props, publishedCollection)
  local prefix = S3Upload.normalizePrefix(props.keyPrefix)
  if publishedCollection and props.useCollectionPrefix then
    prefix = prefix .. slug(publishedCollection:getName()) .. '/'
  end
  return prefix
end

---------------------------------------------------------------------------
-- export / publish
---------------------------------------------------------------------------

function provider.processRenderedPhotos(functionContext, exportContext)
  local exportSession = exportContext.exportSession
  local props = exportContext.propertyTable
  local publishedCollection = exportContext.publishedCollection -- nil for a plain export
  local isPublish = publishedCollection ~= nil

  local nPhotos = exportSession:countRenditions()
  local progress = exportContext:configureProgress {
    title = nPhotos > 1
        and string.format('Uploading %d photos to S3', nPhotos)
        or 'Uploading 1 photo to S3',
  }

  local prefix = buildPrefix(props, publishedCollection)
  local failures = {}
  local uploaded = 0

  for i, rendition in exportSession:renditions { stopIfCanceled = true } do
    progress:setPortionComplete((i - 1) / nPhotos)
    if progress:isCanceled() then break end

    local success, pathOrMessage = rendition:waitForRender()
    if progress:isCanceled() then break end

    if success then
      local path = pathOrMessage
      local leaf = LrPathUtils.leafName(path)
      local key = prefix .. leaf

      local ok, message = S3Upload.put(props, path, key)

      if ok and props.uploadThumb then
        local thumb = S3Upload.makeThumb(props, path)
        if thumb then
          local tok, tmsg = S3Upload.put(props, thumb, S3Upload.thumbKey(key), 'image/jpeg')
          if not tok then
            logger:warn('thumbnail upload failed: ' .. tostring(tmsg))
          end
          S3Upload.removeTemp(thumb)
        end
      end

      if ok then
        uploaded = uploaded + 1

        if isPublish then
          -- If the key changed since the last publish (renamed file, new prefix),
          -- remove the old object so the bucket doesn't keep stale copies.
          local oldKey = rendition.publishedPhotoId
          if oldKey and oldKey ~= key then
            S3Upload.delete(props, oldKey)
            S3Upload.delete(props, S3Upload.thumbKey(oldKey))
          end

          rendition:recordPublishedPhotoId(key)
          local url = S3Upload.publicUrl(props, key)
          if url then
            rendition:recordPublishedPhotoUrl(url)
          end
        end
      else
        failures[#failures + 1] = leaf .. ': ' .. tostring(message)
        rendition:uploadFailed(message)
      end

      LrFileUtils.delete(path)
    end
  end

  progress:done()

  -- meta.json (only when a title is set)
  local title = tostring(props.title or '')
  if uploaded > 0 and not title:match('^%s*$') then
    local json = string.format('{"title":%s,"client":%s,"year":%s}\n',
      jsonString(title), jsonString(props.client), jsonString(props.year))
    local ok, message = S3Upload.putString(props, json, prefix .. 'meta.json', 'application/json')
    if not ok then
      logger:warn('meta.json upload failed: ' .. tostring(message))
    end
  end

  -- Publish runs report per-photo failures through Lightroom itself.
  if not isPublish then
    if #failures > 0 then
      LrDialogs.message('Some uploads failed', table.concat(failures, '\n'), 'warning')
    elseif uploaded > 0 then
      LrDialogs.message('Upload complete',
        string.format('Uploaded %d photo(s) to %s/%s', uploaded, tostring(props.bucket), prefix), 'info')
    end
  end
end

---------------------------------------------------------------------------
-- publish: removing photos from a published collection
---------------------------------------------------------------------------

function provider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
  for _, key in ipairs(arrayOfPhotoIds) do
    local ok, message = S3Upload.delete(publishSettings, key)
    if ok then
      -- Best effort; S3/R2 return success even when the thumbnail doesn't exist.
      S3Upload.delete(publishSettings, S3Upload.thumbKey(key))
      deletedCallback(key)
    else
      logger:warn('delete failed: ' .. tostring(message))
      LrDialogs.message('Could not delete from bucket', tostring(message), 'warning')
      break
    end
  end
end

return provider
