; Dwn's additions to electron-builder's NSIS installer (included automatically
; from build/installer.nsh).

; Always install for the current user, in the same place the old one-click
; installer used (%LOCALAPPDATA%\Programs\dwn): no "for me / for everyone"
; page and no administrator prompt.
!macro customInstallMode
  StrCpy $isForceCurrentInstall "1"
!macroend

; The last page of a first install: say Dwn is installed and offer to run it.
; Auto-updates run silently (/S), never see this page, and are restarted by
; the installer's --force-run instead.
!macro customFinishPage
  Function DwnRunAfterFinish
    ${if} ${isUpdated}
      StrCpy $1 "--updated"
    ${else}
      StrCpy $1 ""
    ${endif}
    ${StdUtils.ExecShellAsUser} $0 "$launchLink" "open" "$1"
  FunctionEnd

  !define MUI_FINISHPAGE_TITLE "Dwn is installed"
  !define MUI_FINISHPAGE_TEXT "Dwn is ready to use. You'll find it in the Start menu and on your desktop.$\r$\n$\r$\nClick Finish to close this window."
  !define MUI_FINISHPAGE_RUN
  !define MUI_FINISHPAGE_RUN_TEXT "Run Dwn"
  !define MUI_FINISHPAGE_RUN_FUNCTION "DwnRunAfterFinish"
  !insertmacro MUI_PAGE_FINISH
!macroend
