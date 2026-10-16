@echo off
rem ===========================================================================
rem  run-jmeter.bat - run one JMeter test plan in non-GUI mode on Windows.
rem
rem  Usage (CMD, from anywhere):
rem      scripts\run-jmeter.bat smoke
rem      scripts\run-jmeter.bat regression
rem
rem  Settings come from ENVIRONMENT VARIABLES so that Jenkins parameters (which
rem  Jenkins exports as environment variables) flow straight in. Defaults below.
rem
rem      JMETER_HOME   C:\tools\apache-jmeter-5.6.3   (required - where JMeter lives)
rem      JAVA_HOME     optional; if set, its bin is put FIRST on PATH for this run
rem      TARGET_ENV    local        -> loads config\env\%TARGET_ENV%.properties
rem      TARGET_HOST   (optional)   overrides host from the env file
rem      TARGET_PORT   (optional)   overrides port from the env file
rem      USERS         2            threads
rem      RAMP_UP       5            seconds
rem      DURATION      60           seconds (duration-based plans, e.g. regression)
rem      LOOPS         3            iterations (loop-based plans, e.g. smoke)
rem      THINK_MS      300          think time per request
rem      JMETER_HEAP   (optional)   e.g. 1g or 2g -> -Xms/-Xmx for this run
rem      RESULTS_DIR   <repo>\results\<test>
rem
rem  Exit codes: 0 = JMeter ran and produced results
rem              2 = configuration problem (paths, missing files)
rem              3 = JMeter ran but produced no usable results file
rem              other = JMeter's own exit code
rem  NOTE: exit code 0 does NOT mean "performance is good". JMeter exits 0 even when
rem  100% of samples fail. Use scripts\validate-jtl.ps1 for pass/fail decisions.
rem ===========================================================================
setlocal EnableExtensions

rem ---- 1. Work out where the repository is (this script lives in <repo>\scripts)
for %%I in ("%~dp0..") do set "REPO_ROOT=%%~fI"

rem ---- 2. Which test?  First argument, default "smoke"
set "TEST_NAME=%~1"
if "%TEST_NAME%"=="" set "TEST_NAME=smoke"

rem ---- 3. Defaults for anything Jenkins (or you) did not set
if not defined JMETER_HOME set "JMETER_HOME=C:\tools\apache-jmeter-5.6.3"
if not defined TARGET_ENV  set "TARGET_ENV=local"
if not defined USERS       set "USERS=2"
if not defined RAMP_UP     set "RAMP_UP=5"
if not defined DURATION    set "DURATION=60"
if not defined LOOPS       set "LOOPS=3"
if not defined THINK_MS    set "THINK_MS=300"
if not defined RESULTS_DIR set "RESULTS_DIR=%REPO_ROOT%\results\%TEST_NAME%"

set "TEST_PLAN=%REPO_ROOT%\tests\%TEST_NAME%\%TEST_NAME%-test.jmx"
set "CI_PROPS=%REPO_ROOT%\config\jmeter-ci.properties"
set "ENV_PROPS=%REPO_ROOT%\config\env\%TARGET_ENV%.properties"
set "JMETER_BAT=%JMETER_HOME%\bin\jmeter.bat"

rem ---- 4. jmeter.bat runs whatever "java" is first on PATH (it ignores JAVA_HOME).
rem         If JAVA_HOME is set, put it first so the run uses the Java we intended.
if defined JAVA_HOME (
    if exist "%JAVA_HOME%\bin\java.exe" (
        set "PATH=%JAVA_HOME%\bin;%PATH%"
    ) else (
        echo [run-jmeter] WARNING: "%JAVA_HOME%\bin\java.exe" not found - using java from PATH
    )
)

rem ---- 5. Optional heap override for this run only
if defined JMETER_HEAP set "HEAP=-Xms%JMETER_HEAP% -Xmx%JMETER_HEAP% -XX:MaxMetaspaceSize=256m"

rem ---- 6. Fail fast on configuration mistakes, with a message a beginner can act on
if not exist "%JMETER_BAT%" (
    echo [run-jmeter] ERROR: JMeter not found at "%JMETER_BAT%". Set JMETER_HOME correctly.
    exit /b 2
)
if not exist "%TEST_PLAN%" (
    echo [run-jmeter] ERROR: test plan not found: "%TEST_PLAN%"
    echo [run-jmeter]        Valid names are the folder names under tests\ ^(smoke, regression^).
    exit /b 2
)
if not exist "%ENV_PROPS%" (
    echo [run-jmeter] ERROR: no environment file "%ENV_PROPS%" for TARGET_ENV=%TARGET_ENV%
    exit /b 2
)
where java >nul 2>nul
if errorlevel 1 (
    echo [run-jmeter] ERROR: java.exe is not on PATH for user %USERNAME%. Install Java 21 or set JAVA_HOME.
    exit /b 2
)

