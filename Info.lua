return {
  LrSdkVersion = 6.0,
  LrSdkMinimumVersion = 5.0,

  LrToolkitIdentifier = 'se.peterwestrup.s3upload',
  LrPluginName = 'Upload to Amazon S3',

  -- One provider serves both the Export dialog and the Library > Publish Services pane
  -- (see supportsIncrementalPublish in ExportServiceProvider.lua).
  LrExportServiceProvider = {
    title = 'Amazon S3',
    file = 'ExportServiceProvider.lua',
  },

  VERSION = { major = 1, minor = 1, revision = 0, build = 1 },
}