# Size
Size (`sz`) displays disk usage, like `du -sh`, using the macOS syscall `getattrlistbulk`, which I discovered thanks to Andrew Healey's blog post, *[Maybe the Fastest Disk Usagae Program on macOS](https://healeycodes.com/maybe-the-fastest-disk-usage-program-on-macos)*.
Size in written in Swift, has performance on par with Healey's `dumac` and has more safety and consistency gauruntees.
## Usage
`sz [--verbose] [--ignore-clones] [--depth <depth>] [--plain] [<directory>]
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
