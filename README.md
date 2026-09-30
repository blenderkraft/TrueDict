# crack_tc.sh

A small Bash script that tries a list of candidate passwords against a single
TrueCrypt (or, optionally, VeraCrypt) container file until one of them opens
it, then tells you which password worked.

## Why this exists

If you have an old TrueCrypt container and a list of passwords you *might*
have used (an old password manager export, a list of variants you remember
typing, etc.), trying them one at a time by hand is slow and tedious. This
script automates that: point it at a volume and a password list, and it does
the trial-and-error for you using `cryptsetup`'s built-in TrueCrypt/VeraCrypt
support.

It is meant for recovering access to **your own** encrypted volumes when
you've forgotten the exact password. Don't point it at a volume you don't
have the right to open.

## How it works

1. Loads the password list, one candidate per line - trimming leading/trailing
   whitespace, dropping blank lines, and removing duplicates.
2. For each candidate password, runs:
   ```
   cryptsetup open --type tcrypt --readonly <volume> <mapping-name>
   ```
   TrueCrypt/VeraCrypt containers don't store which hash algorithm or cipher
   they were encrypted with, so for every password `cryptsetup` internally
   tries several hash algorithms (RIPEMD-160, SHA-512, Whirlpool, and more
   under `--veracrypt`) and cipher chains (AES, Serpent, Twofish, and their
   cascades). Each hash requires a full password-based key derivation
   (PBKDF2), which TrueCrypt/VeraCrypt deliberately make slow to resist
   exactly this kind of brute-forcing - so expect each single attempt to take
   anywhere from a few seconds to 15+ seconds depending on your CPU.
3. If a password succeeds, the script mounts the volume **read-only** to
   confirm it's a genuine match, records the result, and then immediately
   **unmounts and closes it again** - the script never leaves a volume
   mounted when it exits, successful or not.
4. The outcome (success + working password, or failure) is appended to
   `crack_results.txt`. Every individual attempt (but never the passwords
   themselves, aside from the one that ultimately worked) is logged to
   `crack_attempts.log`.

By default only classic TrueCrypt (`tcrypt`) key derivation is tried. Pass
`--veracrypt` to also run a second pass using VeraCrypt-compatible KDFs (which
use far more iterations and is correspondingly much slower) if the first pass
finds nothing.

## Why it needs your sudo password

Opening a TrueCrypt/VeraCrypt container and mounting it both require root:
`cryptsetup open` sets up a device-mapper block device backed by the
container file, and `mount` needs root to attach a filesystem. There's no way
around this - it's how disk encryption works on Linux.

### How it gets your password, and how it's handled

The script asks for your sudo password **once**, up front, via a graphical
`zenity --password` dialog rather than sudo's normal terminal prompt. This is
so the script works the same way whether you launch it from a terminal, a
file manager, or anywhere else without a real controlling terminal attached -
sudo's own prompt can fail with "a terminal is required to read the password"
in those cases.

From there:

- The password is held **only in a local shell variable**, in the script's
  own memory. It is never written to disk, never logged, and never passed as
  a command-line argument to `sudo` or anything else - which matters because
  command-line arguments are visible to every other user on the system via
  `ps aux`.
- Every privileged command feeds the password to `sudo -S` (read password
  from stdin) instead, piped directly in-memory: `printf '%s\n' "$SUDO_PW" |
  sudo -S <command>`.
- Each privileged call also runs `sudo -k` first, which discards any cached
  sudo timestamp beforehand - so every single privileged action is
  authenticated explicitly with the password you gave, rather than
  implicitly trusting an ambient cached credential.
- The variable only lives for the duration of the script's process and dies
  with it; it is not exported, so it never ends up in `/proc/<pid>/environ`
  either.

This is the same level of exposure as typing your password into any
interactive sudo prompt - it's just collected once, through a GUI dialog,
instead of typed repeatedly into a terminal.

## Usage

```
./crack_tc.sh <volume_file> <password_list_file> [--veracrypt]
```

Example, using the sample volume and password list included in this repo:

```
./crack_tc.sh sample_volume.tc sample_passwords.txt
```

Output on success:

```
SUCCESS: sample_volume.tc opened with password 'test' (tcrypt)
```

Output on failure:

```
FAILED: no password in sample_passwords.txt opened sample_volume.tc
```

### Password list format

Plain text, one password per line. Leading/trailing whitespace and duplicate
lines are ignored automatically, so you don't need to clean the list up
first.

## Requirements

- `cryptsetup` built with tcrypt support (most distro packages are).
- `zenity`, and a running graphical session (X11 or Wayland) for the password
  prompt.
- `sudo` access.

On Arch: `sudo pacman -S cryptsetup zenity`
On Debian/Ubuntu: `sudo apt install cryptsetup zenity`

## Companion tool: tcmap.sh

Also included in this repo. Once you already know a volume's password (e.g.
after `crack_tc.sh` finds it, or you just remember it), `tcmap.sh` is a
simpler script for manually mapping/unmounting a volume for actual use - it
mounts read-only, supports `--veracrypt`, and prompts for both the sudo
password and the volume passphrase through the normal (hidden, non-echoing)
terminal prompts, since at that point you're running it interactively
yourself:

```
./tcmap.sh map <volume_file> [mapping_name] [--veracrypt]
./tcmap.sh unmap <mapping_name>
```

Example, using the sample volume from this repo:

```
./tcmap.sh map sample_volume.tc sample
# ... enter your sudo password, then the volume passphrase ('test') when prompted ...
./tcmap.sh unmap sample
```

## Disclaimer

Use this only on volumes you own or otherwise have explicit authorization to
access. This is a password-recovery convenience tool, not a general-purpose
password-cracking tool, and it's only as good as the candidate list you give
it.
