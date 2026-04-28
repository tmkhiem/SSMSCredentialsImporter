[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputPath = ".\input.txt",

    [Parameter()]
    [string]$OutputPath = ".\output.regsrvr",

    [Parameter()]
    [string]$GroupName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security

function Escape-XmlText {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    return $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Protect-PasswordForSsms {
    param(
        [string]$Password
    )

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Password)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )

    return [Convert]::ToBase64String($protected)
}

function Get-UriSegment {
    param(
        [string]$Value
    )

    return $Value.Replace('.', '_.')
}

function Parse-EntryName {
    param(
        [string]$EntryName
    )

    $parts = $EntryName -split ':'
    if ($parts.Count -lt 5) {
        throw "Unsupported Entry Name format: $EntryName"
    }

    $serverName = $parts[4].Trim()
    $databaseName = if ($parts.Count -ge 6) { $parts[5].Trim() } else { "" }

    return [pscustomobject]@{
        ServerName   = $serverName
        DatabaseName = $databaseName
    }
}

function Parse-CredentialDump {
    param(
        [string]$Path
    )

    $content = Get-Content -Raw -LiteralPath $Path
    $blocks = $content -split '(?m)^\s*=+\s*$' | Where-Object { $_.Trim() }
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($block in $blocks) {
        $values = @{}

        foreach ($line in ($block -split "`r?`n")) {
            if ($line -match '^(?<key>[^:]+?)\s*:\s*(?<value>.*)$') {
                $values[$matches.key.Trim()] = $matches.value.Trim()
            }
        }

        if (-not $values.ContainsKey('Entry Name')) {
            continue
        }

        $target = Parse-EntryName -EntryName $values['Entry Name']

        $entries.Add([pscustomobject]@{
            EntryName    = $values['Entry Name']
            UserName     = $values['User Name']
            Password     = $values['Password']
            ServerName   = $target.ServerName
            DatabaseName = $target.DatabaseName
        })
    }

    return $entries
}

function New-ConnectionString {
    param(
        [string]$ServerName,
        [string]$DatabaseName,
        [string]$UserName,
        [string]$Password
    )

    $segments = New-Object System.Collections.Generic.List[string]
    $segments.Add("data source=$ServerName")

    if ($DatabaseName) {
        $segments.Add("initial catalog=$DatabaseName")
    }

    $segments.Add("user id=$UserName")
    $segments.Add("password=$(Protect-PasswordForSsms -Password $Password)")
    $segments.Add("pooling=False")
    $segments.Add("multiple active result sets=False")
    $segments.Add("connect timeout=30")
    $segments.Add("encrypt=False")
    $segments.Add("trust server certificate=False")
    $segments.Add("packet size=4096")
    $segments.Add('application name="Microsoft SQL Server Management Studio"')
    $segments.Add("command timeout=0")

    return ($segments -join ';')
}

$entries = Parse-CredentialDump -Path $InputPath
if ($entries.Count -eq 0) {
    throw "No credential entries were parsed from '$InputPath'."
}

$databaseEngineGroupUri = "/RegisteredServersStore/ServerGroup/DatabaseEngineServerGroup"
if (-not $GroupName) {
    $GroupName = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
}
if (-not $GroupName) {
    $GroupName = "Imported Servers"
}

$groupUri = "$databaseEngineGroupUri/ServerGroup/$GroupName"
$documents = New-Object System.Collections.Generic.List[string]
$references = New-Object System.Collections.Generic.List[string]
$usedIds = @{}

