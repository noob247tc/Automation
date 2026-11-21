@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Automation - Playwright Setup and Runner

echo.
echo ==========================================
echo   Automation - Setup and Playwright Runner
echo ==========================================
echo.

set "ROOT=%~dp0"
set "PROJECT_DIR=%ROOT%Automation"
set "REPO=https://github.com/christianmartincabucos/Automation.git"

REM --- Check/install Git ---
call :find_git
if not defined GIT_EXE (
    echo [INFO] Git is not installed. Attempting to install Git...
    where winget >nul 2>nul
    if not errorlevel 1 (
        winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements
    ) else (
        echo [INFO] winget not found. Downloading Git for Windows installer...
        powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:TEMP 'Git-Setup.exe'; Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/latest/download/Git-64-bit.exe' -OutFile $p; Start-Process -FilePath $p -ArgumentList '/VERYSILENT','/NORESTART' -Wait"
    )
    call :refresh_path
    call :find_git
)
if not defined GIT_EXE (
    echo [ERROR] Git installation could not be completed or Git was not found.
    echo Install Git manually from https://git-scm.com/download/win and rerun this file.
    goto :fail
)
echo [OK] Git found: !GIT_EXE!

REM --- Clone/update repository ---
if exist "%PROJECT_DIR%\.git" (
    echo [INFO] Repository already exists. Updating it...
    "!GIT_EXE!" -C "%PROJECT_DIR%" pull
    if errorlevel 1 (
        echo [ERROR] git pull failed.
        goto :fail
    )
) else (
    if exist "%PROJECT_DIR%" (
        echo [WARN] "%PROJECT_DIR%" exists but is not a Git repository.
        echo Rename or remove that folder, then run this script again.
        goto :fail
    )
    echo [INFO] Cloning repository...
    "!GIT_EXE!" clone "%REPO%" "%PROJECT_DIR%"
    if errorlevel 1 (
        echo [ERROR] git clone failed.
        goto :fail
    )
)
cd /d "%PROJECT_DIR%"
if errorlevel 1 goto :fail

REM --- Check/install Node.js and npm ---
call :find_node
if not defined NODE_EXE (
    echo [INFO] Node.js is not installed. Attempting to install the current LTS...
    where winget >nul 2>nul
    if not errorlevel 1 (
        winget install --id OpenJS.NodeJS.LTS -e --source winget --silent --accept-package-agreements --accept-source-agreements
    ) else (
        echo [INFO] winget not found. Downloading the official Node.js LTS MSI...
        powershell -NoProfile -ExecutionPolicy Bypass -Command "$arch=if([Environment]::Is64BitOperatingSystem){'x64'}else{'x86'}; if($env:PROCESSOR_ARCHITECTURE -match 'ARM64'){$arch='arm64'}; $releases=Invoke-RestMethod 'https://nodejs.org/dist/index.json'; $v=($releases | Where-Object {$_.lts -ne $false} | Select-Object -First 1).version; $file='node-'+$v+'-'+$arch+'.msi'; $url='https://nodejs.org/dist/'+$v+'/'+$file; $p=Join-Path $env:TEMP $file; Invoke-WebRequest -Uri $url -OutFile $p; Start-Process msiexec.exe -ArgumentList '/i',('""'+$p+'""'),'/qn','/norestart' -Wait"
    )
    call :refresh_path
    call :find_node
)
if not defined NODE_EXE (
    echo [ERROR] Node.js installation could not be completed or Node was not found.
    echo Install Node.js LTS manually from https://nodejs.org/ and rerun this file.
    goto :fail
)
call :find_npm
if not defined NPM_CMD (
    echo [ERROR] npm was not found after Node.js installation.
    goto :fail
)
echo [OK] Node.js: !NODE_EXE!
echo [OK] npm: !NPM_CMD!

REM --- Install dependencies ---
echo.
echo [INFO] Running npm install...
call "!NPM_CMD!" install
if errorlevel 1 (
    echo [ERROR] npm install failed.
    goto :fail
)

REM --- Install Playwright browsers ---
echo.
echo [INFO] Installing Playwright browsers...
call npx playwright install
if errorlevel 1 (
    echo [WARN] npm exec Playwright install failed. Trying npx...
    call npx playwright install
    if errorlevel 1 (
        echo [ERROR] Playwright browser installation failed.
        goto :fail
    )
)

REM --- Run tests ---
echo.
echo [INFO] Starting Playwright tests...
call "%PROJECT_DIR%\node_modules\.bin\playwright.cmd" test
set "TEST_EXIT=%ERRORLEVEL%"

echo.
if "%TEST_EXIT%"=="0" (
    echo ==========================================
    echo   Playwright tests completed successfully.
    echo ==========================================
) else (
    echo ==========================================
    echo   Playwright tests finished with errors.
    echo   Exit code: %TEST_EXIT%
    echo ==========================================
)

echo.
pause
exit /b %TEST_EXIT%

:find_git
set "GIT_EXE="
for %%G in (git.exe) do set "GIT_EXE=%%~$PATH:G"
if not defined GIT_EXE if exist "%ProgramFiles%\Git\cmd\git.exe" set "GIT_EXE=%ProgramFiles%\Git\cmd\git.exe"
if not defined GIT_EXE if exist "%ProgramFiles%\Git\bin\git.exe" set "GIT_EXE=%ProgramFiles%\Git\bin\git.exe"
if not defined GIT_EXE if exist "%LocalAppData%\Programs\Git\cmd\git.exe" set "GIT_EXE=%LocalAppData%\Programs\Git\cmd\git.exe"
exit /b

:find_node
set "NODE_EXE="
for %%N in (node.exe) do set "NODE_EXE=%%~$PATH:N"
if not defined NODE_EXE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE_EXE=%ProgramFiles%\nodejs\node.exe"
if not defined NODE_EXE if exist "%LocalAppData%\Programs\nodejs\node.exe" set "NODE_EXE=%LocalAppData%\Programs\nodejs\node.exe"
exit /b

:find_npm
set "NPM_CMD="
for %%N in (npm.cmd) do set "NPM_CMD=%%~$PATH:N"
if not defined NPM_CMD if exist "%ProgramFiles%\nodejs\npm.cmd" set "NPM_CMD=%ProgramFiles%\nodejs\npm.cmd"
if not defined NPM_CMD if exist "%LocalAppData%\Programs\nodejs\npm.cmd" set "NPM_CMD=%LocalAppData%\Programs\nodejs\npm.cmd"
exit /b

:refresh_path
REM Refresh PATH for this running batch process after installer changes.
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')"` ) do set "PATH=%%P;%PATH%"
exit /b

:fail
echo.
echo ==========================================
echo   Setup or execution failed.
echo   Review the error above.
echo ==========================================
echo.
pause
exit /b 1
