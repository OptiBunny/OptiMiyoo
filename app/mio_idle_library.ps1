# Small, finite gestures preserve the resting silhouette and original palette.
# Call once after the original poses exist; no clock or random work occurs here.
function Initialize-MioIdleLibrary([hashtable]$Frames) {
    if ($Frames.ContainsKey('idleearleft') -and $script:MioIdleGestures) {return}
    $addPose = {
        param([string]$Name,[string]$Base,[hashtable]$Rows)
        [string[]]$copy=$Frames[$Base].Clone()
        foreach ($row in $Rows.Keys) {$copy[[int]$row]=$Rows[$row]}
        $Frames[$Name]=$copy
    }
    # Only the named changed rows are copied; every original pose stays intact.
    & $addPose 'idlewinkleft' 'idle' @{
        11='...OWWWWWWWWWWDWWWO...'
        12='...OWWDDDWWWWWDWWWO...'
    }
    & $addPose 'idleearleft' 'idle' @{
        0='......OO.....OO.......'
        1='.....OWWO...OWWO......'
        2='.....OWWO...OWWO......'
    }
    & $addPose 'idleearright' 'idle' @{
        0='.......OO.....OO......'
        1='......OWWO...OWWO.....'
        2='......OWWO...OWWO.....'
    }
    & $addPose 'idleperk' 'idle' @{
        0='......OO......OO......'
        1='.....OWWO....OWWO.....'
        2='.....OWWO....OWWO.....'
    }
    & $addPose 'idlelookup' 'idle' @{
        10='....OWWDWWWWWWDWWO....'
        12='...OWWWWWWWWWWWWWWO...'
    }
    # Squash a repeated body row for the crouch, then a repeated inner-ear
    # row for the lift. The complete ear tips and feet stay inside the frame.
    [string[]]$Frames['idlehopcrouch']=@('......................') + $Frames['idle'][0..18] + $Frames['idle'][20..23]
    [string[]]$Frames['idlehopup']=$Frames['happy'][0..3] + $Frames['happy'][5..23] + @('......................')
    & $addPose 'idlegroomlow' 'blink' @{
        14='...OWOOOWDWDWWWWWWO...'
        15='....OWWWOWWWWWWWWO....'
        16='.....OWWOSSSSSSSO.....'
        18='......OSSSSSSWWSWOWWO.'
        19='......OSSSSSSWWSWOWWO.'
    }
    & $addPose 'idlegroomhigh' 'blink' @{
        13='...OWOOOWWDWWWWBBWO...'
        14='...OOWWWODWDWWWWWWO...'
        15='....OOWWOWWWWWWWWO....'
        16='.....OOOSSSSSSSSO.....'
        18='......OSSSSSSWWSWOWWO.'
        19='......OSSSSSSWWSWOWWO.'
    }
    & $addPose 'idlesniffleft' 'idle' @{
        13='...OWBBWWDWWWWWBBWO...'
        14='...OWWWWDWDWWWWWWWO...'
    }
    & $addPose 'idlesniffright' 'idle' @{
        13='...OWBBWWWWDWWWBBWO...'
        14='...OWWWWWWDWDWWWWWO...'
    }
    & $addPose 'idletailup' 'idle' @{
        16='.....OSSSSSSSSSSOOO...'
        17='......OOSSOOOSSOOWWO..'
        18='......OSWWSSSWWSWWWWO.'
        19='......OSWWSSSWWSWWWO..'
        20='.......OSSSSSSSSOOO...'
    }
    & $addPose 'idletailout' 'idle' @{
        17='......OOSSOOOSSOOOOO..'
        18='......OSWWSSSWWSWWWWO.'
        19='......OSWWSSSWWSWWWWO.'
        20='.......OSSSSSSSSOWWO..'
    }
    & $addPose 'idlenod' 'blink' @{
        12='...OWWWWWWWWWWWWWWO...'
        13='...OWBDDDWWWDDDBBWO...'
        14='...OWWWWWWDWWWWWWWO...'
        15='....OWWWWDWDWWWWWO....'
    }

    # The scheduler returns to idle after each finite sequence.
    $script:MioIdleGestures=@(
        [pscustomobject]@{Id='blink';Name='Blink';Frames=@(
            [pscustomobject]@{Pose='blink';DurationMs=140}
        )},
        [pscustomobject]@{Id='doubleblink';Name='Double blink';Frames=@(
            [pscustomobject]@{Pose='blink';DurationMs=120},
            [pscustomobject]@{Pose='idle';DurationMs=180},
            [pscustomobject]@{Pose='blink';DurationMs=140}
        )},
        [pscustomobject]@{Id='slowblink';Name='Sleepy blink';Frames=@(
            [pscustomobject]@{Pose='wait';DurationMs=180},
            [pscustomobject]@{Pose='blink';DurationMs=240},
            [pscustomobject]@{Pose='wait';DurationMs=180}
        )},
        [pscustomobject]@{Id='lookaround';Name='Curious glance';Frames=@(
            [pscustomobject]@{Pose='scanleft';DurationMs=260},
            [pscustomobject]@{Pose='idle';DurationMs=120},
            [pscustomobject]@{Pose='scanright';DurationMs=260}
        )},
        [pscustomobject]@{Id='lookup';Name='Look up';Frames=@(
            [pscustomobject]@{Pose='idlelookup';DurationMs=300},
            [pscustomobject]@{Pose='blink';DurationMs=120}
        )},
        [pscustomobject]@{Id='winkright';Name='Right wink';Frames=@(
            [pscustomobject]@{Pose='check';DurationMs=280},
            [pscustomobject]@{Pose='happy';DurationMs=200}
        )},
        [pscustomobject]@{Id='winkleft';Name='Left wink';Frames=@(
            [pscustomobject]@{Pose='idlewinkleft';DurationMs=280},
            [pscustomobject]@{Pose='happy';DurationMs=200}
        )},
        [pscustomobject]@{Id='earleft';Name='Left ear flick';Frames=@(
            [pscustomobject]@{Pose='idleearleft';DurationMs=140},
            [pscustomobject]@{Pose='idle';DurationMs=100},
            [pscustomobject]@{Pose='idleearleft';DurationMs=120}
        )},
        [pscustomobject]@{Id='earright';Name='Right ear flick';Frames=@(
            [pscustomobject]@{Pose='idleearright';DurationMs=140},
            [pscustomobject]@{Pose='idle';DurationMs=100},
            [pscustomobject]@{Pose='idleearright';DurationMs=120}
        )},
        [pscustomobject]@{Id='perk';Name='Ears perk up';Frames=@(
            [pscustomobject]@{Pose='idleperk';DurationMs=240},
            [pscustomobject]@{Pose='happy';DurationMs=240}
        )},
        [pscustomobject]@{Id='hop';Name='Happy hop';Frames=@(
            [pscustomobject]@{Pose='idlehopcrouch';DurationMs=180},
            [pscustomobject]@{Pose='idlehopup';DurationMs=240},
            [pscustomobject]@{Pose='idlehopcrouch';DurationMs=140},
            [pscustomobject]@{Pose='happy';DurationMs=220}
        )},
        [pscustomobject]@{Id='groom';Name='Cheek rub';Frames=@(
            [pscustomobject]@{Pose='idlegroomlow';DurationMs=200},
            [pscustomobject]@{Pose='idlegroomhigh';DurationMs=220},
            [pscustomobject]@{Pose='idlegroomlow';DurationMs=180}
        )},
        [pscustomobject]@{Id='tail';Name='Tail wiggle';Frames=@(
            [pscustomobject]@{Pose='idletailup';DurationMs=180},
            [pscustomobject]@{Pose='idletailout';DurationMs=180},
            [pscustomobject]@{Pose='idletailup';DurationMs=180}
        )},
        [pscustomobject]@{Id='sniff';Name='Tiny sniff';Frames=@(
            [pscustomobject]@{Pose='idlesniffleft';DurationMs=140},
            [pscustomobject]@{Pose='idlesniffright';DurationMs=140},
            [pscustomobject]@{Pose='idlesniffleft';DurationMs=140}
        )},
        [pscustomobject]@{Id='nod';Name='Sleepy nod';Frames=@(
            [pscustomobject]@{Pose='wait';DurationMs=200},
            [pscustomobject]@{Pose='idlenod';DurationMs=260},
            [pscustomobject]@{Pose='blink';DurationMs=180},
            [pscustomobject]@{Pose='wait';DurationMs=180}
        )},
        [pscustomobject]@{Id='happypaws';Name='Happy paws';Frames=@(
            [pscustomobject]@{Pose='happy';DurationMs=200},
            [pscustomobject]@{Pose='happyturn';DurationMs=260},
            [pscustomobject]@{Pose='happy';DurationMs=200}
        )}
    )
}
