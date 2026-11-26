# Paint for macOS (MacPaint)

Native Swift/AppKit clone of Windows 10 Paint. Build: `./build.sh` -> `build/Paint.app` (universal, ad-hoc signed).
First launch of an unsigned app: right-click > Open.

Zoom: Cmd/Ctrl + scroll wheel, trackpad pinch, magnifier tool (click in / right-click out), status-bar slider,
View menu (Cmd+/-, Cmd+0 = 100%, Cmd+9 = fit). Levels 12.5% .. 6400%; pixel grid appears at >= 800%.
Arrow keys nudge a selection 1px (Shift = 10px). Option-drag copies a selection. Right-click draws with Color 2.
Dev hook: PAINT_SNAPSHOT=/path/prefix ./build/Paint.app/Contents/MacOS/Paint renders demo PNGs and exits.

## License

MIT, see [LICENSE](LICENSE).
