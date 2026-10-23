# Keep filenames and converter diagnostics as data when displaying or exporting.
function ConvertTo-SafeExternalText([string]$Text) {
    return [regex]::Replace($Text,'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]','')
}

function ConvertTo-SafeReportRow {
    param([Parameter(Mandatory=$true,ValueFromPipeline=$true)][psobject]$InputObject)
    process {
        $row=[ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $value=$property.Value
            if ($value -is [string] -and $value -match '^[\s\x00-\x1f]*[=+@\-\uFF1D\uFF0B\uFF0D\uFF20]') {
                # CSV quoting protects delimiters, not spreadsheet formulas.
                # Prefix only the exported field; real paths and result objects
                # retain their exact names for conversion and source verification.
                $value="'"+$value
            }
            $row[$property.Name]=$value
        }
        [pscustomobject]$row
    }
}
