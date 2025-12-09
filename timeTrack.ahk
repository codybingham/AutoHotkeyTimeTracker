#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
; CONFIG
; ================================================================
logFile    := A_ScriptDir "\time_log.csv"
taskFile   := A_ScriptDir "\tasks.txt"
configFile := A_ScriptDir "\time_tracker.ini"

; Defaults (overridden by config/settings GUI)
DEFAULT_IDLE_THRESHOLD := 5          ; minutes
DEFAULT_IDLE_POLL_MS   := 15000      ; milliseconds
DEFAULT_QUICK_LOCK_SEC := 60

; Idle handling (minutes). When you're inactive for this long, the current task stops
; and you'll be prompted on return about what to do with the idle block.
IdleThresholdMinutes := DEFAULT_IDLE_THRESHOLD
; How frequently to check for idle time (milliseconds)
IdlePollInterval := DEFAULT_IDLE_POLL_MS
; How long a lock can last (in seconds) and still auto-resume the previous task
QuickLockResumeSeconds := DEFAULT_QUICK_LOCK_SEC

LoadConfig()
tasks := LoadTasks(taskFile)
currentTask := ""
startTime := ""

locked := false
lockStart := ""
lastTaskBeforeLock := ""
lastUnlockTime := ""   ; unlock timestamp for locked period

idleActive := false
idleStart := ""
lastTaskBeforeIdle := ""

OnExit(SaveTasksOnExit)

; Register for lock/unlock notifications
OnMessage(0x02B1, SessionChange)
DllCall("Wtsapi32.dll\WTSRegisterSessionNotification", "Ptr", A_ScriptHwnd, "UInt", 0)

; Clean up any blank lines created by earlier versions and start idle polling
NormalizeLogFile()
SetTimer(IdleMonitor, IdlePollInterval)


; ================================================================
; HOTKEYS
; ================================================================
^!t::OpenTaskPicker()   ; Start/select task
^!0::StopTask()         ; Stop task
^!s::ShowSummary()      ; Summary since last Monday
^!d::ManageTasks()      ; Delete/archive tasks
^!e::ManageEntries()    ; Delete/archive time entries
^!a::AddTimeEntry()     ; Manually add a time slot
^!c::OpenSettings()     ; Configure idle/lock behavior


; ================================================================
; SESSION LOCK / UNLOCK
; ================================================================
SessionChange(wParam, lParam, msg, hwnd)
{
    global locked, lockStart, currentTask, lastTaskBeforeLock
    global startTime, lastUnlockTime, logFile

    if (wParam = 7) ; LOCK
    {
        locked := true
        lockStart := A_Now
        lastTaskBeforeLock := currentTask
        return
    }

    if (wParam = 8) ; UNLOCK
    {
        if !locked
            return

        locked := false
        lastUnlockTime := A_Now
        durationSec := DateDiff(lastUnlockTime, lockStart, "Seconds")

        ; QUICK LOCK (≤ QuickLockResumeSeconds) → resume silently
        if (durationSec <= QuickLockResumeSeconds)
        {
            if (lastTaskBeforeLock != "")
            {
                currentTask := lastTaskBeforeLock
                ; keep original startTime so pre-lock work isn't lost
                if (startTime = "")
                    startTime := lastUnlockTime
                TrayTip("Time Tracker", "Resumed: " currentTask " (quick lock)")
            }
            return
        }

        ; LONG LOCK (> QuickLockResumeSeconds)
        ; 1) Always log pre-lock work for the previous task (if any)
        if (lastTaskBeforeLock != "" && startTime != "")
            StopTask(lockStart, false)

        ; 2) Show unified popup for locked time + next action
        lockedMinutes := Floor(durationSec / 60)
        hasPrev := (lastTaskBeforeLock != "")
        ShowUnifiedUnlockPopup(lockedMinutes, hasPrev)
        return
    }
}


; ================================================================
; IDLE MONITOR
; ================================================================
IdleMonitor()
{
    global IdleThresholdMinutes, idleActive, idleStart, lastTaskBeforeIdle
    global currentTask, startTime, locked

    ; Do not treat OS locks as idle — they are already handled elsewhere
    if (locked)
        return

    idleSec := A_TimeIdlePhysical // 1000  ; milliseconds → seconds
    thresholdSec := IdleThresholdMinutes * 60

    ; Entering idle state
    if (!idleActive && currentTask != "" && idleSec >= thresholdSec)
    {
        idleActive := true
        ; Estimate when idle began based on inactivity duration
        idleStart := DateAdd(A_Now, -idleSec, "Seconds")
        lastTaskBeforeIdle := currentTask
        StopTask(idleStart, false)
        return
    }

    ; Returning from idle
    if (idleActive && idleSec < thresholdSec)
    {
        idleActive := false
        idleEnd := A_Now
        idleMinutes := Floor(DateDiff(idleEnd, idleStart, "Seconds") / 60)
        if (idleMinutes < 1)
            idleMinutes := 1
        ShowIdleReturnPopup(idleMinutes, (lastTaskBeforeIdle != ""))
    }
}


