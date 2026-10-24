# LavaPass

A native LavaUI password manager for KeePass `.kdbx` files, built with Swift 6.1+. Encryption,
authentication, KDFs, and KDBX parsing are provided by the pinned BSD-licensed
[KDBXKit 1.3.0](https://github.com/shadone/KDBXKit/tree/v1.3.0) dependency.
The [KDBX specification](https://keepass.info/help/kb/kdbx.html) is public.

```sh
swift run LavaPass
LAVA_CLIENT=1 swift run LavaPass /path/to/passwords.kdbx
```

Open an existing vault, enter its master password and optional key file, and
choose Unlock. New Vault creates a KDBX 4.1 file with the library's Argon2id
default and AES-256 encryption. A new vault never overwrites an existing file.

Groups appear at the left; search matches titles, usernames, URLs, and group
names. New Entry and Edit support title, username, password, URL, notes, and
group. Notes is optional multiline text: it is visible in the entry details,
can be copied without editing, and can be changed in Edit Entry. The generator produces a 24-character password by default; its length
can be adjusted. Save Entry writes immediately. Recycle moves entries into a
reversible Recycle Bin; Edit / Restore moves them back by choosing another
group. Attachments, custom fields, auto-type configuration, and entry history
are retained when standard fields are edited.

## Attachments

The entry details list each attachment's filename and size. **Add File…**
imports a file into the encrypted KDBX vault (up to 128 MiB per new attachment).
**Save As…** exports the original bytes to a new owner-only file; existing
files and the vault itself are never overwritten. **Open** uses the desktop's
default application with a private temporary copy (0600 file in a 0700 directory).
LavaPass removes those temporary copies on vault lock and normal process exit.
Files explicitly exported with Save As remain at the location you chose.

**Remove** asks for confirmation and saves the change immediately. The previous
attachment remains in entry history, and shared binary data used by other
entries is preserved. Add/remove actions also keep the entry's Notes and custom
fields unchanged. Save a new entry before adding attachments; attachment
management is available from its details, outside the editing form. Attachments
in read-only and legacy vaults can still be opened and exported.

Every edit checks whether the encrypted file differs from what was opened,
before and after serialization, and refuses to save when it has changed.
Saves retain the previous encrypted file as `vault.kdbx.bak`, fsync a private
0600 sibling temporary file, and rename it over the destination. Save KDBX 4
Copy creates a new file without replacing the original. There is no cloud
sync or automatic merge with another editor.

KDBX 3 files open read-only. Save KDBX 4 Copy explicitly converts a copy for
editing. If the parser reports fields it cannot preserve, the vault remains
read-only and conversion is disabled. Unsupported ciphers, plugin key providers,
and Windows-account/DPAPI keys cannot be opened by this backend.

## Keyring and locking

Remember master password in desktop keyring is optional and off by default.
Only a successfully verified master password is stored, using libsecret and a
LavaPass-specific schema keyed by the canonical vault path. It is never stored
in AppSettings or passed on a command line. Use Keyring retrieves it; any
additional key file is still required. Forget Remembered Password removes only
LavaPass's item. A running Secret Service provider, such as GNOME Keyring or
KeePassXC's Secret Service integration, is required for these optional actions.
The encrypted vault works without a keyring provider.

Lock releases decrypted vault objects, entry drafts, and unlock key material.
It also locks after five minutes without presses or typing. File pickers run
off the frame loop so they cannot stall locking or clipboard expiry. Copy
Password clears its clipboard value after thirty seconds, on lock, and before
closing from the app controls or Quit, provided the clipboard still contains that value. Another
application's newer clipboard value is left alone. Force-killing a process or the compositor destroying its surface first cannot
reliably clear a compositor-owned clipboard selection. Master-password and entry-password fields use LavaUI's
secure input, which masks text and disables copy, cut, and undo.

The development agent is disabled for real vaults. `--demo` is a separate
mode that generates public test credentials, cannot open a real vault, and
never accesses the desktop keyring. It can use `LAVA_AGENT_PORT` for UI tests:

```sh
LAVA_CLIENT=1 LAVA_AGENT_PORT=19879 swift run LavaPass --demo
```

## Scope and validation

This version handles standard credential fields, groups, Notes, and attachments.
Custom-field editing, TOTP display, auto-type, database rekeying, and sync are
not implemented. Existing values for these features remain in the
KDBX model. Plaintext attachment files are created only on explicit Open or
Save As actions; no plaintext vault export is used.

```sh
swift test --filter LavaPassCoreTests
scripts/test-lavapass-keyring.sh # optional: private GNOME Keyring service
LAVA_KEEPASSXC_CLI=/usr/bin/keepassxc-cli swift test --filter LavaPassCoreTests
```

The tests use public KeePassXC-generated fixtures and cover encrypted saves,
backups, wrong credentials, key files, attachments, custom data, history,
recycling, conflict detection, legacy conversion, optional Notes, and attachment
import/removal/export (including legacy binary pools and shared history). The optional reference
suite verifies both directions against KeePassXC itself.

| Concern | Location |
|---|---|
| KDBX document, encrypted file writes, generator | `Sources/LavaPassCore` |
| Worker queue, locking, clipboard lease, views | `Sources/LavaPassApp` |
| libsecret adapter | `Sources/CLavaPass` |
| Public fixture tests | `Tests/LavaPassCoreTests` |
