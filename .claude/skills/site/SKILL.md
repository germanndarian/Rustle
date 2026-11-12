---
name: site
description: Work on the Rustle website in site/. Use when asked to change the website, landing page, index.html, the in-browser leaves or menu demo, the site images in site/assets, the Download button, or the GitHub Pages deploy.
---

# Rustle website

`site/` is a static page: `site/index.html` (one file, about 1460 lines) and images in `site/assets/` (`leaves.png`, `leaves-large.png`, `rake.png`, `blower.png`, `icon-256.png`). It runs the app's leaves live in the browser with a working copy of the menu, the feature list, a specimen sheet of the six leaf kinds and a Download section.

## Deploy

- `.github/workflows/pages.yml` deploys `site/` to GitHub Pages on a push to `main` that touches `site/**` or the workflow, and on manual dispatch.
- Live at https://germanndarian.github.io/Rustle/ after a merge. Don't push to `main`; changes go through a PR.
- The Download button links to the latest GitHub release, which carries `Rustle.dmg`.

## Keep in step with the app

- The page mirrors the app's menu (Leaf Fall, Breeze, Accumulate, Wind Blows Leaves Away, Leaves Crumble, Sound, Tools). When the app's menu or behavior changes, change the page too.
- The leaf images come from the app's own drawing code (`LeafArt`, `ToolArt`); don't redraw them by hand.

## Checking a change

- Open `site/index.html` in a browser (a local file works for a static page). Not confirmed with a server command.
- Look at the page after a visual change; there is no automated check for the site.
