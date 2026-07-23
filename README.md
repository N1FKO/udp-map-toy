# UDP Map Toy

UDP Map Toy is a standalone macOS Swift script that listens for UDP decode packets, builds a local heard-spots JSON feed, serves a browser map, and writes ADIF output.

A bit of background:  I report reception to PSK reporter and I like to watch the map to observe openings.  Occasionally
(e.g. during contests) PSK reporter's map gets behind.  There are other applications that (amongst their many
features) also display a map, but sometimes you just want the map.  Here we are.

This program plots decoded points on an auto adjusting Leaflet map.  The points are colorized by age but not
removed.  You can click on a dot for details from hamdb or optionally hamqth.  You can click on the callsign
block in the sidebar for a map zoom + details.  The map will revert on its next update cycle.

You can enable browser notifications and macOS notifications via AppleScript for DX spots.  DX spots and strong
signals get a little extra decoration.


## Build

```bash
swiftc -o udp-map-toy udp-map-toy.swift
```

## Quick start

Only one flag is required for map functionality:

- `--my-grid GRID`

Example:

```bash
./udp-map-toy --my-grid FN31pr
```

## Optional ADIF identity fields

These fields are written into ADIF when provided, and omitted when left blank:

- `--operator CALLSIGN` (default `N0CALL`)
- `--my-name NAME`
- `--my-city CITY`
- `--my-state STATE`
- `--my-county COUNTY`
- `--my-dxcc DXCC`
- `--my-country COUNTRY`

Example with a few optional identity fields:

```bash
./udp-map-toy   --my-grid FN31pr   --operator W1AW   --my-country USA
```

## Other options

- `--udp-port PORT` (default `2237`)
- `--http-port PORT` (default `8080`)
- `--html PATH` (default `~/udp-map-toy.html`)
- `--json PATH` (default `~/spots.json`)
- `--adif PATH` (default `~/udp-map-toy-YYYY-MM-DD.adi`)
- `--program-id NAME` (default `UDP Map Toy`)
- `--notify-distance MILES` (default `1000`)
- `--hamqth-user USER`
- `--hamqth-password PASS`
- `--quiet`
- `--help`

Then open `http://127.0.0.1:8080/` in a browser.

## License

Copyright (c) 2026 Walter Horbert

This project is licensed under the MIT License (see `LICENSE`).

## Third-party services and resources

UDP Map Toy does not bundle any third-party source code. At runtime it loads or calls:

- [Leaflet](https://leafletjs.com/) (BSD-2-Clause) via CDN, for the map UI
- [OpenStreetMap](https://www.openstreetmap.org/copyright) tiles (ODbL), with in-app attribution
- [Fontshare](https://www.fontshare.com/) "General Sans" web font, linked via CSS
- [HamDB](https://hamdb.org/) and [HamQTH](https://www.hamqth.com/) public callsign lookup APIs

Use of these services is subject to their own terms and is unaffected by this project's MIT license.
