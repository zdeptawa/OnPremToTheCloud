param (
    $ResourceGroupName = 'onpremtothecloud',
    $ManagementResourceGroupName = ($ResourceGroupName + '-mgmt'),
    $StorageAccountName = 'optcdsc',
    $StorageContainerName = 'configurations',
    $Location = 'eastus',
    $AzureDevOpsToken = $env:AzureDevOpsEnvironmentPat,
    $VMName = 'MercuryHealthDev',
    [switch]$FreshStart,
    [switch]$ManagementRGOnly,
    [switch]$ApplicationRGOnly
)
# This is set in a variable in the ApplicationRG deployment.
# If you change this, then you have to update the ARM template

if ([string]::IsNullOrEmpty($AzureDevOpsToken)) {
    Write-Warning "This provisioning process needs a Personal Access Token capable of adding a VM to an environment in your Azure DevOps project."
    Write-Warning "Please ensure that the token has the right permissions."
    throw "Please provide -AzureDevOpsToken or set `$env:AzureDevOpsEnvironmentPat."
}

$ConfigurationPath = 'MercHealthConfig.ps1'
$PolicyDefinitionPath = './network-security-rule-with-port.json'
$PolicyJson = Get-Content $PolicyDefinitionPath -Raw | ConvertFrom-Json  

if ($FreshStart) {
    $Jobs = @()
    if (-not $ManagementRGOnly) {
        Write-Host ""; Write-Host "Removing $ResourceGroupName"
        $Jobs += Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue |
        Remove-AzResourceGroup -Force -AsJob
    }
    if (-not $ApplicationRGOnly) {
        Write-Host ""; Write-Host "Removing $ManagementResourceGroupName"
        $Jobs += Get-AzResourceGroup -Name $ManagementResourceGroupName -ErrorAction SilentlyContinue |
        Remove-AzResourceGroup -Force -AsJob
    }    
    Write-Host ""; Write-Host "Removing parameters files."
    Remove-Item './ApplicationRG.current.parameters.json' -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item './ManagementRG.current.parameters.json' -Force -ErrorAction SilentlyContinue | Out-Null

    Write-Host "Waiting for the resource groups to delete."
    $Jobs | Receive-Job -Wait | Out-Null
    Write-Host "Resource groups have been deleted."

}

Write-Host "Checking Azure Policy status"
$Policy = Get-AzPolicyDefinition -Name $PolicyJson.displayName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
if ($Policy) {
    if ($PolicyJson.metadata.version -eq $Policy.Properties.metadata.version) {
        Write-Host "Policy $($PolicyJson.displayName) is up to date."
    }
    else {
        Write-Host ""; Write-Host "Updating Policy Definition $($PolicyJson.displayName)."
        $Policy = Set-AzPolicyDefinition -Id $Policy.ResourceId -Policy $PolicyDefinitionPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 
    }
}
else {
    Write-Host "Creating New Policy Definition $($PolicyJson.displayName)."
    $Policy = New-AzPolicyDefinition -Name $PolicyJson.displayName -Policy $PolicyDefinitionPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}

$PolicyName = $PolicyJson.displayName.tolower() -replace '\s+', '-'
$PolicyAssignment = Get-AzPolicyAssignment -Name $PolicyName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
if (-not $PolicyAssignment) {
    Write-Host ""; Write-Host "Assigning the policy to block opening 3389 to the internet."
    New-AzPolicyAssignment -Name $PolicyName -DisplayName $PolicyJson.displayName -PolicyDefinition $Policy -PolicyParameterObject @{port = '3389' } | Out-Null
}
else {
    Write-Host ""; Write-Host "Policy already assigned."    
}

$TemplateSpecParams = @{
    ResourceGroupName = $ManagementResourceGroupName
    Location          = $Location
    Force             = $true
}

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

    $MGParametersFile = get-content './ManagementRG.parameters.json' -raw | ConvertFrom-Json
    $MGParametersFile.parameters.storageAccountName.value = $StorageAccountName
    $MGParametersFile.parameters.storageContainerName.value = $StorageContainerName
    $MGParametersFile | 
    ConvertTo-Json | 
    out-file ./ManagementRG.current.parameters.json -Force

    # Deploying this environment incrementally so the template specs don't disappear.
    # Otherwise, we have a Chicken/Egg scenario.
    Write-Host ""; Write-Host "Creating storage resources in the management group to host the DSC configuration and application code."
    $ManagementRGDeploymentParameters = @{
        ResourceGroupName     = $ManagementResourceGroupName
        TemplateSpecId        = $ManagementRGSpecId
        TemplateParameterFile = './ManagementRG.current.parameters.json'
        Mode                  = 'Incremental'
        Force                 = $true
    }

    New-AzResourceGroupDeployment @ManagementRGDeploymentParameters | Out-Null
    Remove-Item -Path ./ManagementRG.current.parameters.json -Force

}

### YOU'LL WANT FROM HERE
$ConfigurationPath = 'MercHealthConfig.ps1'
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
### To here for the dsc publish.  You'll need to provide a resource group name, storage account and storage container name



if (-not $ManagementRGOnly) {
    
    Write-Host ""; Write-Host "Creating the application resource group."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $ManagementResourceGroupName -Name $StorageAccountName
    $DscArchiveStorageUri = $StorageAccount.PrimaryEndpoints.Blob + $StorageContainerName + '/'
    $ParametersFile = get-content './ApplicationRG.parameters.json' -raw | ConvertFrom-Json
    $ParametersFile.parameters.dscBlobStorageUri.value = $DscArchiveStorageUri
    $ParametersFile.parameters.azureDevOpsToken.value = $AzureDevOpsToken
    $ParametersFile.parameters.vmname.value = $VMName
    $ParametersFile | 
    ConvertTo-Json | 
    out-file './ApplicationRG.current.parameters.json' -Force

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
        TemplateParameterFile = './ApplicationRG.current.parameters.json'
        Mode                  = 'Complete'
        Force                 = $true
    }
    New-AzResourceGroupDeployment @FullDeploymentParameters
    Remove-Item -Path ./ApplicationRG.current.parameters.json -Force
}

$DSCStatus = Get-AzVMDscExtensionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName
$DSCStatus.StatusMessage
$DSCStatus.DscConfigurationLog
