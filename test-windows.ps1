<#
Windows integration tests for timeout. Native Windows — no Git Bash needed.

Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\test-windows.ps1 [-Timeout .\timeout.exe]

Notes:
    - The timeout path must be explicit (default .\timeout.exe): a bare
      `timeout` resolves to C:\Windows\System32\timeout.exe (Windows builtin).
    - Long-running children are `cmd /c ping -n 60 127.0.0.1`: cmd exits on
      console control events, and the job object reaps the orphaned ping
      when timeout exits. If a child proves unkillable on first run, swap
      for: powershell -NoProfile -Command "Start-Sleep 60"

Windows-specific expectations:
    - numeric signals (-s 15) are rejected -> 125
    - timeout -> 124 regardless of console presence (graceful fallback)
    - explicit KILL (-s KILL) -> 137
#>

param(
    [string]$Timeout = ".\timeout.exe"
)

$g_timeout = $Timeout
$g_pass = 0
$g_fail = 0
$g_sleep = @('cmd', '/c', 'ping', '-n', '3', '127.0.0.1')
$g_start = Get-Date
Write-Host "== timeout windows test suite (expect ~20s) =="

function Assert-Exit {
    param([string]$desc, [string]$expected, $actual)
    if ("$expected" -eq "$actual") {
        $script:g_pass++
        Write-Host ("  ok   {0} (exit={1})" -f $desc, $actual)
    } else {
        $script:g_fail++
        Write-Host ("  FAIL {0} (expected {1}, got {2})" -f $desc, $expected, $actual)
    }
}

Write-Host "== exit codes =="

& $g_timeout 10 cmd /c exit 0
Assert-Exit "no timeout, exit 0" 0 $LASTEXITCODE

& $g_timeout 10 cmd /c exit 42
Assert-Exit "no timeout, exit 42" 42 $LASTEXITCODE

& $g_timeout 1 @g_sleep 2>$null
Assert-Exit "timeout -> 124" 124 $LASTEXITCODE

& $g_timeout 1 nonexistent-cmd-xyz 2>$null
Assert-Exit "not found -> 127" 127 $LASTEXITCODE

Write-Host "== -p preserve status =="

& $g_timeout -p 10 cmd /c exit 7
Assert-Exit "-p, no timeout, exit 7" 7 $LASTEXITCODE

Write-Host "== stdin inheritance =="

$b_result = ("pipe-test" | & $g_timeout 5 cmd /c sort).Trim()
if ($b_result -eq "pipe-test") {
    $script:g_pass++; Write-Host "  ok   stdin inherited"
} else {
    $script:g_fail++; Write-Host "  FAIL stdin inherited (got '$b_result')"
}

Write-Host "== 0 duration = no timeout =="

& $g_timeout 0 cmd /c "ping -n 2 127.0.0.1 >nul & exit 9"
Assert-Exit "0 duration, no timeout, exit 9" 9 $LASTEXITCODE

Write-Host "== duration parsing =="

& $g_timeout 0.5d cmd /c exit 3
Assert-Exit "0.5d parses, exit 3" 3 $LASTEXITCODE

& $g_timeout 1d cmd /c exit 5
Assert-Exit "1d parses, exit 5" 5 $LASTEXITCODE

& $g_timeout abc cmd /c exit 1 2>$null
Assert-Exit "invalid duration -> 125" 125 $LASTEXITCODE

& $g_timeout -k "-2" 1 cmd /c exit 1 2>$null
Assert-Exit "invalid kill delay -> 125" 125 $LASTEXITCODE

& $g_timeout -s "BOGUS" 1 cmd /c exit 1 2>$null
Assert-Exit "invalid signal -> 125" 125 $LASTEXITCODE

Write-Host "== -s named signals =="

& $g_timeout -s SIGTERM 1 @g_sleep 2>$null
Assert-Exit "-s SIGTERM -> 124" 124 $LASTEXITCODE

& $g_timeout -s sigint 1 @g_sleep 2>$null
Assert-Exit "-s sigint -> 124" 124 $LASTEXITCODE

& $g_timeout -s KILL 1 @g_sleep 2>$null
Assert-Exit "-s KILL -> 137" 137 $LASTEXITCODE

# Windows deviation: numeric signals are unsupported
& $g_timeout -s 15 1 @g_sleep 2>$null
Assert-Exit "-s 15 (numeric) -> 125 (unsupported on windows)" 125 $LASTEXITCODE

& $g_timeout -s 0 1 cmd /c exit 1 2>$null
Assert-Exit "-s 0 -> 125" 125 $LASTEXITCODE

& $g_timeout -s 200 1 cmd /c exit 1 2>$null
Assert-Exit "-s 200 -> 125" 125 $LASTEXITCODE

Write-Host "== -s and -k equals form =="

& $g_timeout -s=TERM 1 @g_sleep 2>$null
Assert-Exit "-s=TERM -> 124" 124 $LASTEXITCODE

& $g_timeout -s=KILL 1 @g_sleep 2>$null
Assert-Exit "-s=KILL -> 137" 137 $LASTEXITCODE

Write-Host "== negative duration =="

& $g_timeout -1 @g_sleep 2>$null
Assert-Exit "-1 duration -> 125" 125 $LASTEXITCODE

& $g_timeout -- -1 @g_sleep 2>$null
Assert-Exit "-- -1 duration -> 125" 125 $LASTEXITCODE

& $g_timeout -1.5d @g_sleep 2>$null
Assert-Exit "-1.5d duration -> 125" 125 $LASTEXITCODE

& $g_timeout -2s @g_sleep 2>$null
Assert-Exit "-2s duration -> 125" 125 $LASTEXITCODE

Write-Host "== sub-second duration =="

& $g_timeout 0.1 @g_sleep 2>$null
Assert-Exit "0.1s -> 124" 124 $LASTEXITCODE

Write-Host "== usage / arg validation =="

& $g_timeout 2>$null
Assert-Exit "no args -> 125" 125 $LASTEXITCODE

& $g_timeout 10 2>$null
Assert-Exit "missing command -> 125" 125 $LASTEXITCODE

& $g_timeout -- 10 cmd /c exit 3
Assert-Exit "-- end of options" 3 $LASTEXITCODE

& $g_timeout --help *>$null
Assert-Exit "--help -> 0" 0 $LASTEXITCODE

& $g_timeout -h *>$null
Assert-Exit "-h -> 0" 0 $LASTEXITCODE

Write-Host "== long options =="

& $g_timeout --foreground 1 @g_sleep 2>$null
Assert-Exit "--foreground -> 124" 124 $LASTEXITCODE

& $g_timeout --preserve-status 10 cmd /c exit 7 2>$null
Assert-Exit "--preserve-status, no timeout -> 7" 7 $LASTEXITCODE

& $g_timeout --signal=TERM 1 @g_sleep 2>$null
Assert-Exit "--signal=TERM -> 124" 124 $LASTEXITCODE

& $g_timeout --signal KILL 1 @g_sleep 2>$null
Assert-Exit "--signal KILL -> 137" 137 $LASTEXITCODE

Write-Host "== combined short flags =="

& $g_timeout -fp 10 cmd /c exit 3 2>$null
Assert-Exit "-fp (foreground+preserve) -> 3" 3 $LASTEXITCODE

& $g_timeout -fsKILL 1 @g_sleep 2>$null
Assert-Exit "-fsKILL (foreground+signal=KILL) -> 137" 137 $LASTEXITCODE

Write-Host "== verbose =="

$b_out = (& $g_timeout --verbose 1 @g_sleep 2>&1 | Out-String)
if ($b_out -match 'sending signal TERM') {
    $script:g_pass++; Write-Host "  ok   --verbose prints signal sent"
} else {
    $script:g_fail++; Write-Host "  FAIL --verbose should print signal sent (got: $b_out)"
}

Write-Host "== version =="

& $g_timeout --version *>$null
Assert-Exit "--version -> 0" 0 $LASTEXITCODE

$b_out = (& $g_timeout --version 2>&1 | Out-String)
if ($b_out -match 'timeout') {
    $script:g_pass++; Write-Host "  ok   --version output contains 'timeout'"
} else {
    $script:g_fail++; Write-Host "  FAIL --version output should contain 'timeout' (got: $b_out)"
}

& $g_timeout -V *>$null
Assert-Exit "-V -> 0" 0 $LASTEXITCODE

# --- summary ---

Write-Host ""
Write-Host "=============================="
Write-Host ("  {0} passed, {1} failed  ({2:N1}s)" -f $g_pass, $g_fail, ((Get-Date) - $g_start).TotalSeconds)
Write-Host "=============================="

if ($g_fail -gt 0) { exit 1 } else { exit 0 }
