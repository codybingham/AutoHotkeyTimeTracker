#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
; CONFIG
; ================================================================
logFile        := A_ScriptDir "\time_log.csv"
invalidLogFile := A_ScriptDir "\time_log_invalid.txt"
taskFile       := A_ScriptDir "\tasks.txt"
configFile     := A_ScriptDir "\time_tracker.ini"

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

                AppendCsvLine(logFile, date, lockedTask, st, en, mins)
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

    readResult := ReadLogLines(logFile)
    WarnInvalidLines(readResult["invalid"], "while reading the time log for the summary")
    lines := readResult["valid"]

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
        task := Trim(parts[2], " `t")
        minsStr := Trim(parts[5],"`t`r`n")
        if !IsNumber(minsStr)
            continue
        mins := Integer(minsStr)

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

    lines := StrSplit(out, "`n")
    linesCount := lines.Length
    maxChars := 0
    for line in lines
        maxChars := Max(maxChars, StrLen(line))

    summaryGui := Gui("+AlwaysOnTop", "Summary")
    summaryGui.SetFont("s10", "Consolas")

    charWidth := GetAverageCharWidth(summaryGui.Hwnd)
    guiWidth := Max(420, (maxChars * charWidth) + 40)
    guiRows := Max(12, Min(linesCount + 2, 30))

    summaryEdit := summaryGui.Add(
        "Edit",
        "+ReadOnly -Wrap +HScroll xm ym w" guiWidth " r" guiRows,
        out
    )

    closeBtn := summaryGui.Add("Button", "xm y+10 w80 Default", "Close")
    closeBtn.OnEvent("Click", (*) => summaryGui.Destroy())

    summaryGui.Show()
    closeBtn.Focus()
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

GetAverageCharWidth(hwnd)
{
    hdc := DllCall("GetDC", "Ptr", hwnd, "Ptr")
    size := Buffer(8, 0)
    ; Measure a representative character in the current font to size the summary window.
    DllCall("GetTextExtentPoint32", "Ptr", hdc, "Str", "W", "Int", 1, "Ptr", size)
    width := NumGet(size, 0, "Int")
    DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", hdc)
    return width
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

    readResult := ReadLogLines(logFile)
    WarnInvalidLines(readResult["invalid"], "while loading entries")

    gEntry := Gui("+AlwaysOnTop", "Manage Time Entries")
    gEntry.Add("Text",, "Select a time entry to delete or archive:")

    lb := gEntry.Add("ListBox", "w600 r15")

    for line in readResult["valid"]
        lb.Add([line])

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

    kept := []
    readResult := ReadLogLines(logFile)
    WarnInvalidLines(readResult["invalid"], "while deleting an entry")
    for line in readResult["valid"]
    {
        if (line != Trim(sel))
            kept.Push(line)
    }

    WriteLogLines(logFile, kept)

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

    archiveLine := NormalizeCsvLine(sel)
    if (archiveLine != "")
    {
        TrimFileTrailingBlanks(A_ScriptDir "\\time_archive.csv")
        FileAppend(archiveLine "`r`n", A_ScriptDir "\\time_archive.csv")
    }

    kept := []
    readResult := ReadLogLines(logFile)
    WarnInvalidLines(readResult["invalid"], "while archiving an entry")
    for line in readResult["valid"]
    {
        if (line != Trim(sel))
            kept.Push(line)
    }

    WriteLogLines(logFile, kept)

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

    gAdd.Add("Text",, "Start time:")
    startTimeCtl := gAdd.Add("DateTime", "vstartTimeCtl w120", "HH':'mm")
    startTimeCtl.Value := A_Now

    gAdd.Add("Text",, "End time:")
    endTimeCtl := gAdd.Add("DateTime", "vendTimeCtl w120", "HH':'mm")
    endTimeCtl.Value := DateAdd(A_Now, 1, "Hours")

    btnAdd    := gAdd.Add("Button", "w100", "Add Entry")
    btnCancel := gAdd.Add("Button", "w100", "Cancel")

    btnAdd.OnEvent("Click", (*) => AddTimeEntry_Commit(gAdd, ddTask, newTask, dtDate, startTimeCtl, endTimeCtl))
    btnCancel.OnEvent("Click", (*) => gAdd.Destroy())

    gAdd.Show()
}

