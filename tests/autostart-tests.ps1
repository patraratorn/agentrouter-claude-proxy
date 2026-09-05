<#
    autostart-tests.ps1 -- deterministic tests for the autostart scripts.

    Everything here is static: files are parsed with the PowerShell AST and
    the installer's verification function is unit-tested against synthetic
    task objects. No scheduled task is registered, read, or modified, and no
    existing task (such as the live AgentRouterProxy) is touched.

    Usage (normally invoked by run-tests.ps1):
      .\tests\autostart-tests.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$root   = Split-Path -Parent $here

$installer   = Join-Path $root 'install-autostart.ps1'
$uninstaller = Join-Path $root 'uninstall-autostart.ps1'

$script:failures = 0

function Pass {
    param([string]$What)
    Write-Host "[ ok  ] $What" -ForegroundColor Green
}
function Fail {
    param([string]$What)
    $script:failures++
    Write-Host "[fail ] $What" -ForegroundColor Red
}
function Assert-True {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Pass $What } else { Fail $What }
}

function Get-CommandAsts {
    # All CommandAsts in a parsed script, so callers can filter by name.
    param($Ast)
    return @($Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true))
}

# --- parse both scripts once ------------------------------------------------

$parseErrors = $null
$instAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $installer, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { Fail "install-autostart.ps1 has parse errors"; exit 1 }
$parseErrors = $null
$uninstAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $uninstaller, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { Fail "uninstall-autostart.ps1 has parse errors"; exit 1 }
$instText   = Get-Content $installer -Raw
$uninstText = Get-Content $uninstaller -Raw
Pass 'installer and uninstaller parse cleanly'

$instCommands   = Get-CommandAsts $instAst
$uninstCommands = Get-CommandAsts $uninstAst

# --- 1. principal configuration ---------------------------------------------

$principalCalls = @($instCommands | Where-Object { $_.GetCommandName() -eq 'New-ScheduledTaskPrincipal' })

