$script:UsersPath = $null
$script:UsersMutexName = "Global\BatSchedulerUsers"
$script:SessionMutexName = "Global\BatSchedulerSessions"
$script:Sessions = @{}
$script:SessionCookieName = "bat_session"
$script:SessionHours = 24
$script:PasswordIterations = 100000

function Initialize-Auth {
    param([Parameter(Mandatory = $true)][string]$DataDir)

    if (-not (Test-Path $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir | Out-Null
    }

    $script:UsersPath = Join-Path $DataDir "users.json"
    if (-not (Test-Path $script:UsersPath)) {
        $admin = New-AuthUserRecord -Username "admin" -Password "3M1234" -Role "admin"
        $store = @{ users = @($admin) }
        Write-UserStore $store
        return
    }

    $store = Read-UserStore
    $hasAdmin = @($store.users | Where-Object { $_.username -eq "admin" }).Count -gt 0
    if (-not $hasAdmin) {
        $admin = New-AuthUserRecord -Username "admin" -Password "3M1234" -Role "admin"
        $store.users = @($admin) + @($store.users)
        Write-UserStore $store
    }
}

function New-PasswordHash {
    param([Parameter(Mandatory = $true)][string]$Password)

    $saltBytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
    $pbkdf2 = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password,
        $saltBytes,
        $script:PasswordIterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $hashBytes = $pbkdf2.GetBytes(32)
    $pbkdf2.Dispose()

    return @{
        salt       = [Convert]::ToBase64String($saltBytes)
        hash       = [Convert]::ToBase64String($hashBytes)
        iterations = $script:PasswordIterations
    }
}

function Test-Password {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)]$UserRecord
    )

    $saltBytes = [Convert]::FromBase64String([string]$UserRecord.passwordSalt)
    $expected = [Convert]::FromBase64String([string]$UserRecord.passwordHash)
    $iterations = [int]$UserRecord.iterations
    if ($iterations -lt 1) { $iterations = $script:PasswordIterations }

    $pbkdf2 = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password,
        $saltBytes,
        $iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $actual = $pbkdf2.GetBytes($expected.Length)
    $pbkdf2.Dispose()

    if ($actual.Length -ne $expected.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $actual.Length; $i++) {
        $diff = $diff -bor ($actual[$i] -bxor $expected[$i])
    }
    return ($diff -eq 0)
}

function New-AuthUserRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Role = "user"
    )

    $hash = New-PasswordHash -Password $Password
    return [ordered]@{
        username     = $Username
        role         = $Role
        passwordSalt = $hash.salt
        passwordHash = $hash.hash
        iterations   = $hash.iterations
        createdAt    = (Get-Date).ToString("o")
    }
}

function Read-UserStore {
    $raw = Get-Content -Path $script:UsersPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ users = @() }
    }
    $obj = $raw | ConvertFrom-Json
    if ($null -eq $obj.users) {
        $obj | Add-Member -NotePropertyName users -NotePropertyValue @() -Force
    }
    if ($obj.users -isnot [System.Array]) {
        $obj.users = @($obj.users)
    }
    return $obj
}

function Write-UserStore($store) {
    $json = $store | ConvertTo-Json -Depth 8
    Set-Content -Path $script:UsersPath -Value $json -Encoding UTF8
}

function Test-UsernameFormat([string]$username) {
    if ([string]::IsNullOrWhiteSpace($username)) {
        return "Username is required"
    }
    if ($username.Length -lt 3 -or $username.Length -gt 32) {
        return "Username length must be 3-32"
    }
    if ($username -notmatch '^[A-Za-z0-9_]+$') {
        return "Username may only contain letters, numbers, underscore"
    }
    return $null
}

function Get-PublicUser($userRecord) {
    return @{
        username  = [string]$userRecord.username
        role      = [string]$userRecord.role
        createdAt = [string]$userRecord.createdAt
    }
}

function Get-CookieValue {
    param($Request, [string]$Name)

    $header = $Request.Headers["Cookie"]
    if ([string]::IsNullOrWhiteSpace($header)) { return $null }

    foreach ($part in $header.Split(";")) {
        $piece = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($piece)) { continue }
        $eq = $piece.IndexOf("=")
        if ($eq -lt 1) { continue }
        $key = $piece.Substring(0, $eq).Trim()
        if ($key -ne $Name) { continue }
        return $piece.Substring($eq + 1).Trim()
    }
    return $null
}

function Add-SetCookieHeader {
    param($Response, [string]$Value)
    $Response.Headers.Add("Set-Cookie", $Value)
}

function New-SessionToken {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).Replace("+", "-").Replace("/", "_").TrimEnd("=")
}

