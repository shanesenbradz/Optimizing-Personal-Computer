#!/bin/bash
set -e
cd "$(dirname "$0")"
rm -rf dist && mkdir -p dist/OPC-V7
python3 - <<'PY'
import base64
s=open('OPC-V7.ps1').read()
b=base64.b64encode(open('assets/logo96.png','rb').read()).decode()
s=s.replace('__LOGO_B64__',b)
assert '__LOGO_B64__' not in s
s=s.replace('\r\n','\n').replace('\n','\r\n')
s.encode('ascii')
open('dist/OPC-V7/OPC-V7.ps1','w',newline='').write(s)
PY
mcs -nologo -target:winexe -platform:anycpu -optimize+ -out:dist/OPC-V7/OPC-V7.exe \
    -win32icon:assets/OPC_V7.ico -resource:dist/OPC-V7/OPC-V7.ps1,OPC-V7.ps1 launcher/Launcher.cs
printf '@echo off\r\nREM OPC V7 fallback launcher. Same app as OPC-V7.exe.\r\nREM The script asks for administrator rights by itself.\r\nstart "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%%~dp0OPC-V7.ps1"\r\n' > dist/OPC-V7/Run-OPC-V7.cmd
cp assets/OPC_V7_logo.png dist/OPC-V7/
python3 -c "import sys; s=open('README.txt').read().replace('\r\n','\n').replace('\n','\r\n'); open('dist/OPC-V7/README.txt','w',newline='').write(s)"
mkdir -p dist/OPC-V7/source && cp launcher/Launcher.cs build.sh dist/OPC-V7/source/ && cp assets/OPC_V7.ico dist/OPC-V7/source/
(cd dist && rm -f OPC-V7.zip && zip -qr9 OPC-V7.zip OPC-V7)
