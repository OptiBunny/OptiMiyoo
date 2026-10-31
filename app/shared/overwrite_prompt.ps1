# Shared overwrite questions use a bounded body even for long conflict lists.
function Get-OverwriteChoiceRows {
    return @('Y Overwrite | N Skip [Enter = N]', 'A Overwrite all | S Skip all', 'B / Esc Back to settings | Q Quit')
}

function Get-OverwriteInputPrompt {return 'Overwrite? [Enter = N]'}

function ConvertFrom-OverwriteAnswer([AllowEmptyString()][string]$Answer) {
    switch ($Answer.Trim().ToUpperInvariant()) {
        'Y' {return 'Overwrite'}
        'A' {return 'OverwriteAll'}
        'S' {return 'SkipAll'}
        {$_ -in '', 'N'} {return 'Skip'}
        'B' {return 'Back'}
        'Q' {return 'Exit'}
    }
    return $null
}
