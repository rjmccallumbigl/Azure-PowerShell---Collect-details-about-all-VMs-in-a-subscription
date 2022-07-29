<###################################################################################################
.SYNOPSIS
    Collect VM information and add results to a spreadsheet.
.DESCRIPTION
    Collect VM information and add results to a spreadsheet. Uses Run Command to collect disk utilization from guest OS.
.INPUTS
	$subscriptionId
	Subscription ID you would like the script to operate on. Optional.

    $rg
	Resource Group you would like the script to operate on. Optional.
.OUTPUTS
	Creates a CSV file in the same location the script is ran: "myVMReport_$($date).csv"
.EXAMPLE
	# Run the function to get information on all VMs
	Write-VMInformation

    # Run the function to get information on all VMs in the Resource Group "ubuntu_group"
	Write-VMInformation -rg ubuntu_group

.LINK
	https://github.com/rjmccallumbigl/PowerShell-Ping-Test
.NOTES
    Author: Ryan McCallum
	TODO: Add parallel deployment functionality if PS 7+ is detected
	Sources:
		https://docs.microsoft.com/en-us/previous-versions/azure/virtual-machines/scripts/virtual-machines-powershell-sample-collect-vm-details
####################################################################################################>

function Write-VMInformation {
    param(
        [Parameter(Mandatory = $false)][string]$subscriptionId,
        [Parameter(Mandatory = $false)][string]$rg
    )

    # (Optional) Provide the subscription Id where the VMs reside
    if ($subscriptionId) {
        Select-AzSubscription $subscriptionId
    }

    #Provide the name of the csv file to be exported
    $date = Get-Date -Format "MM-dd-yyyy_HH-MM-ss"
    $reportName = "myVMReport_$($date).csv"

    # Declare variables
    if ($rg) {
        $vms = Get-AzVM -ResourceGroupName $rg
        $nics = Get-AzNetworkInterface -ResourceGroupName $rg | Where-Object { $null -NE $_.VirtualMachine }
    }
    else {
        $vms = Get-AzVM
        $nics = Get-AzNetworkInterface | Where-Object { $null -NE $_.VirtualMachine }
    }

    $report = @()
    $publicIps = Get-AzPublicIpAddress

    # Collect VM + NIC information
    foreach ($nic in $nics) {
        $info = "" | Select-Object VmName, ResourceGroupName, Region, VmSize, VirtualNetwork, Subnet, PrivateIpAddress, OsType, PublicIPAddress, NicName, ApplicationSecurityGroup, ID, MAC, InternalDNS, OSDiskSpace
        $vm = $vms | Where-Object -Property Id -EQ $nic.VirtualMachine.id
        foreach ($publicIp in $publicIps) {
            if ($nic.IpConfigurations.id -eq $publicIp.ipconfiguration.Id) {
                $info.PublicIPAddress = $publicIp.ipaddress
            }
        }
        $info.OsType = $vm.StorageProfile.OsDisk.OsType
        $info.VMName = $vm.Name
        $info.ResourceGroupName = $vm.ResourceGroupName
        $info.Region = $vm.Location
        $info.VmSize = $vm.HardwareProfile.VmSize
        $info.VirtualNetwork = $nic.IpConfigurations.subnet.Id.Split("/")[-3]
        $info.Subnet = $nic.IpConfigurations.subnet.Id.Split("/")[-1]
        $info.PrivateIpAddress = $nic.IpConfigurations.PrivateIpAddress -join ','
        $info.NicName = $nic.Name -join ','
        $info.ApplicationSecurityGroup = $nic.IpConfigurations.ApplicationSecurityGroups.Id
        $info.ID = $vm.Id
        $info.MAC = $nic.MacAddress -join ','
        $info.InternalDNS = $nic.DnsSettings.InternalDomainNameSuffix
        $info.OSDiskSpace = (Invoke-RunCommand -rg $vm.ResourceGroupName -vmName $vm.Name -osVersion $vm.StorageProfile.OsDisk.OsType)
        $report += $info
    }
    $report | Format-Table VmName, ResourceGroupName, Region, VmSize, VirtualNetwork, Subnet, PrivateIpAddress, OsType, PublicIPAddress, NicName, ApplicationSecurityGroup, ID, MAC, InternalDNS, OSDiskSpace -AutoSize
    $report | Export-Csv $reportName -NoTypeInformation -Force
    Write-Output "Saved to $((Get-Item $reportName).FullName)"
}

function Invoke-RunCommand {
    param(
        [Parameter(Mandatory = $true)][string]$rg,
        [Parameter(Mandatory = $true)][string]$vmName,
        [Parameter(Mandatory = $true)][string]$osVersion
    )

    # Declare variables
    $runCommand = ""

    # Deploy the proper Run Command based on OS and return results
    try {
        if ($osVersion -eq "Windows") {
            $runCommand = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName -CommandId "RunPowerShellScript" -ScriptString "`$Wmi_LogicalDisks = Get-CimInstance -Query 'Select Size,FreeSpace From Win32_LogicalDisk'; `$disks = `$Wmi_LogicalDisks | ForEach-Object { ""DeviceID = {0} {1}GB/{2}GB Used"" -f `$_.DeviceID, (([math]::round(`$_.Size / 1GB)) - ([math]::round(`$_.FreeSpace / 1GB))), ([math]::round(`$_.Size / 1GB)) }; Write-Output `$(`$disks -join "" | "");" -ErrorAction Stop
            return ($runCommand.Value | Where-Object { $_.Code -like "*StdOut*" }).Message
        }
        elseif ($osVersion -eq "Linux") {
            $runCommand = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName -CommandId 'RunShellScript' -ScriptString "lsblk -o NAME,FSUSED,FSSIZE | grep sd"
            return (($runCommand.Value).Message -split "`\n" | Where-Object { $_ -match 'sd.*' }) -join " | "
        }
        else {
            return "Unknown OS"
        }
    }
    catch {
        return $_.ToString().Split("`n")[0]
    }
}
