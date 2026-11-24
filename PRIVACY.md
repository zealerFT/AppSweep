# Privacy

AppSweep 0.2.0 runs locally. It has no analytics, account system, advertising,
network client, cloud storage, remote diagnostics, or automatic update service.

The application reads installed application metadata and icons, the current
user's supported Library locations, and launch-job metadata to identify
unsupported uninstall scenarios. It inspects file attributes to estimate size;
it does not upload file contents. Only explicitly selected files may be moved
to the system Trash after confirmation.

The application reads macOS Spotlight last-use dates to sort the application
list. Missing dates remain unknown; it does not track browsing activity or record
application launches. Sort order and the successful-cleanup dialog preference
are saved locally in UserDefaults. Neither is sent to a server.

Operation history contains application names and identifiers, timestamps,
original paths, resulting Trash paths and errors. It is retained on the current
Mac under `~/Library/Application Support/<bundle-identifier>/history.json` until
the user removes that local file. Files and paths can be sensitive; review them
before sharing history or screenshots with anyone.

Full Disk Access, when granted in System Settings, is controlled by macOS. The
application does not equate this with administrator privileges and does not
bypass system protections. The user may revoke access in System Settings.

Release signing/notarization scripts contact Apple only when explicitly run by
the developer; these scripts are not shipped as application functionality.

Before public release, the distributor must identify the responsible publisher
and provide their own support/privacy contact. No publisher identity is assumed
by this development project.
