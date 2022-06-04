; This script contains AutoHotkey (un)installation routines.
; See the AutoHotkey v2 documentation for usage.
#include inc\bounce-v1.ahk
/* v1 stops here */
#requires AutoHotkey v2.0-beta.3

#include inc\launcher-common.ahk
#include inc\HashFile.ahk
#include inc\config.ahk
#include inc\CreateAppShortcut.ahk
#include inc\EnableUIAccess.ahk

if A_LineFile = A_ScriptFullPath
    Install_Main

Install_Main() {
    try {
        if !A_Args.Length {
            Installation().InstallFull() ; Re-registration mode
            ExitApp
        }
        switch A_Args[1] {
            case '/install':
                Installation(A_Args[2]).InstallExtraVersion()
            case '/uninstall':
                Installation().Uninstall()
            case '/to':
                Installation(, A_Args[2]).InstallFull()
        }
    }
    catch as e {
        MsgBox type(e) ": " e.Message "`n`n" (e.Extra = "" ? "" : "Specifically: " e.Extra)
            . "`n`nStack:`n" e.Stack,, "Iconx"
        ExitApp 1
    }
}

class Installation {
    ProductName     := "AutoHotkey"
    ProductURL      := "https://autohotkey.com"
    Publisher       := "AutoHotkey Foundation LLC"
    Version         := A_AhkVersion
    AppUserModelID  := 'AutoHotkey.AutoHotkey'
    
    UserInstall     := !A_IsAdmin
    Interpreter     := A_AhkPath
    
    ScriptProgId    := 'AutoHotkeyScript'
    SoftwareSubKey  := 'Software\AutoHotkey'
    RootKey         => this.UserInstall ? 'HKCU' : 'HKLM'
    SoftwareKey     => this.RootKey '\' this.SoftwareSubKey
    ClassesKey      => this.RootKey '\Software\Classes'
    FileTypeKey     => this.ClassesKey '\' this.ScriptProgId
    UninstallKey    => this.RootKey '\Software\Microsoft\Windows\CurrentVersion\Uninstall\AutoHotkey'
    StartShortcut   => (this.UserInstall ? A_Programs : A_ProgramsCommon) '\AutoHotkey.lnk'
    
    DialogTitle     => this.ProductName " Setup"
    
    FileItems       := [] ; [{Source, Dest}]
    RegItems        := [] ; [{Key, ValueName, Value}]
    PreCheck        := [] ; [Callback(this)]
    PreAction       := [] ; [Callback(this)]
    PostAction      := [] ; [Callback(this)]
    
