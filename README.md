# Omarchy on Apple Silicon, in UTM

A working setup for running Omarchy as a **daily driver** on an M-series Mac,
inside a [UTM](https://mac.getutm.app/) virtual machine.

The manual's [Mac support](https://github.com/basecamp/omarchy/blob/quattro/manual/44-mac-support.md)
chapter covers bare-metal Intel Macs and notes that M-series is not directly
supported. [Omarchy on…](https://github.com/basecamp/omarchy/blob/quattro/manual/49-omarchy-on.md)
points at Asahi Linux and at Parallels. This guide covers the third route: the
**aarch64 build, virtualised under UTM**, with macOS still running underneath.

Everything below was measured on the machine, not inferred. Where a number
appears, it came from a command whose output is shown.

**Host:** Apple M5 Max, 64 GB, macOS 27 · **Guest:** Omarchy 4.0.3 (aarch64),
Hyprland 0.56.1 · **VM:** UTM 4.7.5, QEMU backend, 8 vCPU / 24 GB / 128 GB disk

---

## Is this the right route for you?

| | Asahi Linux | UTM (this guide) | Parallels |
|---|---|---|---|
| macOS available at the same time | no | **yes** | yes |
| GPU acceleration | native | virgl (limited) | better |
| Effort to set up | high | moderate | moderate |
| Reversible | wipes the disk | **fully** | fully |

Pick UTM if you want Omarchy as your main working environment **without giving up
macOS** — you keep Xcode, iOS development, Secretive, and everything else on the
host. The cost is graphics: see [Electron apps](#4-electron-apps-refuse-to-start)
and [DRM](#8-known-limitations).

You will need the **aarch64 packages**. The official distribution is x86-only;
the aarch64 compatibility fork lives at
[`riverscn/omarchy-aarch64`](https://github.com/riverscn/omarchy-aarch64). Note
that fork is explicitly transitional — it tracks upstream and is intended to be
archived once the architecture-neutral runtime hooks land upstream. Keep your
customisation in `~/.config` and you will survive that transition.

---

## Getting the VM

**UTM 4.7.5 or newer**, from [getutm.app](https://mac.getutm.app/) or the
[project's releases](https://github.com/utmapp/UTM/releases). The `v5.0.x` builds
listed there are pre-releases; 4.7.5 is the current stable and is what this guide
was written against.

Rather than installing Arch by hand, take the prebuilt aarch64 image:

```bash
/bin/bash -o pipefail -c 'curl -fsSL https://github.com/riverscn/omarchy-aarch64-image/releases/latest/download/install-Omarchy-virt.command | /bin/bash -s -- "$HOME/UTM"'
```

That pulls from
[`riverscn/omarchy-aarch64-image`](https://github.com/riverscn/omarchy-aarch64-image)
(currently `v4.0.3-virt.1`) and unpacks `Omarchy-virt.utm` into `~/UTM`. It is
about **3.7 GB**, split across two parts. If you would rather not pipe a release
asset straight into bash — reasonable — the release also ships
`Omarchy-virt.utm.zip.sha256`, `image-provenance.txt` and an
`image-package-inventory.zip`, so you can download, verify and unpack by hand.

### Exclude the image from Time Machine straight away

A multi-gigabyte disk image is rewritten constantly, so Time Machine will copy
the whole thing on every backup:

```bash
tmutil addexclusion ~/UTM/Omarchy-virt.utm
```

Do it before your first backup runs. Two consequences follow: the image is now
protected by nothing, so you want a backup running *inside* the guest (see
[Backups](#9-backups)); and the exclusion does **not** stop APFS local snapshots
pinning the image's freed blocks (see
[Free space has three layers](#10-free-space-has-three-layers)).

---

## 1. The keyboard is the hard part

Budget most of your setup time here. Omarchy binds **140 of its 182 default
shortcuts** to SUPER, and a Mac keyboard has no Super key — so every one of them
has to come from somewhere, on a keyboard whose modifiers the host is also
using.

### Make left Option into SUPER

In `~/.config/hypr/input.lua`:

```lua
hl.config({
  input = {
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
```

`kb_options` **replaces** Omarchy's defaults rather than appending to them, so
carry over anything you still want (here, Compose on Caps Lock).

Verify against the compiled keymap rather than trusting the setting:

```
left Option   (LALT) -> Super_L      <- this is SUPER
left Command  (LWIN) -> Alt_L
right Option  (RALT) -> Alt_R
right Command (RWIN) -> Super_R      <- a second SUPER
Caps Lock     (CAPS) -> Multi_key
```

Note `altwin:swap_lalt_lwin` swaps only the **left** pair. Right Option was
always `Alt_R`.

### Then discover that most chords never arrive

UTM's cursor capture is the problem, and it is worse than the settings suggest.
The preference offers "Command+Option" or "Ctrl+Option" for capture/release —
but it is **additive, not exclusive**. Both chords capture, whichever you pick.
There is no setting that frees them.

And separately, macOS swallows a letter pressed with **two Option keys**, because
Option is its dead-key modifier.

Traced from raw scancodes on `/dev/input/event3`:

```
left Option  + F                  -> DOWN 56,  DOWN 33 F         works
right Option + F                  -> DOWN 100, DOWN 33 F         works
left Option + right Option + F    -> DOWN 56, DOWN 100, NO F     letter lost
left Command + right Command + F  -> DOWN 125, DOWN 126, DOWN 33 works
```

The practical result, once SUPER is left Option:

| Omarchy chord | Reaches the guest? |
|---|---|
| `SUPER + X` | **yes** |
| `SUPER + SHIFT + X` | **yes** |
| `SUPER + CTRL + X` | no — Option+Ctrl captures the cursor |
| `SUPER + ALT + X` | no — by every available route |

So **plan on two usable modifier spaces**, and rehome the shortcuts you actually
use into them. In `~/.config/hypr/bindings.lua`:

```lua
-- Unbind before rebinding, or the old binding stays live.
hl.unbind("SUPER + ALT + SPACE")
o.bind("SUPER + D", "Apps menu", "omarchy-menu toggle apps")
```

A worked example — window groups ("tabs"), whose stock bindings are *all* on
dead chords:

```lua
hl.unbind("SUPER + ALT + TAB")
hl.unbind("SUPER + ALT + SHIFT + TAB")
hl.unbind("SUPER + CTRL + LEFT")
hl.unbind("SUPER + CTRL + RIGHT")
o.bind("SUPER + code:34", "Previous window in group", hl.dsp.group.prev())  -- [
o.bind("SUPER + code:35", "Next window in group",     hl.dsp.group.next())  -- ]
```

Brackets keep the macOS `Cmd+[` / `Cmd+]` tab muscle memory.

### Two traps when hunting for free keys

**The number row is not free.** Omarchy binds digits by keycode
(`SUPER + code:10..19` are the workspaces), and `hyprctl binds` reports
keycode-bound entries with an **empty `key` and `keycode: 0`** — so they look
unbound when they are not. Cross-check the source:

```bash
grep -rhoE 'o\.bind\("SUPER \+ [^"]+"' /usr/share/omarchy/default/hypr/bindings/ \
  | sed 's/o\.bind("//; s/"$//' | sort -u
```

**Caps Lock cannot be a modifier.** `caps:super` looks tempting and does not
work: macOS treats Caps Lock as a *locking* key — key-down on press, key-up only
on the next press — and UTM forwards that faithfully, so the guest sees SUPER
held down indefinitely.

### When one shortcut misbehaves and its neighbours are fine

Suspect a **host-side global hotkey** before digging through guest input layers.
The signature in an `/dev/input` trace is unmistakable: **the modifiers arrive,
the letter never does.** This happened twice here — the ChatGPT desktop app's
"Pets" feature bound to `⌥Space`, and a personal macOS script on `⌥⇧V`. Compare
against a control chord of the same shape to confirm.

```bash
# needs root once; revoke afterwards
pkexec setfacl -m u:$USER:r /dev/input/event3
# read 24-byte struct input_event: struct.unpack('llHHi', ...), type==1 is EV_KEY
pkexec setfacl -x u:$USER /dev/input/event3
```

### Moving windows around the tiling

With SUPER on left Option, these stock Omarchy bindings all survive UTM and need
no rehoming:

| Keys | What it does |
|---|---|
| `SUPER + ←/→/↑/↓` | move **focus** to the neighbouring window |
| `SUPER + SHIFT + ←/→/↑/↓` | **swap** the focused window with its neighbour in that direction |
| `SUPER + J` | **toggle the split**: side by side ↔ stacked |
| `SUPER + -` / `SUPER + =` | resize horizontally (100 px steps) |
| `SUPER + SHIFT + -` / `=` | resize vertically |
| `SUPER + left-drag` | **move** a window with the mouse |
| `SUPER + right-drag` | resize with the mouse |
| `SUPER + SHIFT + 1…9` | send the focused window to that workspace |
| `SUPER + T` | toggle floating ↔ tiled |

The 25 px and 300 px resize variants (`SUPER + ALT` / `SUPER + CTRL` + `-`/`=`)
are on dead chords here.

**Two windows side by side:** if they are stacked, focus either one and press
`SUPER + J`. If the window you want is on another workspace, go there and send it
over with `SUPER + SHIFT + <number>`; it tiles in beside what is already there.

**Moving a small window elsewhere:** `SUPER + SHIFT + arrow` swaps it with its
neighbour; repeat to walk it across. A swap trades *places* but keeps each slot's
size, so the small window takes over the larger slot. To put a window anywhere
at all rather than trade places, hold `SUPER` and left-drag it onto the window it
should sit next to; where you drop it decides which window gets split.

---

## 2. Display scaling and fonts

**Do not trust automatic scaling.** QEMU's virtual display reports a junk EDID
physical size, so Hyprland's `auto` computes a nonsense DPI — here it silently
flipped to 1.5 on reload. Pin it in `~/.config/hypr/monitors.lua`:

```lua
omarchy_monitor_scale = 1
omarchy_gdk_scale     = 1
```

**Never set scale 2** unless you have genuinely measured the DPI. A 5120×1440
ultrawide at 1:1 is about 109 DPI — normal desktop density, not HiDPI. Compute it
from the panel's real size, not from anything the VM reports.

With scaling correct, text quality is a fontconfig problem. In
`~/.config/fontconfig/fonts.conf`, use full hinting and subpixel rendering:

```xml
<match target="font">
  <edit name="hintstyle" mode="assign"><const>hintfull</const></edit>
  <edit name="rgba"      mode="assign"><const>rgb</const></edit>
  <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
</match>
```

Preserve any monospace mapping Omarchy already set. One trap: **`--` is illegal
inside an XML comment**, and a malformed `fonts.conf` fails *silently* — settings
revert to defaults with no error. Validate:

```bash
python3 -c "import xml.dom.minidom;xml.dom.minidom.parse('$HOME/.config/fontconfig/fonts.conf')"
fc-match -v monospace | grep -E 'hintstyle|rgba|lcdfilter'
```

### Moving the VM window between a 1x and a Retina screen

A pinned scale is right for one screen. Drag the UTM window from a 1x desktop
monitor to the MacBook's Retina panel and everything in the VM is half size;
drag it back and it is double. Two things make this awkward to automate:

- **The VM cannot see which screen it is on.** The virtual EDID is the same
  everywhere. The guest's pixel width does not tell you either, because a
  windowed VM on a 5120-wide monitor is narrower than a full-screen one on a
  3024-wide laptop.
- **Moving the window changes nothing in the guest.** UTM keeps the guest at
  the same pixel resolution and shows those pixels 1:1 on the new screen, so
  no resolution event fires. Only a resize produces one.

What works is asking macOS. This helper reports the backing scale factor of
the screen that holds the UTM window, from the window list, so it needs no
Accessibility permission and answers in a tenth of a second. Build it on the
Mac with `swiftc -O -o ~/bin/utm-screen-scale utm-screen-scale.swift`:

```swift
// Print the backing scale factor (1 or 2) of the screen that holds UTM's
// main window, so the Omarchy VM can pick its Hyprland scale from the real
// display instead of guessing from the window size. Uses the window list
// (no Accessibility permission needed for bounds). Output: "<scale> <WxH>".
import AppKit

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fputs("no window list\n", stderr); exit(2)
}
var best: CGRect? = nil
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "UTM",
          let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    if r.width < 200 || r.height < 200 { continue }           // skip palettes/toolbars
    if best == nil || r.width * r.height > best!.width * best!.height { best = r }
}
guard let win = best else { fputs("no UTM window\n", stderr); exit(3) }
// Window bounds are in global top-left coordinates; NSScreen frames are
// bottom-left with the primary screen's origin at 0,0.
let primaryH = NSScreen.screens.first?.frame.height ?? 0
let cx = win.midX, cy = primaryH - win.midY
var chosen = NSScreen.main
for s in NSScreen.screens where s.frame.contains(CGPoint(x: cx, y: cy)) { chosen = s }
guard let screen = chosen else { fputs("no screen\n", stderr); exit(4) }
let px = screen.frame.size.applying(CGAffineTransform(scaleX: screen.backingScaleFactor, y: screen.backingScaleFactor))
print("\(Int(screen.backingScaleFactor)) \(Int(px.width))x\(Int(px.height))")
```

On the VM side, a script sets the Hyprland scale from that answer. Two
details matter under Omarchy's Lua config: `hyprctl keyword` is gone, use
`hyprctl eval`, and never pass `mode = "preferred"` for the virtual output,
which is the EDID's 1280×800 fallback and collapses the desktop. Re-use the
live mode instead:

```bash
mon=$(hyprctl -j monitors | jq -c '.[] | select(.name == "Virtual-1")')
w=$(jq -r .width <<<"$mon"); h=$(jq -r .height <<<"$mon"); hz=$(jq -r '.refreshRate | floor' <<<"$mon")
read -r want _ < <(ssh -o BatchMode=yes mac '~/bin/utm-screen-scale')   # 1 or 2
hyprctl eval "hl.monitor({ output = \"Virtual-1\", mode = \"${w}x${h}@${hz}\", position = \"0x0\", scale = $want })"
```

Then run it from two triggers. A systemd user **path unit** on
`~/.local/state/spice-guest-tools/display.state` covers resizes, since the
SPICE display bridge records every new layout there (it re-applies layouts
with whatever scale is already live, so it never changes the scale itself).
A small **watch service** covers moves: it keeps one ssh session to the Mac
running the helper once a second and applies the scale when the answer
changes. With a standing agent tunnel that is one key signature per
connection. In `monitors.lua`, keep the pin as a boot-time fallback.

The Omarchy menu's font-size and scale settings are the wrong lever for this:
they change the look on every screen, and you would be flipping them by hand
on each move.

---

## 3. The pointer: scrolling and focus

### Scrolling direction

There is no touchpad in the VM — the host's trackpad arrives as a **mouse**. So
the touchpad natural-scroll setting is inert. Set it on input instead:

```lua
hl.config({ input = { natural_scroll = true } })
```

### Typing goes to the wrong pane when you come back to the VM

With two panes side by side, switch to a Mac app and back, start typing — and
the keys land in the *other* pane for a few seconds. It is most noticeable when
that pane is lazygit, where letters are commands, or a web app.

It is not the app. Logged from Hyprland's event socket alongside the pointer
position: when the VM regains input, **UTM teleports the pointer** to wherever
it clamps the Mac pointer, typically a screen edge:

```
17:48:22.517  cursor 214,1120        over the left pane
17:48:22.556  FOCUS -> right pane
17:48:22.624  cursor 2155,1050       right edge, no movement in between
     ... focus stays there, while you type, until the mouse moves ...
```

Omarchy's default `follow_mouse = 1` moves keyboard focus to whatever is under
the pointer, so the teleport hands your keyboard to that pane. It happens with a
plain shell too; you just don't notice keys arriving in an idle prompt.

Make focus follow **clicks** instead, in `~/.config/hypr/input.lua`:

```lua
hl.config({ input = { follow_mouse = 2 } })
```

Hovering still scrolls the pane under the pointer; changing keyboard focus now
takes a click (or `SUPER+arrows`). In a VM, where the host keeps moving the
pointer behind your back, that is the behaviour you want.

To diagnose a focus problem like this yourself, watch focus changes and the
pointer together:

```bash
socat -u UNIX-CONNECT:"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" - \
  | grep --line-buffered activewindowv2 &
while sleep 0.1; do hyprctl cursorpos; done
```

---

## 4. Electron apps refuse to start

virgl does not give Electron the OpenGL ES 3.0 it wants, so Chromium-based apps
fail to open a window. **1Password is the confusing one** — its tray icon
appears and works, the main window never does, which looks like a 1Password bug
rather than a graphics one.

The fix is to force ANGLE onto Vulkan:

```
--use-angle=vulkan
```

Add it to each app's `.desktop` Exec line or its `*-flags.conf`. Package updates
overwrite those, so make it survive with a pacman hook in
`/etc/pacman.d/hooks/` that reapplies the flag after an upgrade.

---

## 5. Sharing folders from macOS

UTM's GUI exposes exactly **one** shared directory. For several specific folders,
add raw 9p exports as QEMU arguments (VM Settings → QEMU → Additional Arguments):

```
-fsdev local,id=fsdev_projects,path=/Users/you/projects,security_model=mapped-xattr
-device virtio-9p-pci,fsdev=fsdev_projects,mount_tag=projects
```

Mount them in the guest, then layer `bindfs` to remap macOS's uid/gid
(`501:20`) onto yours:

```
projects  /mnt/projects  9p  trans=virtio,version=9p2000.L,rw,_netdev,nofail,auto  0 0
/mnt/projects  /home/you/Mac/projects  fuse.bindfs  map=501/1000:@20/@1000,allow_other,default_permissions,nosuid,nodev,nofail,_netdev,x-systemd.requires=/mnt/projects  0 0
```

> **Warning.** UTM is sandboxed. The GUI share carries a **security-scoped
> bookmark**, and that bookmark is very likely what grants QEMU access to your
> custom `-fsdev` paths too — UTM cannot create bookmarks for paths it does not
> know about. Removing the GUI share may therefore break every custom export.
> Keep it, and disable unwanted mounts guest-side in `/etc/fstab` instead.

Also **back up `config.plist` before editing VM settings in the GUI** — it
rewrites the file, and your `QEMU/AdditionalArguments` live there.

```bash
cp -p ~/UTM/YourVM.utm/config.plist ~/UTM/YourVM.utm/config.plist.bak
```

---

## 6. Do not run git from the shared folders

This is the single biggest performance trap, and it is easy to misdiagnose.
Same repository, `git status --porcelain`:

| Where | Time |
|---|---|
| macOS, local APFS | **0.03 s** |
| Guest, local disk (a clone) | **0.128 s** |
| Guest, raw 9p | **38 s** |
| Guest, bindfs over 9p | **>280 s** (timed out) |

It is **not** repo size (99 MB of objects, 3,274 tracked files), **not** the
untracked walk (`status.showUntrackedFiles=no` changed nothing), and **not**
bulk data — pruning 50 GB of logs moved the time not at all, because the file
*count* barely changed.

It is **per-file latency**: roughly 12 ms per file over raw 9p, ~85 ms through
bindfs. git must `stat` every tracked file, so cost scales with file count.
bindfs alone costs about **7×**, because every syscall goes
userspace → FUSE → 9p → host.

**Clone into the VM's own disk and work there**, syncing through your git remote.
Bulk sequential I/O over 9p is fine — 1.59 GB streamed in 11 s — so the shares
remain good for moving files. They are simply unusable for metadata-heavy work.

A corollary worth knowing: your shell prompt does this too. Starship's
`git_status` module shells out to `git`, so in a shared folder it times out on
every prompt and prints warnings. `export STARSHIP_LOG=error` silences them while
keeping the branch name, which Starship reads natively.

---

## 7. Sizing the VM

A playspace and a workspace need very different allocations. What mattered here:

- **RAM** — count what your containers actually reserve. One `redis` capped at
  4 GB across two project checkouts was the driver, not the database everyone
  assumes. 24 GB comfortably ran seven services twice over plus editors.
- **CPU** — 8 vCPU on an 18-core host. Past that you fight QEMU's vCPU threads.
- **Disk** — qcow2 is sparse, so an over-provisioned disk costs nothing until
  used, and growing it later means another shutdown. Be generous once.

### Growing the root disk

UTM labels drive resizing as a beta feature, and afterwards it looks as though it
failed, because `df` in the guest does not change. It did work: the virtual device
grows (here `vda` became 512 GB) but the partition and filesystem do not follow.
Claim the space online, no reboot needed:

```bash
lsblk /dev/vda                        # device larger than the partition = resize took
sudo parted /dev/vda resizepart 2 100%
sudo btrfs filesystem resize max /
```

### Better: give Docker its own NVMe disk

If Docker is what fills the disk, don't grow root. Add a second drive in UTM
(VM Settings -> New drive) and move `/var/lib/docker` onto it. Pick the **NVMe**
interface. Measured with `fio` against two qcow2 files on the same APFS SSD
(direct I/O, 4 GiB file):

| | VirtIO | NVMe | |
|---|---|---|---|
| sequential write, 1M | 2,827 MB/s | 4,328 MB/s | 1.5x |
| sequential read, 1M | 2,852 MB/s | 5,295 MB/s | 1.9x |
| random write, 4k QD32 | 21,040 IOPS | 83,250 IOPS | **4.0x** |
| random read, 4k QD32 | 38,497 IOPS | 97,543 IOPS | **2.5x** |

p99 latency was lower on NVMe throughout (889 vs 2,769 us on random writes).
Random 4k I/O at depth is exactly what a database does. One caveat: the two
filesystems differed. The VirtIO side was btrfs, tested in a `chattr +C`
directory, because btrfs quietly falls back to *buffered* I/O on compressed files
even under `O_DIRECT`; the NVMe side was ext4. On a no-CoW direct-I/O path that
cannot explain a 4x gap, so the interface is the dominant variable. Also note the
guest sees the VirtIO disk as `rotational=1`.

The prebuilt image's root drive is VirtIO. Switching an existing root drive's
interface renames the device and was not tested here, so use NVMe for new drives.

Format it **ext4**, not btrfs: Docker volumes are typically database files, and
btrfs copy-on-write fragments badly under database random writes. Nothing on this
disk wants snapshots.

Move Docker with two copies, so the outage lasts only as long as the second one:

```bash
sudo mkfs.ext4 -L docker-data /dev/nvme0n1
sudo mkdir -p /mnt/docker-new && sudo mount /dev/nvme0n1 /mnt/docker-new

# 1. Bulk copy while Docker keeps running.  -H is essential: overlay2 is built on hardlinks.
sudo rsync -aHAXx --numeric-ids /var/lib/docker/ /mnt/docker-new/

# 2. Stop everything, then copy only what changed.
docker stop $(docker ps -q)
sudo systemctl stop docker.service docker.socket containerd.service
sudo rsync -aHAXx --numeric-ids --delete /var/lib/docker/ /mnt/docker-new/

# 3. Verify by file count and a dry run, not by du (btrfs and ext4 account differently).
sudo find /var/lib/docker -xdev | wc -l; sudo find /mnt/docker-new -xdev | wc -l
sudo rsync -aHAXxn --numeric-ids --delete --stats /var/lib/docker/ /mnt/docker-new/ | grep transferred

# 4. Swap. umount -R clears leftover container overlay mounts (see below).
sudo umount /mnt/docker-new
sudo umount -R /var/lib/docker 2>/dev/null
sudo mv /var/lib/docker /var/lib/docker.old && sudo mkdir /var/lib/docker
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1)  /var/lib/docker  ext4  defaults,noatime  0 2" \
  | sudo tee -a /etc/fstab
sudo mount /var/lib/docker && sudo systemctl start docker.socket
docker volume ls | wc -l

# 5. Only once your stacks run from the new disk:
sudo rm -rf /var/lib/docker.old
```

Things that go wrong:

- **"target is busy" with nothing holding it.** Containers set to
  `restart: unless-stopped` come straight back when the daemon starts,
  `containerd.service` is a separate unit, and a stopped daemon can leave
  orphaned overlay mounts under `/var/lib/docker/rootfs/overlayfs/`. `fuser`
  then shows only the kernel. `findmnt -R /var/lib/docker` reveals them, and
  `umount -R` clears them.
- **Mounting twice stacks the mount.** One `umount` then peels off only the top
  layer. Check with `findmnt -n /var/lib/docker` until it is empty.
- **`sudo rm -rf /root-only-dir/*` silently does nothing.** Your unprivileged
  shell expands the glob, cannot read the directory, and `rm -f` deletes a file
  literally named `*`. Remove the directory itself.
- **The new disk does not TRIM by default.** Turn on `fstrim.timer`, or its qcow2
  can only grow; see [Free space has three layers](#10-free-space-has-three-layers).
- Stacks you stopped stay stopped. Bring them back with `docker compose up -d`.

If you only have one disk, the fallback is to make `/var/lib/docker` its own btrfs
subvolume before pulling images, so snapper's root snapshots don't capture the
image store and pin deleted layers. Do it while the directory is still empty.

Docker itself needs nothing special — it runs natively on aarch64, and in
practice the images you want already publish arm64 manifests. Check before
assuming:

```bash
docker manifest inspect <image> | jq -r '.manifests[].platform.architecture'
```

---

## 8. Known limitations

- **No Widevine for aarch64 Linux.** Netflix and other DRM video will not play in
  the guest. Nothing to configure; use the host. (Spotify's web player does work.)
- **GPU acceleration is limited.** virgl covers the desktop well; see
  [Electron apps](#4-electron-apps-refuse-to-start) for the main casualty.
- **Two modifier spaces**, as above — plan your keymap around it.
- **Shared folders are slow for metadata**, as above.
- **No mDNS in the guest.** `.local` names do not resolve. If your network has an
  internal zone, route just that zone via systemd-resolved:

  ```
  [Resolve]
  DNS=192.168.1.1
  Domains=~internal
  ```

  The leading `~` makes it a routing domain, so the whole zone resolves without
  per-host configuration.

---

## 9. Backups

The VM disk image is a single large file that most host backup tools skip or
handle badly — and if you exclude it from Time Machine, it is unprotected.
Run a backup **inside** the guest, to somewhere off the machine:

```bash
restic backup --exclude-caches --one-file-system /home/you /etc
```

`--one-file-system` is load-bearing: it stops restic descending into the mounted
Mac shares. Without it you will quietly copy your entire host home directory to
your backup target.

Excluding the image from Time Machine has a side effect on host disk space that
surprises people; see the next section.

---

## 10. Free space has three layers

The guest's disks are qcow2 files on your Mac's APFS volume, so "how much space
is free" has three different answers, and they disagree in ways that will
eventually bite you.

### Layer 1 — the guest frees space, the qcow2 does not shrink

Deleting files or pruning Docker inside the guest frees blocks *in the guest's
filesystem*. The qcow2 file on the Mac stays the same size until those blocks are
**TRIMmed** through to it. The virtio disks here accept discard, and it works:

```bash
sudo fstrim -v /          # measured: root qcow2 went 126 GB -> 22 GB on the host
```

Omarchy mounts its root btrfs with `discard=async`, so root mostly takes care of
itself. **Any disk you add does not** — an ext4 disk for Docker, say, has no
discard option by default, and its qcow2 can then only ever grow. Turn on the
weekly timer, which covers every mounted filesystem:

```bash
sudo systemctl enable --now fstrim.timer
```

On the host, compare apparent and allocated size to see what a qcow2 actually
costs — a virtual disk resized to 512 GB still only occupies what the guest has
written:

```bash
ls -lh ~/UTM/*.utm/Data/*.qcow2    # apparent
du -h  ~/UTM/*.utm/Data/*.qcow2    # actually allocated
```

### Layer 2 — the host frees blocks, local snapshots keep them

An **APFS local snapshot is block-level and whole-volume**; it is not file-aware
and cannot skip anything. Time Machine *exclusions* are applied later, when the
snapshot is copied to the backup destination. So excluding your VM image saves
backup space and time, but does **not** stop local snapshots pinning the blocks
the image just released. Space freed inside the guest can take ~24 hours to
appear on the host, as snapshots expire.

If you need it now, and your last real backup is recent:

```bash
tmutil latestbackup
sudo tmutil thinlocalsnapshots / 500000000000 4    # ask for up to 500 GB back
```

That removes only the *local* snapshots, the hourly safety net between backups.
Your backups on the destination are untouched. In one case here it returned about
600 GB.

### Layer 3 — Finder and `df` disagree

Finder counts **purgeable** space as free: local snapshots, iCloud files it could
evict, caches. `df` counts only blocks that are free right now. Measured at the
same moment on the same volume:

```
df (actually free):                 57 GB
Finder (includes purgeable):      1107 GB
```

Finder's figure is also an **estimate**, recomputed in the background. It swung
from 1.65 TB to 701 GB within a minute while `df` held steady at 653 GB.

macOS frees purgeable space *reactively*, when something asks for room. Most apps
never notice. A VM writing a large database sync into a qcow2 is a fast, sustained
writer that can outrun the purge, and hit a full disk while Finder still shows
hundreds of gigabytes available. **For anything the VM does, trust `df`:**

```bash
df -h /System/Volumes/Data
```

---

## 11. Audio that drops out or crackles

Two separate faults, with separate fixes. Both showed up as "YouTube stutters in
the guest but plays cleanly on the Mac".

### Dropouts of about a second: move audio off SPICE

By default UTM carries the guest's sound over SPICE, the same connection that
carries the display. During video the audio arrives late and whole chunks are
dropped. Check which backend the running VM uses, on the host:

```bash
ps -o args= -p "$(pgrep -f QEMULauncher)" | tr ' ' '\n' | grep -A1 audiodev
# -audiodev
# spice,id=audio0          <- the default
```

Fix: **UTM → Settings → Sound Backend → CoreAudio** (the app's settings, not the
VM's), then restart the VM. Keep the emulated card on Intel HD Audio: the
aarch64 kernel is built without `CONFIG_SND_VIRTIO`, so with virtio-sound the
guest finds no sound card at all and PipeWire falls back to a "Dummy" output.

### Static-like blips while video plays: raise the PipeWire quantum

With the dropouts gone, video still crackled, in the browser and in mpv, while
audio-only playback of the same file was clean. The guest's sound card was
underrunning: PipeWire hands it 1024 frames (21 ms) at a time, and that is not
enough margin when software video decoding keeps the vCPUs busy. PipeWire counts
every underrun in the `ERR` column of `pw-top`:

```bash
pw-top -b -n 2 | grep alsa_output      # run before and after ~20 s of video
```

| Quantum | Underruns during video |
|---|---|
| 1024 frames (21 ms, the default) | 12 in 12 s |
| 2048 frames (42 ms) | 0 in 20 s |
| 4096, 8192 | 0 in 20 s each |

You can try a size live, without restarting anything (`0` puts it back):

```bash
pw-metadata -n settings 0 clock.force-quantum 2048
```

To make it permanent, create `~/.config/pipewire/pipewire.conf.d/10-vm-quantum.conf`:

```
context.properties = {
    default.clock.quantum     = 2048
    default.clock.min-quantum = 2048
    default.clock.max-quantum = 8192
    vm.overrides = {
        default.clock.min-quantum = 2048
    }
}
```

The `vm.overrides` block is not optional. PipeWire detects that it is running in
a VM and applies its own `vm.overrides` (minimum quantum 1024) on top of the
normal properties, so without it the minimum silently stays at 1024. Then:

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
pw-metadata -n settings 0 | grep quantum      # expect 2048 / 2048 / 8192
```

Players compensate for the extra 21 ms, so lip-sync is unaffected.

**A trap when diagnosing this:** recording the output to inspect it
(`parecord -d <sink>.monitor`) makes PipeWire run with larger buffers, and the
blips disappear for as long as the recorder is attached. Count `ERR` in `pw-top`
instead, and compare by ear with nothing recording.

---

## Credits

Written after migrating a working development environment onto this setup.
Corrections and additions welcome.
