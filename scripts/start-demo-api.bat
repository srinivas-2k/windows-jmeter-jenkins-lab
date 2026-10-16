@echo off
rem ===========================================================================
rem  start-demo-api.bat - start the ShopLite API (the system under test) in this window.
rem
rem  Usage:   scripts\start-demo-api.bat            (port 8081)
rem           scripts\start-demo-api.bat 9090       (custom port)
rem
rem  Needs only Java 21 on PATH (or JAVA_HOME). Java runs the single .java file directly
rem  ("source-file mode", Java 11+), so there is nothing to compile or build.
rem  Stop it with Ctrl+C.
rem
rem  Firewall: to call it from ANOTHER machine, allow TCP 8081 inbound on this machine:
rem    PowerShell (admin): New-NetFirewallRule -DisplayName "ShopLite API (lab)" -Direction Inbound ^
rem                         -Protocol TCP -LocalPort 8081 -RemoteAddress LocalSubnet -Action Allow
rem ===========================================================================
setlocal
set "PORT=%~1"
if "%PORT%"=="" set "PORT=8081"
if defined JAVA_HOME if exist "%JAVA_HOME%\bin\java.exe" set "PATH=%JAVA_HOME%\bin;%PATH%"
java "%~dp0..\demo-app\ShopLiteApi.java" --port %PORT%
