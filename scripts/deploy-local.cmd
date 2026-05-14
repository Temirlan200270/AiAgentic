@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-local.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
  echo Local deploy failed with exit code %EXIT_CODE%.
) else (
  echo Local deploy finished successfully.
)
echo Press any key to close...
pause >nul
exit /b %EXIT_CODE%