; ================================================================
; UNIFIED LOCKED-TIME + NEXT-TASK POPUP
; ================================================================
ShowUnifiedUnlockPopup(lockedMinutes, hasPrevTask)
{
    global tasks

    gUnlock := Gui("+AlwaysOnTop", "Locked Time & Next Task")

    ; ----------------------------------------------------------------
    ; GROUP 1: HANDLE LOCKED TIME
    ; ----------------------------------------------------------------
    gb1 := gUnlock.Add("GroupBox", "xm ym w380 h150", "Handle locked time")

    txtLocked := gUnlock.Add(
        "Text",
        "xp+10 yp+25",
        "You were locked for " lockedMinutes " minutes."
    )

    addChk := gUnlock.Add(
        "CheckBox",
        "xp y+10 vAddChk",
        "Add locked time to a task"
    )
    discardChk := gUnlock.Add(
        "CheckBox",
        "xp y+5 vDiscardChk",
        "Discard locked time"
    )

    ; Add/discard mutual exclusion
    addChk.OnEvent("Click", (*) => discardChk.Value := 0)
    discardChk.OnEvent("Click", (*) => addChk.Value := 0)

    gUnlock.Add("Text", "xp y+10", "Pick task to add time to:")
    ddLocked := gUnlock.Add("DropDownList", "xp w250", tasks)

    gUnlock.Add("Text", "xp y+5", "Or create a new task:")
    newLocked := gUnlock.Add("Edit", "xp w250")

    ; ----------------------------------------------------------------
    ; GROUP 2: WHAT TO DO NEXT
    ; ----------------------------------------------------------------
    gb2 := gUnlock.Add("GroupBox", "xm y+15 w380 h190", "What do you want to do now?")

    resumeChk := gUnlock.Add(
        "CheckBox",
        "xp+10 yp+25 vResumeChk",
        "Resume previous task"
    )
    if !hasPrevTask
    {
        resumeChk.Enabled := false
        resumeChk.Value := 0
    }

    gUnlock.Add("Text", "xp y+15", "Start existing task:")
    ddNext := gUnlock.Add("DropDownList", "xp w250", tasks)

    gUnlock.Add("Text", "xp y+5", "Or create a new task:")
    newNext := gUnlock.Add("Edit", "xp w250")

    noTaskChk := gUnlock.Add(
        "CheckBox",
        "xp y+15 vNoTaskChk",
        "Do not start a task after closing this window"
    )

    ; --- Mutually exclusive behavior for SECTION 2 ---
    resumeChk.OnEvent("Click", (*) => (
        resumeChk.Value
            ? (noTaskChk.Value := 0, ddNext.Enabled := false, newNext.Enabled := false)
            : (ddNext.Enabled := !noTaskChk.Value, newNext.Enabled := !noTaskChk.Value)
    ))

    noTaskChk.OnEvent("Click", (*) => (
        noTaskChk.Value
            ? (resumeChk.Value := 0, ddNext.Enabled := false, newNext.Enabled := false)
            : (ddNext.Enabled := !resumeChk.Value, newNext.Enabled := !resumeChk.Value)
    ))

    ddNext.OnEvent("Change", (*) => (
        resumeChk.Value := 0,
        noTaskChk.Value := 0,
        ddNext.Enabled := true,
        newNext.Enabled := true
    ))

    newNext.OnEvent("Change", (*) => (
        resumeChk.Value := 0,
        noTaskChk.Value := 0,
        ddNext.Enabled := true,
        newNext.Enabled := true
    ))

    ; Buttons
    btnOK     := gUnlock.Add("Button", "xm y+20 w120", "OK")
    btnCancel := gUnlock.Add("Button", "x+m w120", "Cancel")

    btnOK.OnEvent("Click", (*) =>
        UnifiedUnlockHandler(
            gUnlock, lockedMinutes,
            addChk, ddLocked, newLocked,
            discardChk,
            resumeChk, ddNext, newNext, noTaskChk,
            hasPrevTask
        )
    )
    btnCancel.OnEvent("Click", (*) => gUnlock.Destroy())

    gUnlock.Show()
}


