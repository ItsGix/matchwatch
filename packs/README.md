# Community packs

Share files that anyone can import into MatchWatch. A pack is a plain text file with one or more sections; the most useful kind holds only game labels.

To use a pack: open it, copy the text, and paste it under **Share with other players, Use a share file** on the Tools page. Or save it to the router and run `matchwatch share import <file>`. `matchwatch share check <file>` shows what a file holds without changing anything.

## File format

```
matchwatch-share 1

[games]
# name|server ports|kind|hosts
Example Game|7777-7800
Example Shooter|20000-29000||examplehost,as64500
Example Voice|40000|voice
```

- The first line that is not a comment must be `matchwatch-share 1`. Lines starting with `#` are comments.
- **name**: letters, numbers, spaces and `. : , ( ) & + -`.
- **server ports**: the UDP port on the game's server, not the player's. Single ports or ranges, separated by commas.
- **kind**: empty for a game, `voice` for voice chat. Voice chat is never recorded and never blocked.
- **hosts**: optional. Lower-case words looked for in the name of the company hosting the server, and its AS number written as `as64500`. Each must be three characters or more. The label only matches when one is found.
- A range wider than 2000 ports **must** have hosts. Without them the label would claim every unknown stream in that range as the game, and staying on places could then block something that is not a game. MatchWatch refuses such a line on import.

The other sections (`[places]`, `[ratings]`, `[regions]`, `[settings]`) are described in the main README under "Sharing with other players". `matchwatch share export` writes a file with every section, which is the easiest way to see them.

## Adding a pack here

Send a pull request adding one file to this folder, named after what it covers, for example `marvel-rivals.txt`.

A pack is accepted when:

1. **It says where the ports come from.** Put the source in a comment at the top: the publisher's own port list, or a capture you made yourself (say which platform and region). Ports copied from a router maker's forwarding guide are often the player's ports, not the server's; say so if that is all there is.
2. **It names hosts where ranges are shared.** Many games share ranges with each other and with voice chat. `matchwatch servers` shows who hosts the servers you played on.
3. **It holds nothing from your own network.** A games-only pack never does. If you include ratings, they must come from `matchwatch share export`, which leaves out your addresses and match times.
4. **It passes the check.** `matchwatch share check <file>` must accept every line.

No pack is installed automatically. MatchWatch never downloads this folder; people choose what to import.