    __new(sourceDir:=unset, installDir:=unset) {
        ; Resolve installation directory
        IsSet(installDir) ? DirCreate(installDir) : (installDir := A_ScriptDir '\..')
        Loop Files installDir, 'D'
            this.InstallDir := installDir := A_LoopFileFullPath
        else
            throw ValueError("Invalid target directory",, installDir)
        ; Override installation mode if already installed here
        SetRegView 64
        for rootKey in ['HKLM', 'HKCU'] {
            if RegRead(rootKey '\' this.SoftwareSubKey, 'InstallDir', '') = installDir
                this.UserInstall := rootKey = 'HKCU'
        }
        ; Resolve source directory
        Loop Files IsSet(sourceDir) ? sourceDir : A_ScriptDir '\..', 'D'
            this.SourceDir := A_LoopFileFullPath
        else
            throw ValueError("Invalid source directory",, sourceDir)
    }
    
    HashesPath => this.InstallDir '\UX\installed-files.csv'
    Hashes => (
        this.DefineProp('Hashes', {value: hashes := this.ReadHashes()}),
        hashes
    )
    
    Apply() {
        if !DirExist(this.InstallDir)
            DirCreate this.InstallDir
        SetWorkingDir this.InstallDir
        
        ; Execute pre-check actions
        for item in this.PreCheck
            item(this)
        
        ; Detect possible conflicts before taking action
        this.PreApplyChecks()
        
        ; Execute pre-install actions
        for item in this.PreAction
            item(this)
        
        ; Install files
        for item in this.FileItems {
            SplitPath item.Dest,, &destDir
            if destDir != ''
                DirCreate destDir
            try
                FileCopy item.Source, item.Dest, true
            catch
                MsgBox 'Copy failed`nsource: ' item.Source '`ndest: ' item.Dest
            else
                this.AddFileHash(item.Dest, this.Version)
        }
        
        ; Install registry settings
        for item in this.RegItems {
            if item.HasProp('Value') {
                RegWrite(item.Value, item.Value is Integer ? 'REG_DWORD' : 'REG_SZ'
                    , item.Key, item.ValueName)
            } else {
                try RegDelete(item.Key, item.ValueName)
            }
        }
        
        ; Execute post-install actions
        for item in this.PostAction
            item(this)
        
        ; Write file list to disk
        if this.Hashes.Count {
            s := "Hash,Version,Path`r`n"
            for ,item in this.Hashes
                s .= Format('{1},{2},"{3}"`r`n', item.Hash, item.Version, item.Path)
            FileOpen(this.HashesPath, 'w').Write(s)
        }
    }
    
    ElevateIfNeeded() {
        if !A_IsAdmin && !this.UserInstall {
            try Run '*runas ' DllCall('GetCommandLine', 'str')
            ExitApp
        }
    }
    
    ;{ Installation entry points
    
    InstallFull() {
        SetRegView 64
        
        this.ElevateIfNeeded
        
        doFiles := this.InstallDir != this.SourceDir
        
        ; If a newer version is already installed, integrate with it
        ux := doFiles && this.GetTargetUX()
        if ux && VerCompare(ux.Version, this.Version) > 0 {
            cmd := StrReplace(ux.InstallCommand, '%1', this.SourceDir,, &replaced)
            if !replaced
                cmd .= ' "' this.SourceDir '"'
            Run cmd, this.InstallDir
            ExitApp
        }
        
        ; If a legacy version is installed, upgrade it
        wowKey(k) => StrReplace(k, '\Software\', '\Software\Wow6432Node\')
        installedVersion := RegRead(key := wowKey(this.SoftwareKey), 'Version', '')
                         || RegRead(key := this.SoftwareKey, 'Version', '')
        if SubStr(installedVersion, 1, 2) = '1.' {
            this.SoftwareKeyV1 := key
            this.UninstallKeyV1 := InStr(key, 'Wow64') ? wowKey(this.UninstallKey) : this.UninstallKey
            this.AddPreCheck this.PrepareUpgradeV1
            this.AddPreAction this.UpgradeV1
        }
        
        if doFiles {
            subDir := 'v' A_AhkVersion
            this.AddCoreFiles(subDir)
            this.Interpreter := this.InstallDir '\' subDir '\AutoHotkey' (A_Is64bitOS ? '64' : '32') '.exe'
            
            this.AddUXFiles
            this.AddMiscFiles
            this.AddUninstallReg
            this.AddPostAction this.UpdateV2Link
        }
        
        this.AddSoftwareReg
        this.AddFileTypeReg
        
        this.Apply
        
        Run Format('"{2}" "{1}\UX\ui-dash.ahk"', this.InstallDir, this.Interpreter)
    }
    
    InstallExtraVersion() {
        SetRegView 64
        
        Loop Files this.SourceDir '\AutoHotkey*.exe' {
            exe := GetExeInfo(A_LoopFilePath)
            break
        } else
            throw Error("AutoHotkey*.exe not found in source directory",, this.SourceDir)
        
        this.ElevateIfNeeded
        
        this.Version := exe.Version
        this.AddCoreFiles('v' exe.Version)
        
        if FileExist(this.SourceDir '\Compiler\Ahk2Exe.exe') {
            compilerVersion := GetExeInfo(this.SourceDir '\Compiler\Ahk2Exe.exe').Version
            installedCompiler := this.Hashes.Get('Compiler\Ahk2Exe.exe', '')
            if !installedCompiler || VerCompare(compilerVersion, installedCompiler.Version) > 0
                this.AddCompiler(this.SourceDir '\Compiler')
        }
        
        this.Apply
    }
    
    ;}
    
    ;{ Uninstallation
    
    Uninstall() {
        files := this.Hashes
        if !files.Count
            this.GetConfirmation("Installation data missing. Files will not be deleted.", 'x')
        
        ; Close scripts and help files
        this.PreUninstallChecks()
        
        ; Registry
        SetRegView 64
        delKey this.FileTypeKey
        delKey this.ClassesKey '\.ahk'
        delKey this.SoftwareKey
        delKey this.UninstallKey
        if this.RootKey = 'HKLM' {
            delKey 'HKCU\' this.SoftwareSubKey
            delKey 'HKCU\Software\Classes\' this.ScriptProgId
            for k in ['AutoHotkey.exe', 'Ahk2Exe.exe'] ; made by v1 installer
                delKey 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' k
        }
        
        delKey(key) {
            try
                RegDeleteKey key
            catch OSError as e
                if e.number != 2 ; ERROR_FILE_NOT_FOUND
                    throw
        }
        
        this.NotifyAssocChanged
        
        ; Files
        SetWorkingDir this.InstallDir
        modified := ""
        dirs := ""
        for path, f in files {
            if !FileExist(path)
                continue
            if HashFile(path) = f.Hash {
                if this.InstallDir '\' path = A_AhkPath
                    postponed := A_AhkPath
                else
                    FileDelete path
            } else {
                modified .= "`n" path
            }
            SplitPath path,, &dir
            if dir != ""
                dirs .= dir "`n"
        }
        if modified != "" {
            MsgBox("The following files were not deleted as they appear to have been modified:"
                . modified, this.DialogTitle, "Iconi")
        }
        FileDelete this.HashesPath
        for dir in StrSplit(Sort(RTrim(dirs, "`n"), 'UR'), "`n")
            try DirDelete dir, false
        
        this.DeleteLink this.InstallDir '\v2'
        
        if IsSet(postponed) {
            ; Try delete via cmd.exe after we exit
            Run(A_ComSpec ' /c "'
                'ping -n 2 127.1 > NUL & '
                'del "' postponed '" & '
                'cd %TEMP% & '
                'rmdir "' postponed '\.." & '
                'dir "' postponed '\.." & '
                'rmdir "' A_WorkingDir '"'
                '"',, 'Hide')
        }
        ExitApp
    }
    
    ;}
    
    ;{ Conflict prevention
    
    PreApplyChecks() {
        ; Map files which may need to be overwritten
        writeFiles := Map(), writeFiles.CaseSense := 'off'
        hasChm := false
        for item in this.FileItems {
            SplitPath item.Dest,,, &ext
            if ext = 'exe'
                writeFiles[this.InstallDir '\' item.Dest] := true
            else if ext = 'chm'
                hasChm := true
        }
        ; Find any scripts being executed by those files
        ours(exe) => writeFiles.Has(exe) || writeFiles.Has(StrReplace(exe, '_UIA'))
        scripts := this.ScriptsUsingOurFiles(ours)
        
        ; Find files that the user might not want overwritten
        unknownFiles := ''
        modifiedFiles := ''
        hashes := this.Hashes
        for item in this.FileItems {
            if attrib := FileExist(item.Dest) {
                if InStr(attrib, 'D') {
                    this.FatalError("The following file cannot be installed "
                        "because a directory by this name already exists:`n"
                        item.Dest "`n`nNo changes have been made.")
                }
                if !(installedFile := hashes.Get(item.Dest, ''))
                    unknownFiles .= item.Dest "`n"
                else if installedFile.Hash != HashFile(item.Dest)
                    modifiedFiles .= item.Dest "`n"
            }
        }
        
        ; Show confirmation prompt
        message := ""
        if scripts.Length {
            message .= "The following scripts will be closed automatically:`n"
            for w in scripts
                message .= this.ScriptTitle(w) "`n"
            message .= "`n"
        }
        if unknownFiles != '' {
            message .= "The following files not created by setup will be overwritten:`n"
                . unknownFiles
                message .= "`n"
            }
        if modifiedFiles != '' {
            message .= "The following files appear to contain modifications that will be lost:`n"
                . modifiedFiles
            message .= "`n"
        }
        if message != ''
            this.GetConfirmation(message)
        
        this.CloseScriptsUsingOurFiles(scripts, ours)
    }
    
    PreUninstallChecks() {
        ours(exe) => this.Hashes.Has(this.RelativePath(exe))
        scripts := this.ScriptsUsingOurFiles(ours)
        this.CloseScriptsUsingOurFiles(scripts, ours)
    }
    
    CloseScriptsUsingOurFiles(scripts, ours) {
        ; Close scripts and help files
        static WM_CLOSE := 0x10
        for w in WinGetList("AutoHotkey ahk_class HH Parent")
            try PostMessage WM_CLOSE,,, w
        for w in scripts
            try PostMessage WM_CLOSE,,, w
        ; Wait for windows/scripts to close
        WinWaitClose "AutoHotkey ahk_class HH Parent"
        loop {
            Sleep 100
            ; Refresh the list in case scripts have started/stopped
            scripts := this.ScriptsUsingOurFiles(ours)
            ; Prompt again after around 3 seconds of waiting
            if scripts.Length && Mod(A_Index, 30) = 0 {
                message := "The following scripts must be closed manually before setup can continue:`n"
                for w in scripts
                    message .= this.ScriptTitle(w) "`n"
                this.GetConfirmation(message)
            }
        } until scripts.Length = 0
    }
    
    ScriptsUsingOurFiles(ours) {
        scripts := [], dhw := A_DetectHiddenWindows
        DetectHiddenWindows true
        for w in WinGetList('ahk_class AutoHotkey') {
            if w = A_ScriptHwnd
                continue
            if ours(WinGetProcessPath(w))
                scripts.Push(w)
        }
        DetectHiddenWindows dhw
        return scripts
    }
    
    ScriptTitle(wnd) => RegExReplace(WinGetTitle(wnd), ' - AutoHotkey v.*')
     
    ;}
    
    ;{ Components to install
    
    AddCoreFiles(destSubDir) {
        this.AddFiles(this.SourceDir, destSubDir
            , 'AutoHotkey*.exe', 'AutoHotkey.chm', 'WindowSpy.ahk')
        
        ; Queue creation of UIA executable files
        if A_IsAdmin && this.IsTrustedLocation(this.InstallDir)
            Loop Files this.SourceDir '\AutoHotkey*.exe'
                this.AddPostAction this.MakeUIA.Bind(, destSubDir '\' A_LoopFileName)
    }
    
    AddMiscFiles() {
        this.AddFiles(this.SourceDir, '.', 'license.txt')
    }
    
    AddCompiler(compilerSourceDir) {
        this.AddFiles(compilerSourceDir, 'Compiler', 'Ahk2Exe.exe')
        this.AddVerb('Compile', 'Compiler\Ahk2Exe.exe', '/in "%l" %*', "Compile script")
        this.AddVerb('Compile-Gui', 'Compiler\Ahk2Exe.exe', '/gui /in "%l" %*', "Compile script (GUI)...")
    }
    
    AddUXFiles() {
        this.AddFiles(A_ScriptDir, 'UX', '*.ahk')
        this.AddFiles(A_ScriptDir, 'UX\inc', 'inc\*.ahk')
        this.AddFiles(A_ScriptDir '\Templates', 'UX\Templates', '*.ahk')
        this.AddPostAction this.CreateStartShortcut
    }
    
    AddSoftwareReg() {
        this.AddRegValues(this.SoftwareKey, [
            {ValueName: 'InstallDir', Value: this.InstallDir},
            {ValueName: 'InstallCommand', Value: this.CmdStr('UX\install.ahk', '/install "%1"')},
            {ValueName: 'Version', Value: this.Version},
        ])
    }
    
    AddUninstallReg() {
        this.AddRegValues(this.UninstallKey, [
            {ValueName: 'DisplayName',          Value: this.ProductName (this.RootKey = 'HKCU' ? " (user)" : "")},
            {ValueName: 'UninstallString',      Value: this.CmdStr('UX\install.ahk', '/uninstall')},
            {ValueName: 'QuietUninstallString', Value: this.CmdStr('UX\install.ahk', '/uninstall')},
            ; TODO: implement maintenance GUI
            {ValueName: 'NoModify',             Value: 1},
            {ValueName: 'DisplayIcon',          Value: this.Interpreter},
            {ValueName: 'DisplayVersion',       Value: this.Version},
            {ValueName: 'URLInfoAbout',         Value: this.ProductURL},
            {ValueName: 'Publisher',            Value: this.Publisher},
            {ValueName: 'InstallLocation',      Value: this.InstallDir},
        ])

    }
    
    AddFileTypeReg() {
        this.AddRegValues(this.ClassesKey, [
            {Key: '.ahk', Value: this.ScriptProgId},
            {Key: '.ahk\ShellNew', ValueName: 'Command', Value: this.CmdStr('UX\ui-newscript.ahk', '"%1"')},
            {Key: '.ahk\ShellNew', ValueName: 'FileName'}
        ])
        this.AddRegValues(this.FileTypeKey, [
            {Value: "AutoHotkey Script"},
            {Key: 'DefaultIcon', Value: this.Interpreter ",1"},
            {Key: 'Shell', Value: 'Open runas UIAccess Edit'}, ; Including 'runas' in lower-case fixes the shield icon not appearing on Windows 11.
            {Key: 'Shell\Open', ValueName: 'FriendlyAppName', Value: 'AutoHotkey Launcher'},
        ])
        this.AddRunVerbs()
        this.AddEditVerbIfUnset()
        this.AddPostAction this.NotifyAssocChanged
    }
    
    AddRunVerbs() {
        aumid := {ValueName: 'AppUserModelID', Value: this.AppUserModelID}
        this.AddVerb('Open', 'UX\launcher.ahk', '"%1" %*', "Run script",
            aumid
        )
        this.AddVerb('RunAs', 'UX\launcher.ahk', '"%1" %*', "Run as administrator",
            aumid, {ValueName: 'HasLUAShield', Value: ""}
        )
        if A_IsAdmin && this.IsTrustedLocation(this.InstallDir) {
            this.AddVerb('UIAccess', 'UX\launcher.ahk', '/runwith UIA "%1" %*',
                "Run with UI access", aumid)
        }
    }

    AddEditVerbIfUnset() {
        static v1_edit_cmd := 'notepad.exe %1'
        ; Add edit verb only if it is undefined or has its default v1 value.
        if RegRead(this.FileTypeKey '\Shell\Edit\Command',, v1_edit_cmd) = v1_edit_cmd
            this.AddVerb('Edit', 'UX\ui-editor.ahk', '"%1"', "Edit script")
    }
    
    ;}
    
    ;{ Utility functions
    
    RelativePath(p) => (
        i := this.InstallDir '\',
        SubStr(p, 1, StrLen(i)) = i ? SubStr(p, StrLen(i) + 1) : p
    )
    
    CmdStr(script, args:='')
        => RTrim(Format((InStr(script, '.ahk') ? '"{1}" ' : '') '"{2}\{3}" {4}'
            , this.Interpreter, this.InstallDir, script, args))
    
    AddRegValues(key, values) {
        for v in values {
            i := {}
            i.Key := key (v.HasProp('Key') ? '\' v.Key : '')
            i.ValueName := v.HasProp('ValueName') ? v.ValueName : ''
            (v is Primitive)     ? i.Value := v :
            (v.HasProp('Value')) ? i.Value := v.Value : 0
            this.RegItems.Push(i)
        }
    }
    
    AddVerb(name, script, args, values*) {
        this.AddRegValues(this.FileTypeKey '\Shell\' name, [
            {Key: 'Command', Value: this.CmdStr(script, args)},
            values*
        ])
    }
    
    AddFileCopy(sourcePath, destPath) {
        this.FileItems.Push {Source: sourcePath, Dest: destPath}
    }
    
    AddFiles(sourceDir, destSubDir, patterns*) {
        destSubDir := (destSubDir != '.' ? destSubDir '\' : '')
        for p in patterns {
            Loop Files sourceDir '\' p {
                this.AddFileCopy A_LoopFileFullPath, destSubDir . A_LoopFileName
            }
        }
    }
    
    AddPreCheck(f) => this.PreCheck.Push(f)
    AddPreAction(f) => this.PreAction.Push(f)
    AddPostAction(f) => this.PostAction.Push(f)
    
    ReadHashes() {
        filemap := Map(), filemap.CaseSense := 0
        hashesPath := this.HashesPath
        if !FileExist(hashesPath)
            return filemap
        csvfile := FileOpen(hashesPath, 'r')
        props := StrSplit(csvfile.ReadLine(), ',')
        while !csvfile.AtEOF {
            item := {}
            Loop Parse csvfile.ReadLine(), 'CSV'
                item.%props[A_Index]% := A_LoopField
            filemap[item.Path] := item
        }
        return filemap
    }
    
    AddFileHash(f, v) {
        this.Hashes[f] := {Path: f, Hash: HashFile(f), Version: v}
    }
    
    NotifyAssocChanged() {
        DllCall("shell32\SHChangeNotify", "uint", 0x08000000 ; SHCNE_ASSOCCHANGED
            , "uint", 0, "ptr", 0, "ptr", 0)
    }
    
    GetConfirmation(message, icon:='!') {
        if MsgBox(message, this.DialogTitle, 'Icon' icon ' OkCancel') = 'Cancel'
            ExitApp 1
    }
    
    FatalError(message) {
        MsgBox message, this.DialogTitle, 'Iconx'
        ExitApp
    }
    
    GetTargetUX() {
        try {
            ; For registered installations, InstallCommand allows for future changes.
            return {
                Version:        RegRead(this.SoftwareKey, 'Version'),
                InstallCommand: RegRead(this.SoftwareKey, 'InstallCommand')
            }
        }
        try {
            ; Target installation not in registry, or has no InstallCommand (e.g. too old).
            ; Allow non-registry installations that follow protocol as commented below.
            ux := {}
            ; Version information must be provided by the file at this.HashesPath:
            ux.Version := this.Hashes['UX\install.ahk'].Version
            ; Interpreter must be located at the path calculated below:
            interpreter := this.InstallDir '\v' ux.Version '\AutoHotkey' (A_Is64bitOS ? '64' : '32') '.exe'
            if FileExist(interpreter) {
                ; Additional interpreters must be installable with this command line:
                ux.InstallCommand := Format('"{1}" "{2}\UX\install.ahk" /install "%1"'
                                            , interpreter, this.InstallDir)
                return ux
            }
        }
        ; Otherwise, UX script or appropriate interpreter not found.
    }
    
    ; Delete a symbolic link, or do nothing if path does not refer to a symbolic link.
    DeleteLink(path) {
        switch this.GetLinkAttrib(path) {
            case 'D': DirDelete path
            case 'F': FileDelete path
        }
    }
    
    GetLinkAttrib(path) {
        attrib := DllCall('GetFileAttributes', 'str', path)
        ; FILE_ATTRIBUTE_REPARSE_POINT = 0x400
        ; FILE_ATTRIBUTE_DIRECTORY = 0x10
        return (attrib != -1 && (attrib & 0x400)) ? ((attrib & 0x10) ? 'D' : 'F') : ''
    }
    
    UpdateV2Link() {
        ; Create a stable path for the current v2 directory
        ; (if a symbolic link can be created)
        this.DeleteLink link := this.InstallDir '\v2'
        DllCall('CreateSymbolicLink', 'str', link, 'str', 'v' this.Version, 'uint', 1) ; SYMBOLIC_LINK_FLAG_DIRECTORY = 1
    }
    
    CreateStartShortcut() {
        CreateAppShortcut(
            lnk := this.StartShortcut,
            this.Interpreter,
            Format('"{1}\UX\ui-dash.ahk"', this.InstallDir),
            "AutoHotkey Dash",
            this.AppUserModelID
        )
        this.AddFileHash lnk, this.Version
    }
    
    MakeUIA(baseFile) {
        SplitPath baseFile,, &baseDir,, &baseName
        FileCopy baseFile, newPath := baseDir '\' baseName '_UIA.exe', true
        EnableUIAccess newPath
        this.AddFileHash newPath, '' ; For uninstall
    }
    
    IsTrustedLocation(path) { ; http://msdn.com/library/bb756929
        other := EnvGet(A_PtrSize=8 ? "ProgramFiles(x86)" : "ProgramW6432")
        return InStr(path, A_ProgramFiles "\") = 1
            || other && InStr(path, other "\") = 1
    }
    
    ;}

    ;{ Upgrade from v1
    
    PrepareUpgradeV1() {
        ; This needs to be done before conflict-checking
        if FileExist('license.txt')
            this.AddFileHash('license.txt', '')
    }
    
    UpgradeV1() {
        exe := GetExeInfo('AutoHotkey.exe')
        build := RegExReplace(exe.Description, '^AutoHotkey *')
        
        ; Set default launcher settings
        if ConfigRead('Launcher\v1', 'Build', '!') = '!'
            ConfigWrite(build, 'Launcher\v1', 'Build')
        if ConfigRead('Launcher\v1', 'UTF8', '') = ''
            && InStr(RegRead('HKCR\' this.ScriptProgId '\Shell\Open\Command',, ''), '/cp65001 ')
            ConfigWrite(true, 'Launcher\v1', 'UTF8')
        
        ; Record these for Uninstall
        add 'AutoHotkey{1}.exe', '', 'A32', 'U32', 'U64', 'A32_UIA', 'U32_UIA', 'U64_UIA'
        add 'Compiler\{1}.bin', 'ANSI 32-bit', 'Unicode 32-bit', 'Unicode 64-bit', 'AutoHotkeySC'
        add '{1}', 'Compiler\Ahk2Exe.exe', 'WindowSpy.ahk', 'AutoHotkey.chm'
                 , A_WinDir '\ShellNew\Template.ahk'
        
        add(fmt, patterns*) {
            for p in patterns
                if FileExist(f := Format(fmt, p))
                    this.AddFileHash(f, exe.Version)
        }
        
        ; Remove obsolete files
        for item in ['Installer.ahk', 'AutoHotkey Website.url']
            try FileDelete item
        
        ; Remove the v1 shortcuts from the Start menu
        name := RegRead(this.SoftwareKeyV1, 'StartMenuFolder', '')
        if name != ''
            try DirDelete A_ProgramsCommon '\' name, true
        
        ; Remove the old sub-keys, which might be in the wrong reg view
        try RegDeleteKey this.SoftwareKeyV1
        try RegDeleteKey this.UninstallKeyV1
    }
     
    ;}
}
