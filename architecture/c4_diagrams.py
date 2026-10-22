"""Generate mcl-stations' two C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: what the service talks to
  c4-components.svg  Level 2: what it is made of

Drawn from the code, never from a template: the callbacks and the advertised
capability in mcl_stations_service.erl, the child in mcl_stations_sup.erl, the
record types and the snapshot-and-subscribe in
ingest_node_records/ingest_node_records.erl, the provider in
list_stations/list_stations.erl, the docs in station_read_model.erl, the
refusal gauge in station_record_drops.erl, the table in continent_lookup.erl,
the dependencies in rebar.config, and the environment in config/sys.config.src,
the Containerfile and deploy/docker-compose.yml. When one of those changes, the
diagram changes in the same commit.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS custom
properties (rsvg-convert renders those black), so the SVGs render the same on
GitHub, in IDE previews and through rsvg-convert. After a change, render each
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it; keep
architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        # A box that is too small for its own words renders as text on top of the
        # next box, which no test would catch and a reader would read as the
        # diagram saying something it does not. Fail here instead.
        need = 70 + 16 * max(len(desc) - 1, 0) + 18
        if h < need:
            raise ValueError(f"{self.name}: {name} needs height {need}, has {h}")
        for line in desc:
            if 16 + 6.2 * len(line) > w - 16:
                raise ValueError(f"{self.name}: {name}: '{line}' is wider than {w - 32}px")
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "mcl-stations system context", 1100, 720)
    d.box("b-per", 60, 40, 280, 104, "Service operator", "[Person]",
          ["Deploys the release, supplies", "the realm, its key and the pins"], person=True)
    d.box("b-ext", 760, 40, 300, 140, "Mesh callers", "[External system, any node or client]",
          ["Any node or client that calls", "mcl-stations/list_stations; the",
           "procedure is open, every row public"])
    d.box("b-sys", 380, 220, 340, 150, "mcl-stations", "[mcl_om mesh service, own box]",
          ["The station directory: it snapshots", "the DHT, follows it live, and",
           "answers one open RPC with rows a", "client can verify itself"])
    d.box("b-mac", 60, 450, 320, 140, "Macula stations, the mesh and DHT", "[Macula infrastructure]",
          ["Every station broadcasts its", "node_record, station_endpoint",
           "and tombstone; the DHT holds them"])
    d.box("b-mac", 420, 450, 300, 120, "macula-realm", "[Macula infrastructure]",
          ["Endorses the node's identity key;", "grants no authority, because the",
           "DHT records are public"])
    d.box("b-cmp", 760, 450, 300, 120, "Station cache", "[in-container store, no volume]",
          ["barrel_docdb under MCL_DATA_DIR:", "a cache of the DHT snapshot,",
           "rebuilt every boot"])
    d.edge("M200 144V180H420V220")
    d.text("t-rel", 208, 170, "deploys; sets the realm and pins")
    d.edge("M910 180V200H600V220")
    d.text("t-rel", 700, 192, "calls list_stations, open")
    d.edge("M420 370V400H220V450")
    d.text("t-rel", 228, 392, "snapshots, then subscribes")
    d.edge("M500 370V450")
    d.text("t-rel", 508, 410, "boot claim, no authority asked")
    d.edge("M720 330H790V450")
    d.text("t-rel", 798, 400, "writes each record, reads")
    d.text("t-desc", 60, 620, "The mesh is the source: this service holds no station list of its own, it follows what stations broadcast and joins the two records")
    d.text("t-desc", 60, 638, "of one station on the signer's key id. A row carries the raw signed records, so a caller verifies them itself instead of trusting the directory.")
    d.text("t-desc", 60, 656, "A station that stops refreshing is unlisted once its records expire, with no tombstone needed; a graceful shutdown publishes one and retires it at once.")
    d.legend(680, boundary=False)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-stations components", 1200, 1040)
    d.bound(16, 40, 1168, 730, "mcl-stations [Container: one OTP release]")
    d.box("b-cmp", 40, 66, 480, 120, "mcl_stations_app", "[application behaviour]",
          ["start/2 called mcl_om:boot/1 with this service:", "the mesh, the identity, health and the capability",
           "are wired before start/1 runs"], code=True)
    d.box("b-cmp", 660, 66, 500, 120, "mcl_stations_service", "[mcl_om_service behaviour]",
          ["The six callbacks. data_dir/0 is private and not",
           "exported; start/1 opens the read model first;",
           "capabilities/0 advertises list_stations, auth open"], code=True)
    d.box("b-cmp", 40, 210, 480, 104, "mcl_stations_sup", "[supervisor, one_for_one]",
          ["One child, ingest_node_records:", "the directory has one feeder"], code=True)
    d.box("b-cmp", 660, 210, 500, 120, "list_stations", "[macula_response RPC provider]",
          ["handle_request/2 folds the read model, applies", "the filters, sorts by distance and caps the",
           "count; every stored record is verified again"], code=True)
    d.box("b-cmp", 40, 338, 480, 120, "ingest_node_records", "[gen_server, the feeder]",
          ["Snapshot then subscribe: node_record,", "station_endpoint and tombstone. Monitors the",
           "pool, redials when it restarts, polls its links"], code=True)
    d.box("b-cmp", 660, 338, 500, 120, "station_record_drops", "[ETS gauge]",
          ["Keyed by (row, record type): what the directory", "is refusing right now, per reason. Health reads",
           "the counts, so a directory dropping rows is not green"], code=True)
    d.box("b-cmp", 40, 482, 480, 120, "station_read_model", "[barrel_docdb]",
          ["One doc per station key id, holding each", "record's raw signed bytes and projected fields;",
           "expiry and serving are per record type"], code=True)
    d.box("b-cmp", 660, 482, 480, 120, "continent_lookup", "[pure, a static table]",
          ["ISO 3166-1 alpha-2 country code to", "continent; anything else is unknown"],
          code=True)
    d.box("b-mac", 40, 626, 360, 120, "mcl_om", "[library, ~> 1.0]",
          ["boot/1 wires mesh, identity, health;", "the capability is registered here"], code=True)
    d.box("b-mac", 420, 626, 360, 120, "macula", "[library, ~> 15.6]",
          ["find_records_by_type/2, subscribe_records/3,", "record verification under the crypto profile"],
          code=True)
    d.box("b-mac", 800, 626, 360, 120, "barrel_docdb", "[library, ~> 1.5]",
          ["the read model's store, on the rocksdb", "binding linked to the system librocksdb 11.1"],
          code=True)
    d.box("b-ext", 40, 800, 1120, 104, "the host environment", "[environment, read at boot]",
          ["MCL_REALM, MCL_REALM_KEY, MACULA_STATION_SEEDS, MACULA_STATION_NODE_IDS (mcl_om refuses to boot without them), MCL_DATA_DIR (/var/lib/mcl-stations);",
           "the node identity key is read from /etc/mcl/secrets by mcl_om; nothing here is a secret"],
          code=True)
    d.edge("M520 126H660"); d.text("t-rel", 590, 118, "boots", anchor="middle")
    d.edge("M660 150H580V262H520"); d.text("t-rel", 588, 216, "start/1")
    d.edge("M915 186V210"); d.text("t-rel", 923, 206, "advertises")
    d.edge("M285 314V338"); d.text("t-rel", 293, 334, "supervises")
    d.edge("M285 458V482"); d.text("t-rel", 293, 478, "upserts, retires")
    d.edge("M915 314V338"); d.text("t-rel", 923, 334, "observes a refusal")
    d.edge("M660 262H620V542H520"); d.text("t-rel", 528, 420, "folds a row")
    d.edge("M520 570H660"); d.text("t-rel", 528, 562, "continent_of/1")
    d.text("t-desc", 40, 934, "The read model is a cache: it lives and dies with the container, and every boot replays the DHT snapshot into it. A stored record is verified")
    d.text("t-desc", 40, 952, "again before it is served; one that fails is refused, counted in station_record_drops, and /health turns degraded. The three libraries")
    d.text("t-desc", 40, 970, "are drawn without arrows: every module here reaches the mesh through mcl_om or macula, and the store through barrel_docdb.")
    d.legend(994)
    d.write()


if __name__ == "__main__":
    for make in (context, components):
        make()
