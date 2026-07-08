# aerospace workspace switching with trackpad swipes

<img src="Resources/AppIcon.png" width="96" align="right" alt="AerospaceSwipe icon">

aerospace-swipe detects x-fingered(defaults to 3) swipes on your trackpad and correspondingly switches between [aerospace](https://github.com/nikitabobko/AeroSpace) workspaces.

## features
- fast swipe detection and forwarding to aerospace (uses aerospace server's socket instead of cli)
- works with any number of fingers (default is 3, can be changed in config)
- adjustable sensitivity (Low/Medium/High)
- multi-step swiping: cross more than one workspace in a single continuous gesture, switching live as you swipe (can be disabled for one-switch-per-gesture instead, with velocity-based early triggering for fast flicks)
- optional menu bar icon with runtime controls for all settings
- skips empty workspaces (if enabled in config)
- ignores your palm if it is resting on the trackpad
- haptics on swipe (this is off by default)
- customizable swipe directions (natural or inverted)
- swipe will wrap around workspaces (ex 1-9 workspaces, swipe right from 9 will go to 1)
- utilizes [yyjson](https://github.com/ibireme/yyjson) for performant json ser/de

## configuration
config file is optional and only needed if you want to change the default settings(default settings are shown in the example below)

> to restart after changing the config file: `brew services restart aerospace-swipe` (homebrew install) or
> `make restart` (manual install) — both just unload and reload the launch agent

```jsonc
// ~/.config/aerospace-swipe/config.json
{
  "haptic": false,
  "natural_swipe": false,
  "wrap_around": true,
  "skip_empty": true,
  "fingers": 3,
  "sensitivity": 2,      // 1=Low, 2=Medium, 3=High
  "show_menu_bar": true, // Show menu bar icon with controls
  "multi_swipe": true,   // Cross multiple workspaces in one continuous gesture, live
  "max_steps": 5         // Cap on workspaces crossed per gesture when multi_swipe is on
}
```

## installation
### homebrew (recommended)
```bash
brew tap momepp/formulae
brew install aerospace-swipe        # stable, pinned to the latest tagged release
# or: brew install --HEAD aerospace-swipe   # tracks the main branch instead

brew services start aerospace-swipe # installs + loads the launchd service
```
> the tap ([MomePP/homebrew-formulae](https://github.com/MomePP/homebrew-formulae)) is public, but the formula
> builds from source out of this repo, which is **private** — `brew install`/`brew reinstall` needs to `git
> clone` it, so it only works on a machine with your own GitHub auth set up (`gh auth login`, or an SSH key
> added to your account). Config, restart, and uninstall all work the same as the manual install below, except
> use `brew services restart|stop aerospace-swipe` instead of `make restart`/`make uninstall` for the launchd
> service — `brew` owns that plist once installed this way.

### manual
> this fork ([MomePP/aerospace-swipe](https://github.com/MomePP/aerospace-swipe)) is private, so the plain
> `curl | bash` one-liner won't work — `raw.githubusercontent.com` can't authenticate against a private repo.
> Clone with `gh` (already logged in) or SSH (key added to your GitHub account) instead, then run the script
> from inside the checkout.

#### via gh CLI
```bash
gh repo clone MomePP/aerospace-swipe
cd aerospace-swipe
./install.sh # or: make install
```
#### via SSH
```bash
git clone git@github.com:MomePP/aerospace-swipe.git
cd aerospace-swipe
./install.sh # or: make install
```
## uninstallation
### homebrew
```bash
brew services stop aerospace-swipe
brew uninstall aerospace-swipe
```
### manual
```bash
cd aerospace-swipe # wherever you cloned it, e.g. ~/.local/share/aerospace-swipe
./uninstall.sh # or: make uninstall
```
