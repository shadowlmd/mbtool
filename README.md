# mbtool
Fido message base tools (Jam/Squish/MSG)

This repository contains tools for Fido message base conversion, processing, and character set recoding:
- **mbtool**: Convert message bases between supported formats with sorting (honoring TZUTC kludge) and deduplication.
- **recode**: Recode message character sets in Fido message bases (e.g. UTF-8 to CP866/CP850, fixing incorrect CHRS kludges).

It is based on [skMHL](https://github.com/shadowlmd/skMHL-avs) library and can be built with [Free Pascal](https://www.freepascal.org/) compiler.

# usage (mbtool)

```
Fido message base conversion and processing tool

Usage:
  mbtool.exe [options] -src <source> -dst <destination>

Options:
  -src <spec>      Source message base specification
  -dst <spec>      Destination message base specification
  -deftz <offset>  Default UTC offset for messages without TZUTC kludge (e.g., 0300 or -0500)
  -sort            Sort messages by date and reply chains
  -dedup           Remove duplicate messages

Base Specification format:
  <Letter><Path>
  Where Letter is:
    J - JAM
    S - Squish
    F, M, * - MSG / Opus
```

# usage (recode)

```
Fido message base character set recoding tool

Usage:
  recode.exe <basespec> <from_charset> <to_charset> [search_charset | msg_number]

Parameters:
  <basespec>       Message base specification
  <from_charset>   Source character set
  <to_charset>     Destination character set
  [search_charset] Optional character set to match in CHRS kludge
  [msg_number]     Optional specific message number to recode

Note:
  This tool operates interactively with manual confirmation. A preview
  of the decoded message is shown on screen before writing to base.
  It is recommended to recode to your console character set (e.g., CP866)
  so the preview is readable, or do so at your own risk.
```

# examples

## mbtool examples
### convert JAM base to Squish base and skip dupe messages
```
mbtool.exe -src Jc:\fido\msgbase\jam\ruftndev -dst Sc:\fido\msgbase\squish\ruftndev -dedup
```

### convert JAM base to Squish base and sort it, using UTC+0300 for messages without TZUTC kludge
```
mbtool.exe -src Jc:\fido\msgbase\jam\r50sysop -dst Sc:\fido\msgbase\squish\r50sysop -deftz 0300 -sort
```

### convert JAM base to Squish base and sort it, using UTC-0500 for messages without TZUTC kludge, and remove dupe messages
```
mbtool.exe -src Jc:\fido\msgbase\jam\enetsys -dst Sc:\fido\msgbase\squish\enetsys -deftz -0500 -sort -dedup
```

### convert MSG (Opus) base to JAM base and sort it
```
mbtool.exe -src Mc:\fido\msgbase\msg\netmail -dst Jc:\fido\msgbase\jam\netmail -sort
```

## recode examples
### recode messages in JAM base from UTF-8 to CP866
```
recode.exe Jc:\fido\msgbase\jam\ruftndev UTF-8 CP866
```

### recode messages in Squish base from UTF-8 to CP850
```
recode.exe Sc:\fido\msgbase\squish\fn_sysop UTF-8 CP850
```

### recode messages in MSG base with incorrect CHRS kludge (KOI instead of KOI8-R)
```
recode.exe Mc:\fido\msgbase\msg\netmail KOI8-R CP866 KOI
```

### replace incorrect CHRS kludge in JAM base (ASCII -> CP866)
```
recode.exe Jc:\fido\msgbase\jam\su_chainik CP866 CP866 ASCII
```

### recode specific message #666 in Squish base even if it has no CHRS kludge
```
recode.exe Sc:\fido\msgbase\squish\ru_linux KOI8-R CP866 666
```
