# Notes for coding agents

This repository is public. It holds only the generic manager code. Real app definitions and nginx routes are
machine-specific and live in the owner's private config repo, cloned next to this one:

```
~/code/app_manager          <- this repo (public, code only)
~/code/app_manager_config   <- private config repo, one folder per machine
```

## Which apps.json the manager uses

Every manager (`app_manager_tmux`, `app_manager_win`, `app_manager_psmux`) and its landing page loads, and saves back
to, the first of:

1. `$APP_MANAGER_APPS_FILE`, if set
2. `~/code/app_manager_config/machines/<hostname>/<platform>/apps.json` (`$APP_MANAGER_CONFIG_DIR` overrides the
   folder; `<platform>` is `tmux`, `win` or `psmux`)
3. `apps.json` next to the scripts

`<hostname>` is `hostname -s` on Linux/macOS and `$env:COMPUTERNAME` on Windows. Check it on the machine rather than
guessing. The manager prints `Loading apps from: <path>` at startup.

## Adding or changing an app

1. Edit `~/code/app_manager_config/machines/<hostname>/<platform>/apps.json` for the machine the app runs on.
   No copying is needed; the manager reads it there.
2. Commit and push the change in `~/code/app_manager_config`, not here.

Entry format: see `apps_example.json` in each platform folder and the "Custom apps" section of `README.md`.

## Adding an nginx route

1. Add the `location` block to `~/code/app_manager_config/machines/<hostname>/nginx/fix_nginx.sh`, following the
   existing blocks there.
2. Set `NginxPath` on the app entry in `apps.json` so the dashboard links through nginx.
3. Commit and push in `~/code/app_manager_config`. Applying it on the server (`bash fix_nginx.sh`, which uses sudo
   and reloads nginx) is the owner's step; do not run it without asking.

## Keep this repo free of personal data

Never commit to this repo: real `apps.json` files or backups, hostnames, IP addresses, usernames, home-directory
paths, app or project names, ports of real apps, nginx routes, or credentials. Use placeholders such as
`192.168.1.10`, `203.0.113.10`, `/home/user/...`, `C:\Users\me\...` and `my_app` in examples.

If `~/code/app_manager_config` or the machine's folder does not exist, stop and ask the owner instead of putting
the config here.