UnifiedUnlockHandler(
    gUnlock, lockedMinutes,
    addChk, ddLocked, newLocked,
    discardChk,
    resumeChk, ddNext, newNext, noTaskChk,
    hasPrevTask
)
{
    global tasks, taskFile, logFile
    global lastTaskBeforeLock, lockStart, lastUnlockTime

    ; =======================================================
    ; SECTION 1 — HANDLE LOCKED TIME
    ; =======================================================
    if (discardChk.Value)
    {
        ; Discard: do not log locked period at all.
    }
    else if (addChk.Value)
    {
        lockedTask := ""

        if (newLocked.Value != "")
        {
            lockedTask := AddTask(newLocked.Value)
        }
        else if (ddLocked.Text != "")
            lockedTask := ddLocked.Text

        if (lockedTask != "")
        {
            ; Log the locked period from lockStart to unlockTime
            mins := DateDiff(lastUnlockTime, lockStart, "Minutes")
            if (mins > 0)
            {
                date := FormatTime(lockStart, "yyyy-MM-dd")
                st   := FormatTime(lockStart, "HH:mm")
                en   := FormatTime(lastUnlockTime, "HH:mm")

                TrimFileTrailingBlanks(logFile)
                FileAppend(date "," lockedTask "," st "," en "," mins "`r`n", logFile)
            }
        }
        else
        {
            MsgBox "To add locked time, pick a task or create a new one."
            return  ; keep the window open
        }
    }

    ; =======================================================
    ; SECTION 2 — WHAT TO DO NEXT
    ; =======================================================
    nextTask := ""

    ; Case 1: Resume previous task
    if (resumeChk.Value)
    {
        if hasPrevTask && (lastTaskBeforeLock != "")
        {
            nextTask := lastTaskBeforeLock
        }
        else
        {
            MsgBox "There is no previous task to resume."
            return
        }
    }
    ; Case 2: Do not start any task
    else if (noTaskChk.Value)
    {
        gUnlock.Destroy()
        return
    }
    ; Case 3: Start new task (existing or new name)
    else
    {
        if (newNext.Value != "")
        {
            nextTask := AddTask(newNext.Value)
        }
        else if (ddNext.Text != "")
        {
            nextTask := ddNext.Text
        }
        else
        {
            MsgBox "Select a task to start, create a new one, resume a task, or choose 'Do not start a task'."
            return
        }
    }

    gUnlock.Destroy()

    if (nextTask != "")
        StartTask(nextTask)
}


; ================================================================
; IDLE RETURN POPUP
; ================================================================
ShowIdleReturnPopup(idleMinutes, hasPrevTask)
{
    global tasks

    gIdle := Gui("+AlwaysOnTop", "Idle Detected")

    gIdle.Add("Text", "xm ym", "You were idle for ~" idleMinutes " minutes.")

    gIdle.Add("GroupBox", "xm y+10 w380 h150", "Handle idle block")
    gIdle.Add("Text", "xm+10 yp+25", "Assign idle time to task (optional):")
    ddIdle := gIdle.Add("DropDownList", "xp w250", tasks)
    gIdle.Add("Text", "xp y+5", "Or create a new task:")
    newIdle := gIdle.Add("Edit", "xp w250")
    skipIdle := gIdle.Add("CheckBox", "xp y+10 vSkipIdle", "Discard idle time")

    gIdle.Add("GroupBox", "xm y+15 w380 h170", "What to do now")
    resumeChk := gIdle.Add("CheckBox", "xm+10 yp+25 vResumeIdle", "Resume previous task")
    if !hasPrevTask
    {
        resumeChk.Enabled := false
        resumeChk.Value := 0
    }

    gIdle.Add("Text", "xp y+10", "Start existing task:")
    ddNext := gIdle.Add("DropDownList", "xp w250", tasks)
    gIdle.Add("Text", "xp y+5", "Or create a new task:")
    newNext := gIdle.Add("Edit", "xp w250")
    noTaskChk := gIdle.Add("CheckBox", "xp y+10 vIdleNoTask", "Do not start a task")

    resumeChk.OnEvent("Click", (*) => (
        resumeChk.Value
            ? (noTaskChk.Value := 0, ddNext.Enabled := false, newNext.Enabled := false)
            : (ddNext.Enabled := !noTaskChk.Value, newNext.Enabled := !noTaskChk.Value)
    ))
    noTaskChk.OnEvent("Click", (*) => (
        noTaskChk.Value
            ? (resumeChk.Value := 0, ddNext.Enabled := false, newNext.Enabled := false)
            : (ddNext.Enabled := !resumeChk.Value, newNext.Enabled := !resumeChk.Value)
    ))

    btnOK := gIdle.Add("Button", "xm y+20 w120", "OK")
    btnCancel := gIdle.Add("Button", "x+m w120", "Cancel")

    btnOK.OnEvent("Click", (*) => HandleIdleReturn(
        gIdle, idleMinutes, ddIdle, newIdle, skipIdle,
        resumeChk, ddNext, newNext, noTaskChk, hasPrevTask
    ))
    btnCancel.OnEvent("Click", (*) => gIdle.Destroy())

    gIdle.Show()
}

