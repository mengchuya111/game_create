@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo.
echo   正在启动监管打卡 App...
echo.

REM 等服务器起来再开浏览器，否则会打开一个"无法访问"的页面
start "" /b cmd /c "timeout /t 2 >nul & start http://localhost:8080"

node server.js

REM 服务异常退出时别让窗口一闪而过，好让人看到错误
echo.
echo   服务已停止。按任意键关闭窗口。
pause >nul
