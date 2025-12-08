# Time Tracker — AutoHotkey v2

A fully automated work-time tracking tool designed for engineers who want clean data, minimal friction, and accurate task logging — even across lock/unlock cycles.

This script was designed around real engineering workflows: switching tasks rapidly, leaving for meetings, stepping away from your desk, and wanting post-event control over how time is handled.

---

## Features

### Automatic Task Tracking
- Start and stop tasks with hotkeys  
- Switch tasks seamlessly (previous task auto-closes)

### Automatic Lock/Unlock Handling
- Short lock (≤ 60s): task auto-resumes  
- Long lock (> 60s): previous task stops at lock time and a unified popup appears

### Unified Unlock Popup
**SECTION 1 — Handle locked time**
- Add locked time to an existing or new task  
- Discard locked time  
- Add/Discard are mutually exclusive  

**SECTION 2 — Choose next action**
- Resume previous task  
- Start a new task  
- Do not start any task  
- Resume/Next Task/Do Nothing are mutually exclusive  

### Explicit time decisions
- No time is logged without your approval  
- Nothing is double-logged  
- All timestamps are exact  

---

## Hotkeys

| Action | Hotkey |
|--------|--------|
| Open task picker | Ctrl + Alt + T |
| Stop current task | Ctrl + Alt + 0 |
| Show summary | Ctrl + Alt + S |
| Manage tasks | Ctrl + Alt + D |
| Manage time entries | Ctrl + Alt + E |

---

## File Structure

The script creates and uses four files:

