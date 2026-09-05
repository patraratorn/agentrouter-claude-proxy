<#
    run-tests.ps1 -- run the full compatibility suite against a mock upstream.

    Nothing here touches the real AgentRouter service, a real credential, or a
    proxy you may already have running on 8787. A mock upstream and a throwaway
    proxy instance are started on isolated ports and torn down afterwards.

    Usage:
      .\tests\run-tests.ps1
      .\tests\run-tests.ps1 -MockPort 9788 -ProxyPort 9789
#>

[CmdletBinding()]
param(
    [int]$MockPort  = 8788,
    [int]$ProxyPort = 8789
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

function Test-PortFree {
    param([int]$P)
    try {
        $c = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
        return -not $c
    } catch { return $true }
}

foreach ($p in @($MockPort, $ProxyPort)) {
    if (-not (Test-PortFree -P $p)) {
        Write-Host "[fail ] port $p is already in use. Pick another with -MockPort / -ProxyPort." -ForegroundColor Red
        exit 2
    }
}

$venvPython = Join-Path $root '.venv\Scripts\python.exe'
if (Test-Path $venvPython) {
    $python = $venvPython
} else {
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { $python = (Get-Command py -ErrorAction SilentlyContinue).Source }
    if (-not $python) {
        Write-Host '[fail ] No Python interpreter found. Install Python 3.10+ and re-run.' -ForegroundColor Red
        exit 1
    }
}

Write-Host "[test ] interpreter : $(& $python --version 2>&1)" -ForegroundColor Cyan
Write-Host "[test ] mock  upstream on 127.0.0.1:$MockPort" -ForegroundColor Cyan
Write-Host "[test ] proxy under test on 127.0.0.1:$ProxyPort" -ForegroundColor Cyan

$mockProc = $null
$proxyProc = $null
$exitCode = 1

try {
    # ---- 1. syntax check -------------------------------------------------
    Write-Host "`n[test ] compiling sources" -ForegroundColor Cyan
    & $python -m py_compile (Join-Path $root 'proxy.py') `
                            (Join-Path $here 'mock_upstream.py') `
                            (Join-Path $here 'scenario_tests.py') `
                            (Join-Path $here 'disconnect_test.py')
    if ($LASTEXITCODE -ne 0) { throw 'py_compile failed' }
    Write-Host '[ ok  ] all sources compile' -ForegroundColor Green

    # ---- 1b. PowerShell scripts: parse + scheduled-task enum values -------
    # Static only: nothing is registered and no existing task is touched.
    # The principal's LogonType value "InteractiveToken" (issue #1) parsed
    # fine but was rejected at runtime by the ScheduledTasks module, so
    # install-autostart.ps1 failed at the point of use. Check every
    # enum-valued argument against the live enum instead.
    Write-Host "`n[test ] validating PowerShell scripts" -ForegroundColor Cyan
    $psFiles = @(Get-ChildItem -Path $root -Filter '*.ps1' -File) +
               @(Get-ChildItem -Path $here -Filter '*.ps1' -File)
    foreach ($f in $psFiles) {
        $perrs = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $f.FullName, [ref]$null, [ref]$perrs) | Out-Null
        if ($perrs) { throw "$($f.Name): $($perrs[0].Message)" }
    }
    Write-Host "[ ok  ] $($psFiles.Count) PowerShell scripts parse cleanly" -ForegroundColor Green

    $enumParams = @{
        LogonType = 'New-ScheduledTaskPrincipal'
        RunLevel  = 'New-ScheduledTaskPrincipal'
    }
    $checked = 0
    foreach ($param in $enumParams.Keys) {
        $cmd = Get-Command $enumParams[$param] -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }   # module unavailable: skip, do not fail
        $valid = [enum]::GetNames($cmd.Parameters[$param].ParameterType)
        foreach ($f in $psFiles) {
            foreach ($m in ([regex]"-$param\s+([A-Za-z]+)").Matches(
                            (Get-Content $f.FullName -Raw))) {
                $used = $m.Groups[1].Value
                if ($valid -notcontains $used) {
                    throw ("$($f.Name): -$param $used is not a valid value on " +
                           "this system. Valid: $($valid -join ', ')")
                }
                $checked++
            }
        }
    }
    Write-Host "[ ok  ] $checked scheduled-task enum arguments valid on this system" -ForegroundColor Green

    # ---- 1c. autostart scripts: principal, read-back, downgrade detection ---
    # Deterministic and side-effect free: no task is registered or modified.
    Write-Host "`n[test ] autostart script tests" -ForegroundColor Cyan
    & (Join-Path $here 'autostart-tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'autostart tests failed' }

    # ---- 2. start the mock upstream --------------------------------------
    $mockProc = Start-Process -FilePath $python -PassThru -WindowStyle Hidden `
        -WorkingDirectory $here `
        -ArgumentList @('-m', 'uvicorn', 'mock_upstream:app',
                        '--host', '127.0.0.1', '--port', "$MockPort",
                        '--log-level', 'warning', '--no-access-log')

    # ---- 3. start the proxy pointed at the mock --------------------------
    $env:AGENTROUTER_UPSTREAM = "http://127.0.0.1:$MockPort"
    $env:PROXY_PORT           = "$ProxyPort"
    # Keep the suite quick: the timeout scenarios do not need 120s to prove.
    $env:PROXY_PRIME_TIMEOUT_S = '10'
    $env:PROXY_STREAM_MODE     = 'normal'

    $proxyProc = Start-Process -FilePath $python -PassThru -WindowStyle Hidden `
        -WorkingDirectory $root `
        -ArgumentList @('-m', 'uvicorn', 'proxy:app',
                        '--host', '127.0.0.1', '--port', "$ProxyPort",
                        '--log-level', 'warning', '--no-access-log')

    # ---- 4. wait for both to answer --------------------------------------
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $h = Invoke-RestMethod "http://127.0.0.1:$ProxyPort/_health" -TimeoutSec 3 -ErrorAction Stop
            Invoke-RestMethod "http://127.0.0.1:$MockPort/_mock_stats" -TimeoutSec 3 -ErrorAction Stop | Out-Null
            if ($h.status -eq 'ok') { $ready = $true; break }
        } catch { }
    }
    if (-not $ready) { throw "proxy or mock did not become ready on 127.0.0.1:$ProxyPort / :$MockPort" }

    $health = Invoke-RestMethod "http://127.0.0.1:$ProxyPort/_health" -TimeoutSec 5
    Write-Host "[ ok  ] /_health -> status=$($health.status) listen=$($health.listen) upstream=$($health.upstream)" -ForegroundColor Green

    if ($health.listen -ne "127.0.0.1:$ProxyPort") {
        throw "proxy reports listen=$($health.listen) -- expected loopback 127.0.0.1:$ProxyPort"
    }

    # ---- 5. confirm the listener is loopback-only ------------------------
    $bound = Get-NetTCPConnection -LocalPort $ProxyPort -State Listen -ErrorAction SilentlyContinue
    $addrs = @($bound | Select-Object -ExpandProperty LocalAddress -Unique)
    if ($addrs -contains '0.0.0.0' -or $addrs -contains '::') {
        throw "proxy is bound to $($addrs -join ', ') -- expected 127.0.0.1 only"
    }
    Write-Host "[ ok  ] bound to $($addrs -join ', ') only (not 0.0.0.0)" -ForegroundColor Green

    $env:TEST_PROXY_URL = "http://127.0.0.1:$ProxyPort"
    $env:TEST_MOCK_URL  = "http://127.0.0.1:$MockPort"

    # ---- 6. scenario suite -----------------------------------------------
    Write-Host "`n[test ] scenario suite" -ForegroundColor Cyan
    & $python (Join-Path $here 'scenario_tests.py')
    $scenarioExit = $LASTEXITCODE

    # ---- 7. client disconnect --------------------------------------------
    Write-Host "`n[test ] client disconnect handling" -ForegroundColor Cyan
    & $python (Join-Path $here 'disconnect_test.py')
    $disconnectExit = $LASTEXITCODE

    # Reliable mode runs in a second isolated proxy process so the legacy suite
    # above remains an explicit normal-mode regression check.
    $reliablePort = $ProxyPort + 1
    if (-not (Test-PortFree -P $reliablePort)) { throw "port $reliablePort is already in use" }
    $env:PROXY_PORT = "$reliablePort"
    $env:PROXY_STREAM_MODE = 'reliable'
    $env:PROXY_RELIABLE_MAX_BYTES = '4096'
    $reliableProc = Start-Process -FilePath $python -PassThru -WindowStyle Hidden `
        -WorkingDirectory $root `
        -ArgumentList @('-m', 'uvicorn', 'proxy:app', '--host', '127.0.0.1',
                        '--port', "$reliablePort", '--log-level', 'warning', '--no-access-log')
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $h = Invoke-RestMethod "http://127.0.0.1:$reliablePort/_health" -TimeoutSec 3 -ErrorAction Stop
            if ($h.status -eq 'ok') { break }
        } catch { }
    }
    $env:TEST_RELIABLE_PROXY_URL = "http://127.0.0.1:$reliablePort"
    Write-Host "`n[test ] reliable stream suite" -ForegroundColor Cyan
    & $python (Join-Path $here 'reliable_tests.py')
    $reliableExit = $LASTEXITCODE

    # ---- 8. counters ------------------------------------------------------
    Write-Host "`n[test ] /_stats" -ForegroundColor Cyan
    $st = Invoke-RestMethod "http://127.0.0.1:$ProxyPort/_stats" -TimeoutSec 10
    $st | ConvertTo-Json -Depth 3 | Write-Host

    if ($scenarioExit -eq 0 -and $disconnectExit -eq 0 -and $reliableExit -eq 0) {
        Write-Host "`n[ ok  ] ALL TESTS PASSED" -ForegroundColor Green
        $exitCode = 0
    } else {
        Write-Host "`n[fail ] scenario=$scenarioExit disconnect=$disconnectExit reliable=$reliableExit" -ForegroundColor Red
        $exitCode = 1
    }
}
catch {
    Write-Host "[fail ] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    # Only ever stops the two processes this script started itself.
    foreach ($p in @($reliableProc, $proxyProc, $mockProc)) {
        if ($p -and -not $p.HasExited) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    Remove-Item Env:AGENTROUTER_UPSTREAM, Env:PROXY_PORT, Env:PROXY_PRIME_TIMEOUT_S, `
                 Env:TEST_PROXY_URL, Env:TEST_MOCK_URL, Env:TEST_RELIABLE_PROXY_URL, `
                 Env:PROXY_STREAM_MODE, Env:PROXY_RELIABLE_MAX_BYTES -ErrorAction SilentlyContinue
}

exit $exitCode
