// Exact upstream 2.10.0 framework shape. This is custody metadata, not binary
// provenance; SDK source admission must separately verify its pinned archive.
export const sparkleRoot = 'Contents/Frameworks/Sparkle.framework';
export const sparkleLinks = new Map([
  ['Versions/Current', 'B'],
  ...['Autoupdate', 'Headers', 'Modules', 'PrivateHeaders', 'Resources', 'Sparkle', 'Updater.app', 'XPCServices']
    .map(name => [name, `Versions/Current/${name}`]),
].map(([path, target]) => [`${sparkleRoot}/${path}`, target]));
export const sparkleRoles = new Map([
  ['Sparkle', 6], ['Autoupdate', 2], ['Updater.app/Contents/MacOS/Updater', 2],
  ['XPCServices/Downloader.xpc/Contents/MacOS/Downloader', 2],
  ['XPCServices/Installer.xpc/Contents/MacOS/Installer', 2],
].map(([path, type]) => [`${sparkleRoot}/Versions/B/${path}`, type]));
export const sparkleContainers = [
  `${sparkleRoot}/Versions/B/XPCServices/Downloader.xpc`,
  `${sparkleRoot}/Versions/B/XPCServices/Installer.xpc`,
  `${sparkleRoot}/Versions/B/Updater.app`, sparkleRoot,
];
