# Dwn privacy policy

_Last updated: 11 November 2026_

Dwn ([dwn.pxlvzn.in](https://dwn.pxlvzn.in)) is a desktop app for macOS and Windows that downloads videos, music and files. It runs entirely on your computer. Dwn has no servers and no accounts of its own, and its developer never receives your files, your sign-ins or anything about how you use it.

## Google Drive, Dropbox and other cloud accounts

When you connect a cloud account in Dwn's Cloud tab, you sign in on the provider's own page (for example Google's) and grant Dwn access to your files.

- **What Dwn accesses:** the list of your files and folders, the files shared with you (including who shared them), your storage usage and your account's email address. With Google Drive, Dwn asks for access to your Drive files so it can list, download and upload them.
- **What Dwn does with it:** only what you ask. It shows your files in the app, downloads the files and folders you choose to your computer, uploads the files you choose, and creates or deletes folders and files when you tell it to.
- **Where it's stored:** the sign-in token is saved on your computer, in Dwn's settings folder (`~/Library/Application Support/Dwn` on macOS, `%APPDATA%\Dwn` on Windows). Downloaded files go to the folder you choose. Nothing is sent to the developer or to any other party.
- **Who Dwn talks to:** only the provider you signed in to (for example Google's Drive API), directly from your computer, using the open-source [rclone](https://rclone.org) tool bundled with Dwn.
- **No sharing, selling or advertising:** Dwn doesn't transfer your data to anyone, use it for advertising, or use it to train AI models.

Dwn's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

### Removing access

Choose **Remove Account** from the account's ••• menu in Dwn to delete its sign-in from your computer. You can also revoke Dwn's access at any time from your Google account at <https://myaccount.google.com/permissions> (or your Dropbox, OneDrive, Box or pCloud account settings).

## Other network use

To do its job, Dwn also connects to:

- the websites you download from (YouTube, for example), using the links you give it;
- GitHub, to check for and download Dwn updates;
- PyPI, to check for and download updates to yt-dlp, its download library.

If you turn on "Use browser logins", Dwn reads that browser's cookies on your computer to download from sites that need you to be signed in. They're used only for those downloads and never leave your computer except in requests to those sites.

## Analytics

Dwn has no analytics, tracking or crash reporting.

## Contact

Questions or requests: open an issue at <https://github.com/YuvrajxGarg/dwn/issues>.
