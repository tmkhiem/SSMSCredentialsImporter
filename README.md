# SSMS Registered Server Import Generator

*Preface:* 

Due to negligence on my part, I deferred updating my rusty SSMS 19 installation a few (hundred) times. At some point, one has to throw his towel and call it a day. 

There is a bug in SSMS 19 that bogs down my machine (which almost never shuts down) from time to time, which causes Task manager to be paused (this is my theory, because at the time I'm writing this, an uptime of 4 days without SSMS 19 has not caused task manager to be paused.

However, also due to my grossly insecure practices, I saved most (hundreds) of my SQL Server connections in SSMS 19. I need them all imported into SSMS 22 (latest at time of writing).

Upon first startup, SSMS shows a very promising dialog allowing one to import from earlier versions of SSMS. This is documented here: https://learn.microsoft.com/en-us/ssms/tutorials/import-export-settings. Don't be fooled -- that only import settings, and the passwords won't be migrated over. You will end up with a bunch of password-less connections that will error as soon as you connect.

This has led me to figure out a way to migrate my precious connections over, and hence this tool was written.

I hope whoever you are, you can benefit from this.

---

This tool converts a CredentialFileView-style `input.txt` export into an SSMS `.regsrvr` import file. 

Credential File View can be downloaded here: https://www.nirsoft.net/utils/credentials_file_view.html 

It is intended for credentials stored by SQL Server Management Studio and exported in the repeated key/value block format shown in input.txt

## Files

- [generate-regsrvr.ps1](F:\credentialsfileview-x64\codex\generate-regsrvr.ps1): PowerShell script that reads the credential dump and writes an SSMS import file
- [input.txt](F:\credentialsfileview-x64\codex\input.txt): example input
- [sample-output.regsrvr](F:\credentialsfileview-x64\codex\sample-output.regsrvr): sample SSMS export used as a format reference

## What It Does

For each entry in `input.txt`, the script:

1. Parses `Entry Name`
2. Extracts the SQL Server target and database name
3. Reads `User Name` and `Password`
4. Protects the password with Windows DPAPI for the current user
5. Writes a `.regsrvr` XML file that SSMS can import

The generated file creates a child group under SSMS `DatabaseEngineServerGroup` instead of trying to recreate the built-in root group. This avoids the SSMS import error:

`An entry with the same key already exists`

## Input Format

The script expects repeated blocks like this:

```text
==================================================
Entry Name        : LegacyGeneric:target=Microsoft:SSMS:19:1.2.3.4,12345:dbname:8c91a03d-f9b4-46c0-a305-b5dcc79ff907:1
User Name         : dbuser
Password          : dbpassword
==================================================
```

The important fields are:

- `Entry Name`
- `User Name`
- `Password`

From `Entry Name`, the script expects this layout:

```text
LegacyGeneric:target=Microsoft:SSMS:19:<server>:<database>:<guid>:1
```

## Usage

Run the script from this directory:

```powershell
.\generate-regsrvr.ps1 -InputPath .\input.txt -OutputPath .\servers.regsrvr
```

Example with an explicit SSMS group name:

```powershell
.\generate-regsrvr.ps1 `
  -InputPath .\input.txt `
  -OutputPath .\servers.regsrvr `
  -GroupName 'Imported from CredentialFileView'
```

## Parameters

- `-InputPath`
  Path to the CredentialFileView text export

- `-OutputPath`
  Path to the generated `.regsrvr` file

- `-GroupName`
  Optional SSMS group name to create under `DatabaseEngineServerGroup`

If `-GroupName` is omitted, the script uses the output filename without extension.

## Importing Into SSMS

1. Open SSMS
2. Open `Registered Servers`
3. Expand `Database Engine`
4. Right-click `Local Server Groups` or a child group
5. Choose `Tasks` -> `Import`
6. Select the generated `.regsrvr` file

The import should create a child group containing the generated server entries.

## Important Notes

- Passwords are protected with Windows DPAPI for the current Windows user.
- The generated file is intended to be imported by the same Windows user account that generated it.
- Importing the same file more than once with the same `GroupName` will create a group-name collision in SSMS.
- If two input entries point to the same server and database, the script adds a numeric suffix to keep registered server names unique.

## Example

Generate a file named `ssms19.regsrvr`:

```powershell
.\generate-regsrvr.ps1 -InputPath .\input.txt -OutputPath .\ssms19.regsrvr
```

This will create an SSMS child group named `ssms19`.

## Troubleshooting

`String was not properly escaped`

- This usually points to a malformed `.regsrvr` payload or an incompatible manually edited file.
- Regenerate the file with the script instead of editing the XML by hand.

`An entry with the same key already exists`

- This usually means the target SSMS group name already exists.
- Use a different `-GroupName`, or delete the old imported child group before importing again.

`No credential entries were parsed`

- Check that `input.txt` still uses the expected CredentialFileView block format.

## Requirements

- Windows
- PowerShell 5.1 or later
- SSMS-style credential input exported to text
