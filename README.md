# XNB Reader for osu!stable

This is a very minimal reader for the [XNA Compiled Content Format](<https://github.com/SimonDarksideJ/XNAGameStudio/wiki/Compiled-(XNB)-Content-Format>) that old versions of osu!stable used to store graphics resources.

Only the `Texture2D` and `Effect` content types are supported. Malformed headers are supported as long as the file contains a valid resource for osu!stable.

## Usage

Read content from an XNB file into an output file (extension will be added automatically):

```
xnb-read [<XNB file>] [<output file>]
```

Omitting or writing `-` as either of the filenames will read from stdin or write to stdout respectively.
