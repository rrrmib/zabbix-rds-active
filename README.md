# Zabbix RDS Active Monitoring

Monitoring template for Microsoft Remote Desktop Services (RDS) on **Zabbix 7.0**
using **Zabbix Agent 2 active checks** and a PowerShell collector based on the
native Windows Terminal Services API (WTS API).

## What it monitors

- total / active / disconnected RDS sessions
- per-session user, domain and session ID
- session state
- client hostname and client IP
- RDP protocol
- idle time
- session duration
- disconnected duration
- process count per session
- aggregate Working Set memory per session
- accumulated CPU time per session
- RDS dashboards and trigger prototypes

## Architecture

```text
Windows RDS
   |
   +-- PowerShell + WTS API
   |       |
   |       +-- JSON
   |
   +-- Zabbix Agent 2
           |
           +-- active checks --> Zabbix Server:10051
```

The collector is called once by the active master item `rds.sessions.get`.
Dependent items and LLD extract the remaining metrics from the same JSON payload.

## Requirements

- Zabbix 7.0
- Zabbix Agent 2 on Windows
- Windows Server with Remote Desktop Services
- PowerShell 5.1 or later

Developed and tested with Zabbix Agent 2 7.0.30.

## Installation

1. Copy:

```text
scripts\rds_sessions.ps1
```

to:

```text
C:\Program Files\Zabbix Agent 2\scripts\rds_sessions.ps1
```

2. Place `agent2\rds_sessions.conf.example` in the Agent 2 include directory
   (rename it to `.conf` if needed).

3. Make sure the main Agent 2 config includes that directory.

4. Test the collector:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\rds_sessions.ps1"
```

5. Test the custom key:

```powershell
& "C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe" `
  -c "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf" `
  -t rds.sessions.get
```

6. Import:

```text
template\template_rds_by_zabbix_agent_active.yaml
```

in **Data collection -> Templates -> Import**.

## Active mode

Typical active-only Agent 2 settings:

```ini
ServerActive=<ZABBIX_SERVER>:10051
Hostname=<EXACT_ZABBIX_HOST_NAME>
```

If passive checks are not required, `Server=` may be omitted.

## Template macros

| Macro | Default | Description |
|---|---:|---|
| `{$RDS.DISCONNECTED.TIME.WARN}` | `300` | Maximum allowed disconnected session duration in minutes |
| `{$RDS.DISCONNECTED.WARN}` | `5` | Maximum allowed number of disconnected RDS sessions |
| `{$RDS.DURATION.WARN}` | `1440` | Maximum allowed RDS session duration in minutes |
| `{$RDS.IDLE.WARN}` | `240` | Maximum allowed session idle time in minutes |
| `{$RDS.MEMORY.WARN}` | `2048` | Maximum allowed memory usage per RDS session in MB |
| `{$RDS.NODATA}` | `5m` | Maximum allowed time without RDS monitoring data |
| `{$RDS.PROCESSES.WARN}` | `80` | Maximum allowed number of processes per RDS session |
| `{$RDS.SESSIONS.MAX}` | `30` | Maximum allowed number of concurrent RDS sessions |

## LLD lifetime

The template uses:

```text
Delete lost resources: After 1d
```

This is intentional because RDS session IDs are temporary and can be reused.

## Notes

- `cpu_seconds` is accumulated process CPU time, not instantaneous CPU percentage.
- Client IP is reported by the Windows Terminal Services API and may differ from
  an address observed elsewhere when NAT/gateways are involved.
- The collector does not parse localized `quser.exe` output.

## License

This project is licensed under the MIT License.  
See the [MIT License](LICENSE) file for details.