HandleIdleReturn(gIdle, idleMinutes, ddIdle, newIdle, skipIdle,
    resumeChk, ddNext, newNext, noTaskChk, hasPrevTask)
{
    global lastTaskBeforeIdle, idleStart, logFile

    ; Optionally log idle block
    if (!skipIdle.Value)
    {
        idleTask := ""
        if (newIdle.Value != "")
            idleTask := AddTask(newIdle.Value)
        else if (ddIdle.Text != "")
            idleTask := ddIdle.Text

        if (idleTask = "")
            return MsgBox("Select or enter a task to assign idle time, or choose 'Discard idle time'.")

        idleEnd := A_Now
        AppendLogEntry(idleTask, idleStart, idleEnd)
    }

    nextTask := ""
    if (resumeChk.Value)
    {
        if hasPrevTask
            nextTask := lastTaskBeforeIdle
        else
            return MsgBox("There is no previous task to resume.")
    }
    else if (noTaskChk.Value)
    {
        gIdle.Destroy()
        return
    }
    else
    {
        if (newNext.Value != "")
            nextTask := AddTask(newNext.Value)
        else if (ddNext.Text != "")
            nextTask := ddNext.Text
        else
            return MsgBox("Select or create a task, resume previous, or pick 'Do not start a task'.")
    }

    gIdle.Destroy()
    lastTaskBeforeIdle := ""
    idleStart := ""
    if (nextTask != "")
        StartTask(nextTask)
}



; ================================================================
; TASK PICKER
; ================================================================
OpenTaskPicker()
{
    global tasks

    gPicker := Gui("+AlwaysOnTop", "Start Task")

    gPicker.Add("Text",, "Select Existing Task:")
    dd := gPicker.Add("DropDownList", "w200", tasks)

    gPicker.Add("Text",, "Or create a new task:")
    newTask := gPicker.Add("Edit", "w200")

    btnStart  := gPicker.Add("Button", "w100", "Start")
    btnCancel := gPicker.Add("Button", "w100", "Cancel")

    btnStart.OnEvent("Click", (*) => StartTaskFromGui(gPicker, dd, newTask))
    btnCancel.OnEvent("Click", (*) => gPicker.Destroy())

    gPicker.Show()
}

StartTaskFromGui(gPicker, dd, newTask)
{
    global tasks, taskFile

    chosen := dd.Text
    typed := newTask.Value

    if typed != ""
    {
        taskName := AddTask(typed)
        if (taskName = "")
        {
            MsgBox "Please enter a valid task name."
            return
        }
        StartTask(taskName)
    }
    else if chosen != ""
        StartTask(chosen)

    gPicker.Destroy()
}


; ================================================================
; TASK CONTROL
; ================================================================
StartTask(name)
{
    global currentTask, startTime

    if currentTask != ""
        StopTask()

    currentTask := name
    startTime := A_Now
    TrayTip("Time Tracker", "Started: " name)
}

StopTask(endTime := "", showTip := true)
{
    global currentTask, startTime, logFile

    if (currentTask = "" || startTime = "")
        return

    end := (endTime = "") ? A_Now : endTime
    AppendLogEntry(currentTask, startTime, end)

    if showTip
    {
        mins := Floor(DateDiff(end, startTime, "Seconds") / 60)
        if (mins < 1)
            mins := 1
        TrayTip("Time Tracker", "Stopped: " currentTask " (" mins " min)")
    }
    currentTask := ""
    startTime := ""
}


