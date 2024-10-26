#!/usr/bin/pwsh
param(
    [string]$Method = "GET",
    [string]$Key = (Get-Content "${PSScriptRoot}/apikey"),
    [string]$Api = "https://api.ouraring.com/v2/usercollection/daily_readiness",
    [string[]]$IncludeData = ('temperature_deviation', 'temperature_trend_deviation'),
    [string]$LokiUrl = "http://loki.nuc.home.arpa:3100/loki/api/v1/push"
)

Write-Host $Method $Api
$Response = Invoke-WebRequest -Method $Method -Headers @{ "Authorization" = "Bearer $key" } -Uri $Api | ConvertFrom-Json -AsHashTable

$values = New-Object System.Collections.ArrayList
foreach ($data in $Response.data)
{
    $line = New-Object System.Collections.ArrayList

    # 通常の階層
    $line.Add($data) > $null
    # 下の階層(e.g. contributors)を掘って同列に
    $data.Keys | ForEach-Object {
        if ($data.$_.GetType().Name -eq "OrderedHashtable")
        {
            $line.Add($data.$_) > $null
        }
    }

    # Lokiが対応するUnixTime(ns)形式
    $timestamp = $data.timestamp ? $data.timestamp : $data.day | ForEach-Object { ([datetimeoffset]$_).ToUnixTimeMilliSeconds() * 1000000 }

    # [timestamp, "key=value"]
    $line.Keys | Where-Object {$_ -in $IncludeData} | ForEach-Object {
        $values.Add(@(
            "$timestamp",
            ("{0}={1}" -f $_, $line.$_)
        )) > $null
    }
}

# Ingest logs
$body =
@{
    streams =
    @(
        @{
            stream =
            @{
                # daily_readiness
                oura = "$([Regex]::Replace($Api, "^.*/([^?]*).*?$", { $args.Groups[1].value }))"
            }
            values = $values
        }
    )
} | ConvertTo-Json -Depth 5
Write-Host $body

Invoke-RestMethod -Method Post -Uri $LokiUrl -ContentType "application/json" -Body $body
