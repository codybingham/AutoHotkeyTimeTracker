#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
; CONFIG
; ================================================================
logFile  := A_ScriptDir "\time_log.csv"
taskFile := A_ScriptDir "\tasks.txt"

tasks := LoadTasks(taskFile)
currentTask := ""
startTime := ""

locked := false
lockStart := ""
lastTaskBeforeLock := ""
lastUnlockTime := ""   ; unlock timestamp for locked period

OnExit(SaveTasksOnExit)

; Register for lock/unlock notifications
OnMessage(0x02B1, SessionChange)
DllCall("Wtsapi32.dll\WTSRegisterSessionNotification", "Ptr", A_ScriptHwnd, "UInt", 0)


; ================================================================
; HOTKEYS
; ================================================================
^!t::OpenTaskPicker()   ; Start/select task
^!0::StopTask()         ; Stop task
^!s::ShowSummary()      ; Summary since last Monday
^!d::ManageTasks()      ; Delete/archive tasks
^!e::ManageEntries()    ; Delete/archive time entries
^!a::AddTimeEntry()     ; Manually add a time slot


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

        ; QUICK LOCK (≤60s) → resume silently
        if (durationSec <= 60)
        {
            if (lastTaskBeforeLock != "")
            {
                currentTask := lastTaskBeforeLock
                startTime := A_Now
                TrayTip("Time Tracker", "Resumed: " currentTask " (quick lock)")
            }
            return
        }

        ; LONG LOCK (>60s)
        ; 1) Always log pre-lock work for the previous task (if any)
        if (lastTaskBeforeLock != "" && startTime != "")
        {
            preMins := DateDiff(lockStart, startTime, "Minutes")
            if (preMins > 0)
            {
                date := FormatTime(startTime, "yyyy-MM-dd")
                st   := FormatTime(startTime, "HH:mm")
                en   := FormatTime(lockStart, "HH:mm")
                TrimFileTrailingBlanks(logFile)
                FileAppend(date "," lastTaskBeforeLock "," st "," en "," preMins "`r`n", logFile)
            }
            ; previous task is now stopped
            currentTask := ""
            startTime := ""
        }

        ; 2) Show unified popup for locked time + next action
        lockedMinutes := Floor(durationSec / 60)
        hasPrev := (lastTaskBeforeLock != "")
        ShowUnifiedUnlockPopup(lockedMinutes, hasPrev)
        return
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
            lockedTask := newLocked.Value
            tasks.Push(lockedTask)
            SaveTasks(taskFile, tasks)
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
            nextTask := newNext.Value
            tasks.Push(nextTask)
            SaveTasks(taskFile, tasks)
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
        tasks.Push(typed)
        SaveTasks(taskFile, tasks)
        StartTask(typed)
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

StopTask()
{
    global currentTask, startTime, logFile

    if currentTask = ""
        return

    end := A_Now
    mins := DateDiff(end, startTime, "Minutes")
    date := FormatTime(startTime, "yyyy-MM-dd")
    st   := FormatTime(startTime, "HH:mm")
    en   := FormatTime(end, "HH:mm")

    TrimFileTrailingBlanks(logFile)
    FileAppend(date "," currentTask "," st "," en "," mins "`r`n", logFile)

    TrayTip("Time Tracker", "Stopped: " currentTask " (" mins " min)")
    currentTask := ""
    startTime := ""
}


; ================================================================
; SUMMARY SINCE LAST MONDAY
; ================================================================
ShowSummary()
{
    global logFile

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

    totals := Map()

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

        if dateNum < mondayNum
            continue

        totals[task] := (totals.Has(task) ? totals[task] : 0) + mins
    }

    out := "⏱ Summary (since last Monday)`n`n"

    for task, mins in totals
        out .= task ": " Round(mins / 60, 2) " hrs  " GenerateBars(Round(mins/60,2)) "`n"

    if totals.Count = 0
        out .= "(no entries since last Monday)"

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

    idx := 0
    for i, t in tasks
        if (t = task)
        {
            idx := i
            break
        }

    if idx = 0
        return MsgBox("Task not found.")

    tasks.RemoveAt(idx)
    SaveTasks(taskFile, tasks)

    MsgBox "Task deleted: " task
    gTask.Destroy()
}

ArchiveTask(gTask, dd)
{
    task := dd.Text
    if task = ""
        return

    FileAppend(task "`r`n", A_ScriptDir "\task_archive.txt")
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
        if Trim(line) != Trim(sel)
            out .= Trim(line) "`r`n"
    }

    FileDelete(logFile)
    FileAppend(out, logFile)

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
        if Trim(line) != Trim(sel)
            out .= Trim(line) "`r`n"
    }

    FileDelete(logFile)
    FileAppend(out, logFile)

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
        task := newTask.Value
        tasks.Push(task)
        SaveTasks(taskFile, tasks)
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

    TrimFileTrailingBlanks(logFile)
    FileAppend(dateStr "," task "," startStr "," endStr "," mins "`r`n", logFile)
    TrayTip("Time Tracker", "Added manual entry: " task " (" mins " min)")

    gAdd.Destroy()
}



; ================================================================
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
