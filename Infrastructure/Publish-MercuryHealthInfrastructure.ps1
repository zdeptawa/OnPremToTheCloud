param (
    $ResourceGroupName = 'onpremtothecloud',
    $StorageAccountName = 'optcdsc',
    $StorageContainerName = 'configurations',
    $ConfigurationPath = 'MercHealthConfig.ps1'
)


New-AzResourceGroup -Name $ResourceGroupName -Location 'eastus'
$TemplateSpecParams = @{
    Version =  '1.0.0'
    ResourceGroupName = $ResourceGroupName 
    Location = 'eastus' 
}
New-AzTemplateSpec -Name MercuryHealthWeb -TemplateFile ./azuredeploy.json @TemplateSpecParams
New-AzTemplateSpec -Name DscStorage -TemplateFile ./DscStorage.json @TemplateSpecParams

$DSCStorageSpec = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Resources/templateSpecs/DscStorage/versions/1.0.0"
$MercuryHealthSpec = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Resources/templateSpecs/DscStorage/versions/1.0.0"

New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateSpecId $DSCStorageSpec

if (-not (Get-Module -ListAvailable xWebAdministration)) {
    Install-Module xWebAdministration -RequiredVersion 3.2.0 -Scope CurrentUser
}

$Parameters = @{
    ResourceGroupName = $ResourceGroupName 
    ConfigurationPath = $ConfigurationPath
    StorageAccountName = $StorageAccountName
    ContainerName = $StorageContainerName
}

Publish-AzVMDscConfiguration @Parameters
$FullDeploymentParameters = @{
    ResourceGroupName = $ResourceGroupName
    TemplateSpecId = $MercuryHealthSpec 
    TemplateParameterObject =  @{ dscTemplateSpec = $DSCStorageSpec }
}
New-AzResourceGroupDeployment @FullDeploymentParameters


<#
# Helpers


Set-AzVMDscExtension -ResourceGroupName $rg -VMName mercuryheathvm -ArchiveStorageAccountName optcdsc -ConfigurationName MercuryHealthWeb -ArchiveBlobName MercHealthConfig.ps1.zip -ArchiveContainerName configurations -Version "2.83"

$template = @'
WindowsFeature $Name {
    Name = '$Name'
    Ensure = 'Present'
}
'@
$templatedep = @'
WindowsFeature $Name {
    Name = '$Name'
    Ensure = 'Present'
    DependsOn = $DependsOn
}
'@

$f | 
    sort depth | 
    % { 
        $Name = $_.Name
        $currenttemplate = if ($_.DependsOn) { $templatedep; $DependsOn = "'[WindowsFeature]" + ($_.DependsOn -join "','[WindowsFeature]") + "'" } else { $template }
        $ExecutionContext.InvokeCommand.ExpandString($currenttemplate)
        }  | clip
    
#>
