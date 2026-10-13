# Lightroom S3 / R2 Upload & Publish

A Lightroom Classic plugin that uploads photos to **Amazon S3**, **Cloudflare R2**, or any other S3-compatible storage. It works two ways:

- **Export service** - right-click photos, choose Export, and pick the S3 preset. One-shot upload.
- **Publish service** - a live folder in the Library pane. Drag photos in, click **Publish**, and later edits are detected so you can re-publish them. Photos you remove are deleted from the bucket.

The publish service means your bucket can act as a living photo repository, much like the Flickr or Immich publish services.


![S3 Publisher in Lightroom Library View](https://i.imgur.com/6Z2K4ag.png)

## Features

- Export and Publish Service from the same plugin
- Re-publish detection: edited photos show under *Modified Photos to Re-Publish*
- Removing a photo from a published folder deletes it from the bucket
- Optional thumbnails in a `thumbs/` sub-folder
- Optional `meta.json` (title, client, year) next to the photos
- Optional per-collection sub-folders in the bucket
- Optional public base URL so Lightroom can link to the published photo
- Credentials are passed to curl through a short-lived config file, not on the command line
- Retries on transient network errors, with a log file for troubleshooting

## Requirements

- Lightroom Classic (SDK 5.0 or newer)
- `curl` 7.75 or newer (for `--aws-sigv4`). Current macOS and Windows 10/11 include it.
- Thumbnails: macOS uses the built-in `sips`. Windows needs [ImageMagick](https://imagemagick.org) on the PATH. Without it, uploads still work and thumbnails are skipped.

## Installation

1. Download or clone this repository into a folder named `S3Upload.lrplugin`.
2. In Lightroom Classic, open **File > Plug-in Manager**, click **Add**, and select the `S3Upload.lrplugin` folder.

## Configuration

The same settings are used by both the Export dialog and the Publish Service dialog.

### Amazon S3

| Field | Value |
| --- | --- |
| Access key ID / Secret access key | An IAM user's keys |
| Bucket | Your bucket name |
| Region | For example `us-east-1` |
| Custom endpoint | Leave empty |

The IAM user needs `s3:PutObject` on the bucket, and `s3:DeleteObject` if you want the publish service to remove photos.

### Cloudflare R2

| Field | Value |
| --- | --- |
| Access key ID / Secret access key | An R2 API token (read and write) |
| Bucket | Your bucket name |
| Region | `auto` |
| Custom endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |

### Other settings

| Field | What it does |
| --- | --- |
| Skip TLS certificate verification | Workaround for the macOS curl/LibreSSL problem with R2. On by default on macOS. Untick it if your curl connects to R2 without it. |
| Key prefix | Folder inside the bucket, for example `portfolio/2026/` |
| Put each collection in its own sub-folder | Publish only. Uses the collection name as a sub-folder under the prefix. |
| Public base URL | Optional, for example `https://img.example.com`. Lets Lightroom link to the published photo. |
| Upload a thumbnail | Also uploads a resized JPEG to `thumbs/` |
| Title / Client / Year | If a title is set, a `meta.json` file is uploaded alongside the photos |

## Usage

### Export (one-shot)

1. Right-click one or more photos and choose **Export**.
2. Choose the **Amazon S3** preset (or create one in the Export dialog).
3. Click Export.

### Publish Service (live repository)

1. In the Library pane, click **+** next to **Publish Services** and choose **Amazon S3**.
2. Enter your storage settings and save. A default folder named *Published* is created.
3. Drag photos into the folder and click **Publish**.
4. Edit a published photo later. It moves to **Modified Photos to Re-Publish**. Click **Publish** to overwrite the object in the bucket.
5. Remove a photo from the folder and publish to delete it from the bucket (its thumbnail is removed too).

You can create more folders to publish to different prefixes or sub-folders.

## How objects are named

Each photo is stored as `<key prefix>[<collection>/]<file name>`, where the file name comes from Lightroom's **File Naming** settings. Thumbnails go to `<dir>/thumbs/<name>.jpg`. Lightroom stores the object key as the published photo ID, so if a key changes on re-publish (renamed file, new prefix), the old object is deleted.

Two photos with the same file name in the same folder overwrite each other. Use a File Naming template (custom text, sequence number, or original file name plus a suffix) to keep names unique.

## Troubleshooting

- A log is written to `~/Documents/LrClassicLogs/S3Upload.log`. It never contains your secret key.
- **HTTP 403 / SignatureDoesNotMatch**: check the keys, bucket, region (`auto` for R2) and endpoint.
- **TLS errors on macOS with R2**: tick *Skip TLS certificate verification*.
- **Thumbnails missing on Windows**: install ImageMagick and make sure `magick` is on the PATH.
- **curl: option --aws-sigv4 is unknown**: your curl is older than 7.75. Update your OS or install a newer curl.

## Security notes

- Lightroom stores export and publish settings, including the secret key, in its own preset/catalog data in plain text. Use a bucket-scoped key with the minimum permissions.
- Skipping TLS verification is a convenience workaround. Turn it off if you can.

## Known limitations

- Deleting a published folder in Lightroom does not delete its files from the bucket.
- Video export is not supported.

## Credits

- **Original plugin**: [westruplabs/lightroom-s3-upload](https://github.com/westruplabs/lightroom-s3-upload). This project is a fork of it and builds on its S3 and R2 upload work. Thank you to its author for the foundation.
- **Inspiration**: [bmachek/lrc-immich-plugin](https://github.com/bmachek/lrc-immich-plugin) by Bernhard Machek. Its Immich publish service showed how a storage backend can act as a live Library-pane repository with re-publish detection, which motivated the publish service here. No code was copied from it.

## License

MIT License — free to use, modify, and distribute. Attribution appreciated but not required.

---

Developed by [Brent Saltzman](https://brentsaltzman.com)