; ================================================================
; SUMMARY SINCE LAST MONDAY
; ================================================================
ShowSummary()
{
    global logFile, currentTask, startTime

    if !FileExist(logFile)
        return MsgBox("No time entries logged yet.")

    lines := StrSplit(FileRead(logFile), "`n")

    dow := A_WDay  ; 1=Sun,2=Mon,...7=Sat
    if (dow = 2)
        offset := 0
    else if (dow = 1)
        offset := 6
    else
        offset := dow - 2

    mondayDate := FormatTime(DateAdd(A_Now, -offset, "Days"), "yyyy-MM-dd")
    mondayNum  := DateToNum(mondayDate)

    totalsWeek := Map()
    totalsToday := Map()
    weeklyTotalMins := 0
    todayTotalMins := 0

    todayDate := FormatTime(A_Now, "yyyy-MM-dd")
    todayNum  := DateToNum(todayDate)

    for line in lines
    {
        line := Trim(line)
        if line = ""
            continue

        parts := StrSplit(line, ",")
        if parts.Length < 5
            continue

        date := parts[1]
        task := parts[2]
        mins := Integer(Trim(parts[5],"`t`r`n"))

        dateNum := DateToNum(date)
        if dateNum = 0
            continue

        if (dateNum >= mondayNum)
        {
            totalsWeek[task] := (totalsWeek.Has(task) ? totalsWeek[task] : 0) + mins
            weeklyTotalMins += mins
        }

        if (dateNum = todayNum)
        {
            totalsToday[task] := (totalsToday.Has(task) ? totalsToday[task] : 0) + mins
            todayTotalMins += mins
        }
    }

    out := "⏱ Summary`n`n"

    if (currentTask != "" && startTime != "")
    {
        activeMins := Max(0, DateDiff(A_Now, startTime, "Minutes"))
        out .= "Current: " currentTask " (" Round(activeMins/60,2) " hrs, started " FormatTime(startTime, "HH:mm") ")`n`n"
    }

    out .= "This week (since " mondayDate "):`n"
    if totalsWeek.Count = 0
        out .= "  (no entries)`n"
    else
        for task, mins in totalsWeek
            out .= "  " task ": " Round(mins / 60, 2) " hrs  " GenerateBars(Round(mins/60,2)) "`n"

    out .= "Total: " Round(weeklyTotalMins/60, 2) " hrs`n`n"

    out .= "Today (" todayDate "):`n"
    if totalsToday.Count = 0
        out .= "  (no entries)`n"
    else
        for task, mins in totalsToday
            out .= "  " task ": " Round(mins / 60, 2) " hrs  " GenerateBars(Round(mins/60,2)) "`n"

    out .= "Total today: " Round(todayTotalMins/60, 2) " hrs"

    MsgBox(out)
}


; ================================================================
; BAR VISUALIZATION
; ================================================================
GenerateBars(hours)
{
    bars := ""
    Loop Round(hours)
        bars .= "█"
    return bars
}


; ================================================================
; DATE NORMALIZATION
; ================================================================
DateToNum(date)
{
    date := Trim(date)

    if InStr(date, "/") {
        p := StrSplit(date, "/")
        if p.Length < 3
            return 0
        return Integer(p[3] Format("{:02}", p[1]) Format("{:02}", p[2]))
    }

    if InStr(date, "-") {
        p := StrSplit(date, "-")
        if p.Length < 3
            return 0
        return Integer(p[1] Format("{:02}", p[2]) Format("{:02}", p[3]))
    }

    return Integer(date)
}


; ================================================================
; TASK MANAGEMENT (DELETE / ARCHIVE)
; ================================================================
ManageTasks()
{
    global tasks

    gTask := Gui("+AlwaysOnTop", "Manage Tasks")
    gTask.Add("Text",, "Select a task to delete or archive:")
    dd := gTask.Add("DropDownList", "w250", tasks)

    btnDelete  := gTask.Add("Button", "w120", "Delete")
    btnArchive := gTask.Add("Button", "w120", "Archive")
    btnCancel  := gTask.Add("Button", "w120", "Cancel")

    btnDelete.OnEvent("Click", (*) => DeleteTask(gTask, dd))
    btnArchive.OnEvent("Click", (*) => ArchiveTask(gTask, dd))
    btnCancel.OnEvent("Click", (*) => gTask.Destroy())

    gTask.Show()
}

DeleteTask(gTask, dd)
{
    global tasks, taskFile

    task := dd.Text
    if task = ""
        return

    before := tasks.Length
    RemoveTask(task)

    if (tasks.Length = before)
        return MsgBox("Task not found.")

    SaveTasks(taskFile, tasks)

    MsgBox "Task deleted: " task
    gTask.Destroy()
}

ArchiveTask(gTask, dd)
{
    global tasks, taskFile

    task := dd.Text
    if task = ""
        return

    FileAppend(task "`r`n", A_ScriptDir "\\task_archive.txt")
    RemoveTask(task)
    SaveTasks(taskFile, tasks)
    MsgBox "Task archived: " task
    gTask.Destroy()
}