function New-AuthSession {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $token = New-SessionToken
    $now = Get-Date
    $session = @{
        token     = $token
        username  = $Username
        role      = $Role
        createdAt = $now
        expiresAt = $now.AddHours($script:SessionHours)
    }

    $mutex = New-Object System.Threading.Mutex($false, $script:SessionMutexName)
    $locked = $false
    try {
        $locked = $mutex.WaitOne(10000)
        $script:Sessions[$token] = $session
    } finally {
        if ($locked) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
    return $session
}

function Remove-AuthSession([string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    $mutex = New-Object System.Threading.Mutex($false, $script:SessionMutexName)
    $locked = $false
    try {
        $locked = $mutex.WaitOne(10000)
        if ($script:Sessions.ContainsKey($Token)) {
            $script:Sessions.Remove($Token) | Out-Null
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
}

function Get-RequestSession($Request) {
    $token = Get-CookieValue -Request $Request -Name $script:SessionCookieName
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }

    $mutex = New-Object System.Threading.Mutex($false, $script:SessionMutexName)
    $locked = $false
    try {
        $locked = $mutex.WaitOne(10000)
        if (-not $script:Sessions.ContainsKey($token)) { return $null }
        $session = $script:Sessions[$token]
        if ((Get-Date) -gt $session.expiresAt) {
            $script:Sessions.Remove($token) | Out-Null
            return $null
        }
        return $session
    } finally {
        if ($locked) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
}

function Test-AuthPublicStatic([string]$Path) {
    switch ($Path.ToLowerInvariant()) {
        "/login.html" { return $true }
        "/login.js" { return $true }
        "/styles.css" { return $true }
        default { return $false }
    }
}

function Send-Unauthorized {
    param($Response, [string]$Message = "Unauthorized")
    Send-Json $Response 401 @{ error = $Message }
}

function Send-Forbidden {
    param($Response, [string]$Message = "Forbidden")
    Send-Json $Response 403 @{ error = $Message }
}

function Send-Redirect {
    param($Response, [string]$Location, [int]$StatusCode = 302)
    $Response.StatusCode = $StatusCode
    $Response.RedirectLocation = $Location
    $Response.ContentLength64 = 0
    $Response.OutputStream.Close()
}

function Set-SessionCookie {
    param($Response, [string]$Token)
    $maxAge = $script:SessionHours * 3600
    Add-SetCookieHeader $Response "$($script:SessionCookieName)=$Token; Path=/; HttpOnly; SameSite=Lax; Max-Age=$maxAge"
}

function Clear-SessionCookie {
    param($Response)
    Add-SetCookieHeader $Response "$($script:SessionCookieName)=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
}

function Handle-AuthApi {
    param($Request, $Response)

    $method = $Request.HttpMethod.ToUpperInvariant()
    $path = $Request.Url.AbsolutePath.TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }

    if ($method -eq "POST" -and $path -eq "/api/auth/login") {
        $bodyText = Get-RequestBody $Request
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
            Send-Json $Response 400 @{ error = "Missing request body" }
            return
        }
        $body = $bodyText | ConvertFrom-Json
        $username = [string]$body.username
        $password = [string]$body.password

        if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
            Send-Json $Response 400 @{ error = "Invalid username or password" }
            return
        }

        $store = Read-UserStore
        $user = @($store.users | Where-Object { $_.username -eq $username } | Select-Object -First 1)
        if (-not $user -or -not (Test-Password -Password $password -UserRecord $user)) {
            Send-Json $Response 401 @{ error = "Invalid username or password" }
            return
        }

        $session = New-AuthSession -Username $user.username -Role $user.role
        Set-SessionCookie -Response $Response -Token $session.token
        Send-Json $Response 200 @{ ok = $true; user = (Get-PublicUser $user) }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/auth/logout") {
        $token = Get-CookieValue -Request $Request -Name $script:SessionCookieName
        Remove-AuthSession $token
        Clear-SessionCookie $Response
        Send-Json $Response 200 @{ ok = $true }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/auth/me") {
        $session = Get-RequestSession $Request
        if (-not $session) {
            Send-Unauthorized $Response
            return
        }
        Send-Json $Response 200 @{
            user = @{
                username = $session.username
                role     = $session.role
            }
        }
        return
    }

    Send-Json $Response 404 @{ error = "API not found" }
}

function Test-IsAdmin($Session) {
    return ($Session -and $Session.role -eq "admin")
}

function Get-AdminCount($store) {
    return @($store.users | Where-Object { $_.role -eq "admin" }).Count
}

function Handle-UsersApi {
    param($Request, $Response, $Session)

    if (-not (Test-IsAdmin $Session)) {
        Send-Forbidden $Response "Admin only"
        return
    }

    $method = $Request.HttpMethod.ToUpperInvariant()
    $path = $Request.Url.AbsolutePath.TrimEnd("/")

    if ($method -eq "GET" -and $path -eq "/api/users") {
        $store = Read-UserStore
        $items = @($store.users | ForEach-Object { Get-PublicUser $_ })
        Send-Json $Response 200 @{ items = $items }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/users") {
        $bodyText = Get-RequestBody $Request
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
            Send-Json $Response 400 @{ error = "Missing request body" }
            return
        }
        $body = $bodyText | ConvertFrom-Json
        $username = [string]$body.username
        $password = [string]$body.password
        $role = [string]$body.role
        if ([string]::IsNullOrWhiteSpace($role)) { $role = "user" }
        if ($role -ne "admin" -and $role -ne "user") {
            Send-Json $Response 400 @{ error = "Invalid role" }
            return
        }

        $userError = Test-UsernameFormat $username
        if ($userError) {
            Send-Json $Response 400 @{ error = $userError }
            return
        }
        if ([string]::IsNullOrWhiteSpace($password) -or $password.Length -lt 4) {
            Send-Json $Response 400 @{ error = "Password must be at least 4 characters" }
            return
        }

        $mutex = New-Object System.Threading.Mutex($false, $script:UsersMutexName)
        $locked = $false
        try {
            $locked = $mutex.WaitOne(15000)
            if (-not $locked) { throw "User store is busy" }

            $store = Read-UserStore
            $exists = @($store.users | Where-Object { $_.username -eq $username }).Count -gt 0
            if ($exists) {
                Send-Json $Response 409 @{ error = "Username already exists" }
                return
            }

            $record = New-AuthUserRecord -Username $username -Password $password -Role $role
            $store.users = @($store.users) + @($record)
            Write-UserStore $store
            Send-Json $Response 201 @{ user = (Get-PublicUser $record) }
        } finally {
            if ($locked) { $mutex.ReleaseMutex() | Out-Null }
            $mutex.Dispose()
        }
        return
    }

    if ($method -eq "PUT" -and $path -match '^/api/users/([A-Za-z0-9_]+)$') {
        $targetName = $Matches[1]
        $bodyText = Get-RequestBody $Request
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
            Send-Json $Response 400 @{ error = "Missing request body" }
            return
        }
        $body = $bodyText | ConvertFrom-Json
        $newPassword = [string]$body.password
        $newRole = [string]$body.role

        $mutex = New-Object System.Threading.Mutex($false, $script:UsersMutexName)
        $locked = $false
        try {
            $locked = $mutex.WaitOne(15000)
            if (-not $locked) { throw "User store is busy" }

            $store = Read-UserStore
            $user = @($store.users | Where-Object { $_.username -eq $targetName } | Select-Object -First 1)
            if (-not $user) {
                Send-Json $Response 404 @{ error = "User not found" }
                return
            }

            if (-not [string]::IsNullOrWhiteSpace($newRole)) {
                if ($newRole -ne "admin" -and $newRole -ne "user") {
                    Send-Json $Response 400 @{ error = "Invalid role" }
                    return
                }
                if ($user.role -eq "admin" -and $newRole -ne "admin" -and (Get-AdminCount $store) -le 1) {
                    Send-Json $Response 400 @{ error = "Cannot remove the last admin" }
                    return
                }
                $user.role = $newRole
            }

            if (-not [string]::IsNullOrWhiteSpace($newPassword)) {
                if ($newPassword.Length -lt 4) {
                    Send-Json $Response 400 @{ error = "Password must be at least 4 characters" }
                    return
                }
                $hash = New-PasswordHash -Password $newPassword
                $user.passwordSalt = $hash.salt
                $user.passwordHash = $hash.hash
                $user.iterations = $hash.iterations
            }

            Write-UserStore $store
            Send-Json $Response 200 @{ user = (Get-PublicUser $user) }
        } finally {
            if ($locked) { $mutex.ReleaseMutex() | Out-Null }
            $mutex.Dispose()
        }
        return
    }

    if ($method -eq "DELETE" -and $path -match '^/api/users/([A-Za-z0-9_]+)$') {
        $targetName = $Matches[1]
        if ($targetName -eq $Session.username) {
            Send-Json $Response 400 @{ error = "Cannot delete your own account while logged in" }
            return
        }

        $mutex = New-Object System.Threading.Mutex($false, $script:UsersMutexName)
        $locked = $false
        try {
            $locked = $mutex.WaitOne(15000)
            if (-not $locked) { throw "User store is busy" }

            $store = Read-UserStore
            $user = @($store.users | Where-Object { $_.username -eq $targetName } | Select-Object -First 1)
            if (-not $user) {
                Send-Json $Response 404 @{ error = "User not found" }
                return
            }
            if ($user.role -eq "admin" -and (Get-AdminCount $store) -le 1) {
                Send-Json $Response 400 @{ error = "Cannot delete the last admin" }
                return
            }

            $store.users = @($store.users | Where-Object { $_.username -ne $targetName })
            Write-UserStore $store
            Send-Json $Response 200 @{ ok = $true }
        } finally {
            if ($locked) { $mutex.ReleaseMutex() | Out-Null }
            $mutex.Dispose()
        }
        return
    }

    Send-Json $Response 404 @{ error = "API not found" }
}
