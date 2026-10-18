# How to Install DropWheel

DropWheel takes about 5 minutes to set up and is free. You download one file, drag it into a folder, and
tell your Mac once that it's OK to open.

## Before you start: check your Mac

DropWheel only works on newer Macs. Check yours first, it takes 30 seconds.

1. Click the **Apple logo** in the top-left corner of your screen.
2. Click **About This Mac**.
3. Look at the window that opens:

| Look for | You need | If it doesn't match |
| --- | --- | --- |
| **Chip** | Apple M1, M2, M3, M4 or newer | It says "Processor … Intel": DropWheel won't run on this Mac yet |
| **macOS** | Version **15** or a higher number | Update first: Apple logo → System Settings → General → Software Update |

Both match? Great, carry on.

## Step 1: Download it

1. Open this link in Safari or Chrome: <https://github.com/Mosabhavi/DropWheel/releases/latest>
2. Scroll down to the section called **Assets**.
3. Click **DropWheel-1.0.0.zip**. Don't click the files called "Source code": those are for programmers.
4. Wait a few seconds for the download to finish. It's small, about 1.5 MB.

You don't need a GitHub account, and you don't need to sign in.

## Step 2: Put it in your Applications folder

1. Open **Finder**. It's the blue smiley face at the left of your Dock.
2. In the left sidebar, click **Downloads**.
3. Find the downloaded file:
   - If you see an app called **DropWheel** (a colorful wheel icon), go to the next step.
   - If you only see **DropWheel-1.0.0.zip**, double-click it. The DropWheel app appears next to it.
4. Drag the **DropWheel** app onto **Applications** in the left sidebar, and let go.

You can now delete the .zip file. You don't need it anymore.

## Step 3: Open it the first time

Your Mac will block DropWheel the first time. **This is normal.** DropWheel is free and isn't registered
with Apple (registering costs money), so macOS asks you to confirm once. You only do this one time.

1. Open **Applications** in Finder and double-click **DropWheel**.
2. A message says something like **"DropWheel" Not Opened** or "Apple could not verify…".
   - Click **Done**.
   - **Do not** click "Move to Trash".
3. Click the **Apple logo** (top-left) → **System Settings**.
4. In the left sidebar, click **Privacy & Security**.
5. Scroll down on the right side until you see **"DropWheel" was blocked…**
6. Click **Open Anyway** next to it.
7. Confirm with your Mac password or Touch ID, then click **Open Anyway** again.

A welcome message appears: click **OK**. DropWheel is now running.

**Where is it?** Look at the **top-right of your screen**, in the menu bar next to the clock and Wi-Fi
icons. You'll see a small circle icon (◎). That's DropWheel. There's no window and no Dock icon; it waits
quietly in the background.

## Step 4: Use it

Try it on any photo:

1. Open a Finder window with a photo in it.
2. **Click and hold** on the photo, and start moving the mouse a little, as if you're dragging it somewhere.
3. While you're still holding, **press and hold the Shift key** (⇧, above Control on the left of your
   keyboard).
4. A wheel of options pops up around your mouse.
5. Move onto **JPG** (it turns red) and **let go of the mouse**.
6. A message at the bottom of the screen says **Saved…**. The new copy is right next to your original photo.

The two wheels:

| To | Hold while dragging | You get |
| --- | --- | --- |
| Change the file type | **Shift** | JPG, PNG, PDF, MP3, MP4… |
| Edit, crop, shrink, trim… | **Option + Shift** (Option is the ⌥ key) | Compress, Crop, Redact, Trim, Metadata… |

Good to know:

- **Changed your mind?** Drop on the middle of the wheel, or anywhere outside it. Nothing happens.
- **Your original is never changed.** DropWheel always makes a new copy beside it.
- **Several files at once?** Select them all, then drag them together.
- **Some tools open a small window**, for example Crop or Trim. Adjust, then click **Apply**.
- **Prefer the Command key (⌘) instead of Shift?** Click the ◎ icon in the menu bar → **Trigger Key** →
  **Command**.
- **Start it automatically** when your Mac turns on: ◎ icon → **Open at Login**.
- Nothing is uploaded. Everything happens on your own Mac.

## Something went wrong?

| Problem | Fix |
| --- | --- |
| The wheel doesn't appear | Start dragging **first**, then press Shift. Pressing Shift before you click doesn't work. |
| Still no wheel | Check the ◎ icon is in the top-right menu bar. If it isn't, open DropWheel again from Applications. Also check which key is ticked under ◎ → **Trigger Key**. |
| "DropWheel is damaged and can't be opened" | It isn't damaged, that's the security block. Follow Step 3 again (System Settings → Privacy & Security → Open Anyway). |
| I clicked "Move to Trash" by accident | Download it again (Step 1) and repeat Steps 2 and 3. |
| No "Open Anyway" button | It only shows for about an hour after you try to open the app. Double-click DropWheel again, then go straight back to Privacy & Security. |
| A message says "…needs ffmpeg" | That format needs a free add-on. See "Extra formats" below, or pick another format. |
| Nothing happens after dropping a big video | It's working. Watch the message at the bottom of the screen; big files take a minute. |
| The ZIP won't open, or the app is missing | Delete it and download again. The download may have been cut short. |

## Optional: extra formats

Most things work straight away: photos, PDFs, Word documents, MP4/MOV videos, and WAV/M4A/FLAC audio. A
few formats need a free add-on: **MP3, OGG, Opus, MKV, AVI, WMV, WebM and WebP**. Skip this if you don't
need them.

1. Press **Command (⌘) + Space**, type **Terminal**, and press Return.
2. Copy this whole line, paste it into Terminal, and press Return:

   ```
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

3. Type your Mac password when asked, and press Return. You won't see the letters as you type; that's
   normal. Press Return again if it asks you to, then wait until it finishes (about 5 minutes).
4. Copy this line, paste it, and press Return:

   ```
   /opt/homebrew/bin/brew install ffmpeg webp
   ```

5. Wait until it finishes, then close Terminal. No restart needed: the extra formats work right away.

## Removing DropWheel

1. Click the ◎ icon in the menu bar. If **Open at Login** has a tick, click it to turn it off.
2. Click the ◎ icon again → **Quit DropWheel**.
3. Open **Applications** in Finder and drag **DropWheel** to the Trash.
