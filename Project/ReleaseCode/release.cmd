@echo off
setlocal
set "ROOT=%~dp0"
set "BUNDLED_PYTHON=%ROOT%..\..\Dependencies\Non-Packageable\Windows\python\python.exe"
if exist "%BUNDLED_PYTHON%" (
  "%BUNDLED_PYTHON%" "%ROOT%tool\release.py" %*
) else (
  python "%ROOT%tool\release.py" %*
)
exit /b %ERRORLEVEL%