; ================================================================
; TIME ENTRY MANAGEMENT
; ================================================================
ManageEntries()
{
    global logFile

    if !FileExist(logFile)
        return MsgBox("No entries to manage.")

    NormalizeLogFile()

    gEntry := Gui("+AlwaysOnTop", "Manage Time Entries")
    gEntry.Add("Text",, "Select a time entry to delete or archive:")

    lb := gEntry.Add("ListBox", "w600 r15")

    Loop Parse, FileRead(logFile), "`n"
    {
        line := Trim(A_LoopField)
        if line != ""
            lb.Add([line])
    }

    btnDelete  := gEntry.Add("Button", "w120", "Delete")
    btnArchive := gEntry.Add("Button", "w120", "Archive")
    btnCancel  := gEntry.Add("Button", "w120", "Cancel")

    btnDelete.OnEvent("Click", (*) => DeleteEntry(gEntry, lb))
    btnArchive.OnEvent("Click", (*) => ArchiveEntry(gEntry, lb))
    btnCancel.OnEvent("Click", (*) => gEntry.Destroy())

    gEntry.Show()
}

DeleteEntry(gEntry, lb)
{
    global logFile

    sel := lb.Text
    if sel = ""
        return

    out := ""
    for line in StrSplit(FileRead(logFile), "`n")
    {
        trimmed := Trim(line, "`r`n `t")
        if (trimmed = "")
            continue
        if (trimmed != Trim(sel))
            out .= trimmed "`r`n"
    }

    FileDelete(logFile)
    FileAppend(out, logFile)
    NormalizeLogFile()

    if lb.Value
        lb.Delete(lb.Value)

    TrayTip("Time Tracker", "Entry deleted.")
}

ArchiveEntry(gEntry, lb)
{
    global logFile

    sel := lb.Text
    if sel = ""
        return

    FileAppend(sel "`r`n", A_ScriptDir "\time_archive.csv")

    out := ""
    for line in StrSplit(FileRead(logFile), "`n")
    {
        trimmed := Trim(line, "`r`n `t")
        if (trimmed = "")
            continue
        if (trimmed != Trim(sel))
            out .= trimmed "`r`n"
    }

    FileDelete(logFile)
    FileAppend(out, logFile)
    NormalizeLogFile()

    if lb.Value
        lb.Delete(lb.Value)

    TrayTip("Time Tracker", "Entry archived.")
}


; ================================================================
; MANUAL TIME ENTRY (ADVANCED GUI)
; ================================================================
AddTimeEntry()
{
    global tasks

    gAdd := Gui("+AlwaysOnTop", "Add Time Entry")

    gAdd.Add("Text",, "Task:")
    ddTask := gAdd.Add("DropDownList", "w250", tasks)

    gAdd.Add("Text",, "Or create a new task:")
    newTask := gAdd.Add("Edit", "w250")

    gAdd.Add("Text",, "Date:")
    dtDate := gAdd.Add("DateTime", "w200 vdtDate", "yyyy-MM-dd")
    dtDate.Value := A_Now

    gAdd.Add("Text",, "Start time (HH:mm):")
    startTimeEdit := gAdd.Add("Edit", "vstartTimeEdit w80", FormatTime(A_Now, "HH:mm"))

    gAdd.Add("Text",, "End time (HH:mm):")
    endTimeEdit := gAdd.Add("Edit", "vendTimeEdit w80", FormatTime(A_Now, "HH:mm"))

    btnAdd    := gAdd.Add("Button", "w100", "Add Entry")
    btnCancel := gAdd.Add("Button", "w100", "Cancel")

    btnAdd.OnEvent("Click", (*) => AddTimeEntry_Commit(gAdd, ddTask, newTask, dtDate, startTimeEdit, endTimeEdit))
    btnCancel.OnEvent("Click", (*) => gAdd.Destroy())

    gAdd.Show()
}