AddTimeEntry_Commit(gAdd, ddTask, newTask, dtDate, startTimeCtl, endTimeCtl)
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
    dateVal := dtDate.Value
    if (dateVal = "")
    {
        MsgBox "Please pick a date."
        return
    }

    dateStr := FormatTime(dateVal, "yyyy-MM-dd")

    ; ----- Time handling -----
    startVal := startTimeCtl.Value
    endVal   := endTimeCtl.Value

    if (startVal = "" || endVal = "")
    {
        MsgBox "Please pick both a start and end time."
        return
    }

    startStr := FormatTime(startVal, "HH:mm")
    endStr   := FormatTime(endVal, "HH:mm")

    startTotal := TimeStrToMinutes(startStr)
    endTotal   := TimeStrToMinutes(endStr)

    if (startTotal < 0 || endTotal < 0)
    {
        MsgBox "Invalid time values. Use 24-hour HH:mm format."
        return
    }

    if (endTotal <= startTotal)
    {
        MsgBox "End time must be later than start time."
        return
    }

    mins := endTotal - startTotal

    ; ----- Check overlap with existing entries on the same date -----
    if FileExist(logFile)
    {
        readResult := ReadLogLines(logFile)
        WarnInvalidLines(readResult["invalid"], "while checking for overlapping entries")

        for line in readResult["valid"]
        {
            parts := StrSplit(line, ",")
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

    AppendCsvLine(logFile, dateStr, task, startStr, endStr, mins)
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

    secs := DateDiff(endTs, startTs, "Seconds")
    if (secs < 60)
        return

    mins := Floor(secs / 60)
    if (mins < 1)
        mins := 1

    date := FormatTime(startTs, "yyyy-MM-dd")
    st   := FormatTime(startTs, "HH:mm")
    en   := FormatTime(endTs, "HH:mm")

    AppendCsvLine(logFile, date, task, st, en, mins)
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

    readResult := ReadLogLines(logFile)
    WarnInvalidLines(readResult["invalid"], "while cleaning the time log")
    WriteLogLines(logFile, readResult["valid"])
}

; CLEAN TRAILING BLANK LINES BEFORE APPENDING
; ================================================================
TrimFileTrailingBlanks(file)
{
    global invalidLogFile

    if !FileExist(file)
        return

    if (file = invalidLogFile)
    {
        cleaned := ""
        for line in StrSplit(FileRead(file), "`n")
        {
            trimmed := Trim(line, "`r`n")
            if (trimmed != "")
                cleaned .= trimmed "`r`n"
        }
        FileDelete(file)
        FileAppend(cleaned, file)
        return
    }

    readResult := ReadLogLines(file)
    WarnInvalidLines(readResult["invalid"], "while normalizing log spacing")
    WriteLogLines(file, readResult["valid"])
}

SanitizeCsvField(val)
{
    clean := StrReplace(StrReplace(val, "`r"), "`n")
    clean := StrReplace(clean, ",", " ")
    return Trim(clean)
}

FormatCsvEntry(date, task, start, end, mins)
{
    return SanitizeCsvField(date) "," SanitizeCsvField(task) "," SanitizeCsvField(start) "," SanitizeCsvField(end) "," SanitizeCsvField(mins)
}

NormalizeCsvLine(line)
{
    validation := ValidateCsvLine(line)
    return validation.valid ? validation.normalized : ""
}

AppendCsvLine(file, date, task, start, end, mins)
{
    TrimFileTrailingBlanks(file)
    FileAppend(FormatCsvEntry(date, task, start, end, mins) "`r`n", file)
}

ValidateCsvLine(line)
{
    result := Map()
    result["line"] := Trim(line, "`r`n `t")
    result["valid"] := false
    result["normalized"] := ""
    result["reason"] := ""

    if (result["line"] = "")
    {
        result["reason"] := "Blank line"
        return result
    }

    parts := StrSplit(result["line"], ",")
    if (parts.Length < 5)
    {
        result["reason"] := "Expected 5 fields (date, task, start, end, minutes)"
        return result
    }

    date := Trim(parts[1])
    start := Trim(parts[3])
    finish := Trim(parts[4])
    mins := Trim(parts[5], "`t`r`n")

    if !RegExMatch(date, "^\d{4}-\d{2}-\d{2}$")
    {
        result["reason"] := "Invalid date format (yyyy-MM-dd)"
        return result
    }

    dParts := StrSplit(date, "-")
    y := Integer(dParts[1]), m := Integer(dParts[2]), d := Integer(dParts[3])
    if (m < 1 || m > 12 || d < 1 || d > 31)
    {
        result["reason"] := "Date values out of range"
        return result
    }

    if !(IsValidTime(start) && IsValidTime(finish))
    {
        result["reason"] := "Invalid time format (HH:mm)"
        return result
    }

    if !RegExMatch(mins, "^-?\d+$")
    {
        result["reason"] := "Minutes must be an integer"
        return result
    }

    if (Integer(mins) < 1)
    {
        result["reason"] := "Minutes must be positive"
        return result
    }

    result["valid"] := true
    result["normalized"] := FormatCsvEntry(date, parts[2], start, finish, mins)
    return result
}

IsValidTime(val)
{
    if !RegExMatch(val, "^\d{2}:\d{2}$")
        return false

    parts := StrSplit(val, ":")
    h := Integer(parts[1]), m := Integer(parts[2])
    return !(h < 0 || h > 23 || m < 0 || m > 59)
}

ReadLogLines(file)
{
    result := Map()
    result["valid"] := []
    result["invalid"] := []

    if !FileExist(file)
        return result

    for line in StrSplit(FileRead(file), "`n")
    {
        check := ValidateCsvLine(line)
        if (check["valid"])
            result["valid"].Push(check["normalized"])
        else if (check["line"] != "")
            result["invalid"].Push(check)
    }

    if (result["invalid"].Length > 0)
        SaveInvalidLogLines(result["invalid"], file)

    return result
}

SaveInvalidLogLines(invalidLines, sourceFile := "")
{
    global invalidLogFile

    if (invalidLines.Length = 0)
        return

    TrimFileTrailingBlanks(invalidLogFile)

    for entry in invalidLines
    {
        msg := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
            . (sourceFile != "" ? " | " sourceFile : "")
            . " | " entry["reason"]
            . " | " entry["line"]

        FileAppend(msg "`r`n", invalidLogFile)
    }
}

WarnInvalidLines(invalidLines, context)
{
    global invalidLogFile

    if (invalidLines.Length = 0)
        return

    first := invalidLines[1]
    MsgBox(
        "Skipped " invalidLines.Length " invalid log entr"
        . "ies " context "." "`n`n"
        . "First issue: " first["reason"] " → " first["line"] "`n`n"
        . "See '" invalidLogFile "' for the full list."
    )
}

WriteLogLines(file, lines)
{
    if (lines.Length = 0)
    {
        FileDelete(file)
        FileAppend("", file)
        return
    }

    content := ""
    for line in lines
        content .= line "`r`n"

    tempFile := file ".tmp"
    existingAttrib := FileExist(file) ? FileGetAttrib(file) : ""

    try
    {
        if FileExist(tempFile)
            FileDelete(tempFile)

        FileAppend(content, tempFile)

        if (existingAttrib != "")
            FileSetAttrib(existingAttrib, tempFile)

        FileMove(tempFile, file, true)
    }
    catch as error
    {
        if FileExist(tempFile)
            FileDelete(tempFile)

        throw error
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
