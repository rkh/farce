$ErrorActionPreference = 'Stop'

$reportDirectory = Join-Path $env:RUNNER_TEMP 'farce-crash-reports'
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

# Capture unhandled Windows exceptions, including crashes without a Ruby report.
$dumpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\ruby.exe'
New-Item -Path $dumpKey -Force | Out-Null
New-ItemProperty -Path $dumpKey -Name DumpFolder -PropertyType ExpandString -Value $reportDirectory -Force | Out-Null
New-ItemProperty -Path $dumpKey -Name DumpType -PropertyType DWord -Value 2 -Force | Out-Null
New-ItemProperty -Path $dumpKey -Name DumpCount -PropertyType DWord -Value 5 -Force | Out-Null

# Ruby's own fatal-signal handler writes its report here when it can run.
$reportTemplate = (Join-Path $reportDirectory 'ruby-%p-%t.log') -replace '\\', '/'
"RUBY_CRASH_REPORT=$reportTemplate" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
