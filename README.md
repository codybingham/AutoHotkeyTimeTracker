# Time Tracker — AutoHotkey v2

A small, unobtrusive time tracker for Windows that keeps clean logs while you swap tasks, lock your screen, step away, or add manual entries later. Idle detection and quick-lock handling reduce popups, and all behavior can be tuned from an in-app settings dialog.

---

## Getting started
1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Run `timeTrack.ahk` (double-click or add to Startup). The script will create its data files in the same folder as the script.
3. Use the hotkeys below to start/stop tasks, review summaries, or change settings. Tray tips will confirm actions.

---

## Hotkeys

| Action | Hotkey |
|--------|--------|
| Open task picker | Ctrl + Alt + T |
| Stop current task | Ctrl + Alt + 0 |
| Show weekly/today summary | Ctrl + Alt + S |
| Manage tasks (delete/archive) | Ctrl + Alt + D |
| Manage time entries (delete/archive) | Ctrl + Alt + E |
| Manually add a time entry | Ctrl + Alt + A |
| Open settings (idle/lock behavior) | Ctrl + Alt + C |

---

## Everyday workflow

### Starting and stopping work
- Press **Ctrl+Alt+T** to pick an existing task or type a new name. Switching tasks auto-stops the previous one.
- Press **Ctrl+Alt+0** to stop the current task immediately.

### Locking/unlocking and quick locks
- **Quick locks** shorter than your configured window (default 60s) automatically resume the last task without resetting the start time.
- **Longer locks** stop the task at the lock time and show a unified popup when you return so you can discard or assign the locked block, then choose what to work on next.

### Idle detection
- If you are inactive longer than the configured idle threshold, the active task pauses automatically. On return you get a popup to discard or assign the idle block and decide what to do next.
- Adjust idle threshold, polling interval, and quick-lock window via **Ctrl+Alt+C**. Values are saved to `time_tracker.ini` and loaded on startup.

### Manual and historical edits
- Use **Ctrl+Alt+A** to enter a manual block: pick or type a task, date, and start/end times. Entries that overlap existing time on the same day are rejected with a clear message, preventing double-logging.
- Manage tasks with **Ctrl+Alt+D** (delete/archive) and entries with **Ctrl+Alt+E** (delete/archive). Archived tasks are removed from dropdowns.

### Summaries
- Press **Ctrl+Alt+S** for a popup showing the active task plus totals for today and the current week (since Monday), with quick bar visuals for scale.

---

## Configuration and data files

All files live next to `timeTrack.ahk`:

| File | Purpose |
|------|---------|
| `time_tracker.ini` | Saved settings for idle threshold (minutes), idle poll interval (ms), and quick-lock resume window (seconds). |
| `time_log.csv` | Main log: `date,task,start,end,minutes` (one entry per line; blank lines are removed automatically). |
| `tasks.txt` | Active task list shown in dropdowns. |
| `task_archive.txt` | Archived task names. |
| `time_archive.csv` | Archived time entries. |

Log handling normalizes whitespace, so each entry stays on its own line without gaps, even after manual edits.

