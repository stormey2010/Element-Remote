import { selectionHaptic } from "./platform";
import React, { useState, useEffect, useRef, useCallback } from "react";
import {
  useMessage,
  useStatus,
  subscribeOSC,
  send,
  coalesce,
  tap,
  command,
  notice,
} from "./osc";
const Button = ({ children, onClick, ...props }) => (
  <button
    type="button"
    {...props}
    onClick={
      onClick
        ? (event) => {
            selectionHaptic();
            onClick(event);
          }
        : undefined
    }
  >
    {children}
  </button>
);
const Panel = ({ children, className = "" }) => (
  <div className={"panel " + className}>{children}</div>
);
const Title = ({ children, aside }) => (
  <div className="view-title">
    <h2>{children}</h2>
    {aside}
  </div>
);
const clamp = (n, min = 0, max = 1) => Math.min(max, Math.max(min, n));
function useEvents(fn) {
  const ref = useRef(fn);
  ref.current = fn;
  useEffect(() => subscribeOSC((msg) => ref.current(msg)), []);
}
function useDrag(onMove, onStart = () => {}) {
  const point = useRef(null);
  return {
    onPointerDown: (e) => {
      if (e.button !== 0) return;
      e.currentTarget.setPointerCapture(e.pointerId);
      point.current = { id: e.pointerId, x: e.clientX, y: e.clientY };
      onStart(e);
    },
    onPointerMove: (e) => {
      if (point.current?.id !== e.pointerId) return;
      onMove(e, {
        x: e.clientX - point.current.x,
        y: e.clientY - point.current.y,
      });
      point.current = { id: e.pointerId, x: e.clientX, y: e.clientY };
    },
    onPointerUp: () => (point.current = null),
    onPointerCancel: () => (point.current = null),
    onLostPointerCapture: () => (point.current = null),
  };
}
function wheel(param, n, fine) {
  if (n) send(`/eos/wheel/${fine ? "fine" : "coarse"}/${param}`, [n]);
}
function Wheel({ param, title, fine }) {
  const value = useMessage("/eos/out/param/" + param),
    residual = useRef(0);
  const drag = useDrag(
    (e, d) => {
      residual.current += d.x;
      const n = Math.trunc(residual.current / 5);
      if (n) {
        wheel(param, n, fine);
        residual.current -= n * 5;
      }
    },
    () => (residual.current = 0),
  );
  return (
    <Panel className="wheel-panel">
      <div className="panel-toolbar">
        <Button
          aria-label={title + " minimum"}
          onClick={() => tap(`/eos/param/${param}/min`)}
        >
          Min
        </Button>
        <b>{title}</b>
        <Button
          aria-label={title + " maximum"}
          onClick={() => tap(`/eos/param/${param}/max`)}
        >
          Max
        </Button>
      </div>
      <div className="wheel-strip">
        <Button
          aria-label={title + " decrease"}
          onClick={() => wheel(param, -1, fine)}
        >
          ◁
        </Button>
        <div
          className="wheel-surface"
          tabIndex="0"
          role="slider"
          aria-label={title + " wheel"}
          aria-valuetext={String(value[0] ?? "No feedback")}
          {...drag}
          onKeyDown={(e) => {
            if (["ArrowLeft", "ArrowRight"].includes(e.key)) {
              e.preventDefault();
              wheel(param, e.key === "ArrowLeft" ? -1 : 1, fine);
            }
          }}
        >
          <output>{value[0] ?? "—"}</output>
        </div>
        <Button
          aria-label={title + " increase"}
          onClick={() => wheel(param, 1, fine)}
        >
          ▷
        </Button>
      </div>
    </Panel>
  );
}
function coordinates(e) {
  const r = e.currentTarget.getBoundingClientRect();
  return {
    x: clamp((e.clientX - r.left) / r.width),
    y: clamp(1 - (e.clientY - r.top) / r.height),
  };
}
function Wheels() {
  const [fine, setFine] = useState(false),
    [mode, setMode] = useState("relative"),
    [cursor, setCursor] = useState({ x: 0.5, y: 0.5 });
  function absolute(e) {
    const p = coordinates(e);
    if (coalesce("/eos/pantilt/xy", [p.x, p.y])) setCursor(p);
  }
  const drag = useDrag(
    (e, d) => {
      if (mode === "absolute") absolute(e);
      else {
        wheel("pan", Math.round(d.x / 2), fine);
        wheel("tilt", -Math.round(d.y / 2), fine);
      }
    },
    (e) => {
      if (mode === "absolute") absolute(e);
    },
  );
  return (
    <>
      <Title
        aside={
          <label className="check-label">
            <input
              type="checkbox"
              checked={fine}
              onChange={(e) => setFine(e.target.checked)}
            />{" "}
            Fine
          </label>
        }
      >
        Parameter wheels
      </Title>
      <p className="hint">
        Controls the console selection. Drag wheels or use their arrows.
      </p>
      <div className="wheel-grid">
        {[
          ["intens", "Intensity"],
          ["pan", "Pan"],
          ["tilt", "Tilt"],
          ["edge", "Edge"],
          ["zoom", "Zoom"],
        ].map(([param, title]) => (
          <Wheel key={param} {...{ param, title, fine }} />
        ))}
      </div>
      <Panel>
        <div className="panel-toolbar">
          <b>Pan / Tilt</b>
          <select
            aria-label="Pan tilt mode"
            value={mode}
            onChange={(e) => setMode(e.target.value)}
          >
            <option value="relative">Relative</option>
            <option value="absolute">Absolute</option>
          </select>
          <Button onClick={() => tap("/eos/param/pan/tilt/home")}>Home</Button>
        </div>
        <div
          className="position-pad"
          tabIndex="0"
          role="application"
          aria-label="Pan tilt pad"
          {...drag}
          onKeyDown={(e) => {
            if (e.key.startsWith("Arrow")) {
              e.preventDefault();
              wheel(
                ["ArrowLeft", "ArrowRight"].includes(e.key) ? "pan" : "tilt",
                ["ArrowLeft", "ArrowDown"].includes(e.key) ? -1 : 1,
                fine,
              );
            }
          }}
        >
          <span
            className="cursor"
            style={{
              left: cursor.x * 100 + "%",
              top: (1 - cursor.y) * 100 + "%",
            }}
          />
          <span className="pad-caption">
            Drag to focus
            <br />
            Arrow keys to adjust
          </span>
          <span className="axis-x">Pan</span>
          <span className="axis-y">Tilt</span>
        </div>
      </Panel>
    </>
  );
}
const locus = [
  [0.174, 0.005],
  [0.168, 0.005],
  [0.157, 0.018],
  [0.144, 0.03],
  [0.124, 0.058],
  [0.091, 0.133],
  [0.046, 0.295],
  [0.008, 0.538],
  [0.014, 0.75],
  [0.074, 0.834],
  [0.155, 0.806],
  [0.23, 0.754],
  [0.302, 0.692],
  [0.374, 0.624],
  [0.444, 0.555],
  [0.512, 0.487],
  [0.575, 0.424],
  [0.627, 0.373],
  [0.665, 0.335],
  [0.692, 0.308],
  [0.708, 0.292],
  [0.719, 0.281],
  [0.728, 0.272],
  [0.735, 0.265],
];
function inside(x, y) {
  let yes = false;
  for (let i = 0, j = locus.length - 1; i < locus.length; j = i++) {
    const a = locus[i],
      b = locus[j];
    if (
      a[1] > y !== b[1] > y &&
      x < ((b[0] - a[0]) * (y - a[1])) / (b[1] - a[1]) + a[0]
    )
      yes = !yes;
  }
  return yes;
}
function rgb(x, y) {
  const X = x / Math.max(y, 0.001),
    Z = (1 - x - y) / Math.max(y, 0.001),
    v = [
      3.2406 * X - 1.5372 - 0.4986 * Z,
      -0.9689 * X + 1.8758 + 0.0415 * Z,
      0.0557 * X - 0.204 + 1.057 * Z,
    ].map((n) => Math.max(0, n)),
    max = Math.max(...v, 1);
  return v.map((n) => {
    n /= max;
    return Math.round(
      255 * (n <= 0.0031308 ? 12.92 * n : 1.055 * n ** (1 / 2.4) - 0.055),
    );
  });
}
let cieImage;
function CIECanvas() {
  const ref = useRef();
  useEffect(() => {
    const ctx = ref.current.getContext("2d");
    if (!cieImage) {
      cieImage = ctx.createImageData(320, 360);
      for (let py = 0; py < 360; py++)
        for (let px = 0; px < 320; px++) {
          const x = (px / 320) * 0.8,
            y = (1 - py / 360) * 0.9,
            c = rgb(x, y),
            factor = inside(x, y) ? 1 : 0.12,
            i = (py * 320 + px) * 4;
          cieImage.data[i] = c[0] * factor;
          cieImage.data[i + 1] = c[1] * factor;
          cieImage.data[i + 2] = c[2] * factor;
          cieImage.data[i + 3] = 255;
        }
    }
    ctx.putImageData(cieImage, 0, 0);
  }, []);
  return <canvas ref={ref} width="320" height="360" />;
}
function Palette({ n, filter }) {
  const data = useMessage(`/eos/out/ds/4/${n}`);
  const text = String(data[0] || n);
  return (
    <Button
      hidden={!!filter && !text.toLowerCase().includes(filter.toLowerCase())}
      onClick={() => tap(`/eos/ds/4/${n}`)}
    >
      {text}
    </Button>
  );
}
function Color() {
  const [space, setSpace] = useState("xy"),
    [h, setH] = useState(0),
    [s, setS] = useState(100),
    [xy, setXY] = useState({ x: 0.313, y: 0.329 }),
    [filter, setFilter] = useState(""),
    [last, setLast] = useState("No color sent");
  function hs(hue, sat) {
    hue = clamp(hue, 0, 360);
    sat = clamp(sat, 0, 100);
    setSpace("hs");
    setH(hue);
    setS(sat);
    if (coalesce("/eos/color/hs", [hue, sat]))
      setLast(`Last sent · ${Math.round(hue)}° / ${Math.round(sat)}%`);
  }
  function setPoint(p) {
    const next = { x: clamp(p.x, 0, 0.8), y: clamp(p.y, 0, 0.9) };
    if (!inside(next.x, next.y)) return;
    setXY(next);
    if (coalesce("/eos/color/xy", [next.x, next.y]))
      setLast(`Last sent · x ${next.x.toFixed(3)} / y ${next.y.toFixed(3)}`);
  }
  function pick(e) {
    const p = coordinates(e);
    space === "xy"
      ? setPoint({ x: p.x * 0.8, y: p.y * 0.9 })
      : hs(p.x * 360, p.y * 100);
  }
  const drag = useDrag(pick, pick),
    cursor =
      space === "xy"
        ? { x: xy.x / 0.8, y: xy.y / 0.9 }
        : { x: h / 360, y: s / 100 };
  return (
    <>
      <Title aside={<small>{last}</small>}>Color</Title>
      <Panel className="color-sliders">
        <label>
          Hue <output>{Math.round(h)}°</output>
          <input
            className="hue"
            aria-label="Hue"
            type="range"
            min="0"
            max="360"
            value={h}
            onChange={(e) => hs(Number(e.target.value), s)}
          />
        </label>
        <label>
          Saturation <output>{Math.round(s)}%</output>
          <input
            className="saturation"
            aria-label="Saturation"
            style={{
              background: `linear-gradient(90deg,white,hsl(${h} 100% 50%))`,
            }}
            type="range"
            min="0"
            max="100"
            value={s}
            onChange={(e) => hs(h, Number(e.target.value))}
          />
        </label>
      </Panel>
      <Panel>
        <div className="panel-toolbar">
          <select
            aria-label="Color space"
            value={space}
            onChange={(e) => setSpace(e.target.value)}
          >
            <option value="xy">CIE xy</option>
            <option value="hs">Hue / Saturation</option>
          </select>
          <span
            className="color-swatch"
            style={{
              background:
                space === "xy"
                  ? `rgb(${rgb(xy.x, xy.y).join(",")})`
                  : `hsl(${h} ${s}% 50%)`,
            }}
          />
        </div>
        <div
          className={"color-pad " + space}
          tabIndex="0"
          role="application"
          aria-label="Color pad"
          {...drag}
          onKeyDown={(e) => {
            if (!e.key.startsWith("Arrow")) return;
            e.preventDefault();
            const dx =
                e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0,
              dy = e.key === "ArrowUp" ? 1 : e.key === "ArrowDown" ? -1 : 0;
            space === "xy"
              ? setPoint({ x: xy.x + dx * 0.002, y: xy.y + dy * 0.002 })
              : hs(h + dx, s + dy);
          }}
        >
          {space === "xy" && <CIECanvas />}
          <span
            className="cursor"
            style={{
              left: cursor.x * 100 + "%",
              top: (1 - cursor.y) * 100 + "%",
            }}
          />
        </div>
        <p className="hint">
          Select a color-capable fixture first. Screen colors approximate
          fixture output.
        </p>
      </Panel>
      <Panel>
        <label>
          Show color palettes
          <input
            type="search"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            placeholder="Search palette labels"
          />
        </label>
        <div className="palette-grid">
          {Array.from({ length: 25 }, (_, i) => (
            <Palette key={i} n={i + 1} filter={filter} />
          ))}
        </div>
      </Panel>
    </>
  );
}
function Patch() {
  const [rows, setRows] = useState({}),
    [offset, setOffset] = useState(0),
    [count, setCount] = useState(null),
    [filter, setFilter] = useState(""),
    [state, setState] = useState("Load patch to request fixture information.");
  const chunks = useRef(new Map()),
    timer = useRef();
  const status = useStatus();
  useEffect(() => () => clearTimeout(timer.current), []);
  useEffect(() => {
    if (!status.bridge) {
      setRows({});
      setState("Disconnected. Load patch after reconnecting.");
    }
  }, [status.bridge]);
  function load(next = offset) {
    if (!send("/eos/get/patch/count")) return;
    setOffset(next);
    setRows({});
    chunks.current.clear();
    setState("Loading patch…");
    for (let n = next; n < next + 25; n++) send("/eos/get/patch/index", [n]);
    clearTimeout(timer.current);
    timer.current = setTimeout(
      () => setState("No further reply. Available rows are shown below."),
      6000,
    );
  }
  useEvents(({ address, parameters: p }) => {
    if (address === "/eos/out/get/patch/count") {
      setCount(Number(p[0]));
      if (Number(p[0]) === 0) {
        setState("No fixtures patched.");
        clearTimeout(timer.current);
      }
    }
    const m = address.match(
      /^\/eos\/out\/get\/patch\/(\d+)\/(\d+)\/list\/(\d+)\/(\d+)$/,
    );
    if (!m) return;
    const id = m[1] + "/" + m[2],
      fields = chunks.current.get(id) || [];
    p.forEach((v, i) => (fields[Number(m[3]) + i] = v));
    chunks.current.set(id, fields);
    if (fields[0] >= 0 && (fields[0] < offset || fields[0] >= offset + 25))
      return;
    if (fields[4] !== undefined) {
      setRows((old) => ({
        ...old,
        [id]: {
          channel: m[1],
          part: m[2],
          label: String(fields[2] ?? ""),
          type: String(fields[4] ?? ""),
          address: String(fields[5] ?? ""),
        },
      }));
      setState("");
      clearTimeout(timer.current);
    }
  });
  const visible = Object.values(rows)
    .sort((a, b) => Number(a.channel) - Number(b.channel))
    .filter((r) =>
      Object.values(r).join(" ").toLowerCase().includes(filter.toLowerCase()),
    );
  function csv() {
    if (!visible.length) {
      notice("Load patch data before exporting.");
      return;
    }
    const quote = (v) => '"' + String(v).replaceAll('"', '""') + '"',
      text = [
        ["Channel", "Part", "Address", "Type", "Label"],
        ...visible.map((r) => [r.channel, r.part, r.address, r.type, r.label]),
      ]
        .map((r) => r.map(quote).join(","))
        .join("\r\n"),
      url = URL.createObjectURL(new Blob([text], { type: "text/csv" })),
      a = document.createElement("a");
    a.href = url;
    a.download = "element-patch-page.csv";
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  return (
    <>
      <Title aside={<Button onClick={() => load(0)}>↻ Load patch</Button>}>
        Patch
      </Title>
      <div className="panel-toolbar">
        <label>
          Filter
          <input
            type="search"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            placeholder="Channel, address or type"
          />
        </label>
        <Button onClick={csv}>Export CSV</Button>
      </div>
      <div className="table-panel">
        <table>
          <thead>
            <tr>
              <th>Chan</th>
              <th>Address</th>
              <th>Type / Label</th>
            </tr>
          </thead>
          <tbody>
            {visible.map((r) => (
              <tr key={r.channel + "/" + r.part}>
                <td>
                  <Button
                    onClick={() => send("/eos/chan", [Number(r.channel)])}
                  >
                    {r.channel}
                    {Number(r.part) > 1 ? "." + r.part : ""}
                  </Button>
                </td>
                <td>{r.address || "—"}</td>
                <td>{[r.type, r.label].filter(Boolean).join(" · ")}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {state && <p className="empty-state">{state}</p>}
      </div>
      <div className="panel-toolbar">
        <Button
          disabled={!offset}
          onClick={() => load(Math.max(0, offset - 25))}
        >
          Page up
        </Button>
        <small>
          Page {offset / 25 + 1}
          {count !== null ? ` · ${count} fixtures` : ""}
        </small>
        <Button
          disabled={count !== null && offset + 25 >= count}
          onClick={() => load(offset + 25)}
        >
          Page down
        </Button>
      </div>
    </>
  );
}
function Cues() {
  const [locked, setLocked] = useState(true),
    [list, setList] = useState(1),
    [loaded, setLoaded] = useState(1),
    [rows, setRows] = useState({}),
    [state, setState] = useState("Load a cue list to receive console data."),
    [goto, setGoto] = useState(false),
    [number, setNumber] = useState("");
  const status = useStatus(),
    timer = useRef();
  useEffect(() => () => clearTimeout(timer.current), []);
  useEffect(() => {
    if (!status.bridge || status.session) {
      setLocked(true);
      setRows({});
      setState(
        status.bridge
          ? "Load list to refresh console data."
          : "Disconnected. Load list after reconnecting.",
      );
    }
  }, [status.bridge, status.session]);
  function wait() {
    setRows({});
    setState("Loading cue list…");
    clearTimeout(timer.current);
    timer.current = setTimeout(
      () =>
        setState(
          "No cue-list reply. Check console software support and connection.",
        ),
      6000,
    );
  }
  function load() {
    const n = clamp(Number(list) || 1, 1, 999);
    if (send(`/eos/cuelist/1/config/${n}/3/12`)) {
      setLoaded(n);
      setLocked(true);
      wait();
    }
  }
  function page(delta) {
    if (send(`/eos/cuelist/1/page/${delta}`)) wait();
  }
  useEvents(({ address, parameters: p }) => {
    const m = address.match(/^\/eos\/out\/cuelist\/1\/(\d+)$/);
    if (m) {
      setRows((old) => {
        const next = { ...old };
        if (p[0]) next[m[1]] = p;
        else delete next[m[1]];
        return next;
      });
      setState("");
      clearTimeout(timer.current);
    }
  });
  return (
    <>
      <Title
        aside={
          <label>
            Controls
            <select
              aria-label="Cue controls"
              value={locked ? "locked" : "unlocked"}
              onChange={(e) => {
                setLocked(e.target.value === "locked");
                setGoto(false);
              }}
            >
              <option value="locked">Locked</option>
              <option value="unlocked">Unlocked</option>
            </select>
          </label>
        }
      >
        Cue list
      </Title>
      <p className="hint">Lock disables playback actions on this screen.</p>
      <div className="panel-toolbar">
        <label>
          List
          <input
            type="number"
            min="1"
            max="999"
            value={list}
            onChange={(e) => setList(e.target.value)}
          />
        </label>
        <Button onClick={load}>Load list</Button>
        <small>Target list {loaded}</small>
      </div>
      <div className="table-panel">
        <table>
          <thead>
            <tr>
              <th>Cue</th>
              <th>Dur</th>
              <th>Label</th>
            </tr>
          </thead>
          <tbody>
            {Object.entries(rows)
              .sort((a, b) => Number(a[0]) - Number(b[0]))
              .map(([id, r]) => (
                <tr key={id}>
                  <td>{r[1] ?? r[0]}</td>
                  <td>
                    {typeof r[6] === "number"
                      ? (r[6] / 1000).toFixed(1) + "s"
                      : "—"}
                  </td>
                  <td>{r[2] ?? ""}</td>
                </tr>
              ))}
          </tbody>
        </table>
        {state && <p className="empty-state">{state}</p>}
      </div>
      <div className="two-grid">
        <Button onClick={() => page(-12)}>Page up</Button>
        <Button onClick={() => page(12)}>Page down</Button>
      </div>
      <div className="cue-actions">
        <Button onClick={() => page(0)}>Current cue</Button>
        <Button disabled={locked} onClick={() => setGoto(!goto)}>
          Go to cue
        </Button>
        <Button
          disabled={locked}
          onClick={() => tap(`/eos/cues/${loaded}/stop`)}
        >
          Stop / Back
        </Button>
        <Button
          disabled={locked}
          onClick={() => tap(`/eos/cues/${loaded}/fire`)}
        >
          Go
        </Button>
      </div>
      {goto && !locked && (
        <Panel>
          <form
            className="inline-form"
            onSubmit={(e) => {
              e.preventDefault();
              command(`Go_To_Cue ${loaded} / ${Number(number)} Enter`);
            }}
          >
            <label>
              Cue number
              <input
                type="number"
                min="0"
                step="0.001"
                required
                value={number}
                onChange={(e) => setNumber(e.target.value)}
              />
            </label>
            <button>Run cue</button>
          </form>
        </Panel>
      )}
    </>
  );
}
export default function ExtraViews({ tab }) {
  return (
    <React.Fragment key={tab}>
      {tab === "wheels" ? (
        <Wheels />
      ) : tab === "color" ? (
        <Color />
      ) : tab === "patch" ? (
        <Patch />
      ) : (
        <Cues />
      )}
    </React.Fragment>
  );
}
