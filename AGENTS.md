# Notes for coding agents

This repository is public. It holds only the generic manager code. Real app definitions and nginx routes are
machine-specific and live in the owner's private config repo, cloned next to this one:

```
~/code/app_manager          <- this repo (public, code only)
~/code/app_manager_config   <- private config repo
```

## Adding or changing an app

1. Edit the real app list in the private repo:
   - Linux (tmux): `~/code/app_manager_config/apps/tmux/apps.json`
   - Windows: `~/code/app_manager_config/apps/win/apps.json`
   - Windows (psmux): `~/code/app_manager_config/apps/psmux/apps.json`
2. Copy it into the matching folder here (`app_manager_tmux/`, `app_manager_win/` or `app_manager_psmux/`) so the
   manager picks it up. `apps.json` is gitignored in this repo.
3. Commit and push the change in `~/code/app_manager_config`, not here.

Entry format: see `apps_example.json` in each platform folder and the "Custom apps" section of `README.md`.

## Adding an nginx route

1. Add the `location` block to `~/code/app_manager_config/nginx/fix_nginx.sh`, following the existing blocks there.
2. Set `NginxPath` on the app entry in `apps.json` so the dashboard links through nginx.
3. Commit and push in `~/code/app_manager_config`. Applying it on the server (`bash fix_nginx.sh`, which uses sudo
   and reloads nginx) is the owner's step; do not run it without asking.

## Keep this repo free of personal data

Never commit to this repo: real `apps.json` files or backups, hostnames, IP addresses, usernames, home-directory
paths, app or project names, ports of real apps, nginx routes, or credentials. Use placeholders such as
`192.168.1.10`, `203.0.113.10`, `/home/user/...`, `C:\Users\me\...` and `my_app` in examples.

If `~/code/app_manager_config` does not exist on the machine, stop and ask the owner instead of putting the
config here.
