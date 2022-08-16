﻿# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

. $PSScriptRoot\..\..\..\..\Shared\Invoke-ScriptBlockHandler.ps1
. $PSScriptRoot\..\..\..\..\Shared\Write-ErrorInformation.ps1

function Invoke-ConfigureMitigation {
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ExchangeServers,
        [Parameter(Mandatory = $true)]
        [object[]]$ipRangeAllowListRules,
        [Parameter(Mandatory = $true)]
        [string[]]$SiteVDirLocations
    )

    begin {
        $FailedServersFilter = @{}

        $progressParams = @{
            Activity        = "Applying IP filtering Rules"
            Status          = [string]::Empty
            PercentComplete = 0
        }

        Write-Verbose "Calling: $($MyInvocation.MyCommand)"

        $ConfigureMitigation = {
            param(
                [Object]$Arguments
            )

            $SiteVDirLocations = $Arguments.SiteVDirLocations
            $IpRangesForFiltering = $Arguments.IpRangesForFiltering
            $WhatIf = $Arguments.PassedWhatIf

            $results = @{
                IsWindowsFeatureInstalled = $false
                IsGetLocalIPSuccessful    = $false
                LocalIPs                  = New-Object 'System.Collections.Generic.List[string]'
                ErrorContext              = $null
            }

            function Backup-currentIpFilteringRules {
                param(
                    [Parameter(Mandatory = $true)]
                    [string]$BackupPath,
                    [Parameter(Mandatory = $true)]
                    [string]$Filter,
                    [Parameter(Mandatory = $true)]
                    [string]$IISPath,
                    [Parameter(Mandatory = $true)]
                    [string]$SiteVDirLocation,
                    [Parameter(Mandatory = $false)]
                    [object[]]$ExistingRules
                )

                $DefaultForUnspecifiedIPs = Get-WebConfigurationProperty -Filter $Filter -PSPath $IISPath -Location $SiteVDirLocation -Name "allowUnlisted"
                if ($null -eq $ExistingRules) {
                    $ExistingRules = New-Object 'System.Collections.Generic.List[object]'
                }

                $BackupFilteringConfiguration = @{Rules=$ExistingRules; DefaultForUnspecifiedIPs=$DefaultForUnspecifiedIPs }
                if (-not $WhatIf) {
                    $BackupFilteringConfiguration |  ConvertTo-Json -Depth 2 | Out-File $BackupPath
                }

                return $true
            }

            function Get-LocalIpAddresses {
                $ips = New-Object 'System.Collections.Generic.List[string]'
                $interfaces = Get-NetIPAddress -ErrorAction Stop
                foreach ($interface in $interfaces) {
                    if ($interface.AddressState -eq 'Preferred') {
                        $ips += $interface.IPAddress
                    }
                }

                return $ips
            }

            # Create ip allow list from user provided ip subnets
            function CreateIPRangeAllowList {
                param (
                    [Parameter(Mandatory = $true)]
                    [string]$SiteVDirLocation,
                    [Parameter(Mandatory = $true)]
                    [object[]]$IpFilteringRules,
                    [Parameter(Mandatory = $true)]
                    [hashtable] $state
                )

                $backupPath = "$($env:WINDIR)\System32\inetsrv\config\IpFilteringRules_" + $SiteVDirLocation.Replace('/', '-') + "_$([DateTime]::Now.ToString("yyyyMMddHHMMss")).bak"
                $Filter = 'system.webServer/security/ipSecurity'
                $IISPath = 'IIS:\'
                $ExistingRules = @(Get-WebConfigurationProperty -Filter $Filter -Location $SiteVDirLocation -name collection)
                $state.IsBackUpSuccessful = Backup-currentIpFilteringRules -BackupPath $backupPath -Filter $Filter -IISPath $IISPath -SiteVDirLocation $SiteVDirLocation -ExistingRules $ExistingRules

                $RulesToBeAdded = @()

                foreach ($IpFilteringRule in $IpFilteringRules) {
                    $ExistingIPSubnetRule = $ExistingRules | Where-Object { $_.ipAddress -eq $IpFilteringRule.IP -and ($_.subnetMask -eq $IpFilteringRule.SubnetMask -or $IpFilteringRule.Type -eq "Single IP") }

                    if ($null -eq $ExistingIPSubnetRule) {
                        if ($IpFilteringRule.Type -eq "Single IP") {
                            $RulesToBeAdded += @{ipAddress=$IpFilteringRule.IP; allowed=$IpFilteringRule.Allowed; }
                        } else {
                            $RulesToBeAdded += @{ipAddress=$IpFilteringRule.IP; subnetMask=$IpFilteringRule.SubnetMask; allowed=$IpFilteringRule.Allowed; }
                        }
                    } else {
                        if ($ExistingIPSubnetRule.allowed -ne $IpFilteringRule.Allowed) {
                            if ($IpFilteringRule.Type -eq "Single IP") {
                                $IpString = $IpFilteringRule.IP
                            } else {
                                $IpString = ("{0}/{1}" -f $IpFilteringRule.IP, $IpFilteringRule.SubnetMask)
                            }

                            $state.IPsNotAdded += $IpString
                        }
                    }
                }

                if ($RulesToBeAdded.Count + $ExistingRules.Count -gt 500) {
                    $state.IPsNotAdded += $RulesToBeAdded
                    throw 'Too many IP filtering rules (Existing rules [$($ExistingRules.Count)] + New rules [$($RulesToBeAdded.Count)] > 500). Please reduce the specified entries by providing appropriate subnets.'
                }

                if ($RulesToBeAdded.Count -gt 0) {
                    Add-WebConfigurationProperty  -Filter $Filter -PSPath $IISPath -Location $SiteVDirLocation -Name "." -Value $RulesToBeAdded -ErrorAction Stop -WhatIf:$WhatIf
                }

                $state.IsCreateIPRulesSuccessful = $true

                # Setting default to deny
                Set-WebConfigurationProperty -Filter $Filter -PSPath $IISPath -Location $SiteVDirLocation -Name "allowUnlisted" -Value $false -WhatIf:$WhatIf
                $state.IsSetDefaultRuleSuccessful = $true
            }

            try {
                try {
                    $baseError = "Installation of IP and Domain filtering Module failed."
                    $InstallResult = Install-WindowsFeature Web-IP-Security -ErrorAction Stop -WhatIf:$WhatIf
                    if (-not $InstallResult.Success) {
                        throw $baseError
                    }
                } catch {
                    throw "$baseError Inner exception: $_"
                }

                $results.IsWindowsFeatureInstalled = $true

                $localIPs = Get-LocalIpAddresses
                $results.IsGetLocalIPSuccessful = $true

                foreach ($localIP in $localIPs) {
                    if ($null -eq ($IpRangesForFiltering | Where-Object { $_.Type -eq "Single IP" -and $_.IP -eq $localIP })) {
                        $IpRangesForFiltering += @{Type="Single IP"; IP=$localIP; Allowed=$true }
                    }
                }

                $results.LocalIPs = $localIPs
                foreach ($SiteVDirLocation in $SiteVDirLocations) {
                    $state = @{
                        IsBackUpSuccessful         = $false
                        IsCreateIPRulesSuccessful  = $false
                        IsSetDefaultRuleSuccessful = $false
                        ErrorContext               = $null
                        IPsNotAdded                = New-Object 'System.Collections.Generic.List[string]'
                    }

                    try {
                        CreateIPRangeAllowList -SiteVDirLocation $SiteVDirLocation -IpFilteringRules $IpRangesForFiltering -state $state
                    } catch {
                        $state.ErrorContext = $_
                    }

                    $results[$SiteVDirLocation] = $state
                }
            } catch {
                $results.ErrorContext = $_
            }

            return $results
        }

        function GetCommaSaperatedString {
            param(
                [Parameter(Mandatory = $true)]
                [object[]]$list
            )

            $string = ""
            foreach ($element in $list) {
                $string += ($element.ToString() + ", ")
            }

            return $string.Trim(", ")
        }
    } process {
        $scriptblockArgs = [PSCustomObject]@{
            SiteVDirLocations    = $SiteVDirLocations
            IpRangesForFiltering = $ipRangeAllowListRules
            PassedWhatIf         = $WhatIfPreference
        }

        $counter = 0
        $totalCount = $ExchangeServers.Count

        if ($null -eq $ipRangeAllowListRules) {
            $ipRangeAllowListString = "null"
        } else {
            $IpStrings = @() 
            $ipRangeAllowListRules | ForEach-Object {
                if ($_.Type -eq "Single IP") {
                    $IpStrings += $_.IP
                } else {
                    $IpStrings += ("{0}/{1}" -f $_.IP, $_.SubnetMask)
                }
            }
            $ipRangeAllowListString = [string]::Join(", ", $IpStrings)
        }

        $SiteVDirLocations | ForEach-Object {
            $FailedServersFilter[$_] = New-Object 'System.Collections.Generic.List[string]'
        }

        foreach ($Server in $ExchangeServers) {
            $baseStatus = "Processing: $Server -"
            $progressParams.PercentComplete = ($counter / $totalCount * 100)
            $progressParams.Status = "$baseStatus Applying rules"
            Write-Progress @progressParams
            $counter ++;

            Write-Verbose ("Calling Invoke-ScriptBlockHandler on Server {0} with arguments SiteVDirLocation: {1}, ipRangeAllowListRules: {2}" -f $Server, $SiteVDirLocation, $ipRangeAllowListString)
            $resultsInvoke = Invoke-ScriptBlockHandler -ComputerName $Server -ScriptBlock $ConfigureMitigation -ArgumentList $scriptblockArgs

            Write-Host ("Adding IP Restriction rules on Server {0}" -f $Server)
            if ($resultsInvoke.IsWindowsFeatureInstalled) {
                Write-Verbose ("Successfully installed windows feature - Web-IP-Security on server {0}" -f $Server)
            } else {
                Write-Host ("Script failed to install windows feature - Web-IP-Security on server {0} with the Inner Exception:" -f $Server) -ForegroundColor Red
                Write-HostErrorInformation $resultsInvoke.ErrorContext
                $FailedServersFilter += $Server
                continue
            }

            if ($resultsInvoke.IsGetLocalIPSuccessful) {
                Write-Verbose ("Successfully retrieved local IPs for the server")
                if ($null -ne $resultsInvoke.LocalIPs -and $resultsInvoke.LocalIPs.Length -gt 0) {
                    Write-Verbose ("Local IPs detected for this server: {0}" -f (GetCommaSaperatedString -list $resultsInvoke.LocalIPs))
                } else {
                    Write-Verbose ("No Local IPs detected for this server")
                }
            } else {
                Write-Host ("Script failed to retrieve local IPs for server {0} with the Inner Exception:" -f $Server) -ForegroundColor Red
                Write-HostErrorInformation $resultsInvoke.ErrorContext
                $FailedServersFilter += $Server
                continue
            }

            foreach ($SiteVDirLocation in $SiteVDirLocations) {
                $state = $resultsInvoke[$SiteVDirLocation]

                if ($state.IsBackUpSuccessful) {
                    Write-Verbose ("Successfully backed up IP filtering allow list for VDir $SiteVDirLocation")
                } else {
                    Write-Host ("Script failed to backup IP filtering allow list for VDir $SiteVDirLocation with the Inner Exception:") -ForegroundColor Red
                    Write-HostErrorInformation $state.ErrorContext
                    $FailedServersFilter[$SiteVDirLocation] += $Server
                    continue
                }

                if ($state.IsCreateIPRulesSuccessful) {
                    Write-Verbose ("Successfully updated IP filtering allow list for VDir $SiteVDirLocation")
                    if ($state.IPsNotAdded.Length -gt 0) {
                        $line = ("Few IPs were not added to the allow list as deny rules for these IPs were already present.")
                        Write-Warning ($line + "Check logs for further details.")
                        Write-Verbose $line
                        Write-Verbose (GetCommaSaperatedString -list $state.IPsNotAdded)
                    }
                } else {
                    Write-Host ("Script failed to update IP filtering allow list for VDir $SiteVDirLocation. with the Inner Exception:") -ForegroundColor Red
                    Write-HostErrorInformation $state.ErrorContext
                    $FailedServersFilter[$SiteVDirLocation] += $Server
                    continue
                }

                if ($state.IsSetDefaultRuleSuccessful) {
                    Write-Verbose ("Successfully set the default IP filtering rule to deny for VDir $SiteVDirLocation")
                } else {
                    Write-Host ("Script failed to set the default IP filtering rule to deny for VDir $SiteVDirLocation with the Inner Exception:") -ForegroundColor Red
                    Write-HostErrorInformation $state.ErrorContext
                    $FailedServersFilter[$SiteVDirLocation] += $Server
                    continue
                }

                Write-Host ("Enabled ip filtering rules on server {0} for VDir $SiteVDirLocation" -f $Server)
            }
        }
    } end {
        foreach ($SiteVDirLocation in $SiteVDirLocations) {
            if ($FailedServersFilter[$SiteVDirLocation].Length -gt 0) {
                Write-Host ("Unable to create IP Filtering Rules for VDir $SiteVDirLocation on the following servers: {0}" -f [string]::Join(", ", $FailedServersFilter[$SiteVDirLocation])) -ForegroundColor Red
            }
        }
    }
}
