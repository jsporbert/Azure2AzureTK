<#
.SYNOPSIS
    Exports Azure resource availability comparison between regions to Excel or CSV.

.DESCRIPTION
    Reads the output from Get-AvailabilityInformation.ps1, structures it, and
    exports to an Excel or CSV file, including SKU details.

.PARAMETER InputPath
    Path to the JSON or CSV file containing availability information.

.PARAMETER OutputPath
    Path where the report should be saved (without extension).

.PARAMETER ExportExcel
    If specified, exports to .xlsx (requires ImportExcel module), otherwise .csv.
#>

## TODO:
# Is available in implementedSkus logic does not seem to be working as expected
# Add logic for cost (separate code))

param(
    [Parameter(Mandatory = $false)][array]$availabilityInfoPath,
    [Parameter(Mandatory = $false)][string]$costComparisonPath = "..\3-CostInformation\region_comparison_prices.json"
)

Function New-Worksheet {
    param (
        [string]$WorksheetName,
        [int]$LastColumnNumber
    )
$excelParams = @{
    Path          = $xlsxFileName
    WorksheetName = $WorksheetName
    AutoSize      = $true
    TableStyle    = 'None'
    PassThru      = $true
}
    $excelPkg = $reportData | Select-Object -Property $allProps | Export-Excel @excelParams
    $ws = $excelPkg.Workbook.Worksheets[$WorksheetName]
    $lastColLetter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($lastColumnNumber)
    $headerRange = $ws.Cells["A1:$lastColLetter`1"]
    $headerRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
    $headerRange.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::RoyalBlue)
    $headerRange.Style.Font.Color.SetColor([System.Drawing.Color]::White)
    for ($row = 2; $row -le ($reportData.Count + 1); $row++) {
        # Get the total number of columns in the worksheet
        $colCount = $ws.Dimension.Columns
        for ($col = 5; $col -le $colCount; $col++) {
            # Column 5 is E
            $colLetter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($col)
            $cell = $ws.Cells["$colLetter$row"]
            if ($cell.Value -eq "Available") {
                $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::LightGreen)
            }
            elseif ($cell.Value -eq "Not available") {
                $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::LightCoral)
            }
        }
    }
    $excelPkg.Save()
}

# Consider splitting into functions for better readability and maintainability
$reportData = @()
foreach ($path in $availabilityInfoPath) {
    $rawdata = Get-Content $path | ConvertFrom-Json -Depth 10
    foreach ($item in $rawdata) {
        $implementedSkus = ""
        # if implementedSkus is exists and is not null
        if ($item.ImplementedSkus -and $item.ImplementedSkus.Count -gt 0) {
            $resourceType = $item.ResourceType
            ForEach ($sku in $item.ImplementedSkus) {
                # Customize output based on ResourceType
                switch ($resourceType) {
                    "microsoft.compute/virtualmachines" { $resourceType; $implementedSkus += $sku.vmSize + "," }
                    default { 
                        $resourceType; $implementedSkus += $sku.name + "," 
                    } # No action for other resource types
                }
            }
        }
        else {
            $implementedSkus += "N/A"
        }
        $implementedSkus = $implementedSkus.TrimEnd(",")
        $regionAvailability = "Not available"
        $regionHeader = $item.SelectedRegion.region
        If ($item.SelectedRegion.available) {
            $regionAvailability = "Available"
        }
        # If an object with this resource type already exists in reportData, update it
        if ($reportData | Where-Object { $_.ResourceType -eq $item.ResourceType }) {
            # If it exists, update the existing object with the new region availability
            $existingItem = $reportData | Where-Object { $_.ResourceType -eq $item.ResourceType }
            $existingItem | Add-Member -MemberType NoteProperty -Name $regionHeader -Value $regionAvailability
        }
        else {
            $reportItem = [PSCustomObject]@{
                ResourceType       = $item.ResourceType
                ResourceCount      = $item.ResourceCount
                ImplementedRegions = ($item.ImplementedRegions -join ", ")
                ImplementedSkus    = $implementedSkus
                $regionHeader      = $regionAvailability
            }
            $reportData += $reportItem
        }
    }
}
# $costComparisonPath = "..\3-CostInformation\region_comparison_prices.json"
$rawdata = Get-Content $costComparisonPath | ConvertFrom-Json -Depth 10
$reportData = @()
$uniqueMeterIds = $rawdata | Select-Object -Property OrigMeterId -Unique
foreach ($meterId in $uniqueMeterIds) {
    $meterId = $meterId.OrigMeterId
    # get all occurrences of this meterId in $rawdata
    $meterOccurrences = $rawdata | Where-Object { $_.OrigMeterId -eq $meterId }
    $meterOccurrences
    $basedata = $meterOccurrences | Select-Object -Property ServiceName, MeterName, ProductName, SKUName -Unique
    $serviceName = $basedata.ServiceName
    $meterName = $basedata.MeterName
    $productName = $basedata.ProductName
    $skuName = $basedata.SKUName
    $pricingObj = [PSCustomObject]@{}
    foreach ($occurrence in $meterOccurrences) {
        $region = $occurrence.Region
        if ($region -eq $null -or $region -eq "") {
            $region = "Global"
        }
        "region is $region"

        $retailPrice = $occurrence.RetailPrice
        $priceDiffToOrigin = $occurrence.PriceDiffToOrigin
        $pricingObj | Add-Member -MemberType NoteProperty -Name "$region-RetailPrice" -Value $retailPrice
        $pricingObj | Add-Member -MemberType NoteProperty -Name "$region-PriceDiffToOrigin" -Value $priceDiffToOrigin
    }
    # Create a new object for each unique meter ID
    $costReportItem = [PSCustomObject]@{
        MeterId     = $meterId
        ServiceName = $serviceName
        MeterName   = $meterName
        ProductName = $productName
        SKUName     = $skuName
    } 
    Foreach ($key in $pricingObj.PSObject.Properties.Name) {
        $costReportItem | Add-Member -MemberType NoteProperty -Name $key -Value $pricingObj.$key
    }   
        
    # Add the cost report item to the report data array
    $reportData += $costReportItem      
}

#Define output file name with current timestamp (yyyyMMdd_HHmmss)
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvFileName = "Availability_Report_$timestamp.csv"
$xlsxFileName = "Availability_Report_$timestamp.xlsx"

# $excelParams = @{
#     Path          = $xlsxFileName
#     WorksheetName = "General"
#     AutoSize      = $true
#     TableStyle    = 'None'
#     PassThru      = $true
# }

#$allProps = $reportData | ForEach-Object { $_.PSObject.Properties.Name } | Sort-Object -Unique
# Collect all property names in first-seen order
$allProps = @()
foreach ($obj in $reportData) {
    foreach ($p in $obj.PSObject.Properties.Name) {
        if ($allProps -notcontains $p) {
            $allProps += $p
        }
    }
}

# Export to CSV
$reportData | Select-Object -Property $allProps | Export-Csv -Path $csvFileName -NoTypeInformation

# Make the Excel first row (header) with blue background and white text

$WorksheetName = "Cost"
$lastColumnNumber = $allProps.Count

New-Worksheet -WorksheetName $WorksheetName -LastColumnNumber $lastColumnNumber