AddTimeEntry_Commit(gAdd, ddTask, newTask, dtDate, startTimeEdit, endTimeEdit)
{
    global tasks, taskFile, logFile

    ; ----- Task selection -----
    task := ""
    if (newTask.Value != "")
    {
        task := AddTask(newTask.Value)
    }
    else if (ddTask.Text != "")
    {
        task := ddTask.Text
    }

    if (task = "")
    {
        MsgBox "Please select or enter a task."
        return
    }

    ; ----- Date -----
    d := dtDate.Value
    dateStr := FormatTime(d, "yyyy-MM-dd")

    ; ----- Time handling -----
    startStr := startTimeEdit.Value
    endStr   := endTimeEdit.Value

    ; Validate time format HH:mm
    if !RegExMatch(startStr, "^\d{1,2}:\d{2}$")
    {
        MsgBox "Invalid start time format. Use HH:mm."
        return
    }
    if !RegExMatch(endStr, "^\d{1,2}:\d{2}$")
    {
        MsgBox "Invalid end time format. Use HH:mm."
        return
    }

    ; Parse to numbers
    sParts := StrSplit(startStr, ":")
    eParts := StrSplit(endStr, ":")

    sh := Integer(sParts[1]), sm := Integer(sParts[2])
    eh := Integer(eParts[1]), em := Integer(eParts[2])

    if (sh < 0 || sh > 23 || sm < 0 || sm > 59
     || eh < 0 || eh > 23 || em < 0 || em > 59)
    {
        MsgBox "Invalid time values. Hours 0–23, minutes 0–59."
        return
    }

    startTotal := sh*60 + sm
    endTotal   := eh*60 + em

    if (endTotal <= startTotal)
    {
        MsgBox "End time must be later than start time."
        return
    }

    mins := endTotal - startTotal

    ; ----- Check overlap with existing entries on the same date -----
    if FileExist(logFile)
    {
        for line in StrSplit(FileRead(logFile), "`n")
        {
            trimmed := Trim(line)
            if (trimmed = "")
                continue

            parts := StrSplit(trimmed, ",")
            if (parts.Length < 5)
                continue

            existingDate := Trim(parts[1])
            if (existingDate != dateStr)
                continue

            est := TimeStrToMinutes(parts[3])
            eet := TimeStrToMinutes(parts[4])
            if (est < 0 || eet <= est)
                continue

            if (IntervalsOverlap(startTotal, endTotal, est, eet))
            {
                MsgBox "Manual entry overlaps existing entry:" "`n" Trim(parts[2]) " (" parts[3] " - " parts[4] ")"
                return
            }
        }
    }

    TrimFileTrailingBlanks(logFile)
    FileAppend(dateStr "," task "," startStr "," endStr "," mins "`r`n", logFile)
    NormalizeLogFile()
    TrayTip("Time Tracker", "Added manual entry: " task " (" mins " min)")

    gAdd.Destroy()
}



; ================================================================
; LOG HELPERS
; ================================================================
AppendLogEntry(task, startTs, endTs)
{
    global logFile

    mins := Floor(DateDiff(endTs, startTs, "Seconds") / 60)
    if (mins < 1)
        mins := 1

    date := FormatTime(startTs, "yyyy-MM-dd")
    st   := FormatTime(startTs, "HH:mm")
    en   := FormatTime(endTs, "HH:mm")

    TrimFileTrailingBlanks(logFile)
    FileAppend(date "," task "," st "," en "," mins "`r`n", logFile)
}

TimeStrToMinutes(str)
{
    if !RegExMatch(str, "^(\d{1,2}):(\d{2})$", &m)
        return -1

    h := Integer(m[1])
    mi := Integer(m[2])

    if (h < 0 || h > 23 || mi < 0 || mi > 59)
        return -1

    return h*60 + mi
}

IntervalsOverlap(s1, e1, s2, e2)
{
    return (s1 < e2) && (e1 > s2)
}

NormalizeLogFile()
{
    global logFile

    if !FileExist(logFile)
        return

    cleaned := ""
    for line in StrSplit(FileRead(logFile), "`n")
    {
        trimmed := Trim(line, "`r`n `t")
        if (trimmed = "")
            continue
        cleaned .= trimmed "`r`n"
    }

    FileDelete(logFile)
    FileAppend(cleaned, logFile)
}

; CLEAN TRAILING BLANK LINES BEFORE APPENDING
; ================================================================
TrimFileTrailingBlanks(file)
{
    if !FileExist(file)
        return

    content := FileRead(file)

    ; Remove trailing blank lines / whitespace
    cleaned := RTrim(content, "`r`n `t")

    ; Ensure exactly one newline at end
    cleaned .= "`r`n"

    if (cleaned != content)
    {
        FileDelete(file)
        FileAppend(cleaned, file)
    }
}


; ================================================================
; TASK PERSISTENCE
; ================================================================
LoadTasks(file)
{
    if !FileExist(file)
        return []

    raw := Trim(FileRead(file), "`r`n")
    return raw = "" ? [] : StrSplit(raw, "`n")
}

AddTask(name)
{
    global tasks, taskFile

    clean := Trim(name)
    if (clean = "")
        return ""

    for existing in tasks
        if (StrLower(existing) = StrLower(clean))
            return existing

    tasks.Push(clean)
    SaveTasks(taskFile, tasks)
    return clean
}

RemoveTask(name)
{
    global tasks

    idx := 0
    for i, t in tasks
        if (StrLower(t) = StrLower(name))
        {
            idx := i
            break
        }

    if (idx > 0)
        tasks.RemoveAt(idx)
}

