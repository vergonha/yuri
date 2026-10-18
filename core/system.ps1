# Windows integration: PATH in the registry, change broadcast, execution policy.

$script:EnvKeys = @{
    Machine = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    User    = 'Environment'
}

function Get-EnvRegistryKey([string]$Scope, [bool]$Writable) {
    $hive = if ($Scope -eq 'Machine') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $hive.OpenSubKey($script:EnvKeys[$Scope], $Writable)
}

# Reads PATH without expanding %VARIABLES%, so they survive a write back.
function Get-RawPath([ValidateSet('Machine', 'User')][string]$Scope) {
    $key = Get-EnvRegistryKey $Scope $false
    if (-not $key) { return '' }
    try {
        [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { $key.Close() }
}

function Set-RawPath([ValidateSet('Machine', 'User')][string]$Scope, [string]$Value) {
    $key = Get-EnvRegistryKey $Scope $true
    try {
        $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
}

# Tells running programs (Explorer, new terminals) that the environment changed.
function Send-EnvironmentChange {
    if (-not ('Yuri.NativeMethods' -as [type])) {
        Add-Type -Namespace Yuri -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5 s timeout
    $null = [Yuri.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

function ConvertTo-NormalPath([string]$Path) {
    if (-not $Path) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    $expanded.TrimEnd('\').ToLowerInvariant()
}

function Test-PathListHas([string]$List, [string]$Dir) {
    $want = ConvertTo-NormalPath $Dir
    foreach ($entry in ($List -split ';')) {
        if ($entry.Trim() -and (ConvertTo-NormalPath $entry) -eq $want) { return $true }
    }
    $false
}

# Puts Entries at the front of a PATH string, dropping any older copies of them.
function Add-PathEntries([string]$PathValue, [string[]]$Entries) {
    $wanted = @($Entries | ForEach-Object { ConvertTo-NormalPath $_ })
    $rest = @(($PathValue -split ';') | Where-Object {
            $_.Trim() -and ($wanted -notcontains (ConvertTo-NormalPath $_))
        })
    (@($Entries) + $rest) -join ';'
}

# The policy that applies to new terminals (this process may run with -ExecutionPolicy Bypass).
function Get-PolicyWithoutProcess {
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        $policy = [string](Get-ExecutionPolicy -Scope $scope)
        if ($policy -ne 'Undefined') { return @{ Policy = $policy; Scope = $scope } }
    }
    @{ Policy = 'Restricted'; Scope = 'Default' }
}

function Test-PolicyAllowsScripts([string]$Policy) {
    $Policy -in 'RemoteSigned', 'Unrestricted', 'Bypass'
}
