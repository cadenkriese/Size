# Size
Size (`sz`) displays disk usage, like `du -sh`, using the macOS syscall `getattrlistbulk`, which I discovered thanks to Andrew Healey's blog post, *[Maybe the Fastest Disk Usagae Program on macOS](https://healeycodes.com/maybe-the-fastest-disk-usage-program-on-macos)*.
Size is written in Swift, has performance on par with Healey's `dumac` and has more safety and consistency gauruntees.
## Speed
Size follows the same approach as dumac, so it's performance is very similar. In some cases, Size may be a few milliseconds slower than dumac it spends time validating filesystem records and checking for overflow. diskus and du do not use `getattrlistbulk` so they are consistently slower. The one exception is in very deep file trees. At that point dumac and Size lose to du because we spend extra time handling concurrency, whereas du handles it serially. 

### Contrived Benchmarks
diskus crashed on the deep scenario.
<p align="center">
    <picture>
      <source
        media="(prefers-color-scheme: dark)"
        srcset="https://github.com/user-attachments/assets/b57df001-610f-4cab-b1b5-28e65d5a00df">
      <source
        media="(prefers-color-scheme: light)"
        srcset="https://github.com/user-attachments/assets/791e4e63-8ffb-42db-a235-52894fa4b318">
      <img
        width="660"
        height="399"
        alt="Grouped bar chart comparing median runtime in milliseconds for sz, dumac, diskus, and du; lower is faster.
        On many shallow directories, medians are 249, 252, 305, and 675 ms respectively. On many small files: 512, 584,
        1,184, and 995 ms. On deep hierarchies, du is fastest at 299 ms, followed by dumac at 625 ms and sz at 640 ms;
        diskus has no result because it crashed. On the hard-link-heavy scenario, dumac and sz lead at 85 and 88 ms,
        versus 188 ms for du and 365 ms for diskus."
        src="https://github.com/user-attachments/assets/791e4e63-8ffb-42db-a235-52894fa4b318">
    </picture>
</p>

### My home directory (now in seconds)
<p align="center">
    <picture>
      <source
        media="(prefers-color-scheme: dark)"
        srcset="https://github.com/user-attachments/assets/57c5f8eb-79ce-4ce6-813c-c34cd6f9612b">
      <source
        media="(prefers-color-scheme: light)"
        srcset="https://github.com/user-attachments/assets/d1ed46f2-b5d2-46f2-98ad-3df3c7a03cea">
      <img
        width="666"
        height="210"
        alt="Grouped bar chart comparing median runtime in milliseconds for sz, dumac, diskus, and du; lower is faster. sz leads at 7,129 ms, followed by dumac at 8,004, diskus at 9,957, and du at 20,917 ms."
        src="https://github.com/user-attachments/assets/d1ed46f2-b5d2-46f2-98ad-3df3c7a03cea">
    </picture>
</p>

## Usage
`sz [--verbose] [--ignore-clones] [--depth <depth>] [--plain] [<directory>]`
### Arguments
`<directory>             The directory to scan. Defaults to the current directory.`
### Options
```
  -v, --verbose           Prints each unreadable path and its error.
  --ignore-clones         Exclude APFS clones that don't take up any space yet.
  -d, --depth <depth>     Report directories up to this depth.
  --plain                 Omit tree hierarchy symbols.
  -h, --help              Show help information.
```