SaveTasks(file, tasks)
{
    out := ""
    for t in tasks
        out .= t "`r`n"

    if FileExist(file)
        FileDelete(file)

    FileAppend(out, file)
}

SaveTasksOnExit(*)
{
    global taskFile, tasks
    SaveTasks(taskFile, tasks)
    DllCall("Wtsapi32.dll\WTSUnRegisterSessionNotification", "Ptr", A_ScriptHwnd)
}

; ================================================================
; SETTINGS (IDLE / LOCK CONFIG)
; ================================================================
OpenSettings()
{
    global IdleThresholdMinutes, IdlePollInterval, QuickLockResumeSeconds

    gSet := Gui("+AlwaysOnTop", "Time Tracker Settings")

    gSet.Add("Text",, "Idle threshold (minutes before pausing):")
    idleEdit := gSet.Add("Edit", "w120", IdleThresholdMinutes)

    gSet.Add("Text",, "Idle poll interval (milliseconds):")
    pollEdit := gSet.Add("Edit", "w120", IdlePollInterval)

    gSet.Add("Text",, "Quick lock resume window (seconds):")
    lockEdit := gSet.Add("Edit", "w120", QuickLockResumeSeconds)

    btnSave   := gSet.Add("Button", "w100", "Save")
    btnCancel := gSet.Add("Button", "w100", "Cancel")

    btnSave.OnEvent("Click", (*) => SaveSettingsFromGui(gSet, idleEdit, pollEdit, lockEdit))
    btnCancel.OnEvent("Click", (*) => gSet.Destroy())

    gSet.Show()
}

SaveSettingsFromGui(gSet, idleEdit, pollEdit, lockEdit)
{
    global IdleThresholdMinutes, IdlePollInterval, QuickLockResumeSeconds

    idleVal := ParsePositiveInt(idleEdit.Value, 0)
    pollVal := ParsePositiveInt(pollEdit.Value, 0)
    lockVal := ParsePositiveInt(lockEdit.Value, 0)

    if (idleVal < 1)
        return MsgBox("Idle threshold must be at least 1 minute.")

    if (pollVal < 1000)
        return MsgBox("Idle poll interval should be at least 1000 ms to avoid high CPU usage.")

    if (lockVal < 5)
        return MsgBox("Quick lock resume window must be 5 seconds or greater.")

    IdleThresholdMinutes := idleVal
    IdlePollInterval := pollVal
    QuickLockResumeSeconds := lockVal

    SaveConfig()
    RestartIdleTimer()

    TrayTip("Time Tracker", "Settings saved.")
    gSet.Destroy()
}

RestartIdleTimer()
{
    global IdlePollInterval
    SetTimer(IdleMonitor, 0)
    SetTimer(IdleMonitor, IdlePollInterval)
}

LoadConfig()
{
    global configFile, IdleThresholdMinutes, IdlePollInterval, QuickLockResumeSeconds
    global DEFAULT_IDLE_THRESHOLD, DEFAULT_IDLE_POLL_MS, DEFAULT_QUICK_LOCK_SEC

    if !FileExist(configFile)
    {
        IdleThresholdMinutes := DEFAULT_IDLE_THRESHOLD
        IdlePollInterval := DEFAULT_IDLE_POLL_MS
        QuickLockResumeSeconds := DEFAULT_QUICK_LOCK_SEC
        return
    }

    IdleThresholdMinutes := ParsePositiveInt(
        IniRead(configFile, "Settings", "IdleThresholdMinutes", DEFAULT_IDLE_THRESHOLD),
        DEFAULT_IDLE_THRESHOLD
    )

    IdlePollInterval := ParsePositiveInt(
        IniRead(configFile, "Settings", "IdlePollInterval", DEFAULT_IDLE_POLL_MS),
        DEFAULT_IDLE_POLL_MS
    )

    QuickLockResumeSeconds := ParsePositiveInt(
        IniRead(configFile, "Settings", "QuickLockResumeSeconds", DEFAULT_QUICK_LOCK_SEC),
        DEFAULT_QUICK_LOCK_SEC
    )
}

SaveConfig()
{
    global configFile, IdleThresholdMinutes, IdlePollInterval, QuickLockResumeSeconds

    IniWrite(IdleThresholdMinutes, configFile, "Settings", "IdleThresholdMinutes")
    IniWrite(IdlePollInterval, configFile, "Settings", "IdlePollInterval")
    IniWrite(QuickLockResumeSeconds, configFile, "Settings", "QuickLockResumeSeconds")
}

ParsePositiveInt(val, fallback)
{
    val := Trim(val)
    if RegExMatch(val, "^-?\d+$")
    {
        n := Integer(val)
        if (n > 0)
            return n
    }
    return fallback
}
