@echo off
rem Gears of War: E-Day - offline campaign (OfflineCampaign mod).
rem UE4SS is enabled only for this session; a normal Steam launch stays clean.
setlocal
cd /d "%~dp0FairlightConcept\Binaries\Win64"
set "SteamAppId=3010850"
set "SteamGameId=3010850"
set "EOS_USE_ANTICHEATCLIENTNULL=1"
set "GOWEDAY_OFFLINE=1"

set "ACTIVATED="
if not exist "dwmapi.dll" if exist "ue4ss\dwmapi.dll.offline" (
    copy /y "ue4ss\dwmapi.dll.offline" "dwmapi.dll" >nul && set "ACTIVATED=1"
)

start "" /wait "GoWEDay-Steam.exe" %*

if defined ACTIVATED del /q "dwmapi.dll"
endlocal