if ($principalCalls.Count -ne 1) {
    Fail "expected exactly 1 New-ScheduledTaskPrincipal call, found $($principalCalls.Count)"
} else {
    $logonType = $runLevel = $userId = $null
    $elems = @($principalCalls[0].CommandElements)
    for ($i = 0; $i -lt $elems.Count; $i++) {
        if ($elems[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
            # "-Name value" is parsed as two elements: the parameter and the
            # expression that follows it.
            $val = if ($i + 1 -lt $elems.Count) { "$($elems[$i + 1].Extent.Text)" } else { $null }
            switch ($elems[$i].ParameterName) {
                'LogonType' { $logonType = $val }
                'RunLevel'  { $runLevel  = $val }
                'UserId'    { $userId    = $val }
            }
        }
    }
    Assert-True ($logonType -eq 'Interactive') 'principal LogonType is Interactive (logged-in autostart, the documented semantics)'
    Assert-True ($runLevel -eq 'Limited') 'principal RunLevel is Limited (no elevation)'
    Assert-True ($userId -eq '$account') 'principal UserId is the runtime-resolved $account, not a hardcoded name'

    # No other logon type may appear anywhere in the installer: S4U would
    # promise logged-off startup this project intentionally does not offer.
    foreach ($wrong in 'S4U', 'Password', 'ServiceAccount', 'InteractiveToken', 'Group') {
        Assert-True ($instText -notmatch "-LogonType\s+$wrong") "installer never requests -LogonType $wrong"
    }
}

# --- 2. trigger, defaults, and command line stay intact ----------------------

$triggerOk = [bool](@($instCommands |
    Where-Object { $_.GetCommandName() -eq 'New-ScheduledTaskTrigger' } |
    Where-Object {
        @($_.CommandElements | ForEach-Object { "$($_.Extent.Text)" }) -contains '-AtLogOn'
    }).Count -gt 0)
Assert-True $triggerOk 'trigger is -AtLogOn (start when the user logs in)'

$paramBlock = $instAst.ParamBlock
function Get-ParamDefault {
    param([string]$Name)
    foreach ($p in $paramBlock.Parameters) {
        if ("$($p.Name.Extent.Text)" -eq "`$$Name") {
            return "$($p.DefaultValue.Extent.Text)"
        }
    }
    return $null
}
Assert-True ((Get-ParamDefault 'TaskName') -eq "'AgentRouterProxy'") "default task name is still 'AgentRouterProxy'"
Assert-True ((Get-ParamDefault 'Port') -eq '8787') 'default port is still 8787'
Assert-True ($instText -match [regex]::Escape("Join-Path `$root 'start-proxy.ps1'")) 'task still launches start-proxy.ps1 from the repo root'
Assert-True ($instText -match '-Service -Port \{1\} -MaxLogKB \{2\}') 'task command line still passes -Service -Port <port> -MaxLogKB'

# --- 3. registration is scoped to the named task -----------------------------

function Test-TaskScopedCall {
    param($Commands, [string]$CmdletName, [string]$What)
    $calls = @($Commands | Where-Object { $_.GetCommandName() -eq $CmdletName })
    if ($calls.Count -eq 0) { Fail "$What -- no $CmdletName call found"; return }
    $allScoped = $true
    foreach ($c in $calls) {
        $elems = @($c.CommandElements | ForEach-Object { "$($_.Extent.Text)" })
        if ($elems -notcontains '-TaskName') { $allScoped = $false }
    }
    Assert-True $allScoped $What
}
Test-TaskScopedCall -Commands $instCommands -CmdletName 'Register-ScheduledTask' -What 'every Register-ScheduledTask is scoped by -TaskName'
Test-TaskScopedCall -Commands $instCommands -CmdletName 'Get-ScheduledTask'      -What 'every Get-ScheduledTask in the installer is scoped by -TaskName'
Test-TaskScopedCall -Commands $uninstCommands -CmdletName 'Unregister-ScheduledTask' -What 'uninstaller only unregisters the named task'
Test-TaskScopedCall -Commands $uninstCommands -CmdletName 'Stop-ScheduledTask'  -What 'uninstaller only stops the named task'
Assert-True ($uninstText -notmatch 'Unregister-ScheduledTask\s+(?!-TaskName)') 'uninstaller never unregisters an unnamed task'

# --- 4. read-back verification and no false success ---------------------------

$registerCall = @($instCommands | Where-Object { $_.GetCommandName() -eq 'Register-ScheduledTask' }) |
    Select-Object -First 1
if (-not $registerCall) {
    Fail 'no Register-ScheduledTask call found in installer'
} else {
    $regOffset = $registerCall.Extent.StartOffset

    # A Get-ScheduledTask read-back must exist AFTER registration.
    $readBack = @($instCommands |
        Where-Object { $_.GetCommandName() -eq 'Get-ScheduledTask' -and $_.Extent.StartOffset -gt $regOffset })
    Assert-True ($readBack.Count -ge 1) 'task is read back with Get-ScheduledTask after Register-ScheduledTask'

    if ($readBack.Count -ge 1) {
        $readBackOffset = ($readBack | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1).Extent.StartOffset

        # The green "registered" message must come only AFTER verification.
        $okIdx = $instText.IndexOf("registered scheduled task", [StringComparison]::Ordinal)
        Assert-True ($okIdx -gt $readBackOffset) 'success message is printed only after the read-back'

        # Between read-back and success message there must be a failure exit,
        # and the expected values must be the Interactive/Limited principal.
        $verifySlice = $instText.Substring($readBackOffset, $okIdx - $readBackOffset)
        Assert-True ($verifySlice -match 'exit\s+1') 'a principal mismatch exits 1 instead of reporting success'
        Assert-True ($verifySlice -match "-ExpectedLogonType\s+'Interactive'") 'read-back expects LogonType Interactive'
        Assert-True ($verifySlice -match "-ExpectedRunLevel\s+'Limited'") 'read-back expects RunLevel Limited'
        Assert-True ($verifySlice -match '-ExpectedUser\s+\$account') 'read-back expects the runtime-resolved account'
        Assert-True ($verifySlice -match 'Get-TaskPrincipalProblems') 'read-back routes through Get-TaskPrincipalProblems'
    }
}

# --- 5. no elevation requirement ----------------------------------------------

Assert-True ($instText -notmatch '#requires\s+-runasadministrator') 'installer does not require elevation (Interactive needs none)'

# --- 6. unit-test the verification function with synthetic tasks --------------

$fnAsts = @($instAst.FindAll({
    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
              $n.Name -eq 'Get-TaskPrincipalProblems'
}, $true))
if ($fnAsts.Count -ne 1) {
    Fail "Get-TaskPrincipalProblems function not found or duplicated (found $($fnAsts.Count))"
} else {
    Pass 'Get-TaskPrincipalProblems found'
    # The extracted text is a function definition: dot-source it into this
    # scope so the function becomes callable, then test it in isolation.
    $fnBlock = [scriptblock]::Create($fnAsts[0].Extent.Text)
    . $fnBlock

    function New-FakeTask {
        param([string]$User, [string]$LogonType, [string]$RunLevel)
        return [pscustomobject]@{
            Principal = [pscustomobject]@{
                UserId    = $User
                LogonType = $LogonType
                RunLevel  = $RunLevel
            }
        }
    }

    $cases = @(
        @{ Name = 'matching task (bare user stored, DOMAIN\user expected) reports no problems'
           Task = New-FakeTask -User 'LENOVO' -LogonType 'Interactive' -RunLevel 'Limited'
           User = 'DEVICE\LENOVO'; Logon = 'Interactive'; Level = 'Limited'
           WantProblems = 0 },
        @{ Name = 'matching task (DOMAIN\user stored, bare user expected) reports no problems'
           Task = New-FakeTask -User 'DEVICE\LENOVO' -LogonType 'Interactive' -RunLevel 'Limited'
           User = 'LENOVO'; Logon = 'Interactive'; Level = 'Limited'
           WantProblems = 0 },
        @{ Name = 'downgraded logon type (S4U stored, Interactive wanted) is detected'
           Task = New-FakeTask -User 'LENOVO' -LogonType 'S4U' -RunLevel 'Limited'
           User = 'DEVICE\LENOVO'; Logon = 'Interactive'; Level = 'Limited'
           WantProblems = 1; WantText = 'logon type' },
        @{ Name = 'elevated run level (Highest stored, Limited wanted) is detected'
           Task = New-FakeTask -User 'LENOVO' -LogonType 'Interactive' -RunLevel 'Highest'
           User = 'DEVICE\LENOVO'; Logon = 'Interactive'; Level = 'Limited'
           WantProblems = 1; WantText = 'run level' },
        @{ Name = 'wrong task user is detected'
           Task = New-FakeTask -User 'OTHERUSER' -LogonType 'Interactive' -RunLevel 'Limited'
           User = 'DEVICE\LENOVO'; Logon = 'Interactive'; Level = 'Limited'
           WantProblems = 1; WantText = 'task user' }
    )

    foreach ($c in $cases) {
        $got = @(Get-TaskPrincipalProblems -StoredTask $c.Task -ExpectedUser $c.User `
                     -ExpectedLogonType $c.Logon -ExpectedRunLevel $c.Level)
        $okCount = ($got.Count -eq $c.WantProblems)
        $okText  = $true
        if ($c.WantText) { $okText = [bool]($got | Where-Object { $_ -match $c.WantText }) }
        Assert-True ($okCount -and $okText) $c.Name
    }
}

# --- verdict -------------------------------------------------------------------

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host '[ ok  ] ALL AUTOSTART TESTS PASSED' -ForegroundColor Green
    exit 0
}
Write-Host "[fail ] $script:failures autostart test(s) failed" -ForegroundColor Red
exit 1
