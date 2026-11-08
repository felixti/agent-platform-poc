param(
  [Parameter(Mandatory=$true)][ValidateSet('Start','Stop')][string]$Action,
  [string]$ResourceGroup = 'aks-lab',
  [string]$ClusterName = 'aks-lab'
)
$ErrorActionPreference = 'Stop'
Connect-AzAccount -Identity | Out-Null
$c = Get-AzAksCluster -ResourceGroupName $ResourceGroup -Name $ClusterName
$state = $c.PowerState.Code
Write-Output "Cluster $ClusterName power state: $state"
if ($Action -eq 'Start' -and $state -ne 'Running') { Start-AzAksCluster -ResourceGroupName $ResourceGroup -Name $ClusterName; Write-Output 'Started' }
elseif ($Action -eq 'Stop' -and $state -ne 'Stopped') { Stop-AzAksCluster -ResourceGroupName $ResourceGroup -Name $ClusterName; Write-Output 'Stopped' }
else { Write-Output 'Nothing to do' }
