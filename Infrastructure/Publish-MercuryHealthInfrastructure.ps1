param (
    $ResourceGroupName = 'onpremtothecloud',
    $ManagementResourceGroupName = ($ResourceGroupName + '-mgmt'),
    $StorageAccountName = 'optcdsc',
    $StorageContainerName = 'configurations',
    $Location = 'eastus',
    [ValidateNotNullOrEmpty()]
    $AzureDevOpsToken = $env:AzureDevOpsEnvironmentPat,
    [switch]$FreshStart,
    [switch]$ManagementRGOnly,
    [switch]$ApplicationRGOnly
)
# This is set in a variable in the ApplicationRG deployment.
# If you change this, then you have to update the ARM template

$ConfigurationPath = 'MercHealthConfig.ps1'

if ($FreshStart) {
    if (-not $ManagementRGOnly) {
        Write-Host ""; Write-Host "Removing $ResourceGroupName"
        Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue |
        Remove-AzResourceGroup -Force | 
        Out-Null
    }
    if (-not $ApplicationRGOnly) {
        Write-Host ""; Write-Host "Removing $ManagementResourceGroupName"
        Get-AzResourceGroup -Name $ManagementResourceGroupName -ErrorAction SilentlyContinue |
        Remove-AzResourceGroup -Force | 
        Out-Null
    }
    Write-Host ""; Write-Host "Removing parameters file."
    Remove-Item './current.parameters.json' -Force | Out-Null
}

$TemplateSpecParams = @{
    ResourceGroupName = $ManagementResourceGroupName
    Location          = $Location
    Force             = $true
}

### Policy?

if (-not $ApplicationRGOnly) {
    Write-Host ""; Write-Host "Setting up the management resource group - $ManagementResourceGroupName"
    New-AzResourceGroup -Name $ManagementResourceGroupName -Location $Location -Force | Out-Null

    Write-Host ""; Write-Host "Deploying template specs to the management resource group."
    $ManagementRGTemplateVersion = (Get-Content './ManagementRG.json' -raw | ConvertFrom-Json).ContentVersion
    $ManagementRGSpec = New-AzTemplateSpec @TemplateSpecParams -Name ManagementRG -TemplateFile './ManagementRG.json' -Version $ManagementRGTemplateVersion
    $ManagementRGSpecId = $ManagementRGSpec.Versions |
    Sort-Object -Property Name -Descending |
    Select-Object -First 1 -ExpandProperty Id

    $ApplicationRGTemplateVersion = (Get-Content './ApplicationRG.json' -raw | ConvertFrom-Json).ContentVersion
    $ApplicationRGSpec = New-AzTemplateSpec @TemplateSpecParams -Name ApplicationRG -TemplateFile './ApplicationRG.json' -Version $ApplicationRGTemplateVersion
    $ApplicationRGSpecId = $ApplicationRGSpec.Versions |
    Sort-Object -Property Name -Descending |
    Select-Object -First 1 -ExpandProperty Id

    # Deploying this environment incrementally so the template specs don't disappear.
    # Otherwise, we have a Chicken/Egg scenario.
    Write-Host ""; Write-Host "Creating storage resources in the management group to host the DSC configuration and application code."
    $ManagementRGDeploymentParameters = @{
        ResourceGroupName = $ManagementResourceGroupName
        TemplateSpecId    = $ManagementRGSpecId
        Mode              = 'Incremental'
        Force             = $true
    }

    New-AzResourceGroupDeployment @ManagementRGDeploymentParameters | Out-Null

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
        ResourceGroupName  = $ManagementResourceGroupName
        ConfigurationPath  = $ConfigurationPath
        StorageAccountName = $StorageAccountName
        ContainerName      = $StorageContainerName
        Force              = $true
    }
    Publish-AzVMDscConfiguration @Parameters | Out-Null
}
if (-not $ManagementRGOnly) {
    
    Write-Host ""; Write-Host "Creating the application resource group."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $ManagementResourceGroupName -Name $StorageAccountName
    $DscArchiveStorageUri = $StorageAccount.PrimaryEndpoints.Blob + $StorageContainerName + '/'
    Write-Host ""; Write-Host "Creating a current parameters file with Storage URI - $DscArchiveStorageUri."
    Write-Host ""; Write-Host "Creating a current parameters file with Token - $AzureDevOpsToken."
    $ParametersFile = get-content './ApplicationRG.parameters.json' -raw | ConvertFrom-Json
    $ParametersFile.parameters.dscBlobStorageUri.value = $DscArchiveStorageUri
    $ParametersFile.parameters.azureDevOpsToken.value = $AzureDevOpsToken
    $ParametersFile | 
        ConvertTo-Json | 
        out-file ./current.parameters.json -Force

    if (-not $ApplicationRGSpecId) {
        Write-Host ""; Write-Host "Getting the current application resource group templatespec Id"
        $TemplateSpecParams.Remove('Location') | Out-Null
        $TemplateSpecParams.Remove('Force') | Out-Null
        $ApplicationRGSpecId = (Get-AzTemplateSpec @TemplateSpecParams -Name ApplicationRG).Versions |
        Sort-Object -Property Name -Descending |
        Select-Object -First 1 -ExpandProperty Id
    }

    Write-Host ""; Write-Host "Deploy the application environment."
    $FullDeploymentParameters = @{
        ResourceGroupName     = $ResourceGroupName
        TemplateSpecId        = $ApplicationRGSpecId
        TemplateParameterFile = './current.parameters.json'
        Mode                  = 'Complete'
        Force                 = $true
    }
    New-AzResourceGroupDeployment @FullDeploymentParameters
    Remove-Item -Path ./current.parameters.json -Force
}
