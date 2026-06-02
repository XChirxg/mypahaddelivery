@echo off
cd /d "%~dp0"

set /p msg=Commit message:

git add .
git commit -m "%msg%"
git push

pause
