# mbtool
Fido message base tool (Jam/Squish/MSG)

This tool allows to convert message bases between supported formats with sorting (honoring TZUTC kludge) and deduplication.

It is based on [skMHL](https://github.com/shadowlmd/skMHL-avs) library and can be built with [Free Pascal](https://www.freepascal.org/) compiler.

# usage

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

# examples
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
