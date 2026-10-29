# Rustle

Autumn leaves on your Mac's desktop. They drift down in a soft breeze, pile up along the bottom of the screen and on the tops of your windows, scatter with a crunch when you sweep the cursor through them, and every so often a gust of wind blows them off the screen.

A small native menu-bar app (Swift, AppKit, SpriteKit). No permissions needed.

## What the leaves do

- **Fall.** Maple, oak, birch, beech, ginkgo and sweetgum leaves in golds, ambers, reds and browns. Each one swings and rocks like a real falling leaf, and some tumble.
- **Pile up.** They settle into a heap along the bottom of the screen and slump to a natural slope. They also settle on the top edges of windows that have room above them.
- **Crunch.** Push the cursor through the pile and the leaves fly up and fall back. With **Sound** on, you hear dry leaves crunching. The sound is synthesized live, so it never repeats, and it gets fuller the faster and deeper you go.
- **Rake.** Pick up the rake from the menu and your cursor becomes one. Hold the mouse button and drag: the leaves gather in the tines and come along until you let go, so you can rake them into heaps.
- **Leaf blower.** Pick up the leaf blower and hold the mouse button to blow. It faces the way you last moved, and scrolling aims the nozzle up or down. It lifts leaves off the pile and can blow them right off the screen, with a soft electric whoosh.
- **Blow away.** With **Wind Blows Leaves Away** on, a gust sweeps across the screen every so often and carries part of the pile away. The fuller the pile, the stronger and more frequent the gusts, so it never takes over your screen. Turn it off and the leaves stay.
- **Slide off.** Drag a window and its leaves slide off with it. Close or minimize it and they drop. Switch Spaces and they come back with the window.
- **Stay out of the way.** Clicks go straight through the leaves. Screenshots and screen sharing don't show them unless you turn on **Show in Screenshots**. Rustle pauses while the screen sleeps or is locked, and runs at a lower frame rate on battery or in Low Power Mode.

## Menu

| Item | |
| --- | --- |
| Leaf Fall: Off, Light, Steady, Heavy, Variable | How many leaves fall. Variable rises and eases over time. |
| Breeze: Calm, Breezy, Gusty | How much the wind pushes the falling leaves around. |
| Accumulate | Leaves pile up. When off, they land and fade. |
| Wind Blows Leaves Away | Gusts now and then blow the pile off the screen. |
| Leaves on Windows | Leaves settle on window tops. |
| Sound | Crunching leaves, the rake's rustle, and the blower's whoosh. |
| Clear Leaves | One big gust carries everything away. |
| Tools: Rake, Leaf Blower | Equip a tool. Esc, a right-click, or choosing it again puts it away. While a tool is equipped, clicks go to the leaves instead of your apps. |
| Behind Windows | Leaves fall on the desktop, behind your windows. |
| Show in Screenshots | Include the leaves in screenshots and screen recordings. |
| Open at Login | Start Rustle when you log in. |

## Build

Requires macOS 14 or later and Xcode 15 or later (or the Swift toolchain).

```bash
./build.sh            # build/Rustle.app for this Mac
./build.sh --dmg      # also build/Rustle.dmg
./build.sh --universal --dmg   # Apple silicon + Intel
./build.sh --install  # copy it to /Applications and open it
```

After `--install`, Rustle is in Applications, so you can start it with Spotlight (⌘Space, "Rustle"). Otherwise open `build/Rustle.app`, or drag it to Applications yourself. The app is ad-hoc signed, so the first time you open a copy downloaded from elsewhere, right-click it and choose **Open**.

`swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`.

## How it works

- One transparent, click-through window per display, just under the Dock's level, so the Dock sits in front of the pile. With Behind Windows on, the window drops to just above the desktop icons.
- `LeafScene` runs the simulation in SpriteKit. All the leaf art is drawn in code into a single sprite sheet (`LeafArt`), so every leaf renders in one batch. Each pile is a row of columns that stack leaves. Leaves slide down any slope steeper than the angle of repose, and the leaves above a kicked-out leaf sink into the gap.
- Window ledges come from `CGWindowListCopyWindowInfo`. Window frames don't need Screen Recording permission; only window titles would. Ledges covered by a window in front hide their leaves until they're uncovered.
- `CrunchAudio` synthesizes everything live in one audio source: a random stream of tiny resonant fracture clicks whose rate and loudness follow how hard the leaves are being disturbed, the rake's rustle, and the blower's whoosh. It stops the audio engine when it goes quiet.
- Equipping a tool puts a nearly invisible window over each display that catches the mouse, hides the cursor and draws the tool in its place (`Tools.swift`, art in `ToolArt.swift`).

### Debug switches

Set these environment variables when launching `build/Rustle.app/Contents/MacOS/Rustle` directly:

| Variable | Effect |
| --- | --- |
| `RUSTLE_DEBUG=1` | Logs frame rate and leaf counts every 5 s. |
| `RUSTLE_SNAPSHOT=/path/prefix` | With `RUSTLE_DEBUG`, writes a PNG of each display every 5 s. |
| `RUSTLE_PREFILL=1500` | Starts with that many leaves already on the ground. |
| `RUSTLE_FAKE_CURSOR=1` | Sweeps a virtual cursor back and forth through the pile. |
| `RUSTLE_FAKE_WINDOWS=1` | Adds two pretend windows; the front one is "dragged" after 25 s. |
| `RUSTLE_FAKE_TOOL=rake` or `blower` | With `RUSTLE_FAKE_CURSOR`, uses that tool, pressed for 8 s out of every 12. |
| `RUSTLE_GUST_AT=8`, `RUSTLE_CLEAR_AT=20` | With `RUSTLE_DEBUG`, a blow-away gust or a Clear Leaves at that many seconds. |

Settings can also be passed as arguments, e.g. `-leafFall heavy -breeze gusty`.

## Credits

Inspired by [Snowhush](https://github.com/mbezruchko/Snowhush), which does the same for snow.
