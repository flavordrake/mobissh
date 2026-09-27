package com.flavordrake.mobissh.mobissh

import androidx.core.content.FileProvider

/**
 * The self-update FileProvider (#1216 R11). Its own class so the manifest
 * merger keys it separately from any plugin's FileProvider, its own authority
 * (`${applicationId}.updates.fileprovider`), and its paths limited to
 * `cache/updates/` (res/xml/update_paths.xml). Removed from the Play bundle
 * (src/play/AndroidManifest.xml, R13).
 */
class UpdatesFileProvider : FileProvider()