rem ---- 7. Optional overrides of the env file
set "EXTRA_PROPS="
if defined TARGET_HOST set "EXTRA_PROPS=%EXTRA_PROPS% -Jhost=%TARGET_HOST%"
if defined TARGET_PORT set "EXTRA_PROPS=%EXTRA_PROPS% -Jport=%TARGET_PORT%"

rem ---- 8. Clean, repeatable output folder. JMeter refuses to write the HTML
rem         report into a non-empty folder, so we always start from nothing.
if exist "%RESULTS_DIR%" rmdir /s /q "%RESULTS_DIR%"
mkdir "%RESULTS_DIR%"
if errorlevel 1 (
    echo [run-jmeter] ERROR: cannot create "%RESULTS_DIR%" - is a file open in Explorer or a browser?
    exit /b 2
)

echo ============================================================
echo  JMeter run      : %TEST_NAME%
echo  Test plan       : %TEST_PLAN%
echo  Environment     : %TARGET_ENV%  (%ENV_PROPS%)
echo  Load            : users=%USERS% rampup=%RAMP_UP%s duration=%DURATION%s loops=%LOOPS% thinkMs=%THINK_MS%
echo  Overrides       : %EXTRA_PROPS%
echo  Results folder  : %RESULTS_DIR%
echo  Running as      : %USERDOMAIN%\%USERNAME% on %COMPUTERNAME%
echo  Java on PATH    :
where java
java -version 2>&1
echo ============================================================

rem ---- 9. Run JMeter.
rem   call   - required to run another .bat and come back to this script
rem   -n     - non-GUI mode           -t - test plan        -l - results (JTL)
rem   -j     - JMeter's own log       -e -o - HTML dashboard into an EMPTY folder
rem   -q     - extra property files (CI settings, then the environment)
rem   -J     - single properties; they are applied after -q, so they win
rem   < NUL  - jmeter.bat ends with "pause" on errors; NUL stdin stops a console
rem            run from waiting for a key press (Jenkins has no keyboard either)
call "%JMETER_BAT%" -n ^
  -t "%TEST_PLAN%" ^
  -q "%CI_PROPS%" ^
  -q "%ENV_PROPS%" ^
  -l "%RESULTS_DIR%\results.jtl" ^
  -j "%RESULTS_DIR%\jmeter.log" ^
  -e -o "%RESULTS_DIR%\html-report" ^
  -Jusers=%USERS% -Jrampup=%RAMP_UP% -Jduration=%DURATION% -Jloops=%LOOPS% -JthinkMs=%THINK_MS% ^
  %EXTRA_PROPS% < NUL
set "JMETER_RC=%ERRORLEVEL%"

echo [run-jmeter] JMeter exit code: %JMETER_RC%
if not "%JMETER_RC%"=="0" (
    echo [run-jmeter] JMeter itself failed. Read "%RESULTS_DIR%\jmeter.log" - the first ERROR line is usually the cause.
    exit /b %JMETER_RC%
)

rem ---- 10. A run that wrote no samples is a broken run, even with exit code 0
if not exist "%RESULTS_DIR%\results.jtl" (
    echo [run-jmeter] ERROR: no results.jtl was produced.
    exit /b 3
)
rem Full path on purpose: if Git's usr\bin is on PATH before System32, a bare "find" is GNU find,
rem which ignores these switches and starts walking the whole C: drive.
for /f %%C in ('type "%RESULTS_DIR%\results.jtl" ^| "%SystemRoot%\System32\find.exe" /c /v ""') do set "JTL_LINES=%%C"
if %JTL_LINES% LSS 2 (
    echo [run-jmeter] ERROR: results.jtl has no samples - did any thread start? Check users/duration.
    exit /b 3
)

set /a SAMPLES=%JTL_LINES%-1
echo [run-jmeter] OK: %SAMPLES% samples written to %RESULTS_DIR%\results.jtl
echo [run-jmeter] HTML dashboard: %RESULTS_DIR%\html-report\index.html
endlocal & exit /b 0
