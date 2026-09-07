@echo off

for %%i in (mbtool.pas recode.pas) do (
    fpc.exe -B -dRELEASE -Flout -FUout -Fud:\prog\pascal\skMHL-avs\sources -Fid:\prog\pascal\skMHL-avs\sources -g -gl %%i
)
