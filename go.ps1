# The one command to start everything, on any Windows PC, with no sign-in. In PowerShell:
#
#   irm https://raw.githubusercontent.com/oliverb-cbr/cbr-beatles/HEAD/go.ps1 | iex
#
# It fetches bootstrap.bat and runs it. That asks for administrator rights, gets the latest scripts
# into C:\CBR\cbr-beatles, then shows the menu: make the install USB stick, set up this PC, update
# it or check it. Needs the repo to be public. HEAD means the repo's default branch.
& {
    $bat = Join-Path $env:TEMP 'cbr-go.bat'
    Invoke-WebRequest -UseBasicParsing -OutFile $bat `
        -Uri 'https://raw.githubusercontent.com/oliverb-cbr/cbr-beatles/HEAD/bootstrap.bat'
    & $bat
}
