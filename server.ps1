param(
    [int]$Port = 8123,
    [string]$Root = ""
)

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "Serving $Root on http://127.0.0.1:$Port"

function Get-ContentType([string]$ext) {
    switch ($ext.ToLower()) {
        ".html" { "text/html; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".svg"  { "image/svg+xml" }
        ".png"  { "image/png" }
        ".jpg"  { "image/jpeg" }
        ".ico"  { "image/x-icon" }
        default { "application/octet-stream" }
    }
}

while ($true) {
    try {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000

        # Читаем заголовки запроса байтами до \r\n\r\n
        $buffer = New-Object System.Collections.Generic.List[byte]
        $one = New-Object byte[] 1
        $state = 0
        while ($state -ne 4) {
            $n = $stream.Read($one, 0, 1)
            if ($n -le 0) { break }
            $buffer.Add($one[0])
            $b = $one[0]
            if (($state -eq 0 -and $b -eq 13) -or ($state -eq 1 -and $b -eq 10) -or
                ($state -eq 2 -and $b -eq 13) -or ($state -eq 3 -and $b -eq 10)) {
                $state++
            } elseif ($b -eq 13 -and $state -eq 0) { $state = 1 }
            else { $state = 0 }
            if ($buffer.Count -gt 16384) { break }
        }

        $headerText = [System.Text.Encoding]::ASCII.GetString($buffer.ToArray())
        $requestLine = ($headerText -split "`r`n")[0]
        $path = "index.html"
        if ($requestLine -match '^\S+\s+(\S+)') {
            $path = $matches[1].Split('?')[0].TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($path)) { $path = "index.html" }
        }
        # защита от выхода за пределы папки
        $path = $path.Replace("..", "")

        $file = Join-Path $Root $path
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $ct = Get-ContentType ([System.IO.Path]::GetExtension($file))
            $extra = ""
            $acceptsGzip = $headerText -match '(?i)accept-encoding:\s*[^\r\n]*gzip'
            if ($acceptsGzip -and ($ct -match 'text/|javascript|svg|json' -or $ct -match 'octet-stream')) {
                $ms = New-Object System.IO.MemoryStream
                $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Optimal)
                $gz.Write($bytes, 0, $bytes.Length)
                $gz.Close()
                $bytes = $ms.ToArray()
                $extra = "Content-Encoding: gzip`r`n"
            }
            $header = "HTTP/1.1 200 OK`r`nContent-Type: $ct`r`n$extra" + "Content-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($hb, 0, $hb.Length)
            $stream.Write($bytes, 0, $bytes.Length)
        } else {
            $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
            $header = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($msg.Length)`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($hb, 0, $hb.Length)
            $stream.Write($msg, 0, $msg.Length)
        }

        $stream.Flush()
        $client.Close()
    } catch {
        if ($client) { try { $client.Close() } catch {} }
    }
}
