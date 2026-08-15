NETSVC.R4X
==========

NETSVC.R4X ist die Netzwerk-Service-Diagnose.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\NetSvcDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\NetSvcDiag\zig-out\NETSVC.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `netsvc_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4NET`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\NETSVC.R4X`
