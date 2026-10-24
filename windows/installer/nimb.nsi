; The installer and the uninstaller of Nimb for Windows (NSIS 3, built on a Mac by build.sh).
;
; Defines from the command line: ARCH (amd64 or arm64), VERSION, SRC (the folder with Nimb.exe, nimb-svc.exe, wintun.dll and the
; text files), ICON (nimb.ico), OUTFILE.
;
; What it does: puts the files in Program Files\Nimb, installs the service NimbHelper (it has the rights that the switching of DNS
; and of the tunnel needs, so that the window never asks for them again), makes a shortcut and a record in "Apps and features".
; The uninstaller undoes all of it and gives back the DNS: see nimb-svc.exe cleanup.

Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!insertmacro GetParameters
!insertmacro GetOptions

!ifndef ARCH
  !error "define ARCH"
!endif
!ifndef VERSION
  !error "define VERSION"
!endif

Name "Nimb"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\Nimb"
InstallDirRegKey HKLM "Software\Nimb" "InstallDir"
RequestExecutionLevel admin
BrandingText "Nimb ${VERSION}"
SetCompressor /SOLID lzma

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING

!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Запустить Nimb"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchNimb

!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "ProductName" "Nimb"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "FileDescription" "Установщик Nimb"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "LegalCopyright" "PolyForm Noncommercial 1.0.0"

; The window must start with the rights of the person, not with the rights of the installer: explorer.exe hands it over.
Function LaunchNimb
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\Nimb.exe"'
FunctionEnd

; The window of Nimb is drawn by Microsoft Edge WebView2. Windows 11 has it; an old Windows 10 may not: then the small official
; installer of Microsoft is downloaded and run quietly.
Function EnsureWebView2
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  ${If} $0 == ""
    ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  ${EndIf}
  ${If} $0 == ""
  ${OrIf} $0 == "0.0.0.0"
    DetailPrint "Устанавливаю Microsoft Edge WebView2 (нужен для окна Nimb)…"
    nsExec::ExecToLog 'powershell -NoProfile -Command "(New-Object Net.WebClient).DownloadFile($\'https://go.microsoft.com/fwlink/p/?LinkId=2124703$\', $\'$TEMP\MicrosoftEdgeWebview2Setup.exe$\')"'
    Pop $1
    ${If} $1 == 0
      nsExec::ExecToLog '"$TEMP\MicrosoftEdgeWebview2Setup.exe" /silent /install'
      Pop $1
      Delete "$TEMP\MicrosoftEdgeWebview2Setup.exe"
    ${Else}
      MessageBox MB_OK|MB_ICONEXCLAMATION "Не удалось скачать Microsoft Edge WebView2. Без него окно Nimb не откроется. Подключитесь к интернету и запустите установку ещё раз."
    ${EndIf}
  ${EndIf}
FunctionEnd

Section "Nimb"
  SetRegView 64
  SetShellVarContext all

  ; An older Nimb that is running is stopped first: its files cannot be replaced while they are in use.
  nsExec::Exec 'taskkill /F /IM Nimb.exe'
  Pop $0
  ; The window was stopped on purpose, not by a crash: the mark of a running program that it left is taken away (the installer that runs
  ; elevated by the same person has the same %APPDATA%; the version in the mark covers the other cases).
  ReadEnvStr $R8 APPDATA
  ${If} $R8 != ""
    Delete "$R8\Nimb\session.marker"
  ${EndIf}
  nsExec::Exec 'sc stop NimbHelper'
  Pop $0
  Sleep 1500

  Call EnsureWebView2

  SetOutPath "$INSTDIR"
  File "${SRC}\Nimb.exe"
  File "${SRC}\nimb-svc.exe"
  File "${SRC}\wintun.dll"
  File "${SRC}\LICENSE"
  File "${SRC}\THIRD-PARTY-NOTICES.md"

  DetailPrint "Устанавливаю службу Nimb…"
  nsExec::ExecToLog '"$INSTDIR\nimb-svc.exe" install'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONSTOP "Не удалось установить службу Nimb (код $0). Без неё не будут работать DNS и туннель."
    Abort
  ${EndIf}

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortCut "$SMPROGRAMS\Nimb.lnk" "$INSTDIR\Nimb.exe" "" "$INSTDIR\Nimb.exe" 0

  WriteRegStr HKLM "Software\Nimb" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "DisplayName" "Nimb"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "Publisher" "Nimb"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "DisplayIcon" "$INSTDIR\Nimb.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "URLInfoAbout" "https://github.com/Dizrane/Nimb"
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb" "NoRepair" 1

  ; An update that the window started (it passes /relaunch): the window comes back, as the person had it.
  ${GetParameters} $R0
  ${GetOptions} $R0 "/relaunch" $R1
  ${IfNot} ${Errors}
    Call LaunchNimb
  ${EndIf}
SectionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext all

  nsExec::Exec 'taskkill /F /IM Nimb.exe'
  Pop $0

  ; 1. The service goes (it takes the tunnel down with it). 2. The DNS comes back, the account at Cloudflare is deleted, the
  ; folder of the service and the driver of the adapter are removed.
  DetailPrint "Останавливаю службу Nimb…"
  nsExec::ExecToLog '"$INSTDIR\nimb-svc.exe" uninstall'
  Pop $0
  DetailPrint "Возвращаю DNS и удаляю данные…"
  nsExec::ExecToLog '"$INSTDIR\nimb-svc.exe" cleanup'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "Не всё удалось вернуть (код $0). Если интернет работает странно, откройте Параметры → Сеть и интернет → ваше подключение → Назначение DNS-сервера и выберите «Автоматически (DHCP)»."
  ${EndIf}

  ; What Nimb left in the folders of the people of this computer, and the autostart of the person who is uninstalling.
  ReadEnvStr $R0 SystemDrive
  FindFirst $R2 $R1 "$R0\Users\*"
  ${While} $R1 != ""
    ${If} $R1 != "."
    ${AndIf} $R1 != ".."
      RMDir /r "$R0\Users\$R1\AppData\Roaming\Nimb"
      ; the cache of WebView2 of the builds before the window had its own folder for it
      RMDir /r "$R0\Users\$R1\AppData\Roaming\Nimb.exe"
    ${EndIf}
    FindNext $R2 $R1
  ${EndWhile}
  FindClose $R2
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Nimb"
  ; the same for every person who is logged in now (their registry is loaded under HKEY_USERS)
  StrCpy $R3 0
  ${Do}
    EnumRegKey $R4 HKU "" $R3
    ${If} $R4 == ""
      ${Break}
    ${EndIf}
    DeleteRegValue HKU "$R4\Software\Microsoft\Windows\CurrentVersion\Run" "Nimb"
    IntOp $R3 $R3 + 1
  ${Loop}

  Delete "$SMPROGRAMS\Nimb.lnk"
  Delete "$INSTDIR\Nimb.exe"
  Delete "$INSTDIR\nimb-svc.exe"
  Delete "$INSTDIR\wintun.dll"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\THIRD-PARTY-NOTICES.md"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Nimb"
  DeleteRegKey HKLM "Software\Nimb"
SectionEnd
