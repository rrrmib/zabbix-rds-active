$ErrorActionPreference = "Stop"

# ============================================================
# RDS session collector for Zabbix Agent 2
# Без quser.exe — данные получаются напрямую через WTS API
# ============================================================


# ------------------------------------------------------------
# Native Windows RDS API
# ------------------------------------------------------------

if (-not ("RdsNative.Api" -as [type])) {

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace RdsNative
{
    public enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive       = 0,
        WTSConnected    = 1,
        WTSConnectQuery = 2,
        WTSShadow       = 3,
        WTSDisconnected = 4,
        WTSIdle         = 5,
        WTSListen       = 6,
        WTSReset        = 7,
        WTSDown         = 8,
        WTSInit         = 9
    }

    public enum WTS_INFO_CLASS
    {
        WTSInitialProgram      = 0,
        WTSApplicationName     = 1,
        WTSWorkingDirectory    = 2,
        WTSOEMId               = 3,
        WTSSessionId           = 4,
        WTSUserName            = 5,
        WTSWinStationName      = 6,
        WTSDomainName          = 7,
        WTSConnectState        = 8,
        WTSClientBuildNumber   = 9,
        WTSClientName          = 10,
        WTSClientDirectory     = 11,
        WTSClientProductId     = 12,
        WTSClientHardwareId    = 13,
        WTSClientAddress       = 14,
        WTSClientDisplay       = 15,
        WTSClientProtocolType  = 16,
        WTSIdleTime            = 17,
        WTSLogonTime           = 18,
        WTSIncomingBytes       = 19,
        WTSOutgoingBytes       = 20,
        WTSIncomingFrames      = 21,
        WTSOutgoingFrames      = 22,
        WTSClientInfo          = 23,
        WTSSessionInfo         = 24,
        WTSSessionInfoEx       = 25
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_SESSION_INFO
    {
        public Int32 SessionID;
        public IntPtr pWinStationName;
        public WTS_CONNECTSTATE_CLASS State;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFO
    {
        public WTS_CONNECTSTATE_CLASS State;
        public UInt32 SessionId;

        public UInt32 IncomingBytes;
        public UInt32 OutgoingBytes;
        public UInt32 IncomingFrames;
        public UInt32 OutgoingFrames;
        public UInt32 IncomingCompressedBytes;
        public UInt32 OutgoingCompressedBytes;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string WinStationName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)]
        public string Domain;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)]
        public string UserName;

        public Int64 ConnectTime;
        public Int64 DisconnectTime;
        public Int64 LastInputTime;
        public Int64 LogonTime;
        public Int64 CurrentTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_CLIENT_ADDRESS
    {
        public UInt32 AddressFamily;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 20)]
        public byte[] Address;
    }

    public static class Api
    {
        [DllImport(
            "Wtsapi32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true
        )]
        public static extern bool WTSEnumerateSessionsW(
            IntPtr hServer,
            Int32 Reserved,
            Int32 Version,
            out IntPtr ppSessionInfo,
            out Int32 pCount
        );

        [DllImport(
            "Wtsapi32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true
        )]
        public static extern bool WTSQuerySessionInformationW(
            IntPtr hServer,
            Int32 sessionId,
            WTS_INFO_CLASS wtsInfoClass,
            out IntPtr ppBuffer,
            out Int32 pBytesReturned
        );

        [DllImport("Wtsapi32.dll")]
        public static extern void WTSFreeMemory(
            IntPtr pMemory
        );
    }
}
"@

}


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Get-WtsString {

    param(
        [int]$SessionId,
        [RdsNative.WTS_INFO_CLASS]$InfoClass
    )

    $buffer = [IntPtr]::Zero
    $bytes = 0

    try {

        $ok = [RdsNative.Api]::WTSQuerySessionInformationW(
            [IntPtr]::Zero,
            $SessionId,
            $InfoClass,
            [ref]$buffer,
            [ref]$bytes
        )

        if (
            -not $ok -or
            $buffer -eq [IntPtr]::Zero -or
            $bytes -le 2
        ) {
            return $null
        }

        $value =
            [Runtime.InteropServices.Marshal]::PtrToStringUni($buffer)

        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        return $value
    }
    finally {

        if ($buffer -ne [IntPtr]::Zero) {
            [RdsNative.Api]::WTSFreeMemory($buffer)
        }
    }
}


