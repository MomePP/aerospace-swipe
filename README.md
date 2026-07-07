# aerospace workspace switching with trackpad swipes

aerospace-swipe detects x-fingered(defaults to 3) swipes on your trackpad and correspondingly switches between [aerospace](https://github.com/nikitabobko/AeroSpace) workspaces.

## features
- fast swipe detection and forwarding to aerospace (uses aerospace server's socket instead of cli)
- works with any number of fingers (default is 3, can be changed in config)
- adjustable sensitivity (Low/Medium/High) with velocity-based early triggering
- optional menu bar icon with runtime controls for all settings
- skips empty workspaces (if enabled in config)
- ignores your palm if it is resting on the trackpad
- haptics on swipe (this is off by default)
- customizable swipe directions (natural or inverted)
- swipe will wrap around workspaces (ex 1-9 workspaces, swipe right from 9 will go to 1)
- utilizes [yyjson](https://github.com/ibireme/yyjson) for performant json ser/de

## configuration
config file is optional and only needed if you want to change the default settings(default settings are shown in the example below)

> to restart after changing the config file, run `make restart`(this just unloads and reloads the launch agent)

```jsonc
// ~/.config/aerospace-swipe/config.json
{
  "haptic": false,
  "natural_swipe": false,
  "wrap_around": true,
  "skip_empty": true,
  "fingers": 3,
  "sensitivity": 2,      // 1=Low, 2=Medium, 3=High
  "show_menu_bar": true  // Show menu bar icon with controls
}
```

## installation
> this fork ([MomePP/aerospace-swipe](https://github.com/MomePP/aerospace-swipe)) is private, so the plain
> `curl | bash` one-liner won't work — `raw.githubusercontent.com` can't authenticate against a private repo.
> Clone with `gh` (already logged in) or SSH (key added to your GitHub account) instead, then run the script
> from inside the checkout.

### via gh CLI
```bash
gh repo clone MomePP/aerospace-swipe
cd aerospace-swipe
./install.sh # or: make install
```
### via SSH
```bash
git clone git@github.com:MomePP/aerospace-swipe.git
cd aerospace-swipe
./install.sh # or: make install
```
## uninstallation
```bash
cd aerospace-swipe # wherever you cloned it, e.g. ~/.local/share/aerospace-swipe
./uninstall.sh # or: make uninstall
```
