$ErrorActionPreference='Stop'
$repo='Psychologg/Psych0VMod-Releases'
if($env:GITHUB_REPOSITORY -cne $repo){throw 'Wrong publishing repository'}
$plan=Get-Content release-input/plan.json -Raw | ConvertFrom-Json
$output=Join-Path $env:RUNNER_TEMP 'Psych0VMod-publish'
[void](New-Item -ItemType Directory -Path $output -Force)
function Gh([string[]]$Arguments){
    $result=& gh @Arguments
    if($LASTEXITCODE -ne 0){throw ('GitHub command failed: '+$Arguments[0])}
    return $result
}
function VerifyHash($Path,$Expected){
    if($Expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected){throw ('Checksum mismatch: '+$Path)}
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Verify every published ZIP and its own app/mod inventories before any release is created.
foreach($package in $plan.packages){
    $path=Join-Path 'release-input' $package.file
    VerifyHash $path $package.sha256
    $archive=[IO.Compression.ZipFile]::OpenRead((Resolve-Path $path))
    try{
        $ledgers=@($archive.Entries | Where-Object {$_.FullName.EndsWith('/.psych0-release.json')})
        if(!$ledgers.Count){throw 'Missing package inventory'}
        foreach($entry in $ledgers){
            $reader=[IO.StreamReader]::new($entry.Open());try{$ledger=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
            if($ledger.channel -ne $package.channel){throw 'Mixed package channels'}
            $prefix=$entry.FullName.Substring(0,$entry.FullName.LastIndexOf('/')+1)
            foreach($file in $ledger.files){
                $item=$archive.GetEntry($prefix+$file.path)
                if(!$item){throw ('Missing archive file: '+$file.path)}
                $stream=$item.Open();$hasher=[Security.Cryptography.SHA256]::Create()
                try{$actual=[Convert]::ToHexString($hasher.ComputeHash($stream))}finally{$stream.Dispose();$hasher.Dispose()}
                if($actual -ne $file.sha256){throw ('Inventory mismatch: '+$file.path)}
            }
        }
    }finally{$archive.Dispose()}
}
$speechTag='speech-v1.0.0'
$existing=& gh api ('repos/'+$repo+'/releases/tags/'+$speechTag) 2>$null
$speechExists=($LASTEXITCODE -eq 0)
if($speechExists -and !($existing|ConvertFrom-Json).draft){
    # A published dependency is immutable: require GitHub's SHA256 digests to match.
    $assets=($existing|ConvertFrom-Json).assets
    foreach($pack in $plan.speech){
        $asset=@($assets|Where-Object {$_.name -ceq $pack.file})
        if($asset.Count -ne 1 -or $asset[0].digest -cne ('sha256:'+$pack.sha256)){throw 'Published speech dependency differs'}
    }
}else{
    foreach($pack in $plan.speech){
        $destination=Join-Path $output $pack.file
        $stream=[IO.File]::Create($destination)
        try{
            foreach($url in $pack.download_urls){
                $uri=[Uri]$url
                if($uri.Scheme -ne 'https' -or $uri.Host -cne 'psych0vmod-downloads.alight-flute-0599.chatgpt.site' -or $uri.AbsolutePath -notmatch '^/speech/speech-(pl|en)\.\d+\.bin$'){throw 'Invalid bootstrap speech address'}
                $part=Join-Path $output 'speech.part'
                Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $part -TimeoutSec 600
                $inputStream=[IO.File]::OpenRead($part);try{$inputStream.CopyTo($stream)}finally{$inputStream.Dispose()}
                Remove-Item $part -Force
            }
        }finally{$stream.Dispose()}
        VerifyHash $destination $pack.sha256
        $archive=[IO.Compression.ZipFile]::OpenRead($destination);try{if(!$archive.Entries.Count){throw 'Empty speech archive'}}finally{$archive.Dispose()}
    }
    if(!$speechExists){[void](Gh @('release','create',$speechTag,'--repo',$repo,'--draft','--title','Vosk PL/EN — 1.0.0','--notes','Offline speech dependencies, identical SHA256-verified PL/EN packs.'))}
    foreach($pack in $plan.speech){[void](Gh @('release','upload',$speechTag,(Join-Path $output $pack.file),'--repo',$repo,'--clobber'))}
}
foreach($channel in @('public')){
    $tag=$channel+'-v'+$plan.version
    $release=& gh api ('repos/'+$repo+'/releases/tags/'+$tag) 2>$null
    $exists=($LASTEXITCODE -eq 0)
    if($exists -and !($release|ConvertFrom-Json).draft){throw ('Release already published: '+$tag)}
    if(!$exists){[void](Gh @('release','create',$tag,'--repo',$repo,'--draft','--prerelease','--title',('Psych0VMod '+$channel+' '+$plan.version),'--notes-file','release-input/notes.md'))}
    foreach($package in $plan.packages|Where-Object {$_.channel -eq $channel}){[void](Gh @('release','upload',$tag,(Join-Path 'release-input' $package.file),'--repo',$repo,'--clobber'))}
}
# Enable manifests only after all three release sets have been uploaded successfully.
if(!$speechExists -or ($existing|ConvertFrom-Json).draft){[void](Gh @('release','edit',$speechTag,'--repo',$repo,'--draft=false'))}
foreach($channel in @('public')){
    [void](Gh @('release','edit',($channel+'-v'+$plan.version),'--repo',$repo,'--draft=false','--prerelease'))
    $manifest=Get-Content ('channels/'+$channel+'.json') -Raw | ConvertFrom-Json
    $manifest.ready=$true
    $manifest|ConvertTo-Json -Depth 30|Set-Content ('channels/'+$channel+'.json') -Encoding utf8NoBOM
}
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add channels
git commit -m ('Enable verified GitHub update channels for '+$plan.version)
if($LASTEXITCODE -ne 0){throw 'Manifest commit failed'}
git push origin HEAD:main
if($LASTEXITCODE -ne 0){throw 'Manifest push failed'}
Write-Output 'PASS: all release assets uploaded; GitHub Public/Developer manifests enabled'
