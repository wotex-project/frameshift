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
export const sparkleArchive = Object.freeze({
  version: '2.10.0',
  commit: 'eef1a539a373c1f1a320624b1130fc5de7b2e100',
  bytes: 10_193_895,
  sha256: '17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959',
  url: 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip',
});
