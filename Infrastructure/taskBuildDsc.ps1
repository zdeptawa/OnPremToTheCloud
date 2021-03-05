$ConfigurationPath = './Infrastructure/MercHealthConfig.ps1'

Write-Host ""; Write-Host 'Getting the xWebAdministration module to package as part of the published DSC configuration.'
if (-not (Get-Module -ListAvailable xWebAdministration)) {
    Install-Module xWebAdministration -RequiredVersion 3.2.0 -Scope CurrentUser
}
Write-Host ""; Write-Host 'Getting the xPSDesiredStateConfiguration module to package as part of the published DSC configuration.'
if (-not (Get-Module -ListAvailable xPSDesiredStateConfiguration)) {
    Install-Module xPSDesiredStateConfiguration -RequiredVersion 9.1.0 -Scope CurrentUser
}
Write-Host ""; Write-Host 'Packaging and publishing the DSC configuration and supporting modules.'
$Parameters = @{
    ResourceGroupName  = ${env:MGMTRESOURCEGROUP}
    ConfigurationPath  = $ConfigurationPath
    StorageAccountName = ${env:STORAGEACCOUNTNAME}
    ContainerName      = ${env:STORAGECONTAINERNAME}
    Force              = $true
}
Publish-AzVMDscConfiguration @Parameters | Out-Null