function Get-WtsProtocol {

    param([int]$SessionId)

    $buffer = [IntPtr]::Zero
    $bytes = 0

    try {

        $ok = [RdsNative.Api]::WTSQuerySessionInformationW(
            [IntPtr]::Zero,
            $SessionId,
            [RdsNative.WTS_INFO_CLASS]::WTSClientProtocolType,
            [ref]$buffer,
            [ref]$bytes
        )

        if (
            -not $ok -or
            $buffer -eq [IntPtr]::Zero
        ) {
            return $null
        }

        $protocol =
            [Runtime.InteropServices.Marshal]::ReadInt16($buffer)

        switch ($protocol) {

            0 { return "Console" }
            1 { return "Legacy" }
            2 { return "RDP" }

            default {
                return "Other:$protocol"
            }
        }
    }
    finally {

        if ($buffer -ne [IntPtr]::Zero) {
            [RdsNative.Api]::WTSFreeMemory($buffer)
        }
    }
}


function Get-WtsClientIP {

    param([int]$SessionId)

    $buffer = [IntPtr]::Zero
    $bytes = 0

    try {

        $ok = [RdsNative.Api]::WTSQuerySessionInformationW(
            [IntPtr]::Zero,
            $SessionId,
            [RdsNative.WTS_INFO_CLASS]::WTSClientAddress,
            [ref]$buffer,
            [ref]$bytes
        )

        if (
            -not $ok -or
            $buffer -eq [IntPtr]::Zero
        ) {
            return $null
        }

        $info =
            [Runtime.InteropServices.Marshal]::PtrToStructure(
                $buffer,
                [type][RdsNative.WTS_CLIENT_ADDRESS]
            )

        # AF_INET
        if ($info.AddressFamily -eq 2) {

            if ($null -eq $info.Address -or $info.Address.Length -lt 6) {
                return $null
            }

            # Для IPv4 первые два байта зарезервированы.
            $ip = "{0}.{1}.{2}.{3}" -f `
                $info.Address[2],
                $info.Address[3],
                $info.Address[4],
                $info.Address[5]

            if ($ip -eq "0.0.0.0") {
                return $null
            }

            return $ip
        }

        # AF_INET6
        if ($info.AddressFamily -eq 23) {

            try {

                $ipv6Bytes = New-Object byte[] 16

                [Array]::Copy(
                    $info.Address,
                    0,
                    $ipv6Bytes,
                    0,
                    16
                )

                $ip =
                    (New-Object System.Net.IPAddress (,$ipv6Bytes)).ToString()

                if ($ip -eq "::") {
                    return $null
                }

                return $ip
            }
            catch {
                return $null
            }
        }

        return $null
    }
    finally {

        if ($buffer -ne [IntPtr]::Zero) {
            [RdsNative.Api]::WTSFreeMemory($buffer)
        }
    }
}


function Get-WtsSessionInfo {

    param([int]$SessionId)

    $buffer = [IntPtr]::Zero
    $bytes = 0

    try {

        $ok = [RdsNative.Api]::WTSQuerySessionInformationW(
            [IntPtr]::Zero,
            $SessionId,
            [RdsNative.WTS_INFO_CLASS]::WTSSessionInfo,
            [ref]$buffer,
            [ref]$bytes
        )

        if (
            -not $ok -or
            $buffer -eq [IntPtr]::Zero
        ) {
            return $null
        }

        return [Runtime.InteropServices.Marshal]::PtrToStructure(
            $buffer,
            [type][RdsNative.WTSINFO]
        )
    }
    finally {

        if ($buffer -ne [IntPtr]::Zero) {
            [RdsNative.Api]::WTSFreeMemory($buffer)
        }
    }
}


function Convert-FileTimeLocal {

    param([Int64]$Value)

    if ($Value -le 0) {
        return $null
    }

    try {

        return [DateTime]::FromFileTimeUtc(
            $Value
        ).ToLocalTime()
    }
    catch {
        return $null
    }
}


function Convert-State {

    param(
        [RdsNative.WTS_CONNECTSTATE_CLASS]$State
    )

    switch ($State) {

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSActive) {
            return "Active"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSConnected) {
            return "Connected"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSConnectQuery) {
            return "ConnectQuery"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSShadow) {
            return "Shadow"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSDisconnected) {
            return "Disconnected"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSIdle) {
            return "Idle"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSListen) {
            return "Listen"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSReset) {
            return "Reset"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSDown) {
            return "Down"
        }

        ([RdsNative.WTS_CONNECTSTATE_CLASS]::WTSInit) {
            return "Init"
        }

        default {
            return $State.ToString()
        }
    }
}


# ------------------------------------------------------------
# Процессы группируем один раз по SessionId
# ------------------------------------------------------------

$processStats = @{}

Get-Process -ErrorAction SilentlyContinue |
ForEach-Object {

    try {
        $sid = [int]$_.SessionId
    }
    catch {
        return
    }

    if ($sid -le 0) {
        return
    }

    if (-not $processStats.ContainsKey($sid)) {

        $processStats[$sid] = [PSCustomObject]@{
            Count           = 0
            WorkingSetBytes = [Int64]0
            CpuSeconds      = [double]0
        }
    }

    $stats = $processStats[$sid]

    $stats.Count++

    try {
        $stats.WorkingSetBytes += [Int64]$_.WorkingSet64
    }
    catch {
    }

    try {

        if ($null -ne $_.CPU) {
            $stats.CpuSeconds += [double]$_.CPU
        }
    }
    catch {
    }
}


# ------------------------------------------------------------
# Enumerate RDS sessions
# ------------------------------------------------------------

$sessionBuffer = [IntPtr]::Zero
$sessionCount = 0
$sessions = @()

try {

    $ok = [RdsNative.Api]::WTSEnumerateSessionsW(
        [IntPtr]::Zero,
        0,
        1,
        [ref]$sessionBuffer,
        [ref]$sessionCount
    )

    if (-not $ok) {

        $win32Error =
            [Runtime.InteropServices.Marshal]::GetLastWin32Error()

        throw "WTSEnumerateSessionsW failed. Win32 error: $win32Error"
    }

    $structSize =
        [Runtime.InteropServices.Marshal]::SizeOf(
            [type][RdsNative.WTS_SESSION_INFO]
        )

    for ($i = 0; $i -lt $sessionCount; $i++) {

        $currentPtr =
            [IntPtr]::Add(
                $sessionBuffer,
                $i * $structSize
            )

        $nativeSession =
            [Runtime.InteropServices.Marshal]::PtrToStructure(
                $currentPtr,
                [type][RdsNative.WTS_SESSION_INFO]
            )

        $sessionId = [int]$nativeSession.SessionID

        # ----------------------------------------------------
        # Username. Системные/listener sessions без пользователя
        # нас для RDS-мониторинга не интересуют.
        # ----------------------------------------------------

        $username = Get-WtsString `
            -SessionId $sessionId `
            -InfoClass ([RdsNative.WTS_INFO_CLASS]::WTSUserName)

        if ([string]::IsNullOrWhiteSpace($username)) {
            continue
        }


        # ----------------------------------------------------
        # Основные поля
        # ----------------------------------------------------

        $domain = Get-WtsString `
            -SessionId $sessionId `
            -InfoClass ([RdsNative.WTS_INFO_CLASS]::WTSDomainName)

        $clientName = Get-WtsString `
            -SessionId $sessionId `
            -InfoClass ([RdsNative.WTS_INFO_CLASS]::WTSClientName)

        $clientIP = Get-WtsClientIP `
            -SessionId $sessionId

        $protocol = Get-WtsProtocol `
            -SessionId $sessionId

        $state = Convert-State $nativeSession.State


        # Имя станции из WTSEnumerateSessions
        $sessionName = $null

        if ($nativeSession.pWinStationName -ne [IntPtr]::Zero) {

            $sessionName =
                [Runtime.InteropServices.Marshal]::PtrToStringUni(
                    $nativeSession.pWinStationName
                )

            if ([string]::IsNullOrWhiteSpace($sessionName)) {
                $sessionName = $null
            }
        }


        # ----------------------------------------------------
        # Session timestamps / traffic
        # ----------------------------------------------------

        $wtsInfo = Get-WtsSessionInfo `
            -SessionId $sessionId

        $logonTime      = $null
        $connectTime    = $null
        $disconnectTime = $null
        $lastInputTime  = $null
        $currentTime    = Get-Date

        $incomingBytes = $null
        $outgoingBytes = $null

        if ($null -ne $wtsInfo) {

            $logonTime =
                Convert-FileTimeLocal $wtsInfo.LogonTime

            $connectTime =
                Convert-FileTimeLocal $wtsInfo.ConnectTime

            $disconnectTime =
                Convert-FileTimeLocal $wtsInfo.DisconnectTime

            $lastInputTime =
                Convert-FileTimeLocal $wtsInfo.LastInputTime

            $tmpCurrent =
                Convert-FileTimeLocal $wtsInfo.CurrentTime

            if ($null -ne $tmpCurrent) {
                $currentTime = $tmpCurrent
            }

            $incomingBytes = [UInt64]$wtsInfo.IncomingBytes
            $outgoingBytes = [UInt64]$wtsInfo.OutgoingBytes
        }


        # ----------------------------------------------------
        # Idle / session duration
        # ----------------------------------------------------

        $idleMinutes = $null

        if (
            $null -ne $lastInputTime -and
            $currentTime -ge $lastInputTime
        ) {

            $idleMinutes =
                [math]::Floor(
                    ($currentTime - $lastInputTime).TotalMinutes
                )
        }


        $sessionMinutes = $null

        if (
            $null -ne $logonTime -and
            $currentTime -ge $logonTime
        ) {

            $sessionMinutes =
                [math]::Floor(
                    ($currentTime - $logonTime).TotalMinutes
                )
        }

        $disconnectedMinutes = 0

        if (
            $state -eq "Disconnected" -and
            $null -ne $disconnectTime -and
            $currentTime -ge $disconnectTime
        ) {
            $disconnectedMinutes =
                [math]::Floor(
                    ($currentTime - $disconnectTime).TotalMinutes
                )
        }

        # ----------------------------------------------------
        # Process stats
        # ----------------------------------------------------

        $processCount = 0
        $workingSetMB = 0
        $cpuSeconds = 0

        if ($processStats.ContainsKey($sessionId)) {

            $stats = $processStats[$sessionId]

            $processCount = $stats.Count

            $workingSetMB =
                [math]::Round(
                    $stats.WorkingSetBytes / 1MB,
                    1
                )

            $cpuSeconds =
                [math]::Round(
                    $stats.CpuSeconds,
                    1
                )
        }


        # ----------------------------------------------------
        # Объект сессии
        #
        # Старые имена полей сохраняем, чтобы существующий
        # шаблон Zabbix продолжил работать.
        # ----------------------------------------------------

        $sessions += [PSCustomObject]@{

            user            = $username
            domain          = $domain

            session_name    = $sessionName
            id              = $sessionId

            state           = $state
            state_raw       = $nativeSession.State.ToString()

            protocol        = $protocol

            client_name     = $clientName
            client_ip       = $clientIP

            # Оставляем поле для совместимости
            idle_raw        = if ($null -ne $idleMinutes) {
                                  [string]$idleMinutes
                              }
                              else {
                                  $null
                              }

            idle_minutes    = $idleMinutes

            disconnected_minutes = $disconnectedMinutes

            # Формат старого поля тоже сохраняем
            logon_time      = if ($null -ne $logonTime) {
                                  $logonTime.ToString(
                                      "dd.MM.yyyy H:mm"
                                  )
                              }
                              else {
                                  $null
                              }

            logon_time_iso  = if ($null -ne $logonTime) {
                                  $logonTime.ToString("o")
                              }
                              else {
                                  $null
                              }

            connect_time_iso = if ($null -ne $connectTime) {
                                   $connectTime.ToString("o")
                               }
                               else {
                                   $null
                               }

            disconnect_time_iso = if ($null -ne $disconnectTime) {
                                      $disconnectTime.ToString("o")
                                  }
                                  else {
                                      $null
                                  }

            last_input_time_iso = if ($null -ne $lastInputTime) {
                                      $lastInputTime.ToString("o")
                                  }
                                  else {
                                      $null
                                  }

            session_minutes = $sessionMinutes

            process_count   = $processCount
            working_set_mb  = $workingSetMB
            cpu_seconds     = $cpuSeconds

            incoming_bytes  = $incomingBytes
            outgoing_bytes  = $outgoingBytes
        }
    }
}
finally {

    if ($sessionBuffer -ne [IntPtr]::Zero) {
        [RdsNative.Api]::WTSFreeMemory($sessionBuffer)
    }
}


# ------------------------------------------------------------
# Final JSON
# ------------------------------------------------------------

$result = [PSCustomObject]@{

    server       = $env:COMPUTERNAME
    collected_at = (Get-Date).ToString("o")

    total = @($sessions).Count

    active = @(
        $sessions |
        Where-Object state -eq "Active"
    ).Count

    disconnected = @(
        $sessions |
        Where-Object state -eq "Disconnected"
    ).Count

    sessions = $sessions
}


$result | ConvertTo-Json -Depth 6 -Compress