foreach ($entry in $entries) {
    $displayName = $entry.ServerName
    if ($entry.DatabaseName) {
        $displayName = "$displayName [$($entry.DatabaseName)]"
    }

    $uriSegment = Get-UriSegment -Value $displayName
    $suffix = 2
    while ($usedIds.ContainsKey($uriSegment)) {
        $displayName = if ($entry.DatabaseName) {
            "$($entry.ServerName) [$($entry.DatabaseName)] ($suffix)"
        }
        else {
            "$($entry.ServerName) ($suffix)"
        }
        $uriSegment = Get-UriSegment -Value $displayName
        $suffix++
    }
    $usedIds[$uriSegment] = $true

    $serverUri = "$groupUri/RegisteredServer/$uriSegment"
    $connectionString = New-ConnectionString `
        -ServerName $entry.ServerName `
        -DatabaseName $entry.DatabaseName `
        -UserName $entry.UserName `
        -Password $entry.Password

    $references.Add(@"
                          <sfc:Reference sml:ref="true">
                            <sml:Uri>$(Escape-XmlText -Value $serverUri)</sml:Uri>
                          </sfc:Reference>
"@)

    $documents.Add(@"
                <document>
                  <docinfo>
                    <aliases>
                      <alias>$(Escape-XmlText -Value $serverUri)</alias>
                    </aliases>
                    <sfc:version DomainVersion="1" />
                  </docinfo>
                  <data>
                    <RegisteredServers:RegisteredServer xmlns:RegisteredServers="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08" xmlns:sml="http://schemas.serviceml.org/sml/2007/02" xmlns:xs="http://www.w3.org/2001/XMLSchema">
                      <RegisteredServers:Parent>
                        <sfc:Reference sml:ref="true">
                          <sml:Uri>$groupUri</sml:Uri>
                        </sfc:Reference>
                      </RegisteredServers:Parent>
                      <RegisteredServers:Name type="string">$(Escape-XmlText -Value $displayName)</RegisteredServers:Name>
                      <RegisteredServers:Description type="string">$(Escape-XmlText -Value $entry.DatabaseName)</RegisteredServers:Description>
                      <RegisteredServers:ServerName type="string">$(Escape-XmlText -Value $entry.ServerName)</RegisteredServers:ServerName>
                      <RegisteredServers:UseCustomConnectionColor type="boolean">false</RegisteredServers:UseCustomConnectionColor>
                      <RegisteredServers:CustomConnectionColorArgb type="int">-986896</RegisteredServers:CustomConnectionColorArgb>
                      <RegisteredServers:ServerType type="ServerType">DatabaseEngine</RegisteredServers:ServerType>
                      <RegisteredServers:ConnectionStringWithEncryptedPassword type="string">$(Escape-XmlText -Value $connectionString)</RegisteredServers:ConnectionStringWithEncryptedPassword>
                      <RegisteredServers:CredentialPersistenceType type="CredentialPersistenceType">PersistLoginNameAndPassword</RegisteredServers:CredentialPersistenceType>
                      <RegisteredServers:OtherParams type="string" />
                      <RegisteredServers:AuthenticationType type="int">1</RegisteredServers:AuthenticationType>
                      <RegisteredServers:ActiveDirectoryTenant type="string" />
                    </RegisteredServers:RegisteredServer>
                  </data>
                </document>
"@)
}

$modelId = [guid]::NewGuid()
$xml = @"
<?xml version="1.0"?>
<model xmlns="http://schemas.serviceml.org/smlif/2007/02">
  <identity>
    <name>urn:uuid:$modelId</name>
    <baseURI>http://documentcollection/</baseURI>
  </identity>
  <xs:bufferSchema xmlns:xs="http://www.w3.org/2001/XMLSchema">
    <definitions xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08">
      <document>
        <docinfo>
          <aliases>
            <alias>/system/schema/RegisteredServers</alias>
          </aliases>
          <sfc:version DomainVersion="1" />
        </docinfo>
        <data>
          <xs:schema targetNamespace="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08" xmlns:sml="http://schemas.serviceml.org/sml/2007/02" xmlns:xs="http://www.w3.org/2001/XMLSchema" elementFormDefault="qualified">
            <xs:element name="ServerGroup">
              <xs:complexType>
                <xs:sequence>
                  <xs:any namespace="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" processContents="skip" minOccurs="0" maxOccurs="unbounded" />
                </xs:sequence>
              </xs:complexType>
            </xs:element>
            <xs:element name="RegisteredServer">
              <xs:complexType>
                <xs:sequence>
                  <xs:any namespace="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" processContents="skip" minOccurs="0" maxOccurs="unbounded" />
                </xs:sequence>
              </xs:complexType>
            </xs:element>
            <RegisteredServers:bufferData xmlns:RegisteredServers="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08">
              <instances xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08">
                <document>
                  <docinfo>
                    <aliases>
                      <alias>$groupUri</alias>
                    </aliases>
                    <sfc:version DomainVersion="1" />
                  </docinfo>
                  <data>
                    <RegisteredServers:ServerGroup xmlns:RegisteredServers="http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08" xmlns:sfc="http://schemas.microsoft.com/sqlserver/sfc/serialization/2007/08" xmlns:sml="http://schemas.serviceml.org/sml/2007/02" xmlns:xs="http://www.w3.org/2001/XMLSchema">
                      <RegisteredServers:RegisteredServers>
                        <sfc:Collection>
$($references -join "`r`n")
                        </sfc:Collection>
                      </RegisteredServers:RegisteredServers>
                      <RegisteredServers:Parent>
                        <sfc:Reference sml:ref="true">
                          <sml:Uri>$databaseEngineGroupUri</sml:Uri>
                        </sfc:Reference>
                      </RegisteredServers:Parent>
                      <RegisteredServers:Name type="string">$(Escape-XmlText -Value $GroupName)</RegisteredServers:Name>
                      <RegisteredServers:ServerType type="ServerType">DatabaseEngine</RegisteredServers:ServerType>
                    </RegisteredServers:ServerGroup>
                  </data>
                </document>
$($documents -join "`r`n")
              </instances>
            </RegisteredServers:bufferData>
          </xs:schema>
        </data>
      </document>
    </definitions>
  </xs:bufferSchema>
</model>
"@

$outputDirectory = Split-Path -Parent $OutputPath
if (-not $outputDirectory) {
    $outputDirectory = "."
}

$resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outputDirectory)
if (-not (Test-Path -LiteralPath $resolvedOutputDirectory)) {
    New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
}

$resolvedOutputPath = Join-Path $resolvedOutputDirectory (Split-Path -Leaf $OutputPath)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($resolvedOutputPath, $xml, $utf8NoBom)

Write-Host "Wrote $($entries.Count) registered server entries to '$resolvedOutputPath'."
Write-Host "Passwords were protected with DPAPI for the current Windows user."
