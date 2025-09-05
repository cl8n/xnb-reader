# XNB Reader for osu!stable

This is a very minimal reader for the [XNA Compiled Content Format](<https://github.com/SimonDarksideJ/XNAGameStudio/wiki/Compiled-(XNB)-Content-Format>) that old versions of osu!stable used to store graphics resources.

Only the `Texture2D` and `Effect` content types are supported. Malformed headers are supported as long as the file contains a valid resource for osu!stable.

## Usage

Read content from an XNB file into an output file (extension will be added automatically):

```
xnb-read [<XNB file>] [<output file>]
```

Omitting or writing `-` as either of the filenames will read from stdin or write to stdout respectively.

---

Read content from an XNB file and pipe the result to a program with templated arguments. Currently only supports `Texture2D` files with 1 mip and RGBA pixel format.

```
xnb-read [<XNB file>] --pipe <program> [<argument templates>...]
```

The supported templates are `{width}`, `{height}`, and `{depth}`.

### Options

- `--pipe`\
  Explained above.

- `--`\
  Interpret the rest of arguments as positional arguments.

- `-h`, `-?`, `--help`\
  Print this help page.
