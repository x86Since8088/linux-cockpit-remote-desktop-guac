@echo off
REM deploy.bat - a thin wrapper, and nothing else.
REM
REM It exists so an operator can double-click, and it contains no logic:
REM logic in two languages is logic that diverges. deploy.ps1 says everything.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
exit /b %ERRORLEVEL%
